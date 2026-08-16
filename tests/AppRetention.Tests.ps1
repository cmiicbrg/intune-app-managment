#Requires -Version 7.4

# Tests for the pure retention evaluator in AppRetention.ps1.

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'AppRetention.ps1')

    $script:now = [datetime]::new(2026, 8, 16, 12, 0, 0, [DateTimeKind]::Utc)

    # Helper: an app created N weeks before $now
    function New-TestApp {
        param([string]$Id, [string]$Version, [double]$WeeksOld, [string]$Name = "App $Version")
        [PSCustomObject]@{
            Id              = $Id
            DisplayName     = $Name
            Version         = if ($Version) { [version]$Version } else { $null }
            CreatedDateTime = $script:now.AddDays(-7 * $WeeksOld)
        }
    }

    $script:defaultPolicy = @{ KeepNewest = 3; KeepNewerThanWeeks = 10 }
}

Describe 'Get-AppRetentionPlan' {
    It 'returns an empty result for an empty family' {
        @(Get-AppRetentionPlan -Apps @() -Policy $defaultPolicy -Now $now).Count | Should -Be 0
    }

    It 'keeps the newest N by rank and deletes older versions past the age cutoff' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '5.0' -WeeksOld 1),
            (New-TestApp -Id 'b' -Version '4.0' -WeeksOld 12),
            (New-TestApp -Id 'c' -Version '3.0' -WeeksOld 20),
            (New-TestApp -Id 'd' -Version '2.0' -WeeksOld 30),
            (New-TestApp -Id 'e' -Version '1.0' -WeeksOld 40)
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -Now $now

        ($plan | Where-Object Id -eq 'a').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'a').Reasons | Should -Contain 'newest version'
        ($plan | Where-Object Id -eq 'b').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'b').Reasons | Should -Contain 'within newest 3'
        ($plan | Where-Object Id -eq 'c').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'd').Action | Should -Be 'Delete'
        ($plan | Where-Object Id -eq 'e').Action | Should -Be 'Delete'
    }

    It 'keeps versions newer than the age cutoff even beyond the newest N' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '5.0' -WeeksOld 1),
            (New-TestApp -Id 'b' -Version '4.0' -WeeksOld 2),
            (New-TestApp -Id 'c' -Version '3.0' -WeeksOld 3),
            (New-TestApp -Id 'd' -Version '2.0' -WeeksOld 4),
            (New-TestApp -Id 'e' -Version '1.0' -WeeksOld 11)
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -Now $now

        ($plan | Where-Object Id -eq 'd').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'd').Reasons | Should -Contain 'newer than 10 weeks'
        ($plan | Where-Object Id -eq 'e').Action | Should -Be 'Delete'
    }

    It 'orders results newest first with distinct-version ranks' {
        $apps = @(
            (New-TestApp -Id 'old' -Version '1.0' -WeeksOld 30),
            (New-TestApp -Id 'new' -Version '2.0' -WeeksOld 1)
        )
        $plan = @(Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -Now $now)
        $plan[0].Id | Should -Be 'new'
        $plan[0].Rank | Should -Be 1
        $plan[1].Rank | Should -Be 2
    }

    It 'never deletes protected apps' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '5.0' -WeeksOld 1),
            (New-TestApp -Id 'b' -Version '4.0' -WeeksOld 20),
            (New-TestApp -Id 'c' -Version '3.0' -WeeksOld 20),
            (New-TestApp -Id 'dep' -Version '2.0' -WeeksOld 40)
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -ProtectedAppIds @('dep') -Now $now
        ($plan | Where-Object Id -eq 'dep').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'dep').Reasons | Should -Contain 'protected (dependency target)'
    }

    It 'marks duplicate versions Review, and duplicates do not consume a keep slot' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '3.0' -WeeksOld 20),
            (New-TestApp -Id 'a2' -Version '3.0' -WeeksOld 21),
            (New-TestApp -Id 'b' -Version '2.0' -WeeksOld 22),
            (New-TestApp -Id 'c' -Version '1.0' -WeeksOld 23),
            (New-TestApp -Id 'd' -Version '0.9' -WeeksOld 24)
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -Now $now

        ($plan | Where-Object Id -eq 'a').Action | Should -Be 'Review'
        ($plan | Where-Object Id -eq 'a2').Action | Should -Be 'Review'
        ($plan | Where-Object Id -eq 'a').Rank | Should -Be 1
        ($plan | Where-Object Id -eq 'a2').Rank | Should -Be 1
        # ranks 2 and 3 are still within the newest 3
        ($plan | Where-Object Id -eq 'b').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'c').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'd').Action | Should -Be 'Delete'
    }

    It 'keeps unparseable versions and gives them no rank' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '2.0' -WeeksOld 1),
            (New-TestApp -Id 'x' -Version '' -WeeksOld 50 -Name 'App Latest')
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -Now $now
        $x = $plan | Where-Object Id -eq 'x'
        $x.Action | Should -Be 'Keep'
        $x.Rank | Should -BeNullOrEmpty
        $x.Reasons[0] | Should -Match 'unparseable'
    }

    It 'lists unparseable versions after ranked ones, newest-created first, with all applicable reasons' {
        $apps = @(
            [PSCustomObject]@{ Id = 'u-nodate'; DisplayName = 'App Latest'; Version = $null; CreatedDateTime = $null },
            (New-TestApp -Id 'u-old' -Version '' -WeeksOld 40 -Name 'App Old'),
            (New-TestApp -Id 'a' -Version '2.0' -WeeksOld 1),
            (New-TestApp -Id 'u-new' -Version '' -WeeksOld 2 -Name 'App New')
        )
        $plan = @(Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -ProtectedAppIds @('u-old') -Now $now)
        $plan.Id | Should -Be @('a', 'u-new', 'u-old', 'u-nodate')
        ($plan | Where-Object Id -eq 'u-nodate').Reasons | Should -Contain 'unknown creation date'
        ($plan | Where-Object Id -eq 'u-old').Reasons | Should -Contain 'protected (dependency target)'
    }

    It 'keeps apps with an unknown creation date' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '5.0' -WeeksOld 1),
            (New-TestApp -Id 'b' -Version '4.0' -WeeksOld 1),
            (New-TestApp -Id 'c' -Version '3.0' -WeeksOld 1),
            [PSCustomObject]@{ Id = 'nodate'; DisplayName = 'App 1.0'; Version = [version]'1.0'; CreatedDateTime = $null }
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -Now $now
        ($plan | Where-Object Id -eq 'nodate').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'nodate').Reasons | Should -Contain 'unknown creation date'
    }

    It 'reports the age in weeks' {
        $plan = Get-AppRetentionPlan -Apps @((New-TestApp -Id 'a' -Version '1.0' -WeeksOld 4.5)) -Policy $defaultPolicy -Now $now
        $plan[0].AgeWeeks | Should -Be 4.5
    }

    It 'honors a stricter per-app policy' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '3.0' -WeeksOld 20),
            (New-TestApp -Id 'b' -Version '2.0' -WeeksOld 21),
            (New-TestApp -Id 'c' -Version '1.0' -WeeksOld 22)
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy @{ KeepNewest = 2; KeepNewerThanWeeks = 0 } -Now $now
        ($plan | Where-Object Id -eq 'b').Action | Should -Be 'Keep'
        ($plan | Where-Object Id -eq 'c').Action | Should -Be 'Delete'
    }
}

