#Requires -Version 7.4

# IntuneInterop.ps1
# The single boundary between this repository and the external IntuneWin32App module.
#
# No other script may call IntuneWin32App cmdlets or touch the module's internals -
# CI enforces this (see the boundary check in pwsh-validate.yml). Wrapper functions
# accept plain domain values (strings, bools, hashtables) and return Graph-schema
# shaped hashtables, so issue #9 can swap each implementation for native Microsoft
# Graph calls without changing any caller.
#
# Migration state (#9): package metadata, detection/requirement rule builders, icons,
# read-only Graph queries, assignments, and relationship writes are native. Only app
# creation/upload (Publish-InteropWin32App) is still backed by the IntuneWin32App module.

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

    .DESCRIPTION
    Native implementation: opens the .intunewin zip and parses the Detection.xml
    entry. Matching the previous module behavior, failures warn and return $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
        try {
            $entry = $archive.Entries | Where-Object { $_.Name -like 'detection.xml' } | Select-Object -First 1
            if ($null -eq $entry) {
                Write-Warning "No detection.xml entry found inside '$FilePath'"
                return $null
            }

            $reader = [System.IO.StreamReader]::new($entry.Open())
            try {
                return [xml]$reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        Write-Warning "Could not read metadata from '$FilePath': $($_.Exception.Message)"
        return $null
    }
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

    return [ordered]@{
        '@odata.type'          = '#microsoft.graph.win32LobAppFileSystemDetection'
        'operator'             = $Operator
        'detectionValue'       = $VersionValue
        'path'                 = $Path
        'fileOrFolderName'     = $FileOrFolder
        'check32BitOn64System' = $Check32BitOn64System
        'detectionType'        = 'version'
    }
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

    return [ordered]@{
        '@odata.type'            = '#microsoft.graph.win32LobAppProductCodeDetection'
        'productCode'            = $ProductCode
        'productVersionOperator' = 'notConfigured'
        'productVersion'         = ''
    }
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

        # Defaults to '' explicitly: the output shape always carries valueName, as an
        # empty string for key-only existence checks (matching the module's output)
        [string]$ValueName = '',

        [bool]$Check32BitOn64System = $false
    )

    # valueName is always present (empty string when not provided), matching the
    # module's output shape.
    return [ordered]@{
        '@odata.type'          = '#microsoft.graph.win32LobAppRegistryDetection'
        'operator'             = 'notConfigured'
        'detectionValue'       = $null
        'check32BitOn64System' = $Check32BitOn64System
        'keyPath'              = $KeyPath
        'valueName'            = $ValueName
        'detectionType'        = $DetectionType
    }
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

    return [ordered]@{
        '@odata.type'          = '#microsoft.graph.win32LobAppRegistryDetection'
        'operator'             = $Operator
        'detectionValue'       = $VersionValue
        'check32BitOn64System' = $Check32BitOn64System
        'keyPath'              = $KeyPath
        'valueName'            = $ValueName
        'detectionType'        = 'version'
    }
}

function New-InteropScriptDetectionRule {
    <#
    .SYNOPSIS
    Builds a PowerShell script detection rule (win32LobAppPowerShellScriptDetection)

    .DESCRIPTION
    Takes the script CONTENT rather than a file path; the content is base64-encoded
    directly into the rule, no temp file involved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptContent,

        [bool]$EnforceSignatureCheck = $false,

        [bool]$RunAs32Bit = $false
    )

    return [ordered]@{
        '@odata.type'           = '#microsoft.graph.win32LobAppPowerShellScriptDetection'
        'enforceSignatureCheck' = $EnforceSignatureCheck
        'runAs32Bit'            = $RunAs32Bit
        'scriptContent'         = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ScriptContent))
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
        [ValidateSet('x64', 'x86', 'arm64', 'x64x86', 'AllWithARM64')]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [ValidateSet('W10_1607', 'W10_1703', 'W10_1709', 'W10_1803', 'W10_1809', 'W10_1903', 'W10_1909', 'W10_2004', 'W10_20H2', 'W10_21H1', 'W10_21H2', 'W10_22H2', 'W11_21H2', 'W11_22H2')]
        [string]$MinimumSupportedOperatingSystem
    )

    $architectureTable = @{
        'x64'          = 'x64'
        'x86'          = 'x86'
        'arm64'        = 'arm64'
        'x64x86'       = 'x64,x86'
        'AllWithARM64' = 'x64,x86,arm64'
    }

    # Service enum values ("2H20" for 20H2 is not a typo - it is what the Graph
    # service expects for that release)
    $operatingSystemTable = @{
        'W10_1607' = '1607'
        'W10_1703' = '1703'
        'W10_1709' = '1709'
        'W10_1803' = '1803'
        'W10_1809' = '1809'
        'W10_1903' = '1903'
        'W10_1909' = '1909'
        'W10_2004' = '2004'
        'W10_20H2' = '2H20'
        'W10_21H1' = '21H1'
        'W10_21H2' = 'Windows10_21H2'
        'W10_22H2' = 'Windows10_22H2'
        'W11_21H2' = 'Windows11_21H2'
        'W11_22H2' = 'Windows11_22H2'
    }

    return [ordered]@{
        'allowedArchitectures'           = $architectureTable[$Architecture]
        'applicableArchitectures'        = 'none'
        'minimumSupportedWindowsRelease' = $operatingSystemTable[$MinimumSupportedOperatingSystem]
    }
}

