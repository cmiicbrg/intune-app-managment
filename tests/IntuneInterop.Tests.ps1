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
        param($Method, $Uri, $OutputType, $Body, $ContentType)
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

Describe 'Get-InteropWin32App (native Graph list + per-ID fetch)' {
    BeforeAll {
        # The list responses deliberately carry ONLY id and displayName: derived
        # win32LobApp properties (displayVersion) cannot be $select-ed on the list
        # endpoint and are not guaranteed there, which is why the implementation must
        # do per-ID GETs for the full objects.
        Mock Invoke-MgGraphRequest {
            if ($Uri -match '/mobileApps/([^/?]+)$') {
                # Per-ID GET returns the full app object
                $id = $Matches[1]
                $names = @{ '1' = 'Google Chrome 151'; '2' = 'Mozilla Firefox 153 (German)'; '3' = '7-Zip 26' }
                [PSCustomObject]@{ id = $id; displayName = $names[$id]; displayVersion = "$id.0"; createdDateTime = "2026-01-0$id" }
            }
            elseif ($Uri -like '*next-page*') {
                # Final list page: no @odata.nextLink property
                [PSCustomObject]@{
                    value = @(
                        [PSCustomObject]@{ id = '3'; displayName = '7-Zip 26' }
                    )
                }
            }
            else {
                [PSCustomObject]@{
                    value             = @(
                        [PSCustomObject]@{ id = '1'; displayName = 'Google Chrome 151' },
                        [PSCustomObject]@{ id = '2'; displayName = 'Mozilla Firefox 153 (German)' }
                    )
                    '@odata.nextLink' = 'https://graph.microsoft.com/beta/next-page'
                }
            }
        }
    }

    It 'follows @odata.nextLink paging and returns a full object per app' {
        $result = @(Get-InteropWin32App)
        $result.Count | Should -Be 3
        foreach ($app in $result) {
            $app.displayVersion | Should -Not -BeNullOrEmpty -Because 'full objects come from the per-ID GETs, not the list'
        }
        # 2 list pages + 3 per-ID fetches
        Should -Invoke Invoke-MgGraphRequest -Times 5 -Exactly
    }

    It 'filters by display name with contains-match semantics before fetching details' {
        $result = @(Get-InteropWin32App -DisplayName 'Chrome')
        $result.Count | Should -Be 1
        $result[0].id | Should -Be '1'
        # Only the matching app is fetched individually
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter { $Uri -match '/mobileApps/[^/?]+$' } -Times 1 -Exactly
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

Describe 'Add-Interop*Assignment (native Graph writes)' {
    BeforeAll {
        # GET returns the app (supersededAppCount drives autoUpdateSettings);
        # POST returns the created assignment
        Mock Invoke-MgGraphRequest {
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ id = 'app-1'; supersededAppCount = 1 }
            }
            else {
                [PSCustomObject]@{ id = 'assignment-1' }
            }
        }
    }

    It 'posts an All Users assignment with the win32LobApp settings shape' {
        $result = Add-InteropAllUsersAssignment -AppId 'app-1' -Intent 'available' -Notification 'showAll'
        $result.id | Should -Be 'assignment-1'
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter {
            if ($Method -ne 'POST') { return $false }
            $parsed = $Body | ConvertFrom-Json
            $parsed.'@odata.type' -eq '#microsoft.graph.mobileAppAssignment' -and
            $parsed.intent -eq 'available' -and
            $parsed.source -eq 'direct' -and
            $parsed.target.'@odata.type' -eq '#microsoft.graph.allLicensedUsersAssignmentTarget' -and
            $parsed.settings.'@odata.type' -eq '#microsoft.graph.win32LobAppAssignmentSettings' -and
            $parsed.settings.notifications -eq 'showAll'
        } -Times 1 -Exactly
    }

    It 'writes autoUpdateSettings enabled for available intent on a superseding app' {
        $null = Add-InteropAllUsersAssignment -AppId 'app-1' -Intent 'available' -AutoUpdateSuperseded $true
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter {
            $Method -eq 'POST' -and
            ($Body | ConvertFrom-Json).settings.autoUpdateSettings.autoUpdateSupersededAppsState -eq 'enabled'
        } -Times 1 -Exactly
    }

    It 'omits autoUpdateSettings when the app supersedes nothing' {
        Mock Invoke-MgGraphRequest {
            if ($Method -eq 'GET') { [PSCustomObject]@{ id = 'app-2'; supersededAppCount = 0 } }
            else { [PSCustomObject]@{ id = 'assignment-2' } }
        }
        $null = Add-InteropAllUsersAssignment -AppId 'app-2' -Intent 'available' -AutoUpdateSuperseded $true
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter {
            $Method -eq 'POST' -and $null -eq ($Body | ConvertFrom-Json).settings.autoUpdateSettings
        } -Times 1 -Exactly
    }

    It 'targets All Devices with the required intent and no autoUpdateSettings' {
        $null = Add-InteropAllDevicesAssignment -AppId 'app-1' -Intent 'required'
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter {
            if ($Method -ne 'POST') { return $false }
            $parsed = $Body | ConvertFrom-Json
            $parsed.target.'@odata.type' -eq '#microsoft.graph.allDevicesAssignmentTarget' -and
            $parsed.intent -eq 'required' -and
            $null -eq $parsed.settings.autoUpdateSettings
        } -Times 1 -Exactly
    }

    It 'targets the group and carries the groupId' {
        $null = Add-InteropGroupAssignment -AppId 'app-1' -GroupId 'g-9' -Intent 'available'
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter {
            if ($Method -ne 'POST') { return $false }
            $parsed = $Body | ConvertFrom-Json
            $parsed.target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget' -and
            $parsed.target.groupId -eq 'g-9'
        } -Times 1 -Exactly
    }

    It 'warns and returns $null when the POST fails' {
        Mock Invoke-MgGraphRequest {
            if ($Method -eq 'GET') { [PSCustomObject]@{ id = 'app-1'; supersededAppCount = 0 } }
            else { throw 'BadRequest: The MobileApp Assignment already exists' }
        }
        Add-InteropAllUsersAssignment -AppId 'app-1' -Intent 'available' -WarningAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}

Describe 'Add-InteropSupersedence (native updateRelationships)' {
    It 'merges the new supersedence with existing dependencies, replacing old supersedence' {
        Mock Invoke-MgGraphRequest {
            if ($Method -eq 'GET') {
                [PSCustomObject]@{
                    value = @(
                        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; dependencyType = 'autoInstall'; targetId = 'dep-1' },
                        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; supersedenceType = 'update'; targetId = 'ancient-app' }
                    )
                }
            }
        }

        Add-InteropSupersedence -AppId 'new-app' -SupersededAppId 'old-app' -SupersedenceType 'Replace'

        Should -Invoke Invoke-MgGraphRequest -ParameterFilter {
            if ($Method -ne 'POST') { return $false }
            $rels = @(($Body | ConvertFrom-Json).relationships)
            $supersedences = @($rels | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.mobileAppSupersedence' })
            $dependencies = @($rels | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.mobileAppDependency' })
            $rels.Count -eq 2 -and
            $supersedences.Count -eq 1 -and
            $supersedences[0].targetId -eq 'old-app' -and
            $supersedences[0].supersedenceType -eq 'replace' -and
            $dependencies[0].targetId -eq 'dep-1'
        } -Times 1 -Exactly
    }

    It 'refuses self-supersedence without calling Graph' {
        Mock Invoke-MgGraphRequest { }
        Add-InteropSupersedence -AppId 'a' -SupersededAppId 'a' -WarningAction SilentlyContinue
        Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
    }
}

Describe 'Add-InteropDependency (native updateRelationships)' {
    It 'merges new dependencies with existing supersedence, replacing old dependencies' {
        Mock Invoke-MgGraphRequest {
            if ($Method -eq 'GET') {
                [PSCustomObject]@{
                    value = @(
                        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; supersedenceType = 'update'; targetId = 'old-version' },
                        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; dependencyType = 'autoInstall'; targetId = 'stale-dep' }
                    )
                }
            }
        }

        Add-InteropDependency -AppId 'app' -DependencyAppIds @('dep-a', 'dep-b')

        Should -Invoke Invoke-MgGraphRequest -ParameterFilter {
            if ($Method -ne 'POST') { return $false }
            $rels = @(($Body | ConvertFrom-Json).relationships)
            $dependencies = @($rels | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.mobileAppDependency' })
            $supersedences = @($rels | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.mobileAppSupersedence' })
            $rels.Count -eq 3 -and
            $dependencies.Count -eq 2 -and
            ($dependencies.targetId -contains 'dep-a') -and
            ($dependencies.targetId -contains 'dep-b') -and
            ($dependencies.targetId -notcontains 'stale-dep') -and
            $supersedences[0].targetId -eq 'old-version'
        } -Times 1 -Exactly
    }

    It 'refuses self-dependency without calling Graph' {
        Mock Invoke-MgGraphRequest { }
        Add-InteropDependency -AppId 'a' -DependencyAppIds @('b', 'a') -WarningAction SilentlyContinue
        Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
    }
}
