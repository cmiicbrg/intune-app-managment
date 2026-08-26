#Requires -Version 7.4

# AppInventory.ps1
# Pure inventory assembly and analysis for the Win32 apps of one tenant. No Graph calls: the
# Get-IntuneAppInventory.ps1 script fetches raw objects through IntuneInterop.ps1 and hands them
# in here, which keeps every analytical rule unit-testable with synthetic data.
#
# Pipeline: ConvertTo-AppInventoryRecord (one normalized record per Intune app)
#        -> Get-AppInventoryAnalysis (families, retention verdicts, supersedence graphs, anomalies)
#        -> Format-AppInventoryMarkdown / the JSON document the script writes

. (Join-Path $PSScriptRoot "SharedFunctions.ps1")
. (Join-Path $PSScriptRoot "AppRetention.ps1")

# Intune allows at most this many nodes in one supersedence graph; families approaching it will
# fail to add the next version's supersedence ("The total supersedence limit was reached").
$script:SupersedenceGraphNodeLimit = 11
$script:SupersedenceGraphWarnAt = 9

# Detection operators (file/registry rules) and script rules under which an older version keeps
# "detecting" as installed once a newer one is present. Install counts on old versions of these
# families are inflated (a reporting caveat only - it has no Company Portal effect).
$script:InflatingOperators = @('greaterThanOrEqual', 'greaterThan', 'notEqual')

# Graph timestamps arrive as strings; a missing one stays $null instead of becoming 01/01/0001.
function ConvertTo-AppInventoryDateTime {
    param([AllowNull()]$Value)

    if (-not $Value) { return $null }
    return [datetime]$Value
}

# The family whose base name an unmanaged app shares without following its naming convention -
# longest base name first, so "Firefox ESR" wins over "Firefox". $null when it resembles none.
function Get-AppFamilyNearMiss {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$DisplayName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Families
    )

    foreach ($candidate in ($Families | Sort-Object { $_.BaseName.Length } -Descending)) {
        if ($DisplayName.StartsWith($candidate.BaseName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $candidate.AppConfigName
        }
    }
    return $null
}

# The JSON-friendly version block of a record; $null when no version could be read at all.
function ConvertTo-AppVersionRecord {
    param([AllowNull()]$VersionInfo)

    if (-not $VersionInfo) { return $null }

    $parsed = $null
    if ($VersionInfo.Version) { $parsed = $VersionInfo.Version.ToString() }
    return [ordered]@{ Raw = $VersionInfo.Raw; Parsed = $parsed; Source = $VersionInfo.Source }
}

# One entry per detection rule: its Graph type without the namespace, and its operator (script
# rules have none).
function ConvertTo-AppDetectionRecord {
    param([Parameter(Mandatory = $true)] $App)

    # ,@() so a rule-less app yields an empty array rather than $null (return unrolls)
    $rules = @(foreach ($rule in @($App.detectionRules)) {
        $operator = $null
        if ($rule.PSObject.Properties.Name -contains 'operator') { $operator = "$($rule.operator)" }
        [ordered]@{
            Type     = "$($rule.'@odata.type')" -replace '^#microsoft\.graph\.', ''
            Operator = $operator
        }
    })
    return ,$rules
}

# $true when the app detects itself with a rule under which an older version keeps "detecting" as
# installed once a newer one is present (see $script:InflatingOperators).
function Test-AppInflatingDetection {
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Detection)

    return [bool]($Detection | Where-Object {
        $_.Type -eq 'win32LobAppPowerShellScriptDetection' -or ($_.Operator -and $script:InflatingOperators -contains $_.Operator)
    })
}

# One entry per assignment, with the group display name resolved where it is known.
function ConvertTo-AppAssignmentRecord {
    param(
        [AllowNull()] $Assignments,
        [hashtable]$GroupNames = @{}
    )

    # @($null) iterates once in PowerShell - a failed read ($Assignments = $null) must yield an
    # empty set here, with AssignmentsUnavailable carrying the "unknown" state.
    $records = @(foreach ($assignment in @($Assignments)) {
        if ($null -eq $assignment) { continue }

        $groupName = $null
        if ($assignment.GroupId -and $GroupNames.ContainsKey($assignment.GroupId)) {
            $groupName = $GroupNames[$assignment.GroupId]
        }

        [ordered]@{
            Intent               = $assignment.Intent
            Target               = $assignment.Target
            GroupId              = $assignment.GroupId
            GroupName            = $groupName
            AutoUpdateSuperseded = $assignment.AutoUpdateSuperseded
        }
    })
    return ,$records
}

