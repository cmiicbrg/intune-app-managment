#Requires -Version 7.4

# IntuneInventory.ps1
# Graph-facing read of a tenant's Win32 apps into inventory records - the one read path shared
# by the inventory report (Get-IntuneAppInventory.ps1) and the cleanup
# (Remove-OldIntuneAppVersions.ps1), so both act on exactly the same evaluation. The analysis
# itself stays in the pure AppInventory.ps1.

. (Join-Path $PSScriptRoot "AppInventory.ps1")

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

    if ($OnlyFamilies) {
        # Classify on the list items' display names so only the selected apps are fetched in full.
        # Plain script block, not a closure: Get-InteropWin32App invokes it from a scope below this
        # one, so $Families/$OnlyFamilies/$IncludeUnmanaged resolve dynamically - a closure would
        # run in its own module scope and not see the dot-sourced Resolve-AppFamily.
        $familyFilter = {
            param($displayName)
            $family = Resolve-AppFamily -DisplayName "$displayName" -Families $Families
            if ($family) { $OnlyFamilies -contains $family.AppConfigName } else { [bool]$IncludeUnmanaged }
        }
        $apps = @(Get-InteropWin32App -DisplayNameFilter $familyFilter)
        Write-Host "  $($apps.Count) Win32 app(s) of $($OnlyFamilies -join ', ')$(if ($IncludeUnmanaged) { ' (plus unmanaged apps)' }) in tenant" -ForegroundColor Gray
    }
    else {
        $apps = @(Get-InteropWin32App)
        Write-Host "  $($apps.Count) Win32 app(s) in tenant" -ForegroundColor Gray
    }

    foreach ($ensureId in @($EnsureAppIds | Where-Object { $_ })) {
        if (@($apps | Where-Object { "$($_.id)" -eq $ensureId }).Count -gt 0) { continue }
        try {
            $late = Get-InteropWin32AppById -AppId $ensureId
            if ($null -ne $late) {
                $apps += $late
                Write-Host "  + $($late.displayName) (not in the tenant list yet - fetched directly)" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "  Warning: app '$ensureId' could not be read directly: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    $appCount = $apps.Count

    # Group name resolution is best-effort: only when the Groups module is already available
    $groupNames = @{}
    $canResolveGroups = $false
    if ($ResolveGroupNames -and (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
        try {
            Import-Module Microsoft.Graph.Groups -ErrorAction Stop
            $canResolveGroups = $true
        }
        catch {
            Write-Host "  Microsoft.Graph.Groups could not be loaded - group assignments are reported by id" -ForegroundColor Yellow
        }
    }

    # Install counts come from one tenant-wide report (getAppsInstallSummaryReport) rather than
    # one request per app. If the report fails, the inventory still works - without counts.
    $installSummaries = $null
    if ($IncludeInstallSummary) {
        try {
            $installSummaries = Get-InteropAppInstallSummaryReport
            Write-Host "  Read install summaries for $($installSummaries.Count) app(s)" -ForegroundColor Gray
        }
        catch {
            Write-Host "  Warning: could not read the install summary report, the inventory will not include install counts: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($app in $apps) {
        $index++
        Write-Progress -Activity 'Reading app details' -Status "$index of $($apps.Count): $($app.displayName)" -PercentComplete (100 * $index / [math]::Max($apps.Count, 1))

        $assignments = $null
        try {
            $assignments = @(Get-InteropAppAssignmentDetail -AppId $app.id)
        }
        catch {
            Write-Host "  Warning: could not read assignments for '$($app.displayName)': $($_.Exception.Message)" -ForegroundColor Yellow
        }

        foreach ($assignment in @($assignments)) {
            if ($canResolveGroups -and $assignment.GroupId -and -not $groupNames.ContainsKey($assignment.GroupId)) {
                try {
                    $groupNames[$assignment.GroupId] = (Get-MgGroup -GroupId $assignment.GroupId -Property displayName -ErrorAction Stop).DisplayName
                }
                catch {
                    $groupNames[$assignment.GroupId] = $null
                }
            }
        }

        # $null (not an empty set) on failure: the record is marked RelationshipsUnavailable and
        # the analysis suppresses its deletion, because it might be a dependency target we cannot see.
        $relationships = $null
        try {
            $relationships = @(Get-InteropAppRelationship -AppId $app.id)
        }
        catch {
            Write-Host "  Warning: could not read relationships for '$($app.displayName)': $($_.Exception.Message)" -ForegroundColor Yellow
        }

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
