#Requires -Version 7.4

# Tests for the pure-logic helpers in SharedFunctions.ps1: version cache writes,
# existing-package version checks, and download integrity verification.
# Scripts are copied to TestDrive so AppVersions.json writes land in the sandbox,
# never in the repo checkout.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'SharedFunctions.ps1') $workDir
    Copy-Item (Join-Path $repoRoot 'AppConfig.ps1') $workDir
    Copy-Item (Join-Path $repoRoot 'IntuneInterop.ps1') $workDir
    . (Join-Path $workDir 'SharedFunctions.ps1')
    $cachePath = Join-Path $workDir 'AppVersions.json'
}

Describe 'Save-AppVersionCache' {
    BeforeEach {
        Remove-Item $cachePath -ErrorAction SilentlyContinue
    }

    It 'records a new version and returns $true' {
        Save-AppVersionCache -AppName 'Firefox' -Version '143.0.1' -Url 'https://example.test/fx.exe' -Filename 'fx.exe' |
            Should -BeTrue
        $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
        $cache.Apps.Firefox.Version | Should -Be '143.0.1'
        $cache.Apps.Firefox.Url | Should -Be 'https://example.test/fx.exe'
        $cache.Apps.Firefox.Filename | Should -Be 'fx.exe'
        # Raw text, not ConvertFrom-Json: PS7 would coerce the ISO string to [datetime]
        Get-Content $cachePath -Raw | Should -Match '"UpdatedUtc": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
    }

    It 'skips the write and returns $false when nothing changed' {
        Save-AppVersionCache -AppName 'Firefox' -Version '143.0.1' -Url 'u' -Filename 'f' | Should -BeTrue
        Save-AppVersionCache -AppName 'Firefox' -Version '143.0.1' -Url 'u' -Filename 'f' | Should -BeFalse
    }

    It 'refuses to record the "Latest" placeholder version' {
        Save-AppVersionCache -AppName 'GoogleDrive' -Version 'Latest' | Should -BeFalse
        Test-Path $cachePath | Should -BeFalse
    }

    It 'preserves other apps and keeps keys sorted' {
        Save-AppVersionCache -AppName 'Firefox' -Version '143.0.1' -Url 'u1' -Filename 'f1' | Should -BeTrue
        Save-AppVersionCache -AppName 'Audacity' -Version '3.7.8' -Url 'u2' -Filename 'f2' | Should -BeTrue
        $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
        $cache.Apps.Firefox.Version | Should -Be '143.0.1'
        @($cache.Apps.PSObject.Properties.Name) | Should -Be @('Audacity', 'Firefox') -Because 'keys are written sorted for minimal diffs'
    }

    It 'preserves the _comment header of an existing cache file' {
        '{ "_comment": "header text", "Apps": {} }' | Set-Content $cachePath
        Save-AppVersionCache -AppName 'Firefox' -Version '143.0.1' | Should -BeTrue
        (Get-Content $cachePath -Raw | ConvertFrom-Json)._comment | Should -Be 'header text'
    }

    It 'writes the cache file without a UTF-8 BOM' {
        Save-AppVersionCache -AppName 'Firefox' -Version '143.0.1' | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($cachePath)
        $bytes[0] | Should -Not -Be 0xEF
    }
}

Describe 'Test-VersionExists' {
    BeforeAll {
        $appFolder = Join-Path $TestDrive 'packages\firefox'
        New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $appFolder 'Firefox-Setup-143.0.3-de.intunewin') | Out-Null
    }

    It 'returns $false when the folder does not exist' {
        Test-VersionExists -AppFolder (Join-Path $TestDrive 'does-not-exist') -NewVersion '1.0' | Should -BeFalse
    }

    It 'returns $false when the folder has no packages' {
        $empty = Join-Path $TestDrive 'packages\empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        Test-VersionExists -AppFolder $empty -NewVersion '1.0' | Should -BeFalse
    }

    It 'returns $true when an equal version already exists' {
        Test-VersionExists -AppFolder $appFolder -NewVersion '143.0.3' | Should -BeTrue
    }

    It 'returns $true when a newer version already exists' {
        Test-VersionExists -AppFolder $appFolder -NewVersion '143.0.1' | Should -BeTrue
    }

    It 'returns $false when only older versions exist' {
        Test-VersionExists -AppFolder $appFolder -NewVersion '144.0' | Should -BeFalse
    }
}