# Which bucket a relationship belongs in, from its Graph type and whether the app is the child of
# the relationship. $null for a relationship type the inventory does not track.
function Get-AppRelationshipBucket {
    param(
        [AllowEmptyString()] [string]$ODataType,
        [bool]$IsChild
    )

    if ($ODataType -like '*mobileAppSupersedence') {
        if ($IsChild) { return 'Supersedes' }
        return 'SupersededBy'
    }
    if ($ODataType -like '*mobileAppDependency') {
        if ($IsChild) { return 'DependsOn' }
        return 'DependencyOf'
    }
    return $null
}

# The app's relationships split into @{ Supersedes; SupersededBy; DependsOn; DependencyOf }.
function Split-AppRelationshipRecord {
    param([AllowNull()] $Relationships)

    $buckets = @{ Supersedes = @(); SupersededBy = @(); DependsOn = @(); DependencyOf = @() }

    foreach ($relationship in @($Relationships)) {
        $bucket = Get-AppRelationshipBucket -ODataType "$($relationship.'@odata.type')" -IsChild ("$($relationship.targetType)" -eq 'child')
        if (-not $bucket) { continue }

        $entry = [ordered]@{
            TargetId             = $relationship.targetId
            TargetDisplayName    = $relationship.targetDisplayName
            TargetDisplayVersion = $relationship.targetDisplayVersion
        }
        if ($bucket -in 'Supersedes', 'SupersededBy') {
            $entry['SupersedenceType'] = $relationship.supersedenceType
        }
        else {
            $entry['DependencyType'] = $relationship.dependencyType
        }

        $buckets[$bucket] += $entry
    }

    return $buckets
}

# The device/user install counts Graph reported, $null when the summary could not be read.
function ConvertTo-AppInstallSummaryRecord {
    param([AllowNull()] $InstallSummary)

    if ($null -eq $InstallSummary) { return $null }

    $summary = [ordered]@{}
    foreach ($name in 'installedDeviceCount', 'failedDeviceCount', 'notInstalledDeviceCount', 'pendingInstallDeviceCount', 'notApplicableDeviceCount', 'installedUserCount', 'failedUserCount', 'notInstalledUserCount', 'pendingInstallUserCount', 'notApplicableUserCount') {
        if ($InstallSummary.PSObject.Properties.Name -contains $name) {
            $summary[$name] = $InstallSummary.$name
        }
    }
    return $summary
}

# One normalized, JSON-friendly record per Intune app.
#   -App            raw win32LobApp object (largeIcon is dropped)
#   -Assignments    Get-InteropAppAssignmentDetail output (may be $null on read failure)
#   -Relationships  Get-InteropAppRelationship output (may be $null on read failure)
#   -InstallSummary Get-InteropAppInstallSummary output or $null
#   -Families       Get-AppFamilyCatalog output
#   -GroupNames     optional hashtable groupId -> displayName
function ConvertTo-AppInventoryRecord {
    param(
        [Parameter(Mandatory = $true)] $App,
        [AllowNull()] $Assignments,
        [AllowNull()] $Relationships,
        [AllowNull()] $InstallSummary,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Families,
        [hashtable]$GroupNames = @{}
    )

    $family = Resolve-AppFamily -DisplayName "$($App.displayName)" -Families $Families

    # Near miss: shares a family's base name but does not follow its naming convention
    $nearMiss = $null
    if ($null -eq $family) {
        $nearMiss = Get-AppFamilyNearMiss -DisplayName "$($App.displayName)" -Families $Families
    }

    $versionInfo = Get-IntuneAppVersion -App $App
    $detection = ConvertTo-AppDetectionRecord -App $App
    $related = Split-AppRelationshipRecord -Relationships $Relationships

    return [PSCustomObject]@{
        Id                    = $App.id
        DisplayName           = $App.displayName
        DisplayVersion        = $App.displayVersion
        Publisher             = $App.publisher
        CreatedDateTime       = ConvertTo-AppInventoryDateTime -Value $App.createdDateTime
        LastModifiedDateTime  = ConvertTo-AppInventoryDateTime -Value $App.lastModifiedDateTime
        IsAssigned            = $App.isAssigned
        PublishingState       = $App.publishingState
        Size                  = $App.size
        Family                = $family.AppConfigName
        FamilyNearMiss        = $nearMiss
        Version               = ConvertTo-AppVersionRecord -VersionInfo $versionInfo
        ParsedVersion         = $versionInfo.Version
        Detection             = $detection
        InflatingDetection    = Test-AppInflatingDetection -Detection $detection
        Assignments           = ConvertTo-AppAssignmentRecord -Assignments $Assignments -GroupNames $GroupNames
        AssignmentsUnavailable = ($null -eq $Assignments)
        RelationshipsUnavailable = ($null -eq $Relationships)
        Supersedes            = $related.Supersedes
        SupersededBy          = $related.SupersededBy
        DependsOn             = $related.DependsOn
        DependencyOf          = $related.DependencyOf
        InstallSummary        = ConvertTo-AppInstallSummaryRecord -InstallSummary $InstallSummary
        Retention             = $null   # filled in by Get-AppInventoryAnalysis for managed apps
    }
}

