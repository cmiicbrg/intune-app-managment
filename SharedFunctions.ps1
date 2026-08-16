#Requires -Version 7.4

# Shared Functions Module
# Common functions used by both Download-And-Package-Software.ps1 and Deploy-ToIntune.ps1


# Import configuration
. (Join-Path $PSScriptRoot "AppConfig.ps1")

# All Intune module interaction goes through the interop boundary
. (Join-Path $PSScriptRoot "IntuneInterop.ps1")

#region App family and version helpers
# Shared by Deploy-ToIntune.ps1 and the inventory/cleanup tooling so "which AppConfig family does
# this Intune app belong to, and which version is it" is answered the same way everywhere.

# Base display name of an app family - the part every version shares. Derived either from the
# AppConfig DisplayNameTemplate (the text before the "{0}" version placeholder) or from a concrete
# Intune display name (the text before the first version number). For this repository's naming
# convention ("<base> {0}[ suffix]") both readings are equivalent; a unit test pins that.
function Get-AppFamilyBaseName {
    [CmdletBinding(DefaultParameterSetName = 'Template')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Template')]
        [string]$DisplayNameTemplate,

        [Parameter(Mandatory = $true, ParameterSetName = 'DisplayName')]
        [string]$DisplayName
    )

    if ($PSCmdlet.ParameterSetName -eq 'Template') {
        $index = $DisplayNameTemplate.IndexOf('{0}')
        $base = if ($index -ge 0) { $DisplayNameTemplate.Substring(0, $index) } else { $DisplayNameTemplate }
        return $base.Trim()
    }

    # e.g. "Google Chrome 142" -> "Google Chrome"; "Mozilla Firefox 153 (German)" -> "Mozilla Firefox"
    return ($DisplayName -replace '\s+\d+.*$', '').Trim()
}

# One entry per AppConfig app that has a package folder and pattern - the deployable set.
# Returned in canonical app-name order (Get-AllAppNames), which is also the order Deploy-ToIntune.ps1
# processes apps in.
#   AppConfigName - key in AppConfig.ps1 (e.g. "Firefox")
#   Name          - display label, template without the version placeholder (e.g. "Mozilla Firefox (German)")
#   BaseName      - family prefix used to match Intune display names (e.g. "Mozilla Firefox")
function Get-AppFamilyCatalog {
    $families = @()
    foreach ($appConfigName in (Get-AllAppNames)) {
        $cfg = Get-AppConfiguration -AppName $appConfigName
        if ($cfg -and $cfg.Folder -and $cfg.IntuneWinPattern) {
            $families += [PSCustomObject]@{
                AppConfigName = $appConfigName
                Name          = ($cfg.DisplayNameTemplate -replace '\s*\{0\}', '').Trim()
                BaseName      = Get-AppFamilyBaseName -DisplayNameTemplate $cfg.DisplayNameTemplate
                Folder        = $cfg.Folder
                Pattern       = $cfg.IntuneWinPattern
                PackageType   = $cfg.PackageType
            }
        }
    }
    return $families
}

# Maps an Intune display name to the family it belongs to. The longest matching base name wins,
# so a hypothetical "Google Drive Enterprise" family could never be claimed by "Google Drive".
# Returns $null for apps this repository does not manage.
function Resolve-AppFamily {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        # Output of Get-AppFamilyCatalog
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Families
    )

    foreach ($family in ($Families | Sort-Object { $_.BaseName.Length } -Descending)) {
        if ($DisplayName.StartsWith($family.BaseName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $family
        }
    }
    return $null
}

# The version an Intune app reports: displayVersion first, else the first dotted number in the
# display name (older deployments left displayVersion empty). Returns $null when neither yields
# anything. Version is the parsed [version], or $null when Raw does not parse (e.g. "Latest").
function Get-IntuneAppVersion {
    param(
        [Parameter(Mandatory = $true)]
        $App
    )

    $raw = $null
    $source = $null
    if ($App.displayVersion) {
        $raw = "$($App.displayVersion)"
        $source = 'displayVersion'
    }
    elseif ($App.displayName -match '(\d+(?:\.\d+)*)') {
        $raw = $matches[1]
        $source = 'displayName'
    }

    if ($null -eq $raw) {
        return $null
    }

    $parsed = $null
    $version = if ([version]::TryParse($raw, [ref]$parsed)) { $parsed } else { $null }

    return [PSCustomObject]@{
        Raw     = $raw
        Version = $version
        Source  = $source
    }
}

