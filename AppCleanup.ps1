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
    $deletions = [System.Collections.Generic.List[object]]::new()

    foreach ($family in ($Analysis.Families | Sort-Object Family)) {
        $members = @($Records | Where-Object { $_.Family -eq $family.Family })
        $familyDeletions = [System.Collections.Generic.List[object]]::new()
        $skipped = [System.Collections.Generic.List[object]]::new()

        # DeleteCandidates are already ordered oldest first (Select-AppRetentionDeleteCandidates)
        foreach ($candidate in @($family.DeleteCandidates)) {
            $record = $members | Where-Object Id -eq $candidate.Id | Select-Object -First 1

            # Every rule below is already enforced by the evaluator or the analysis; they are
            # re-checked here so a future change upstream cannot silently widen the deletions.
            $reason = $null
            if (-not $family.InPlan) { $reason = "family '$($family.Family)' is not in the tenant's deployment plan" }
            elseif ($null -eq $record) { $reason = 'candidate has no inventory record' }
            elseif ($record.Retention.Action -ne 'Delete') { $reason = "retention verdict is '$($record.Retention.Action)', not 'Delete'" }
            elseif ($record.RelationshipsUnavailable) { $reason = 'relationships could not be read - may be a dependency target' }
            elseif (@($record.DependencyOf).Count -gt 0) { $reason = 'dependency target' }
            elseif ($family.Newest -and $record.Id -eq $family.Newest.Id) { $reason = 'newest version' }
            elseif ($record.Retention.Rank -le $family.Policy.KeepNewest) { $reason = "within the newest $($family.Policy.KeepNewest) versions" }

            $entry = [ordered]@{
                Id                   = $candidate.Id
                Family               = $family.Family
                DisplayName          = $candidate.DisplayName
                DisplayVersion       = if ($record) { $record.DisplayVersion } else { $candidate.Version }
                Version              = $candidate.Version
                Rank                 = if ($record) { $record.Retention.Rank } else { $null }
                AgeWeeks             = $candidate.AgeWeeks
                CreatedDateTime      = if ($record) { $record.CreatedDateTime } else { $null }
                AssignmentCount      = if ($record) { @($record.Assignments).Count } else { $null }
                SupersededBy         = if ($record) { @($record.SupersededBy | ForEach-Object { $_.TargetDisplayName }) } else { @() }
                InstalledDeviceCount = if ($record -and $record.InstallSummary) { $record.InstallSummary.installedDeviceCount } else { $null }
                Reason               = $reason
            }

            if ($reason) {
                $skipped.Add([PSCustomObject]$entry)
            }
            else {
                $entry.Remove('Reason')
                $familyDeletions.Add([PSCustomObject]$entry)
                $deletions.Add([PSCustomObject]$entry)
            }
        }

        $families.Add([PSCustomObject]@{
            Family                = $family.Family
            InPlan                = $family.InPlan
            Policy                = $family.Policy
            VersionCount          = $family.VersionCount
            KeepCount             = $family.KeepCount
            ReviewCount           = $family.ReviewCount
            Deletions             = @($familyDeletions)
            Skipped               = @($skipped)
            RemainingAfterCleanup = $family.VersionCount - $familyDeletions.Count
        })
    }

    return [PSCustomObject]@{
        Families      = @($families)
        Deletions     = @($deletions)
        DeletionCount = $deletions.Count
        SkippedCount  = ($families | ForEach-Object { $_.Skipped.Count } | Measure-Object -Sum).Sum ?? 0
    }
}