# Writes the retention verdicts of one family onto its records.
# An app whose relationships could not be read may be a dependency target we cannot see, and
# dependency targets are always kept - so it must not become a delete candidate (the cleanup
# consumes these verdicts). Downgrade to Review.
function Set-AppInventoryRetention {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Members,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Plan
    )

    foreach ($verdict in $Plan) {
        $record = $Members | Where-Object Id -eq $verdict.Id | Select-Object -First 1
        if ($record.RelationshipsUnavailable -and $verdict.Action -eq 'Delete') {
            $verdict.Action = 'Review'
            $verdict.Reasons = @($verdict.Reasons) + 'relationships could not be read - may be a dependency target; deletion suppressed, re-run the inventory'
        }
        $record.Retention = [ordered]@{ Rank = $verdict.Rank; AgeWeeks = $verdict.AgeWeeks; SupersededWeeks = $verdict.SupersededWeeks; Action = $verdict.Action; Reasons = @($verdict.Reasons) }
    }
}

# Anomalies about the data the inventory could read and about the family's shape: unreadable
# relationships, duplicate version numbers, and a supersedence graph nearing the Intune limit.
function Get-AppFamilyDataAnomaly {
    param(
        [Parameter(Mandatory = $true)] [string]$FamilyName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Members,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Plan,
        $GraphNodes = 0
    )

    $anomalies = [System.Collections.Generic.List[object]]::new()

    $relationshipsUnavailable = @($Members | Where-Object RelationshipsUnavailable)
    if ($relationshipsUnavailable.Count -gt 0) {
        $anomalies.Add((New-Anomaly -Type 'RelationshipsUnavailable' -Family $FamilyName -Message "relationships of $($relationshipsUnavailable.Count) version(s) could not be read - supersedence graph size and dependency protection are incomplete for this family and deletion of the affected version(s) is suppressed; re-run the inventory" -AppIds @($relationshipsUnavailable.Id)))
    }

    # Duplicates are detected by version number, not by the Review action - Review is also
    # the verdict for an app whose relationships could not be read.
    $duplicateGroups = @($Plan | Where-Object { $null -ne $_.Version } | Group-Object { $_.Version.ToString() } | Where-Object Count -gt 1)
    foreach ($group in $duplicateGroups) {
        $anomalies.Add((New-Anomaly -Type 'DuplicateVersion' -Family $FamilyName -Message "version $($group.Name) exists more than once - review manually, retention will not delete either copy" -AppIds @($group.Group.Id)))
    }

    if ($GraphNodes -ge $script:SupersedenceGraphWarnAt) {
        $anomalies.Add((New-Anomaly -Type 'SupersedenceGraphNearLimit' -Family $FamilyName -Message "supersedence graph has $GraphNodes node(s); Intune allows $script:SupersedenceGraphNodeLimit - the next version's supersedence will fail once the limit is reached" -AppIds @($Members.Id)))
    }

    return @($anomalies)
}

# Anomalies about what users see in the Company Portal: an older version that shows up as a
# separate app, and a newest version nobody can install.
#
# A superseded version keeping its 'available' assignment is normal and required: the Company
# Portal hides it behind the newest version, and the assignment is what keeps supersedence/
# auto-update working - never flag that. What does show up as a separate app in the Company
# Portal is an older version with an 'available' assignment (the intent the portal lists) that is
# NOT superseded by anything - a chain split at the graph limit, or a version that was never
# linked. Required-only assignments are not visible in the portal and are left alone.
function Get-AppFamilyPortalAnomaly {
    param(
        [Parameter(Mandatory = $true)] [string]$FamilyName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Members,
        [AllowNull()] $Newest,
        [AllowNull()] $AppConfig
    )

    $anomalies = [System.Collections.Generic.List[object]]::new()

    $unlinkedOlder = @($Members | Where-Object {
        $_.Retention.Rank -and $_.Retention.Rank -gt 1 -and
        @($_.SupersededBy).Count -eq 0 -and -not $_.RelationshipsUnavailable -and
        @(Select-AvailableAssignment -Assignments $_.Assignments).Count -gt 0
    })
    if ($unlinkedOlder.Count -gt 0) {
        $names = ($unlinkedOlder | ForEach-Object { "$($_.DisplayName) v$($_.DisplayVersion)" }) -join ', '
        $anomalies.Add((New-Anomaly -Type 'OlderVersionUnlinked' -Family $FamilyName -Message "$($unlinkedOlder.Count) older version(s) are assigned 'available' but not superseded by any version ($names) - they show up as separate apps in the Company Portal instead of being hidden behind the newest one. Retention deletes them once they leave the keep window; until then, make the next newer version supersede them." -AppIds @($unlinkedOlder.Id)))
    }

    $newestRecord = $null
    if ($Newest) {
        $newestRecord = $Members | Where-Object Id -eq $Newest.Id
    }
    if ($newestRecord -and @($newestRecord.Assignments).Count -eq 0 -and -not $newestRecord.AssignmentsUnavailable -and -not ($AppConfig -and $AppConfig.HideFromPortal -eq $true)) {
        $anomalies.Add((New-Anomaly -Type 'NewestUnassigned' -Family $FamilyName -Message "the newest version ($($newestRecord.DisplayName) v$($newestRecord.DisplayVersion)) has no assignments" -AppIds @($newestRecord.Id)))
    }

    return @($anomalies)
}

