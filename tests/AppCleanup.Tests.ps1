#Requires -Version 7.4

# Tests for the pure cleanup planner in AppCleanup.ps1: which delete candidates of an inventory
# analysis are executed (in which order) and which are skipped, with reasons.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    foreach ($file in 'AppCleanup.ps1', 'AppInventory.ps1', 'SharedFunctions.ps1', 'AppConfig.ps1', 'IntuneInterop.ps1', 'AppRetention.ps1') {
        Copy-Item (Join-Path $repoRoot $file) $workDir
    }
    . (Join-Path $workDir 'AppCleanup.ps1')

    $script:now = [datetime]::new(2026, 8, 17, 12, 0, 0, [DateTimeKind]::Utc)
    $script:families = @(Get-AppFamilyCatalog)
    $script:policyResolver = { param($name) @{ KeepNewest = 3; KeepNewerThanWeeks = 10; Source = 'tenant'; OptIn = $true } }

    function New-GraphApp {
        param([string]$Id, [string]$Name, [string]$Version, [double]$WeeksOld)
        [PSCustomObject]@{
            id              = $Id
            displayName     = $Name
            displayVersion  = $Version
            publisher       = 'Test'
            createdDateTime = $script:now.AddDays(-7 * $WeeksOld).ToString('o')
            isAssigned      = $true
            publishingState = 'published'
            size            = 1000
            detectionRules  = @([PSCustomObject]@{ '@odata.type' = '#microsoft.graph.win32LobAppFileSystemDetection'; operator = 'greaterThanOrEqual' })
        }
    }
    function New-Assignment { [PSCustomObject]@{ Id = [guid]::NewGuid().ToString(); Intent = 'available'; Target = 'AllUsers'; GroupId = $null; AutoUpdateSuperseded = $true } }
    function New-Supersedes { param([string]$TargetId)
        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = $TargetId; targetDisplayName = 'x'; targetDisplayVersion = '1'; targetType = 'child'; supersedenceType = 'update' }
    }
    function New-SupersededBy { param([string]$TargetId, [string]$Name = 'x')
        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = $TargetId; targetDisplayName = $Name; targetDisplayVersion = '1'; targetType = 'parent'; supersedenceType = 'update' }
    }
    function New-DependencyOf { param([string]$TargetId)
        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = $TargetId; targetDisplayName = 'x'; targetDisplayVersion = '1'; targetType = 'parent'; dependencyType = 'autoInstall' }
    }
    function New-Record {
        param([string]$Id, [string]$Name, [string]$Version, [double]$WeeksOld, $Relationships = @(), $InstallSummary = $null)
        ConvertTo-AppInventoryRecord -App (New-GraphApp -Id $Id -Name $Name -Version $Version -WeeksOld $WeeksOld) -Assignments @((New-Assignment)) -Relationships $Relationships -InstallSummary $InstallSummary -Families $script:families
    }

    $script:records = [System.Collections.Generic.List[object]]::new()
    # Chrome (in plan): a 6-node chain. Keep-3 keeps 145/144/143; 142, 141 and 140 are old
    # enough to go - but 141's relationships could not be read.
    $script:records.Add((New-Record -Id 'c-0' -Name 'Google Chrome 140' -Version '140.0.1' -WeeksOld 50 -Relationships @((New-SupersededBy -TargetId 'c-1' -Name 'Google Chrome 141')) -InstallSummary ([PSCustomObject]@{ installedDeviceCount = 2 })))
    $script:records.Add((New-Record -Id 'c-1' -Name 'Google Chrome 141' -Version '141.0.1' -WeeksOld 40 -Relationships $null))
    $script:records.Add((New-Record -Id 'c-2' -Name 'Google Chrome 142' -Version '142.0.1' -WeeksOld 30 -Relationships @((New-Supersedes -TargetId 'c-1'), (New-SupersededBy -TargetId 'c-3' -Name 'Google Chrome 143'))))
    $script:records.Add((New-Record -Id 'c-3' -Name 'Google Chrome 143' -Version '143.0.1' -WeeksOld 20 -Relationships @((New-Supersedes -TargetId 'c-2'), (New-SupersededBy -TargetId 'c-4'))))
    $script:records.Add((New-Record -Id 'c-4' -Name 'Google Chrome 144' -Version '144.0.1' -WeeksOld 5 -Relationships @((New-Supersedes -TargetId 'c-3'), (New-SupersededBy -TargetId 'c-5'))))
    $script:records.Add((New-Record -Id 'c-5' -Name 'Google Chrome 145' -Version '145.0.1' -WeeksOld 1 -Relationships @((New-Supersedes -TargetId 'c-4'))))
    # Stellarium (NOT in plan): the oldest would be a delete candidate
    $script:records.Add((New-Record -Id 's-0' -Name 'Stellarium 24' -Version '24.1' -WeeksOld 60 -Relationships @((New-SupersededBy -TargetId 's-1'))))
    $script:records.Add((New-Record -Id 's-1' -Name 'Stellarium 25' -Version '25.1' -WeeksOld 40 -Relationships @((New-Supersedes -TargetId 's-0'), (New-SupersededBy -TargetId 's-2'))))
    $script:records.Add((New-Record -Id 's-2' -Name 'Stellarium 26' -Version '26.1' -WeeksOld 20 -Relationships @((New-Supersedes -TargetId 's-1'), (New-SupersededBy -TargetId 's-3'))))
    $script:records.Add((New-Record -Id 's-3' -Name 'Stellarium 26' -Version '26.2' -WeeksOld 1 -Relationships @((New-Supersedes -TargetId 's-2'))))
    # VCRedist (in plan): all old, the oldest is a dependency target of KeePassXC
    $script:records.Add((New-Record -Id 'v-0' -Name 'Visual C++ Redistributable 14' -Version '14.30.1' -WeeksOld 70 -Relationships @((New-DependencyOf -TargetId 'kpx-1'))))
    $script:records.Add((New-Record -Id 'v-1' -Name 'Visual C++ Redistributable 14' -Version '14.40.1' -WeeksOld 60))
    $script:records.Add((New-Record -Id 'v-2' -Name 'Visual C++ Redistributable 14' -Version '14.44.1' -WeeksOld 50))
    $script:records.Add((New-Record -Id 'v-3' -Name 'Visual C++ Redistributable 14' -Version '14.44.2' -WeeksOld 40))

    $script:analysis = Get-AppInventoryAnalysis -Records @($script:records) -Families $script:families -PolicyResolver $script:policyResolver -PlanAppNames @('Chrome', 'VCRedist', 'KeePassXC') -AppConfigs @{} -Now $script:now
    $script:plan = Get-AppCleanupPlan -Analysis $script:analysis -Records @($script:records)
}