Describe 'Test-DownloadedFileIntegrity' {
    BeforeAll {
        $testFile = Join-Path $TestDrive 'installer.bin'
        'fixture installer content' | Set-Content $testFile -NoNewline
        $goodHash = (Get-FileHash -Path $testFile -Algorithm SHA256).Hash
    }

    It 'returns $false when the file does not exist' {
        Test-DownloadedFileIntegrity -FilePath (Join-Path $TestDrive 'missing.bin') -ExpectedSha256 $goodHash |
            Should -BeFalse
    }

    It 'passes when the SHA-256 hash matches' {
        Test-DownloadedFileIntegrity -FilePath $testFile -ExpectedSha256 $goodHash | Should -BeTrue
    }

    It 'normalizes lowercase and whitespace in the expected hash' {
        Test-DownloadedFileIntegrity -FilePath $testFile -ExpectedSha256 (" $($goodHash.ToLower()) ") | Should -BeTrue
    }

    It 'fails closed on a SHA-256 mismatch' {
        Test-DownloadedFileIntegrity -FilePath $testFile -ExpectedSha256 ('0' * 64) | Should -BeFalse
    }

    It 'fails closed when the expected hash is not valid hex' {
        Test-DownloadedFileIntegrity -FilePath $testFile -ExpectedSha256 'not-a-hash' | Should -BeFalse
    }

    It 'fails closed for an unsigned file when signature enforcement is on' {
        Test-DownloadedFileIntegrity -FilePath $testFile -EnforceSignatureCheck $true | Should -BeFalse
    }

    It 'passes an unsigned file when signature enforcement is explicitly disabled' {
        Test-DownloadedFileIntegrity -FilePath $testFile -EnforceSignatureCheck $false | Should -BeTrue
    }
}

Describe 'ConvertFrom-WingetInstallerManifest' {
    BeforeAll {
        # Mirrors the real manifest shapes: root-level defaults (7-Zip/Inkscape put Scope
        # there), per-entry keys, and a nested AppsAndFeaturesEntries list whose InstallerType
        # must NOT leak into the installer entry.
        $script:wingetYaml = @'
PackageIdentifier: Fixture.App
PackageVersion: 3.0.10
Scope: machine
Installers:
- Architecture: x86
  InstallerType: wix
  InstallerUrl: https://vendor.example/files/fixture-3.0.10-x86.msi
  InstallerSha256: 1111111111111111111111111111111111111111111111111111111111111111
- Architecture: x64
  InstallerType: wix
  InstallerUrl: https://vendor.example/files/fixture%203.0.10-x64.msi
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  AppsAndFeaturesEntries:
  - DisplayName: Fixture App
    ProductCode: '{AAAAAAAA-0000-0000-0000-000000000000}'
    InstallerType: burn
- Architecture: x64
  InstallerType: nullsoft
  InstallerUrl: https://vendor.example/files/fixture-3.0.10-x64.exe
  InstallerSha256: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
ManifestType: installer
ManifestVersion: 1.6.0
'@
    }

    It 'parses root defaults and every installer entry' {
        $manifest = ConvertFrom-WingetInstallerManifest -Yaml $script:wingetYaml
        $manifest.Defaults['Scope'] | Should -Be 'machine'
        $manifest.Defaults['PackageVersion'] | Should -Be '3.0.10'
        $manifest.Installers.Count | Should -Be 3
    }

    It 'keeps entry keys and ignores nested structures like AppsAndFeaturesEntries' {
        $manifest = ConvertFrom-WingetInstallerManifest -Yaml $script:wingetYaml
        $x64msi = $manifest.Installers | Where-Object { $_['InstallerUrl'] -like '*x64.msi' }
        $x64msi['InstallerType'] | Should -Be 'wix' -Because 'the nested burn InstallerType must not overwrite the entry value'
        $x64msi['InstallerSha256'] | Should -Be ('A' * 64)
    }

    It 'lets installer entries inherit root-level defaults' {
        $yaml = "InstallerType: wix`nInstallers:`n- Architecture: x64`n  InstallerUrl: https://v.example/a.msi`n  InstallerSha256: $('C' * 64)"
        $manifest = ConvertFrom-WingetInstallerManifest -Yaml $yaml
        $manifest.Defaults['InstallerType'] | Should -Be 'wix'
        $manifest.Installers[0].ContainsKey('InstallerType') | Should -BeFalse
    }
}