Describe 'Select-AppRetentionDeleteCandidates' {
    It 'returns only Delete actions, oldest version first' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '5.0' -WeeksOld 1),
            (New-TestApp -Id 'b' -Version '4.0' -WeeksOld 20),
            (New-TestApp -Id 'c' -Version '3.0' -WeeksOld 20),
            (New-TestApp -Id 'd' -Version '2.0' -WeeksOld 30),
            (New-TestApp -Id 'e' -Version '1.0' -WeeksOld 40)
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -Now $now
        $candidates = @(Select-AppRetentionDeleteCandidates -Plan $plan)
        $candidates.Id | Should -Be @('e', 'd')
    }

    It 'excludes Review items' {
        $apps = @(
            (New-TestApp -Id 'a' -Version '3.0' -WeeksOld 1),
            (New-TestApp -Id 'b' -Version '2.0' -WeeksOld 1),
            (New-TestApp -Id 'c' -Version '1.5' -WeeksOld 1),
            (New-TestApp -Id 'd' -Version '1.0' -WeeksOld 30),
            (New-TestApp -Id 'd2' -Version '1.0' -WeeksOld 31)
        )
        $plan = Get-AppRetentionPlan -Apps $apps -Policy $defaultPolicy -Now $now
        @(Select-AppRetentionDeleteCandidates -Plan $plan).Count | Should -Be 0
        @($plan | Where-Object Action -eq 'Review').Count | Should -Be 2
    }
}
