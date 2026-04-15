# Complete Intune Win32 App Deployment Script
# Uses IntuneWin32App module for proper deployment


<#
.SYNOPSIS
    Deploys Win32 applications to Microsoft Intune using IntuneWin32App module

.DESCRIPTION
    This script automatically deploys all IntuneWin packages to Microsoft Intune.
    It uses the IntuneWin32App PowerShell module for proper Win32 app management.

.PARAMETER TenantName
    Name of pre-configured tenant from intune-tenants.json (see Add-IntuneTenant).
    Use this OR provide TenantId/ClientId/ClientSecret directly.

.PARAMETER AppName
    Optional. If specified, only deploys the specified app from AppConfig (e.g., "Firefox", "Chrome")

.PARAMETER AssignToAllUsers
    If specified, assigns the app to "All Users" group

.PARAMETER AssignToAllDevices
    If specified, assigns the app to "All Devices" group

.PARAMETER AssignToGroupName
    Optional. Name of Azure AD group to assign the app to (e.g., "Teachers", "IT-Staff")

.PARAMETER GroupAssignmentIntent
    Intent for group assignment: "Available" or "Required". Default is "Available"

.PARAMETER ForceUpdate
    If specified, creates new versions even if apps already exist (for updates/supersedence)

.EXAMPLE
    .\Deploy-ToIntune.ps1 -TenantName "School" -AssignToAllUsers

.EXAMPLE
    .\Deploy-ToIntune.ps1 -TenantName "School" -AppName "Firefox" -AssignToAllUsers

.EXAMPLE
    .\Deploy-ToIntune.ps1 -TenantId "xxx" -ClientId "yyy" -ClientSecret "zzz" -AppName "Chrome"

.NOTES
    Prerequisites:
    1. Install-Module -Name IntuneWin32App
    2. Configure tenant: Add-IntuneTenant -Name "YourTenant"
       OR provide TenantId, ClientId, ClientSecret parameters directly
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
    
    [Parameter(Mandatory = $false)]
    [string]$AppName,
    
    [Parameter(Mandatory = $false)]
    [switch]$AssignToAllUsers,
    
    [Parameter(Mandatory = $false)]
    [switch]$AssignToAllDevices,
    
    [Parameter(Mandatory = $false)]
    [string]$AssignToGroupName,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Available", "Required")]
    [string]$GroupAssignmentIntent = "Available",
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipInstallation,
    
    [Parameter(Mandatory = $false)]
    [switch]$ForceUpdate
)

$ErrorActionPreference = "Stop"
$BaseDir = $PSScriptRoot

# Import shared functions and configuration
. (Join-Path $PSScriptRoot "SharedFunctions.ps1")
. (Join-Path $PSScriptRoot "AuthenticationManager.ps1")
. (Join-Path $PSScriptRoot "TenantConfig.ps1")

# Resolve TenantName to credentials if using that parameter set
if ($PSCmdlet.ParameterSetName -eq 'TenantName') {
    Write-Host "Loading credentials for tenant '$TenantName'..." -ForegroundColor Cyan
    $tenantCreds = Get-IntuneTenant -Name $TenantName
    
    if ($null -eq $tenantCreds) {
        Write-Host "Failed to retrieve credentials for tenant '$TenantName'." -ForegroundColor Red
        Write-Host ""
        Write-Host "To configure a new tenant, run:" -ForegroundColor Yellow
        Write-Host "  . .\TenantConfig.ps1" -ForegroundColor Gray
        Write-Host "  Add-IntuneTenant -Name '$TenantName'" -ForegroundColor Gray
        exit 1
    }
    
    $TenantId = $tenantCreds.TenantId
    $ClientId = $tenantCreds.ClientId
    $ClientSecret = $tenantCreds.ClientSecret
    
    Write-Host "Credentials loaded for tenant: $TenantName (TenantId: $TenantId)" -ForegroundColor Green
}