Describe 'Get-WingetInstallerInfo' {
    BeforeAll {
        $script:wingetListing = @(
            [PSCustomObject]@{ name = '3.0.9'; type = 'dir' },
            [PSCustomObject]@{ name = '3.0.10'; type = 'dir' },
            [PSCustomObject]@{ name = 'Nightly'; type = 'dir' },
            [PSCustomObject]@{ name = '.validation'; type = 'file' }
        )
    }

    BeforeEach {
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://api.github.com/*') { return $script:wingetListing }
            return $script:wingetYaml
        }
    }

    It 'picks the highest version by [version] sort (not string sort) and skips Nightly' {
        $info = Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' -AllowedUrlPrefixes @('https://vendor.example/')
        $info.Version | Should -Be '3.0.10' -Because 'a string sort would rank 3.0.9 above 3.0.10'
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*/3.0.10/Fixture.App.installer.yaml' } -Times 1
    }

    It 'returns the URL, hash and decoded filename of the uniquely matching installer' {
        $info = Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' -AllowedUrlPrefixes @('https://vendor.example/')
        $info.Url | Should -Be 'https://vendor.example/files/fixture%203.0.10-x64.msi'
        $info.Sha256 | Should -Be ('A' * 64)
        $info.Filename | Should -Be 'fixture 3.0.10-x64.msi'
    }

    It 'fails closed without any network call when no allowlist is provided' {
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' | Should -BeNullOrEmpty
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' -AllowedUrlPrefixes @('', '  ') |
            Should -BeNullOrEmpty -Because 'blank-only entries are no allowlist at all'
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'fails closed when the selector matches more than one installer' {
        # x64 without an InstallerType matches both the wix and the nullsoft entry
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -AllowedUrlPrefixes @('https://vendor.example/') | Should -BeNullOrEmpty
    }

    It 'fails closed when the selector matches nothing' {
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -Architecture 'arm64' -AllowedUrlPrefixes @('https://vendor.example/') | Should -BeNullOrEmpty
    }

    It 'refuses an InstallerUrl outside the allowed prefixes' {
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' `
            -AllowedUrlPrefixes @('https://download.othervendor.example/') | Should -BeNullOrEmpty
    }

    It 'accepts an InstallerUrl matching an allowed prefix' {
        $info = Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' `
            -AllowedUrlPrefixes @('https://vendor.example/files/')
        $info.Sha256 | Should -Be ('A' * 64)
    }

    It 'returns $null when the version listing cannot be fetched' {
        Mock Invoke-RestMethod { throw 'API rate limit exceeded' }
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' -AllowedUrlPrefixes @('https://vendor.example/') | Should -BeNullOrEmpty
    }

    It 'builds the manifest path from a multi-segment package id' {
        Get-WingetInstallerInfo -PackageId 'The.Document.Foundation' -InstallerType 'wix' -AllowedUrlPrefixes @('https://vendor.example/') | Out-Null
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*/manifests/t/The/Document/Foundation' } -Times 1
    }

    It 'canonicalizes dot-segment URLs before the allowlist check' {
        # Raw-string StartsWith would pass this URL, but the HTTP client fetches the
        # canonical form, which points outside the allowed prefix
        $dotSegmentYaml = @"
PackageVersion: 3.0.10
Installers:
- Architecture: x64
  InstallerType: wix
  InstallerUrl: https://vendor.example/files/../evil/payload.msi
  InstallerSha256: $('D' * 64)
"@
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://api.github.com/*') { return $script:wingetListing }
            return $dotSegmentYaml
        }
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' `
            -AllowedUrlPrefixes @('https://vendor.example/files/') | Should -BeNullOrEmpty
    }

    It 'returns the canonical URL so the fetch matches what was allowlisted' {
        $info = Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' `
            -AllowedUrlPrefixes @('https://vendor.example/files/')
        $info.Url | Should -Be ([System.Uri]$info.Url).AbsoluteUri
    }

    It 'never lets a blank allowlist entry match every URL' {
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' `
            -AllowedUrlPrefixes @('', 'https://download.othervendor.example/') | Should -BeNullOrEmpty
    }

    It 'fails closed when the manifest declares a different PackageVersion than its directory' {
        $mismatchYaml = @"
PackageVersion: 9.9.9
Installers:
- Architecture: x64
  InstallerType: wix
  InstallerUrl: https://vendor.example/files/old.msi
  InstallerSha256: $('E' * 64)
"@
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://api.github.com/*') { return $script:wingetListing }
            return $mismatchYaml
        }
        Get-WingetInstallerInfo -PackageId 'Fixture.App' -InstallerType 'wix' -AllowedUrlPrefixes @('https://vendor.example/') | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-FileDownload' {
    It 'refuses non-HTTPS URLs before any network call' {
        Mock Invoke-WebRequest { }
        Invoke-FileDownload -Url 'http://vendor.example/app.exe' -OutputPath (Join-Path $TestDrive 'app.exe') |
            Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'deletes the download and returns $false when the pinned SHA-256 does not match' {
        Mock Invoke-WebRequest { Set-Content -Path $OutFile -Value 'tampered payload' -NoNewline }
        $out = Join-Path $TestDrive 'tampered.exe'
        Invoke-FileDownload -Url 'https://vendor.example/app.exe' -OutputPath $out -ExpectedSha256 ('A' * 64) |
            Should -BeFalse
        Test-Path $out | Should -BeFalse -Because 'an unverified download must not stay on disk for packaging'
    }

    It 'removes the partial file when the transfer itself fails' {
        Mock Invoke-WebRequest {
            Set-Content -Path $OutFile -Value 'half a payload' -NoNewline
            throw 'connection reset'
        }
        $out = Join-Path $TestDrive 'partial.exe'
        Invoke-FileDownload -Url 'https://vendor.example/app.exe' -OutputPath $out | Should -BeFalse
        Test-Path $out | Should -BeFalse -Because 'a partial download must not be mistaken for a verified installer later'
    }

    It 'keeps the download and returns $true when the pinned SHA-256 matches' {
        $reference = Join-Path $TestDrive 'reference.bin'
        'known good payload' | Set-Content $reference -NoNewline
        $goodHash = (Get-FileHash -Path $reference -Algorithm SHA256).Hash

        Mock Invoke-WebRequest { Set-Content -Path $OutFile -Value 'known good payload' -NoNewline }
        $out = Join-Path $TestDrive 'good.exe'
        Invoke-FileDownload -Url 'https://vendor.example/app.exe' -OutputPath $out -ExpectedSha256 $goodHash |
            Should -BeTrue
        Test-Path $out | Should -BeTrue
    }
}

