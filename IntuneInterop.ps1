#Requires -Version 7.4

# IntuneInterop.ps1
# The single boundary between this repository and the external IntuneWin32App module.
#
# No other script may call IntuneWin32App cmdlets or touch the module's internals -
# CI enforces this (see the boundary check in pwsh-validate.yml). Wrapper functions
# accept plain domain values (strings, bools, hashtables) and return the Graph-schema
# shaped hashtables the module builders produce, so issue #9 can swap each
# implementation for native Microsoft Graph calls without changing any caller.

$script:InteropModuleName = 'IntuneWin32App'

#region Module bootstrap

function Install-InteropModule {
    <#
    .SYNOPSIS
    Ensures the backing module is installed, installing it unless -SkipInstallation

    .OUTPUTS
    Boolean - $true when the module is available
    #>
    [CmdletBinding()]
    param(
        [switch]$SkipInstallation
    )

    if (Get-Module -ListAvailable -Name $script:InteropModuleName) {
        Write-Host "Module '$script:InteropModuleName' is already installed" -ForegroundColor Green
        return $true
    }

    Write-Host "Module '$script:InteropModuleName' not found. Installing..." -ForegroundColor Yellow
    if ($SkipInstallation) {
        Write-Host "Skipping installation of $script:InteropModuleName (use without -SkipInstallation to install)" -ForegroundColor Yellow
        return $false
    }

    try {
        Install-Module -Name $script:InteropModuleName -Scope CurrentUser -Force -AllowClobber
        Write-Host "Successfully installed $script:InteropModuleName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to install $script:InteropModuleName : $_" -ForegroundColor Red
        return $false
    }
}

#endregion

#region Authentication

function Initialize-InteropAuth {
    <#
    .SYNOPSIS
    Prepares the backing module's authentication state from client credentials

    .DESCRIPTION
    The IntuneWin32App module authenticates via the deprecated MSAL.PS, so instead a
    token is requested directly from Entra ID and the global variables the module's
    Test-AuthenticationState expects are populated. Failure is non-fatal: a warning is
    written and $false returned, matching the previous inline behavior.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$ClientSecret
    )

    Write-Verbose "Authenticating $script:InteropModuleName module..."
    try {
        # Get access token directly from Entra ID
        $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://graph.microsoft.com/.default"
        }

        $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        $accessToken = $response.access_token

        # ExpiresOn handling for module compatibility on non-English locales:
        # - AuthenticationHeader.ExpiresOn must be [DateTime] (UTC) because
        #   New-IntuneWin32AppSupersedence does DateTime subtraction on it.
        # - AccessToken.ExpiresOn needs a wrapper because Test-AccessToken calls
        #   .ToString() then parses with InvariantCulture - bare DateTime.ToString()
        #   uses CurrentCulture which fails on e.g. German locale (dd.MM.yyyy).
        $expiresOnUtc = (Get-Date).ToUniversalTime().AddSeconds($response.expires_in)

        $expiresOnWrapped = New-Object -TypeName PSObject
        $expiresOnWrapped | Add-Member -MemberType NoteProperty -Name '_utc' -Value $expiresOnUtc
        $expiresOnWrapped | Add-Member -MemberType ScriptMethod -Name 'ToUniversalTime' -Value {
            return $this._utc
        }
        $expiresOnWrapped | Add-Member -MemberType ScriptMethod -Name 'ToString' -Force -Value {
            return $this._utc.ToString('o')
        }

        # Create the authentication header structure that the module expects
        # ExpiresOn as plain [DateTime] for arithmetic support in supersedence cmdlets
        $Global:AuthenticationHeader = @{
            "Authorization" = "Bearer $accessToken"
            "Content-Type"  = "application/json"
            "ExpiresOn"     = $expiresOnUtc
        }

        # Also set the AccessToken variable that some cmdlets check
        # Must be PSCustomObject so Test-AccessToken can find ExpiresOn via .PSObject.Properties
        # ExpiresOn uses wrapper for culture-invariant ToString()
        $Global:AccessToken = [PSCustomObject]@{
            AccessToken = $accessToken
            ExpiresOn   = $expiresOnWrapped
        }

        # Set tenant ID variable required by the module's Test-AuthenticationState
        $Global:AccessTokenTenantID = $TenantId

        Write-Verbose "$script:InteropModuleName authentication header configured"
        return $true
    }
    catch {
        Write-Warning "Failed to configure $script:InteropModuleName authentication: $_"
        Write-Warning "$script:InteropModuleName cmdlets may not work properly"
        return $false
    }
}

#endregion

#region Package metadata

function Get-InteropPackageMetadata {
    <#
    .SYNOPSIS
    Reads the metadata (Detection.xml) embedded in an .intunewin package
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    return Get-IntuneWin32AppMetaData -FilePath $FilePath
}

