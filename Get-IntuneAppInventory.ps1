#Requires -Version 7.4

<#
.SYNOPSIS
    Creates a local, read-only inventory of a tenant's Win32 apps in Intune

.DESCRIPTION
    Fetches every Win32 app with its assignments, supersedence/dependency relationships and
    (by default) install summary, maps each app to its AppConfig family, evaluates the tenant's
    version-retention policy (TenantDeployments.json), sizes supersedence graphs against Intune's
    limit, and flags anomalies - all without changing anything in Intune.

    Writes two files to -OutputPath (default: inventory/, git-ignored):
      <Tenant>-<yyyyMMdd-HHmm>.json   full structured snapshot
      <Tenant>-<yyyyMMdd-HHmm>.md     human-readable report

.PARAMETER TenantName
    Name of a pre-configured tenant from intune-tenants.json (see Add-IntuneTenant).
    Use this OR provide TenantId/ClientId/ClientSecret directly.

.PARAMETER AppName
    Optional. Restrict the analysis to one AppConfig family (e.g. "Chrome"). Unmanaged apps
    and near-miss names of that family are still reported.

.PARAMETER OutputPath
    Folder for the report files. Default: inventory/ next to this script.

.PARAMETER SkipInstallSummary
    Skip the install counts (one tenant-wide report request).

.PARAMETER SkipInstallation
    Do not install missing PowerShell modules automatically.

.EXAMPLE
    .\Get-IntuneAppInventory.ps1 -TenantName "MZ"

.EXAMPLE
    .\Get-IntuneAppInventory.ps1 -TenantName "MZ" -AppName "Chrome" -SkipInstallSummary
#>

[CmdletBinding(DefaultParameterSetName = 'TenantName')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'TenantName')]
    [ValidateNotNullOrEmpty()]
    [string]$TenantName,

    [Parameter(Mandatory = $true, ParameterSetName = 'DirectCredentials')]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory = $true, ParameterSetName = 'DirectCredentials')]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,

    [Parameter(Mandatory = $true, ParameterSetName = 'DirectCredentials')]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret,

    [string]$AppName,

    [string]$OutputPath,

    [switch]$SkipInstallSummary,

    [switch]$SkipInstallation
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "SharedFunctions.ps1")
. (Join-Path $PSScriptRoot "IntuneSession.ps1")
. (Join-Path $PSScriptRoot "TenantDeployments.ps1")
. (Join-Path $PSScriptRoot "IntuneInventory.ps1")

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Intune Win32 App Inventory (read-only)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Resolve credentials and connect (shared bootstrap)
if ($PSCmdlet.ParameterSetName -eq 'TenantName') {
    $tenantCreds = Resolve-IntuneTenantCredential -TenantName $TenantName
    if ($null -eq $tenantCreds) {
        exit 1
    }
    $TenantId = $tenantCreds.TenantId
    $ClientId = $tenantCreds.ClientId
    $ClientSecret = $tenantCreds.ClientSecret
    $reportName = $TenantName
}
else {
    $reportName = $TenantId
}

if (-not (Connect-IntuneTenantSession -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -SkipInstallation:$SkipInstallation -UsageHint '.\Get-IntuneAppInventory.ps1 -TenantId <tenant> -ClientId <id> -ClientSecret <secret>')) {
    exit 1
}