# Live check against the real winget repository: every winget-pinned app must resolve to
# exactly one allowlisted installer with a pinned hash. Catches manifest-format drift and
# selector ambiguity early. Network-dependent, so excluded in CI via -ExcludeTag LocalOnly.
Describe 'Get-WingetInstallerInfo (live winget repository)' -Tag 'LocalOnly' {
    It 'resolves a unique, allowlisted installer for every winget-pinned app' {
        $checked = 0
        foreach ($name in (Get-AllAppNames)) {
            $cfg = Get-AppConfiguration -AppName $name
            if (-not $cfg.WingetPackageId) { continue }
            $info = Get-WingetInstallerInfo -PackageId $cfg.WingetPackageId `
                -InstallerType $cfg.WingetInstallerType `
                -AllowedUrlPrefixes $cfg.AllowedDownloadUrlPrefixes
            $info | Should -Not -BeNullOrEmpty -Because "winget resolution must succeed for $name"
            $info.Sha256 | Should -Match '^[0-9A-Fa-f]{64}$'
            $info.Version | Should -Match '^\d'
            $checked++
        }
        $checked | Should -BeGreaterOrEqual 3 -Because '7-Zip, VLC and Inkscape are winget-pinned'
    }
}

Describe 'Get-AppFamilyBaseName' {
    It 'takes the text before the version placeholder from a template' {
        Get-AppFamilyBaseName -DisplayNameTemplate 'Mozilla Firefox {0} (German)' | Should -Be 'Mozilla Firefox'
        Get-AppFamilyBaseName -DisplayNameTemplate '7-Zip {0}' | Should -Be '7-Zip'
    }

    It 'takes the text before the first version number from a display name' {
        Get-AppFamilyBaseName -DisplayName 'Mozilla Firefox 153 (German)' | Should -Be 'Mozilla Firefox'
        Get-AppFamilyBaseName -DisplayName 'Gpg4win 5' | Should -Be 'Gpg4win' -Because 'digits inside a word are not a version'
    }

    It 'agrees between template and rendered display name for every configured app' {
        # This equivalence is what lets Deploy-ToIntune.ps1 (display-name based) and the inventory
        # (template based) identify the same families
        foreach ($name in (Get-AllAppNames)) {
            $template = (Get-AppConfiguration -AppName $name).DisplayNameTemplate
            $rendered = $template -f 42
            (Get-AppFamilyBaseName -DisplayName $rendered) | Should -Be (Get-AppFamilyBaseName -DisplayNameTemplate $template) -Because "template '$template'"
        }
    }
}

