#Requires -Version 7.4

# Builder of the McAfee removal package (AppConfig.ps1: McAfeeRemoval, PackageBuilder).
# Dot-sourced by Download-And-Package-Software.ps1 after SharedFunctions.ps1.
#
# Every other app in this repository is one vendor installer that is downloaded, verified and
# wrapped. This package is assembled instead:
#
#   packages\mcafee-removal\Remove-McAfee.ps1          the removal script (install command)
#   packages\mcafee-removal\Detect-McAfeeRemoval.ps1   detection rule, also used by the script
#   MCPR\                                              McAfee's Consumer Product Removal tool,
#                                                      unpacked, with the engine exchanged
#
# The two McAfee ingredients and why there are two:
#
#   1. MCPR.exe, the official download. It carries the removal recipes for every McAfee consumer
#      product, but it is an NSIS self-extractor that only starts an interactive wizard (licence
#      text, CAPTCHA). 7-Zip unpacks it without running it.
#   2. The engine inside it, mccleanup.exe, validates its parent process since build 10.5 and
#      ends at once unless that wizard started it - a script gets nothing removed. Build
#      10.4.123.0 is the last one that runs unattended. McAfee no longer offers it for download,
#      so it is taken from community archives and accepted only if it is byte-for-byte the pinned
#      file AND carries McAfee's valid signature.
#
# Both ingredients are pinned by SHA-256 in AppConfig.ps1 and additionally checked for McAfee's
# Authenticode signature. The verified files are kept in the package folder (git-ignored) and
# re-verified on every build, so a build does not depend on the mirrors staying online.

# 7-Zip's command line program, or $null when 7-Zip is not installed.
function Find-SevenZip {
    $command = Get-Command '7z.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }) {
        $candidate = Join-Path $root '7-Zip\7z.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

# The package version declared in Remove-McAfee.ps1 ($script:McAfeeRemovalVersion), or $null when
# the script does not declare a parseable one. The script is the single place the version lives,
# so that whoever changes it has the number in front of them.
function Get-McAfeeRemovalPackageVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) { return $null }

    $content = Get-Content -LiteralPath $ScriptPath -Raw
    if ($content -notmatch '(?m)^\$script:McAfeeRemovalVersion\s*=\s*''(\d+(?:\.\d+){1,3})''') { return $null }
    return $matches[1]
}

# A McAfee ingredient is accepted only when it matches its SHA-256 pin and carries a valid
# Authenticode signature of the expected publisher. The pin alone would do for integrity; the
# signature states where the file comes from, which matters for the engine fetched from a mirror.
function Test-McAfeeRemovalIngredient {
    param(
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [Parameter(Mandatory = $true)] [string]$Sha256,
        [Parameter(Mandatory = $true)] [string]$ExpectedPublisher
    )

    if (-not (Test-FileSha256 -FilePath $FilePath -ExpectedSha256 $Sha256)) { return $false }
    return (Test-FileAuthenticodeSignature -FilePath $FilePath -ExpectedPublisher $ExpectedPublisher)
}

# The verified official MCPR.exe in the package folder (downloaded when it is not there yet), or
# $null when no file matching the pin could be had.
function Get-McAfeeRemovalTool {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$AppConfig,
        [Parameter(Mandatory = $true)] [string]$AppFolder
    )

    $path = Join-Path $AppFolder "MCPR-$($AppConfig.McprVersion).exe"

    if (Test-Path -LiteralPath $path) {
        Write-Host "  Verifying $(Split-Path $path -Leaf)..." -ForegroundColor Gray
        if (Test-McAfeeRemovalIngredient -FilePath $path -Sha256 $AppConfig.McprSha256 -ExpectedPublisher $AppConfig.ExpectedPublisher) {
            return $path
        }
        Write-Host "  Stored copy failed verification - downloading it again" -ForegroundColor Yellow
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Downloading McAfee's removal tool (MCPR $($AppConfig.McprVersion))..." -ForegroundColor Cyan
    if (-not (Invoke-FileDownload -Url $AppConfig.McprUrl -OutputPath $path -ExpectedSha256 $AppConfig.McprSha256)) {
        Write-Host "  MCPR could not be downloaded, or the download is not the pinned build $($AppConfig.McprVersion)." -ForegroundColor Red
        Write-Host "  If McAfee has published a new build: review it, then update McprVersion and McprSha256 in AppConfig.ps1" -ForegroundColor Yellow
        Write-Host "  and raise the package version in Remove-McAfee.ps1." -ForegroundColor Yellow
        return $null
    }
    if (-not (Test-FileAuthenticodeSignature -FilePath $path -ExpectedPublisher $AppConfig.ExpectedPublisher)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $path
}

# Looks through a zip archive for a file with the given name and exactly the pinned content, and
# writes it to $Destination. Returns $false when the archive holds no such file. Reads the
# archive entry by entry and only ever writes to $Destination, so the layout (or a hostile path)
# inside the archive is irrelevant.
function Save-ZipEntryMatchingHash {
    param(
        [Parameter(Mandatory = $true)] [string]$ArchivePath,
        [Parameter(Mandatory = $true)] [string]$EntryName,
        [Parameter(Mandatory = $true)] [string]$Sha256,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $candidatePath = "$Destination.candidate"
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in @($archive.Entries | Where-Object { $_.Name -ieq $EntryName })) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $candidatePath, $true)
            if ((Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash -eq $Sha256.ToUpperInvariant()) {
                Move-Item -LiteralPath $candidatePath -Destination $Destination -Force
                return $true
            }
        }
        return $false
    }
    finally {
        $archive.Dispose()
        Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
    }
}

