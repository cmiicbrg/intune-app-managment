#Requires -Version 7.4

# IntuneCleanup.ps1
# Executes a cleanup plan (Get-AppCleanupPlan) against Intune - unlink, then delete, one version
# at a time - with the per-version decision supplied by the caller. Shared by
# Remove-OldIntuneAppVersions.ps1 (interactive: ShouldProcess prompt / -WhatIf) and
# Deploy-ToIntune.ps1 (unattended retention after a deploy, for opted-in tenants).
# Also writes the audit log both callers produce.

. (Join-Path $PSScriptRoot "AppCleanup.ps1")

function Invoke-IntuneAppCleanup {
    <#
    .SYNOPSIS
    Deletes the versions of a cleanup plan from Intune and returns one outcome per version

    .DESCRIPTION
    For every deletion in the plan (already ordered: family by name, oldest version first) the
    -Decision scriptblock is asked with a descriptive label; when it returns $true the version is
    unlinked (Remove-InteropAppRelationships - reads the relationships fresh, refuses an app
    that has become a dependency target) and then deleted (Remove-InteropWin32App). Every step
    is reported on the console and in the returned outcome objects:
      Deleted | Skipped (could not re-read, or dependency target - nothing changed)
      | Failed (with the partial-unlink state spelled out) | <DeclinedOutcome>

    The default decision deletes everything (unattended use). A caller with ShouldProcess passes
    { param($label) $cmdlet.ShouldProcess($label, 'Delete Win32 app from Intune') } and sets
    -DeclinedOutcome 'WouldDelete' under -WhatIf.
    #>
    [CmdletBinding()]
    param(
        # Get-AppCleanupPlan output
        [Parameter(Mandatory = $true)]
        $Plan,

        # Receives the label, returns $true to delete that version
        [scriptblock]$Decision = { param($label) $true },

        # Outcome recorded when the decision is $false
        [string]$DeclinedOutcome = 'Declined'
    )

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($deletion in @($Plan.Deletions)) {
        $assignmentInfo = if ($null -ne $deletion.AssignmentCount) { "$($deletion.AssignmentCount) assignment(s)" } else { 'assignments unknown' }
        $label = "$($deletion.DisplayName) v$($deletion.DisplayVersion) [$($deletion.Family)] - rank $($deletion.Rank), $($deletion.AgeWeeks) weeks old, $assignmentInfo"
        $outcome = [ordered]@{
            Id             = $deletion.Id
            Family         = $deletion.Family
            DisplayName    = $deletion.DisplayName
            DisplayVersion = $deletion.DisplayVersion
            Rank           = $deletion.Rank
            AgeWeeks       = $deletion.AgeWeeks
            Outcome        = $null
            Detail         = $null
        }

        if (-not (& $Decision $label)) {
            $outcome.Outcome = $DeclinedOutcome
            $results.Add([PSCustomObject]$outcome)
            continue
        }

        # Everything below happens AFTER the decision (an interactive prompt may have sat open
        # for a while): the relationships are read fresh now. Intune refuses to delete an app
        # that is part of a supersedence relationship, so the version is unlinked first - unless
        # it has become a dependency target in the meantime, in which case nothing is touched.
        $removal = $null
        try {
            $removal = Remove-InteropAppRelationships -AppId $deletion.Id
        }
        catch {
            $outcome.Outcome = 'Skipped'
            $outcome.Detail = "could not re-read relationships: $($_.Exception.Message)"
            Write-Host "  Skipped $label - $($outcome.Detail)" -ForegroundColor Yellow
            $results.Add([PSCustomObject]$outcome)
            continue
        }
        if ($removal.DependencyTargets.Count -gt 0) {
            $outcome.Outcome = 'Skipped'
            $outcome.Detail = "is now a dependency target of: $($removal.DependencyTargets -join ', ') - nothing was changed"
            Write-Host "  Skipped $label - $($outcome.Detail)" -ForegroundColor Yellow
            $results.Add([PSCustomObject]$outcome)
            continue
        }
        if ($removal.Error) {
            $outcome.Outcome = 'Failed'
            $outcome.Detail = "$($removal.Error) ($($removal.Removed) of $($removal.Total) relationship(s) were removed before that - the app is partially unlinked and still in Intune; re-run the cleanup)"
            Write-Host "  FAILED  $label - $($outcome.Detail)" -ForegroundColor Red
            $results.Add([PSCustomObject]$outcome)
            continue
        }

        try {
            Remove-InteropWin32App -AppId $deletion.Id
            $outcome.Outcome = 'Deleted'
            $outcome.Detail = "$($removal.Removed) relationship(s) removed first"
            Write-Host "  Deleted $label" -ForegroundColor Green
        }
        catch {
            $outcome.Outcome = 'Failed'
            $outcome.Detail = $_.Exception.Message
            if ($removal.Removed -gt 0) {
                $outcome.Detail += " (its $($removal.Removed) relationship(s) were already removed, so the app is now unlinked and still in Intune - re-run the cleanup)"
            }
            Write-Host "  FAILED  $label - $($outcome.Detail)" -ForegroundColor Red
        }
        $results.Add([PSCustomObject]$outcome)
    }
    return @($results)
}

function Write-AppCleanupLog {
    <#
    .SYNOPSIS
    Writes the audit log of a cleanup run and returns its path

    .DESCRIPTION
    One file per run under -Directory: <Tenant>-cleanup-<yyyyMMdd-HHmmss>.json, with a numbered
    suffix if that name already exists - a log is never overwritten. Records what was decided
    (Families: deletions and skipped candidates with reasons) and what happened (Results).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$TenantName,

        [datetime]$Now = [datetime]::UtcNow,

        # 'Live' or 'WhatIf'
        [string]$Mode = 'Live',

        # What started the run: 'Cleanup' (the script) or 'Deploy' (retention after a deploy)
        [string]$Trigger = 'Cleanup',

        [string]$AppName,

        # Get-TenantRetentionPolicy output (tenant level)
        $TenantPolicy,

        [string[]]$PlanAppNames,

        # Get-AppInventoryAnalysis Summary (optional)
        $Summary,

        # Get-AppCleanupPlan Families
        [AllowEmptyCollection()]
        [array]$Families = @(),

        # Invoke-IntuneAppCleanup output
        [AllowEmptyCollection()]
        [array]$Results = @(),

        [string]$ToolVersionPath = (Join-Path $PSScriptRoot 'VERSION.txt')
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $safeName = ($TenantName -replace '[^\w\-\.]', '_')
    $stamp = $Now.ToString('yyyyMMdd-HHmmss')
    $logPath = Join-Path $Directory "$safeName-cleanup-$stamp.json"
    $suffix = 1
    while (Test-Path -LiteralPath $logPath) {
        $suffix++
        $logPath = Join-Path $Directory "$safeName-cleanup-$stamp-$suffix.json"
    }

    $document = [ordered]@{
        Tenant       = $TenantName
        GeneratedUtc = $Now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        ToolVersion  = ((Get-Content $ToolVersionPath -Raw -ErrorAction SilentlyContinue) ?? '').Trim()
        Mode         = $Mode
        Trigger      = $Trigger
        AppName      = $AppName
        TenantPolicy = if ($TenantPolicy) { [ordered]@{ KeepNewest = $TenantPolicy.KeepNewest; KeepNewerThanWeeks = $TenantPolicy.KeepNewerThanWeeks } } else { $null }
        PlanApps     = $PlanAppNames
        Summary      = $Summary
        Families     = $Families
        Results      = $Results
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($logPath, ($document | ConvertTo-Json -Depth 12), $utf8)
    return $logPath
}
