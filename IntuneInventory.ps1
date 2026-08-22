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

    With -OnlyFamilies, the per-app detail reads are limited to the apps of those families
    (classified by display name right after the list call, so nothing else is fetched);
    -IncludeUnmanaged additionally reads the apps that belong to no family.

    Returns @{ Records = @(...); AppCount (in tenant); SelectedCount; IncludesInstallSummary }.
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

        [switch]$IncludeInstallSummary,

        [switch]$ResolveGroupNames
    )

    $apps = @(Get-InteropWin32App)
    $appCount = $apps.Count
    Write-Host "  $appCount Win32 app(s) in tenant" -ForegroundColor Gray

    if ($OnlyFamilies) {
        $apps = @($apps | Where-Object {
            $family = Resolve-AppFamily -DisplayName "$($_.displayName)" -Families $Families
            if ($family) { $OnlyFamilies -contains $family.AppConfigName } else { [bool]$IncludeUnmanaged }
        })
        Write-Host "  $($apps.Count) selected for $($OnlyFamilies -join ', ')$(if ($IncludeUnmanaged) { ' (plus unmanaged apps)' }) - details are read for these only" -ForegroundColor Gray
    }

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
