#Requires -Version 7.4

# Tests for the session bootstrap in IntuneSession.ps1. Credential lookup, module installation
# and Graph authentication are mocked; these tests pin the flow and return values.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    foreach ($file in 'IntuneSession.ps1', 'AuthenticationManager.ps1', 'TenantConfig.ps1') {
        Copy-Item (Join-Path $repoRoot $file) $workDir
    }
    . (Join-Path $workDir 'IntuneSession.ps1')
}

AfterAll {
    $global:__IntuneCachedMasterKey = $null
    $global:__IntuneCachedTenantSecrets = @{}
}

Describe 'Resolve-IntuneTenantCredential' {
    It 'returns the stored credential object' {
        Mock Get-IntuneTenant { [PSCustomObject]@{ TenantId = 't-1'; ClientId = 'c-1'; ClientSecret = 's-1' } }
        $creds = Resolve-IntuneTenantCredential -TenantName 'MZ' 6> $null
        $creds.TenantId | Should -Be 't-1'
        $creds.ClientSecret | Should -Be 's-1'
        Should -Invoke Get-IntuneTenant -ParameterFilter { $Name -eq 'MZ' } -Times 1 -Exactly
    }

    It 'returns $null when the tenant cannot be resolved' {
        Mock Get-IntuneTenant { $null }
        Resolve-IntuneTenantCredential -TenantName 'Unknown' 6> $null | Should -BeNullOrEmpty
    }
}

Describe 'Connect-IntuneTenantSession' {
    It 'connects when modules are present and authentication succeeds' {
        Mock Install-RequiredModules { $true }
        Mock Initialize-IntuneAuthentication { $true }
        Connect-IntuneTenantSession -TenantId 't' -ClientId 'c' -ClientSecret 's' 6> $null | Should -BeTrue
        Should -Invoke Initialize-IntuneAuthentication -ParameterFilter { $TenantId -eq 't' -and $ClientId -eq 'c' -and $ClientSecret -eq 's' } -Times 1 -Exactly
    }

    It 'passes -SkipInstallation through to the module check' {
        Mock Install-RequiredModules { $true }
        Mock Initialize-IntuneAuthentication { $true }
        $null = Connect-IntuneTenantSession -TenantId 't' -ClientId 'c' -ClientSecret 's' -SkipInstallation 6> $null
        Should -Invoke Install-RequiredModules -ParameterFilter { $SkipInstallation } -Times 1 -Exactly
    }

    It 'fails without authenticating when required modules are missing' {
        Mock Install-RequiredModules { $false }
        Mock Initialize-IntuneAuthentication { $true }
        Connect-IntuneTenantSession -TenantId 't' -ClientId 'c' -ClientSecret 's' 6> $null | Should -BeFalse
        Should -Invoke Initialize-IntuneAuthentication -Times 0 -Exactly
    }

    It 'fails without authenticating when client credentials are missing' {
        Mock Install-RequiredModules { $true }
        Mock Initialize-IntuneAuthentication { $true }
        Connect-IntuneTenantSession -TenantId 't' 6> $null | Should -BeFalse
        Should -Invoke Initialize-IntuneAuthentication -Times 0 -Exactly
    }

    It 'fails when authentication fails' {
        Mock Install-RequiredModules { $true }
        Mock Initialize-IntuneAuthentication { $false }
        Connect-IntuneTenantSession -TenantId 't' -ClientId 'c' -ClientSecret 's' 6> $null | Should -BeFalse
    }
}