# Fetches the pinned engine out of one community archive. $false when the archive cannot be
# downloaded or does not contain the pinned file.
function Save-McAfeeRemovalEngineFromArchive {
    param(
        [Parameter(Mandatory = $true)] [string]$Url,
        [Parameter(Mandatory = $true)] [string]$Sha256,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    if (-not $Url.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "  Download REFUSED: only HTTPS URLs are allowed ($Url)" -ForegroundColor Red
        return $false
    }

    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) "mcpr-engine-$([guid]::NewGuid().ToString('N')).zip"
    Write-Host "  Fetching the engine from: $Url" -ForegroundColor Cyan
    try {
        $previousProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $archivePath -ErrorAction Stop
        }
        finally {
            $ProgressPreference = $previousProgressPreference
        }

        if (Save-ZipEntryMatchingHash -ArchivePath $archivePath -EntryName 'mccleanup.exe' -Sha256 $Sha256 -Destination $Destination) {
            return $true
        }
        Write-Host "  That archive does not contain the pinned engine" -ForegroundColor Yellow
        return $false
    }
    catch {
        Write-Host "  Could not use that archive: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    finally {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    }
}

# The verified unattended engine in the package folder (fetched from the community archives when
# it is not there yet), or $null. A copy placed there by hand is accepted on the same terms: it
# has to match the pin and carry McAfee's signature.
function Get-McAfeeRemovalEngine {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$AppConfig,
        [Parameter(Mandatory = $true)] [string]$AppFolder
    )

    $path = Join-Path $AppFolder "mccleanup-$($AppConfig.McprEngineVersion).exe"

    if (Test-Path -LiteralPath $path) {
        Write-Host "  Verifying $(Split-Path $path -Leaf)..." -ForegroundColor Gray
        if (Test-McAfeeRemovalIngredient -FilePath $path -Sha256 $AppConfig.McprEngineSha256 -ExpectedPublisher $AppConfig.ExpectedPublisher) {
            return $path
        }
        Write-Host "  Stored copy failed verification - fetching it again" -ForegroundColor Yellow
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    foreach ($url in @($AppConfig.McprEngineArchiveUrls)) {
        if (Save-McAfeeRemovalEngineFromArchive -Url $url -Sha256 $AppConfig.McprEngineSha256 -Destination $path) {
            break
        }
    }

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "  The unattended MCPR engine $($AppConfig.McprEngineVersion) could not be fetched from any configured archive." -ForegroundColor Red
        Write-Host "  If you have that mccleanup.exe from elsewhere, save it as:" -ForegroundColor Yellow
        Write-Host "    $path" -ForegroundColor Yellow
        Write-Host "  It is only accepted with SHA-256 $($AppConfig.McprEngineSha256) and McAfee's signature." -ForegroundColor Yellow
        return $null
    }

    if (-not (Test-McAfeeRemovalIngredient -FilePath $path -Sha256 $AppConfig.McprEngineSha256 -ExpectedPublisher $AppConfig.ExpectedPublisher)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $path
}

