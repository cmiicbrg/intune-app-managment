#Requires -Version 7.4

# AppCleanup.ps1
# Pure planner for the version cleanup: turns an inventory analysis (Get-AppInventoryAnalysis)
# into the ordered list of versions to delete, plus every delete candidate that is NOT deleted
# and why. No Graph calls - Remove-OldIntuneAppVersions.ps1 executes the plan.
#
# What gets deleted: the retention evaluator's delete candidates (oldest first) of families that
# are in the tenant's deployment plan. Everything else is off limits and cannot be overridden by
# a parameter: Review/protected verdicts, apps whose relationships could not be read, the newest
# version, anything within the KeepNewest window, dependency targets, and all unmanaged apps
# (non-conforming names are not even records of a family).

. (Join-Path $PSScriptRoot "AppInventory.ps1")

# Why a delete candidate must NOT be deleted - $null when it may be. Every rule here is already
# enforced by the retention evaluator or the analysis; they are re-checked so a future change
# upstream cannot silently widen the deletions.
function Get-AppCleanupSkipReason {
    param(
        # One Analysis family
        [Parameter(Mandatory = $true)]
        $Family,

        # The candidate's inventory record ($null when the analysis has none)
        [AllowNull()]
        $Record
    )

    if (-not $Family.InPlan) { return "family '$($Family.Family)' is not in the tenant's deployment plan" }
    if ($null -eq $Record) { return 'candidate has no inventory record' }
    if ($Record.Retention.Action -ne 'Delete') { return "retention verdict is '$($Record.Retention.Action)', not 'Delete'" }
    if ($Record.RelationshipsUnavailable) { return 'relationships could not be read - may be a dependency target' }
    if (@($Record.DependencyOf).Count -gt 0) { return 'dependency target' }
    if ($Family.Newest -and $Record.Id -eq $Family.Newest.Id) { return 'newest version' }
    if ($Record.Retention.Rank -le $Family.Policy.KeepNewest) { return "within the newest $($Family.Policy.KeepNewest) versions" }

    return $null
}

# One plan entry for one delete candidate. Everything the inventory record answers is $null when
# there is no record; AssignmentCount and InstalledDeviceCount are also $null ($null = unknown)
# when the tenant read for that record failed. A Reason is only carried by skipped entries.
function New-AppCleanupEntry {
    param(
        [Parameter(Mandatory = $true)]
        $Family,

        # One DeleteCandidate of that family
        [Parameter(Mandatory = $true)]
        $Candidate,

        [AllowNull()]
        $Record,

        [AllowNull()]
        [string]$Reason
    )

    $entry = [ordered]@{
        Id                   = $Candidate.Id
        Family               = $Family.Family
        DisplayName          = $Candidate.DisplayName
        DisplayVersion       = if ($Record) { $Record.DisplayVersion } else { $Candidate.Version }
        Version              = $Candidate.Version
        Rank                 = $Record.Retention.Rank                                     # $null without a record
        AgeWeeks             = $Candidate.AgeWeeks
        SupersededWeeks      = $Candidate.SupersededWeeks
        CreatedDateTime      = $Record.CreatedDateTime
        AssignmentCount      = if ($Record -and -not $Record.AssignmentsUnavailable) { @($Record.Assignments).Count } else { $null }
        SupersededBy         = if ($Record) { @($Record.SupersededBy | ForEach-Object { $_.TargetDisplayName }) } else { @() }
        InstalledDeviceCount = if ($Record -and $Record.InstallSummary) { $Record.InstallSummary.installedDeviceCount } else { $null }
    }

    if ($Reason) { $entry.Reason = $Reason }

    return [PSCustomObject]$entry
}

# The plan for one family: its deletions (oldest version first) and every delete candidate that is
# not deleted, with the reason why.
function Get-AppCleanupFamilyPlan {
    param(
        [Parameter(Mandatory = $true)]
        $Family,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Records
    )

    $members = @($Records | Where-Object { $_.Family -eq $Family.Family })
    $deletions = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    # DeleteCandidates are already ordered oldest first (Select-AppRetentionDeleteCandidates)
    foreach ($candidate in @($Family.DeleteCandidates)) {
        $record = $members | Where-Object Id -eq $candidate.Id | Select-Object -First 1
        $reason = Get-AppCleanupSkipReason -Family $Family -Record $record
        $entry = New-AppCleanupEntry -Family $Family -Candidate $candidate -Record $record -Reason $reason

        if ($reason) { $skipped.Add($entry) } else { $deletions.Add($entry) }
    }

    return [PSCustomObject]@{
        Family                = $Family.Family
        InPlan                = $Family.InPlan
        Policy                = $Family.Policy
        VersionCount          = $Family.VersionCount
        KeepCount             = $Family.KeepCount
        ReviewCount           = $Family.ReviewCount
        Deletions             = @($deletions)
        Skipped               = @($skipped)
        RemainingAfterCleanup = $Family.VersionCount - $deletions.Count
    }
}

function Get-AppCleanupPlan {
    <#
    .SYNOPSIS
    Builds the ordered deletion list from an inventory analysis

    .DESCRIPTION
    Returns @{ Families = @(per family: Deletions, Skipped, counts); Deletions = @(all, in
    execution order: family by name, oldest version first); DeletionCount; SkippedCount }.
    #>
    [CmdletBinding()]
    param(
        # Get-AppInventoryAnalysis output
        [Parameter(Mandatory = $true)]
        $Analysis,

        # The records the analysis was run on (their Retention property is filled in)
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Records
    )

    $families = [System.Collections.Generic.List[object]]::new()

    foreach ($family in ($Analysis.Families | Sort-Object Family)) {
        $families.Add((Get-AppCleanupFamilyPlan -Family $family -Records $Records))
    }

    # Execution order: family by name (the loop above), oldest version first (within each family)
    $deletions = @($families | ForEach-Object { $_.Deletions })

    return [PSCustomObject]@{
        Families      = @($families)
        Deletions     = $deletions
        DeletionCount = $deletions.Count
        SkippedCount  = ($families | ForEach-Object { $_.Skipped.Count } | Measure-Object -Sum).Sum ?? 0
    }
}
