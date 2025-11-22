# Shared Functions Module
# Common functions used by both Download-And-Package-Software.ps1 and Deploy-ToIntune.ps1
# Author: GitHub Copilot
# Date: October 11, 2025

# Import configuration
. (Join-Path $PSScriptRoot "AppConfig.ps1")

# Function to check if version already exists
function Test-VersionExists {
    param(
        [string]$AppFolder,
        [string]$NewVersion,
        [string]$Pattern = "*.intunewin"
    )
    
    if (-not (Test-Path $AppFolder)) {
        return $false
    }
    
    $existingPackages = Get-ChildItem -Path $AppFolder -Filter $Pattern -ErrorAction SilentlyContinue
    
    if (-not $existingPackages) {
        return $false
    }
    
    # Extract versions from existing packages
    foreach ($package in $existingPackages) {
        if ($package.BaseName -match '(\d+\.[\d\.]+)') {
            $existingVersion = $matches[1].TrimEnd('.')
            
            # Compare versions
            try {
                $newVer = [version]$NewVersion
                $existVer = [version]$existingVersion
                
                if ($existVer -ge $newVer) {
                    Write-Host "  Existing version $existingVersion is up to date (>= $NewVersion)" -ForegroundColor Green
                    return $true
                }
            }
            catch {
                # If version comparison fails, do string comparison
                if ($existingVersion -eq $NewVersion) {
                    Write-Host "  Existing version $existingVersion matches $NewVersion" -ForegroundColor Green
                    return $true
                }
            }
        }
    }
    
    return $false
}

# Function to download file with progress
function Invoke-FileDownload {
    param(
        [string]$Url,
        [string]$OutputPath
    )
    
    Write-Host "Downloading from: $Url" -ForegroundColor Cyan
    Write-Host "To: $(Split-Path $OutputPath)" -ForegroundColor Cyan
    
    try {
        # Use Invoke-WebRequest for better compatibility with modern websites
        # Set TLS version for secure connections
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        
        # Download with progress
        $ProgressPreference = 'SilentlyContinue'  # Speeds up download
        Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = 'Continue'
        
        Write-Host "Download completed successfully!" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Download failed: $_" -ForegroundColor Red
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            Write-Host "HTTP Status: $($_.Exception.Response.StatusCode.value__) $($_.Exception.Response.StatusDescription)" -ForegroundColor Red
        }
        return $false
    }
}

