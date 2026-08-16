#Requires -Version 7.4

# Tests for TenantDeployments.ps1: deployment-plan loading and the version-retention policy.
# The script is copied to TestDrive (with AppConfig.ps1) so its TenantDeployments.json lookup
# lands in the sandbox, never on the real, git-ignored plan file.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'AppConfig.ps1') $workDir
    Copy-Item (Join-Path $repoRoot 'TenantDeployments.ps1') $workDir
    . (Join-Path $workDir 'TenantDeployments.ps1')
    $planPath = Join-Path $workDir 'TenantDeployments.json'

    function Set-Plan {
        param([Parameter(Mandatory = $true)][string]$Json)
        $Json | Set-Content -Path $planPath -Encoding UTF8
    }
}

Describe 'Get-TenantDeploymentPlan (unchanged behaviour)' {
    BeforeEach {
        Remove-Item $planPath -ErrorAction SilentlyContinue
    }

    It 'returns $null when there is no plan file' {
        Get-TenantDeploymentPlan -TenantName 'Any' | Should -BeNullOrEmpty
    }

    It 'returns $null for a tenant that is not in the file' {
        Set-Plan '{ "Tenants": { "Contoso": { "Apps": { "Chrome": {} } } } }'
        Get-TenantDeploymentPlan -TenantName 'Fabrikam' | Should -BeNullOrEmpty
    }

    It 'resolves app names case-insensitively into assignment specs' {
        Set-Plan '{ "Tenants": { "Contoso": { "Apps": { "chrome": { "AllUsers": true, "AllDevices": true }, "VCRedist": {} } } } }'
        $plan = Get-TenantDeploymentPlan -TenantName 'contoso'
        @($plan.Keys) | Should -Be @('Chrome', 'VCRedist')
        $plan['Chrome'].AllUsers | Should -BeTrue
        $plan['Chrome'].AllDevices | Should -BeTrue
        $plan['VCRedist'].AllUsers | Should -BeFalse
    }

    It 'rejects unknown app names' {
        Set-Plan '{ "Tenants": { "Contoso": { "Apps": { "NotAnApp": {} } } } }'
        { Get-TenantDeploymentPlan -TenantName 'Contoso' } | Should -Throw '*unknown app*'
    }

    It 'rejects non-boolean assignment flags' {
        Set-Plan '{ "Tenants": { "Contoso": { "Apps": { "Chrome": { "AllUsers": "false" } } } } }'
        { Get-TenantDeploymentPlan -TenantName 'Contoso' } | Should -Throw '*must be true or false*'
    }

    It 'still loads a plan that carries Retention blocks, without exposing them in the spec' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewest": 3 }, "Apps": { "Chrome": { "AllUsers": true, "Retention": { "KeepNewest": 2 } } } } } }'
        $plan = Get-TenantDeploymentPlan -TenantName 'Contoso'
        $plan['Chrome'].AllUsers | Should -BeTrue
        $plan['Chrome'].Keys | Should -Not -Contain 'Retention'
    }

    It 'fails plan loading on a malformed Retention block' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewest": "3" }, "Apps": { "Chrome": {} } } } }'
        { Get-TenantDeploymentPlan -TenantName 'Contoso' } | Should -Throw '*whole number*'
    }
}

