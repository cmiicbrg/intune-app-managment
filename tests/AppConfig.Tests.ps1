#Requires -Version 7.4

# Golden-config guard: characterizes the exact detection/requirement rule shapes and
# command lines that Get-MsiAppConfig / Get-FileAppConfig / Get-ScriptAppConfig produce
# for one representative app per detection type. These tests pin the contract that the
# issue #8 interop refactor (and later the #9 native Graph migration) must preserve.
#
# Requires the IntuneWin32App module (rule builders are executed for real).
# Get-IntuneWin32AppMetaData is mocked so no .intunewin fixture binaries are needed.

BeforeAll {
    Import-Module IntuneWin32App -ErrorAction Stop

    # Copy the scripts to TestDrive so $PSScriptRoot-derived paths (AppVersions.json,
    # detection scripts) resolve inside the sandbox, and skip the version-cache overlay
    # so FallbackVersion values stay at their deterministic seeds.
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path (Join-Path $workDir 'packages\geogebra') -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'SharedFunctions.ps1') $workDir
    Copy-Item (Join-Path $repoRoot 'AppConfig.ps1') $workDir
    Copy-Item (Join-Path $repoRoot 'packages\geogebra\Detect-GeoGebraVersion.ps1') (Join-Path $workDir 'packages\geogebra')
    . (Join-Path $workDir 'SharedFunctions.ps1')

    $mockProductCode = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0000}'

    # Get-IntuneWin32AppMetaData validates that -FilePath exists even when mocked
    # (Pester mock proxies keep parameter validation), so provide a real empty file.
    $dummyIntuneWin = Join-Path $TestDrive 'dummy.intunewin'
    New-Item -ItemType File -Path $dummyIntuneWin -Force | Out-Null
}