Describe 'Get-AppFamilyCatalog / Resolve-AppFamily' {
    BeforeAll {
        $catalog = @(Get-AppFamilyCatalog)
    }

    It 'lists every deployable app in canonical order with label and base name' {
        $catalog.AppConfigName | Should -Be @(Get-AllAppNames)
        $firefox = $catalog | Where-Object AppConfigName -eq 'Firefox'
        $firefox.Name | Should -Be 'Mozilla Firefox (German)'
        $firefox.BaseName | Should -Be 'Mozilla Firefox'
        $firefox.Folder | Should -Be 'firefox'
        $firefox.PackageType | Should -Be 'EXE'
    }

    It 'resolves Intune display names to their families' {
        (Resolve-AppFamily -DisplayName 'Google Chrome 151' -Families $catalog).AppConfigName | Should -Be 'Chrome'
        (Resolve-AppFamily -DisplayName 'Google Drive 129' -Families $catalog).AppConfigName | Should -Be 'GoogleDrive'
        (Resolve-AppFamily -DisplayName 'Google Earth Pro 7' -Families $catalog).AppConfigName | Should -Be 'GoogleEarthPro'
        (Resolve-AppFamily -DisplayName 'mozilla firefox 153 (German)' -Families $catalog).AppConfigName | Should -Be 'Firefox'
    }

    It 'accepts full version numbers, not just the major version this tooling writes' {
        (Resolve-AppFamily -DisplayName 'Mozilla Firefox 145.0.2 (German)' -Families $catalog).AppConfigName | Should -Be 'Firefox'
    }

    It 'returns $null for apps this repository does not manage' {
        Resolve-AppFamily -DisplayName 'Adobe Reader DC' -Families $catalog | Should -BeNullOrEmpty
    }

    It 'requires the version boundary, so unrelated apps sharing a base name are not claimed' {
        # A plain prefix match would make these deletion candidates of the Chrome / Firefox families
        Resolve-AppFamily -DisplayName 'Google Chrome Remote Desktop 2.0' -Families $catalog | Should -BeNullOrEmpty
        Resolve-AppFamily -DisplayName 'Google Chrome Enterprise 100' -Families $catalog | Should -BeNullOrEmpty
        Resolve-AppFamily -DisplayName 'Mozilla Firefox 153 (English)' -Families $catalog | Should -BeNullOrEmpty -Because 'the suffix is part of the convention'
        Resolve-AppFamily -DisplayName 'Mozilla Firefox 153' -Families $catalog | Should -BeNullOrEmpty -Because 'the German family requires its suffix'
    }

    It 'treats a hand-deployed app without a version in its name as unmanaged' {
        Resolve-AppFamily -DisplayName 'Google Chrome' -Families $catalog | Should -BeNullOrEmpty
        Resolve-AppFamily -DisplayName '7-Zip' -Families $catalog | Should -BeNullOrEmpty
    }

    It 'prefers the longest matching base name when patterns overlap' {
        $families = @(
            [PSCustomObject]@{ AppConfigName = 'Short'; BaseName = 'Google Drive'; NamePattern = (Get-AppFamilyNamePattern -DisplayNameTemplate 'Google Drive {0}') },
            [PSCustomObject]@{ AppConfigName = 'Long'; BaseName = 'Google Drive Enterprise'; NamePattern = (Get-AppFamilyNamePattern -DisplayNameTemplate 'Google Drive Enterprise {0}') }
        )
        (Resolve-AppFamily -DisplayName 'Google Drive Enterprise 3' -Families $families).AppConfigName | Should -Be 'Long'
        (Resolve-AppFamily -DisplayName 'Google Drive 129' -Families $families).AppConfigName | Should -Be 'Short'
    }
}

