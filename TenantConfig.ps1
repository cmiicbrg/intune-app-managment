# TenantConfig.ps1
# Secure tenant configuration management with password-encrypted secrets
# Secrets are stored AES-256 encrypted in a portable JSON file
#
# NOTE: Only one copy of this repository should be used per PowerShell session.
# The credential cache is session-global, so loading multiple repo checkouts
# (each with its own intune-tenants.json) in the same session can cause
# cache collisions. Use separate PowerShell windows for separate checkouts.

# Suppress PSScriptAnalyzer warning for internal helper functions that require plain strings for crypto operations
# Public-facing functions use SecureString for user input
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
param()

$script:ConfigFileName = "intune-tenants.json"
$script:ConfigFilePath = Join-Path $PSScriptRoot $script:ConfigFileName
if ($null -eq $global:__IntuneCachedMasterKey) { $global:__IntuneCachedMasterKey = $null }
if ($null -eq $global:__IntuneCachedTenantSecrets) { $global:__IntuneCachedTenantSecrets = @{} }

#region Encryption Helpers

function Get-DerivedKey {
    <#
    .SYNOPSIS
    Derives an AES-256 key from a password using PBKDF2
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Password,
        
        [Parameter(Mandatory = $true)]
        [byte[]]$Salt
    )
    
    $iterations = 100000  # OWASP recommended minimum for PBKDF2-SHA256
    $keySize = 32  # 256 bits for AES-256
    
    $deriveBytes = $null
    try {
        $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $Password, 
            $Salt, 
            $iterations, 
            [System.Security.Cryptography.HashAlgorithmName]::SHA256
        )
        
        $keyBytes = $deriveBytes.GetBytes($keySize)
    }
    finally {
        if ($null -ne $deriveBytes) {
            $deriveBytes.Dispose()
        }
    }
    
    return $keyBytes
}

function Protect-Secret {
    <#
    .SYNOPSIS
    Encrypts a secret string using AES-256 with a password-derived key
    
    .DESCRIPTION
    Uses PBKDF2 for key derivation with random salt and IV.
    Returns a base64 string containing: salt (16 bytes) + IV (16 bytes) + ciphertext
    
    Note: Uses AES-CBC for PowerShell 5.1 compatibility. Integrity protection (MAC) is not 
    included; tampering will result in authentication failures at the Graph API level rather 
    than decryption errors. This is acceptable for this use case where the threat model is 
    casual exposure (accidental commits, screen visibility), not active attackers with 
    filesystem write access.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlainText,
        
        [Parameter(Mandatory = $true)]
        [string]$Password
    )
    
    # Generate random salt and IV
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($salt)
        $rng.GetBytes($iv)
    }
    finally {
        $rng.Dispose()
    }
    
    # Derive key from password
    $key = Get-DerivedKey -Password $Password -Salt $salt
    
    # Encrypt
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    
    $encryptor = $aes.CreateEncryptor()
    try {
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    
        # Combine salt + IV + ciphertext
        $combined = New-Object byte[] ($salt.Length + $iv.Length + $cipherBytes.Length)
        [System.Buffer]::BlockCopy($salt, 0, $combined, 0, $salt.Length)
        [System.Buffer]::BlockCopy($iv, 0, $combined, $salt.Length, $iv.Length)
        [System.Buffer]::BlockCopy($cipherBytes, 0, $combined, $salt.Length + $iv.Length, $cipherBytes.Length)
    
        return [System.Convert]::ToBase64String($combined)
    }
    finally {
        $encryptor.Dispose()
        $aes.Dispose()
    }
}