#endregion

# Function to extract version from an installer file
# For MSI files, queries the MSI database directly via the WindowsInstaller COM object.
# For EXE files, falls back to Get-AppLockerFileInformation, which PS 7 loads through
# the Windows compatibility session.
function Get-InstallerVersion {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()

    # MSI: query ProductVersion from the MSI database (reliable on all PS versions)
    if ($extension -eq '.msi') {
        $dbObject = $null
        $viewObject = $null
        try {
            $msiInstaller = New-Object -ComObject WindowsInstaller.Installer
            $dbObject = $msiInstaller.OpenDatabase($FilePath, 0)
            $viewObject = $dbObject.OpenView("SELECT Value FROM Property WHERE Property = 'ProductVersion'")
            [void]$viewObject.Execute()
            $record = $viewObject.Fetch()
            if ($record) {
                $ver = $record.StringData(1)
                if (-not [string]::IsNullOrWhiteSpace($ver)) {
                    return $ver
                }
            }
        }
        catch {
            Write-Verbose "MSI COM version extraction failed: $_"
        }
        finally {
            if ($null -ne $viewObject) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($viewObject) | Out-Null } catch {} }
            if ($null -ne $dbObject)   { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($dbObject)   | Out-Null } catch {} }
        }
    }

    # Fallback: Get-AppLockerFileInformation (works for both MSI and EXE)
    try {
        $info = Get-AppLockerFileInformation -Path $FilePath -ErrorAction Stop
        $pub = $info.Publisher

        # The compat session usually returns Publisher as a string on PS 7, but the
        # shape isn't guaranteed across Windows builds - handle both.
        if ($null -ne $pub -and $pub -is [string]) {
            # Format: "PUBLISHER\PRODUCT\BINARY,VERSION"
            if ($pub -match ',(\d+[\d\.]+)') {
                return $matches[1]
            }
        }
        elseif ($null -ne $pub) {
            $bv = $pub.BinaryVersion
            if ($null -ne $bv) {
                return $bv.ToString()
            }
        }
    }
    catch {
        Write-Verbose "AppLocker version extraction failed: $_"
    }

    return $null
}

# Function to record a successfully downloaded version in AppVersions.json.
# AppConfig.ps1 overlays these values onto FallbackVersion/FallbackUrl/FallbackFilename at load
# time, which keeps the offline fallbacks from going stale. Never throws: a cache write failing
# must not fail an otherwise successful packaging run.
function Save-AppVersionCache {
    param(
        [Parameter(Mandatory=$true)]
        [string]$AppName,

        [Parameter(Mandatory=$true)]
        [string]$Version,

        [string]$Url,

        [string]$Filename
    )

    # "Latest" is a placeholder for apps whose version is only known after download - nothing to record
    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -eq 'Latest') {
        return $false
    }

    try {
        $cachePath = $script:AppVersionCachePath
        if (-not $cachePath) {
            $cachePath = Join-Path $PSScriptRoot "AppVersions.json"
        }

        # Preserve the file header and every other app's entry
        $comment = $null
        $apps = @{}
        if (Test-Path $cachePath) {
            $existing = Get-Content -Path $cachePath -Raw | ConvertFrom-Json
            $comment = $existing._comment
            if ($existing.Apps) {
                foreach ($entry in $existing.Apps.PSObject.Properties) {
                    $apps[$entry.Name] = $entry.Value
                }
            }
        }

        # Skip the write when nothing changed, so repeat runs leave the working tree clean
        $current = $apps[$AppName]
        if ($current -and $current.Version -eq $Version -and $current.Url -eq $Url -and $current.Filename -eq $Filename) {
            return $false
        }

        $apps[$AppName] = [PSCustomObject]@{
            Version    = $Version
            Url        = $Url
            Filename   = $Filename
            UpdatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }

        # Sorted keys keep diffs minimal and merge noise low
        $orderedApps = [ordered]@{}
        foreach ($key in ($apps.Keys | Sort-Object)) {
            $orderedApps[$key] = $apps[$key]
        }

        $document = [ordered]@{}
        if ($comment) { $document['_comment'] = $comment }
        $document['Apps'] = $orderedApps

        # WriteAllText writes BOM-less UTF-8 explicitly, independent of shell encoding defaults
        $json = ($document | ConvertTo-Json -Depth 5) + "`n"
        [System.IO.File]::WriteAllText($cachePath, $json, (New-Object System.Text.UTF8Encoding($false)))

        Write-Host "  Recorded version $Version in $(Split-Path $cachePath -Leaf)" -ForegroundColor Gray
        return $true
    }
    catch {
        Write-Warning "Could not update version cache for '$AppName': $($_.Exception.Message)"
        return $false
    }
}

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

