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
      - After the confirmation (which may have sat open for a while) the app's relationships
        are re-read; an app that became a dependency target in the meantime is skipped and
        nothing is touched. Otherwise the version is unlinked first - the superseding version's
        relationship set is updated without it, as Intune refuses to delete an app that is part
        of a supersedence relationship - and then the app is deleted.
      - Every decision is written to <OutputPath>/<Tenant>-cleanup-<yyyyMMdd-HHmmss>.json
        (never overwritten - a second run in the same second gets a numbered suffix).
      - Deploy-ToIntune.ps1 runs the same retention unattended after each deploy for opted-in
        tenants (see -NoRetention there); this script is the interactive, tenant-wide pass.

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
. (Join-Path $PSScriptRoot "IntuneCleanup.ps1")

# The per-version confirmation (ShouldProcess) lives in the shared executor's decision hook
$cleanupCmdlet = $PSCmdlet

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

# --- Connected from here on: the finally block disconnects on every exit path ----------------
try {
    # --- Evaluate live (identical to the inventory) ----------------------------------------------
    Write-Host "`nReading the tenant..." -ForegroundColor Cyan
    # With -AppName only that family's apps are read in detail (the cleanup never touches
    # unmanaged apps, so they are not needed here)
    $readScope = if ($AppName) { @{ OnlyFamilies = @($AppName) } } else { @{} }
    $inventory = Read-IntuneAppInventory -Families $allFamilies -IncludeInstallSummary @readScope
    $records = @($inventory.Records)
    $recordsForAnalysis = $records
    if ($AppName) {
        $recordsForAnalysis = @($records | Where-Object { $_.Family -eq $AppName })
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

    # --- Execute (shared executor; the decision is this script's ShouldProcess prompt) -------------
    $results = @()
    if ($cleanup.DeletionCount -eq 0) {
        Write-Host "Nothing to delete." -ForegroundColor Green
    }
    else {
        Write-Host "$($cleanup.DeletionCount) version(s) to delete:" -ForegroundColor Cyan
        foreach ($d in $cleanup.Deletions) {
            $installed = if ($null -ne $d.InstalledDeviceCount) { "$($d.InstalledDeviceCount) device(s)" } else { 'unknown' }
            Write-Host ("  {0,-45} v{1,-18} rank {2,2}  {3,6} weeks  installed: {4}" -f $d.DisplayName, $d.DisplayVersion, $d.Rank, ([string]$d.AgeWeeks), $installed) -ForegroundColor Gray
        }
        Write-Host ""

        $results = @(Invoke-IntuneAppCleanup -Plan $cleanup `
            -Decision { param($label) $cleanupCmdlet.ShouldProcess($label, 'Delete Win32 app from Intune') } `
            -DeclinedOutcome $(if ($WhatIfPreference) { 'WouldDelete' } else { 'Declined' }))
    }

    # --- Log and summary -------------------------------------------------------------------------
    if (-not $OutputPath) {
        $OutputPath = Join-Path $PSScriptRoot 'inventory'
    }
    $logPath = Write-AppCleanupLog -Directory $OutputPath -TenantName $TenantName -Now $now `
        -Mode $(if ($WhatIfPreference) { 'WhatIf' } else { 'Live' }) -Trigger 'Cleanup' -AppName $AppName `
        -TenantPolicy $tenantPolicy -PlanAppNames $planAppNames -Summary $analysis.Summary `
        -Families @($cleanup.Families) -Results @($results) -ToolVersionPath (Join-Path $PSScriptRoot 'VERSION.txt')

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
}
finally {
    # Every exit path - success, exit 1, terminating error - drops the privileged Graph session
    Disconnect-IntuneSession -Force
}
