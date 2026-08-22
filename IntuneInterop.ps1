#Requires -Version 7.4

# IntuneInterop.ps1
# The single boundary between this repository and the Microsoft Graph Intune APIs.
#
# Every wrapper here is a native Graph implementation (Invoke-MgGraphRequest against
# the beta endpoint, riding the Connect-MgGraph session that AuthenticationManager.ps1
# establishes). Wrapper functions accept plain domain values (strings, bools,
# hashtables) and return Graph-schema shaped hashtables, so callers never deal with
# request bodies, paging, or upload mechanics.
#
# History: this file began (issue #8) as the isolation layer around the third-party
# IntuneWin32App module and was then migrated function by function to native Graph
# (issue #9). The module dependency is gone; the boundary check in pwsh-validate.yml
# remains as a tripwire so it is never reintroduced outside this file.

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

    .DESCRIPTION
    Native Graph implementation of the module's create-and-upload sequence:
    build the win32LobApp body, POST the app, create a content version and file
    entry, extract the pre-encrypted payload from the .intunewin package, upload
    it to Azure Storage in chunks, commit the file with the fileEncryptionInfo
    from Detection.xml, and mark the content version committed. Throws on failure
    (callers recover via their existing retry-lookup path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AppParams
    )

    if ($AppParams['Verbose']) {
        $VerbosePreference = 'Continue'
    }

    Write-Verbose "Attempting to gather additional meta data from .intunewin file: $($AppParams.FilePath)"
    $metadata = Get-InteropPackageMetadata -FilePath $AppParams.FilePath
    if ($null -eq $metadata) {
        throw "Could not read metadata from .intunewin file '$($AppParams.FilePath)'"
    }
    $appInfo = $metadata.ApplicationInfo

    # Build the win32LobApp body. This repository always provides explicit install and
    # uninstall command lines, which is the module's 'EXE' body shape - msiInformation
    # is never sent, matching how every app (MSI packages included) has always been
    # deployed here.
    $body = [ordered]@{
        '@odata.type'           = '#microsoft.graph.win32LobApp'
        'description'           = $AppParams.Description
        'developer'             = ''
        'displayVersion'        = $AppParams.AppVersion
        'owner'                 = ''
        'notes'                 = ''
        'informationUrl'        = ''
        'privacyInformationUrl' = ''
        'isFeatured'            = $false
        'displayName'           = $AppParams.DisplayName
        'fileName'              = $appInfo.FileName
        'setupFilePath'         = $appInfo.SetupFile
        'installCommandLine'    = $AppParams.InstallCommandLine
        'uninstallCommandLine'  = $AppParams.UninstallCommandLine
        'installExperience'     = @{
            'runAsAccount'          = $AppParams.InstallExperience
            'deviceRestartBehavior' = $AppParams.RestartBehavior
            'maxRunTimeInMinutes'   = 60
        }
        'publisher'             = $AppParams.Publisher
    }
    # Note: the module also sent 'runAs32bit = $false' here. That property does not
    # exist on win32LobApp in the Graph schema (runAs32Bit belongs to the script
    # detection/requirement rule types) and the service ignores it, so it is omitted.

    $requirementRule = $AppParams.RequirementRule
    if ($requirementRule) {
        $body['minimumSupportedWindowsRelease'] = $requirementRule['minimumSupportedWindowsRelease']
        if ($requirementRule['allowedArchitectures']) {
            $body['allowedArchitectures'] = $requirementRule['allowedArchitectures']
            $body['applicableArchitectures'] = 'none'
        }
        else {
            $body['applicableArchitectures'] = $requirementRule['applicableArchitectures']
        }
        foreach ($ruleProperty in 'minimumFreeDiskSpaceInMB', 'minimumMemoryInMB', 'minimumNumberOfProcessors', 'minimumCpuSpeedInMHz') {
            if ($requirementRule[$ruleProperty]) {
                $body[$ruleProperty] = $requirementRule[$ruleProperty]
            }
        }
    }
    else {
        # Module defaults when no requirement rule is given
        $body['applicableArchitectures'] = 'x64,x86'
        $body['minimumSupportedWindowsRelease'] = '2H20'
    }

    $body['detectionRules'] = @($AppParams.DetectionRule)

    # Default return code set (module parity)
    $body['returnCodes'] = @(
        @{ 'returnCode' = 0; 'type' = 'success' }
        @{ 'returnCode' = 1707; 'type' = 'success' }
        @{ 'returnCode' = 3010; 'type' = 'softReboot' }
        @{ 'returnCode' = 1641; 'type' = 'hardReboot' }
        @{ 'returnCode' = 1618; 'type' = 'retry' }
    )

    if ($AppParams.Icon) {
        $body['largeIcon'] = @{
            'type'  = 'image/png'
            'value' = $AppParams.Icon
        }
    }

    # Create the app
    Write-Verbose 'Attempting to create Win32 app using constructed body'
    $app = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps' -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
    if ($app.'@odata.type' -notlike '#microsoft.graph.win32LobApp') {
        throw "Failed to create Win32 app - unexpected response type '$($app.'@odata.type')'"
    }
    Write-Verbose "Successfully created Win32 app with ID: $($app.id)"

    # Create the content version
    $appUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)"
    $contentVersion = Invoke-MgGraphRequest -Method POST -Uri "$appUri/microsoft.graph.win32LobApp/contentVersions" -Body '{}' -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
    if ([string]::IsNullOrEmpty($contentVersion.id)) {
        throw 'Failed to create the contentVersions resource for the Win32 app'
    }
    Write-Verbose "Successfully created contentVersions resource with ID: $($contentVersion.id)"

    # Extract the pre-encrypted payload from the .intunewin package
    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ('InteropExpand-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        $payloadPath = Join-Path $extractDir $appInfo.FileName
        $archive = [System.IO.Compression.ZipFile]::OpenRead($AppParams.FilePath)
        try {
            # Exact match, not -like: the filename comes from Detection.xml data and
            # must never be interpreted as a wildcard pattern
            $payloadEntry = $archive.Entries | Where-Object { $_.Name -eq "$($appInfo.FileName)" } | Select-Object -First 1
            if ($null -eq $payloadEntry) {
                throw "Could not find the encrypted payload '$($appInfo.FileName)' inside the .intunewin package"
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($payloadEntry, $payloadPath, $true)
        }
        finally {
            $archive.Dispose()
        }

        # Create the content file entry and wait for the Azure Storage SAS URI
        Write-Verbose 'Constructing Win32 app content file body for uploading of .intunewin file'
        $fileBody = [ordered]@{
            '@odata.type'   = '#microsoft.graph.mobileAppContentFile'
            'name'          = [System.IO.Path]::GetFileName($AppParams.FilePath)
            'size'          = [int64]$appInfo.UnencryptedContentSize
            'sizeEncrypted' = (Get-Item -Path $payloadPath).Length
            'manifest'      = $null
            'isDependency'  = $false
        }
        $contentFile = Invoke-MgGraphRequest -Method POST -Uri "$appUri/microsoft.graph.win32LobApp/contentVersions/$($contentVersion.id)/files" -Body ($fileBody | ConvertTo-Json) -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
        if ([string]::IsNullOrEmpty($contentFile.id)) {
            throw 'Failed to create the contentVersions files resource for the Win32 app'
        }

        $filesUri = "$appUri/microsoft.graph.win32LobApp/contentVersions/$($contentVersion.id)/files/$($contentFile.id)"
        Write-Verbose 'Waiting for Intune service to process contentVersions/files request'
        $processedFile = Wait-InteropFileProcessing -Stage 'AzureStorageUriRequest' -Uri $filesUri
        if ($processedFile.uploadState -notlike 'azureStorageUriRequestSuccess') {
            throw "Azure Storage URI request failed with uploadState: $($processedFile.uploadState)"
        }

        # Upload the payload in chunks
        Invoke-InteropAzureBlobUpload -StorageUri $processedFile.azureStorageUri -FilePath $payloadPath -FilesUri $filesUri

        # Commit the file with the encryption info the packaging tool recorded
        $commitBody = @{
            'fileEncryptionInfo' = [ordered]@{
                'encryptionKey'        = $appInfo.EncryptionInfo.EncryptionKey
                'macKey'               = $appInfo.EncryptionInfo.MacKey
                'initializationVector' = $appInfo.EncryptionInfo.InitializationVector
                'mac'                  = $appInfo.EncryptionInfo.Mac
                # Prefer what the packaging tool recorded; 'ProfileVersion1' is the
                # only known value and doubles as the fallback (module parity)
                'profileIdentifier'    = [string]::IsNullOrEmpty($appInfo.EncryptionInfo.ProfileIdentifier) ? 'ProfileVersion1' : $appInfo.EncryptionInfo.ProfileIdentifier
                'fileDigest'           = $appInfo.EncryptionInfo.FileDigest
                'fileDigestAlgorithm'  = $appInfo.EncryptionInfo.FileDigestAlgorithm
            }
        }
        $null = Invoke-MgGraphRequest -Method POST -Uri "$filesUri/commit" -Body ($commitBody | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop

        Write-Verbose 'Waiting for Intune service to process the commit file request'
        $commitResult = Wait-InteropFileProcessing -Stage 'CommitFile' -Uri $filesUri
        if ($commitResult.uploadState -notlike 'commitFileSuccess') {
            throw "Commit file request failed with uploadState: $($commitResult.uploadState)"
        }

        # Mark the content version as committed and return the final app object
        Write-Verbose "Updating committedContentVersion property with ID '$($contentVersion.id)' for Win32 app with ID: $($app.id)"
        $patchBody = [ordered]@{
            '@odata.type'             = '#microsoft.graph.win32LobApp'
            'committedContentVersion' = $contentVersion.id
        }
        $null = Invoke-MgGraphRequest -Method PATCH -Uri $appUri -Body ($patchBody | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop

        Write-Verbose 'Successfully created Win32 app and committed file content to Azure Storage blob'
        return Invoke-MgGraphRequest -Method GET -Uri $appUri -OutputType PSObject -ErrorAction Stop
    }
    finally {
        Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
    Returns an app's relationship objects (both directions), optionally filtered by @odata.type

    .DESCRIPTION
    Each mobileAppRelationship carries targetId/targetDisplayName/targetDisplayVersion and
    targetType: 'child' means this app supersedes / depends on the target, 'parent' means the
    target supersedes / depends on this app. Used by the relationship writers (read-merge-write)
    and by the inventory.
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

function Wait-InteropFileProcessing {
    <#
    .SYNOPSIS
    Internal: polls a contentVersions file resource until the given stage completes

    .DESCRIPTION
    Returns the resource once uploadState reaches <Stage>Success, <Stage>Failed, or
    <Stage>TimedOut, using the module's original backoff (1s for the first 5 polls,
    then 3s, then 5s). Waiting - whether the state is the expected Pending one or
    something unexpected - is bounded by TimeoutSeconds of scheduled wait so a stuck
    resource can never hang a deployment forever.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        # Total scheduled wait budget. Intune normally self-limits by transitioning
        # to <Stage>TimedOut long before this; it is a safety net, not the norm.
        [int]$TimeoutSeconds = 1800
    )

    $pollCount = 0
    $scheduledWait = 0
    do {
        $request = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        switch ($request.uploadState) {
            "$($Stage)Failed" {
                Write-Warning "Intune service request for operation '$Stage' failed"
                return $request
            }
            "$($Stage)TimedOut" {
                Write-Warning "Intune service request for operation '$Stage' timed out"
                return $request
            }
            "$($Stage)Success" {
                # Handled by the until condition below
            }
            default {
                # Either the expected <Stage>Pending, or an unknown/stale state (e.g.
                # the previous stage's state briefly lingering right after a renewal
                # request). Both keep polling with backoff, within the shared budget.
                $pollCount++
                $waitSeconds = if ($pollCount -le 5) { 1 } elseif ($pollCount -le 15) { 3 } else { 5 }
                $scheduledWait += $waitSeconds
                if ($scheduledWait -gt $TimeoutSeconds) {
                    throw "Gave up waiting for operation '$Stage' after $TimeoutSeconds seconds - last uploadState: '$($request.uploadState)'"
                }
                if ($request.uploadState -eq "$($Stage)Pending") {
                    Write-Verbose "Intune service request for operation '$Stage' is in pending state (attempt $pollCount), waiting $waitSeconds second(s)"
                }
                else {
                    Write-Verbose "Unexpected uploadState '$($request.uploadState)' while waiting for '$Stage' (attempt $pollCount), waiting $waitSeconds second(s)"
                }
                Start-Sleep -Seconds $waitSeconds
            }
        }
    }
    until ($request.uploadState -like "$($Stage)Success")

    Write-Verbose "Intune service request for operation '$Stage' was successful with uploadState: $($request.uploadState)"
    return $request
}

function Invoke-InteropAzureBlobUpload {
    <#
    .SYNOPSIS
    Internal: uploads a file to the Azure Storage block blob behind a SAS URI

    .DESCRIPTION
    6 MiB PutBlock chunks with retry, SAS URI renewal via /renewUpload when the
    upload runs long (the SAS is only valid for a few minutes), and a final
    PutBlockList commit - the module's proven sequence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorageUri,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        # Full Graph URI of the contentVersions file resource (for SAS renewal)
        [Parameter(Mandatory = $true)]
        [string]$FilesUri,

        [int64]$ChunkSizeBytes = 6MB
    )

    Write-Verbose 'Waiting for Azure Storage SAS token propagation'
    Start-Sleep -Seconds 2

    $sasRenewalTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $fileSize = (Get-Item -Path $FilePath).Length
    $chunkCount = [System.Math]::Ceiling($fileSize / $ChunkSizeBytes)
    $reader = [System.IO.BinaryReader]::new([System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite))
    try {
        $chunkIds = @()
        for ($chunk = 0; $chunk -lt $chunkCount; $chunk++) {
            $chunkId = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($chunk.ToString('0000')))
            $chunkIds += $chunkId
            $start = $chunk * $ChunkSizeBytes
            $length = [int][System.Math]::Min($ChunkSizeBytes, $fileSize - $start)
            $bytes = $reader.ReadBytes($length)
            $currentChunk = $chunk + 1
            Write-Verbose "Uploading file to Azure Storage blob, processing chunk '$currentChunk' of '$chunkCount'"

            $uploaded = $false
            for ($attempt = 1; $attempt -le 8; $attempt++) {
                try {
                    $null = Invoke-WebRequest -Uri "$StorageUri&comp=block&blockid=$chunkId" -Method Put -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body $bytes -ErrorAction Stop
                    $uploaded = $true
                    break
                }
                catch {
                    $delay = Get-Random -Minimum 7 -Maximum 30
                    Write-Warning "Failed to upload chunk $currentChunk of $chunkCount (attempt $attempt of 8), retrying in $delay seconds: $($_.Exception.Message)"
                    Start-Sleep -Seconds $delay
                }
            }
            if (-not $uploaded) {
                throw "Failed to upload chunk $currentChunk of $chunkCount after 8 attempts"
            }

            # Renew the SAS URI before it expires on long uploads (~7.5 minutes elapsed)
            if (($currentChunk -lt $chunkCount) -and ($sasRenewalTimer.ElapsedMilliseconds -ge 450000)) {
                Write-Verbose 'SAS Uri renewal is required, attempting to renew'
                try {
                    $null = Invoke-MgGraphRequest -Method POST -Uri "$FilesUri/renewUpload" -Body '{}' -ContentType 'application/json' -ErrorAction Stop
                    $renewed = Wait-InteropFileProcessing -Stage 'AzureStorageUriRenewal' -Uri $FilesUri -TimeoutSeconds 60
                    if ($renewed.uploadState -like 'azureStorageUriRenewalSuccess') {
                        $StorageUri = $renewed.azureStorageUri
                        $sasRenewalTimer.Restart()
                    }
                    else {
                        Write-Warning 'SAS Uri renewal failed, continuing with the existing Uri'
                    }
                }
                catch {
                    Write-Warning "SAS Uri renewal attempt failed, continuing with the existing Uri: $($_.Exception.Message)"
                }
            }
        }

        # Commit the block list
        $blockListXml = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($chunkIds | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
        $finalized = $false
        for ($attempt = 1; $attempt -le 8; $attempt++) {
            try {
                $null = Invoke-RestMethod -Uri "$StorageUri&comp=blocklist" -Method Put -Body $blockListXml -ContentType 'text/plain; charset=UTF-8' -ErrorAction Stop
                $finalized = $true
                break
            }
            catch {
                $delay = Get-Random -Minimum 7 -Maximum 30
                Write-Warning "Failed to finalize the blob upload (attempt $attempt of 8), retrying in $delay seconds: $($_.Exception.Message)"
                Start-Sleep -Seconds $delay
            }
        }
        if (-not $finalized) {
            throw 'Failed to finalize the Azure Storage blob upload after 8 attempts'
        }
    }
    finally {
        $reader.Dispose()
    }
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

function Get-InteropAppAssignmentDetail {
    <#
    .SYNOPSIS
    Returns the app's assignments with intent, normalized target, and the auto-update flag

    .OUTPUTS
    Objects with Id, Intent, Target ('AllUsers' | 'AllDevices' | 'Group:<groupId>' |
    'ExcludedGroup:<groupId>' | 'Other:<type>'), GroupId ($null unless a group or excluded-group
    target), AutoUpdateSuperseded ($true / $false / $null when the assignment carries no
    autoUpdateSettings). Throws when the assignments cannot be read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId
    )

    $details = [System.Collections.Generic.List[object]]::new()
    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments"
    while ($uri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
        foreach ($assignment in @($response.value)) {
            $targetType = "$($assignment.target.'@odata.type')"
            $groupId = $null
            # Exclusion targets are checked before the plain group pattern, which they also match;
            # the breaks matter because switch keeps evaluating cases after a match
            $target = switch -Wildcard ($targetType) {
                '*allLicensedUsersAssignmentTarget' { 'AllUsers'; break }
                '*allDevicesAssignmentTarget'       { 'AllDevices'; break }
                '*exclusionGroupAssignmentTarget'   { $groupId = $assignment.target.groupId; "ExcludedGroup:$groupId"; break }
                '*groupAssignmentTarget'            { $groupId = $assignment.target.groupId; "Group:$groupId"; break }
                default                             { "Other:$($targetType -replace '^#microsoft\.graph\.', '')" }
            }

            $autoUpdate = $null
            $state = $assignment.settings.autoUpdateSettings.autoUpdateSupersededAppsState
            if ($null -ne $state) {
                $autoUpdate = ($state -eq 'enabled')
            }

            $details.Add([PSCustomObject]@{
                Id                   = $assignment.id
                Intent               = $assignment.intent
                Target               = $target
                GroupId              = $groupId
                AutoUpdateSuperseded = $autoUpdate
            })
        }
        $uri = $response.'@odata.nextLink'
    }
    return @($details)
}

function Get-InteropAppInstallSummary {
    <#
    .SYNOPSIS
    Returns the app's install summary (device and user counts by state)

    .DESCRIPTION
    Tries the documented GET /mobileApps/{id}/installSummary first; that legacy endpoint has
    started returning 400 in current service releases, so on failure it falls back to what the
    Intune admin center uses - POST /deviceManagement/reports/getAppStatusOverviewReport with an
    ApplicationId filter - and maps the report's Schema/Values table onto the same camelCase
    property names (installedDeviceCount, ...), so callers see one shape either way. Returns
    $null when the report has no row for the app; throws when both paths fail.

    Note for version-comparison detection rules ("greaterThanOrEqual" and >=-style scripts):
    a device with a newer version installed also detects every older version, so
    installedDeviceCount on old versions is inflated - it is only a reliable "still in use"
    signal for product-code and equal-operator apps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId
    )

    try {
        return Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/installSummary" -OutputType PSObject -ErrorAction Stop
    }
    catch {
        Write-Verbose "installSummary GET failed for app '$AppId' ($($_.Exception.Message)); falling back to getAppStatusOverviewReport"
    }

    $body = @{ filter = "(ApplicationId eq '$AppId')" } | ConvertTo-Json
    $report = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/reports/getAppStatusOverviewReport' -Body $body -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop

    $row = @($report.Values) | Select-Object -First 1
    if ($null -eq $row) {
        return $null
    }

    # Schema columns are PascalCase (InstalledDeviceCount, ...); lowercase the first letter to
    # match the legacy installSummary property names
    $summary = [ordered]@{}
    $columns = @($report.Schema)
    for ($i = 0; $i -lt $columns.Count; $i++) {
        $name = "$($columns[$i].Column)"
        if ([string]::IsNullOrEmpty($name)) { continue }
        $summary[($name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1))] = $row[$i]
    }
    return [PSCustomObject]$summary
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