function Unprotect-Secret {
    <#
    .SYNOPSIS
    Decrypts a secret that was encrypted with Protect-Secret
    
    .DESCRIPTION
    Extracts salt and IV from the encrypted blob, derives the key, and decrypts.
    Returns $null if decryption fails (wrong password or corrupted data).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$EncryptedBase64,
        
        [Parameter(Mandatory = $true)]
        [string]$Password
    )
    
    try {
        $combined = [System.Convert]::FromBase64String($EncryptedBase64)
        
        # Extract salt (16 bytes), IV (16 bytes), and ciphertext
        $salt = New-Object byte[] 16
        $iv = New-Object byte[] 16
        $cipherBytes = New-Object byte[] ($combined.Length - 32)
        
        [System.Buffer]::BlockCopy($combined, 0, $salt, 0, 16)
        [System.Buffer]::BlockCopy($combined, 16, $iv, 0, 16)
        [System.Buffer]::BlockCopy($combined, 32, $cipherBytes, 0, $cipherBytes.Length)
        
        # Derive key from password
        $key = Get-DerivedKey -Password $Password -Salt $salt
        
        # Decrypt
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        
        $decryptor = $aes.CreateDecryptor()
        try {
            $plainBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
            return [System.Text.Encoding]::UTF8.GetString($plainBytes)
        }
        finally {
            $decryptor.Dispose()
            $aes.Dispose()
        }
    }
    catch {
        return $null
    }
}

#endregion

#region Config File Management

function Get-TenantConfigPath {
    return $script:ConfigFilePath
}

function Read-TenantConfig {
    <#
    .SYNOPSIS
    Reads the tenant configuration file
    #>
    if (Test-Path $script:ConfigFilePath) {
        $content = Get-Content -Path $script:ConfigFilePath -Raw -Encoding UTF8
        try {
            $config = $content | ConvertFrom-Json
        }
        catch {
            throw "Failed to parse tenant configuration file '$script:ConfigFilePath'. The file may contain invalid JSON. Fix or delete the file before retrying."
        }
        
        if ($null -eq $config -or -not ($config.PSObject.Properties.Name -contains 'tenants')) {
            throw "Tenant configuration file '$script:ConfigFilePath' is missing required 'tenants' field. Fix or delete the file before retrying."
        }
        
        return $config
    }
    else {
        return [PSCustomObject]@{ tenants = [PSCustomObject]@{} }
    }
}

function Write-TenantConfig {
    <#
    .SYNOPSIS
    Writes the tenant configuration to file
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )
    
    $json = $Config | ConvertTo-Json -Depth 10
    $json | Out-File -FilePath $script:ConfigFilePath -Encoding UTF8 -Force
}

#endregion

#region Session Cache Management

function Get-CachedMasterKey {
    <#
    .SYNOPSIS
    Gets the master key from the in-session cache
    #>
    return $global:__IntuneCachedMasterKey
}

function Set-CachedMasterKey {
    <#
    .SYNOPSIS
    Caches the master key in the current session
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Password
    )
    
    $global:__IntuneCachedMasterKey = $Password
}

function Get-CachedTenantSecret {
    <#
    .SYNOPSIS
    Gets a tenant's decrypted secret from session cache
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantName
    )
    
    return $global:__IntuneCachedTenantSecrets[$TenantName]
}

function Set-CachedTenantSecret {
    <#
    .SYNOPSIS
    Caches a tenant's decrypted secret in the session
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantName,
        
        [Parameter(Mandatory = $true)]
        [string]$Secret
    )
    
    $global:__IntuneCachedTenantSecrets[$TenantName] = $Secret
}

function Clear-CachedTenantSecret {
    <#
    .SYNOPSIS
    Removes a tenant's cached secret from the session
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantName
    )
    
    $global:__IntuneCachedTenantSecrets.Remove($TenantName)
}

#endregion

#region Credential Testing

function Test-IntuneCredentials {
    <#
    .SYNOPSIS
    Tests if the provided credentials can authenticate to Microsoft Graph
    
    .DESCRIPTION
    Attempts to get an access token using the client credentials flow.
    Returns $true if successful, $false otherwise.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,
        
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        
        [Parameter(Mandatory = $true)]
        [string]$ClientSecret
    )
    
    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    
    try {
        $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        
        if ($response.access_token) {
            return $true
        }
        return $false
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            try {
                $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
                $errorMessage = "$($errorJson.error): $($errorJson.error_description)"
            }
            catch {
                $errorMessage = $_.ErrorDetails.Message
            }
        }
        Write-Host "Authentication failed: $errorMessage" -ForegroundColor Red
        return $false
    }
}

#endregion

#region Public Functions