Describe 'Get-AppFamilyNamePattern' {
    It 'builds base + version + suffix from a template' {
        $pattern = Get-AppFamilyNamePattern -DisplayNameTemplate 'Mozilla Firefox {0} (German)'
        'Mozilla Firefox 153 (German)' | Should -Match $pattern
        'Mozilla Firefox 153.0.4 (German)' | Should -Match $pattern
        'Mozilla Firefox 153 (German) Beta' | Should -Not -Match $pattern
        'Mozilla Firefox (German)' | Should -Not -Match $pattern
    }

    It 'escapes regex metacharacters in the template' {
        $pattern = Get-AppFamilyNamePattern -DisplayNameTemplate 'Notepad++ {0}'
        'Notepad++ 8' | Should -Match $pattern
        'Notepad 8' | Should -Not -Match $pattern
        (Get-AppFamilyNamePattern -DisplayNameTemplate 'Visual C++ Redistributable {0}') | Should -Match '\\\+\\\+'
    }

    It 'matches the display names this tooling generates for every configured app' {
        foreach ($name in (Get-AllAppNames)) {
            $template = (Get-AppConfiguration -AppName $name).DisplayNameTemplate
            ($template -f 42) | Should -Match (Get-AppFamilyNamePattern -DisplayNameTemplate $template) -Because "template '$template'"
        }
    }

    It 'falls back to an exact match for a template without a version placeholder' {
        $pattern = Get-AppFamilyNamePattern -DisplayNameTemplate 'Some Tool'
        'Some Tool' | Should -Match $pattern
        'Some Tool 2' | Should -Not -Match $pattern
    }
}

