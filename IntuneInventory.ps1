#Requires -Version 7.4

# IntuneInventory.ps1
# Graph-facing read of a tenant's Win32 apps into inventory records - the one read path shared
# by the inventory report (Get-IntuneAppInventory.ps1) and the cleanup
# (Remove-OldIntuneAppVersions.ps1), so both act on exactly the same evaluation. The analysis
# itself stays in the pure AppInventory.ps1.

. (Join-Path $PSScriptRoot "AppInventory.ps1")

# The tenant's Win32 apps, or - with -OnlyFamilies - just the apps of those families (plus the
# unmanaged ones with -IncludeUnmanaged).
function Get-IntuneAppInventoryList {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Families,
        [string[]]$OnlyFamilies,
        [bool]$IncludeUnmanaged = $false
    )

    if (-not $OnlyFamilies) {
        $apps = @(Get-InteropWin32App)
        Write-Host "  $($apps.Count) Win32 app(s) in tenant" -ForegroundColor Gray
        return ,$apps
    }

    # Classify on the list items' display names so only the selected apps are fetched in full.
    # Deliberately a plain script block: it is only ever invoked from inside Get-InteropWin32App,
    # i.e. from a scope below this one, so $Families/$OnlyFamilies/$IncludeUnmanaged resolve
    # through PowerShell's dynamic scoping. Do NOT turn it into a closure (.GetNewClosure()):
    # a closure is bound to a new dynamic module whose command lookup skips the scope the
    # scripts dot-source into, and Resolve-AppFamily is then not found (observed:
    # CommandNotFoundException in both the tests and a script-scope run).
    $familyFilter = {
        param($displayName)
        $family = Resolve-AppFamily -DisplayName "$displayName" -Families $Families
        if ($family) { $OnlyFamilies -contains $family.AppConfigName } else { [bool]$IncludeUnmanaged }
    }
    $apps = @(Get-InteropWin32App -DisplayNameFilter $familyFilter)
    Write-Host "  $($apps.Count) Win32 app(s) of $($OnlyFamilies -join ', ')$(if ($IncludeUnmanaged) { ' (plus unmanaged apps)' }) in tenant" -ForegroundColor Gray
    return ,$apps
}

