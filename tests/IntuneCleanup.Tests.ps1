#Requires -Version 7.4

# Tests for the shared cleanup executor in IntuneCleanup.ps1 (unlink + delete per version, with
# the caller's decision hook) and the audit log writer. The interop wrappers are mocked.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    foreach ($file in 'IntuneCleanup.ps1', 'AppCleanup.ps1', 'AppInventory.ps1', 'SharedFunctions.ps1', 'AppConfig.ps1', 'IntuneInterop.ps1', 'AppRetention.ps1') {
        Copy-Item (Join-Path $repoRoot $file) $workDir
    }
    '9.9.9' | Set-Content (Join-Path $workDir 'VERSION.txt')
    . (Join-Path $workDir 'IntuneCleanup.ps1')

    function New-Deletion { param([string]$Id, [string]$Name, [string]$Version, [int]$Rank = 5, [double]$AgeWeeks = 40, $AssignmentCount = 1)
        [PSCustomObject]@{ Id = $Id; Family = 'Chrome'; DisplayName = $Name; DisplayVersion = $Version; Version = $Version; Rank = $Rank; AgeWeeks = $AgeWeeks; CreatedDateTime = $null; AssignmentCount = $AssignmentCount; SupersededBy = @(); InstalledDeviceCount = 3 }
    }
    function New-Plan { param([array]$Deletions)
        [PSCustomObject]@{ Families = @(); Deletions = @($Deletions); DeletionCount = @($Deletions).Count; SkippedCount = 0 }
    }
    function New-Removal { param([int]$Total = 1, [int]$Removed = 1, [string[]]$DependencyTargets = @(), [string]$Error = $null)
        [PSCustomObject]@{ Total = $Total; Removed = $Removed; DependencyTargets = $DependencyTargets; Error = $Error }
    }
}

Describe 'Invoke-IntuneAppCleanup' {
    BeforeEach {
        Mock Remove-InteropAppRelationships { New-Removal }
        Mock Remove-InteropWin32App { }
    }

    It 'unlinks and deletes every version of the plan by default, in plan order' {
        $plan = New-Plan -Deletions @((New-Deletion -Id 'x1' -Name 'Google Chrome 140' -Version '140.0'), (New-Deletion -Id 'x2' -Name 'Google Chrome 141' -Version '141.0' -Rank 4))
        $results = @(Invoke-IntuneAppCleanup -Plan $plan 6> $null)
        $results.Count | Should -Be 2
        $results.Id | Should -Be @('x1', 'x2')
        $results.Outcome | Should -Be @('Deleted', 'Deleted')
        $results[0].Detail | Should -Be '1 relationship(s) removed first'
        Should -Invoke Remove-InteropAppRelationships -ParameterFilter { $AppId -eq 'x1' } -Times 1 -Exactly
        Should -Invoke Remove-InteropWin32App -ParameterFilter { $AppId -eq 'x2' } -Times 1 -Exactly
        Should -Invoke Remove-InteropWin32App -Times 2 -Exactly
    }

    It 'asks the decision hook with a descriptive label and records a declined version without touching Intune' {
        $plan = New-Plan -Deletions @((New-Deletion -Id 'x1' -Name 'Google Chrome 140' -Version '140.0' -AssignmentCount $null))
        # A reference type: the decision scriptblock runs in its own scope, so an array += would
        # only create a local copy
        $seen = [System.Collections.Generic.List[string]]::new()
        $results = @(Invoke-IntuneAppCleanup -Plan $plan -Decision { param($label) $seen.Add($label); $false } -DeclinedOutcome 'WouldDelete' 6> $null)
        $results[0].Outcome | Should -Be 'WouldDelete'
        $seen.Count | Should -Be 1
        $seen[0] | Should -Be 'Google Chrome 140 v140.0 [Chrome] - rank 5, 40 weeks old, assignments unknown'
        Should -Invoke Remove-InteropAppRelationships -Times 0 -Exactly
        Should -Invoke Remove-InteropWin32App -Times 0 -Exactly
    }

    It 'skips a version that became a dependency target, without deleting' {
        Mock Remove-InteropAppRelationships { New-Removal -Removed 0 -DependencyTargets @('KeePassXC 2') }
        $results = @(Invoke-IntuneAppCleanup -Plan (New-Plan -Deletions @((New-Deletion -Id 'x1' -Name 'Google Chrome 140' -Version '140.0'))) 6> $null)
        $results[0].Outcome | Should -Be 'Skipped'
        $results[0].Detail | Should -Match 'dependency target of: KeePassXC 2'
        Should -Invoke Remove-InteropWin32App -Times 0 -Exactly
    }

    It 'reports a partial unlink as Failed and does not delete' {
        Mock Remove-InteropAppRelationships { New-Removal -Total 2 -Removed 1 -Error 'Forbidden' }
        $results = @(Invoke-IntuneAppCleanup -Plan (New-Plan -Deletions @((New-Deletion -Id 'x1' -Name 'Google Chrome 140' -Version '140.0'))) 6> $null)
        $results[0].Outcome | Should -Be 'Failed'
        $results[0].Detail | Should -Match '1 of 2 relationship\(s\) were removed'
        $results[0].Detail | Should -Match 'partially unlinked'
        Should -Invoke Remove-InteropWin32App -Times 0 -Exactly
    }

    It 'reports a failed delete after a successful unlink as an unlinked app' {
        Mock Remove-InteropWin32App { throw 'BadRequest: nope' }
        $results = @(Invoke-IntuneAppCleanup -Plan (New-Plan -Deletions @((New-Deletion -Id 'x1' -Name 'Google Chrome 140' -Version '140.0'))) 6> $null)
        $results[0].Outcome | Should -Be 'Failed'
        $results[0].Detail | Should -Match 'nope'
        $results[0].Detail | Should -Match 'already removed'
    }

    It 'skips a version whose relationships cannot be re-read and continues with the next' {
        Mock Remove-InteropAppRelationships { param($AppId) if ($AppId -eq 'x1') { throw 'NotFound' }; New-Removal }
        $plan = New-Plan -Deletions @((New-Deletion -Id 'x1' -Name 'Google Chrome 140' -Version '140.0'), (New-Deletion -Id 'x2' -Name 'Google Chrome 141' -Version '141.0' -Rank 4))
        $results = @(Invoke-IntuneAppCleanup -Plan $plan 6> $null)
        $results[0].Outcome | Should -Be 'Skipped'
        $results[0].Detail | Should -Match 'could not re-read'
        $results[1].Outcome | Should -Be 'Deleted'
    }

    It 'returns an empty result for an empty plan' {
        @(Invoke-IntuneAppCleanup -Plan (New-Plan -Deletions @())).Count | Should -Be 0
    }
}