# Superseding versions that are available without auto-update although the family opted into it -
# users see them as 'New' instead of updating automatically.
function Get-AppFamilyAutoUpdateAnomaly {
    param(
        [Parameter(Mandatory = $true)] [string]$FamilyName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Members,
        [AllowNull()] $AppConfig
    )

    if (-not ($AppConfig -and $AppConfig.AutoUpdate -eq $true)) {
        return @()
    }

    $gaps = @($Members | Where-Object {
        @($_.Supersedes).Count -gt 0 -and
        @(Select-AvailableAssignment -Assignments $_.Assignments | Where-Object { $_.AutoUpdateSuperseded -ne $true }).Count -gt 0
    })
    if ($gaps.Count -eq 0) {
        return @()
    }

    return @(New-Anomaly -Type 'AutoUpdateNotEnabled' -Family $FamilyName -Message "$($gaps.Count) superseding version(s) have an 'available' assignment without auto-update, although AutoUpdate is enabled in AppConfig - users see them as 'New' instead of updating automatically" -AppIds @($gaps.Id))
}

# The per-family report of the analysis (see Get-AppInventoryAnalysis).
function New-AppFamilyReport {
    param(
        [Parameter(Mandatory = $true)] $Family,
        [bool]$InPlan = $true,
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Members,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Plan,
        [AllowNull()] $Newest,
        $GraphNodes = 0
    )

    $newestReport = $null
    if ($Newest) {
        $newestReport = [ordered]@{ Id = $Newest.Id; DisplayName = $Newest.DisplayName; Version = $Newest.Version.ToString() }
    }

    return [PSCustomObject]@{
        Family                  = $Family.AppConfigName
        BaseName                = $Family.BaseName
        InPlan                  = $InPlan
        Policy                  = [ordered]@{ KeepNewest = $Policy.KeepNewest; KeepNewerThanWeeks = $Policy.KeepNewerThanWeeks; Source = $Policy.Source; OptIn = $Policy.OptIn }
        VersionCount            = $Members.Count
        Newest                  = $newestReport
        OldestAgeWeeks          = ($Plan | Where-Object { $null -ne $_.AgeWeeks } | Measure-Object -Property AgeWeeks -Maximum).Maximum
        SupersedenceGraphNodes  = $GraphNodes
        InflatingDetection      = [bool]($Members | Where-Object InflatingDetection | Select-Object -First 1)
        KeepCount               = @($Plan | Where-Object Action -eq 'Keep').Count
        DeleteCandidateCount    = @($Plan | Where-Object Action -eq 'Delete').Count
        ReviewCount             = @($Plan | Where-Object Action -eq 'Review').Count
        DeleteCandidates        = @(Select-AppRetentionDeleteCandidates -Plan $Plan | ForEach-Object { [ordered]@{ Id = $_.Id; DisplayName = $_.DisplayName; Version = $_.Version.ToString(); AgeWeeks = $_.AgeWeeks; SupersededWeeks = $_.SupersededWeeks } })
    }
}

# The apps no family claims, plus the NamingConventionMismatch anomaly for those that resemble
# one. Returns @{ Unmanaged = @(...); Anomalies = @(...) }, near misses first (actionable).
function Get-AppUnmanagedAnalysis {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Records,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Families
    )

    $unmanaged = [System.Collections.Generic.List[object]]::new()
    $anomalies = [System.Collections.Generic.List[object]]::new()

    foreach ($record in ($Records | Where-Object { $null -eq $_.Family })) {
        # The anomaly only fires when the near-miss family is in the analysis scope (with -AppName
        # the record may resemble an out-of-scope family); the Unmanaged listing keeps LooksLike
        # either way.
        $nearMissFamily = $null
        if ($record.FamilyNearMiss) {
            $nearMissFamily = $Families | Where-Object AppConfigName -eq $record.FamilyNearMiss | Select-Object -First 1
        }
        if ($nearMissFamily) {
            $anomalies.Add((New-Anomaly -Type 'NamingConventionMismatch' -Family $record.FamilyNearMiss -Message "'$($record.DisplayName)' looks like $($record.FamilyNearMiss) but does not follow the naming convention, so it is not managed (never superseded, never deleted). Rename it to the pattern '$($nearMissFamily.Name)' with its version to bring it under management." -AppIds @($record.Id)))
        }
        $unmanaged.Add([ordered]@{ Id = $record.Id; DisplayName = $record.DisplayName; DisplayVersion = $record.DisplayVersion; Publisher = $record.Publisher; LooksLike = $record.FamilyNearMiss })
    }

    return @{ Unmanaged = @($unmanaged); Anomalies = @($anomalies) }
}

