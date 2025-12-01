# Script to download latest software versions and create IntuneWin packages
# Author: GitHub Copilot
# Date: October 10, 2025

param(
    [Parameter(Mandatory=$false)]
    [string]$AppName
)

$ErrorActionPreference = "Stop"
$BaseDir = $PSScriptRoot

# Import shared functions and configuration
. (Join-Path $PSScriptRoot "SharedFunctions.ps1")

# Generic function to get latest version info for an app
function Get-LatestVersionInfo {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$AppConfig
    )
    
    try {
        # Handle different version detection methods
        if ($AppConfig.VersionApiUrl) {
            # API-based version detection (Firefox)
            Write-Host "Fetching version from API..." -ForegroundColor Gray
            $versionInfo = Invoke-RestMethod -Uri $AppConfig.VersionApiUrl
            $version = $versionInfo.($AppConfig.VersionApiProperty)
            $filename = $AppConfig.FilenameTemplate -f $version
            return @{Url = $AppConfig.DownloadUrl; Version = $version; Filename = $filename}
        }
        elseif ($AppConfig.GitHubApiUrl) {
            # GitHub releases (Notepad++)
            Write-Host "Fetching version from GitHub..." -ForegroundColor Gray
            $release = Invoke-RestMethod -Uri $AppConfig.GitHubApiUrl
            $asset = $release.assets | Where-Object { $_.name -match $AppConfig.GitHubAssetPattern } | Select-Object -First 1
            if ($asset) {
                $version = $release.tag_name -replace '^v', ''
                return @{Url = $asset.browser_download_url; Version = $version; Filename = $asset.name}
            }
        }
        elseif ($AppConfig.DownloadPageUrl -and $AppConfig.DownloadUrlRegex) {
            # Web scraping (7-Zip, GIMP, VLC)
            Write-Host "Fetching version from download page..." -ForegroundColor Gray
            $page = Invoke-WebRequest -Uri $AppConfig.DownloadPageUrl -UseBasicParsing
            
            if ($page.Content -match $AppConfig.DownloadUrlRegex) {
                if ($AppConfig.Name -eq "7-Zip") {
                    # 7-Zip special handling
                    $url = $AppConfig.DownloadUrlTemplate -f $matches[1]
                    $version = $matches[2]
                    $filename = $AppConfig.FilenameTemplate -f $version
                    return @{Url = $url; Version = $version; Filename = $filename}
                }
                elseif ($AppConfig.Name -eq "GIMP") {
                    # GIMP special handling
                    $version = $matches[1]
                    $majorMinor = $version.Substring(0, $version.LastIndexOf('.'))
                    $url = $AppConfig.DownloadUrlTemplate -f $majorMinor, $version
                    $filename = $AppConfig.FilenameTemplate -f $version
                    return @{Url = $url; Version = $version; Filename = $filename}
                }
                elseif ($AppConfig.Name -eq "VLC") {
                    # VLC special handling
                    $filename = $matches[1]
                    $version = $matches[2]
                    $url = $AppConfig.DownloadUrlTemplate -f $filename
                    return @{Url = $url; Version = $version; Filename = $filename}
                }
                elseif ($AppConfig.Name -eq "Inkscape") {
                    # Inkscape special handling - two-step process
                    $version = $matches[1]  # e.g., 1.4.2
                    Write-Host "  Found version: $version" -ForegroundColor Gray
                    
                    # Step 2: Get the platforms page to find the actual MSI download link
                    $platformsUrl = $AppConfig.PlatformsUrlTemplate -f $version
                    Write-Host "  Fetching download link from platforms page..." -ForegroundColor Gray
                    $platformsPage = Invoke-WebRequest -Uri $platformsUrl -UseBasicParsing
                    
                    if ($platformsPage.Content -match $AppConfig.DownloadLinkRegex) {
                        $actualFilename = $matches[1]  # e.g., inkscape-1.4.2_2025-05-13_f4327f4-x64.msi
                        $url = $matches[0]  # Full URL
                        $filename = $AppConfig.FilenameTemplate -f $version  # Simplified filename for storage
                        Write-Host "  Found MSI: $actualFilename" -ForegroundColor Gray
                        return @{Url = $url; Version = $version; Filename = $actualFilename}
                    }
                    else {
                        Write-Host "  Could not find MSI download link on platforms page" -ForegroundColor Yellow
                    }
                }
                elseif ($AppConfig.Name -eq "LibreOffice") {
                    # LibreOffice special handling - find unique versions and pick the lower one (enterprise/stable)
                    $allMatches = [regex]::Matches($page.Content, $AppConfig.DownloadUrlRegex)
                    Write-Host "  Found $($allMatches.Count) match(es) on page" -ForegroundColor Gray
                    
                    # Get unique versions
                    $uniqueVersions = $allMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Sort-Object
                    
                    if ($uniqueVersions.Count -ge 2) {
                        # Use the lower version (enterprise/business version)
                        $version = $uniqueVersions[0]  # First (lowest) version
                        $url = $AppConfig.DownloadUrlTemplate -f $version
                        $filename = $AppConfig.FilenameTemplate -f $version
                        Write-Host "  Found enterprise version: $version (lower of: $($uniqueVersions -join ', '))" -ForegroundColor Green
                        return @{Url = $url; Version = $version; Filename = $filename}
                    }
                    elseif ($uniqueVersions.Count -eq 1) {
                        Write-Host "  Only found 1 unique version: $($uniqueVersions[0])" -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "  No matches found with regex pattern" -ForegroundColor Yellow
                    }
                }
            }
        }
        elseif ($AppConfig.VersionExtraction -eq "AppLocker") {
            # Version extracted after download (Chrome, Affinity)
            # Use FilenameTempate if it exists (Chrome typo compatibility), otherwise extract filename from URL
            $filename = if ($AppConfig.FilenameTempate) {
                $AppConfig.FilenameTempate
            } else {
                # Extract filename from URL
                $uri = [System.Uri]$AppConfig.DownloadUrl
                [System.IO.Path]::GetFileName($uri.LocalPath)
            }
            return @{Url = $AppConfig.DownloadUrl; Version = "Latest"; Filename = $filename}
        }
        
        # If no method worked, use fallback
        Write-Host "Using fallback URL" -ForegroundColor Yellow
        return @{Url = $AppConfig.FallbackUrl; Version = $AppConfig.FallbackVersion; Filename = ($AppConfig.FilenameTemplate -f $AppConfig.FallbackVersion)}
    }
    catch {
        Write-Host "Error fetching version info: $_" -ForegroundColor Yellow
        if ($AppConfig.FallbackUrl) {
            Write-Host "Using fallback URL" -ForegroundColor Yellow
            return @{Url = $AppConfig.FallbackUrl; Version = $AppConfig.FallbackVersion; Filename = ($AppConfig.FilenameTemplate -f $AppConfig.FallbackVersion)}
        }
        return $null
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Software Download and Packaging Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get all apps from configuration (or filter by parameter)
if ($AppName) {
    $appConfig = Get-AppConfiguration -AppName $AppName
    if (-not $appConfig) {
        Write-Host "Error: App '$AppName' not found in configuration" -ForegroundColor Red
        Write-Host "Available apps: $(Get-AllAppNames -join ', ')" -ForegroundColor Yellow
        exit 1
    }
    $allAppNames = @($AppName)
    Write-Host "Processing single app: $AppName" -ForegroundColor Yellow
    Write-Host ""
}
else {
    $allAppNames = Get-AllAppNames
    Write-Host "Processing all apps from configuration" -ForegroundColor Yellow
    Write-Host ""
}

$appCount = $allAppNames.Count
$currentApp = 0

foreach ($appName in $allAppNames) {
    $currentApp++
    Write-Host "`n[$currentApp/$appCount] Processing $appName..." -ForegroundColor Magenta
    
    $appConfig = Get-AppConfiguration -AppName $appName
    if (-not $appConfig) {
        Write-Host "  Skipping - configuration not found" -ForegroundColor Red
        continue
    }
    
    $appFolder = Join-Path $BaseDir "packages" $appConfig.Folder
    if (-not (Test-Path $appFolder)) {
        New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
    }
    
    # Get version info
    $versionInfo = Get-LatestVersionInfo -AppConfig $appConfig
    if (-not $versionInfo) {
        Write-Host "  Skipping - could not determine version" -ForegroundColor Red
        continue
    }
    
    Write-Host "  Latest version: $($versionInfo.Version)" -ForegroundColor Cyan
    
    # Special handling for apps with version extraction after download (Chrome, Affinity)
    if ($appConfig.VersionExtraction -eq "AppLocker") {
        $installerTemp = Join-Path $appFolder $versionInfo.Filename
        
        Write-Host "  Downloading (version will be determined from file)..." -ForegroundColor Cyan
        if (Invoke-FileDownload -Url $versionInfo.Url -OutputPath $installerTemp) {
            
            # Check if extraction is required (Affinity Studio)
            if ($appConfig.ManualExtraction) {
                Write-Host ""
                Write-Host "  Extracting version information from EXE..." -ForegroundColor White
                
                # Extract version from the downloaded EXE
                try {
                    $fileInfo = Get-AppLockerFileInformation -Path $installerTemp -ErrorAction Stop
                    $version = $fileInfo.Publisher.BinaryVersion.ToString()
                    Write-Host "  Detected version: $version" -ForegroundColor Green
                }
                catch {
                    Write-Host "  Warning: Could not extract version from EXE: $_" -ForegroundColor Yellow
                    Write-Host "  Using version from download: $version" -ForegroundColor Yellow
                }
                
                # Determine expected MSI filename with extracted version
                $expectedMsiName = $appConfig.FilenameTemplate -replace '\.exe$', '.msi' -replace '\{0\}', $version
                $expectedMsiPath = Join-Path $appFolder $expectedMsiName
                $expectedIntunewinPath = $expectedMsiPath -replace '\.msi$', '.intunewin'
                
                # Check if we already have this version packaged
                if (Test-Path $expectedIntunewinPath) {
                    Write-Host "  Version $version already packaged: $expectedIntunewinPath" -ForegroundColor Green
                    Write-Host "  Skipping extraction and packaging" -ForegroundColor Yellow
                    
                    # Clean up the downloaded EXE
                    Remove-Item $installerTemp -Force -ErrorAction SilentlyContinue
                    Write-Host "  Cleaned up downloaded EXE" -ForegroundColor White
                    Write-Host ""
                    continue
                }
                
                Write-Host ""
                Write-Host "  =====================================================" -ForegroundColor Yellow
                Write-Host "  Extraction Required - $($appConfig.Name)" -ForegroundColor Yellow
                Write-Host "  =====================================================" -ForegroundColor Yellow
                Write-Host "  Downloaded EXE: $installerTemp" -ForegroundColor Cyan
                Write-Host "  Expected MSI:   $expectedMsiPath" -ForegroundColor Cyan
                
                Write-Host "  Expected MSI:   $expectedMsiPath" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Starting extraction dialog..." -ForegroundColor White
                Write-Host "  IMPORTANT: Save the MSI to the path shown above!" -ForegroundColor Yellow
                Write-Host ""
                
                try {
                    # Execute the extraction command
                    $extractCmd = $appConfig.ExtractionCommand -f $installerTemp
                    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$extractCmd`"" -Wait -PassThru -NoNewWindow
                    
                    Write-Host "  Extraction dialog closed." -ForegroundColor White
                    Write-Host ""
                    
                    # Check if MSI was created
                    if (Test-Path $expectedMsiPath) {
                        Write-Host "  ✓ MSI file found: $expectedMsiPath" -ForegroundColor Green
                        
                        # Delete the original EXE
                        Write-Host "  Removing original EXE..." -ForegroundColor White
                        Remove-Item $installerTemp -Force
                        Write-Host "  ✓ Original EXE removed" -ForegroundColor Green
                        
                        # Update installerTemp to point to MSI for packaging
                        $installerTemp = $expectedMsiPath
                        Write-Host ""
                        Write-Host "  Continuing with MSI packaging..." -ForegroundColor Green
                        Write-Host ""
                    }
                    else {
                        Write-Host "  ✗ MSI file not found at expected location" -ForegroundColor Red
                        Write-Host "  Expected: $expectedMsiPath" -ForegroundColor Yellow
                        Write-Host "  Please manually save the MSI and re-run this script" -ForegroundColor Yellow
                        Write-Host ""
                        continue
                    }
                }
                catch {
                    Write-Host "  Error during extraction: $_" -ForegroundColor Red
                    Write-Host ""
                    continue
                }
            }
            
            try {
                Write-Host "  Extracting version from file..." -ForegroundColor Gray
                $appLockerInfo = Get-AppLockerFileInformation -Path $installerTemp | Select-Object -ExpandProperty Publisher
                $version = $appLockerInfo.BinaryVersion.ToString()
                Write-Host "  Version detected: $version" -ForegroundColor Cyan
                
                # Check if this version already exists
                if (Test-VersionExists -AppFolder $appFolder -NewVersion $version -Pattern $appConfig.IntuneWinPattern) {
                    Write-Host "  Skipping - version $version already packaged" -ForegroundColor Yellow
                    Remove-Item -Path $installerTemp -Force -ErrorAction SilentlyContinue
                    continue
                }
                
                # Rename with version
                $installer = Join-Path $appFolder ($appConfig.FilenameTemplate -f $version)
                if (Test-Path $installer) {
                    Remove-Item -Path $installer -Force
                }
                Move-Item -Path $installerTemp -Destination $installer -Force
                
                # Clean up old files before packaging
                Remove-OldAppFiles -AppFolder $appFolder -KeepFileName (Split-Path $installer -Leaf)
                
                Write-Host "  Creating IntuneWin package..." -ForegroundColor Cyan
                New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installer -Leaf) -OutputFolder $appFolder
            }
            catch {
                Write-Host "  Error extracting version: $_" -ForegroundColor Yellow
                Write-Host "  Creating package with default filename..." -ForegroundColor Yellow
                
                # Clean up old files before packaging
                Remove-OldAppFiles -AppFolder $appFolder -KeepFileName (Split-Path $installerTemp -Leaf)
                
                New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installerTemp -Leaf) -OutputFolder $appFolder
            }
        }
        continue
    }
    
    # Special handling for 7-Zip (version format without dots)
    if ($appConfig.VersionFormat -eq "NoPrefix") {
        $existingPackages = Get-ChildItem -Path $appFolder -Filter $appConfig.IntuneWinPattern -ErrorAction SilentlyContinue
        $versionExists = $false
        foreach ($package in $existingPackages) {
            if ($package.BaseName -match '7z(\d+)') {
                $existingVersion = $matches[1]
                if ($existingVersion -eq $versionInfo.Version.Replace('7z', '')) {
                    Write-Host "  Skipping - version $($versionInfo.Version) already packaged" -ForegroundColor Yellow
                    $versionExists = $true
                    break
                }
            }
        }
        if ($versionExists) {
            continue
        }
    }
    else {
        # Standard version checking
        if (Test-VersionExists -AppFolder $appFolder -NewVersion $versionInfo.Version -Pattern $appConfig.IntuneWinPattern) {
            Write-Host "  Skipping - already up to date" -ForegroundColor Yellow
            continue
        }
    }
    
    # Download and package
    $installer = Join-Path $appFolder $versionInfo.Filename
    
    # Check if installer file already exists
    if (Test-Path $installer) {
        Write-Host "  Installer file already exists: $installer" -ForegroundColor Yellow
        Write-Host "  Checking if package exists..." -ForegroundColor Gray
        
        # Check if .intunewin also exists
        $intunewinPath = $installer -replace '\.(exe|msi)$', '.intunewin'
        if (Test-Path $intunewinPath) {
            Write-Host "  Skipping - both installer and package already exist" -ForegroundColor Yellow
            continue
        }
        else {
            Write-Host "  Package not found, creating from existing installer..." -ForegroundColor Cyan
            New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installer -Leaf) -OutputFolder $appFolder
            continue
        }
    }
    
    Write-Host "  Downloading version $($versionInfo.Version)..." -ForegroundColor Cyan
    if (Invoke-FileDownload -Url $versionInfo.Url -OutputPath $installer) {
        # Clean up old files before packaging
        Remove-OldAppFiles -AppFolder $appFolder -KeepFileName (Split-Path $installer -Leaf)
        
        Write-Host "  Creating IntuneWin package..." -ForegroundColor Cyan
        New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installer -Leaf) -OutputFolder $appFolder
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "All downloads and packaging completed!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