# Function to create IntuneWin package
function New-IntuneWinPackage {
    param(
        [string]$SourceFolder,
        [string]$SetupFile,
        [string]$OutputFolder
    )
    
    $IntuneWinUtil = Join-Path $PSScriptRoot "IntuneWinAppUtil.exe"
    
    Write-Host "`nCreating IntuneWin package..." -ForegroundColor Yellow
    Write-Host "Source: $SourceFolder" -ForegroundColor Gray
    Write-Host "Setup File: $SetupFile" -ForegroundColor Gray
    Write-Host "Output: $OutputFolder" -ForegroundColor Gray
    
    $arguments = @(
        "-c", "`"$SourceFolder`"",
        "-s", "`"$SetupFile`"",
        "-o", "`"$OutputFolder`"",
        "-q"
    )
    
    & $IntuneWinUtil $arguments
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "IntuneWin package created successfully!" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "Failed to create IntuneWin package. Exit code: $LASTEXITCODE" -ForegroundColor Red
        return $false
    }
}

# Function to clean up old app files before packaging
function Remove-OldAppFiles {
    param(
        [Parameter(Mandatory=$true)]
        [string]$AppFolder,
        
        [Parameter(Mandatory=$true)]
        [string]$KeepFileName
    )
    
    try {
        Write-Host "  Cleaning up old files..." -ForegroundColor Gray
        
        # Remove all .intunewin files
        $oldIntuneWin = Get-ChildItem -Path $AppFolder -Filter "*.intunewin" -ErrorAction SilentlyContinue
        if ($oldIntuneWin) {
            $oldIntuneWin | Remove-Item -Force
            Write-Host "    Removed $($oldIntuneWin.Count) old .intunewin file(s)" -ForegroundColor Gray
        }
        
        # Remove old installer files (keep only the new one)
        $oldInstallers = Get-ChildItem -Path $AppFolder -File | 
            Where-Object { 
                $_.Name -ne $KeepFileName -and 
                $_.Extension -in @('.exe', '.msi')
            }
        
        if ($oldInstallers) {
            foreach ($file in $oldInstallers) {
                Write-Host "    Removing: $($file.Name)" -ForegroundColor Gray
                Remove-Item $file.FullName -Force
            }
        }
        
        return $true
    }
    catch {
        Write-Host "    Warning: Cleanup failed: $_" -ForegroundColor Yellow
        return $false
    }
}

# Generic function to create MSI-based app configuration
function Get-MsiAppConfig {
    param(
        [string]$AppName,
        [string]$Version,
        [string]$SetupFile,
        [string]$IntuneWinPath
    )
    
    $appConfig = Get-AppConfiguration -AppName $AppName
    $commonSettings = Get-CommonSettings
    
    # Get MSI metadata from .intunewin file
    $IntuneWinMetaData = Get-IntuneWin32AppMetaData -FilePath $IntuneWinPath
    
    # Determine detection method based on config
    if ($appConfig.DetectionFile) {
        # Hybrid MSI: Use file-based detection for auto-update MSI apps (like Chrome)
        # MSI version doesn't reflect actual app version after auto-update
        $detectionOperator = if ($appConfig.DetectionOperator) {
            $appConfig.DetectionOperator
        } else {
            $commonSettings.DetectionOperator
        }
        
        $DetectionRule = New-IntuneWin32AppDetectionRuleFile `
            -Version `
            -Path $appConfig.DetectionPath `
            -FileOrFolder $appConfig.DetectionFile `
            -Check32BitOn64System $commonSettings.Check32BitOn64System `
            -Operator $detectionOperator `
            -VersionValue $Version
        
        # Use provided version for display name and app version
        $fullVersion = $Version
        $useVersion = $fullVersion
    }
    else {
        # Pure MSI: Product code only detection (like 7-Zip)
        # Each version has unique product code, no version checking needed
        $DetectionRule = New-IntuneWin32AppDetectionRuleMSI `
            -ProductCode $IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiProductCode
        
        # Use MSI metadata for version
        $fullVersion = $IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiProductVersion
        $useVersion = $fullVersion
    }
    
    # Extract major version for display name (e.g., "142" from "142.0.7444.135")
    $majorVersion = if ($useVersion -match '^(\d+)') { $matches[1] } else { $useVersion }
    
    $DisplayName = $appConfig.DisplayNameTemplate -f $majorVersion
    $Description = $appConfig.Description
    
    $RequirementRule = New-IntuneWin32AppRequirementRule `
        -Architecture $commonSettings.Architecture `
        -MinimumSupportedOperatingSystem $commonSettings.MinimumOS
    
    # Get publisher from metadata or config
    $Publisher = if ($IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiPublisher) {
        $IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiPublisher
    } else {
        $appConfig.Publisher
    }
    
    # Format commands - uninstall always uses MSI product code
    $UninstallCommand = $appConfig.UninstallCommandTemplate -f $IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiProductCode
    $InstallCommand = $appConfig.InstallCommandTemplate -f $SetupFile
    
    return @{
        DisplayName = $DisplayName
        Description = $Description
        Publisher = $Publisher
        AppVersion = $fullVersion
        InstallExperience = $commonSettings.InstallExperience
        RestartBehavior = $commonSettings.RestartBehavior
        DetectionRules = $DetectionRule
        RequirementRule = $RequirementRule
        InstallCommandLine = $InstallCommand
        UninstallCommandLine = $UninstallCommand
    }
}

# Generic function to create File-based app configuration
function Get-FileAppConfig {
    param(
        [string]$AppName,
        [string]$Version,
        [string]$SetupFile
    )
    
    $appConfig = Get-AppConfiguration -AppName $AppName
    $commonSettings = Get-CommonSettings
    
    # Use app-specific detection operator if specified, otherwise use common setting
    $detectionOperator = if ($appConfig.DetectionOperator) {
        $appConfig.DetectionOperator
    } else {
        $commonSettings.DetectionOperator
    }
    
    # Create file detection rule
    $DetectionRule = New-IntuneWin32AppDetectionRuleFile `
        -Version `
        -Path $appConfig.DetectionPath `
        -FileOrFolder $appConfig.DetectionFile `
        -Check32BitOn64System $commonSettings.Check32BitOn64System `
        -Operator $detectionOperator `
        -VersionValue $Version
    
    $RequirementRule = New-IntuneWin32AppRequirementRule `
        -Architecture $commonSettings.Architecture `
        -MinimumSupportedOperatingSystem $commonSettings.MinimumOS
    
    # Extract major version for display name (e.g., "143" from "143.0.4")
    $majorVersion = if ($Version -match '^(\d+)') { $matches[1] } else { $Version }
    
    # Format display name with major version only, description without version
    $DisplayName = $appConfig.DisplayNameTemplate -f $majorVersion
    $Description = $appConfig.Description
    
    # Format commands
    $InstallCommand = $appConfig.InstallCommandTemplate -f $SetupFile
    $UninstallCommand = $appConfig.UninstallCommandTemplate
    
    return @{
        DisplayName = $DisplayName
        Description = $Description
        Publisher = $appConfig.Publisher
        AppVersion = $Version
        InstallExperience = $commonSettings.InstallExperience
        RestartBehavior = $commonSettings.RestartBehavior
        DetectionRules = $DetectionRule
        RequirementRule = $RequirementRule
        InstallCommandLine = $InstallCommand
        UninstallCommandLine = $UninstallCommand
    }
}