# Family-level analysis over the records: retention verdicts, supersedence graph sizes, anomalies.
#   -Records        ConvertTo-AppInventoryRecord output for every Win32 app in the tenant
#   -Families       Get-AppFamilyCatalog output
#   -PolicyResolver scriptblock: param($AppConfigName) -> Get-TenantRetentionPolicy result
#   -PlanAppNames   canonical app names in the tenant's deployment plan ($null = no plan)
#   -AppConfigs     hashtable AppConfigName -> AppConfig hashtable (for AutoUpdate flags)
# Returns @{ Families = @(...); Anomalies = @(...); Unmanaged = @(...); Summary = @{...} } and sets
# each managed record's Retention property.
function Get-AppInventoryAnalysis {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Records,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Families,
        [Parameter(Mandatory = $true)] [scriptblock]$PolicyResolver,
        [AllowNull()] [string[]]$PlanAppNames,
        [hashtable]$AppConfigs = @{},
        [datetime]$Now = [datetime]::UtcNow
    )

    $anomalies = [System.Collections.Generic.List[object]]::new()
    $familyReports = [System.Collections.Generic.List[object]]::new()

    # Dependency targets are protected from deletion in every family
    $protectedIds = @($Records | Where-Object { @($_.DependencyOf).Count -gt 0 } | ForEach-Object { $_.Id })

    # Supersedence graphs: connected components over supersedence edges (either direction)
    $componentSize = Get-SupersedenceComponentSizes -Records $Records

    foreach ($family in $Families) {
        $members = @($Records | Where-Object { $_.Family -eq $family.AppConfigName })
        if ($members.Count -eq 0) { continue }

        $inPlan = if ($null -eq $PlanAppNames) { $true } else { $PlanAppNames -contains $family.AppConfigName }
        $policy = & $PolicyResolver $family.AppConfigName
        $appConfig = $AppConfigs[$family.AppConfigName]

        $retentionInput = @($members | ForEach-Object {
            [PSCustomObject]@{ Id = $_.Id; DisplayName = $_.DisplayName; Version = $_.ParsedVersion; CreatedDateTime = $_.CreatedDateTime }
        })
        $plan = @(Get-AppRetentionPlan -Apps $retentionInput -Policy @{ KeepNewest = $policy.KeepNewest; KeepNewerThanWeeks = $policy.KeepNewerThanWeeks } -ProtectedAppIds $protectedIds -Now $Now)
        Set-AppInventoryRetention -Members $members -Plan $plan

        $newest = $plan | Where-Object Rank -eq 1 | Select-Object -First 1
        $graphNodes = ($members | ForEach-Object { $componentSize[$_.Id] } | Measure-Object -Maximum).Maximum ?? 0

        $anomalies.AddRange([object[]]@(
            @(Get-AppFamilyDataAnomaly -FamilyName $family.AppConfigName -Members $members -Plan $plan -GraphNodes $graphNodes) +
            @(Get-AppFamilyPortalAnomaly -FamilyName $family.AppConfigName -Members $members -Newest $newest -AppConfig $appConfig) +
            @(Get-AppFamilyAutoUpdateAnomaly -FamilyName $family.AppConfigName -Members $members -AppConfig $appConfig)
        ))

        $familyReports.Add((New-AppFamilyReport -Family $family -InPlan $inPlan -Policy $policy -Members $members -Plan $plan -Newest $newest -GraphNodes $graphNodes))
    }

    $unmanagedAnalysis = Get-AppUnmanagedAnalysis -Records $Records -Families $Families
    $unmanaged = $unmanagedAnalysis.Unmanaged
    $anomalies.AddRange([object[]]$unmanagedAnalysis.Anomalies)

    $managedRecords = @($Records | Where-Object { $null -ne $_.Family })
    return @{
        Families  = @($familyReports)
        Anomalies = @($anomalies)
        Unmanaged = @($unmanaged)
        Summary   = [ordered]@{
            TotalWin32Apps        = $Records.Count
            ManagedApps           = $managedRecords.Count
            UnmanagedApps         = $unmanaged.Count
            FamiliesPresent       = $familyReports.Count
            DeleteCandidates      = ($familyReports | Measure-Object -Property DeleteCandidateCount -Sum).Sum
            ReviewItems           = ($familyReports | Measure-Object -Property ReviewCount -Sum).Sum
            FamiliesNearGraphLimit = @($familyReports | Where-Object { $_.SupersedenceGraphNodes -ge $script:SupersedenceGraphWarnAt }).Count
            AppsWithUnavailableRelationships = @($managedRecords | Where-Object RelationshipsUnavailable).Count
        }
    }
}