# Adds the apps the tenant list does not carry yet (the mobileApps list lags a creation by a few
# seconds; the per-ID GET does not). An app that cannot be read directly is warned about and
# skipped - the caller works with what is there.
function Add-IntuneEnsuredApp {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [array]$Apps,
        [string[]]$EnsureAppIds
    )

    $result = @($Apps)
    foreach ($ensureId in @($EnsureAppIds | Where-Object { $_ })) {
        if (@($result | Where-Object { "$($_.id)" -eq $ensureId }).Count -gt 0) { continue }
        try {
            $late = Get-InteropWin32AppById -AppId $ensureId
            if ($null -ne $late) {
                $result += $late
                Write-Host "  + $($late.displayName) (not in the tenant list yet - fetched directly)" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "  Warning: app '$ensureId' could not be read directly: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    return ,$result
}

# Group name resolution is best-effort: only when the Groups module is already available.
function Initialize-GroupNameResolution {
    param([bool]$ResolveGroupNames = $false)

    if (-not ($ResolveGroupNames -and (Get-Module -ListAvailable -Name Microsoft.Graph.Groups))) {
        return $false
    }

    try {
        Import-Module Microsoft.Graph.Groups -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "  Microsoft.Graph.Groups could not be loaded - group assignments are reported by id" -ForegroundColor Yellow
        return $false
    }
}

# Install counts come from one tenant-wide report (getAppsInstallSummaryReport) rather than one
# request per app. If the report fails, the inventory still works - without counts ($null).
function Get-IntuneInstallSummaryReport {
    try {
        $installSummaries = Get-InteropAppInstallSummaryReport
        Write-Host "  Read install summaries for $($installSummaries.Count) app(s)" -ForegroundColor Gray
        return $installSummaries
    }
    catch {
        Write-Host "  Warning: could not read the install summary report, the inventory will not include install counts: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# One app's assignments, or $null when they could not be read - never an empty set, which is a
# successful read of an unassigned app.
function Read-IntuneAppAssignmentDetail {
    param([Parameter(Mandatory = $true)] $App)

    try {
        $assignments = @(Get-InteropAppAssignmentDetail -AppId $App.id)
        return ,$assignments
    }
    catch {
        Write-Host "  Warning: could not read assignments for '$($App.displayName)': $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# One app's relationships. $null (not an empty set) on failure: the record is marked
# RelationshipsUnavailable and the analysis suppresses its deletion, because it might be a
# dependency target we cannot see.
function Read-IntuneAppRelationshipDetail {
    param([Parameter(Mandatory = $true)] $App)

    try {
        $relationships = @(Get-InteropAppRelationship -AppId $App.id)
        return ,$relationships
    }
    catch {
        Write-Host "  Warning: could not read relationships for '$($App.displayName)': $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# Resolves the display name of every group these assignments target that the cache does not know
# yet (a group that cannot be read is cached as $null, so it is not asked for again).
function Update-AppGroupNameCache {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$GroupNames,
        [AllowNull()] $Assignments,
        [bool]$CanResolveGroups = $false
    )

    if (-not $CanResolveGroups) { return }

    foreach ($assignment in @($Assignments)) {
        if (-not $assignment.GroupId -or $GroupNames.ContainsKey($assignment.GroupId)) { continue }
        try {
            $GroupNames[$assignment.GroupId] = (Get-MgGroup -GroupId $assignment.GroupId -Property displayName -ErrorAction Stop).DisplayName
        }
        catch {
            $GroupNames[$assignment.GroupId] = $null
        }
    }
}

function Read-IntuneAppInventory {
    <#
    .SYNOPSIS
    Reads every Win32 app of the connected tenant into inventory records

    .DESCRIPTION
    Lists the apps (Get-InteropWin32App), then reads each app's assignments and relationships -
    a failed read is recorded as "unavailable" on the record, never as an empty set, so the
    analysis can suppress deletion of an app that might be a dependency target - and, with
    -IncludeInstallSummary, the install counts from one tenant-wide report. Group display names
    are resolved with -ResolveGroupNames when Microsoft.Graph.Groups is available.

    With -OnlyFamilies, only the apps of those families are fetched and read in detail
    (classified by display name on the list items, so nothing else is even fetched);
    -IncludeUnmanaged additionally reads the apps that belong to no family. -EnsureAppIds adds
    apps the tenant list does not carry yet (see below).

    Returns @{ Records = @(...); AppCount; SelectedCount; IncludesInstallSummary } - both counts
    are the apps read (the whole tenant, or the selection).
    #>
    [CmdletBinding()]
    param(
        # Get-AppFamilyCatalog output; classification always uses the full catalog
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Families,

        # AppConfig names; when set, only these families' apps get their details read
        [string[]]$OnlyFamilies,

        # With -OnlyFamilies: also read the apps that belong to no family (near-miss reporting)
        [switch]$IncludeUnmanaged,

        # App ids that must be part of the result even if the tenant list does not carry them
        # yet (the mobileApps list lags a creation by a few seconds; the per-ID GET does not).
        # They are fetched directly and classified like everything else.
        [string[]]$EnsureAppIds,

        [switch]$IncludeInstallSummary,

        [switch]$ResolveGroupNames
    )

    # No @() around these calls: both return the array as one object (,$array), which @() would
    # wrap a second time
    $apps = Get-IntuneAppInventoryList -Families $Families -OnlyFamilies $OnlyFamilies -IncludeUnmanaged ([bool]$IncludeUnmanaged)
    $apps = Add-IntuneEnsuredApp -Apps $apps -EnsureAppIds $EnsureAppIds
    $appCount = $apps.Count

    $groupNames = @{}
    $canResolveGroups = Initialize-GroupNameResolution -ResolveGroupNames ([bool]$ResolveGroupNames)

    $installSummaries = $null
    if ($IncludeInstallSummary) {
        $installSummaries = Get-IntuneInstallSummaryReport
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($app in $apps) {
        $index++
        Write-Progress -Activity 'Reading app details' -Status "$index of $($apps.Count): $($app.displayName)" -PercentComplete (100 * $index / [math]::Max($apps.Count, 1))

        $assignments = Read-IntuneAppAssignmentDetail -App $app
        Update-AppGroupNameCache -GroupNames $groupNames -Assignments $assignments -CanResolveGroups $canResolveGroups

        $relationships = Read-IntuneAppRelationshipDetail -App $app

        # $null check, not truthiness: an empty (but successfully read) report is a hashtable
        # that evaluates to $false
        $installSummary = if ($null -ne $installSummaries) { $installSummaries["$($app.id)"] } else { $null }

        $records.Add((ConvertTo-AppInventoryRecord -App $app -Assignments $assignments -Relationships $relationships -InstallSummary $installSummary -Families $Families -GroupNames $groupNames))
    }
    Write-Progress -Activity 'Reading app details' -Completed

    return [PSCustomObject]@{
        Records                = @($records)
        AppCount               = $appCount
        SelectedCount          = $apps.Count
        IncludesInstallSummary = ($null -ne $installSummaries)
    }
}
