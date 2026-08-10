#Requires -Version 7.4

# Tests for TenantConfig.ps1: AES-256-GCM secret encryption and config format v3.
# The script is copied to TestDrive before dot-sourcing so $PSScriptRoot-derived
# paths (intune-tenants.json) never touch the real repo checkout.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'tenantconfig'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'TenantConfig.ps1') $workDir
    . (Join-Path $workDir 'TenantConfig.ps1')
    $configPath = Join-Path $workDir 'intune-tenants.json'
}

AfterAll {
    # The script initializes session-global cache variables; don't leak them
    $global:__IntuneCachedMasterKey = $null
    $global:__IntuneCachedTenantSecrets = @{}
}

Describe 'Protect-Secret / Unprotect-Secret (AES-256-GCM)' {
    BeforeAll {
        $secret = 'my-Cl13nt~S3cret.Value_42'
        $password = 'correct-horse-battery-staple'
        $blob = Protect-Secret -PlainText $secret -Password $password
        $blobBytes = [Convert]::FromBase64String($blob)
    }

    It 'round-trips a secret with the correct password' {
        Unprotect-Secret -EncryptedBase64 $blob -Password $password | Should -BeExactly $secret
    }

    It 'produces the documented blob layout: salt(16) + nonce(12) + tag(16) + ciphertext' {
        $blobBytes.Length | Should -Be (44 + [Text.Encoding]::UTF8.GetByteCount($secret))
    }

    It 'uses a fresh salt and nonce per encryption (same input, different blob)' {
        Protect-Secret -PlainText $secret -Password $password | Should -Not -Be $blob
    }

    It 'returns $null for a wrong password' {
        Unprotect-Secret -EncryptedBase64 $blob -Password 'wrong-password' | Should -BeNullOrEmpty
    }

    It 'returns $null when the ciphertext is tampered with' {
        $tampered = [byte[]]$blobBytes.Clone()
        $tampered[44] = $tampered[44] -bxor 1
        Unprotect-Secret -EncryptedBase64 ([Convert]::ToBase64String($tampered)) -Password $password |
            Should -BeNullOrEmpty
    }

    It 'returns $null when the authentication tag is tampered with' {
        $tampered = [byte[]]$blobBytes.Clone()
        $tampered[30] = $tampered[30] -bxor 1
        Unprotect-Secret -EncryptedBase64 ([Convert]::ToBase64String($tampered)) -Password $password |
            Should -BeNullOrEmpty
    }

    It 'returns $null for a truncated blob' {
        Unprotect-Secret -EncryptedBase64 ([Convert]::ToBase64String([byte[]]::new(20))) -Password $password |
            Should -BeNullOrEmpty
    }

    It 'returns $null for input that is not valid base64' {
        Unprotect-Secret -EncryptedBase64 'not-base64!!!' -Password $password | Should -BeNullOrEmpty
    }
}

Describe 'Tenant config file format v3' {
    BeforeEach {
        Remove-Item $configPath -ErrorAction SilentlyContinue
    }

    It 'returns an in-memory default with version 3 when no file exists' {
        $config = Read-TenantConfig
        $config.version | Should -Be 3
        $config.PSObject.Properties.Name | Should -Contain 'tenants' -Because 'the tenants property must exist even when empty'
    }

    It 'stamps version 3 when writing a config that has no version property' {
        Write-TenantConfig -Config ([PSCustomObject]@{ tenants = [PSCustomObject]@{} })
        (Get-Content $configPath -Raw | ConvertFrom-Json).version | Should -Be 3
    }

    It 'round-trips a written config through Read-TenantConfig' {
        Write-TenantConfig -Config (Read-TenantConfig)
        (Read-TenantConfig).version | Should -Be 3
    }

    It 'rejects a pre-3.0 config (no version field) with re-add instructions' {
        '{ "tenants": { "Old": { "tenantId": "x", "clientId": "y", "encryptedSecret": "AAAA" } } }' |
            Set-Content $configPath
        { Read-TenantConfig } | Should -Throw -ExpectedMessage '*Add-IntuneTenant*'
    }

    It 'rejects a config with a newer format version than supported' {
        '{ "version": 4, "tenants": {} }' | Set-Content $configPath
        { Read-TenantConfig } | Should -Throw -ExpectedMessage '*newer*'
    }

    It 'rejects a config file missing the tenants field' {
        '{ "version": 3 }' | Set-Content $configPath
        { Read-TenantConfig } | Should -Throw -ExpectedMessage '*tenants*'
    }

    It 'rejects a config file containing invalid JSON' {
        'this is { not json' | Set-Content $configPath
        { Read-TenantConfig } | Should -Throw -ExpectedMessage '*invalid JSON*'
    }
}
