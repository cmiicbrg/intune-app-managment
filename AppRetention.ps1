#Requires -Version 7.4

# AppRetention.ps1
# Pure retention evaluation for the versions of one app family in Intune. No Graph calls, no
# config-file access: callers (the inventory report, the cleanup tooling, later Deploy-ToIntune's
# post-deploy step) gather a family's versions and the effective policy and pass them in, so one
# evaluation drives both the report and the deletions.
#
# Policy (see TenantDeployments.ps1 for how it is configured):
#   a version is KEPT when it is among the newest KeepNewest versions, or was created within the
#   last KeepNewerThanWeeks weeks; otherwise it is a DELETE candidate.
# Always kept regardless of policy: the newest version, versions whose id is in ProtectedAppIds
# (dependency targets), versions with an unparseable version or unknown creation date.
# Versions that share a version number with another app are marked REVIEW - never deleted
# automatically, because it is not knowable which duplicate carries the live assignments.

# Evaluates one family. Returns one object per input app, newest first:
#     Id, DisplayName, Version, CreatedDateTime, Rank, AgeWeeks, Action ('Keep'|'Delete'|'Review'), Reasons
# Rank counts distinct version numbers (duplicates share a rank), so a duplicate never consumes a
# KeepNewest slot. Unparseable versions have no rank.
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

    $keepNewest = [int]$Policy.KeepNewest
    $ageCutoff = $Now.AddDays(-7 * [int]$Policy.KeepNewerThanWeeks)

    $parseable = @($Apps | Where-Object { $null -ne $_.Version })
    $unparseable = @($Apps | Where-Object { $null -eq $_.Version })

    # Newest first; identical versions ordered newest-created first
    $ordered = @($parseable | Sort-Object -Property @{ Expression = 'Version'; Descending = $true }, @{ Expression = 'CreatedDateTime'; Descending = $true })

    # Distinct-version ranks and duplicate detection
    $rankByVersion = @{}
    $countByVersion = @{}
    $rank = 0
    foreach ($app in $ordered) {
        $key = $app.Version.ToString()
        if (-not $rankByVersion.ContainsKey($key)) {
            $rank++
            $rankByVersion[$key] = $rank
            $countByVersion[$key] = 0
        }
        $countByVersion[$key]++
    }

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($app in $ordered) {
        $key = $app.Version.ToString()
        $appRank = $rankByVersion[$key]
        $reasons = [System.Collections.Generic.List[string]]::new()
        $ageWeeks = $null

        if ($appRank -eq 1) {
            $reasons.Add('newest version')
        }
        elseif ($appRank -le $keepNewest) {
            $reasons.Add("within newest $keepNewest")
        }

        if ($null -eq $app.CreatedDateTime) {
            $reasons.Add('unknown creation date')
        }
        else {
            $ageWeeks = [math]::Round(($Now - [datetime]$app.CreatedDateTime).TotalDays / 7, 1)
            if ([datetime]$app.CreatedDateTime -ge $ageCutoff) {
                $reasons.Add("newer than $($Policy.KeepNewerThanWeeks) weeks")
            }
        }

        if ($ProtectedAppIds -contains $app.Id) {
            $reasons.Add('protected (dependency target)')
        }

        $action = if ($reasons.Count -gt 0) { 'Keep' } else { 'Delete' }
        if ($action -eq 'Delete') {
            $reasons.Add("older than $($Policy.KeepNewerThanWeeks) weeks and outside newest $keepNewest")
        }

        if ($countByVersion[$key] -gt 1) {
            $reasons.Add('duplicate version - review manually')
            $action = 'Review'
        }

        $results.Add([PSCustomObject]@{
            Id              = $app.Id
            DisplayName     = $app.DisplayName
            Version         = $app.Version
            CreatedDateTime = $app.CreatedDateTime
            Rank            = $appRank
            AgeWeeks        = $ageWeeks
            Action          = $action
            Reasons         = @($reasons)
        })
    }

    foreach ($app in $unparseable) {
        $ageWeeks = if ($null -ne $app.CreatedDateTime) { [math]::Round(($Now - [datetime]$app.CreatedDateTime).TotalDays / 7, 1) } else { $null }
        $results.Add([PSCustomObject]@{
            Id              = $app.Id
            DisplayName     = $app.DisplayName
            Version         = $null
            CreatedDateTime = $app.CreatedDateTime
            Rank            = $null
            AgeWeeks        = $ageWeeks
            Action          = 'Keep'
            Reasons         = @('unparseable version - never deleted automatically')
        })
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