# Pre-flight for a deploy: can one more version be linked into the supersedence graph that the
# app to be superseded belongs to? Intune caps a graph at $script:SupersedenceGraphNodeLimit
# nodes; the new version would be one more. Records are ConvertTo-AppInventoryRecord output.
function Test-SupersedenceHeadroom {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Records,

        # The app the new version will supersede (the newest existing one); $null/unknown = a new
        # chain of one node
        [AllowNull()]
        [string]$AppId,

        [int]$Limit = $script:SupersedenceGraphNodeLimit
    )

    # Fail closed: a record whose relationships could not be read looks like an isolated node,
    # so an 11-node chain could pass as empty during a relationship outage and the upload would
    # end in exactly the unlinked app this check exists to prevent.
    $unreadable = @($Records | Where-Object { $_.RelationshipsUnavailable })
    if ($unreadable.Count -gt 0) {
        return [PSCustomObject]@{
            Nodes         = $null
            NodesAfter    = $null
            Limit         = $Limit
            CanAddVersion = $false
            WillFill      = $false
            Unknown       = $true
            Reason        = "the relationships of $($unreadable.Count) existing version(s) could not be read, so the size of the supersedence graph is unknown"
        }
    }

    $sizes = Get-SupersedenceComponentSizes -Records $Records
    $nodes = if ($AppId -and $sizes.ContainsKey($AppId)) { [int]$sizes[$AppId] } else { 0 }
    return [PSCustomObject]@{
        Nodes         = $nodes
        NodesAfter    = $nodes + 1
        Limit         = $Limit
        CanAddVersion = ($nodes + 1) -le $Limit
        WillFill      = ($nodes + 1) -eq $Limit
        Unknown       = $false
        Reason        = $null
    }
}

