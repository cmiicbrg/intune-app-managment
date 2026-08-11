#Requires -Version 7.4

# Tests for the native implementations inside IntuneInterop.ps1: the .intunewin
# metadata parser, icon encoding, requirement-rule mapping, and the read-only Graph
# queries (Invoke-MgGraphRequest is stubbed and mocked, so no Graph connection or
# Microsoft.Graph module is needed).

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'IntuneInterop.ps1') $workDir
    . (Join-Path $workDir 'IntuneInterop.ps1')

    # Stub so the Graph cmdlet exists for Pester to mock without the Microsoft.Graph
    # module being installed. CmdletBinding gives it the common parameters the
    # wrappers pass (-ErrorAction).
    function Invoke-MgGraphRequest {
        [CmdletBinding()]
        param($Method, $Uri, $OutputType)
        throw 'stub was not mocked'
    }

    # Minimal real .intunewin fixture: a zip carrying only the Detection.xml metadata
    $stagingRoot = Join-Path $TestDrive 'intunewin-staging'
    $metadataDir = Join-Path $stagingRoot 'IntuneWinPackage\Metadata'
    New-Item -ItemType Directory -Path $metadataDir -Force | Out-Null
    @"
<ApplicationInfo>
  <SetupFile>setup.msi</SetupFile>
  <MsiInfo>
    <MsiProductCode>{11111111-2222-3333-4444-555555555555}</MsiProductCode>
    <MsiProductVersion>1.2.3.4</MsiProductVersion>
  </MsiInfo>
</ApplicationInfo>
"@ | Set-Content -Path (Join-Path $metadataDir 'Detection.xml')
    $fixtureIntuneWin = Join-Path $TestDrive 'fixture.intunewin'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingRoot, $fixtureIntuneWin)
}

Describe 'Get-InteropPackageMetadata (native zip parser)' {
    It 'parses Detection.xml out of an .intunewin package' {
        $metadata = Get-InteropPackageMetadata -FilePath $fixtureIntuneWin
        $metadata.ApplicationInfo.SetupFile | Should -Be 'setup.msi'
        $metadata.ApplicationInfo.MsiInfo.MsiProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
        $metadata.ApplicationInfo.MsiInfo.MsiProductVersion | Should -Be '1.2.3.4'
    }

    It 'warns and returns $null for a file that is not a zip' {
        $notAZip = Join-Path $TestDrive 'garbage.intunewin'
        'not a zip archive' | Set-Content $notAZip
        Get-InteropPackageMetadata -FilePath $notAZip -WarningAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'warns and returns $null for a zip without a Detection.xml entry' {
        $emptyStaging = Join-Path $TestDrive 'empty-staging'
        New-Item -ItemType Directory -Path $emptyStaging -Force | Out-Null
        'placeholder' | Set-Content (Join-Path $emptyStaging 'other.txt')
        $noMetadataZip = Join-Path $TestDrive 'no-metadata.intunewin'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($emptyStaging, $noMetadataZip)
        Get-InteropPackageMetadata -FilePath $noMetadataZip -WarningAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'New-InteropAppIcon (native base64 encoding)' {
    It 'returns the base64 string of the file bytes' {
        $iconPath = Join-Path $TestDrive 'icon.png'
        $bytes = [byte[]](137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3)
        [System.IO.File]::WriteAllBytes($iconPath, $bytes)
        New-InteropAppIcon -FilePath $iconPath | Should -Be ([Convert]::ToBase64String($bytes))
    }
}

Describe 'New-InteropRequirementRule (native mapping)' {
    It 'maps combined architectures to the comma-separated Graph value' {
        (New-InteropRequirementRule -Architecture 'x64x86' -MinimumSupportedOperatingSystem 'W11_21H2').allowedArchitectures |
            Should -Be 'x64,x86'
    }

    It 'maps Windows 10 21H2 to the service release name' {
        (New-InteropRequirementRule -Architecture 'x64' -MinimumSupportedOperatingSystem 'W10_21H2').minimumSupportedWindowsRelease |
            Should -Be 'Windows10_21H2'
    }

    It 'rejects unknown OS values' {
        { New-InteropRequirementRule -Architecture 'x64' -MinimumSupportedOperatingSystem 'W95_OSR2' } | Should -Throw
    }
}

Describe 'Get-InteropWin32App (native Graph list)' {
    BeforeAll {
        Mock Invoke-MgGraphRequest {
            if ($Uri -like '*next-page*') {
                # Final page: no @odata.nextLink property
                [PSCustomObject]@{
                    value = @(
                        [PSCustomObject]@{ id = '3'; displayName = '7-Zip 26'; displayVersion = '26.02.00.0'; createdDateTime = '2026-01-03' }
                    )
                }
            }
            else {
                [PSCustomObject]@{
                    value             = @(
                        [PSCustomObject]@{ id = '1'; displayName = 'Google Chrome 151'; displayVersion = '151.0'; createdDateTime = '2026-01-01' },
                        [PSCustomObject]@{ id = '2'; displayName = 'Mozilla Firefox 153 (German)'; displayVersion = '153.0'; createdDateTime = '2026-01-02' }
                    )
                    '@odata.nextLink' = 'https://graph.microsoft.com/beta/next-page'
                }
            }
        }
    }

    It 'follows @odata.nextLink paging and returns all apps' {
        @(Get-InteropWin32App).Count | Should -Be 3
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
    }

    It 'requests only the summary properties via $select' {
        $null = Get-InteropWin32App
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter { $Uri -like '*`$select=id,displayName,displayVersion,createdDateTime*' }
    }

    It 'filters by display name with contains-match semantics' {
        $result = @(Get-InteropWin32App -DisplayName 'Chrome')
        $result.Count | Should -Be 1
        $result[0].id | Should -Be '1'
    }

    It 'returns an empty result when nothing matches the display name' {
        @(Get-InteropWin32App -DisplayName 'Nonexistent App').Count | Should -Be 0
    }
}

Describe 'Get-InteropAppAssignment (native Graph read + normalization)' {
    It 'normalizes all three target types' {
        Mock Invoke-MgGraphRequest {
            [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ id = 'a1'; target = [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } },
                    [PSCustomObject]@{ id = 'a2'; target = [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } },
                    [PSCustomObject]@{ id = 'a3'; target = [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g-123' } }
                )
            }
        }

        $targets = @(Get-InteropAppAssignment -AppId 'app-1')
        $targets | Should -Be @('AllUsers', 'AllDevices', 'Group:g-123')
    }

    It 'follows @odata.nextLink paging across assignment pages' {
        Mock Invoke-MgGraphRequest {
            if ($Uri -like '*next-assignments*') {
                [PSCustomObject]@{
                    value = @(
                        [PSCustomObject]@{ id = 'a2'; target = [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g-2' } }
                    )
                }
            }
            else {
                [PSCustomObject]@{
                    value             = @(
                        [PSCustomObject]@{ id = 'a1'; target = [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }
                    )
                    '@odata.nextLink' = 'https://graph.microsoft.com/beta/next-assignments'
                }
            }
        }

        @(Get-InteropAppAssignment -AppId 'app-1') | Should -Be @('AllUsers', 'Group:g-2')
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
    }

    It 'returns an empty array when the app has no assignments' {
        Mock Invoke-MgGraphRequest { [PSCustomObject]@{ value = @() } }
        @(Get-InteropAppAssignment -AppId 'app-1').Count | Should -Be 0
    }

    It 'returns an empty array when the request fails' {
        Mock Invoke-MgGraphRequest { throw 'Graph unavailable' }
        @(Get-InteropAppAssignment -AppId 'app-1').Count | Should -Be 0
    }
}
