#Requires -Version 7.4

<#
.SYNOPSIS
    Deletes old versions of managed Win32 apps from Intune according to the tenant's retention policy

.DESCRIPTION
    Evaluates the tenant live - the same read and analysis as Get-IntuneAppInventory.ps1, never a
    saved report - and deletes the retention evaluator's delete candidates, oldest version first,
    for every app family in the tenant's deployment plan. A version is deleted only when it is
    outside the newest KeepNewest versions AND older than KeepNewerThanWeeks weeks (see
    TenantDeployments.json). Never deleted: the newest version, dependency targets, duplicate
    version numbers (Review), versions whose relationships could not be read, families outside
    the deployment plan, and apps that do not follow the family naming convention (unmanaged).

    Safety:
      - The tenant must opt in with a tenant-level "Retention" block in TenantDeployments.json.
      - -WhatIf previews every deletion; without it, each deletion asks for confirmation
        (answer "Yes to All" to approve the rest, or pass -Confirm:$false for an unattended run).
      - Right before each DELETE the app's relationships are re-read; an app that became a
        dependency target in the meantime is skipped.
      - Every decision is written to <OutputPath>/<Tenant>-cleanup-<yyyyMMdd-HHmm>.json.

.PARAMETER TenantName
    Name of a pre-configured tenant from intune-tenants.json (see Add-IntuneTenant). The
    retention policy and the deployment plan are read from TenantDeployments.json.

.PARAMETER AppName
    Optional. Restrict the cleanup to one AppConfig family (e.g. "Chrome").

.PARAMETER OutputPath
    Folder for the cleanup log. Default: inventory/ next to this script.

.PARAMETER SkipInstallation
    Do not install missing PowerShell modules automatically.

.EXAMPLE
    .\Remove-OldIntuneAppVersions.ps1 -TenantName "MZ" -WhatIf

.EXAMPLE
    .\Remove-OldIntuneAppVersions.ps1 -TenantName "MZ" -AppName "Chrome"

.EXAMPLE
    .\Remove-OldIntuneAppVersions.ps1 -TenantName "MZ" -Confirm:$false
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantName,

    [string]$AppName,

    [string]$OutputPath,

    [switch]$SkipInstallation
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "SharedFunctions.ps1")
. (Join-Path $PSScriptRoot "IntuneSession.ps1")
. (Join-Path $PSScriptRoot "TenantDeployments.ps1")
. (Join-Path $PSScriptRoot "IntuneInventory.ps1")
. (Join-Path $PSScriptRoot "AppCleanup.ps1")

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Intune Win32 App Version Cleanup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "Preview mode (-WhatIf): nothing will be deleted" -ForegroundColor Yellow
}
Write-Host ""

