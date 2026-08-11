#Requires -Version 7.4

# Authentication Manager Module
# Centralized authentication for Microsoft Intune operations

# The Intune module's auth shim lives behind the interop boundary
. (Join-Path $PSScriptRoot "IntuneInterop.ps1")

<#
.SYNOPSIS
    Centralized authentication management for Intune operations using Microsoft.Graph SDK

.DESCRIPTION
    This module provides unified authentication functions using modern Microsoft.Graph SDK
    authentication. The Intune module's own authentication state is prepared through the
    IntuneInterop.ps1 boundary (Initialize-InteropAuth).
#>

function Initialize-IntuneAuthentication {
    <#
    .SYNOPSIS
        Establishes authenticated connection to Microsoft Intune via Microsoft.Graph SDK
    
    .DESCRIPTION
        Connects to Microsoft Graph with required permissions for Intune app management.
        Uses app-based authentication with ClientId and ClientSecret.
        
        Required permissions:
        - DeviceManagementApps.ReadWrite.All
        - DeviceManagementConfiguration.ReadWrite.All
        - Group.Read.All
    
    .PARAMETER TenantId
        Azure AD Tenant ID (GUID)
    
    .PARAMETER ClientId
        Azure AD App Registration Client ID (Application ID)
    
    .PARAMETER ClientSecret
        Azure AD App Registration Client Secret
    
    .PARAMETER RequiredScopes
        Optional array of required permission scopes. Defaults to Intune management scopes.
    
    .EXAMPLE
        Initialize-IntuneAuthentication -TenantId "00000000-0000-0000-0000-000000000000" -ClientId "abc123" -ClientSecret "secret123"
    
    .OUTPUTS
        Boolean - $true if connection successful, $false otherwise
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,
        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientId,
        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientSecret,
        
        [Parameter(Mandatory = $false)]
        [string[]]$RequiredScopes = @(
            "DeviceManagementApps.ReadWrite.All",
            "DeviceManagementConfiguration.ReadWrite.All", 
            "Group.Read.All"
        )
    )
    
    Write-Verbose "Initializing Microsoft Graph authentication..."
    Write-Verbose "Tenant ID: $TenantId"
    Write-Verbose "Client ID: $ClientId"
    Write-Verbose "Required Scopes: $($RequiredScopes -join ', ')"
    
    try {
        # Check if already connected to the correct tenant
        $existingContext = Get-MgContext -ErrorAction SilentlyContinue
        if ($existingContext -and $existingContext.TenantId -eq $TenantId) {
            Write-Verbose "Already connected to tenant $TenantId"
            
            # Verify the connection is still valid
            if (Test-IntuneConnection) {
                Write-Verbose "Existing connection is valid, reusing"
                return $true
            }
            else {
                Write-Verbose "Existing connection is invalid, reconnecting"
                Disconnect-MgGraph -ErrorAction SilentlyContinue
            }
        }
        
        # Create PSCredential from ClientId and ClientSecret
        $credential = Get-IntuneAuthCredential -ClientId $ClientId -ClientSecret $ClientSecret
        
        # Connect to Microsoft Graph using app-based authentication
        Write-Verbose "Connecting to Microsoft Graph..."
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome -ErrorAction Stop
        
        # Verify connection was successful
        $context = Get-MgContext
        if (-not $context) {
            Write-Error "Failed to establish Microsoft Graph connection"
            return $false
        }
        
        Write-Verbose "Successfully connected to Microsoft Graph"
        Write-Verbose "Auth Type: $($context.AuthType)"
        Write-Verbose "Account: $($context.Account)"
        
        # Prepare the Intune module's authentication state. The shim lives inside the
        # interop boundary (IntuneInterop.ps1); failure warns but is non-fatal.
        $null = Initialize-InteropAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
        
        # Validate we can access Intune endpoints
        if (Test-IntuneConnection) {
            Write-Verbose "Intune API access verified"
            return $true
        }
        else {
            Write-Error "Connected to Graph but cannot access Intune endpoints"
            return $false
        }
    }
    catch {
        Write-Error "Failed to initialize Intune authentication: $_"
        Write-Verbose "Exception details: $($_.Exception.Message)"
        return $false
    }
}