Describe 'Write-AppCleanupLog' {
    It 'writes one JSON log per run and never overwrites an earlier one' {
        $dir = Join-Path $TestDrive 'logs'
        $now = [datetime]::new(2026, 8, 22, 18, 0, 0, [DateTimeKind]::Utc)
        $policy = @{ KeepNewest = 3; KeepNewerThanWeeks = 10; Source = 'tenant'; OptIn = $true }
        $results = @([PSCustomObject]@{ Id = 'x1'; Family = 'Chrome'; DisplayName = 'Google Chrome 140'; DisplayVersion = '140.0'; Rank = 5; AgeWeeks = 40; Outcome = 'Deleted'; Detail = '1 relationship(s) removed first' })

        $first = Write-AppCleanupLog -Directory $dir -TenantName 'MZ' -Now $now -Mode 'Live' -Trigger 'Deploy' -AppName 'Chrome' -TenantPolicy $policy -PlanAppNames @('Chrome', 'Firefox') -Families @() -Results $results -ToolVersionPath (Join-Path $TestDrive 'repo\VERSION.txt')
        $second = Write-AppCleanupLog -Directory $dir -TenantName 'MZ' -Now $now -ToolVersionPath (Join-Path $TestDrive 'repo\VERSION.txt')

        (Split-Path $first -Leaf) | Should -Be 'MZ-cleanup-20260822-180000.json'
        (Split-Path $second -Leaf) | Should -Be 'MZ-cleanup-20260822-180000-2.json'
        $doc = Get-Content $first -Raw | ConvertFrom-Json
        $doc.Tenant | Should -Be 'MZ'
        $doc.Trigger | Should -Be 'Deploy'
        $doc.Mode | Should -Be 'Live'
        $doc.ToolVersion | Should -Be '9.9.9'
        $doc.TenantPolicy.KeepNewest | Should -Be 3
        $doc.PlanApps | Should -Be @('Chrome', 'Firefox')
        $doc.Results[0].Outcome | Should -Be 'Deleted'
        (Get-Content $second -Raw | ConvertFrom-Json).Trigger | Should -Be 'Cleanup'
    }
}