# Function to verify integrity of a downloaded installer file.
# Checks SHA-256 hash (if provided) or Authenticode signature + optional publisher match.
# Returns $true if the file passes verification, $false otherwise (fail closed).
function Test-DownloadedFileIntegrity {
    param(
        [string]$FilePath,
        [string]$ExpectedSha256,
        [bool]$EnforceSignatureCheck = $true,
        [string]$ExpectedPublisher
    )

    if (-not (Test-Path $FilePath)) {
        Write-Host "Integrity check failed: file does not exist ($FilePath)" -ForegroundColor Red
        return $false
    }

    # SHA-256 takes precedence — if provided, Authenticode checks are intentionally skipped
    # because an explicit hash pins the exact binary content (stronger than signature alone).
    if ($ExpectedSha256) {
        # Normalize: strip whitespace, uppercase, validate 64 hex chars
        $normalizedHash = ($ExpectedSha256 -replace '\s','').ToUpperInvariant()
        if ($normalizedHash.Length -ne 64 -or $normalizedHash -notmatch '^[0-9A-F]{64}$') {
            Write-Host "Integrity check FAILED: ExpectedSha256 is not a valid 64-character hex string." -ForegroundColor Red
            Write-Host "  Received: $ExpectedSha256" -ForegroundColor Red
            return $false
        }
        try {
            $actualHash = (Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($actualHash -ne $normalizedHash) {
                Write-Host "Integrity check FAILED: SHA-256 mismatch for $(Split-Path $FilePath -Leaf)" -ForegroundColor Red
                Write-Host "  Expected: $normalizedHash" -ForegroundColor Red
                Write-Host "  Actual:   $actualHash" -ForegroundColor Red
                return $false
            }
            Write-Host "Integrity check passed: SHA-256 verified." -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Integrity check FAILED: unable to compute SHA-256 for $(Split-Path $FilePath -Leaf)" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }

    # Authenticode signature check (default path)
    if ($EnforceSignatureCheck) {
        try {
            $signature = Get-AuthenticodeSignature -FilePath $FilePath -ErrorAction Stop
        }
        catch {
            Write-Host "Integrity check FAILED: unable to verify Authenticode signature for $(Split-Path $FilePath -Leaf)" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }

        if ($signature.Status -ne 'Valid') {
            Write-Host "Integrity check FAILED: Authenticode signature status is '$($signature.Status)' for $(Split-Path $FilePath -Leaf)" -ForegroundColor Red
            return $false
        }

        # Publisher match (substring, case-insensitive)
        if ($ExpectedPublisher) {
            $subject = $signature.SignerCertificate.Subject
            if (-not $subject -or $subject.IndexOf($ExpectedPublisher, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                Write-Host "Integrity check FAILED: publisher mismatch for $(Split-Path $FilePath -Leaf)" -ForegroundColor Red
                Write-Host "  Expected publisher containing: $ExpectedPublisher" -ForegroundColor Red
                Write-Host "  Actual certificate subject:    $subject" -ForegroundColor Red
                return $false
            }
            Write-Host "Integrity check passed: valid signature from '$ExpectedPublisher'." -ForegroundColor Green
        }
        else {
            Write-Host "Integrity check passed: valid Authenticode signature." -ForegroundColor Green
        }
        return $true
    }

    # Signature enforcement explicitly disabled (AllowUnsignedInstaller = $true)
    Write-Host "Integrity check skipped: signature enforcement disabled for this app." -ForegroundColor Yellow
    return $true
}

# Function to download file with progress
function Invoke-FileDownload {
    param(
        [string]$Url,
        [string]$OutputPath,
        [string]$ExpectedSha256,
        [bool]$EnforceSignatureCheck = $true,
        [string]$ExpectedPublisher
    )
    
    Write-Host "Downloading from: $Url" -ForegroundColor Cyan
    Write-Host "To: $(Split-Path $OutputPath)" -ForegroundColor Cyan
    
    try {
        # Download with progress
        $ProgressPreference = 'SilentlyContinue'  # Speeds up download
        Invoke-WebRequest -Uri $Url -OutFile $OutputPath -ErrorAction Stop
        $ProgressPreference = 'Continue'

        # Verify integrity before declaring success
        if (-not (Test-DownloadedFileIntegrity -FilePath $OutputPath -ExpectedSha256 $ExpectedSha256 -EnforceSignatureCheck $EnforceSignatureCheck -ExpectedPublisher $ExpectedPublisher)) {
            Write-Host "Removing unverified download: $(Split-Path $OutputPath -Leaf)" -ForegroundColor Red
            Remove-Item -Path $OutputPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        
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
    
    # Out-Host keeps the tool's output visible without letting it contaminate the return value
    & $IntuneWinUtil $arguments | Out-Host

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
    $IntuneWinMetaData = Get-InteropPackageMetadata -FilePath $IntuneWinPath
    
    # Determine detection method based on config
    if ($appConfig.DetectionFile) {
        # Hybrid MSI: Use file-based detection for auto-update MSI apps (like Chrome)
        # MSI version doesn't reflect actual app version after auto-update
        $detectionOperator = if ($appConfig.DetectionOperator) {
            $appConfig.DetectionOperator
        } else {
            $commonSettings.DetectionOperator
        }
        
        $DetectionRule = New-InteropFileDetectionRule `
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
        $DetectionRule = New-InteropMsiDetectionRule `
            -ProductCode $IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiProductCode
        
        # Use MSI metadata for version
        $fullVersion = $IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiProductVersion
        $useVersion = $fullVersion
    }
    
    # Extract major version for display name (e.g., "142" from "142.0.7444.135")
    $majorVersion = if ($useVersion -match '^(\d+)') { $matches[1] } else { $useVersion }
    
    $DisplayName = $appConfig.DisplayNameTemplate -f $majorVersion
    $Description = $appConfig.Description
    
    $RequirementRule = New-InteropRequirementRule `
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
    
    # Create detection rule based on detection type
    if ($appConfig.DetectionType -eq "Registry") {
        if ($detectionOperator -eq "exists" -or $detectionOperator -eq "doesNotExist" -or $detectionOperator -eq "notExists") {
            if ($detectionOperator -eq "notExists") {
                $detectionOperator = "doesNotExist"
            }
            $existenceParams = @{
                KeyPath              = $appConfig.DetectionPath
                DetectionType        = $detectionOperator
                Check32BitOn64System = $commonSettings.Check32BitOn64System
            }
            if ($appConfig.DetectionValueName) {
                $existenceParams['ValueName'] = $appConfig.DetectionValueName
            }
            $DetectionRule = New-InteropRegistryExistenceDetectionRule @existenceParams
        }
        else {
            $DetectionRule = New-InteropRegistryVersionDetectionRule `
                -KeyPath $appConfig.DetectionPath `
                -ValueName $appConfig.DetectionValueName `
                -Operator $detectionOperator `
                -VersionValue $Version `
                -Check32BitOn64System $commonSettings.Check32BitOn64System
        }
    }
    else {
        # Default: file-based detection
        $DetectionRule = New-InteropFileDetectionRule `
            -Path $appConfig.DetectionPath `
            -FileOrFolder $appConfig.DetectionFile `
            -Check32BitOn64System $commonSettings.Check32BitOn64System `
            -Operator $detectionOperator `
            -VersionValue $Version
    }
    
    $RequirementRule = New-InteropRequirementRule `
        -Architecture $commonSettings.Architecture `
        -MinimumSupportedOperatingSystem $commonSettings.MinimumOS
    
    # Extract major version for display name (e.g., "143" from "143.0.4")
    $majorVersion = if ($Version -match '^(\d+)') { $matches[1] } else { $Version }
    
    # Format display name with major version only, description without version
    $DisplayName = $appConfig.DisplayNameTemplate -f $majorVersion
    $Description = $appConfig.Description
    
    # Format commands - {0} = setup filename, {1} = app version
    $InstallCommand = $appConfig.InstallCommandTemplate -f $SetupFile, $Version
    $UninstallCommand = $appConfig.UninstallCommandTemplate -f $SetupFile, $Version
    
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

# Generic function to create Script-based app configuration (for apps like GeoGebra)
function Get-ScriptAppConfig {
    param(
        [string]$AppName,
        [string]$Version,
        [string]$SetupFile,
        [string]$IntuneWinPath
    )
    
    $appConfig = Get-AppConfiguration -AppName $AppName
    $commonSettings = Get-CommonSettings
    
    # Validate version for EXE apps (required for uninstall command and detection script)
    if ($appConfig.PackageType -eq "EXE") {
        try {
            $null = [version]$Version
        }
        catch {
            throw "Script-detected EXE app '$AppName' requires a valid version number (got '$Version'). " +
                  "Update FallbackVersion in AppConfig.ps1 or ensure the installer filename contains a parseable version."
        }
    }
    
    # Get detection script path
    $scriptPath = Join-Path $PSScriptRoot $appConfig.DetectionScriptPath
    
    if (-not (Test-Path $scriptPath)) {
        Write-Host "  Warning: Detection script not found: $scriptPath" -ForegroundColor Yellow
        Write-Host "  Falling back to MSI detection..." -ForegroundColor Yellow
        
        # Fallback to MSI detection if script doesn't exist
        $IntuneWinMetaData = Get-InteropPackageMetadata -FilePath $IntuneWinPath
        $DetectionRule = New-InteropMsiDetectionRule `
            -ProductCode $IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiProductCode
    }
    else {
        # Read the detection script and inject the required version
        $scriptContent = Get-Content $scriptPath -Raw

        # Replace the param block to inject the actual version
        $scriptWithVersion = $scriptContent -replace 'param\(\s*\[Parameter\(Mandatory=\$true\)\]\s*\[string\]\$RequiredVersion\s*\)', "`$RequiredVersion = '$Version'"

        $DetectionRule = New-InteropScriptDetectionRule `
            -ScriptContent $scriptWithVersion `
            -EnforceSignatureCheck $false `
            -RunAs32Bit $false
    }
    
    $RequirementRule = New-InteropRequirementRule `
        -Architecture $commonSettings.Architecture `
        -MinimumSupportedOperatingSystem $commonSettings.MinimumOS
    
    # Extract major version for display name (e.g., "6" from "6.0.907.0")
    $majorVersion = if ($Version -match '^(\d+)') { $matches[1] } else { $Version }
    
    # Format display name with major version only
    $DisplayName = $appConfig.DisplayNameTemplate -f $majorVersion
    $Description = $appConfig.Description
    
    # Format commands
    $InstallCommand = $appConfig.InstallCommandTemplate -f $SetupFile
    
    # Format uninstall command based on package type
    if ($appConfig.PackageType -eq "MSI" -and $IntuneWinPath) {
        # MSI apps: use product code for uninstall
        $IntuneWinMetaData = Get-InteropPackageMetadata -FilePath $IntuneWinPath
        $UninstallCommand = $appConfig.UninstallCommandTemplate -f $IntuneWinMetaData.ApplicationInfo.MsiInfo.MsiProductCode
    }
    else {
        # EXE apps: use version for uninstall command (e.g., versioned folder paths)
        $UninstallCommand = $appConfig.UninstallCommandTemplate -f $Version
    }
    
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
