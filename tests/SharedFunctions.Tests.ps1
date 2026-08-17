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
