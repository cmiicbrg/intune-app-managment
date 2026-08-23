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
# Regex that an Intune display name must match to count as a member of the family described by
# an AppConfig DisplayNameTemplate: the base name, whitespace, a version number, and the template's
# suffix (if any) - e.g. "Mozilla Firefox {0} (German)" -> ^Mozilla\ Firefox\s+\d+(?:\.\d+)*\s+\(German\)$
#
# The version boundary is what keeps unrelated apps out: with a plain prefix match, "Google Chrome
# Remote Desktop 2.0" would be a Chrome version, and since family membership feeds the retention
# cleanup, that would make an unrelated app a deletion candidate. Apps that share a base name but
# do not follow the convention (a bare "Google Chrome", or a differently suffixed variant) are
# simply not managed by this tooling; renaming them to the template brings them under management.
function Get-AppFamilyNamePattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayNameTemplate
    )

    $index = $DisplayNameTemplate.IndexOf('{0}')
    if ($index -lt 0) {
        return '^' + [regex]::Escape($DisplayNameTemplate.Trim()) + '$'
    }

    $prefix = $DisplayNameTemplate.Substring(0, $index).TrimEnd()
    $suffix = $DisplayNameTemplate.Substring($index + 3).TrimStart()

    $pattern = '^' + [regex]::Escape($prefix) + '\s+\d+(?:\.\d+)*'
    if ($suffix) {
        $pattern += '\s+' + [regex]::Escape($suffix)
    }
    return $pattern + '$'
}

# One entry per AppConfig app that has a package folder and pattern - the deployable set.
# Returned in canonical app-name order (Get-AllAppNames), which is also the order Deploy-ToIntune.ps1
# processes apps in.
#   AppConfigName - key in AppConfig.ps1 (e.g. "Firefox")
#   Name          - display label, template without the version placeholder (e.g. "Mozilla Firefox (German)")
#   BaseName      - family prefix (e.g. "Mozilla Firefox")
#   NamePattern   - regex a display name must match to belong to the family (Get-AppFamilyNamePattern)
function Get-AppFamilyCatalog {
    $families = @()
    foreach ($appConfigName in (Get-AllAppNames)) {
        $cfg = Get-AppConfiguration -AppName $appConfigName
        if ($cfg -and $cfg.Folder -and $cfg.IntuneWinPattern) {
            $families += [PSCustomObject]@{
                AppConfigName = $appConfigName
                Name          = ($cfg.DisplayNameTemplate -replace '\s*\{0\}', '').Trim()
                BaseName      = Get-AppFamilyBaseName -DisplayNameTemplate $cfg.DisplayNameTemplate
                NamePattern   = Get-AppFamilyNamePattern -DisplayNameTemplate $cfg.DisplayNameTemplate
                Folder        = $cfg.Folder
                Pattern       = $cfg.IntuneWinPattern
                PackageType   = $cfg.PackageType
            }
        }
    }
    return $families
}