#endregion

#region Detection and requirement rule builders

function New-InteropFileDetectionRule {
    <#
    .SYNOPSIS
    Builds a file-system version detection rule (win32LobAppFileSystemDetection)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$FileOrFolder,

        [Parameter(Mandatory = $true)]
        [string]$Operator,

        [Parameter(Mandatory = $true)]
        [string]$VersionValue,

        [bool]$Check32BitOn64System = $false
    )

    return New-IntuneWin32AppDetectionRuleFile `
        -Version `
        -Path $Path `
        -FileOrFolder $FileOrFolder `
        -Check32BitOn64System $Check32BitOn64System `
        -Operator $Operator `
        -VersionValue $VersionValue
}

function New-InteropMsiDetectionRule {
    <#
    .SYNOPSIS
    Builds an MSI product-code detection rule (win32LobAppProductCodeDetection)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProductCode
    )

    return New-IntuneWin32AppDetectionRuleMSI -ProductCode $ProductCode
}

function New-InteropRegistryExistenceDetectionRule {
    <#
    .SYNOPSIS
    Builds a registry existence detection rule (win32LobAppRegistryDetection)

    .PARAMETER DetectionType
    'exists' or 'doesNotExist'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('exists', 'doesNotExist')]
        [string]$DetectionType,

        [string]$ValueName,

        [bool]$Check32BitOn64System = $false
    )

    $params = @{
        Existence            = $true
        KeyPath              = $KeyPath
        DetectionType        = $DetectionType
        Check32BitOn64System = $Check32BitOn64System
    }
    if ($ValueName) {
        $params['ValueName'] = $ValueName
    }

    return New-IntuneWin32AppDetectionRuleRegistry @params
}

function New-InteropRegistryVersionDetectionRule {
    <#
    .SYNOPSIS
    Builds a registry version-comparison detection rule (win32LobAppRegistryDetection)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,

        [Parameter(Mandatory = $true)]
        [string]$ValueName,

        [Parameter(Mandatory = $true)]
        [string]$Operator,

        [Parameter(Mandatory = $true)]
        [string]$VersionValue,

        [bool]$Check32BitOn64System = $false
    )

    return New-IntuneWin32AppDetectionRuleRegistry `
        -VersionComparison `
        -KeyPath $KeyPath `
        -ValueName $ValueName `
        -VersionComparisonOperator $Operator `
        -VersionComparisonValue $VersionValue `
        -Check32BitOn64System $Check32BitOn64System
}