# Check and install IntuneWin32App module
function Install-RequiredModules {
    Write-Host "Checking required modules..." -ForegroundColor Cyan
    
    $requiredModules = @(
        "IntuneWin32App",
        "Microsoft.Graph.Authentication",
        "Microsoft.Graph.Groups"
    )
    
    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            Write-Host "Module '$moduleName' not found. Installing..." -ForegroundColor Yellow
            try {
                if (-not $SkipInstallation) {
                    Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber
                    Write-Host "Successfully installed $moduleName" -ForegroundColor Green
                }
                else {
                    Write-Host "Skipping installation of $moduleName (use without -SkipInstallation to install)" -ForegroundColor Yellow
                    return $false
                }
            }
            catch {
                Write-Host "Failed to install $moduleName : $_" -ForegroundColor Red
                return $false
            }
        }
        else {
            Write-Host "Module '$moduleName' is already installed" -ForegroundColor Green
        }
    }
    
    return $true
}

# Create app configuration and upload
function Publish-App {
    param(
        [string]$AppName,
        [string]$IntuneWinPath,
        [string]$SetupFileName,
        [hashtable]$AppConfig,
        [string]$NewVersion,
        [string]$IconPath,
        [switch]$ForceUpdate
    )
    
    Write-Host "`n  Checking for existing apps..." -ForegroundColor Cyan
    
    try {
        # Get the base app name without version for searching (e.g., "Google Chrome" from "Google Chrome 142")
        $baseDisplayName = $AppConfig.DisplayName -replace '\s+\d+.*$', ''
        Write-Host "  Searching for apps matching: '$baseDisplayName*'" -ForegroundColor Gray
        
        # Search for all apps that start with the base display name (to find different versions)
        $searchPattern = $baseDisplayName  # Use base display name for searching
        $allExistingApps = Get-IntuneWin32App | Where-Object { $_.displayName -like "$searchPattern*" }
        
        if ($allExistingApps) {
            Write-Host "  Found $($allExistingApps.Count) existing app(s) for '$AppName'" -ForegroundColor Yellow
            
            # Analyze all existing apps to find versions (always check all, don't rely on exact match)
            $oldVersionApps = @()
            $sameVersionExists = $false
            $newestOlderApp = $null
            $newestOlderVersion = $null
            
            foreach ($existingApp in $allExistingApps) {
                # Get version from displayVersion field or parse from display name
                $existingVersion = $null
                
                if ($existingApp.displayVersion) {
                    $existingVersion = $existingApp.displayVersion
                    Write-Host "    - $($existingApp.displayName) (v$existingVersion)" -ForegroundColor Gray
                }
                else {
                    # Try to extract version from display name
                    if ($existingApp.displayName -match '(\d+(?:\.\d+)*)') {
                        $existingVersion = $matches[1]
                        Write-Host "    - $($existingApp.displayName) (v$existingVersion extracted from name)" -ForegroundColor Gray
                    }
                    else {
                        Write-Host "    - $($existingApp.displayName) (version unknown - skipping)" -ForegroundColor Yellow
                        continue
                    }
                }
                
                try {
                    # Compare versions
                    $existingVer = [version]$existingVersion
                    $newVer = [version]$NewVersion
                    
                    if ($existingVer -lt $newVer) {
                        Write-Host "      -> Older version: $existingVersion < $NewVersion" -ForegroundColor Gray
                        
                        # Track only the newest older version for supersedence (creates proper chain)
                        if ($null -eq $newestOlderVersion -or $existingVer -gt $newestOlderVersion) {
                            $newestOlderApp = $existingApp
                            $newestOlderVersion = $existingVer
                        }
                    }
                    elseif ($existingVer -eq $newVer) {
                        Write-Host "      -> Same version ($existingVersion = $NewVersion)" -ForegroundColor Yellow
                        if (-not $ForceUpdate) {
                            $sameVersionExists = $true
                        }
                    }
                    else {
                        Write-Host "      -> Newer version exists ($existingVersion > $NewVersion)" -ForegroundColor Cyan
                    }
                }
                catch {
                    Write-Host "      Warning: Could not compare versions: $_" -ForegroundColor Yellow
                }
            }
            
            # Add only the newest older version for supersedence
            if ($null -ne $newestOlderApp) {
                Write-Host "  Will supersede most recent older version: $($newestOlderApp.displayName) v$($newestOlderApp.displayVersion)" -ForegroundColor Yellow
                $oldVersionApps = @($newestOlderApp)
            }
            
            # Skip if same version already exists (unless ForceUpdate)
            if ($sameVersionExists) {
                Write-Host "  Skipping: Version $NewVersion already exists in Intune (use -ForceUpdate to recreate)" -ForegroundColor Yellow
                $deployedApps += $AppName
                continue
            }
            
            if ($oldVersionApps.Count -gt 0) {
                Write-Host "  Creating new version with supersedence..." -ForegroundColor Cyan
            }
            else {
                Write-Host "  No older versions found - creating new app without supersedence" -ForegroundColor Gray
            }
        }
        else {
            Write-Host "  No existing apps found - creating new..." -ForegroundColor Cyan
        }
            
        # Create new app
        $appParams = @{
            FilePath             = $IntuneWinPath
            DisplayName          = $AppConfig.DisplayName
            Description          = $AppConfig.Description
            Publisher            = $AppConfig.Publisher
            AppVersion           = $AppConfig.AppVersion
            InstallExperience    = $AppConfig.InstallExperience
            RestartBehavior      = $AppConfig.RestartBehavior
            DetectionRule        = $AppConfig.DetectionRules
            RequirementRule      = $AppConfig.RequirementRule
            InstallCommandLine   = $AppConfig.InstallCommandLine
            UninstallCommandLine = $AppConfig.UninstallCommandLine
            Verbose              = $true
        }
            
        # Add icon if available (must be converted to base64)
        if ($IconPath -and (Test-Path $IconPath)) {
            Write-Host "  Adding app icon: $(Split-Path $IconPath -Leaf)" -ForegroundColor Gray
            try {
                $iconFile = New-IntuneWin32AppIcon -FilePath $IconPath
                $appParams.Icon = $iconFile
            }
            catch {
                Write-Host "  Warning: Failed to add icon: $_" -ForegroundColor Yellow
            }
        }
            
        # Upload app to Intune with error handling for Azure Storage failures
        $Win32App = $null
        try {
            $Win32App = Add-IntuneWin32App @appParams -ErrorAction Stop
                
            # Validate that the app was created successfully with a valid ID
            if (-not $Win32App -or -not $Win32App.id) {
                throw "App creation returned but no valid app ID was provided"
            }
                
            Write-Host "  Successfully created new app: $($AppConfig.DisplayName) v$($AppConfig.AppVersion)" -ForegroundColor Green
            Write-Host "    App ID: $($Win32App.id)" -ForegroundColor Gray
        }
        catch {
            Write-Host "  Warning: Upload encountered an error: $_" -ForegroundColor Yellow
                
            # Check if app was created in Intune despite the error
            Write-Host "  Checking if app was created in Intune..." -ForegroundColor Gray
            Start-Sleep -Seconds 10
                
            $createdApp = Get-IntuneWin32App -DisplayName $AppConfig.DisplayName -ErrorAction SilentlyContinue
            if ($createdApp -and $createdApp.id) {
                Write-Host "  Found created app in Intune (ID: $($createdApp.id))" -ForegroundColor Green
                $Win32App = $createdApp
            }
            else {
                throw "App creation failed and app not found in Intune: $_"
            }
        }
            
        # Final validation
        if (-not $Win32App -or -not $Win32App.id) {
            throw "No valid app object available for supersedence and assignment operations"
        }
                
        # Set up supersedence for older versions
        if ($oldVersionApps.Count -gt 0) {
            Write-Host "  Setting up supersedence relationships..." -ForegroundColor Cyan
                
            foreach ($oldApp in $oldVersionApps) {
                try {
                    Write-Host "    Superseding: $($oldApp.displayName) v$($oldApp.displayVersion)" -ForegroundColor Gray
                        
                    # Get supersedence type from app config (default to "Update" if not specified)
                    $supersedenceType = if ($AppConfig.SupersedenceType) { $AppConfig.SupersedenceType } else { "Update" }
                    Write-Host "      Supersedence type: $supersedenceType" -ForegroundColor Gray
                        
                    # Step 1: Create supersedence object
                    $supersedence = New-IntuneWin32AppSupersedence `
                        -ID $oldApp.id `
                        -SupersedenceType $supersedenceType
                        
                    # Step 2: Add supersedence to the new app
                    Add-IntuneWin32AppSupersedence `
                        -ID $Win32App.id `
                        -Supersedence $supersedence `
                        -Verbose
                        
                    Write-Host "    [OK] Supersedence configured (Update): $($oldApp.displayName) -> $($Win32App.displayName) v$($Win32App.displayVersion)" -ForegroundColor Green
                }
                catch {
                    Write-Host "    [Err] Failed to set supersedence for $($oldApp.displayName): $_" -ForegroundColor Red
                }
            }
        }
        
        # Set up dependencies
        if ($AppConfig.Dependencies -and $AppConfig.Dependencies.Count -gt 0) {
            Write-Host "  Setting up dependency relationships..." -ForegroundColor Cyan
            $dependencyObjects = @()
            $allIntuneApps = Get-IntuneWin32App
            
            foreach ($depName in $AppConfig.Dependencies) {
                try {
                    Write-Host "    Resolving dependency: $depName" -ForegroundColor Gray
                    
                    # Get the dependency's config to find its display name pattern
                    $depConfig = Get-AppConfiguration -AppName $depName
                    if (-not $depConfig) {
                        Write-Host "    [Err] Dependency '$depName' not found in AppConfig" -ForegroundColor Red
                        continue
                    }
                    
                    # Search Intune for the dependency app by base display name
                    $depBaseName = $depConfig.DisplayNameTemplate -replace '\s*\{0\}', ''
                    $depIntuneApp = $allIntuneApps | Where-Object { $_.displayName -like "$depBaseName*" } | Sort-Object -Property createdDateTime -Descending | Select-Object -First 1
                    
                    # Auto-deploy dependency if not found in Intune
                    if (-not $depIntuneApp) {
                        Write-Host "    Dependency '$depName' not found in Intune, auto-deploying..." -ForegroundColor Yellow
                        
                        # Find the dependency's app entry in $appsToDeploy
                        $depAppEntry = $script:appsToDeploy | Where-Object { $_.AppConfigName -eq $depName }
                        if (-not $depAppEntry) {
                            Write-Host "    [Err] Dependency '$depName' not found in appsToDeploy" -ForegroundColor Red
                            continue
                        }
                        
                        $depFolder = Join-Path (Join-Path $BaseDir "packages") $depAppEntry.Folder
                        $depIntunewinFiles = Get-ChildItem -Path $depFolder -File |
                            Where-Object { $_.Name -like $depAppEntry.Pattern -and $_.Extension -eq ".intunewin" } |
                            Sort-Object LastWriteTime -Descending
                        
                        if ($depIntunewinFiles.Count -eq 0) {
                            Write-Host "    [Err] No .intunewin package found for dependency '$depName'" -ForegroundColor Red
                            Write-Host "    Run: .\Download-And-Package-Software.ps1 -AppName $depName" -ForegroundColor Yellow
                            continue
                        }
                        
                        $depIntunewinFile = $depIntunewinFiles[0]
                        $depVersion = "1.0"
                        if ($depIntunewinFile.BaseName -match '(\d+\.[\d\.]+)') {
                            $depVersion = $matches[1].TrimEnd('.')
                        }
                        
                        $depMetaData = Get-IntuneWin32AppMetaData -FilePath $depIntunewinFile.FullName
                        $depSetupFile = $depMetaData.ApplicationInfo.SetupFile
                        
                        # Build config for the dependency
                        if ($depAppEntry.PackageType -eq "MSI") {
                            $depAppConfig = Get-MsiAppConfig -AppName $depName -Version $depVersion -SetupFile $depSetupFile -IntuneWinPath $depIntunewinFile.FullName
                        }
                        else {
                            $depAppConfig = Get-FileAppConfig -AppName $depName -Version $depVersion -SetupFile $depSetupFile
                        }
                        
                        # Build upload params (no assignment)
                        $depAppParams = @{
                            FilePath             = $depIntunewinFile.FullName
                            DisplayName          = $depAppConfig.DisplayName
                            Description          = $depAppConfig.Description
                            Publisher            = $depAppConfig.Publisher
                            AppVersion           = $depAppConfig.AppVersion
                            InstallExperience    = $depAppConfig.InstallExperience
                            RestartBehavior      = $depAppConfig.RestartBehavior
                            DetectionRule        = $depAppConfig.DetectionRules
                            RequirementRule      = $depAppConfig.RequirementRule
                            InstallCommandLine   = $depAppConfig.InstallCommandLine
                            UninstallCommandLine = $depAppConfig.UninstallCommandLine
                            Verbose              = $true
                        }
                        
                        # Add icon if available
                        $depIconPath = Join-Path $depFolder $depConfig.IconFile
                        if ($depConfig.IconFile -and (Test-Path $depIconPath)) {
                            try {
                                $depAppParams.Icon = New-IntuneWin32AppIcon -FilePath $depIconPath
                            }
                            catch { }
                        }
                        
                        $depIntuneApp = Add-IntuneWin32App @depAppParams -ErrorAction Stop
                        Write-Host "    Auto-deployed '$depName' to Intune (ID: $($depIntuneApp.id))" -ForegroundColor Green
                    }
                    
                    # Collect dependency object for batch linking
                    $dependency = New-IntuneWin32AppDependency `
                        -ID $depIntuneApp.id `
                        -DependencyType "AutoInstall"
                    $dependencyObjects += $dependency
                    Write-Host "    [OK] Resolved: $($depIntuneApp.displayName)" -ForegroundColor Green
                }
                catch {
                    Write-Host "    [Err] Failed to resolve dependency '$depName': $_" -ForegroundColor Red
                }
            }
            
            # Link all dependencies in a single call
            if ($dependencyObjects.Count -gt 0) {
                try {
                    Add-IntuneWin32AppDependency `
                        -ID $Win32App.id `
                        -Dependency $dependencyObjects `
                        -Verbose
                    Write-Host "  Dependencies linked ($($dependencyObjects.Count))" -ForegroundColor Green
                }
                catch {
                    Write-Host "  [Err] Failed to link dependencies: $_" -ForegroundColor Red
                }
            }
        }
        
        # Assign if requested and collect assignment IDs for auto-update
        $assignmentIds = @()
        
        # Skip assignments for apps marked as hidden (dependency-only apps)
        if ($AppConfig.HideFromPortal -eq $true) {
            Write-Host "  Skipping assignments (HideFromPortal = true)" -ForegroundColor Gray
        }
        else {
            if ($AssignToAllUsers) {
                Write-Host "  Assigning to All Users..." -ForegroundColor Cyan
                $assignment = Add-IntuneWin32AppAssignmentAllUsers -ID $Win32App.id -Intent "available" -Notification "showAll"
                if ($assignment -and $assignment.id) {
                    $assignmentIds += $assignment.id
                }
                Write-Host "  Assigned to All Users" -ForegroundColor Green
            }
            
            if ($AssignToAllDevices) {
                Write-Host "  Assigning to All Devices..." -ForegroundColor Cyan
                Add-IntuneWin32AppAssignmentAllDevices -ID $Win32App.id -Intent "required" -Notification "showAll"
                Write-Host "  Assigned to All Devices" -ForegroundColor Green
            }
            
            if ($AssignToGroupName) {
            Write-Host "  Assigning to group: $AssignToGroupName..." -ForegroundColor Cyan
            
            try {
                # Ensure Microsoft.Graph.Groups module is available
                if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
                    Write-Host "  Installing Microsoft.Graph.Groups module..." -ForegroundColor Yellow
                    Install-Module -Name Microsoft.Graph.Groups -Scope CurrentUser -Force -AllowClobber
                }
                Import-Module Microsoft.Graph.Groups -ErrorAction Stop
                
                # Ensure connection is still valid
                if (-not (Test-IntuneConnection)) {
                    Write-Warning "  Connection lost, group assignment will be skipped"
                    continue
                }
                
                # Query Azure AD group by display name
                $group = Get-MgGroup -Filter "displayName eq '$AssignToGroupName'" -ErrorAction Stop
                
                if ($group) {
                    if ($group -is [array] -and $group.Count -gt 1) {
                        Write-Host "  Warning: Multiple groups found with name '$AssignToGroupName', using first match" -ForegroundColor Yellow
                        $group = $group[0]
                    }
                    
                    $intent = $GroupAssignmentIntent.ToLower()
                    Add-IntuneWin32AppAssignmentGroup -Include -ID $Win32App.id -GroupID $group.Id -Intent $intent -Notification "showAll"
                    Write-Host "  Assigned to group '$AssignToGroupName' (ID: $($group.Id)) as $GroupAssignmentIntent" -ForegroundColor Green
                }
                else {
                    Write-Host "  Warning: Group '$AssignToGroupName' not found" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "  Warning: Failed to assign to group '$AssignToGroupName': $_" -ForegroundColor Yellow
                Write-Host "  Error details: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        }  # end else (not HideFromPortal)
        
        # Enable auto-update for assignments if supersedence was configured and AutoUpdate is enabled
        if ($oldVersionApps.Count -gt 0 -and $assignmentIds.Count -gt 0 -and $AppConfig.AutoUpdate -eq $true) {
            Write-Host "  Enabling auto-update for app assignments..." -ForegroundColor Cyan
            try {
                # Ensure connection is still valid
                if (-not (Test-IntuneConnection)) {
                    Write-Warning "  Connection lost, auto-update will be skipped"
                }
                else {
                    $updatedCount = 0
                    foreach ($assignmentId in $assignmentIds) {
                        $result = Enable-IntuneAppAutoUpdate -AppId $Win32App.id -AssignmentId $assignmentId
                        $updatedCount += [int]$result
                    }
                    
                    if ($updatedCount -gt 0) {
                        Write-Host "  Auto-update enabled for $updatedCount assignment(s)" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  No assignments were updated with auto-update" -ForegroundColor Yellow
                    }
                }
            }
            catch {
                Write-Host "  Warning: Failed to enable auto-update: $_" -ForegroundColor Yellow
            }
        }
        elseif ($oldVersionApps.Count -gt 0 -and $assignmentIds.Count -gt 0) {
            Write-Host "  Skipping auto-update for assignments (AutoUpdate is disabled for this app)" -ForegroundColor Gray
        }
        
        return $Win32App
    }
    catch {
        Write-Host "  Failed to deploy app: $_" -ForegroundColor Red
        Write-Host "  Error details: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Main execution
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Intune Win32 App Deployment Automation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($ForceUpdate) {
    Write-Host "Mode: FORCE UPDATE (will create new versions of existing apps)" -ForegroundColor Yellow
    Write-Host "Note: You may need to manually set up supersedence relationships in Intune portal" -ForegroundColor Yellow
}
else {
    Write-Host "Mode: SAFE (will skip apps that already exist)" -ForegroundColor Green
    Write-Host "Tip: Use -ForceUpdate to create new versions for updates" -ForegroundColor Gray
}
Write-Host ""

# Check and install modules
if (-not (Install-RequiredModules)) {
    Write-Host "`nCannot proceed without required modules." -ForegroundColor Red
    Write-Host "Run the script without -SkipInstallation to install them automatically." -ForegroundColor Yellow
    exit 1
}

# Authenticate to Microsoft Intune
Write-Host "`nConnecting to Microsoft Intune..." -ForegroundColor Cyan
Write-Host "Tenant ID: $TenantId" -ForegroundColor Gray

if (-not $ClientId -or -not $ClientSecret) {
    Write-Host "Error: ClientId and ClientSecret are required for authentication" -ForegroundColor Red
    Write-Host "Usage: .\Deploy-ToIntune.ps1 -TenantId <tenant> -ClientId <id> -ClientSecret <secret>" -ForegroundColor Yellow
    exit 1
}

Write-Host "Using app-based authentication (Client ID: $ClientId)" -ForegroundColor Gray

if (-not (Initialize-IntuneAuthentication -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret)) {
    Write-Host "`nAuthentication failed. Exiting." -ForegroundColor Red
    exit 1
}

Write-Host "Successfully connected to Microsoft Intune!" -ForegroundColor Green

# Build apps to deploy dynamically from AppConfig.ps1 (single source of truth)
$script:appsToDeploy = @()
foreach ($appConfigName in (Get-AllAppNames)) {
    $cfg = Get-AppConfiguration -AppName $appConfigName
    if ($cfg -and $cfg.Folder -and $cfg.IntuneWinPattern) {
        $displayName = $cfg.DisplayNameTemplate -replace '\s*\{0\}', ''
        $script:appsToDeploy += @{
            Name = $displayName.Trim()
            Folder = $cfg.Folder
            Pattern = $cfg.IntuneWinPattern
            AppConfigName = $appConfigName
            PackageType = $cfg.PackageType
        }
    }
}

# Filter apps if AppName parameter is specified
$appsToProcess = $script:appsToDeploy
if ($AppName) {
    $filteredApp = $script:appsToDeploy | Where-Object { $_.AppConfigName -eq $AppName }
    if (-not $filteredApp) {
        Write-Host "Error: App '$AppName' not found in deployment configuration" -ForegroundColor Red
        Write-Host "Available apps: $($script:appsToDeploy.AppConfigName -join ', ')" -ForegroundColor Yellow
        exit 1
    }
    $appsToProcess = @($filteredApp)
    Write-Host "Processing single app: $AppName" -ForegroundColor Yellow
    Write-Host ""
}

$deployedApps = @()
$failedApps = @()

foreach ($app in $appsToProcess) {
    # Validate connection before each app deployment
    if (-not (Test-IntuneConnection)) {
        Write-Host "`n  Connection lost, attempting to reconnect..." -ForegroundColor Yellow
        if (-not (Initialize-IntuneAuthentication -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret)) {
            Write-Host "  Reconnection failed, skipping remaining apps" -ForegroundColor Red
            break
        }
        Write-Host "  Reconnected successfully!" -ForegroundColor Green
    }
    
    Write-Host "`n[Deploying $($app.Name)]" -ForegroundColor Magenta
    
    $appFolder = Join-Path (Join-Path $BaseDir "packages") $app.Folder
    if (-not (Test-Path $appFolder)) {
        Write-Host "  Folder not found: $appFolder" -ForegroundColor Red
        $failedApps += $app.Name
        continue
    }
    
    # Find the latest intunewin package
    Write-Host "  Looking for pattern: $($app.Pattern)" -ForegroundColor Gray
    $intunewinFiles = Get-ChildItem -Path $appFolder -File | 
    Where-Object { $_.Name -like $app.Pattern -and $_.Extension -eq ".intunewin" } | 
    Sort-Object LastWriteTime -Descending
    
    if ($intunewinFiles.Count -eq 0) {
        Write-Host "  No IntuneWin package found matching pattern: $($app.Pattern)" -ForegroundColor Red
        Write-Host "  Files in folder:" -ForegroundColor Gray
        Get-ChildItem -Path $appFolder -File | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor Gray }
        $failedApps += $app.Name
        continue
    }
    
    Write-Host "  Found $($intunewinFiles.Count) matching package(s)" -ForegroundColor Gray
    
    $intunewinFile = $intunewinFiles[0]
    Write-Host "  Package: $($intunewinFile.Name)" -ForegroundColor Cyan
    
    # Extract version from filename
    $version = "Latest"
    if ($intunewinFile.BaseName -match '(\d+\.[\d\.]+)') {
        $version = $matches[1].TrimEnd('.')  # Remove trailing dot if present
    }
    Write-Host "  Version: $version" -ForegroundColor Cyan
    
    # Get the original setup file name from .intunewin metadata (preserves .exe/.msi extension)
    Write-Host "  Reading package metadata..." -ForegroundColor Gray
    $IntuneWinMetaData = Get-IntuneWin32AppMetaData -FilePath $intunewinFile.FullName
    $setupFileName = $IntuneWinMetaData.ApplicationInfo.SetupFile
    Write-Host "  Setup file: $setupFileName" -ForegroundColor Gray
    
    # Get app configuration using the appropriate generic function
    $appConfigFromFile = Get-AppConfiguration -AppName $app.AppConfigName
    
    # Check if this app uses script-based detection (like GeoGebra)
    if ($appConfigFromFile.DetectionType -eq "Script") {
        Write-Host "  Using script-based detection..." -ForegroundColor Gray
        $appConfig = Get-ScriptAppConfig -AppName $app.AppConfigName -Version $version -SetupFile $setupFileName -IntuneWinPath $intunewinFile.FullName
    }
    elseif ($app.PackageType -eq "MSI") {
        $appConfig = Get-MsiAppConfig -AppName $app.AppConfigName -Version $version -SetupFile $setupFileName -IntuneWinPath $intunewinFile.FullName
    }
    else {
        # For EXE files, try to get the actual file version if detection is "equal"
        if ($appConfigFromFile.DetectionOperator -eq "equal") {
            # Find the actual setup file in the folder to get its real version
            $actualSetupFile = Get-ChildItem -Path $appFolder -File | Where-Object { $_.Name -eq $setupFileName } | Select-Object -First 1
            if ($actualSetupFile) {
                try {
                    $fileVersion = (Get-Item $actualSetupFile.FullName).VersionInfo.FileVersion
                    if ($fileVersion) {
                        # Trim any whitespace from the version string
                        $fileVersion = $fileVersion.Trim()
                        Write-Host "  Detected file version: $fileVersion" -ForegroundColor Gray
                        $version = $fileVersion
                    }
                }
                catch {
                    Write-Host "  Warning: Could not read file version, using filename version" -ForegroundColor Yellow
                }
            }
        }
        $appConfig = Get-FileAppConfig -AppName $app.AppConfigName -Version $version -SetupFile $setupFileName
    }
    
    # Check for icon file
    $iconPath = $null
    $appConfigFromFile = Get-AppConfiguration -AppName $app.AppConfigName
    if ($appConfigFromFile.IconFile) {
        $possibleIconPath = Join-Path $appFolder $appConfigFromFile.IconFile
        if (Test-Path $possibleIconPath) {
            $iconPath = $possibleIconPath
        }
        else {
            Write-Host "  Icon file not found: $($appConfigFromFile.IconFile)" -ForegroundColor Yellow
        }
    }
    
    # Add SupersedenceType to appConfig if specified in config file
    if ($appConfigFromFile.SupersedenceType) {
        $appConfig.SupersedenceType = $appConfigFromFile.SupersedenceType
    }
    
    # Forward AutoUpdate flag ($false is falsy, so use ContainsKey to forward both $true and $false)
    if ($appConfigFromFile.ContainsKey('AutoUpdate')) {
        $appConfig.AutoUpdate = $appConfigFromFile.AutoUpdate
    }
    
    # Forward Dependencies array
    if ($appConfigFromFile.Dependencies) {
        $appConfig.Dependencies = $appConfigFromFile.Dependencies
    }
    
    # Forward HideFromPortal flag
    if ($appConfigFromFile.HideFromPortal -eq $true) {
        $appConfig.HideFromPortal = $true
    }
    
    # Deploy the app with version info for supersedence
    $result = Publish-App `
        -AppName $app.Name `
        -IntuneWinPath $intunewinFile.FullName `
        -SetupFileName $setupFileName `
        -AppConfig $appConfig `
        -NewVersion $version `
        -IconPath $iconPath `
        -ForceUpdate:$ForceUpdate
    
    if ($result) {
        $deployedApps += $app.Name
    }
    else {
        $failedApps += $app.Name
    }
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Successfully deployed: $($deployedApps.Count)" -ForegroundColor Green
foreach ($app in $deployedApps) {
    Write-Host "  [OK] $app" -ForegroundColor Green
}

if ($failedApps.Count -gt 0) {
    Write-Host "`nFailed to deploy: $($failedApps.Count)" -ForegroundColor Red
    foreach ($app in $failedApps) {
        Write-Host "  [FAILED] $app" -ForegroundColor Red
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "Check the Intune portal to verify deployments" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan

# Clean up connection
Write-Host "`nDisconnecting from Microsoft Graph..." -ForegroundColor Gray
Disconnect-IntuneSession -Force
