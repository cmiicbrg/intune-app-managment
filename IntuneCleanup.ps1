#Requires -Version 7.4

# IntuneCleanup.ps1
# Executes a cleanup plan (Get-AppCleanupPlan) against Intune - unlink, then delete, one version
# at a time - with the per-version decision supplied by the caller. Shared by
# Remove-OldIntuneAppVersions.ps1 (interactive: ShouldProcess prompt / -WhatIf) and
# Deploy-ToIntune.ps1 (unattended retention after a deploy, for opted-in tenants).
# Also writes the audit log both callers produce.

. (Join-Path $PSScriptRoot "AppCleanup.ps1")

# The one-line description of a planned deletion, used for the decision prompt and the console.
function Format-AppCleanupLabel {
    param([Parameter(Mandatory = $true)] $Deletion)

    $assignmentInfo = if ($null -ne $Deletion.AssignmentCount) { "$($Deletion.AssignmentCount) assignment(s)" } else { 'assignments unknown' }
    $superseded = if ($null -ne $Deletion.SupersededWeeks) { "superseded $($Deletion.SupersededWeeks) weeks ago" } else { 'superseded at an unknown time' }

    return "$($Deletion.DisplayName) v$($Deletion.DisplayVersion) [$($Deletion.Family)] - rank $($Deletion.Rank), $superseded, $($Deletion.AgeWeeks) weeks old, $assignmentInfo"
}

# Unlinks and deletes one version, returning @{ Outcome; Detail }.
#
# Everything here happens AFTER the decision (an interactive prompt may have sat open for a
# while): the relationships are read fresh now. Intune refuses to delete an app that is part of
# a supersedence relationship, so the version is unlinked first - unless it has become a
# dependency target in the meantime, in which case nothing is touched.
function Remove-IntuneAppVersion {
    param(
        [Parameter(Mandatory = $true)] $Deletion
    )

    try {
        $removal = Remove-InteropAppRelationships -AppId $Deletion.Id
    }
    catch {
        return @{ Outcome = 'Skipped'; Detail = "could not re-read relationships: $($_.Exception.Message)" }
    }

    if ($removal.DependencyTargets.Count -gt 0) {
        return @{ Outcome = 'Skipped'; Detail = "is now a dependency target of: $($removal.DependencyTargets -join ', ') - nothing was changed" }
    }
    if ($removal.Error) {
        return @{ Outcome = 'Failed'; Detail = "$($removal.Error) ($($removal.Removed) of $($removal.Total) relationship(s) were removed before that - the app is partially unlinked and still in Intune; re-run the cleanup)" }
    }

    try {
        Remove-InteropWin32App -AppId $Deletion.Id
        return @{ Outcome = 'Deleted'; Detail = "$($removal.Removed) relationship(s) removed first" }
    }
    catch {
        $detail = $_.Exception.Message
        if ($removal.Removed -gt 0) {
            $detail += " (its $($removal.Removed) relationship(s) were already removed, so the app is now unlinked and still in Intune - re-run the cleanup)"
        }
        return @{ Outcome = 'Failed'; Detail = $detail }
    }
}

# Reports one version's outcome on the console.
function Write-AppCleanupOutcome {
    param(
        [Parameter(Mandatory = $true)] [string]$Outcome,
        [Parameter(Mandatory = $true)] [string]$Label,
        [AllowNull()] [string]$Detail
    )

    switch ($Outcome) {
        'Deleted' { Write-Host "  Deleted $Label" -ForegroundColor Green }
        'Skipped' { Write-Host "  Skipped $Label - $Detail" -ForegroundColor Yellow }
        'Failed' { Write-Host "  FAILED  $Label - $Detail" -ForegroundColor Red }
    }
}

function Invoke-IntuneAppCleanup {
    <#
    .SYNOPSIS
    Deletes the versions of a cleanup plan from Intune and returns one outcome per version

    .DESCRIPTION
    For every deletion in the plan (already ordered: family by name, oldest version first) the
    -Decision scriptblock is asked with a descriptive label; when it returns $true the version is
    unlinked (Remove-InteropAppRelationships - reads the relationships fresh, refuses an app
    that has become a dependency target) and then deleted (Remove-InteropWin32App). Every outcome
    is reported on the console (a declined version too, except under -WhatIf where ShouldProcess
    prints its own "What if" line) and returned as an outcome object:
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
        $label = Format-AppCleanupLabel -Deletion $deletion
        $outcome = [ordered]@{
            Id              = $deletion.Id
            Family          = $deletion.Family
            DisplayName     = $deletion.DisplayName
            DisplayVersion  = $deletion.DisplayVersion
            Rank            = $deletion.Rank
            AgeWeeks        = $deletion.AgeWeeks
            SupersededWeeks = $deletion.SupersededWeeks
            Outcome         = $null
            Detail          = $null
        }

        if (-not (& $Decision $label)) {
            $outcome.Outcome = $DeclinedOutcome
            # Under -WhatIf, ShouldProcess has already printed its "What if" line for this label
            if ($DeclinedOutcome -ne 'WouldDelete') {
                Write-Host "  Declined $label" -ForegroundColor Yellow
            }
            $results.Add([PSCustomObject]$outcome)
            continue
        }

        $result = Remove-IntuneAppVersion -Deletion $deletion
        $outcome.Outcome = $result.Outcome
        $outcome.Detail = $result.Detail
        Write-AppCleanupOutcome -Outcome $result.Outcome -Label $label -Detail $result.Detail

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