function Test-IntuneConnection {
    <#
    .SYNOPSIS
        Tests whether an active and valid Intune connection exists
    
    .DESCRIPTION
        Validates Microsoft Graph connection and verifies access to Intune APIs.
        This function performs a lightweight API call to confirm connectivity.
    
    .PARAMETER Detailed
        Returns detailed connection information instead of just boolean
    
    .EXAMPLE
        if (Test-IntuneConnection) { Write-Host "Connected" }
    
    .EXAMPLE
        $details = Test-IntuneConnection -Detailed
        Write-Host "Tenant: $($details.TenantId)"
    
    .OUTPUTS
        Boolean (default) or PSCustomObject (with -Detailed switch)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )
    
    $result = [PSCustomObject]@{
        IsConnected = $false
        Method      = $null
        TenantId    = $null
        Account     = $null
        Scopes      = @()
        ApiAccess   = $false
        ErrorMessage = $null
    }
    
    try {
        # Check if Microsoft.Graph context exists
        $context = Get-MgContext -ErrorAction Stop
        
        if (-not $context) {
            $result.ErrorMessage = "No Microsoft Graph context found"
            if ($Detailed) { return $result } else { return $false }
        }
        
        # Populate connection details
        $result.Method = if ($context.AuthType -eq 'AppOnly') { 'App-Based' } else { 'Delegated' }
        $result.TenantId = $context.TenantId
        $result.Account = $context.Account
        $result.Scopes = $context.Scopes
        $result.IsConnected = $true
        
        # Test actual API access with a lightweight query
        Write-Verbose "Testing Intune API access..."
        $testUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=1"
        $null = Invoke-MgGraphRequest -Uri $testUri -Method GET -ErrorAction Stop
        
        $result.ApiAccess = $true
        Write-Verbose "Intune API access confirmed"
        
        if ($Detailed) {
            return $result
        }
        else {
            return $true
        }
    }
    catch {
        $result.IsConnected = $false
        $result.ApiAccess = $false
        $result.ErrorMessage = $_.Exception.Message
        Write-Verbose "Connection test failed: $($_.Exception.Message)"
        
        if ($Detailed) {
            return $result
        }
        else {
            return $false
        }
    }
}

function Get-IntuneAuthCredential {
    <#
    .SYNOPSIS
        Creates a PSCredential object from ClientId and ClientSecret
    
    .DESCRIPTION
        Helper function to build a PSCredential object required by Connect-MgGraph.
        The ClientId becomes the username and ClientSecret becomes the secure password.
    
    .PARAMETER ClientId
        Azure AD App Registration Client ID
    
    .PARAMETER ClientSecret
        Azure AD App Registration Client Secret (plain text)
    
    .EXAMPLE
        $cred = Get-IntuneAuthCredential -ClientId "abc123" -ClientSecret "secret123"
    
    .OUTPUTS
        PSCredential object
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientId,
        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientSecret
    )
    
    try {
        Write-Verbose "Creating PSCredential for Client ID: $ClientId"
        
        # Convert plain text secret to secure string
        $secureSecret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
        
        # Create credential object (ClientId as username, ClientSecret as password)
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ClientId, $secureSecret
        
        Write-Verbose "PSCredential created successfully"
        return $credential
    }
    catch {
        Write-Error "Failed to create PSCredential: $_"
        return $null
    }
}

function Disconnect-IntuneSession {
    <#
    .SYNOPSIS
        Disconnects from Microsoft Graph and cleans up authentication session
    
    .DESCRIPTION
        Properly terminates the Microsoft Graph connection and clears authentication state.
        Should be called at the end of scripts to ensure clean session termination.
    
    .PARAMETER Force
        Suppresses any disconnection errors
    
    .EXAMPLE
        Disconnect-IntuneSession
    
    .EXAMPLE
        Disconnect-IntuneSession -Force
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    try {
        $context = Get-MgContext -ErrorAction SilentlyContinue
        
        if ($context) {
            Write-Verbose "Disconnecting from Microsoft Graph (Tenant: $($context.TenantId))..."
            Disconnect-MgGraph -ErrorAction Stop
            Write-Verbose "Successfully disconnected from Microsoft Graph"
        }
        else {
            Write-Verbose "No active Microsoft Graph session to disconnect"
        }
    }
    catch {
        if ($Force) {
            Write-Verbose "Disconnect error suppressed (Force mode): $_"
        }
        else {
            Write-Warning "Failed to disconnect from Microsoft Graph: $_"
        }
    }
}
