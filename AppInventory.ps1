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
        foreach ($candidate in ($Families | Sort-Object { $_.BaseName.Length } -Descending)) {
            if ("$($App.displayName)".StartsWith($candidate.BaseName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $nearMiss = $candidate.AppConfigName
                break
            }
        }
    }

    $versionInfo = Get-IntuneAppVersion -App $App

    $detection = @(foreach ($rule in @($App.detectionRules)) {
        [ordered]@{
            Type     = "$($rule.'@odata.type')" -replace '^#microsoft\.graph\.', ''
            Operator = if ($rule.PSObject.Properties.Name -contains 'operator') { "$($rule.operator)" } else { $null }
        }
    })
    $inflating = [bool]($detection | Where-Object {
        $_.Type -eq 'win32LobAppPowerShellScriptDetection' -or ($_.Operator -and $script:InflatingOperators -contains $_.Operator)
    })

    # @($null) iterates once in PowerShell - a failed read ($Assignments = $null) must yield an
    # empty set here, with AssignmentsUnavailable carrying the "unknown" state.
    $assignmentRecords = @(foreach ($assignment in @($Assignments)) {
        if ($null -eq $assignment) { continue }
        [ordered]@{
            Intent               = $assignment.Intent
            Target               = $assignment.Target
            GroupId              = $assignment.GroupId
            GroupName            = if ($assignment.GroupId -and $GroupNames.ContainsKey($assignment.GroupId)) { $GroupNames[$assignment.GroupId] } else { $null }
            AutoUpdateSuperseded = $assignment.AutoUpdateSuperseded
        }
    })

    $supersedes = @(); $supersededBy = @(); $dependsOn = @(); $dependencyOf = @()
    foreach ($relationship in @($Relationships)) {
        $entry = [ordered]@{
            TargetId             = $relationship.targetId
            TargetDisplayName    = $relationship.targetDisplayName
            TargetDisplayVersion = $relationship.targetDisplayVersion
        }
        $isChild = ("$($relationship.targetType)" -eq 'child')
        switch -Wildcard ("$($relationship.'@odata.type')") {
            '*mobileAppSupersedence' {
                $entry['SupersedenceType'] = $relationship.supersedenceType
                if ($isChild) { $supersedes += $entry } else { $supersededBy += $entry }
            }
            '*mobileAppDependency' {
                $entry['DependencyType'] = $relationship.dependencyType
                if ($isChild) { $dependsOn += $entry } else { $dependencyOf += $entry }
            }
        }
    }

    $summary = $null
    if ($null -ne $InstallSummary) {
        $summary = [ordered]@{}
        foreach ($name in 'installedDeviceCount', 'failedDeviceCount', 'notInstalledDeviceCount', 'pendingInstallDeviceCount', 'notApplicableDeviceCount', 'installedUserCount', 'failedUserCount', 'notInstalledUserCount', 'pendingInstallUserCount', 'notApplicableUserCount') {
            if ($InstallSummary.PSObject.Properties.Name -contains $name) {
                $summary[$name] = $InstallSummary.$name
            }
        }
    }

    return [PSCustomObject]@{
        Id                    = $App.id
        DisplayName           = $App.displayName
        DisplayVersion        = $App.displayVersion
        Publisher             = $App.publisher
        CreatedDateTime       = if ($App.createdDateTime) { [datetime]$App.createdDateTime } else { $null }
        LastModifiedDateTime  = if ($App.lastModifiedDateTime) { [datetime]$App.lastModifiedDateTime } else { $null }
        IsAssigned            = $App.isAssigned
        PublishingState       = $App.publishingState
        Size                  = $App.size
        Family                = if ($family) { $family.AppConfigName } else { $null }
        FamilyNearMiss        = $nearMiss
        Version               = if ($versionInfo) { [ordered]@{ Raw = $versionInfo.Raw; Parsed = if ($versionInfo.Version) { $versionInfo.Version.ToString() } else { $null }; Source = $versionInfo.Source } } else { $null }
        ParsedVersion         = if ($versionInfo) { $versionInfo.Version } else { $null }
        Detection             = $detection
        InflatingDetection    = $inflating
        Assignments           = $assignmentRecords
        AssignmentsUnavailable = ($null -eq $Assignments)
        RelationshipsUnavailable = ($null -eq $Relationships)
        Supersedes            = $supersedes
        SupersededBy          = $supersededBy
        DependsOn             = $dependsOn
        DependencyOf          = $dependencyOf
        InstallSummary        = $summary
        Retention             = $null   # filled in by Get-AppInventoryAnalysis for managed apps
    }
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
        foreach ($verdict in $plan) {
            $record = $members | Where-Object Id -eq $verdict.Id | Select-Object -First 1
            # An app whose relationships could not be read may be a dependency target we cannot
            # see, and dependency targets are always kept - so it must not become a delete
            # candidate (the cleanup consumes these verdicts). Downgrade to Review.
            if ($record.RelationshipsUnavailable -and $verdict.Action -eq 'Delete') {
                $verdict.Action = 'Review'
                $verdict.Reasons = @($verdict.Reasons) + 'relationships could not be read - may be a dependency target; deletion suppressed, re-run the inventory'
            }
            $record.Retention = [ordered]@{ Rank = $verdict.Rank; AgeWeeks = $verdict.AgeWeeks; Action = $verdict.Action; Reasons = @($verdict.Reasons) }
        }

        $relationshipsUnavailable = @($members | Where-Object RelationshipsUnavailable)
        if ($relationshipsUnavailable.Count -gt 0) {
            $anomalies.Add((New-Anomaly -Type 'RelationshipsUnavailable' -Family $family.AppConfigName -Message "relationships of $($relationshipsUnavailable.Count) version(s) could not be read - supersedence graph size and dependency protection are incomplete for this family and deletion of the affected version(s) is suppressed; re-run the inventory" -AppIds @($relationshipsUnavailable.Id)))
        }

        $newest = $plan | Where-Object Rank -eq 1 | Select-Object -First 1
        $graphNodes = ($members | ForEach-Object { $componentSize[$_.Id] } | Measure-Object -Maximum).Maximum
        if ($null -eq $graphNodes) { $graphNodes = 0 }

        # Anomalies
        # Duplicates are detected by version number, not by the Review action - Review is also
        # the verdict for an app whose relationships could not be read.
        $duplicateGroups = @($plan | Where-Object { $null -ne $_.Version } | Group-Object { $_.Version.ToString() } | Where-Object Count -gt 1)
        foreach ($group in $duplicateGroups) {
            $anomalies.Add((New-Anomaly -Type 'DuplicateVersion' -Family $family.AppConfigName -Message "version $($group.Name) exists more than once - review manually, retention will not delete either copy" -AppIds @($group.Group.Id)))
        }

        # A superseded version keeping its 'available' assignment is normal and required: the
        # Company Portal hides it behind the newest version, and the assignment is what keeps
        # supersedence/auto-update working - never flag that. What does show up as a separate
        # app in the Company Portal is an older version with an 'available' assignment (the
        # intent the portal lists) that is NOT superseded by anything - a chain split at the
        # graph limit, or a version that was never linked. Required-only assignments are not
        # visible in the portal and are left alone.
        $unlinkedOlder = @($members | Where-Object {
            $_.Retention.Rank -and $_.Retention.Rank -gt 1 -and
            @($_.SupersededBy).Count -eq 0 -and -not $_.RelationshipsUnavailable -and
            @(Select-AvailableAssignment -Assignments $_.Assignments).Count -gt 0
        })
        if ($unlinkedOlder.Count -gt 0) {
            $names = ($unlinkedOlder | ForEach-Object { "$($_.DisplayName) v$($_.DisplayVersion)" }) -join ', '
            $anomalies.Add((New-Anomaly -Type 'OlderVersionUnlinked' -Family $family.AppConfigName -Message "$($unlinkedOlder.Count) older version(s) are assigned 'available' but not superseded by any version ($names) - they show up as separate apps in the Company Portal instead of being hidden behind the newest one. Retention deletes them once they leave the keep window; until then, make the next newer version supersede them." -AppIds @($unlinkedOlder.Id)))
        }

        if ($appConfig -and $appConfig.AutoUpdate -eq $true) {
            $gaps = @($members | Where-Object {
                @($_.Supersedes).Count -gt 0 -and
                @(Select-AvailableAssignment -Assignments $_.Assignments | Where-Object { $_.AutoUpdateSuperseded -ne $true }).Count -gt 0
            })
            if ($gaps.Count -gt 0) {
                $anomalies.Add((New-Anomaly -Type 'AutoUpdateNotEnabled' -Family $family.AppConfigName -Message "$($gaps.Count) superseding version(s) have an 'available' assignment without auto-update, although AutoUpdate is enabled in AppConfig - users see them as 'New' instead of updating automatically" -AppIds @($gaps.Id)))
            }
        }

        if ($newest) {
            $newestRecord = $members | Where-Object Id -eq $newest.Id
            if (@($newestRecord.Assignments).Count -eq 0 -and -not $newestRecord.AssignmentsUnavailable -and -not ($appConfig -and $appConfig.HideFromPortal -eq $true)) {
                $anomalies.Add((New-Anomaly -Type 'NewestUnassigned' -Family $family.AppConfigName -Message "the newest version ($($newestRecord.DisplayName) v$($newestRecord.DisplayVersion)) has no assignments" -AppIds @($newestRecord.Id)))
            }
        }

        if ($graphNodes -ge $script:SupersedenceGraphWarnAt) {
            $anomalies.Add((New-Anomaly -Type 'SupersedenceGraphNearLimit' -Family $family.AppConfigName -Message "supersedence graph has $graphNodes node(s); Intune allows $script:SupersedenceGraphNodeLimit - the next version's supersedence will fail once the limit is reached" -AppIds @($members.Id)))
        }

        $familyReports.Add([PSCustomObject]@{
            Family                  = $family.AppConfigName
            BaseName                = $family.BaseName
            InPlan                  = $inPlan
            Policy                  = [ordered]@{ KeepNewest = $policy.KeepNewest; KeepNewerThanWeeks = $policy.KeepNewerThanWeeks; Source = $policy.Source; OptIn = $policy.OptIn }
            VersionCount            = $members.Count
            Newest                  = if ($newest) { [ordered]@{ Id = $newest.Id; DisplayName = $newest.DisplayName; Version = $newest.Version.ToString() } } else { $null }
            OldestAgeWeeks          = ($plan | Where-Object { $null -ne $_.AgeWeeks } | Measure-Object -Property AgeWeeks -Maximum).Maximum
            SupersedenceGraphNodes  = $graphNodes
            InflatingDetection      = [bool]($members | Where-Object InflatingDetection | Select-Object -First 1)
            KeepCount               = @($plan | Where-Object Action -eq 'Keep').Count
            DeleteCandidateCount    = @($plan | Where-Object Action -eq 'Delete').Count
            ReviewCount             = @($plan | Where-Object Action -eq 'Review').Count
            DeleteCandidates        = @(Select-AppRetentionDeleteCandidates -Plan $plan | ForEach-Object { [ordered]@{ Id = $_.Id; DisplayName = $_.DisplayName; Version = $_.Version.ToString(); AgeWeeks = $_.AgeWeeks } })
        })
    }

    # Unmanaged apps: near misses first (actionable), then everything else
    $unmanaged = [System.Collections.Generic.List[object]]::new()
    foreach ($record in ($Records | Where-Object { $null -eq $_.Family })) {
        # The anomaly only fires when the near-miss family is in the analysis scope (with -AppName
        # the record may resemble an out-of-scope family); the Unmanaged listing keeps LooksLike
        # either way.
        $nearMissFamily = if ($record.FamilyNearMiss) { $Families | Where-Object AppConfigName -eq $record.FamilyNearMiss | Select-Object -First 1 } else { $null }
        if ($nearMissFamily) {
            $anomalies.Add((New-Anomaly -Type 'NamingConventionMismatch' -Family $record.FamilyNearMiss -Message "'$($record.DisplayName)' looks like $($record.FamilyNearMiss) but does not follow the naming convention, so it is not managed (never superseded, never deleted). Rename it to the pattern '$($nearMissFamily.Name)' with its version to bring it under management." -AppIds @($record.Id)))
        }
        $unmanaged.Add([ordered]@{ Id = $record.Id; DisplayName = $record.DisplayName; DisplayVersion = $record.DisplayVersion; Publisher = $record.Publisher; LooksLike = $record.FamilyNearMiss })
    }

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

    $sizes = Get-SupersedenceComponentSizes -Records $Records
    $nodes = if ($AppId -and $sizes.ContainsKey($AppId)) { [int]$sizes[$AppId] } else { 0 }
    return [PSCustomObject]@{
        Nodes         = $nodes
        NodesAfter    = $nodes + 1
        Limit         = $Limit
        CanAddVersion = ($nodes + 1) -le $Limit
        WillFill      = ($nodes + 1) -eq $Limit
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

# Human-readable Markdown report.
function Format-AppInventoryMarkdown {
    param(
        [Parameter(Mandatory = $true)] [string]$TenantName,
        [Parameter(Mandatory = $true)] [datetime]$GeneratedUtc,
        [Parameter(Mandatory = $true)] [hashtable]$Analysis,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Records,
        [bool]$IncludesInstallSummary = $true
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $s = $Analysis.Summary
    $lines.Add("# Intune Win32 app inventory - $TenantName")
    $lines.Add('')
    $lines.Add("Generated $($GeneratedUtc.ToString('yyyy-MM-dd HH:mm')) UTC. Read-only snapshot; nothing was changed in Intune.")
    $lines.Add('')
    $lines.Add("- Win32 apps: **$($s.TotalWin32Apps)** ($($s.ManagedApps) managed by this tooling, $($s.UnmanagedApps) unmanaged)")
    $lines.Add("- Families present: **$($s.FamiliesPresent)**, near the supersedence graph limit: **$($s.FamiliesNearGraphLimit)**")
    $lines.Add("- Retention: **$($s.DeleteCandidates)** delete candidate(s), **$($s.ReviewItems)** item(s) to review")
    if ($s.AppsWithUnavailableRelationships -gt 0) {
        $lines.Add("- **Incomplete data**: relationships of **$($s.AppsWithUnavailableRelationships)** managed app(s) could not be read; their deletion is suppressed and graph sizes may be understated - re-run the inventory before a cleanup")
    }
    $lines.Add('')

    $lines.Add('## Families')
    $lines.Add('')
    $lines.Add('| Family | In plan | Versions | Newest | Oldest (weeks) | Graph nodes | Policy | Keep | Delete | Review |')
    $lines.Add('| --- | --- | ---: | --- | ---: | ---: | --- | ---: | ---: | ---: |')
    foreach ($f in ($Analysis.Families | Sort-Object Family)) {
        $newest = if ($f.Newest) { "$($f.Newest.DisplayName) ($($f.Newest.Version))" } else { '-' }
        $graph = if ($f.SupersedenceGraphNodes -ge $script:SupersedenceGraphWarnAt) { "**$($f.SupersedenceGraphNodes)** !" } else { "$($f.SupersedenceGraphNodes)" }
        $policy = "$($f.Policy.KeepNewest) / $($f.Policy.KeepNewerThanWeeks)w ($($f.Policy.Source))"
        $lines.Add("| $($f.Family) | $(if ($f.InPlan) { 'yes' } else { 'no' }) | $($f.VersionCount) | $newest | $($f.OldestAgeWeeks) | $graph | $policy | $($f.KeepCount) | $($f.DeleteCandidateCount) | $($f.ReviewCount) |")
    }
    $lines.Add('')

    $lines.Add('## Delete candidates (oldest first, per family)')
    $lines.Add('')
    $any = $false
    foreach ($f in ($Analysis.Families | Sort-Object Family)) {
        if ($f.DeleteCandidates.Count -eq 0) { continue }
        $any = $true
        $lines.Add("### $($f.Family)")
        $lines.Add('')
        $lines.Add('| App | Version | Age (weeks) |')
        $lines.Add('| --- | --- | ---: |')
        foreach ($c in $f.DeleteCandidates) {
            $lines.Add("| $($c.DisplayName) | $($c.Version) | $($c.AgeWeeks) |")
        }
        $lines.Add('')
    }
    if (-not $any) { $lines.Add('None under the current policy.'); $lines.Add('') }

    $lines.Add('## Anomalies')
    $lines.Add('')
    if ($Analysis.Anomalies.Count -eq 0) {
        $lines.Add('None.')
    }
    else {
        foreach ($a in ($Analysis.Anomalies | Sort-Object Type, Family)) {
            $lines.Add("- **$($a.Type)** [$($a.Family)]: $($a.Message)")
        }
    }
    $lines.Add('')

    $lines.Add('## Versions')
    $lines.Add('')
    if ($IncludesInstallSummary) {
        $lines.Add('Install counts on older versions of families marked *inflating* are unreliable: with version-comparison detection a device that has a newer version also detects every older one.')
        $lines.Add('')
    }
    foreach ($f in ($Analysis.Families | Sort-Object Family)) {
        $members = @($Records | Where-Object { $_.Family -eq $f.Family } | Sort-Object { $_.Retention.Rank ?? [int]::MaxValue }, { $_.CreatedDateTime } -Descending:$false)
        $lines.Add("### $($f.Family)$(if ($f.InflatingDetection) { ' (inflating detection)' })")
        $lines.Add('')
        $header = '| Rank | App | Version | Created | Age (weeks) | Assignments | Supersedes | Action | Reasons |'
        $sep = '| ---: | --- | --- | --- | ---: | --- | --- | --- | --- |'
        if ($IncludesInstallSummary) { $header += ' Installed / Pending / Failed |'; $sep += ' --- |' }
        $lines.Add($header)
        $lines.Add($sep)
        foreach ($m in $members) {
            $assign = if ($m.Assignments.Count -eq 0) { '-' } else { ($m.Assignments | ForEach-Object { "$($_.Target) ($($_.Intent)$(if ($_.AutoUpdateSuperseded -eq $true) { ', auto-update' }))" }) -join '; ' }
            $sup = if ($m.Supersedes.Count -eq 0) { '-' } else { ($m.Supersedes | ForEach-Object { $_.TargetDisplayVersion }) -join ', ' }
            $created = if ($m.CreatedDateTime) { $m.CreatedDateTime.ToString('yyyy-MM-dd') } else { '-' }
            $row = "| $($m.Retention.Rank ?? '-') | $($m.DisplayName) | $($m.DisplayVersion) | $created | $($m.Retention.AgeWeeks ?? '-') | $assign | $sup | $($m.Retention.Action) | $($m.Retention.Reasons -join '; ') |"
            if ($IncludesInstallSummary) {
                $row += if ($m.InstallSummary) { " $($m.InstallSummary.installedDeviceCount) / $($m.InstallSummary.pendingInstallDeviceCount) / $($m.InstallSummary.failedDeviceCount) |" } else { ' - |' }
            }
            $lines.Add($row)
        }
        $lines.Add('')
    }

    $lines.Add('## Unmanaged apps')
    $lines.Add('')
    if ($Analysis.Unmanaged.Count -eq 0) {
        $lines.Add('None.')
    }
    else {
        $lines.Add('| App | Version | Publisher | Looks like |')
        $lines.Add('| --- | --- | --- | --- |')
        foreach ($u in ($Analysis.Unmanaged | Sort-Object { $null -eq $_.LooksLike }, DisplayName)) {
            $lines.Add("| $($u.DisplayName) | $($u.DisplayVersion) | $($u.Publisher) | $($u.LooksLike ?? '-') |")
        }
    }
    $lines.Add('')

    return ($lines -join "`n")
}