# The assignments that actually make an app available in the Company Portal: intent
# 'available' with a positive target. Graph lists exclusions as rows of the same intent with an
# exclusionGroupAssignmentTarget (normalized to 'ExcludedGroup:<id>'); those take availability
# away and must never count as it.
function Select-AvailableAssignment {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        $Assignments
    )

    return @($Assignments | Where-Object {
        $null -ne $_ -and $_.Intent -eq 'available' -and -not "$($_.Target)".StartsWith('ExcludedGroup:', [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function New-Anomaly {
    param(
        [Parameter(Mandatory = $true)] [string]$Type,
        [Parameter(Mandatory = $true)] [string]$Family,
        [Parameter(Mandatory = $true)] [string]$Message,
        [string[]]$AppIds = @()
    )
    return [PSCustomObject]@{ Type = $Type; Family = $Family; Message = $Message; AppIds = @($AppIds) }
}

# Sizes of the connected components formed by supersedence relationships (either direction),
# keyed by app id. Apps without supersedence relationships are components of size 1.
function Get-SupersedenceComponentSizes {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Records
    )

    $parent = @{}
    foreach ($record in $Records) { $parent[$record.Id] = $record.Id }

    $find = {
        param($id)
        while ($parent[$id] -ne $id) {
            $parent[$id] = $parent[$parent[$id]]
            $id = $parent[$id]
        }
        return $id
    }

    foreach ($record in $Records) {
        foreach ($edge in @($record.Supersedes) + @($record.SupersededBy)) {
            $other = $edge.TargetId
            if (-not $parent.ContainsKey($other)) { $parent[$other] = $other }
            $rootA = & $find $record.Id
            $rootB = & $find $other
            if ($rootA -ne $rootB) { $parent[$rootA] = $rootB }
        }
    }

    $sizes = @{}
    foreach ($id in @($parent.Keys)) {
        $root = & $find $id
        $sizes[$root] = 1 + [int]($sizes[$root])
    }

    $result = @{}
    foreach ($record in $Records) {
        $result[$record.Id] = $sizes[(& $find $record.Id)]
    }
    return $result
}

# The report header: the run's provenance and the summary counters.
function Get-AppInventoryHeaderLine {
    param(
        [Parameter(Mandatory = $true)] [string]$TenantName,
        [Parameter(Mandatory = $true)] [datetime]$GeneratedUtc,
        [Parameter(Mandatory = $true)] $Summary
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Intune Win32 app inventory - $TenantName")
    $lines.Add('')
    $lines.Add("Generated $($GeneratedUtc.ToString('yyyy-MM-dd HH:mm')) UTC. Read-only snapshot; nothing was changed in Intune.")
    $lines.Add('')
    $lines.Add("- Win32 apps: **$($Summary.TotalWin32Apps)** ($($Summary.ManagedApps) managed by this tooling, $($Summary.UnmanagedApps) unmanaged)")
    $lines.Add("- Families present: **$($Summary.FamiliesPresent)**, near the supersedence graph limit: **$($Summary.FamiliesNearGraphLimit)**")
    $lines.Add("- Retention: **$($Summary.DeleteCandidates)** delete candidate(s), **$($Summary.ReviewItems)** item(s) to review")
    if ($Summary.AppsWithUnavailableRelationships -gt 0) {
        $lines.Add("- **Incomplete data**: relationships of **$($Summary.AppsWithUnavailableRelationships)** managed app(s) could not be read; their deletion is suppressed and graph sizes may be understated - re-run the inventory before a cleanup")
    }
    $lines.Add('')

    return @($lines)
}

# The Families table: one row per family present in the tenant.
function Get-AppInventoryFamilyTableLine {
    param([Parameter(Mandatory = $true)] [hashtable]$Analysis)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Families')
    $lines.Add('')
    $lines.Add('| Family | In plan | Versions | Newest | Oldest (weeks) | Graph nodes | Policy | Keep | Delete | Review |')
    $lines.Add('| --- | --- | ---: | --- | ---: | ---: | --- | ---: | ---: | ---: |')

    foreach ($f in ($Analysis.Families | Sort-Object Family)) {
        $newest = if ($f.Newest) { "$($f.Newest.DisplayName) ($($f.Newest.Version))" } else { '-' }
        $graph = if ($f.SupersedenceGraphNodes -ge $script:SupersedenceGraphWarnAt) { "**$($f.SupersedenceGraphNodes)** !" } else { "$($f.SupersedenceGraphNodes)" }
        $inPlan = if ($f.InPlan) { 'yes' } else { 'no' }
        $policy = "$($f.Policy.KeepNewest) / $($f.Policy.KeepNewerThanWeeks)w ($($f.Policy.Source))"
        $lines.Add("| $($f.Family) | $inPlan | $($f.VersionCount) | $newest | $($f.OldestAgeWeeks) | $graph | $policy | $($f.KeepCount) | $($f.DeleteCandidateCount) | $($f.ReviewCount) |")
    }
    $lines.Add('')

    return @($lines)
}

# The delete candidates, one table per family that has any.
function Get-AppInventoryDeleteCandidateLine {
    param([Parameter(Mandatory = $true)] [hashtable]$Analysis)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Delete candidates (oldest first, per family)')
    $lines.Add('')

    $families = @($Analysis.Families | Sort-Object Family | Where-Object { $_.DeleteCandidates.Count -gt 0 })
    foreach ($f in $families) {
        $lines.Add("### $($f.Family)")
        $lines.Add('')
        $lines.Add('| App | Version | Superseded (weeks ago) | Age (weeks) |')
        $lines.Add('| --- | --- | ---: | ---: |')
        foreach ($c in $f.DeleteCandidates) {
            $lines.Add("| $($c.DisplayName) | $($c.Version) | $($c.SupersededWeeks ?? '-') | $($c.AgeWeeks) |")
        }
        $lines.Add('')
    }
    if ($families.Count -eq 0) {
        $lines.Add('None under the current policy.')
        $lines.Add('')
    }

    return @($lines)
}

# The anomaly list, in a stable order.
function Get-AppInventoryAnomalyLine {
    param([Parameter(Mandatory = $true)] [hashtable]$Analysis)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Anomalies')
    $lines.Add('')

    if ($Analysis.Anomalies.Count -eq 0) {
        $lines.Add('None.')
    }
    foreach ($a in ($Analysis.Anomalies | Sort-Object Type, Family)) {
        $lines.Add("- **$($a.Type)** [$($a.Family)]: $($a.Message)")
    }
    $lines.Add('')

    return @($lines)
}

# One row of a family's version table.
function Format-AppInventoryVersionRow {
    param(
        [Parameter(Mandatory = $true)] $Record,
        [bool]$IncludesInstallSummary = $true
    )

    $assign = if ($Record.Assignments.Count -eq 0) { '-' } else { ($Record.Assignments | ForEach-Object { "$($_.Target) ($($_.Intent)$(if ($_.AutoUpdateSuperseded -eq $true) { ', auto-update' }))" }) -join '; ' }
    $sup = if ($Record.Supersedes.Count -eq 0) { '-' } else { ($Record.Supersedes | ForEach-Object { $_.TargetDisplayVersion }) -join ', ' }
    $created = if ($Record.CreatedDateTime) { $Record.CreatedDateTime.ToString('yyyy-MM-dd') } else { '-' }

    $row = "| $($Record.Retention.Rank ?? '-') | $($Record.DisplayName) | $($Record.DisplayVersion) | $created | $($Record.Retention.AgeWeeks ?? '-') | $($Record.Retention.SupersededWeeks ?? '-') | $assign | $sup | $($Record.Retention.Action) | $($Record.Retention.Reasons -join '; ') |"
    if ($IncludesInstallSummary) {
        $row += if ($Record.InstallSummary) { " $($Record.InstallSummary.installedDeviceCount) / $($Record.InstallSummary.pendingInstallDeviceCount) / $($Record.InstallSummary.failedDeviceCount) |" } else { ' - |' }
    }
    return $row
}

# One family's version table: every version it has, newest rank first.
function Get-AppInventoryFamilyVersionLine {
    param(
        [Parameter(Mandatory = $true)] $Family,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Records,
        [bool]$IncludesInstallSummary = $true
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $members = @($Records | Where-Object { $_.Family -eq $Family.Family } | Sort-Object { $_.Retention.Rank ?? [int]::MaxValue }, { $_.CreatedDateTime } -Descending:$false)

    $inflating = if ($Family.InflatingDetection) { ' (inflating detection)' } else { '' }
    $lines.Add("### $($Family.Family)$inflating")
    $lines.Add('')

    $header = '| Rank | App | Version | Created | Age (weeks) | Superseded (weeks ago) | Assignments | Supersedes | Action | Reasons |'
    $sep = '| ---: | --- | --- | --- | ---: | ---: | --- | --- | --- | --- |'
    if ($IncludesInstallSummary) {
        $header += ' Installed / Pending / Failed |'
        $sep += ' --- |'
    }
    $lines.Add($header)
    $lines.Add($sep)

    foreach ($m in $members) {
        $lines.Add((Format-AppInventoryVersionRow -Record $m -IncludesInstallSummary $IncludesInstallSummary))
    }
    $lines.Add('')

    return @($lines)
}

# The Versions section: one table per family.
function Get-AppInventoryVersionLine {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Analysis,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Records,
        [bool]$IncludesInstallSummary = $true
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Versions')
    $lines.Add('')
    if ($IncludesInstallSummary) {
        $lines.Add('Install counts on older versions of families marked *inflating* are unreliable: with version-comparison detection a device that has a newer version also detects every older one.')
        $lines.Add('')
    }

    foreach ($f in ($Analysis.Families | Sort-Object Family)) {
        $lines.AddRange([string[]]@(Get-AppInventoryFamilyVersionLine -Family $f -Records $Records -IncludesInstallSummary $IncludesInstallSummary))
    }

    return @($lines)
}

# The apps no family claims, the ones that resemble a family first.
function Get-AppInventoryUnmanagedLine {
    param([Parameter(Mandatory = $true)] [hashtable]$Analysis)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Unmanaged apps')
    $lines.Add('')

    if ($Analysis.Unmanaged.Count -eq 0) {
        $lines.Add('None.')
        $lines.Add('')
        return @($lines)
    }

    $lines.Add('| App | Version | Publisher | Looks like |')
    $lines.Add('| --- | --- | --- | --- |')
    foreach ($u in ($Analysis.Unmanaged | Sort-Object { $null -eq $_.LooksLike }, DisplayName)) {
        $lines.Add("| $($u.DisplayName) | $($u.DisplayVersion) | $($u.Publisher) | $($u.LooksLike ?? '-') |")
    }
    $lines.Add('')

    return @($lines)
}

# Human-readable Markdown report.
function Format-AppInventoryMarkdown {
    param(
        [Parameter(Mandatory = $true)] [string]$TenantName,
        [Parameter(Mandatory = $true)] [datetime]$GeneratedUtc,
        [Parameter(Mandatory = $true)] [hashtable]$Analysis,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Records,
        [bool]$IncludesInstallSummary = $true
    )

    $lines = @(
        @(Get-AppInventoryHeaderLine -TenantName $TenantName -GeneratedUtc $GeneratedUtc -Summary $Analysis.Summary) +
        @(Get-AppInventoryFamilyTableLine -Analysis $Analysis) +
        @(Get-AppInventoryDeleteCandidateLine -Analysis $Analysis) +
        @(Get-AppInventoryAnomalyLine -Analysis $Analysis) +
        @(Get-AppInventoryVersionLine -Analysis $Analysis -Records $Records -IncludesInstallSummary $IncludesInstallSummary) +
        @(Get-AppInventoryUnmanagedLine -Analysis $Analysis)
    )

    return ($lines -join "`n")
}