function Add-IntuneTenant {
    <#
    .SYNOPSIS
    Adds a new tenant configuration with encrypted client secret
    
    .DESCRIPTION
    Guides you through Azure AD app registration setup, then stores the tenant
    configuration with an AES-256 encrypted client secret.
    
    .PARAMETER Name
    A friendly name for the tenant (e.g., "School", "District")
    
    .PARAMETER TenantId
    The Azure AD Directory (tenant) ID
    
    .PARAMETER ClientId
    The Application (client) ID from the app registration
    
    .EXAMPLE
    Add-IntuneTenant -Name "School"
    
    .EXAMPLE
    Add-IntuneTenant -Name "District" -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -ClientId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        
        [Parameter(Mandatory = $false)]
        [string]$TenantId,
        
        [Parameter(Mandatory = $false)]
        [string]$ClientId
    )
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Add Intune Tenant: $Name" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Check if tenant already exists
    $config = Read-TenantConfig
    if ($config.tenants.PSObject.Properties.Name -contains $Name) {
        Write-Host "A tenant with name '$Name' already exists." -ForegroundColor Yellow
        Write-Host "To update it, first remove it with: Remove-IntuneTenant -Name '$Name'" -ForegroundColor Yellow
        return
    }
    
    # Display setup instructions if TenantId not provided
    if (-not $TenantId) {
        Write-Host "STEP 1: Find your Tenant ID" -ForegroundColor Green
        Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host "1. Sign in to the Azure Portal: https://portal.azure.com"
        Write-Host "2. Navigate to: Azure Active Directory (or Microsoft Entra ID)"
        Write-Host "3. On the Overview page, copy the 'Tenant ID' (Directory ID)"
        Write-Host ""
        
        $TenantId = Read-Host "Enter Tenant ID (GUID)"
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            Write-Host "Tenant ID is required. Aborting." -ForegroundColor Red
            return
        }
    }
    
    # Validate TenantId format
    if ($TenantId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        Write-Host "Invalid Tenant ID format. Expected a GUID." -ForegroundColor Red
        return
    }
    
    # Display app registration instructions if ClientId not provided
    if (-not $ClientId) {
        Write-Host ""
        Write-Host "STEP 2: Create an App Registration" -ForegroundColor Green
        Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host "1. In Azure Portal, go to: Azure Active Directory -> App registrations"
        Write-Host "2. Click '+ New registration'"
        Write-Host "3. Configure:"
        Write-Host "   - Name: 'Intune Software Deployment' (or any descriptive name)"
        Write-Host "   - Supported account types: 'Single tenant'"
        Write-Host "   - Redirect URI: Leave empty"
        Write-Host "4. Click 'Register'"
        Write-Host "5. Copy the 'Application (client) ID' from the Overview page"
        Write-Host ""
        
        $ClientId = Read-Host "Enter Application (Client) ID (GUID)"
        if ([string]::IsNullOrWhiteSpace($ClientId)) {
            Write-Host "Client ID is required. Aborting." -ForegroundColor Red
            return
        }
    }
    
    # Validate ClientId format
    if ($ClientId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        Write-Host "Invalid Client ID format. Expected a GUID." -ForegroundColor Red
        return
    }
    
    # Instructions for API permissions
    Write-Host ""
    Write-Host "STEP 3: Configure API Permissions" -ForegroundColor Green
    Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "1. In your app registration, go to: API permissions"
    Write-Host "2. Click '+ Add a permission' -> 'Microsoft Graph' -> 'Application permissions'"
    Write-Host "3. Add these permissions:"
    Write-Host "   - DeviceManagementApps.ReadWrite.All" -ForegroundColor Yellow
    Write-Host "   - DeviceManagementConfiguration.ReadWrite.All (optional)" -ForegroundColor Yellow
    Write-Host "   - Group.Read.All (for group assignments)" -ForegroundColor Yellow
    Write-Host "4. Click 'Grant admin consent for [Your Organization]'"
    Write-Host "5. Verify all permissions show green checkmarks"
    Write-Host ""
    
    # Instructions for client secret
    Write-Host "STEP 4: Create a Client Secret" -ForegroundColor Green
    Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "1. In your app registration, go to: Certificates and secrets"
    Write-Host "2. Click '+ New client secret'"
    Write-Host "3. Set description (e.g., 'IntuneDeploymentKey') and expiration"
    Write-Host "4. Click 'Add'"
    Write-Host "5. IMPORTANT: Copy the 'Value' immediately (it will not be shown again!)"
    Write-Host ""
    
    $secureSecret = Read-Host "Enter Client Secret Value" -AsSecureString
    $clientSecretPtr = [System.IntPtr]::Zero
    try {
        $clientSecretPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
        $clientSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($clientSecretPtr)
    }
    finally {
        if ($clientSecretPtr -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($clientSecretPtr)
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($clientSecret)) {
        Write-Host "Client Secret is required. Aborting." -ForegroundColor Red
        return
    }
    
    # Test credentials before storing
    Write-Host ""
    Write-Host "Testing credentials..." -ForegroundColor Cyan
    
    $testResult = Test-IntuneCredentials -TenantId $TenantId -ClientId $ClientId -ClientSecret $clientSecret
    
    if (-not $testResult) {
        Write-Host ""
        Write-Host "Credential test FAILED. Please verify:" -ForegroundColor Red
        Write-Host "  - Tenant ID is correct"
        Write-Host "  - Client ID is correct"
        Write-Host "  - Client Secret is correct (not the Secret ID!)"
        Write-Host "  - API permissions are granted with admin consent"
        Write-Host ""
        Write-Host "Tenant was NOT saved." -ForegroundColor Red
        return
    }
    
    Write-Host "Credential test PASSED!" -ForegroundColor Green
    Write-Host ""
    
    # Get or prompt for master password
    $masterKey = Get-CachedMasterKey
    if (-not $masterKey) {
        Write-Host "STEP 5: Set Encryption Password" -ForegroundColor Green
        Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host "This password encrypts your client secrets in the config file."
        Write-Host "You need to enter it once per PowerShell session."
        Write-Host ""
        
        $securePassword = Read-Host "Enter encryption password" -AsSecureString
        $masterKeyPtr = [System.IntPtr]::Zero
        try {
            $masterKeyPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
            $masterKey = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($masterKeyPtr)
        }
        finally {
            if ($masterKeyPtr -ne [System.IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($masterKeyPtr)
            }
        }
        
        if ([string]::IsNullOrWhiteSpace($masterKey)) {
            Write-Host "Encryption password is required. Aborting." -ForegroundColor Red
            return
        }
        
        # For new config: confirm password
        # For existing config: validate by decrypting an existing entry
        if (-not (Test-Path $script:ConfigFilePath)) {
            # New config - confirm password
            $securePasswordConfirm = Read-Host "Confirm encryption password" -AsSecureString
            $confirmPtr = [System.IntPtr]::Zero
            try {
                $confirmPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePasswordConfirm)
                $masterKeyConfirm = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($confirmPtr)
            }
            finally {
                if ($confirmPtr -ne [System.IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmPtr)
                }
            }
            
            if ($masterKey -ne $masterKeyConfirm) {
                Write-Host "Passwords do not match. Aborting." -ForegroundColor Red
                return
            }
        }
        else {
            # Existing config - validate password by decrypting an existing entry
            $existingTenantNames = $config.tenants.PSObject.Properties.Name
            if ($existingTenantNames.Count -gt 0) {
                $testTenantName = $existingTenantNames | Select-Object -First 1
                $testTenant = $config.tenants.$testTenantName
                $testDecrypt = Unprotect-Secret -EncryptedBase64 $testTenant.encryptedSecret -Password $masterKey
                
                if ($null -eq $testDecrypt) {
                    Write-Host "Incorrect encryption password (could not decrypt existing tenant '$testTenantName')." -ForegroundColor Red
                    Write-Host "Aborting to prevent mixing passwords in the config file." -ForegroundColor Yellow
                    return
                }
                Write-Host "Password verified against existing config." -ForegroundColor Gray
            }
        }
        
        # Cache the master key for this session
        Set-CachedMasterKey -Password $masterKey
    }
    else {
        Write-Host "Using cached encryption password from this session." -ForegroundColor Gray
    }
    
    # Encrypt the client secret
    $encryptedSecret = Protect-Secret -PlainText $clientSecret -Password $masterKey
    
    # Add tenant to config
    $tenantConfig = [PSCustomObject]@{
        tenantId        = $TenantId
        clientId        = $ClientId
        encryptedSecret = $encryptedSecret
    }
    
    # Handle empty tenants object
    if ($null -eq $config.tenants -or $config.tenants -isnot [PSCustomObject]) {
        $config.tenants = [PSCustomObject]@{}
    }
    
    $config.tenants | Add-Member -MemberType NoteProperty -Name $Name -Value $tenantConfig -Force
    
    # Save config
    Write-TenantConfig -Config $config
    
    # Cache the decrypted secret for this session
    Set-CachedTenantSecret -TenantName $Name -Secret $clientSecret
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Tenant '$Name' added successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Configuration saved to: $script:ConfigFilePath"
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  .\Deploy-ToIntune.ps1 -TenantName '$Name' -AppName 'Chrome'"
    Write-Host "  .\Deploy-ToIntune.ps1 -TenantName '$Name' -AssignToAllUsers"
    Write-Host ""
}