Describe 'App config generation (golden guard for issue #8/#9 refactors)' {
    BeforeAll {
        Mock Get-IntuneWin32AppMetaData {
            [xml]@"
<ApplicationInfo>
  <SetupFile>mock-setup.msi</SetupFile>
  <MsiInfo>
    <MsiProductCode>{AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0000}</MsiProductCode>
    <MsiProductVersion>26.02.00.0</MsiProductVersion>
    <MsiPublisher>Mock Publisher GmbH</MsiPublisher>
  </MsiInfo>
</ApplicationInfo>
"@
        }
    }

    Context 'Get-MsiAppConfig - SevenZip (pure MSI, ProductCodeOnly detection)' {
        BeforeAll {
            $config = Get-MsiAppConfig -AppName 'SevenZip' -Version '26.02' -SetupFile '7z2602-x64.msi' -IntuneWinPath $dummyIntuneWin
        }

        It 'builds an MSI product-code detection rule' {
            $rule = $config.DetectionRules
            $rule.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppProductCodeDetection'
            $rule.productCode | Should -Be $mockProductCode
            $rule.productVersionOperator | Should -Be 'notConfigured'
        }

        It 'takes version and publisher from the MSI metadata' {
            $config.AppVersion | Should -Be '26.02.00.0'
            $config.Publisher | Should -Be 'Mock Publisher GmbH'
        }

        It 'formats the display name with the major version only' {
            $config.DisplayName | Should -Be '7-Zip 26'
        }

        It 'uses the MSI product code in the uninstall command' {
            $config.UninstallCommandLine | Should -Be "msiexec /x $mockProductCode /qn"
        }
    }

    Context 'Get-MsiAppConfig - Chrome (hybrid MSI with file-based detection)' {
        BeforeAll {
            $config = Get-MsiAppConfig -AppName 'Chrome' -Version '151.0.7922.109' -SetupFile 'GoogleChrome-151.0.7922.109-Enterprise-x64.msi' -IntuneWinPath $dummyIntuneWin
        }

        It 'builds a file-system version detection rule instead of a product-code rule' {
            $rule = $config.DetectionRules
            $rule.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppFileSystemDetection'
            $rule.path | Should -Be 'C:\Program Files\Google\Chrome\Application'
            $rule.fileOrFolderName | Should -Be 'chrome.exe'
            $rule.detectionType | Should -Be 'version'
            $rule.operator | Should -Be 'greaterThanOrEqual'
            $rule.detectionValue | Should -Be '151.0.7922.109'
            $rule.check32BitOn64System | Should -BeFalse
        }

        It 'uses the provided version (not MSI metadata) because auto-update outruns the MSI version' {
            $config.AppVersion | Should -Be '151.0.7922.109'
        }

        It 'formats the display name with the major version only' {
            $config.DisplayName | Should -Be 'Google Chrome 151'
        }

        It 'still uses the MSI product code for uninstall' {
            $config.UninstallCommandLine | Should -Be "msiexec /x $mockProductCode /qn"
        }
    }

    Context 'Get-FileAppConfig - Firefox (EXE with file-based detection)' {
        BeforeAll {
            $config = Get-FileAppConfig -AppName 'Firefox' -Version '143.0.1' -SetupFile 'Firefox-Setup-143.0.1-de.exe'
        }

        It 'builds a file-system version detection rule' {
            $rule = $config.DetectionRules
            $rule.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppFileSystemDetection'
            $rule.path | Should -Be 'C:\Program Files\Mozilla Firefox'
            $rule.fileOrFolderName | Should -Be 'firefox.exe'
            $rule.operator | Should -Be 'greaterThanOrEqual'
            $rule.detectionValue | Should -Be '143.0.1'
        }

        It 'formats install and uninstall command lines from the templates' {
            $config.InstallCommandLine | Should -Be '"Firefox-Setup-143.0.1-de.exe" /S'
            $config.UninstallCommandLine | Should -Be '"C:\Program Files\Mozilla Firefox\uninstall\helper.exe" /S'
        }

        It 'keeps the full version as AppVersion but only the major version in the display name' {
            $config.AppVersion | Should -Be '143.0.1'
            $config.DisplayName | Should -Be 'Mozilla Firefox 143 (German)'
        }
    }

    Context 'Get-FileAppConfig - VCRedist (registry existence detection)' {
        BeforeAll {
            $config = Get-FileAppConfig -AppName 'VCRedist' -Version '14.40.33816' -SetupFile 'vc_redist.x64-14.40.33816.exe'
        }

        It 'builds a registry existence detection rule' {
            $rule = $config.DetectionRules
            $rule.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppRegistryDetection'
            $rule.keyPath | Should -Be 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64'
            $rule.valueName | Should -Be 'Installed'
            $rule.detectionType | Should -Be 'exists'
            $rule.operator | Should -Be 'notConfigured'
        }
    }

    Context 'Get-ScriptAppConfig - GeoGebra (PowerShell script detection, MSI package)' {
        BeforeAll {
            $config = Get-ScriptAppConfig -AppName 'GeoGebra' -Version '6.0.906.2' -SetupFile 'GeoGebra-Windows-Installer-6-6.0.906.2.msi' -IntuneWinPath $dummyIntuneWin
        }

        It 'builds a PowerShell script detection rule' {
            $rule = $config.DetectionRules
            $rule.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppPowerShellScriptDetection'
            $rule.enforceSignatureCheck | Should -BeFalse
            $rule.runAs32Bit | Should -BeFalse
        }

        It 'injects the required version into the detection script content' {
            $scriptText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($config.DetectionRules.scriptContent))
            $scriptText | Should -Match ([regex]::Escape("`$RequiredVersion = '6.0.906.2'"))
            $scriptText | Should -Not -Match 'Parameter\(Mandatory' -Because 'the mandatory param block must be replaced by the injected version'
        }

        It 'uses the MSI product code for uninstall (MSI package type)' {
            $config.UninstallCommandLine | Should -Be "msiexec /x $mockProductCode /qn"
        }
    }

    Context 'Common settings applied to every generated config' {
        It 'stamps install experience, restart behavior, and an x64/Win11 requirement rule' {
            foreach ($config in @(
                (Get-MsiAppConfig -AppName 'SevenZip' -Version '26.02' -SetupFile '7z2602-x64.msi' -IntuneWinPath $dummyIntuneWin),
                (Get-FileAppConfig -AppName 'Firefox' -Version '143.0.1' -SetupFile 'Firefox-Setup-143.0.1-de.exe')
            )) {
                $config.InstallExperience | Should -Be 'system'
                $config.RestartBehavior | Should -Be 'suppress'
                $config.RequirementRule.allowedArchitectures | Should -Be 'x64'
                $config.RequirementRule.minimumSupportedWindowsRelease | Should -Be 'Windows11_21H2'
            }
        }
    }
}