# Connected from here on: the finally block disconnects on every exit path
try {
    # Families, plan scope, retention policy resolver. Classification always uses the FULL catalog
    # so apps of other families are recognized as managed (not misreported as unmanaged) even when
    # -AppName narrows the analysis scope to one family.
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

    $planAppNames = $null
    $policyResolver = { param($appConfigName) Get-TenantRetentionPolicy -TenantName $reportName -AppName $appConfigName }
    if ($PSCmdlet.ParameterSetName -eq 'TenantName') {
        $plan = Get-TenantDeploymentPlan -TenantName $TenantName
        if ($plan) {
            $planAppNames = @($plan.Keys)
            Write-Host "Deployment plan for '$TenantName': $($planAppNames.Count) app(s)" -ForegroundColor Gray
        }
        else {
            Write-Host "No deployment plan for '$TenantName' - all AppConfig families are treated as in scope" -ForegroundColor Gray
        }
    }
    else {
        # No tenant name -> no plan lookup possible; policy falls back to the built-in defaults
        $policyResolver = { param($appConfigName) Get-TenantRetentionPolicy -TenantName '__direct__' -AppName $appConfigName }
    }

    $appConfigs = @{}
    foreach ($family in $families) {
        $appConfigs[$family.AppConfigName] = Get-AppConfiguration -AppName $family.AppConfigName
    }

    # Fetch through the read path shared with the cleanup, so both see the same evaluation
    Write-Host "`nFetching Win32 apps..." -ForegroundColor Cyan
    # With -AppName, details are read for that family plus the unmanaged apps only (the latter
    # for near-miss reporting); other families are classified from the list but not fetched
    $readScope = if ($AppName) { @{ OnlyFamilies = @($AppName); IncludeUnmanaged = $true } } else { @{} }
    $inventory = Read-IntuneAppInventory -Families $allFamilies -IncludeInstallSummary:(-not $SkipInstallSummary) -ResolveGroupNames @readScope
    $records = @($inventory.Records)
    $includesInstallSummary = $inventory.IncludesInstallSummary

    # Analyze. With -AppName, scope the records to that family plus the unmanaged apps (so near-miss
    # names of the selected family are still reported); apps of other families are out of scope but
    # correctly classified, not "unmanaged".
    $recordsForAnalysis = @($records)
    if ($AppName) {
        $recordsForAnalysis = @($records | Where-Object { $_.Family -eq $AppName -or $null -eq $_.Family })
    }
    $now = [datetime]::UtcNow
    $analysis = Get-AppInventoryAnalysis -Records $recordsForAnalysis -Families $families -PolicyResolver $policyResolver -PlanAppNames $planAppNames -AppConfigs $appConfigs -Now $now

    # Write
    if (-not $OutputPath) {
        $OutputPath = Join-Path $PSScriptRoot 'inventory'
    }
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    $stamp = $now.ToString('yyyyMMdd-HHmm')
    $safeName = ($reportName -replace '[^\w\-\.]', '_')
    $jsonPath = Join-Path $OutputPath "$safeName-$stamp.json"
    $mdPath = Join-Path $OutputPath "$safeName-$stamp.md"

    $document = [ordered]@{
        Tenant                 = $reportName
        GeneratedUtc           = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        ToolVersion            = ((Get-Content (Join-Path $PSScriptRoot 'VERSION.txt') -Raw -ErrorAction SilentlyContinue) ?? '').Trim()
        IncludesInstallSummary = $includesInstallSummary
        PlanApps               = $planAppNames
        Summary                = $analysis.Summary
        Families               = $analysis.Families
        Anomalies              = $analysis.Anomalies
        Unmanaged              = $analysis.Unmanaged
        Apps                   = @($recordsForAnalysis | Select-Object -Property * -ExcludeProperty ParsedVersion)
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonPath, ($document | ConvertTo-Json -Depth 12), $utf8)
    [System.IO.File]::WriteAllText($mdPath, (Format-AppInventoryMarkdown -TenantName $reportName -GeneratedUtc $now -Analysis $analysis -Records $recordsForAnalysis -IncludesInstallSummary $includesInstallSummary), $utf8)

    # Console summary
    $s = $analysis.Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Inventory summary - $reportName" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ("  Win32 apps: {0} ({1} managed, {2} unmanaged)" -f $s.TotalWin32Apps, $s.ManagedApps, $s.UnmanagedApps)
    Write-Host ("  Families present: {0}, near supersedence graph limit: {1}" -f $s.FamiliesPresent, $s.FamiliesNearGraphLimit)
    Write-Host ("  Retention: {0} delete candidate(s), {1} to review" -f $s.DeleteCandidates, $s.ReviewItems)
    Write-Host ""
    $analysis.Families | Sort-Object Family | ForEach-Object {
        [PSCustomObject]@{
            Family   = $_.Family
            InPlan   = $_.InPlan
            Versions = $_.VersionCount
            Newest   = if ($_.Newest) { $_.Newest.Version } else { '-' }
            Graph    = $_.SupersedenceGraphNodes
            Policy   = "$($_.Policy.KeepNewest)/$($_.Policy.KeepNewerThanWeeks)w"
            Keep     = $_.KeepCount
            Delete   = $_.DeleteCandidateCount
            Review   = $_.ReviewCount
        }
    } | Format-Table -AutoSize | Out-Host

    if ($analysis.Anomalies.Count -gt 0) {
        Write-Host "Anomalies:" -ForegroundColor Yellow
        foreach ($a in ($analysis.Anomalies | Sort-Object Type, Family)) {
            Write-Host "  [$($a.Type)] $($a.Family): $($a.Message)" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "Report written:" -ForegroundColor Green
    Write-Host "  $jsonPath" -ForegroundColor Gray
    Write-Host "  $mdPath" -ForegroundColor Gray
    Write-Host ""
}
finally {
    # Every exit path - success, exit 1, terminating error - drops the privileged Graph session
    Disconnect-IntuneSession -Force
}
