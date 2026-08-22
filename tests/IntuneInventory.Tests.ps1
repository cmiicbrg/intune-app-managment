#Requires -Version 7.4

# Tests for the shared Graph-facing read path in IntuneInventory.ps1. The interop wrappers are
# mocked; these tests pin how read failures and the optional install summary reach the records.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    foreach ($file in 'IntuneInventory.ps1', 'AppInventory.ps1', 'SharedFunctions.ps1', 'AppConfig.ps1', 'IntuneInterop.ps1', 'AppRetention.ps1') {
        Copy-Item (Join-Path $repoRoot $file) $workDir
    }
    . (Join-Path $workDir 'IntuneInventory.ps1')

    $script:families = @(Get-AppFamilyCatalog)
    function New-GraphApp {
        param([string]$Id, [string]$Name)
        [PSCustomObject]@{
            id = $Id; displayName = $Name; displayVersion = '1.0'; publisher = 'Test'
            createdDateTime = '2026-01-01T00:00:00Z'; isAssigned = $true; publishingState = 'published'; size = 1
            detectionRules = @()
        }
    }
}

Describe 'Read-IntuneAppInventory' {
    BeforeEach {
        Mock Get-InteropWin32App { @((New-GraphApp -Id 'a1' -Name 'Google Chrome 150'), (New-GraphApp -Id 'a2' -Name 'Some Other App')) }
        Mock Get-InteropAppAssignmentDetail { @([PSCustomObject]@{ Id = 'as-1'; Intent = 'available'; Target = 'AllUsers'; GroupId = $null; AutoUpdateSuperseded = $true }) }
        Mock Get-InteropAppRelationship { @() }
        Mock Get-InteropAppInstallSummaryReport { @{ 'a1' = [PSCustomObject]@{ installedDeviceCount = 9 } } }
    }

    It 'builds one record per app, classified against the catalog, with the install counts looked up by id' {
        $result = Read-IntuneAppInventory -Families $script:families -IncludeInstallSummary 6> $null
        $result.AppCount | Should -Be 2
        $result.IncludesInstallSummary | Should -BeTrue
        $result.Records.Count | Should -Be 2
        $chrome = $result.Records | Where-Object Id -eq 'a1'
        $chrome.Family | Should -Be 'Chrome'
        $chrome.Assignments.Count | Should -Be 1
        $chrome.InstallSummary.installedDeviceCount | Should -Be 9
        $other = $result.Records | Where-Object Id -eq 'a2'
        $other.Family | Should -BeNullOrEmpty
        $other.InstallSummary | Should -BeNullOrEmpty
        Should -Invoke Get-InteropAppInstallSummaryReport -Times 1 -Exactly -Because 'one tenant-wide report, not one request per app'
    }

    It 'records failed assignment and relationship reads as unavailable, never as empty sets' {
        Mock Get-InteropAppAssignmentDetail { param($AppId) if ($AppId -eq 'a1') { throw 'assignments down' }; @() }
        Mock Get-InteropAppRelationship { param($AppId) if ($AppId -eq 'a2') { throw 'relationships down' }; @() }
        $result = Read-IntuneAppInventory -Families $script:families 6> $null
        ($result.Records | Where-Object Id -eq 'a1').AssignmentsUnavailable | Should -BeTrue
        ($result.Records | Where-Object Id -eq 'a1').RelationshipsUnavailable | Should -BeFalse
        ($result.Records | Where-Object Id -eq 'a2').AssignmentsUnavailable | Should -BeFalse
        ($result.Records | Where-Object Id -eq 'a2').RelationshipsUnavailable | Should -BeTrue
    }

    It 'continues without install counts when the report fails' {
        Mock Get-InteropAppInstallSummaryReport { throw 'report down' }
        $result = Read-IntuneAppInventory -Families $script:families -IncludeInstallSummary 6> $null
        $result.IncludesInstallSummary | Should -BeFalse
        $result.Records.Count | Should -Be 2
        ($result.Records | Where-Object Id -eq 'a1').InstallSummary | Should -BeNullOrEmpty
    }

    It 'treats a successfully read but empty report as "included" with no counts' {
        Mock Get-InteropAppInstallSummaryReport { @{} }
        $result = Read-IntuneAppInventory -Families $script:families -IncludeInstallSummary 6> $null
        $result.IncludesInstallSummary | Should -BeTrue
        ($result.Records | Where-Object Id -eq 'a1').InstallSummary | Should -BeNullOrEmpty
    }

    It 'does not request the report without -IncludeInstallSummary' {
        $result = Read-IntuneAppInventory -Families $script:families 6> $null
        $result.IncludesInstallSummary | Should -BeFalse
        Should -Invoke Get-InteropAppInstallSummaryReport -Times 0 -Exactly
    }
}
