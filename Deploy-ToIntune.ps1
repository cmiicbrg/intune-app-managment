# Complete Intune Win32 App Deployment Script
# Uses IntuneWin32App module for proper deployment
# Author: GitHub Copilot
# Date: October 10, 2025

<#
.SYNOPSIS
    Deploys Win32 applications to Microsoft Intune using IntuneWin32App module

.DESCRIPTION
    This script automatically deploys all IntuneWin packages to Microsoft Intune.
    It uses the IntuneWin32App PowerShell module for proper Win32 app management.

.PARAMETER AppName
    Optional. If specified, only deploys the specified app from AppConfig (e.g., "Firefox", "Chrome")

.PARAMETER AssignToAllUsers
    If specified, assigns the app to "All Users" group

.PARAMETER AssignToAllDevices
    If specified, assigns the app to "All Devices" group

.PARAMETER ForceUpdate
    If specified, creates new versions even if apps already exist (for updates/supersedence)

.EXAMPLE
    .\Deploy-ToIntune.ps1 -AssignToAllUsers

.EXAMPLE
    .\Deploy-ToIntune.ps1 -AppName "Firefox" -AssignToAllUsers

.EXAMPLE
    .\Deploy-ToIntune.ps1 -ForceUpdate -AssignToAllDevices

.NOTES
    Prerequisites:
    1. Install-Module -Name IntuneWin32App
    2. Appropriate Intune permissions (Intune Administrator or Global Administrator)
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$AppName,
    
    [Parameter(Mandatory=$false)]
    [switch]$AssignToAllUsers,
    
    [Parameter(Mandatory=$false)]
    [switch]$AssignToAllDevices,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipInstallation,
    
    [Parameter(Mandatory=$false)]
    [switch]$ForceUpdate,
    
    [Parameter(Mandatory=$false)]
    [string]$TenantId = "common",
    
    [Parameter(Mandatory=$false)]
    [string]$ClientId,
    
    [Parameter(Mandatory=$false)]
    [string]$ClientSecret
)

$ErrorActionPreference = "Stop"
$BaseDir = $PSScriptRoot

# Import shared functions and configuration
. (Join-Path $PSScriptRoot "SharedFunctions.ps1")