Describe 'Get-TenantRetentionPolicy' {
    BeforeEach {
        Remove-Item $planPath -ErrorAction SilentlyContinue
    }

    It 'yields the built-in defaults when there is no plan file' {
        $policy = Get-TenantRetentionPolicy -TenantName 'Any'
        $policy.KeepNewest | Should -Be 3
        $policy.KeepNewerThanWeeks | Should -Be 10
        $policy.Source | Should -Be 'default'
        $policy.OptIn | Should -BeFalse
    }

    It 'yields the defaults with OptIn false when the tenant has no Retention block' {
        Set-Plan '{ "Tenants": { "Contoso": { "Apps": { "Chrome": {} } } } }'
        $policy = Get-TenantRetentionPolicy -TenantName 'Contoso'
        $policy.Source | Should -Be 'default'
        $policy.OptIn | Should -BeFalse
    }

    It 'applies the tenant block and marks the tenant opted in' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewest": 4, "KeepNewerThanWeeks": 6 }, "Apps": { "Chrome": {} } } } }'
        $policy = Get-TenantRetentionPolicy -TenantName 'Contoso'
        $policy.KeepNewest | Should -Be 4
        $policy.KeepNewerThanWeeks | Should -Be 6
        $policy.Source | Should -Be 'tenant'
        $policy.OptIn | Should -BeTrue
    }

    It 'lets a partial tenant block inherit the other default' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewerThanWeeks": 4 }, "Apps": { "Chrome": {} } } } }'
        $policy = Get-TenantRetentionPolicy -TenantName 'Contoso'
        $policy.KeepNewest | Should -Be 3
        $policy.KeepNewerThanWeeks | Should -Be 4
    }

    It 'layers an app override over the tenant block' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewest": 4, "KeepNewerThanWeeks": 6 }, "Apps": { "Chrome": { "Retention": { "KeepNewest": 2 } }, "Firefox": {} } } } }'
        $chrome = Get-TenantRetentionPolicy -TenantName 'Contoso' -AppName 'chrome'
        $chrome.KeepNewest | Should -Be 2
        $chrome.KeepNewerThanWeeks | Should -Be 6 -Because 'the app override inherits the tenant value it does not set'
        $chrome.Source | Should -Be 'app'
        $chrome.OptIn | Should -BeTrue

        $firefox = Get-TenantRetentionPolicy -TenantName 'Contoso' -AppName 'Firefox'
        $firefox.KeepNewest | Should -Be 4
        $firefox.Source | Should -Be 'tenant'
    }

    It 'applies an app override without a tenant block but does not opt the tenant in' {
        Set-Plan '{ "Tenants": { "Contoso": { "Apps": { "Chrome": { "Retention": { "KeepNewest": 5 } } } } } }'
        $policy = Get-TenantRetentionPolicy -TenantName 'Contoso' -AppName 'Chrome'
        $policy.KeepNewest | Should -Be 5
        $policy.Source | Should -Be 'app'
        $policy.OptIn | Should -BeFalse
    }

    It 'rejects KeepNewest below the floor of 2' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewest": 1 }, "Apps": { "Chrome": {} } } } }'
        { Get-TenantRetentionPolicy -TenantName 'Contoso' } | Should -Throw '*at least 2*'
    }

    It 'rejects negative week counts' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewerThanWeeks": -1 }, "Apps": { "Chrome": {} } } } }'
        { Get-TenantRetentionPolicy -TenantName 'Contoso' } | Should -Throw '*at least 0*'
    }

    It 'rejects strings, decimals and booleans' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewest": 2.5 }, "Apps": { "Chrome": {} } } } }'
        { Get-TenantRetentionPolicy -TenantName 'Contoso' } | Should -Throw '*whole number*'
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewerThanWeeks": true }, "Apps": { "Chrome": {} } } } }'
        { Get-TenantRetentionPolicy -TenantName 'Contoso' } | Should -Throw '*whole number*'
    }

    It 'rejects unknown settings so typos never silently mean default' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": { "KeepNewst": 3 }, "Apps": { "Chrome": {} } } } }'
        { Get-TenantRetentionPolicy -TenantName 'Contoso' } | Should -Throw '*unknown setting*'
    }

    It 'rejects a Retention value that is not an object' {
        Set-Plan '{ "Tenants": { "Contoso": { "Retention": 3, "Apps": { "Chrome": {} } } } }'
        { Get-TenantRetentionPolicy -TenantName 'Contoso' } | Should -Throw '*must be an object*'
    }
}