Describe 'Get-IntuneAppVersion' {
    It 'prefers displayVersion' {
        $info = Get-IntuneAppVersion -App ([PSCustomObject]@{ displayName = 'Google Chrome 151'; displayVersion = '151.0.7922.109' })
        $info.Raw | Should -Be '151.0.7922.109'
        $info.Version | Should -Be ([version]'151.0.7922.109')
        $info.Source | Should -Be 'displayVersion'
    }

    It 'accepts an inventory record (PascalCase properties) as well as a raw Graph app' {
        # Deploy-ToIntune hands Publish-App inventory records (ConvertTo-AppInventoryRecord:
        # DisplayName/DisplayVersion/Id); property access is case-insensitive in PowerShell, and
        # this pins that the version helper - and therefore the existing-version detection and
        # supersedence target - works on that shape
        $info = Get-IntuneAppVersion -App ([PSCustomObject]@{ Id = 'app-1'; DisplayName = 'Google Chrome 151'; DisplayVersion = '151.0.7922.109' })
        $info.Version | Should -Be ([version]'151.0.7922.109')
        $info.Source | Should -Be 'displayVersion'
        (Get-IntuneAppVersion -App ([PSCustomObject]@{ Id = 'app-2'; DisplayName = 'Some App 2.5.1'; DisplayVersion = $null })).Version | Should -Be ([version]'2.5.1')
    }

    It 'falls back to the first dotted number in the display name' {
        $info = Get-IntuneAppVersion -App ([PSCustomObject]@{ displayName = 'Some App 2.5.1 (x64)'; displayVersion = '' })
        $info.Raw | Should -Be '2.5.1'
        $info.Version | Should -Be ([version]'2.5.1')
        $info.Source | Should -Be 'displayName'
    }

    It 'returns $null when there is no version anywhere' {
        Get-IntuneAppVersion -App ([PSCustomObject]@{ displayName = 'Some App'; displayVersion = $null }) | Should -BeNullOrEmpty
    }

    It 'keeps Raw but leaves Version $null for values that are not a [version]' {
        $info = Get-IntuneAppVersion -App ([PSCustomObject]@{ displayName = '7-Zip 26'; displayVersion = 'Latest' })
        $info.Raw | Should -Be 'Latest'
        $info.Version | Should -BeNullOrEmpty
        $bare = Get-IntuneAppVersion -App ([PSCustomObject]@{ displayName = 'Notepad++ 8'; displayVersion = '' })
        $bare.Raw | Should -Be '8'
        $bare.Version | Should -BeNullOrEmpty -Because 'a bare major number is not a [version]'
    }

    It 'takes the FIRST number in the name (pre-existing Deploy-ToIntune behaviour, kept for parity)' {
        # "7-Zip 26" yields "7", not "26". Apps deployed by this repository always carry displayVersion,
        # so the fallback is only reached for foreign or very old apps; the quirk is pinned here so a
        # future change to it is a deliberate one.
        (Get-IntuneAppVersion -App ([PSCustomObject]@{ displayName = '7-Zip 26'; displayVersion = '' })).Raw | Should -Be '7'
    }
}

# These execute against real installer binaries in packages/, which are not in git.
# They run on a workstation with downloaded packages and are excluded in CI via -ExcludeTag LocalOnly.
Describe 'Get-InstallerVersion (real installers)' -Tag 'LocalOnly' {
    BeforeDiscovery {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $msi = Get-ChildItem (Join-Path $repoRoot 'packages\7zip') -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
        $exe = Get-ChildItem (Join-Path $repoRoot 'packages\gimp') -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    It 'extracts the version from an MSI via the WindowsInstaller COM object' -Skip:($null -eq $msi) -ForEach @(@{ InstallerPath = $msi.FullName }) {
        Get-InstallerVersion -FilePath $InstallerPath | Should -Match '^\d+\.\d+'
    }

    It 'extracts the version from an EXE via Get-AppLockerFileInformation' -Skip:($null -eq $exe) -ForEach @(@{ InstallerPath = $exe.FullName }) {
        Get-InstallerVersion -FilePath $InstallerPath | Should -Match '^\d+\.\d+'
    }
}
