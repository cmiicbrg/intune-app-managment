#Requires -Version 7.4

# Script to download latest software versions and create IntuneWin packages


param(
    [Parameter(Mandatory=$false)]
    [string]$AppName,

    # Skip writing successfully downloaded versions back to AppVersions.json
    [Parameter(Mandatory=$false)]
    [switch]$NoVersionCacheUpdate
)

$ErrorActionPreference = "Stop"
$BaseDir = $PSScriptRoot

# Import shared functions and configuration
. (Join-Path $PSScriptRoot "SharedFunctions.ps1")

# Build the fallback result for an app whose live version lookup failed.
# Prefers the filename recorded in AppVersions.json, because FilenameTemplate cannot always
# reproduce the real asset name that FallbackUrl serves.
function Get-FallbackVersionInfo {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$AppConfig
    )

    $filename = if ($AppConfig.FallbackFilename) {
        $AppConfig.FallbackFilename
    }
    else {
        $AppConfig.FilenameTemplate -f $AppConfig.FallbackVersion
    }

    return @{Url = $AppConfig.FallbackUrl; Version = $AppConfig.FallbackVersion; Filename = $filename}
}

# Generic function to get latest version info for an app
function Get-LatestVersionInfo {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$AppConfig
    )
    
    try {
        # Handle different version detection methods
        if ($AppConfig.WingetPackageId) {
            # Winget manifest (7-Zip, VLC, Inkscape - unsigned installers). Version, URL and
            # SHA-256 come as one reviewed bundle; the hash replaces the Authenticode check.
            Write-Host "Resolving version from winget manifest..." -ForegroundColor Gray
            $wingetInfo = Get-WingetInstallerInfo -PackageId $AppConfig.WingetPackageId `
                -Architecture ($AppConfig.WingetArchitecture ?? "x64") `
                -InstallerType $AppConfig.WingetInstallerType `
                -AllowedUrlPrefixes $AppConfig.AllowedDownloadUrlPrefixes
            if ($wingetInfo) {
                return @{Url = $wingetInfo.Url; Version = $wingetInfo.Version; Filename = $wingetInfo.Filename; Sha256 = $wingetInfo.Sha256}
            }
            # Deliberately no FallbackUrl here: without a manifest hash there is nothing to
            # verify an unsigned installer against. Skip and pick it up on a later run.
            # If this persists across runs, suspect winget manifest format drift - run the
            # LocalOnly live test in tests/SharedFunctions.Tests.ps1 to diagnose.
            Write-Host "No verifiable winget manifest - skipping this run" -ForegroundColor Yellow
            return $null
        }
        elseif ($AppConfig.VersionApiUrl) {
            # API-based version detection (Firefox)
            Write-Host "Fetching version from API..." -ForegroundColor Gray
            $versionInfo = Invoke-RestMethod -Uri $AppConfig.VersionApiUrl
            $version = $versionInfo.($AppConfig.VersionApiProperty)
            $filename = $AppConfig.FilenameTemplate -f $version
            return @{Url = $AppConfig.DownloadUrl; Version = $version; Filename = $filename}
        }
        elseif ($AppConfig.GitHubApiUrl) {
            # GitHub releases (Notepad++, Audacity, OpenShot, KeePassXC, Stellarium, Next-Exam)
            Write-Host "Fetching version from GitHub..." -ForegroundColor Gray
            $release = Invoke-RestMethod -Uri $AppConfig.GitHubApiUrl
            $asset = $release.assets | Where-Object { $_.name -match $AppConfig.GitHubAssetPattern } | Select-Object -First 1
            if ($asset) {
                # Strip any leading non-digits, so "v8.9.7" and "Audacity-3.7.8" both yield a bare version
                $version = $release.tag_name -replace '^\D*', ''
                return @{Url = $asset.browser_download_url; Version = $version; Filename = $asset.name}
            }
        }
        elseif ($AppConfig.DownloadPageUrl -and $AppConfig.DownloadUrlRegex) {
            # Web scraping (GIMP, LibreOffice, Google Earth Pro)
            Write-Host "Fetching version from download page..." -ForegroundColor Gray
            $page = Invoke-WebRequest -Uri $AppConfig.DownloadPageUrl

            if ($page.Content -match $AppConfig.DownloadUrlRegex) {
                if ($AppConfig.Name -eq "GIMP") {
                    # GIMP special handling
                    $version = $matches[1]
                    $majorMinor = $version.Substring(0, $version.LastIndexOf('.'))
                    $url = $AppConfig.DownloadUrlTemplate -f $majorMinor, $version
                    $filename = $AppConfig.FilenameTemplate -f $version
                    return @{Url = $url; Version = $version; Filename = $filename}
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
                elseif ($AppConfig.Name -eq "Google Earth Pro") {
                    # Google Earth Pro - scrape version from release notes, build versioned URL
                    $version = $matches[1]  # e.g., "7.3.7"
                    $url = $AppConfig.DownloadUrlTemplate -f $version
                    $filename = $AppConfig.FilenameTemplate -f $version
                    Write-Host "  Found version: $version" -ForegroundColor Green
                    return @{Url = $url; Version = $version; Filename = $filename}
                }
            }
        }
        elseif ($AppConfig.VersionExtraction -eq "AppLocker") {
            # Version extracted after download (Chrome, Affinity, VCRedist)
            $uri = [System.Uri]$AppConfig.DownloadUrl
            $filename = [System.IO.Path]::GetFileName($uri.LocalPath)
            return @{Url = $AppConfig.DownloadUrl; Version = "Latest"; Filename = $filename}
        }
        
        # If no method worked, use fallback
        Write-Host "Using fallback URL" -ForegroundColor Yellow
        return (Get-FallbackVersionInfo -AppConfig $AppConfig)
    }
    catch {
        Write-Host "Error fetching version info: $_" -ForegroundColor Yellow
        if ($AppConfig.WingetPackageId) {
            # Never hand an unsigned app to an unverified fallback URL
            Write-Host "No unverified fallback for winget-verified apps - skipping this run" -ForegroundColor Yellow
            return $null
        }
        if ($AppConfig.FallbackUrl) {
            Write-Host "Using fallback URL" -ForegroundColor Yellow
            return (Get-FallbackVersionInfo -AppConfig $AppConfig)
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
    
    $appFolder = Join-Path (Join-Path $BaseDir "packages") $appConfig.Folder
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
        if (Invoke-FileDownload -Url $versionInfo.Url -OutputPath $installerTemp `
            -ExpectedSha256 ($versionInfo.Sha256 ?? $appConfig.ExpectedSha256) `
            -EnforceSignatureCheck (-not $appConfig.AllowUnsignedInstaller) `
            -ExpectedPublisher $appConfig.ExpectedPublisher) {
            
            # Check if extraction is required (Affinity Studio)
            if ($appConfig.ManualExtraction) {
                Write-Host ""
                Write-Host "  Extracting version information from EXE..." -ForegroundColor White
                
                # Extract version from the downloaded EXE
                $version = Get-InstallerVersion -FilePath $installerTemp
                if ($version) {
                    Write-Host "  Detected version: $version" -ForegroundColor Green
                }
                else {
                    Write-Host "  Warning: Could not extract version from EXE" -ForegroundColor Yellow
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
                    
                    # Check if MSI was created at expected path
                    if (Test-Path $expectedMsiPath) {
                        Write-Host "  MSI file found: $expectedMsiPath" -ForegroundColor Green
                        
                        # Delete the original EXE
                        Write-Host "  Removing original EXE..." -ForegroundColor White
                        Remove-Item $installerTemp -Force
                        Write-Host "  Original EXE removed" -ForegroundColor Green
                        
                        # Update installerTemp to point to MSI for packaging
                        $installerTemp = $expectedMsiPath
                        Write-Host ""
                        Write-Host "  Continuing with MSI packaging..." -ForegroundColor Green
                        Write-Host ""
                    }
                    else {
                        Write-Host "  MSI file not found at expected location" -ForegroundColor Red
                        Write-Host "  Expected: $expectedMsiPath" -ForegroundColor Yellow
                        Write-Host "  Please manually save the MSI to the path shown above and re-run this script" -ForegroundColor Yellow
                        Write-Host ""
                        continue
                    }
                }
                catch {
                    Write-Host "  Error during extraction: $_" -ForegroundColor Red
                    Write-Host ""
                    continue
                }
                
                # Package the extracted MSI directly (skip the general rename logic below
                # which would rename the MSI back to an EXE based on FilenameTemplate)
                Remove-OldAppFiles -AppFolder $appFolder -KeepFileName (Split-Path $installerTemp -Leaf)
                
                Write-Host "  Creating IntuneWin package..." -ForegroundColor Cyan
                $packaged = New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installerTemp -Leaf) -OutputFolder $appFolder
                if ($packaged -and -not $NoVersionCacheUpdate) {
                    # No filename recorded: this app's URL serves an EXE that we extract an MSI from,
                    # so the packaged filename is not what the URL would hand back on a fallback
                    Save-AppVersionCache -AppName $appName -Version $version -Url $versionInfo.Url | Out-Null
                }
                continue
            }
            
            try {
                Write-Host "  Extracting version from file..." -ForegroundColor Gray
                $version = Get-InstallerVersion -FilePath $installerTemp
                if (-not $version) { throw "Could not extract version from installer" }
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
                $packaged = New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installer -Leaf) -OutputFolder $appFolder
                if ($packaged -and -not $NoVersionCacheUpdate) {
                    # No filename recorded: we renamed the download to FilenameTemplate ourselves,
                    # so it is not the name the URL serves
                    Save-AppVersionCache -AppName $appName -Version $version -Url $versionInfo.Url | Out-Null
                }
            }
            catch {
                Write-Host "  Error extracting version: $_" -ForegroundColor Yellow
                Write-Host "  Creating package with default filename..." -ForegroundColor Yellow

                # Clean up old files before packaging
                Remove-OldAppFiles -AppFolder $appFolder -KeepFileName (Split-Path $installerTemp -Leaf)

                # No cache write here: the version is unknown, which is why we landed in this catch
                New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installerTemp -Leaf) -OutputFolder $appFolder | Out-Null
            }
        }
        continue
    }
    
    $installer = Join-Path $appFolder $versionInfo.Filename
    $intunewinPath = $installer -replace '\.(exe|msi)$', '.intunewin'

    # One resolved pin for every decision below: the winget manifest hash, or a static
    # ExpectedSha256 from AppConfig for apps pinned that way instead
    $pinnedHash = $versionInfo.Sha256 ?? $appConfig.ExpectedSha256

    # For hash-pinned apps, never let a leftover artifact short-circuit the run unverified:
    # a stale or partial installer (e.g. left behind by an interrupted transfer, or downloaded
    # before hash pinning existed) is removed together with its package, and an .intunewin
    # without its installer is unverifiable and removed too. This must happen before the
    # version-exists check below, which would otherwise skip based on the bad package alone.
    if ($pinnedHash) {
        if (Test-Path $installer) {
            if (-not (Test-DownloadedFileIntegrity -FilePath $installer -ExpectedSha256 $pinnedHash)) {
                Write-Host "  Existing installer failed hash verification - removing it and its package for re-download" -ForegroundColor Yellow
                Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $intunewinPath -Force -ErrorAction SilentlyContinue
            }
        }
        elseif (Test-Path $intunewinPath) {
            Write-Host "  Package exists without its verified installer - removing unverifiable package" -ForegroundColor Yellow
            Remove-Item -Path $intunewinPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Version checking. Apps whose filenames carry no dotted version (e.g. 7-Zip's
    # 7z2602-x64.msi) fall through here and are caught by the installer-exists check below.
    # Hash-pinned apps skip this shortcut entirely: winget can revise an existing version
    # in place (new URL/filename/hash - Inkscape's build-suffixed names make this real),
    # and a same-version artifact under a different filename must not be blessed without
    # verification. For pinned apps only the exact resolved installer, verified against
    # the current pin below, can justify a skip; artifacts under superseded filenames are
    # cleaned up by Remove-OldAppFiles after the fresh download is packaged.
    if (-not $pinnedHash -and (Test-VersionExists -AppFolder $appFolder -NewVersion $versionInfo.Version -Pattern $appConfig.IntuneWinPattern)) {
        Write-Host "  Skipping - already up to date" -ForegroundColor Yellow
        continue
    }

    # Check if installer file already exists
    if (Test-Path $installer) {
        Write-Host "  Installer file already exists: $installer" -ForegroundColor Yellow

        # A leftover file is never reused blindly: it must pass the same verification a
        # fresh download would (pinned hash, or Authenticode + publisher). On failure it
        # is removed and the run falls through to a normal verified download.
        if (Test-DownloadedFileIntegrity -FilePath $installer `
            -ExpectedSha256 $pinnedHash `
            -EnforceSignatureCheck (-not $appConfig.AllowUnsignedInstaller) `
            -ExpectedPublisher $appConfig.ExpectedPublisher) {

            if (Test-Path $intunewinPath) {
                Write-Host "  Skipping - both installer and package already exist" -ForegroundColor Yellow
                continue
            }
            Write-Host "  Package not found, creating from existing installer..." -ForegroundColor Cyan
            New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installer -Leaf) -OutputFolder $appFolder
            continue
        }

        Write-Host "  Existing installer failed verification - removing for re-download" -ForegroundColor Yellow
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $intunewinPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Downloading version $($versionInfo.Version)..." -ForegroundColor Cyan
    if (Invoke-FileDownload -Url $versionInfo.Url -OutputPath $installer `
        -ExpectedSha256 $pinnedHash `
        -EnforceSignatureCheck (-not $appConfig.AllowUnsignedInstaller) `
        -ExpectedPublisher $appConfig.ExpectedPublisher) {
        # Clean up old files before packaging
        Remove-OldAppFiles -AppFolder $appFolder -KeepFileName (Split-Path $installer -Leaf)

        Write-Host "  Creating IntuneWin package..." -ForegroundColor Cyan
        $packaged = New-IntuneWinPackage -SourceFolder $appFolder -SetupFile (Split-Path $installer -Leaf) -OutputFolder $appFolder
        if ($packaged -and -not $NoVersionCacheUpdate) {
            Save-AppVersionCache -AppName $appName -Version $versionInfo.Version -Url $versionInfo.Url -Filename $versionInfo.Filename | Out-Null
        }
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "All downloads and packaging completed!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