function Get-IntuneTenant {
    <#
    .SYNOPSIS
    Retrieves tenant credentials for deployment
    
    .DESCRIPTION
    Gets the tenant configuration, decrypts the client secret (prompting for 
    password if not cached), and returns a credential object.
    
    .PARAMETER Name
    The friendly name of the tenant to retrieve
    
    .OUTPUTS
    PSCustomObject with TenantId, ClientId, and ClientSecret properties
    
    .EXAMPLE
    $creds = Get-IntuneTenant -Name "School"
    .\Deploy-ToIntune.ps1 -TenantId $creds.TenantId -ClientId $creds.ClientId -ClientSecret $creds.ClientSecret
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )
    
    # Check if config file exists
    if (-not (Test-Path $script:ConfigFilePath)) {
        Write-Host "No tenant configuration found." -ForegroundColor Red
        Write-Host "Run 'Add-IntuneTenant -Name `"$Name`"' to set up a tenant." -ForegroundColor Yellow
        return $null
    }
    
    # Read config
    $config = Read-TenantConfig
    
    # Check if tenant exists
    if ($config.tenants.PSObject.Properties.Name -notcontains $Name) {
        Write-Host "Tenant '$Name' not found in configuration." -ForegroundColor Red
        Write-Host ""
        Write-Host "Available tenants:" -ForegroundColor Cyan
        Get-AllIntuneTenants
        return $null
    }
    
    $tenant = $config.tenants.$Name
    
    # Check session cache first
    $cachedSecret = Get-CachedTenantSecret -TenantName $Name
    if ($cachedSecret) {
        return [PSCustomObject]@{
            TenantId     = $tenant.tenantId
            ClientId     = $tenant.clientId
            ClientSecret = $cachedSecret
        }
    }
    
    # Get or prompt for master password, with retry on decryption failure
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $masterKey = Get-CachedMasterKey
        if (-not $masterKey) {
            Write-Host "Enter encryption password for tenant config:" -ForegroundColor Cyan
            $securePassword = Read-Host "Password" -AsSecureString
            $passwordPtr = [System.IntPtr]::Zero
            try {
                $passwordPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
                $masterKey = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
            }
            finally {
                if ($passwordPtr -ne [System.IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
                }
            }
            
            if ([string]::IsNullOrWhiteSpace($masterKey)) {
                Write-Host "Password is required." -ForegroundColor Red
                return $null
            }
        }
        
        # Decrypt the secret
        $clientSecret = Unprotect-Secret -EncryptedBase64 $tenant.encryptedSecret -Password $masterKey
        
        if ($null -ne $clientSecret) {
            # Cache for this session
            Set-CachedMasterKey -Password $masterKey
            Set-CachedTenantSecret -TenantName $Name -Secret $clientSecret
            
            return [PSCustomObject]@{
                TenantId     = $tenant.tenantId
                ClientId     = $tenant.clientId
                ClientSecret = $clientSecret
            }
        }
        
        # Decryption failed: clear cached master key and retry once
        Write-Host "Failed to decrypt client secret. Wrong password?" -ForegroundColor Red
        $global:__IntuneCachedMasterKey = $null
        
        if ($attempt -lt 2) {
            Write-Host "Cleared cached encryption password. Please try again." -ForegroundColor Yellow
        }
    }
    
    # All attempts exhausted
    return $null
}

function Get-AllIntuneTenants {
    <#
    .SYNOPSIS
    Lists all configured tenant names
    
    .DESCRIPTION
    Returns a list of all configured tenants with their names and tenant IDs.
    Does not expose any secrets.
    
    .EXAMPLE
    Get-AllIntuneTenants
    #>
    [CmdletBinding()]
    param()
    
    if (-not (Test-Path $script:ConfigFilePath)) {
        Write-Host "No tenant configuration found." -ForegroundColor Yellow
        Write-Host "Run 'Add-IntuneTenant -Name `"YourTenant`"' to set up a tenant." -ForegroundColor Gray
        return @()
    }
    
    $config = Read-TenantConfig
    $tenantNames = $config.tenants.PSObject.Properties.Name
    
    if ($tenantNames.Count -eq 0) {
        Write-Host "No tenants configured." -ForegroundColor Yellow
        return @()
    }
    
    $tenants = @()
    foreach ($name in $tenantNames) {
        $tenant = $config.tenants.$name
        $tenants += [PSCustomObject]@{
            Name     = $name
            TenantId = $tenant.tenantId
            ClientId = $tenant.clientId
        }
    }
    
    return $tenants
}