Describe 'Get-AppCleanupPlan' {
    It 'deletes the delete candidates of in-plan families, oldest version first' {
        $script:plan.DeletionCount | Should -Be 2
        $script:plan.Deletions.Id | Should -Be @('c-0', 'c-2')
        $script:plan.Deletions[0].DisplayName | Should -Be 'Google Chrome 140'
        $script:plan.Deletions[0].Rank | Should -Be 6
        $script:plan.Deletions[0].InstalledDeviceCount | Should -Be 2
        $script:plan.Deletions[0].SupersededBy | Should -Be @('Google Chrome 141')
        $script:plan.Deletions[0].AssignmentCount | Should -Be 1
        ($script:plan.Deletions | Where-Object Id -eq 'c-2').InstalledDeviceCount | Should -BeNullOrEmpty
    }

    It 'never deletes an app whose relationships could not be read' {
        $script:plan.Deletions.Id | Should -Not -Contain 'c-1'
        ($script:records | Where-Object Id -eq 'c-1').Retention.Action | Should -Be 'Review'
    }

    It 'skips delete candidates of families outside the deployment plan, with the reason' {
        $stellarium = $script:plan.Families | Where-Object Family -eq 'Stellarium'
        $stellarium.InPlan | Should -BeFalse
        $stellarium.Deletions.Count | Should -Be 0
        $stellarium.Skipped.Count | Should -Be 1
        $stellarium.Skipped[0].Id | Should -Be 's-0'
        $stellarium.Skipped[0].Reason | Should -Match 'not in the tenant.s deployment plan'
        $script:plan.SkippedCount | Should -Be 1
    }

    It 'leaves protected dependency targets alone (they are not candidates to begin with)' {
        $vc = $script:plan.Families | Where-Object Family -eq 'VCRedist'
        $vc.Deletions.Count | Should -Be 0
        $vc.Skipped.Count | Should -Be 0
        ($script:records | Where-Object Id -eq 'v-0').Retention.Action | Should -Be 'Keep'
    }

    It 'reports per-family counts and the remaining version count' {
        $chrome = $script:plan.Families | Where-Object Family -eq 'Chrome'
        $chrome.VersionCount | Should -Be 6
        $chrome.KeepCount | Should -Be 3
        $chrome.ReviewCount | Should -Be 1
        $chrome.RemainingAfterCleanup | Should -Be 4
        $chrome.Policy.KeepNewest | Should -Be 3
        ($script:plan.Families | Where-Object Family -eq 'VCRedist').RemainingAfterCleanup | Should -Be 4
    }

    It 'is defensive: re-checks the invariants even if an upstream analysis hands it bad candidates' {
        # A hand-built analysis that (wrongly) nominates the newest version, a dependency target,
        # a version within the keep window and a non-Delete verdict
        $newest = New-Record -Id 'x-newest' -Name 'Google Chrome 150' -Version '150.0.1' -WeeksOld 1
        $dependency = New-Record -Id 'x-dep' -Name 'Google Chrome 148' -Version '148.0.1' -WeeksOld 50 -Relationships @((New-DependencyOf -TargetId 'other'))
        $kept = New-Record -Id 'x-kept' -Name 'Google Chrome 149' -Version '149.0.1' -WeeksOld 30
        $review = New-Record -Id 'x-review' -Name 'Google Chrome 147' -Version '147.0.1' -WeeksOld 60
        $ok = New-Record -Id 'x-ok' -Name 'Google Chrome 146' -Version '146.0.1' -WeeksOld 70
        $newest.Retention = @{ Rank = 1; Action = 'Delete' }
        $dependency.Retention = @{ Rank = 4; Action = 'Delete' }
        $kept.Retention = @{ Rank = 2; Action = 'Delete' }
        $review.Retention = @{ Rank = 5; Action = 'Review' }
        $ok.Retention = @{ Rank = 6; Action = 'Delete' }
        $candidate = { param($r) [ordered]@{ Id = $r.Id; DisplayName = $r.DisplayName; Version = $r.DisplayVersion; AgeWeeks = 1 } }
        $analysis = [PSCustomObject]@{
            Families = @([PSCustomObject]@{
                Family = 'Chrome'; InPlan = $true; Policy = [ordered]@{ KeepNewest = 3; KeepNewerThanWeeks = 10 }
                VersionCount = 5; KeepCount = 0; ReviewCount = 1; Newest = [ordered]@{ Id = 'x-newest' }
                DeleteCandidates = @((& $candidate $ok), (& $candidate $newest), (& $candidate $dependency), (& $candidate $kept), (& $candidate $review), [ordered]@{ Id = 'x-missing'; DisplayName = 'ghost'; Version = '1.0'; AgeWeeks = 1 })
            })
        }

        $plan = Get-AppCleanupPlan -Analysis $analysis -Records @($newest, $dependency, $kept, $review, $ok)
        $plan.Deletions.Id | Should -Be @('x-ok')
        $reasons = @{}
        foreach ($s in $plan.Families[0].Skipped) { $reasons[$s.Id] = $s.Reason }
        $reasons['x-newest'] | Should -Be 'newest version'
        $reasons['x-dep'] | Should -Be 'dependency target'
        $reasons['x-kept'] | Should -Match 'within the newest 3'
        $reasons['x-review'] | Should -Match "verdict is 'Review'"
        $reasons['x-missing'] | Should -Match 'no inventory record'
    }

    It 'reports the assignment count as unknown ($null) when the assignments could not be read' {
        $unknown = ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'u-1' -Name 'Google Chrome 130' -Version '130.0.1' -WeeksOld 80) -Assignments $null -Relationships @() -InstallSummary $null -Families $script:families
        $unknown.Retention = @{ Rank = 9; Action = 'Delete' }
        $analysis = [PSCustomObject]@{
            Families = @([PSCustomObject]@{
                Family = 'Chrome'; InPlan = $true; Policy = [ordered]@{ KeepNewest = 3; KeepNewerThanWeeks = 10 }
                VersionCount = 9; KeepCount = 3; ReviewCount = 0; Newest = [ordered]@{ Id = 'someone-else' }
                DeleteCandidates = @([ordered]@{ Id = 'u-1'; DisplayName = 'Google Chrome 130'; Version = '130.0.1'; AgeWeeks = 80 })
            })
        }
        $plan = Get-AppCleanupPlan -Analysis $analysis -Records @($unknown)
        $plan.Deletions.Count | Should -Be 1
        $plan.Deletions[0].AssignmentCount | Should -BeNullOrEmpty
    }

    It 'returns an empty plan for an analysis without families' {
        $plan = Get-AppCleanupPlan -Analysis ([PSCustomObject]@{ Families = @() }) -Records @()
        $plan.DeletionCount | Should -Be 0
        $plan.SkippedCount | Should -Be 0
        $plan.Families.Count | Should -Be 0
    }
}