#endregion

#region Icons

function New-InteropAppIcon {
    <#
    .SYNOPSIS
    Converts an image file into the base64 string expected on app creation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($FilePath))
}

#endregion

#region App CRUD

function Get-InteropWin32App {
    <#
    .SYNOPSIS
    Retrieves Win32 apps from Intune, optionally filtered by display name (contains match)

    .DESCRIPTION
    Native Graph implementation, mirroring the module's proven two-step pattern:
    a paged isof-filtered list, then a per-ID GET for each app. The per-ID GETs are
    required because the list endpoint validates $select against the base
    microsoft.graph.mobileApp type - derived win32LobApp properties (displayVersion)
    cannot be $select-ed there and list items are not guaranteed to carry them.
    -DisplayName keeps the module's contains-match semantics (filtered before the
    per-ID fetches).
    #>
    [CmdletBinding()]
    param(
        [string]$DisplayName
    )

    # Forward an explicitly passed -ErrorAction (e.g. SilentlyContinue from the
    # post-upload retry lookup) to the Graph calls.
    $forward = @{}
    if ($PSBoundParameters.ContainsKey('ErrorAction')) {
        $forward['ErrorAction'] = $PSBoundParameters['ErrorAction']
    }

    $summaries = [System.Collections.Generic.List[object]]::new()
    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')"
    while ($uri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject @forward
        if ($null -eq $response) {
            # Request failed under a suppressed error action - return what we have
            break
        }
        foreach ($item in @($response.value)) {
            $summaries.Add($item)
        }
        $uri = $response.'@odata.nextLink'
    }

    if ($DisplayName) {
        # Literal case-insensitive contains rather than -like: app names with wildcard
        # metacharacters (e.g. '[') would otherwise fail to match themselves
        $summaries = @($summaries | Where-Object { $_.displayName -and $_.displayName.Contains($DisplayName, [System.StringComparison]::OrdinalIgnoreCase) })
    }

    $apps = [System.Collections.Generic.List[object]]::new()
    foreach ($summary in $summaries) {
        $app = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($summary.id)" -OutputType PSObject @forward
        if ($null -ne $app) {
            $apps.Add($app)
        }
    }
    return $apps
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

#region Native Graph helpers (internal)

function New-InteropAssignmentBody {
    <#
    .SYNOPSIS
    Internal: builds the mobileAppAssignment body shared by the three assignment wrappers
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Intent,

        [Parameter(Mandatory = $true)]
        [string]$Notification,

        [Parameter(Mandatory = $true)]
        [hashtable]$Target,

        # The app object (needed for supersededAppCount)
        [Parameter(Mandatory = $true)]
        $App,

        [bool]$AutoUpdateSuperseded = $false
    )

    $body = [ordered]@{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        'intent'      = $Intent
        'source'      = 'direct'
        'target'      = $Target
        'settings'    = @{
            '@odata.type'                  = '#microsoft.graph.win32LobAppAssignmentSettings'
            'notifications'                = $Notification
            'restartSettings'              = $null
            'deliveryOptimizationPriority' = 'notConfigured'
            'installTimeSettings'          = $null
        }
    }

    # The service only accepts autoUpdateSettings when the intent is 'available' and
    # the app actually supersedes something (matching the module's conditional)
    if ($Intent -eq 'available' -and $App.supersededAppCount -gt 0) {
        $body.settings.autoUpdateSettings = @{
            'autoUpdateSupersededAppsState' = $AutoUpdateSuperseded ? 'enabled' : 'notConfigured'
        }
    }

    return $body
}

