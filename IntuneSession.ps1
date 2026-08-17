#Requires -Version 7.4

# IntuneSession.ps1
# Session bootstrap shared by the scripts that talk to a tenant: resolve stored tenant
# credentials, make sure the Graph module is present, and connect. Deploy-ToIntune.ps1 uses
# it today; the inventory and cleanup tooling reuse it. Kept out of SharedFunctions.ps1 so the
# packaging script does not drag in tenant credentials or Graph authentication.

. (Join-Path $PSScriptRoot "AuthenticationManager.ps1")
. (Join-Path $PSScriptRoot "TenantConfig.ps1")

# Check and install required modules. Only Microsoft.Graph.Authentication is mandatory -
# Intune API calls are native Graph requests (see IntuneInterop.ps1). Microsoft.Graph.Groups
# is needed only for group assignments and is resolved lazily where those are made.
function Install-RequiredModules {
    param(
        [switch]$SkipInstallation
    )

    Write-Host "Checking required modules..." -ForegroundColor Cyan

    $requiredModules = @(
        "Microsoft.Graph.Authentication"
    )

    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            Write-Host "Module '$moduleName' not found. Installing..." -ForegroundColor Yellow
            try {
                if (-not $SkipInstallation) {
                    Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                    Write-Host "Successfully installed $moduleName" -ForegroundColor Green
                }
                else {
                    Write-Host "Skipping installation of $moduleName (use without -SkipInstallation to install)" -ForegroundColor Yellow
                    return $false
                }
            }
            catch {
                Write-Host "Failed to install $moduleName : $_" -ForegroundColor Red
                return $false
            }
        }
        else {
            Write-Host "Module '$moduleName' is already installed" -ForegroundColor Green
        }
    }

    return $true
}

# Resolves a tenant name to its stored credentials (prompting for the master password when it is
# not cached). Returns the credential object, or $null after printing setup guidance.
function Resolve-IntuneTenantCredential {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantName
    )

    Write-Host "Loading credentials for tenant '$TenantName'..." -ForegroundColor Cyan
    $tenantCreds = Get-IntuneTenant -Name $TenantName

    if ($null -eq $tenantCreds) {
        Write-Host "Failed to retrieve credentials for tenant '$TenantName'." -ForegroundColor Red
        Write-Host ""
        Write-Host "To configure a new tenant, run:" -ForegroundColor Yellow
        Write-Host "  . .\TenantConfig.ps1" -ForegroundColor Gray
        Write-Host "  Add-IntuneTenant -Name '$TenantName'" -ForegroundColor Gray
        return $null
    }

    Write-Host "Credentials loaded for tenant: $TenantName (TenantId: $($tenantCreds.TenantId))" -ForegroundColor Green
    return $tenantCreds
}

# Ensures the required modules and connects to Microsoft Intune with client credentials.
# Returns $true when connected; $false after printing the reason (the caller decides to exit).
function Connect-IntuneTenantSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [string]$ClientId,

        [string]$ClientSecret,

        [switch]$SkipInstallation,

        # Shown when ClientId/ClientSecret are missing, so each script can print its own usage line
        [string]$UsageHint = '.\Deploy-ToIntune.ps1 -TenantId <tenant> -ClientId <id> -ClientSecret <secret>'
    )

    if (-not (Install-RequiredModules -SkipInstallation:$SkipInstallation)) {
        Write-Host "`nCannot proceed without required modules." -ForegroundColor Red
        Write-Host "Run the script without -SkipInstallation to install them automatically." -ForegroundColor Yellow
        return $false
    }

    Write-Host "`nConnecting to Microsoft Intune..." -ForegroundColor Cyan
    Write-Host "Tenant ID: $TenantId" -ForegroundColor Gray

    if (-not $ClientId -or -not $ClientSecret) {
        Write-Host "Error: ClientId and ClientSecret are required for authentication" -ForegroundColor Red
        Write-Host "Usage: $UsageHint" -ForegroundColor Yellow
        return $false
    }

    Write-Host "Using app-based authentication (Client ID: $ClientId)" -ForegroundColor Gray

    if (-not (Initialize-IntuneAuthentication -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret)) {
        Write-Host "`nAuthentication failed. Exiting." -ForegroundColor Red
        return $false
    }

    Write-Host "Successfully connected to Microsoft Intune!" -ForegroundColor Green
    return $true
}
