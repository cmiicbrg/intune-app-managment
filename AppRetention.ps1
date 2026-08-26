#Requires -Version 7.4

# AppRetention.ps1
# Pure retention evaluation for the versions of one app family in Intune. No Graph calls, no
# config-file access: callers (the inventory report, the cleanup tooling, later Deploy-ToIntune's
# post-deploy step) gather a family's versions and the effective policy and pass them in, so one
# evaluation drives both the report and the deletions.
#
# Policy (see TenantDeployments.ps1 for how it is configured):
#   a version is KEPT when it is among the newest KeepNewest versions, or was still the CURRENT
#   (newest) version at some point within the last KeepNewerThanWeeks weeks - i.e. the first
#   newer version was created less than that many weeks ago; otherwise it is a DELETE candidate.
#   The window is about devices, not about the version's own age: a device that last checked in
#   N weeks ago runs whatever was current back then, and that version must still exist in Intune
#   for supersedence/auto-update to pick the device up. (A fast-moving family can have three
#   builds younger than the window and still need last month's build kept.)
# Always kept regardless of policy: the newest version, versions whose id is in ProtectedAppIds
# (dependency targets), versions with an unparseable version or unknown creation date, and
# versions superseded at an unknown time (a newer version without creation date).
# Versions that share a version number with another app are marked REVIEW - never deleted
# automatically, because it is not knowable which duplicate carries the live assignments.

# Evaluates one family. Returns one object per input app, newest first:
#     Id, DisplayName, Version, CreatedDateTime, Rank, AgeWeeks, SupersededAt, SupersededWeeks,
#     Action ('Keep'|'Delete'|'Review'), Reasons
# SupersededAt is the creation time of the first newer version ($null for the newest);
# SupersededWeeks the weeks since then - the number the window rule is about.
# Rank counts distinct version numbers (duplicates share a rank), so a duplicate never consumes a
# KeepNewest slot. Unparseable versions have no rank.
# Weeks between a creation time and $Now, $null when the creation time is unknown.
function Get-AppRetentionAgeWeeks {
    param($CreatedDateTime, [datetime]$Now)

    if ($null -eq $CreatedDateTime) { return $null }
    return [math]::Round(($Now - [datetime]$CreatedDateTime).TotalDays / 7, 1)
}

# Distinct-version ranks (1 = newest) and how many apps share each version string, both keyed by
# version string. Duplicates share a rank, so a duplicate never consumes a KeepNewest slot.
function Get-AppRetentionVersionRank {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Ordered
    )

    $rankByVersion = @{}
    $countByVersion = @{}
    $rank = 0
    foreach ($app in $Ordered) {
        $key = $app.Version.ToString()
        if (-not $rankByVersion.ContainsKey($key)) {
            $rank++
            $rankByVersion[$key] = $rank
            $countByVersion[$key] = 0
        }
        $countByVersion[$key]++
    }

    return @{ Rank = $rankByVersion; Count = $countByVersion }
}

# When did this version stop being the newest? At the creation of the first newer version. A
# device that last checked in before that moment may still run this version, so it stays as long
# as that moment lies inside the window. Returns @{ At; Weeks; Reason }, where Reason is the Keep
# reason that moment earns ($null once the version has aged out of the window). The newest version
# is never superseded; a newer version without a creation date makes the moment unknowable, which
# is itself a Keep reason.
function Get-AppRetentionSupersession {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Ordered,

        [Parameter(Mandatory = $true)]
        $App,

        [Parameter(Mandatory = $true)]
        [int]$Rank,

        [Parameter(Mandatory = $true)]
        [hashtable]$Policy,

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    if ($Rank -le 1) {
        return @{ At = $null; Weeks = $null; Reason = $null }
    }

    $newerDates = @($Ordered | Where-Object { $_.Version -gt $App.Version } | ForEach-Object { $_.CreatedDateTime })
    if (@($newerDates | Where-Object { $null -eq $_ }).Count -gt 0) {
        return @{ At = $null; Weeks = $null; Reason = 'superseded at an unknown time (a newer version has no creation date)' }
    }

    $at = ($newerDates | ForEach-Object { [datetime]$_ } | Measure-Object -Minimum).Minimum
    $weeks = [math]::Round(($Now - $at).TotalDays / 7, 1)
    $windowStart = $Now.AddDays(-7 * [int]$Policy.KeepNewerThanWeeks)
    $reason = $null
    if ($at -ge $windowStart) {
        $reason = "current until $weeks weeks ago (within $($Policy.KeepNewerThanWeeks) weeks)"
    }

    return @{ At = $at; Weeks = $weeks; Reason = $reason }
}