# Maps an Intune display name to the family it belongs to: the name must match the family's
# naming convention (NamePattern - base name, version, suffix), not merely start with the base
# name. Longer base names are tried first for deterministic tie-breaking. Returns $null for apps
# this repository does not manage - including same-family apps deployed by hand under a name
# that does not follow the convention.
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
        if ($DisplayName -match $family.NamePattern) {
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

# Minimal parser for winget installer manifests (<PackageId>.installer.yaml).
# Full YAML is deliberately out of scope: only the flat "Key: value" fields this pipeline
# consumes are read, and only at the two indent levels winget manifests actually use
# (root-level defaults and two-space-indented keys inside "- " installer entries).
# Anything else - nested lists, block scalars, unknown keys - is ignored.
function ConvertFrom-WingetInstallerManifest {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Yaml
    )

    # The only keys the resolver consumes; everything else is noise
    $wantedKeys = @('PackageVersion', 'Architecture', 'InstallerType', 'Scope', 'InstallerUrl', 'InstallerSha256')

    $defaults = @{}
    $installers = @()
    $current = $null

    foreach ($line in ($Yaml -split "`r?`n")) {
        if ($line -match '^\s*#') { continue }

        if ($line -match '^- ([A-Za-z][A-Za-z0-9]*):\s*(.*?)\s*$') {
            # New installer entry
            if ($current) { $installers += $current }
            $current = @{}
            $key = $matches[1]; $value = $matches[2].Trim("'`"")
            if ($key -in $wantedKeys -and $value) { $current[$key] = $value }
        }
        elseif ($current -and $line -match '^  ([A-Za-z][A-Za-z0-9]*):\s*(.*?)\s*$') {
            # Key inside the current installer entry (exactly two spaces - deeper
            # indents belong to nested structures like AppsAndFeaturesEntries)
            $key = $matches[1]; $value = $matches[2].Trim("'`"")
            if ($key -in $wantedKeys -and $value -and -not $current.ContainsKey($key)) { $current[$key] = $value }
        }
        elseif ($line -match '^([A-Za-z][A-Za-z0-9]*):\s*(.*?)\s*$') {
            # Root-level key: a default that installer entries inherit
            if ($current) { $installers += $current; $current = $null }
            $key = $matches[1]; $value = $matches[2].Trim("'`"")
            if ($key -in $wantedKeys -and $value) { $defaults[$key] = $value }
        }
    }
    if ($current) { $installers += $current }

    return @{ Defaults = $defaults; Installers = $installers }
}

# Resolves the latest version, download URL and SHA-256 of a package from the community
# winget repository (microsoft/winget-pkgs). Used for vendors that do not Authenticode-sign
# their installers: the manifest hash - independently verified by Microsoft's validation
# pipeline before merge - replaces the signature check.
#
# Fails closed: any ambiguity (no manifest, zero or multiple matching installer entries,
# a download URL outside AllowedUrlPrefixes, an API error) returns $null, which callers
# treat as "skip this app for this run". Deliberately never falls back to an unverified URL.
function Get-WingetInstallerInfo {
    param(
        # Winget package identifier, e.g. "VideoLAN.VLC"
        [Parameter(Mandatory=$true)]
        [string]$PackageId,

        [string]$Architecture = 'x64',

        # Winget installer type to select (e.g. "wix", "nullsoft"); required whenever a
        # package publishes more than one installer per architecture
        [string]$InstallerType,

        # The manifest's InstallerUrl must start with one of these, so a malicious manifest
        # cannot redirect downloads away from the vendor's own infrastructure
        [string[]]$AllowedUrlPrefixes
    )

    $idPath = ($PackageId -split '\.') -join '/'
    $letter = $PackageId.Substring(0, 1).ToLowerInvariant()
    $manifestRoot = "manifests/$letter/$idPath"

    # Latest version = highest directory name that parses as [version]; tags like "Nightly" are skipped
    try {
        $listing = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-pkgs/contents/$manifestRoot" -ErrorAction Stop
    }
    catch {
        Write-Host "Winget lookup FAILED: could not list versions for '$PackageId': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $versions = foreach ($item in $listing) {
        if ($item.type -ne 'dir') { continue }
        $parsed = $null
        if ([version]::TryParse($item.name, [ref]$parsed)) {
            [PSCustomObject]@{ Name = $item.name; Version = $parsed }
        }
    }
    $latest = $versions | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Host "Winget lookup FAILED: no parseable versions found for '$PackageId'" -ForegroundColor Red
        return $null
    }

    try {
        $yaml = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/$manifestRoot/$($latest.Name)/$PackageId.installer.yaml" -ErrorAction Stop
    }
    catch {
        Write-Host "Winget lookup FAILED: could not fetch installer manifest for '$PackageId' $($latest.Name): $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $manifest = ConvertFrom-WingetInstallerManifest -Yaml $yaml

    # The manifest must describe the version whose directory it lives in - a disagreement
    # means a raced listing or a manipulated manifest, and either way the bundle is not
    # the "version + URL + hash" unit we claim to verify
    $declaredVersion = $manifest.Defaults['PackageVersion']
    if ($declaredVersion -and $declaredVersion -ne $latest.Name) {
        Write-Host "Winget lookup FAILED: manifest in directory '$($latest.Name)' declares PackageVersion '$declaredVersion' for '$PackageId'" -ForegroundColor Red
        return $null
    }

    $candidates = @($manifest.Installers | Where-Object {
        $arch = if ($_.ContainsKey('Architecture')) { $_.Architecture } else { $manifest.Defaults['Architecture'] }
        $type = if ($_.ContainsKey('InstallerType')) { $_.InstallerType } else { $manifest.Defaults['InstallerType'] }
        ($arch -eq $Architecture) -and (-not $InstallerType -or $type -eq $InstallerType)
    })

    if ($candidates.Count -ne 1) {
        Write-Host "Winget lookup FAILED: expected exactly 1 installer entry for '$PackageId' $($latest.Name) ($Architecture/$InstallerType), found $($candidates.Count)" -ForegroundColor Red
        return $null
    }

    $url = $candidates[0]['InstallerUrl']
    $sha256 = $candidates[0]['InstallerSha256']
    if (-not $url -or -not $sha256) {
        Write-Host "Winget lookup FAILED: installer entry for '$PackageId' $($latest.Name) is missing InstallerUrl or InstallerSha256" -ForegroundColor Red
        return $null
    }

    # Canonicalize before the allowlist check and use the canonical form from here on:
    # System.Uri compacts dot segments (escaped or not), so a raw-string prefix match on
    # "https://host/allowed/../attacker/..." would pass while the request actually goes
    # elsewhere. The canonical AbsoluteUri is what the HTTP client will really fetch.
    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -ne 'https') {
        Write-Host "Winget lookup REFUSED: InstallerUrl for '$PackageId' $($latest.Name) is not a valid HTTPS URL" -ForegroundColor Red
        Write-Host "  URL: $url" -ForegroundColor Red
        return $null
    }
    $canonicalUrl = $parsedUri.AbsoluteUri

    if ($AllowedUrlPrefixes) {
        $allowed = $false
        foreach ($prefix in $AllowedUrlPrefixes) {
            if ([string]::IsNullOrWhiteSpace($prefix)) { continue }  # never let a blank entry match everything
            if ($canonicalUrl.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
        }
        if (-not $allowed) {
            Write-Host "Winget lookup REFUSED: InstallerUrl for '$PackageId' $($latest.Name) is outside the allowed prefixes" -ForegroundColor Red
            Write-Host "  URL (canonical): $canonicalUrl" -ForegroundColor Red
            return $null
        }
    }

    $filename = [System.Uri]::UnescapeDataString($parsedUri.Segments[-1])
    Write-Host "Winget manifest resolved: $PackageId $($latest.Name) (SHA-256 pinned)" -ForegroundColor Green

    return [PSCustomObject]@{
        Version  = $latest.Name
        Url      = $canonicalUrl
        Sha256   = $sha256
        Filename = $filename
    }
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
    
    # Installers only ever come from HTTPS endpoints - fail before touching the network
    if (-not $Url.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "Download REFUSED: only HTTPS URLs are allowed ($Url)" -ForegroundColor Red
        return $false
    }

    Write-Host "Downloading from: $Url" -ForegroundColor Cyan
    Write-Host "To: $(Split-Path $OutputPath)" -ForegroundColor Cyan

    try {
        # Suppressing progress rendering speeds up Invoke-WebRequest considerably;
        # restored in finally so a thrown transfer cannot leak the setting
        $previousProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutputPath -ErrorAction Stop
        }
        finally {
            $ProgressPreference = $previousProgressPreference
        }

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
        # A failed transfer can leave a partial file at the target path; remove it so a
        # later run cannot mistake it for a previously verified installer
        if (Test-Path $OutputPath) {
            Write-Host "Removing partial download: $(Split-Path $OutputPath -Leaf)" -ForegroundColor Red
            Remove-Item -Path $OutputPath -Force -ErrorAction SilentlyContinue
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