# Check and install IntuneWin32App module
function Install-RequiredModules {
    Write-Host "Checking required modules..." -ForegroundColor Cyan
    
    $requiredModules = @(
        "IntuneWin32App",
        "Microsoft.Graph.Authentication"
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

# Connect to Microsoft Graph
function Connect-ToIntune {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    
    Write-Host "`nConnecting to Microsoft Intune..." -ForegroundColor Cyan
    Write-Host "Tenant ID: $TenantId" -ForegroundColor Gray
    
    try {
        if ($ClientId -and $ClientSecret) {
            # App-based authentication
            Write-Host "Using app-based authentication (Client ID: $ClientId)" -ForegroundColor Gray
            Connect-MSIntuneGraph -TenantID $TenantId -ClientID $ClientId -ClientSecret $ClientSecret
        }
        else {
            # Interactive authentication
            Write-Host "Using interactive authentication" -ForegroundColor Gray
            Write-Host "Please enter your tenant ID (or press Enter to use 'common' for multi-tenant):" -ForegroundColor Yellow
            $interactiveTenantId = Read-Host "Tenant ID"
            if ([string]::IsNullOrWhiteSpace($interactiveTenantId)) {
                $interactiveTenantId = "common"
            }
            Write-Host "A browser window will open for authentication..." -ForegroundColor Yellow
            Connect-MSIntuneGraph -TenantID $interactiveTenantId
        }
        Write-Host "Successfully connected to Microsoft Intune!" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to connect: $_" -ForegroundColor Red
        return $false
    }
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
            
            # Check for exact match with current display name
            $exactMatch = $allExistingApps | Where-Object { $_.displayName -eq $AppConfig.DisplayName }
            
            if ($exactMatch) {
                # Check if it's the same version using displayVersion property
                if ($exactMatch.displayVersion -eq $AppConfig.AppVersion -and -not $ForceUpdate) {
                    Write-Host "  Exact version match found: $($exactMatch.displayName) v$($exactMatch.displayVersion)" -ForegroundColor Yellow
                    Write-Host "  Skipping - app already exists (use -ForceUpdate to recreate)" -ForegroundColor Yellow
                    return $exactMatch
                }
                else {
                    # Same display name but different version - this is an update
                    Write-Host "  Existing app: $($exactMatch.displayName) v$($exactMatch.displayVersion)" -ForegroundColor Yellow
                    Write-Host "  New version: v$($AppConfig.AppVersion)" -ForegroundColor Cyan
                    
                    try {
                        if ([version]$AppConfig.AppVersion -gt [version]$exactMatch.displayVersion) {
                            Write-Host "  Creating newer version with supersedence..." -ForegroundColor Cyan
                            $oldVersionApps = @($exactMatch)
                        }
                        else {
                            Write-Host "  Version $($AppConfig.AppVersion) is not newer than existing $($exactMatch.displayVersion), skipping" -ForegroundColor Yellow
                            return $exactMatch
                        }
                    }
                    catch {
                        Write-Host "  Warning: Could not compare versions, will create anyway" -ForegroundColor Yellow
                        $oldVersionApps = @($exactMatch)
                    }
                }
            }
            else {
                # No exact display name match, but similar apps found - check for older versions
                Write-Host "  No exact match for display name, analyzing versions for supersedence..." -ForegroundColor Gray
                $oldVersionApps = @()
                $sameVersionExists = $false
                
                foreach ($existingApp in $allExistingApps) {
                    # Get version from displayVersion field or parse from display name
                    $existingVersion = $null
                    
                    if ($existingApp.displayVersion) {
                        $existingVersion = $existingApp.displayVersion
                        Write-Host "    - $($existingApp.displayName) (v$existingVersion from displayVersion)" -ForegroundColor Gray
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
                            Write-Host "      -> Will supersede (older: $existingVersion < $NewVersion)" -ForegroundColor Yellow
                            $oldVersionApps += $existingApp
                        }
                        elseif ($existingVer -eq $newVer) {
                            Write-Host "      -> Same version ($existingVersion = $NewVersion) - will skip creation" -ForegroundColor Yellow
                            $sameVersionExists = $true
                        }
                        else {
                            Write-Host "      -> Newer version exists ($existingVersion > $NewVersion)" -ForegroundColor Cyan
                        }
                    }
                    catch {
                        Write-Host "      Warning: Could not compare versions: $_" -ForegroundColor Yellow
                    }
                }
                
                # Skip if same version already exists
                if ($sameVersionExists) {
                    Write-Host "  Skipping: Version $NewVersion already exists in Intune" -ForegroundColor Yellow
                    $deployedApps += $AppName
                    continue
                }
                
                if ($oldVersionApps.Count -gt 0) {
                    Write-Host "  Creating new version with supersedence for $($oldVersionApps.Count) older app(s)..." -ForegroundColor Cyan
                }
                else {
                    Write-Host "  No older versions found - creating new app without supersedence" -ForegroundColor Gray
                }
            }
            
            # Create new app
            $appParams = @{
                FilePath = $IntuneWinPath
                DisplayName = $AppConfig.DisplayName
                Description = $AppConfig.Description
                Publisher = $AppConfig.Publisher
                AppVersion = $AppConfig.AppVersion
                InstallExperience = $AppConfig.InstallExperience
                RestartBehavior = $AppConfig.RestartBehavior
                DetectionRule = $AppConfig.DetectionRules
                RequirementRule = $AppConfig.RequirementRule
                InstallCommandLine = $AppConfig.InstallCommandLine
                UninstallCommandLine = $AppConfig.UninstallCommandLine
                Verbose = $true
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
                        
                        # Step 1: Create supersedence object (Update type, no uninstall)
                        $supersedence = New-IntuneWin32AppSupersedence `
                            -ID $oldApp.id `
                            -SupersedenceType "Update"
                        
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
        }
        else {
            Write-Host "  No existing apps found - creating new..." -ForegroundColor Cyan
            # Create the Win32 app
            $appParams = @{
                FilePath = $IntuneWinPath
                DisplayName = $AppConfig.DisplayName
                Description = $AppConfig.Description
                Publisher = $AppConfig.Publisher
                AppVersion = $AppConfig.AppVersion
                InstallExperience = $AppConfig.InstallExperience
                RestartBehavior = $AppConfig.RestartBehavior
                DetectionRule = $AppConfig.DetectionRules
                RequirementRule = $AppConfig.RequirementRule
                InstallCommandLine = $AppConfig.InstallCommandLine
                UninstallCommandLine = $AppConfig.UninstallCommandLine
                Verbose = $true
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
            
            # Upload app to Intune with error handling
            $Win32App = $null
            try {
                $Win32App = Add-IntuneWin32App @appParams -ErrorAction Stop
                
                if (-not $Win32App -or -not $Win32App.id) {
                    throw "App creation returned but no valid app ID was provided"
                }
                
                Write-Host "  Successfully created app: $($AppConfig.DisplayName) v$($AppConfig.AppVersion)" -ForegroundColor Green
                Write-Host "    App ID: $($Win32App.id)" -ForegroundColor Gray
            }
            catch {
                Write-Host "  Warning: Upload encountered an error: $_" -ForegroundColor Yellow
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
            
            if (-not $Win32App -or -not $Win32App.id) {
                throw "No valid app object available for assignment operations"
            }
        }
        
        # Assign if requested
        if ($AssignToAllUsers) {
            Write-Host "  Assigning to All Users..." -ForegroundColor Cyan
            Add-IntuneWin32AppAssignmentAllUsers -ID $Win32App.id -Intent "available" -Notification "showAll"
            Write-Host "  Assigned to All Users" -ForegroundColor Green
        }
        
        if ($AssignToAllDevices) {
            Write-Host "  Assigning to All Devices..." -ForegroundColor Cyan
            Add-IntuneWin32AppAssignmentAllDevices -ID $Win32App.id -Intent "required" -Notification "showAll"
            Write-Host "  Assigned to All Devices" -ForegroundColor Green
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

# Connect to Intune
if (-not (Connect-ToIntune -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret)) {
    Write-Host "`nFailed to connect to Intune. Exiting." -ForegroundColor Red
    exit 1
}

# Define apps to deploy
$appsToDeploy = @(
    @{Name="Firefox"; Folder="firefox"; Pattern="Firefox-Setup-*-de.intunewin"; AppConfigName="Firefox"; PackageType="EXE"},
    @{Name="Chrome"; Folder="chrome"; Pattern="GoogleChrome-*-Enterprise-x64.intunewin"; AppConfigName="Chrome"; PackageType="MSI"},
    @{Name="7-Zip"; Folder="7zip"; Pattern="7z*-x64.intunewin"; AppConfigName="SevenZip"; PackageType="MSI"},
    @{Name="GIMP"; Folder="gimp"; Pattern="gimp-*-setup*.intunewin"; AppConfigName="GIMP"; PackageType="EXE"},
    @{Name="VLC"; Folder="vlc"; Pattern="vlc-*-win64.intunewin"; AppConfigName="VLC"; PackageType="EXE"},
    @{Name="Notepad++"; Folder="npp"; Pattern="npp.*Installer.x64.intunewin"; AppConfigName="NotepadPlusPlus"; PackageType="EXE"},
    @{Name="Affinity Studio"; Folder="affinity"; Pattern="Affinity*.intunewin"; AppConfigName="AffinityStudio"; PackageType="MSI"},
    @{Name="Inkscape"; Folder="inkscape"; Pattern="inkscape-*.intunewin"; AppConfigName="Inkscape"; PackageType="MSI"},
    @{Name="Audacity"; Folder="audacity"; Pattern="audacity-*.intunewin"; AppConfigName="Audacity"; PackageType="EXE"},
    @{Name="LibreOffice"; Folder="libreoffice"; Pattern="LibreOffice_*.intunewin"; AppConfigName="LibreOffice"; PackageType="MSI"},
    @{Name="OpenShot"; Folder="openshot"; Pattern="OpenShot-v*-x86_64.intunewin"; AppConfigName="OpenShot"; PackageType="EXE"},
    @{Name="GeoGebra"; Folder="geogebra"; Pattern="GeoGebra-Windows-Installer-6-*.intunewin"; AppConfigName="GeoGebra"; PackageType="MSI"}
)

# Filter apps if AppName parameter is specified
if ($AppName) {
    $filteredApp = $appsToDeploy | Where-Object { $_.AppConfigName -eq $AppName }
    if (-not $filteredApp) {
        Write-Host "Error: App '$AppName' not found in deployment configuration" -ForegroundColor Red
        Write-Host "Available apps: $($appsToDeploy.AppConfigName -join ', ')" -ForegroundColor Yellow
        exit 1
    }
    $appsToDeploy = @($filteredApp)
    Write-Host "Processing single app: $AppName" -ForegroundColor Yellow
    Write-Host ""
}

$deployedApps = @()
$failedApps = @()

foreach ($app in $appsToDeploy) {
    # Validate token before each app deployment (tokens can expire)
    try {
        $null = Get-IntuneWin32App -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        if ($_.Exception.Message -like "*token*expired*" -or $_.Exception.Message -like "*authentication*") {
            Write-Host "`n  Token expired, reconnecting..." -ForegroundColor Yellow
            if ($ClientId -and $ClientSecret) {
                Connect-MSIntuneGraph -TenantID $TenantId -ClientID $ClientId -ClientSecret $ClientSecret
            }
            else {
                Write-Host "  Interactive re-authentication required" -ForegroundColor Yellow
                $interactiveTenantId = Read-Host "Tenant ID"
                if ([string]::IsNullOrWhiteSpace($interactiveTenantId)) {
                    $interactiveTenantId = "common"
                }
                Connect-MSIntuneGraph -TenantID $interactiveTenantId
            }
            Write-Host "  Reconnected successfully!" -ForegroundColor Green
        }
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
    if ($app.PackageType -eq "MSI") {
        $appConfig = Get-MsiAppConfig -AppName $app.AppConfigName -Version $version -SetupFile $setupFileName -IntuneWinPath $intunewinFile.FullName
    }
    else {
        # For EXE files, try to get the actual file version if detection is "equal"
        $appConfigFromFile = Get-AppConfiguration -AppName $app.AppConfigName
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