# --- Opt-in gate and plan scope: no credentials needed for these -----------------------------
$tenantPolicy = Get-TenantRetentionPolicy -TenantName $TenantName
if (-not $tenantPolicy.OptIn) {
    Write-Host "Tenant '$TenantName' has not opted in to automated cleanup." -ForegroundColor Red
    Write-Host "Add a tenant-level Retention block to its entry in TenantDeployments.json, for example:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  `"$TenantName`": {" -ForegroundColor Gray
    Write-Host "    `"Retention`": { `"KeepNewest`": 3, `"KeepNewerThanWeeks`": 10 }," -ForegroundColor Gray
    Write-Host "    `"Apps`": { ... }" -ForegroundColor Gray
    Write-Host "  }" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Get-IntuneAppInventory.ps1 shows what the policy would do without opting in." -ForegroundColor Yellow
    exit 1
}

$plan = Get-TenantDeploymentPlan -TenantName $TenantName
if (-not $plan -or $plan.Count -eq 0) {
    Write-Host "Tenant '$TenantName' has no apps in its deployment plan - the cleanup only touches families in the plan, so there is nothing to do." -ForegroundColor Red
    exit 1
}
$planAppNames = @($plan.Keys)
Write-Host "Tenant policy: keep the newest $($tenantPolicy.KeepNewest) version(s) plus everything newer than $($tenantPolicy.KeepNewerThanWeeks) week(s); $($planAppNames.Count) app(s) in the deployment plan" -ForegroundColor Gray

$allFamilies = @(Get-AppFamilyCatalog)
$families = $allFamilies
if ($AppName) {
    $selected = $allFamilies | Where-Object { $_.AppConfigName -eq $AppName }
    if (-not $selected) {
        Write-Host "Error: App '$AppName' not found in AppConfig.ps1. Known apps: $($allFamilies.AppConfigName -join ', ')" -ForegroundColor Red
        exit 1
    }
    $families = @($selected)
}

# --- Connect ---------------------------------------------------------------------------------
$tenantCreds = Resolve-IntuneTenantCredential -TenantName $TenantName
if ($null -eq $tenantCreds) {
    exit 1
}
if (-not (Connect-IntuneTenantSession -TenantId $tenantCreds.TenantId -ClientId $tenantCreds.ClientId -ClientSecret $tenantCreds.ClientSecret -SkipInstallation:$SkipInstallation -UsageHint '.\Remove-OldIntuneAppVersions.ps1 -TenantName <name>')) {
    exit 1
}

# --- Evaluate live (identical to the inventory) ----------------------------------------------
Write-Host "`nReading the tenant..." -ForegroundColor Cyan
$inventory = Read-IntuneAppInventory -Families $allFamilies -IncludeInstallSummary
$records = @($inventory.Records)
$recordsForAnalysis = $records
if ($AppName) {
    $recordsForAnalysis = @($records | Where-Object { $_.Family -eq $AppName -or $null -eq $_.Family })
}

$appConfigs = @{}
foreach ($family in $families) {
    $appConfigs[$family.AppConfigName] = Get-AppConfiguration -AppName $family.AppConfigName
}
$policyResolver = { param($appConfigName) Get-TenantRetentionPolicy -TenantName $TenantName -AppName $appConfigName }
$now = [datetime]::UtcNow
$analysis = Get-AppInventoryAnalysis -Records $recordsForAnalysis -Families $families -PolicyResolver $policyResolver -PlanAppNames $planAppNames -AppConfigs $appConfigs -Now $now
$cleanup = Get-AppCleanupPlan -Analysis $analysis -Records $recordsForAnalysis

# --- Show the plan ---------------------------------------------------------------------------
Write-Host ""
$cleanup.Families | ForEach-Object {
    [PSCustomObject]@{
        Family    = $_.Family
        InPlan    = $_.InPlan
        Policy    = "$($_.Policy.KeepNewest)/$($_.Policy.KeepNewerThanWeeks)w"
        Versions  = $_.VersionCount
        Keep      = $_.KeepCount
        Review    = $_.ReviewCount
        Delete    = $_.Deletions.Count
        Skipped   = $_.Skipped.Count
        Remaining = $_.RemainingAfterCleanup
    }
} | Format-Table -AutoSize | Out-Host

if ($analysis.Summary.AppsWithUnavailableRelationships -gt 0) {
    Write-Host "Warning: relationships of $($analysis.Summary.AppsWithUnavailableRelationships) app(s) could not be read; those apps are excluded from deletion. Re-run for a complete cleanup." -ForegroundColor Yellow
}
foreach ($family in ($cleanup.Families | Where-Object { $_.Skipped.Count -gt 0 })) {
    foreach ($s in $family.Skipped) {
        Write-Host "  Skipped: $($s.DisplayName) v$($s.DisplayVersion) - $($s.Reason)" -ForegroundColor Yellow
    }
}

# --- Execute ---------------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
if ($cleanup.DeletionCount -eq 0) {
    Write-Host "Nothing to delete." -ForegroundColor Green
}
else {
    Write-Host "$($cleanup.DeletionCount) version(s) to delete:" -ForegroundColor Cyan
    foreach ($d in $cleanup.Deletions) {
        $installed = if ($null -ne $d.InstalledDeviceCount) { "$($d.InstalledDeviceCount) device(s)" } else { 'unknown' }
        Write-Host ("  {0,-45} v{1,-18} rank {2,2}  {3,6} weeks  installed: {4}" -f $d.DisplayName, $d.DisplayVersion, $d.Rank, $d.AgeWeeks, $installed) -ForegroundColor Gray
    }
    Write-Host ""

    foreach ($deletion in $cleanup.Deletions) {
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

        # Re-check right before deleting: the app must still exist and must not have become a
        # dependency target since the evaluation.
        try {
            $fresh = @(Get-InteropAppRelationship -AppId $deletion.Id)
        }
        catch {
            $outcome.Outcome = 'Skipped'
            $outcome.Detail = "could not re-read relationships: $($_.Exception.Message)"
            Write-Host "  Skipped $label - $($outcome.Detail)" -ForegroundColor Yellow
            $results.Add([PSCustomObject]$outcome)
            continue
        }
        $dependents = @($fresh | Where-Object { "$($_.'@odata.type')" -like '*mobileAppDependency' -and "$($_.targetType)" -eq 'parent' })
        if ($dependents.Count -gt 0) {
            $outcome.Outcome = 'Skipped'
            $outcome.Detail = "is now a dependency target of: $(($dependents | ForEach-Object { $_.targetDisplayName }) -join ', ')"
            Write-Host "  Skipped $label - $($outcome.Detail)" -ForegroundColor Yellow
            $results.Add([PSCustomObject]$outcome)
            continue
        }

        if ($PSCmdlet.ShouldProcess($label, 'Delete Win32 app from Intune')) {
            try {
                Remove-InteropWin32App -AppId $deletion.Id
                $outcome.Outcome = 'Deleted'
                Write-Host "  Deleted $label" -ForegroundColor Green
            }
            catch {
                $outcome.Outcome = 'Failed'
                $outcome.Detail = $_.Exception.Message
                Write-Host "  FAILED  $label - $($outcome.Detail)" -ForegroundColor Red
            }
        }
        else {
            $outcome.Outcome = if ($WhatIfPreference) { 'WouldDelete' } else { 'Declined' }
        }
        $results.Add([PSCustomObject]$outcome)
    }
}

# --- Log and summary -------------------------------------------------------------------------
if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot 'inventory'
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$safeName = ($TenantName -replace '[^\w\-\.]', '_')
$logPath = Join-Path $OutputPath "$safeName-cleanup-$($now.ToString('yyyyMMdd-HHmm')).json"
$document = [ordered]@{
    Tenant       = $TenantName
    GeneratedUtc = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    ToolVersion  = ((Get-Content (Join-Path $PSScriptRoot 'VERSION.txt') -Raw -ErrorAction SilentlyContinue) ?? '').Trim()
    Mode         = if ($WhatIfPreference) { 'WhatIf' } else { 'Live' }
    AppName      = $AppName
    TenantPolicy = [ordered]@{ KeepNewest = $tenantPolicy.KeepNewest; KeepNewerThanWeeks = $tenantPolicy.KeepNewerThanWeeks }
    PlanApps     = $planAppNames
    Summary      = $analysis.Summary
    Families     = $cleanup.Families
    Results      = @($results)
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($logPath, ($document | ConvertTo-Json -Depth 12), $utf8)

$deleted = @($results | Where-Object Outcome -eq 'Deleted').Count
$failed = @($results | Where-Object Outcome -eq 'Failed').Count
$skippedLate = @($results | Where-Object Outcome -eq 'Skipped').Count
$declined = @($results | Where-Object Outcome -eq 'Declined').Count
$wouldDelete = @($results | Where-Object Outcome -eq 'WouldDelete').Count

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Cleanup summary - $TenantName" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "  Would delete: $wouldDelete version(s) (preview, nothing changed)"
}
else {
    Write-Host "  Deleted: $deleted, failed: $failed, skipped at delete time: $skippedLate, declined: $declined"
}
foreach ($family in ($cleanup.Families | Where-Object { $_.Deletions.Count -gt 0 })) {
    $familyDeleted = @($results | Where-Object { $_.Family -eq $family.Family -and $_.Outcome -eq 'Deleted' }).Count
    Write-Host ("  {0}: {1} of {2} version(s) {3}, {4} remain" -f $family.Family, ($(if ($WhatIfPreference) { $family.Deletions.Count } else { $familyDeleted })), $family.VersionCount, ($(if ($WhatIfPreference) { 'would be deleted' } else { 'deleted' })), ($family.VersionCount - $(if ($WhatIfPreference) { $family.Deletions.Count } else { $familyDeleted }))) -ForegroundColor Gray
}
Write-Host "  Log: $logPath" -ForegroundColor Gray
if ($deleted -gt 0) {
    Write-Host "  Re-run Get-IntuneAppInventory.ps1 to verify the remaining chains." -ForegroundColor Gray
}
Write-Host ""

if ($failed -gt 0) {
    exit 1
}