function New-InteropScriptDetectionRule {
    <#
    .SYNOPSIS
    Builds a PowerShell script detection rule (win32LobAppPowerShellScriptDetection)

    .DESCRIPTION
    Takes the script CONTENT rather than a file path; the temp file the backing module
    requires is created and cleaned up here, inside the boundary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptContent,

        [bool]$EnforceSignatureCheck = $false,

        [bool]$RunAs32Bit = $false
    )

    $tempScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("InteropDetect-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    try {
        $ScriptContent | Out-File -FilePath $tempScriptPath -Encoding UTF8 -Force
        return New-IntuneWin32AppDetectionRuleScript `
            -ScriptFile $tempScriptPath `
            -EnforceSignatureCheck $EnforceSignatureCheck `
            -RunAs32Bit $RunAs32Bit
    }
    finally {
        Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
    }
}

function New-InteropRequirementRule {
    <#
    .SYNOPSIS
    Builds the architecture / minimum-OS requirement rule
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$MinimumSupportedOperatingSystem
    )

    return New-IntuneWin32AppRequirementRule `
        -Architecture $Architecture `
        -MinimumSupportedOperatingSystem $MinimumSupportedOperatingSystem
}

#endregion

#region Icons

function New-InteropAppIcon {
    <#
    .SYNOPSIS
    Converts an image file into the icon object expected on app creation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    return New-IntuneWin32AppIcon -FilePath $FilePath
}

#endregion

#region App CRUD

function Get-InteropWin32App {
    <#
    .SYNOPSIS
    Retrieves Win32 apps from Intune, optionally filtered by exact display name
    #>
    [CmdletBinding()]
    param(
        [string]$DisplayName
    )

    # Forward an explicitly passed -ErrorAction to the module call: preference-variable
    # propagation does not reliably cross script-module boundaries, so relying on it
    # would change behavior vs the previous direct calls.
    $forward = @{}
    if ($PSBoundParameters.ContainsKey('ErrorAction')) {
        $forward['ErrorAction'] = $PSBoundParameters['ErrorAction']
    }

    if ($DisplayName) {
        return Get-IntuneWin32App -DisplayName $DisplayName @forward
    }
    return Get-IntuneWin32App @forward
}

function Publish-InteropWin32App {
    <#
    .SYNOPSIS
    Creates a Win32 app in Intune and uploads its .intunewin content

    .PARAMETER AppParams
    Hashtable with FilePath, DisplayName, Description, Publisher, AppVersion,
    InstallExperience, RestartBehavior, DetectionRule, RequirementRule,
    InstallCommandLine, UninstallCommandLine, and optionally Icon / Verbose.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AppParams
    )

    return Add-IntuneWin32App @AppParams -ErrorAction Stop
}

#endregion

#region Assignments

function Get-InteropAppAssignment {
    <#
    .SYNOPSIS
    Returns the app's existing assignment targets, normalized to plain strings

    .OUTPUTS
    String array containing 'AllUsers', 'AllDevices', and/or 'Group:<groupId>'.
    Returns an empty array when assignments cannot be read (callers then simply
    attempt each assignment, which was the previous behavior).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId
    )

    $targets = @()
    try {
        foreach ($existing in @(Get-IntuneWin32AppAssignment -ID $AppId -ErrorAction Stop)) {
            switch -Wildcard ($existing.Type) {
                '*allLicensedUsersAssignmentTarget' { $targets += 'AllUsers' }
                '*allDevicesAssignmentTarget'       { $targets += 'AllDevices' }
                '*groupAssignmentTarget'            { $targets += "Group:$($existing.GroupID)" }
            }
        }
    }
    catch {
        Write-Verbose "Could not read existing assignments for app '$AppId': $($_.Exception.Message)"
    }
    # Plain return: the pipeline unrolls the array and callers collect with @(...),
    # which also yields an empty array when there are no targets. Returning ", $targets"
    # here would make @(...) produce a nested single-element array and break -contains.
    return $targets
}

function Add-InteropAllUsersAssignment {
    <#
    .SYNOPSIS
    Assigns the app to All Users; returns the created assignment (with .id) or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [string]$Intent = 'available',

        [string]$Notification = 'showAll',

        # Request "auto update superseded apps" on this assignment. The module only
        # writes the setting when the intent is 'available'.
        [bool]$AutoUpdateSuperseded = $false
    )

    $params = @{ ID = $AppId; Intent = $Intent; Notification = $Notification }
    if ($AutoUpdateSuperseded) {
        $params['AutoUpdateSupersededApps'] = 'enabled'
    }
    return Add-IntuneWin32AppAssignmentAllUsers @params
}

function Add-InteropAllDevicesAssignment {
    <#
    .SYNOPSIS
    Assigns the app to All Devices; returns the created assignment (with .id) or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [string]$Intent = 'required',

        [string]$Notification = 'showAll'
    )

    return Add-IntuneWin32AppAssignmentAllDevices -ID $AppId -Intent $Intent -Notification $Notification
}

function Add-InteropGroupAssignment {
    <#
    .SYNOPSIS
    Assigns the app to an Entra ID group; returns the created assignment (with .id) or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        [string]$GroupId,

        [string]$Intent = 'available',

        [string]$Notification = 'showAll',

        # Only valid with intent 'available' - the module rejects it outright otherwise
        [bool]$AutoUpdateSuperseded = $false
    )

    $params = @{ Include = $true; ID = $AppId; GroupID = $GroupId; Intent = $Intent; Notification = $Notification }
    if ($AutoUpdateSuperseded -and $Intent -eq 'available') {
        $params['AutoUpdateSupersededApps'] = 'enabled'
    }
    return Add-IntuneWin32AppAssignmentGroup @params
}

#endregion

#region Relationships (supersedence / dependencies)

function Add-InteropSupersedence {
    <#
    .SYNOPSIS
    Marks the app as superseding an older app (Update keeps it, Replace uninstalls it)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        [string]$SupersededAppId,

        [ValidateSet('Update', 'Replace')]
        [string]$SupersedenceType = 'Update'
    )

    $supersedence = New-IntuneWin32AppSupersedence -ID $SupersededAppId -SupersedenceType $SupersedenceType
    Add-IntuneWin32AppSupersedence -ID $AppId -Supersedence $supersedence -Verbose
}

function Add-InteropDependency {
    <#
    .SYNOPSIS
    Links the app to the apps it depends on (installed automatically first)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        [string[]]$DependencyAppIds,

        [string]$DependencyType = 'AutoInstall'
    )

    $dependencies = foreach ($dependencyAppId in $DependencyAppIds) {
        New-IntuneWin32AppDependency -ID $dependencyAppId -DependencyType $DependencyType
    }
    Add-IntuneWin32AppDependency -ID $AppId -Dependency @($dependencies) -Verbose
}

#endregion