function Get-InteropAppRelationship {
    <#
    .SYNOPSIS
    Internal: returns an app's relationship objects, optionally filtered by @odata.type
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [string]$ODataType
    )

    $relationships = [System.Collections.Generic.List[object]]::new()
    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/relationships"
    while ($uri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
        foreach ($relationship in @($response.value)) {
            $relationships.Add($relationship)
        }
        $uri = $response.'@odata.nextLink'
    }

    if ($ODataType) {
        return @($relationships | Where-Object { $_.'@odata.type' -eq $ODataType })
    }
    return $relationships
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
        $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments"
        while ($uri) {
            $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
            foreach ($assignment in @($response.value)) {
                switch -Wildcard ($assignment.target.'@odata.type') {
                    '*allLicensedUsersAssignmentTarget' { $targets += 'AllUsers' }
                    '*allDevicesAssignmentTarget'       { $targets += 'AllDevices' }
                    '*groupAssignmentTarget'            { $targets += "Group:$($assignment.target.groupId)" }
                }
            }
            $uri = $response.'@odata.nextLink'
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

        # Request "auto update superseded apps" on this assignment. Only written when
        # the intent is 'available' and the app supersedes something.
        [bool]$AutoUpdateSuperseded = $false
    )

    try {
        $app = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId" -OutputType PSObject -ErrorAction Stop

        $target = @{
            '@odata.type'                                = '#microsoft.graph.allLicensedUsersAssignmentTarget'
            'deviceAndAppManagementAssignmentFilterId'   = $null
            'deviceAndAppManagementAssignmentFilterType' = 'none'
        }
        $body = New-InteropAssignmentBody -Intent $Intent -Notification $Notification -Target $target -App $app -AutoUpdateSuperseded $AutoUpdateSuperseded

        return Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
    }
    catch {
        # Warn-and-return-$null matches the module: callers report "assignment was
        # NOT created" and continue with the rest of the deployment
        Write-Warning "An error occurred while creating the All Users assignment for app '$AppId': $($_.Exception.Message)"
        return $null
    }
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

    try {
        $app = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId" -OutputType PSObject -ErrorAction Stop

        $target = @{
            '@odata.type'                                = '#microsoft.graph.allDevicesAssignmentTarget'
            'deviceAndAppManagementAssignmentFilterId'   = $null
            'deviceAndAppManagementAssignmentFilterType' = 'none'
        }
        $body = New-InteropAssignmentBody -Intent $Intent -Notification $Notification -Target $target -App $app

        return Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
    }
    catch {
        Write-Warning "An error occurred while creating the All Devices assignment for app '$AppId': $($_.Exception.Message)"
        return $null
    }
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

        # Only written when the intent is 'available' and the app supersedes something
        [bool]$AutoUpdateSuperseded = $false
    )

    try {
        $app = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId" -OutputType PSObject -ErrorAction Stop

        $target = @{
            '@odata.type'                                = '#microsoft.graph.groupAssignmentTarget'
            'deviceAndAppManagementAssignmentFilterId'   = $null
            'deviceAndAppManagementAssignmentFilterType' = 'none'
            'groupId'                                    = $GroupId
        }
        $body = New-InteropAssignmentBody -Intent $Intent -Notification $Notification -Target $target -App $app -AutoUpdateSuperseded $AutoUpdateSuperseded

        return Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
    }
    catch {
        Write-Warning "An error occurred while creating the group assignment for app '$AppId': $($_.Exception.Message)"
        return $null
    }
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

    if ($AppId -eq $SupersededAppId) {
        Write-Warning "A Win32 app cannot supersede itself (app ID '$AppId')"
        return
    }

    $supersedence = [ordered]@{
        '@odata.type'      = '#microsoft.graph.mobileAppSupersedence'
        'supersedenceType' = $SupersedenceType.ToLowerInvariant()
        'targetId'         = $SupersededAppId
    }

    # updateRelationships REPLACES the app's entire relationship set, so existing
    # dependency relationships must be read and re-submitted alongside the new
    # supersedence (which itself replaces any previous supersedence - matching the
    # module's behavior)
    $dependencies = @(Get-InteropAppRelationship -AppId $AppId -ODataType '#microsoft.graph.mobileAppDependency')

    $body = [ordered]@{ 'relationships' = @(@($supersedence) + $dependencies) }
    $null = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/updateRelationships" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -ErrorAction Stop
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

    if ($AppId -in $DependencyAppIds) {
        Write-Warning "A Win32 app cannot depend on itself (app ID '$AppId')"
        return
    }

    $dependencies = foreach ($dependencyAppId in $DependencyAppIds) {
        [ordered]@{
            '@odata.type'    = '#microsoft.graph.mobileAppDependency'
            'dependencyType' = $DependencyType
            'targetId'       = $dependencyAppId
        }
    }

    # updateRelationships REPLACES the app's entire relationship set, so existing
    # supersedence relationships must be read and re-submitted alongside the new
    # dependencies (which themselves replace any previous dependencies - matching
    # the module's behavior)
    $supersedences = @(Get-InteropAppRelationship -AppId $AppId -ODataType '#microsoft.graph.mobileAppSupersedence')

    $body = [ordered]@{ 'relationships' = @(@($dependencies) + $supersedences) }
    $null = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/updateRelationships" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -ErrorAction Stop
}

#endregion