function Remove-IntuneTenant {
    <#
    .SYNOPSIS
    Removes a tenant from the configuration
    
    .PARAMETER Name
    The friendly name of the tenant to remove
    
    .PARAMETER Force
    Skip confirmation prompt
    
    .EXAMPLE
    Remove-IntuneTenant -Name "School"
    
    .EXAMPLE
    Remove-IntuneTenant -Name "School" -Force
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    if (-not (Test-Path $script:ConfigFilePath)) {
        Write-Host "No tenant configuration found." -ForegroundColor Red
        return
    }
    
    $config = Read-TenantConfig
    
    if ($config.tenants.PSObject.Properties.Name -notcontains $Name) {
        Write-Host "Tenant '$Name' not found in configuration." -ForegroundColor Red
        return
    }
    
    if (-not $Force) {
        $confirm = Read-Host "Are you sure you want to remove tenant '$Name'? (y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }
    }
    
    # Remove the tenant
    $config.tenants.PSObject.Properties.Remove($Name)
    
    # Save config
    Write-TenantConfig -Config $config
    
    # Clear cached secret
    Clear-CachedTenantSecret -TenantName $Name
    
    Write-Host "Tenant '$Name' removed from configuration." -ForegroundColor Green
}

function Clear-IntuneTenantCache {
    <#
    .SYNOPSIS
    Clears all cached credentials from the current session
    
    .DESCRIPTION
    Removes the master password and all decrypted secrets from the session cache.
    Use this when switching users or before leaving your workstation.
    
    .EXAMPLE
    Clear-IntuneTenantCache
    #>
    [CmdletBinding()]
    param()
    
    # Clear master key
    $global:__IntuneCachedMasterKey = $null
    
    # Clear all tenant secrets
    $global:__IntuneCachedTenantSecrets = @{}
    
    Write-Host "Session cache cleared. You will need to enter the encryption password again." -ForegroundColor Green
}

#endregion

# Export functions (only works when imported as module)
if (($MyInvocation.InvocationName -ne '.') -and ($null -eq $MyInvocation.MyCommand.Module)) {
    # Script is being run directly, not dot-sourced — functions won't remain in the caller's session
    Write-Host "To use these commands in your current PowerShell session, dot-source this script:" -ForegroundColor Cyan
    Write-Host "  . .\TenantConfig.ps1" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "After dot-sourcing, the following commands will be available:" -ForegroundColor Cyan
    Write-Host "  Add-IntuneTenant      - Add a new tenant configuration"
    Write-Host "  Get-IntuneTenant      - Get credentials for a tenant"
    Write-Host "  Get-AllIntuneTenants  - List all configured tenants"
    Write-Host "  Remove-IntuneTenant   - Remove a tenant configuration"
    Write-Host "  Clear-IntuneTenantCache - Clear cached credentials"
}