# Unpacks MCPR.exe with 7-Zip (nothing of it is executed) and copies the tool's folder - the one
# holding master.ini next to mccleanup.exe - to $Destination. $false when 7-Zip fails or the
# archive does not look like MCPR any more.
function Expand-McAfeeRemovalTool {
    param(
        [Parameter(Mandatory = $true)] [string]$InstallerPath,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [Parameter(Mandatory = $true)] [string]$SevenZipPath
    )

    $extractPath = Join-Path ([System.IO.Path]::GetTempPath()) "mcpr-extract-$([guid]::NewGuid().ToString('N'))"
    try {
        & $SevenZipPath x $InstallerPath "-o$extractPath" -y -bso0 -bsp0 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  7-Zip could not unpack $(Split-Path $InstallerPath -Leaf) (exit code $LASTEXITCODE)" -ForegroundColor Red
            return $false
        }

        $marker = Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter 'master.ini' |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'mccleanup.exe') } |
            Sort-Object { $_.FullName.Length } |
            Select-Object -First 1
        if (-not $marker) {
            Write-Host "  The unpacked MCPR has no folder with master.ini and mccleanup.exe - its layout has changed" -ForegroundColor Red
            return $false
        }

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Get-ChildItem -LiteralPath $marker.DirectoryName -Force | Copy-Item -Destination $Destination -Recurse -Force
        return $true
    }
    finally {
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Builds packages\mcafee-removal\McAfeeRemoval-<version>.intunewin. Returns $true when a package
# was built, $false when it was skipped (already built) or could not be built - the reason is
# printed either way.
function New-McAfeeRemovalPackage {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$AppConfig,
        [Parameter(Mandatory = $true)] [string]$AppFolder
    )

    $setupFile = 'Remove-McAfee.ps1'
    $detectionFile = Split-Path $AppConfig.DetectionScriptPath -Leaf
    foreach ($file in $setupFile, $detectionFile) {
        if (-not (Test-Path -LiteralPath (Join-Path $AppFolder $file))) {
            Write-Host "  Skipping - $file is missing in $AppFolder" -ForegroundColor Red
            return $false
        }
    }

    $version = Get-McAfeeRemovalPackageVersion -ScriptPath (Join-Path $AppFolder $setupFile)
    if (-not $version) {
        Write-Host "  Skipping - $setupFile declares no package version (`$script:McAfeeRemovalVersion = 'x.y.z')" -ForegroundColor Red
        return $false
    }
    Write-Host "  Package version: $version" -ForegroundColor Cyan

    $packagePath = Join-Path $AppFolder ($AppConfig.IntuneWinPattern -replace '\*', $version)
    if (Test-Path -LiteralPath $packagePath) {
        Write-Host "  Skipping - version $version is already packaged" -ForegroundColor Yellow
        Write-Host "  (changed a script or a pin? Raise `$script:McAfeeRemovalVersion in $setupFile so the change is rolled out)" -ForegroundColor Gray
        return $false
    }

    $sevenZip = Find-SevenZip
    if (-not $sevenZip) {
        Write-Host "  Skipping - 7-Zip is needed to unpack McAfee's removal tool: winget install --id 7zip.7zip" -ForegroundColor Red
        return $false
    }

    $tool = Get-McAfeeRemovalTool -AppConfig $AppConfig -AppFolder $AppFolder
    if (-not $tool) { return $false }
    $engine = Get-McAfeeRemovalEngine -AppConfig $AppConfig -AppFolder $AppFolder
    if (-not $engine) { return $false }

    # Assembled in a scratch folder, so the package holds exactly the payload and none of the
    # stored ingredients, older packages or other files of the package folder
    $stagePath = Join-Path ([System.IO.Path]::GetTempPath()) "mcafee-removal-$([guid]::NewGuid().ToString('N'))"
    $payloadPath = Join-Path $stagePath 'payload'
    $outputPath = Join-Path $stagePath 'output'
    $toolPath = Join-Path $payloadPath 'MCPR'
    try {
        New-Item -ItemType Directory -Path $payloadPath, $outputPath -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $AppFolder $setupFile), (Join-Path $AppFolder $detectionFile) -Destination $payloadPath

        Write-Host "  Unpacking MCPR $($AppConfig.McprVersion)..." -ForegroundColor Cyan
        if (-not (Expand-McAfeeRemovalTool -InstallerPath $tool -Destination $toolPath -SevenZipPath $sevenZip)) {
            return $false
        }

        Write-Host "  Exchanging the engine for build $($AppConfig.McprEngineVersion) (runs unattended)..." -ForegroundColor Cyan
        $packagedEngine = Join-Path $toolPath 'mccleanup.exe'
        Copy-Item -LiteralPath $engine -Destination $packagedEngine -Force
        if (-not (Test-FileSha256 -FilePath $packagedEngine -ExpectedSha256 $AppConfig.McprEngineSha256)) {
            return $false
        }

        $payloadFiles = @(Get-ChildItem -LiteralPath $payloadPath -Recurse -File)
        Write-Host "  Payload: $($payloadFiles.Count) files, $([math]::Round(($payloadFiles | Measure-Object Length -Sum).Sum / 1MB, 1)) MB" -ForegroundColor Gray

        if (-not (New-IntuneWinPackage -SourceFolder $payloadPath -SetupFile $setupFile -OutputFolder $outputPath)) {
            return $false
        }
        $builtPackage = Join-Path $outputPath ([System.IO.Path]::ChangeExtension($setupFile, '.intunewin'))
        if (-not (Test-Path -LiteralPath $builtPackage)) {
            Write-Host "  IntuneWinAppUtil reported success but wrote no package" -ForegroundColor Red
            return $false
        }

        # Like every other app: one package per folder, the newest
        Get-ChildItem -LiteralPath $AppFolder -File -Filter $AppConfig.IntuneWinPattern | Remove-Item -Force
        Move-Item -LiteralPath $builtPackage -Destination $packagePath -Force
        Write-Host "  Package ready: $packagePath" -ForegroundColor Green
        return $true
    }
    finally {
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
