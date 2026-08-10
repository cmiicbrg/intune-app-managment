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