# The plan entry for one version with a parseable version number: every Keep reason it earns, and
# Delete only when it earned none.
function New-AppRetentionEntry {
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [Parameter(Mandatory = $true)]
        [int]$Rank,

        # How many apps share this version number - more than one means Review
        [Parameter(Mandatory = $true)]
        [int]$DuplicateCount,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Ordered,

        [Parameter(Mandatory = $true)]
        [hashtable]$Policy,

        [string[]]$ProtectedAppIds = @(),

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    $keepNewest = [int]$Policy.KeepNewest
    $reasons = [System.Collections.Generic.List[string]]::new()

    if ($Rank -eq 1) {
        $reasons.Add('newest version')
    }
    elseif ($Rank -le $keepNewest) {
        $reasons.Add("within newest $keepNewest")
    }

    if ($null -eq $App.CreatedDateTime) {
        $reasons.Add('unknown creation date')
    }

    $superseded = Get-AppRetentionSupersession -Ordered $Ordered -App $App -Rank $Rank -Policy $Policy -Now $Now
    if ($superseded.Reason) {
        $reasons.Add($superseded.Reason)
    }

    if ($ProtectedAppIds -contains $App.Id) {
        $reasons.Add('protected (dependency target)')
    }

    $action = if ($reasons.Count -gt 0) { 'Keep' } else { 'Delete' }
    if ($action -eq 'Delete') {
        $reasons.Add("superseded $($superseded.Weeks) weeks ago (more than $($Policy.KeepNewerThanWeeks) weeks) and outside newest $keepNewest")
    }

    if ($DuplicateCount -gt 1) {
        $reasons.Add('duplicate version - review manually')
        $action = 'Review'
    }

    return [PSCustomObject]@{
        Id              = $App.Id
        DisplayName     = $App.DisplayName
        Version         = $App.Version
        CreatedDateTime = $App.CreatedDateTime
        Rank            = $Rank
        AgeWeeks        = Get-AppRetentionAgeWeeks -CreatedDateTime $App.CreatedDateTime -Now $Now
        SupersededAt    = $superseded.At
        SupersededWeeks = $superseded.Weeks
        Action          = $action
        Reasons         = @($reasons)
    }
}

# The plan entry for a version whose version number cannot be parsed: always kept, never ranked.
function New-AppRetentionUnparseableEntry {
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [string[]]$ProtectedAppIds = @(),

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $reasons.Add('unparseable version - never deleted automatically')

    if ($null -eq $App.CreatedDateTime) {
        $reasons.Add('unknown creation date')
    }
    if ($ProtectedAppIds -contains $App.Id) {
        $reasons.Add('protected (dependency target)')
    }

    return [PSCustomObject]@{
        Id              = $App.Id
        DisplayName     = $App.DisplayName
        Version         = $null
        CreatedDateTime = $App.CreatedDateTime
        Rank            = $null
        AgeWeeks        = Get-AppRetentionAgeWeeks -CreatedDateTime $App.CreatedDateTime -Now $Now
        SupersededAt    = $null
        SupersededWeeks = $null
        Action          = 'Keep'
        Reasons         = @($reasons)
    }
}

function Get-AppRetentionPlan {
    param(
        # Objects with Id, DisplayName, Version ([version] or $null), CreatedDateTime ([datetime] or $null)
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Apps,

        # @{ KeepNewest = <int>; KeepNewerThanWeeks = <int> }
        [Parameter(Mandatory = $true)]
        [hashtable]$Policy,

        # App ids that must never be deleted (e.g. dependency targets of kept apps)
        [string[]]$ProtectedAppIds = @(),

        # Injectable for tests
        [datetime]$Now = [datetime]::UtcNow
    )

    if ($Apps.Count -eq 0) {
        return @()
    }

    $parseable = @($Apps | Where-Object { $null -ne $_.Version })
    $unparseable = @($Apps | Where-Object { $null -eq $_.Version })

    # Newest first; identical versions ordered newest-created first
    $ordered = @($parseable | Sort-Object -Property @{ Expression = 'Version'; Descending = $true }, @{ Expression = 'CreatedDateTime'; Descending = $true })
    $ranks = Get-AppRetentionVersionRank -Ordered $ordered

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($app in $ordered) {
        $key = $app.Version.ToString()
        $results.Add((New-AppRetentionEntry -App $app -Rank $ranks.Rank[$key] -DuplicateCount $ranks.Count[$key] -Ordered $ordered -Policy $Policy -ProtectedAppIds $ProtectedAppIds -Now $Now))
    }

    # Unparseable versions last, newest-created first (unknown dates at the very end), so the
    # output order is deterministic regardless of input order
    $orderedUnparseable = @($unparseable | Sort-Object -Property @{ Expression = { $null -eq $_.CreatedDateTime } }, @{ Expression = 'CreatedDateTime'; Descending = $true }, 'DisplayName')
    foreach ($app in $orderedUnparseable) {
        $results.Add((New-AppRetentionUnparseableEntry -App $app -ProtectedAppIds $ProtectedAppIds -Now $Now))
    }

    return @($results)
}

# The Delete candidates from a retention plan, oldest version first - the only safe deletion
# order, because removing a newer node before an older one splits the supersedence chain.
function Select-AppRetentionDeleteCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Plan
    )

    return @($Plan | Where-Object { $_.Action -eq 'Delete' } |
        Sort-Object -Property @{ Expression = 'Version'; Descending = $false }, @{ Expression = 'CreatedDateTime'; Descending = $false })
}
