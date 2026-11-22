#Requires -Version 7.4

# Tests for the McAfee removal package: the two client scripts in packages\mcafee-removal, the
# package builder (McAfeeRemovalPackage.ps1) and the app configuration that ties them together.
#
# The client scripts run on the devices under Windows PowerShell 5.1, while this suite runs in
# PowerShell 7 - so next to the unit tests (mocked, in-process) a few tests start the scripts in
# a real powershell.exe. Those only use the read-only paths and synthetic data: nothing here
# uninstalls, stops or deletes anything on the machine running the tests.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    $packageDir = Join-Path $workDir 'packages\mcafee-removal'
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    foreach ($file in 'SharedFunctions.ps1', 'AppConfig.ps1', 'IntuneInterop.ps1', 'McAfeeRemovalPackage.ps1') {
        Copy-Item (Join-Path $repoRoot $file) $workDir
    }
    foreach ($file in 'Remove-McAfee.ps1', 'Detect-McAfeeRemoval.ps1') {
        Copy-Item (Join-Path $repoRoot "packages\mcafee-removal\$file") $packageDir
    }
    $removeScript = Join-Path $packageDir 'Remove-McAfee.ps1'
    $detectScript = Join-Path $packageDir 'Detect-McAfeeRemoval.ps1'

    . (Join-Path $workDir 'SharedFunctions.ps1')
    . (Join-Path $workDir 'McAfeeRemovalPackage.ps1')
    . $removeScript   # dot-sourced: defines the functions (and those of the detection script), runs nothing

    $windowsPowerShell = (Get-Command 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source

    # Runs a script body in Windows PowerShell 5.1 and returns its exit code and output
    function Invoke-WindowsPowerShell {
        param([string]$Body)

        $file = Join-Path $TestDrive "ps51-$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content -LiteralPath $file -Value $Body -Encoding ascii
        $output = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $file 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | ForEach-Object { "$_" }) -join "`n") }
    }

    function New-TestUninstallEntry {
        param(
            [string]$KeyName = 'SomeKey',
            [string]$DisplayName = '',
            [string]$Publisher = '',
            [string]$UninstallString = '',
            [string]$QuietUninstallString = '',
            [string]$WindowsInstaller = ''
        )

        return [pscustomobject]@{
            KeyName = $KeyName; View = 'Registry64'; DisplayName = $DisplayName; Publisher = $Publisher; DisplayVersion = '1.0'
            UninstallString = $UninstallString; QuietUninstallString = $QuietUninstallString; WindowsInstaller = $WindowsInstaller
        }
    }

    # A footprint as Get-McAfeeFootprint returns it, reduced to what the callers decide on
    function New-TestFootprint {
        param(
            [string[]]$Active = @(),
            [string[]]$Unknown = @(),
            [string[]]$Residue = @()
        )

        return [pscustomobject]@{
            Products = @(); AppxPackages = @(); ProvisionedPackages = @(); Services = @(); PendingServices = @(); RegistryRoots = @(); Paths = @()
            Active = $Active; Residue = $Residue; Unknown = $Unknown
            IsPresent = ($Active.Count -gt 0); IsClean = ($Active.Count -eq 0 -and $Unknown.Count -eq 0)
        }
    }
}

Describe 'Client scripts on Windows PowerShell 5.1' {
    It '<_> parses without errors in Windows PowerShell 5.1' -ForEach 'Remove-McAfee.ps1', 'Detect-McAfeeRemoval.ps1' -Skip:(-not (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue)) {
        $path = Join-Path $packageDir $_
        $result = Invoke-WindowsPowerShell -Body @"
`$tokens = `$null; `$errors = `$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$path', [ref]`$tokens, [ref]`$errors)
`$errors | ForEach-Object { 'L' + `$_.Extent.StartLineNumber + ': ' + `$_.Message }
exit `$errors.Count
"@
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It '<_> is pure ASCII (5.1 reads a BOM-less file as ANSI)' -ForEach 'Remove-McAfee.ps1', 'Detect-McAfeeRemoval.ps1' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $packageDir $_))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'the detection rule as uploaded answers with one line and a matching exit code' -Skip:(-not (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue)) {
        # Exactly what Intune gets: the script with the version injected by Get-ScriptAppConfig
        $rule = (Get-ScriptAppConfig -AppName 'McAfeeRemoval' -Version '1.2.3' -SetupFile 'Remove-McAfee.ps1').DetectionRules
        $uploaded = Join-Path $TestDrive 'uploaded-detection.ps1'
        [System.IO.File]::WriteAllBytes($uploaded, [System.Convert]::FromBase64String($rule.scriptContent))

        $output = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $uploaded 2>&1
        $exitCode = $LASTEXITCODE
        # Whatever this machine has installed and whether this run is elevated (the Store
        # package inventories need elevation): text and exit code must be consistent
        if ($exitCode -eq 0) { "$output" | Should -Be 'No McAfee product is installed (removal package 1.2.3)' }
        else { $exitCode | Should -Be 1; "$output" | Should -Match '^(McAfee is present: |Cannot confirm that McAfee is gone: )' }
    }

    It 'the detection rule decides "<Name>" as exit code <ExitCode>' -Skip:(-not (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue)) -ForEach @(
        @{ Name = 'nothing installed, everything readable'; Appx = '@{ Packages = @(); Warning = $null }'; Provisioned = '@{ Packages = @(); Warning = $null }'
            ExitCode = 0; ExpectedOutput = '^No McAfee product is installed \(removal package 1\.2\.3\)$' }
        @{ Name = 'a package that is only provisioned for future users'; Appx = '@{ Packages = @(); Warning = $null }'; Provisioned = '@{ Packages = @([pscustomobject]@{ Name = "5A894077.McAfeeSecurity"; PackageName = "x" }); Warning = $null }'
            ExitCode = 1; ExpectedOutput = '^McAfee is present: provisioned Store package 5A894077\.McAfeeSecurity$' }
        @{ Name = 'installed Store packages unreadable'; Appx = '@{ Packages = @(); Warning = "Store packages could not be read: access denied" }'; Provisioned = '@{ Packages = @(); Warning = $null }'
            ExitCode = 1; ExpectedOutput = '^Cannot confirm that McAfee is gone: Store packages could not be read: access denied$' }
        @{ Name = 'provisioned Store packages unreadable'; Appx = '@{ Packages = @(); Warning = $null }'; Provisioned = '@{ Packages = @(); Warning = "Provisioned Store packages could not be read: DISM failed" }'
            ExitCode = 1; ExpectedOutput = '^Cannot confirm that McAfee is gone: Provisioned Store packages could not be read: DISM failed$' }
    ) {
        # The uploaded rule with its data sources replaced right before the verdict, so the
        # verdict itself runs unchanged in the real 5.1 host
        $rule = (Get-ScriptAppConfig -AppName 'McAfeeRemoval' -Version '1.2.3' -SetupFile 'Remove-McAfee.ps1').DetectionRules
        $ruleText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rule.scriptContent))
        $verdictLine = '$footprint = Get-McAfeeFootprint'
        $ruleText | Should -Match ([regex]::Escape($verdictLine))
        $stubs = @"
function Get-McAfeeUninstallEntry { }
function Get-ServiceRegistryRecord { }
function Get-McAfeeRegistryRoot { }
function Get-McAfeeResiduePath { }
function Get-McAfeeAppxPackage { $Appx }
function Get-McAfeeProvisionedPackage { $Provisioned }
"@
        $file = Join-Path $TestDrive "verdict-$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content -LiteralPath $file -Value $ruleText.Replace($verdictLine, "$stubs`n$verdictLine") -Encoding ascii

        # Not "$output": PowerShell variable names are case-insensitive, it would overwrite
        # a test-case value of the same name
        $actual = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $file 2>&1
        $LASTEXITCODE | Should -Be $ExitCode
        "$actual" | Should -Match $ExpectedOutput
    }

    It 'a detection script uploaded by hand (no injected version) fails fast instead of deciding' -Skip:(-not (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue)) {
        $output = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $detectScript 2>&1
        $LASTEXITCODE | Should -Be 1
        "$output" | Should -Match '^RequiredVersion was not injected'
    }

    It 'the removal script in -ReportOnly mode changes nothing and exits 0' -Skip:(-not (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue)) {
        $log = Join-Path $TestDrive 'report-only.log'
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $removeScript -ReportOnly -LogPath $log *> $null
        $LASTEXITCODE | Should -Be 0
        $text = Get-Content $log -Raw
        $text | Should -Match 'report only - nothing is changed'
        $text | Should -Not -Match '\[ERROR\]'
    }

    It 'footprint, uninstall plan and outcome work in the 5.1 host (synthetic device)' -Skip:(-not (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue)) {
        # The data sources are replaced after dot-sourcing, so everything downstream runs for
        # real in 5.1. (This is what catches 5.1-only failures such as @() around a List[object].)
        $result = Invoke-WindowsPowerShell -Body @"
`$ErrorActionPreference = 'Stop'
. '$removeScript'
function Write-RemovalLog { }
function New-Entry(`$key, `$name, `$uninstall) { [pscustomobject]@{ KeyName = `$key; View = 'Registry64'; DisplayName = `$name; Publisher = 'McAfee, LLC'; DisplayVersion = '1.0'; UninstallString = `$uninstall; QuietUninstallString = ''; WindowsInstaller = '' } }
function Get-McAfeeUninstallEntry {
    New-Entry 'WebAdvisor' 'McAfee WebAdvisor' 'C:\Program Files\McAfee\WebAdvisor\Uninstaller.exe'
    New-Entry 'McAfee.WPS' 'McAfee' '"C:\Program Files\McAfee\WPS\1.2.3\mc-update.exe" /uninstall'
}
function Get-McAfeeAppxPackage { @{ Packages = @([pscustomobject]@{ Name = '5A894077.McAfeeSecurity'; PackageFullName = '5A894077.McAfeeSecurity_2.1_x64__wafk5atnkzcwy' }); Warning = `$null } }
function Get-McAfeeProvisionedPackage { @{ Packages = @([pscustomobject]@{ Name = 'McAfeeWPSSparsePackage'; PackageName = 'McAfeeWPSSparsePackage_1.0_x64__0j6k21vdgrmfw' }); Warning = `$null } }
function Get-ServiceRegistryRecord {
    [pscustomobject]@{ Name = 'mfehidk'; ImagePath = '\SystemRoot\System32\drivers\mfehidk.sys'; Type = 1; DeleteFlag = `$null }
    [pscustomobject]@{ Name = 'mc-fw-host'; ImagePath = '"C:\Program Files\McAfee\WPS\1.2.3\mc-fw-host.exe"'; Type = 16; DeleteFlag = `$null }
    [pscustomobject]@{ Name = 'mfemms'; ImagePath = '"C:\Program Files\Common Files\McAfee\SystemCore\mfemms.exe"'; Type = 32; DeleteFlag = 1 }
    [pscustomobject]@{ Name = 'McpManagementService'; ImagePath = 'C:\WINDOWS\system32\svchost.exe -k McpManagementServiceGroup'; Type = 32; DeleteFlag = `$null }
}
function Get-McAfeeRegistryRoot { 'Registry64|SOFTWARE\McAfee' }
function Get-McAfeeResiduePath { 'C:\ProgramData\McAfee' }
function Get-McAfeeKnownUninstaller { }
`$footprint = Get-McAfeeFootprint
`$plan = Get-McAfeeUninstallPlan -Footprint `$footprint
`$outcome = Get-McAfeeRemovalOutcome -IsPresent `$footprint.IsPresent -RestartPending `$false -RestartRequests 0 -RestartOutstanding `$false
[pscustomobject]@{
    IsPresent  = `$footprint.IsPresent
    Active     = `$footprint.Active
    Residue    = `$footprint.Residue
    Commands   = @(`$plan.Commands | ForEach-Object { `$_.FilePath + ' ' + `$_.Arguments })
    EngineOnly = `$plan.EngineOnly
    ExitCode   = `$outcome.ExitCode
    Binary     = (Resolve-ServiceBinaryPath -ImagePath '\SystemRoot\System32\drivers\mfehidk.sys' -Name 'mfehidk' -IsDriver `$true)
} | ConvertTo-Json -Depth 4
"@
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $data = $result.Output | ConvertFrom-Json

        $data.IsPresent | Should -BeTrue
        $data.Active | Should -Contain "app 'McAfee WebAdvisor' 1.0"
        $data.Active | Should -Contain 'Store package 5A894077.McAfeeSecurity'
        $data.Active | Should -Contain 'provisioned Store package McAfeeWPSSparsePackage'
        $data.Active | Should -Contain 'driver mfehidk'
        $data.Active | Should -Contain 'service mc-fw-host'
        ($data.Active -join ' ') | Should -Not -Match 'McpManagementService|mfemms'
        $data.Residue | Should -Contain 'service mfemms (deleted at next restart)'
        @($data.Commands) | Should -Be @('C:\Program Files\McAfee\WebAdvisor\Uninstaller.exe /s')
        @($data.EngineOnly).Count | Should -Be 1
        $data.ExitCode | Should -Be 3010
        $data.Binary | Should -Be (Join-Path $env:WINDIR 'System32\drivers\mfehidk.sys')
    }
}

Describe 'What counts as McAfee' {
    It 'recognizes the uninstall entry <DisplayName> (<Publisher>): <Expected>' -ForEach @(
        @{ KeyName = 'MSC'; DisplayName = 'McAfee LiveSafe'; Publisher = 'McAfee, LLC'; Expected = $true }
        @{ KeyName = 'McAfee.WPS'; DisplayName = ''; Publisher = ''; Expected = $true }
        @{ KeyName = '{35ED3F83-4BDC-4c44-8EC6-6A8301C7413A}'; DisplayName = 'WebAdvisor by McAfee'; Publisher = ''; Expected = $true }
        @{ KeyName = 'x'; DisplayName = 'Safe Connect'; Publisher = 'McAfee, Inc.'; Expected = $true }
        @{ KeyName = 'x'; DisplayName = 'Intel Security True Key'; Publisher = 'Intel Security'; Expected = $true }
        @{ KeyName = 'x'; DisplayName = 'True Key Tools'; Publisher = 'Some Vendor'; Expected = $false }
        @{ KeyName = 'x'; DisplayName = 'Lenovo Vantage Service'; Publisher = 'Lenovo Group Ltd.'; Expected = $false }
        @{ KeyName = 'x'; DisplayName = 'Microsoft Defender'; Publisher = 'Microsoft Corporation'; Expected = $false }
    ) {
        Test-McAfeeUninstallEntry -Entry (New-TestUninstallEntry -KeyName $KeyName -DisplayName $DisplayName -Publisher $Publisher) | Should -Be $Expected
    }

    It 'recognizes the service <Name>: <Expected>' -ForEach @(
        @{ Name = 'mfemms'; ImagePath = '"C:\Program Files\Common Files\McAfee\SystemCore\mfemms.exe"'; Expected = $true }
        @{ Name = 'McAfee WebAdvisor'; ImagePath = '"C:\Program Files\McAfee\WebAdvisor\ServiceHost.exe" /McCoreSvc'; Expected = $true }
        @{ Name = 'mc-wps-update'; ImagePath = 'C:\Program Files\McAfee\WPS\1.2.3\mc-update.exe'; Expected = $true }
        @{ Name = 'mfehidk'; ImagePath = '\SystemRoot\System32\drivers\mfehidk.sys'; Expected = $true }
        @{ Name = 'mfeelamk'; ImagePath = ''; Expected = $true }
        @{ Name = 'cfwids'; ImagePath = 'system32\drivers\cfwids.sys'; Expected = $true }
        # Windows' own services whose names merely start like McAfee's
        @{ Name = 'McpManagementService'; ImagePath = 'C:\WINDOWS\system32\svchost.exe -k McpManagementServiceGroup'; Expected = $false }
        @{ Name = 'McmSvc'; ImagePath = 'C:\WINDOWS\system32\svchost.exe -k McmSvcGroup'; Expected = $false }
        @{ Name = 'mfe'; ImagePath = ''; Expected = $false }
        @{ Name = 'WinDefend'; ImagePath = '"C:\ProgramData\Microsoft\Windows Defender\Platform\MsMpEng.exe"'; Expected = $false }
    ) {
        Test-McAfeeServiceRecord -Record ([pscustomobject]@{ Name = $Name; ImagePath = $ImagePath }) | Should -Be $Expected
    }
}

Describe 'Get-McAfeeFootprint' {
    BeforeEach {
        Mock Get-McAfeeUninstallEntry { }
        Mock Get-McAfeeAppxPackage { @{ Packages = @(); Warning = $null } }
        Mock Get-McAfeeProvisionedPackage { @{ Packages = @(); Warning = $null } }
        Mock Get-ServiceRegistryRecord { }
        Mock Get-McAfeeRegistryRoot { }
        Mock Get-McAfeeResiduePath { }
    }

    It 'reports a clean device as not present and clean' {
        $footprint = Get-McAfeeFootprint
        $footprint.IsPresent | Should -BeFalse
        $footprint.IsClean | Should -BeTrue
        @($footprint.Active).Count | Should -Be 0
        @($footprint.Residue).Count | Should -Be 0
        @($footprint.Unknown).Count | Should -Be 0
    }

    It 'counts a package that is only provisioned for future users as present' {
        Mock Get-McAfeeProvisionedPackage { @{ Packages = @([pscustomobject]@{ Name = '5A894077.McAfeeSecurity'; PackageName = 'x' }); Warning = $null } }

        $footprint = Get-McAfeeFootprint
        $footprint.IsPresent | Should -BeTrue
        $footprint.Active | Should -Be @('provisioned Store package 5A894077.McAfeeSecurity')
    }

    It 'is not clean when the <Source> inventory could not be read, even though nothing was found' -ForEach @(
        @{ Source = 'installed Store package'; Function = 'Get-McAfeeAppxPackage'; Warning = 'Store packages could not be read: access denied' }
        @{ Source = 'provisioned Store package'; Function = 'Get-McAfeeProvisionedPackage'; Warning = 'Provisioned Store packages could not be read: DISM failed' }
    ) {
        $script:inventoryWarning = $Warning
        Mock $Function { @{ Packages = @(); Warning = $script:inventoryWarning } }

        $footprint = Get-McAfeeFootprint
        $footprint.IsPresent | Should -BeFalse -Because 'nothing was found'
        $footprint.IsClean | Should -BeFalse -Because 'a McAfee Store package could sit behind the failed read'
        $footprint.Unknown | Should -Be @($Warning)
    }

    It 'counts an installed product, a Store package, a service and a driver as present' {
        Mock Get-McAfeeUninstallEntry { New-TestUninstallEntry -DisplayName 'McAfee LiveSafe' -Publisher 'McAfee, LLC' }
        Mock Get-McAfeeAppxPackage { @{ Packages = @([pscustomobject]@{ Name = 'McAfeeWPSSparsePackage'; PackageFullName = 'x' }); Warning = $null } }
        Mock Get-ServiceRegistryRecord {
            [pscustomobject]@{ Name = 'mfevtp'; ImagePath = '"C:\Program Files\Common Files\McAfee\SystemCore\mfemms.exe"'; Type = 32; DeleteFlag = $null }
            [pscustomobject]@{ Name = 'mfesec'; ImagePath = 'system32\drivers\mfesec.sys'; Type = 1; DeleteFlag = $null }
        }

        $footprint = Get-McAfeeFootprint
        $footprint.IsPresent | Should -BeTrue
        $footprint.Active | Should -Be @("app 'McAfee LiveSafe' 1.0", 'Store package McAfeeWPSSparsePackage', 'service mfevtp', 'driver mfesec')
    }

    It 'treats folders, registry roots and services queued for deletion as leftovers, not as present' {
        Mock Get-ServiceRegistryRecord { [pscustomobject]@{ Name = 'mfehidk'; ImagePath = ''; Type = 1; DeleteFlag = 1 } }
        Mock Get-McAfeeRegistryRoot { 'Registry32|SOFTWARE\McAfee' }
        Mock Get-McAfeeResiduePath { 'C:\ProgramData\McAfee' }

        $footprint = Get-McAfeeFootprint
        $footprint.IsPresent | Should -BeFalse -Because 'an empty folder must not keep the app in a failed state until the restart'
        $footprint.IsClean | Should -BeTrue -Because 'leftovers are cleaned up, they do not block the verdict'
        $footprint.Residue | Should -Be @('service mfehidk (deleted at next restart)', 'registry SOFTWARE\McAfee [Registry32]', 'C:\ProgramData\McAfee')
        @($footprint.PendingServices).Count | Should -Be 1
    }

    It 'still reports what it found when an inventory could not be read' {
        Mock Get-McAfeeUninstallEntry { New-TestUninstallEntry -DisplayName 'McAfee LiveSafe' -Publisher 'McAfee, LLC' }
        Mock Get-McAfeeAppxPackage { @{ Packages = @(); Warning = 'Store packages could not be read: access denied' } }

        $footprint = Get-McAfeeFootprint
        $footprint.IsPresent | Should -BeTrue
        $footprint.Active | Should -Be @("app 'McAfee LiveSafe' 1.0")
        $footprint.Unknown | Should -Be @('Store packages could not be read: access denied')
    }
}

Describe 'Product uninstallers' {
    It 'prefers the silent command a product registered itself' {
        $entry = New-TestUninstallEntry -DisplayName 'McAfee Safe Connect' -UninstallString '"C:\ProgramData\Package Cache\{x}\Setup.exe" /uninstall' -QuietUninstallString '"C:\ProgramData\Package Cache\{x}\Setup.exe" /uninstall /quiet'
        $command = Get-McAfeeUninstallCommand -Entry $entry
        $command.FilePath | Should -Be (Join-Path $env:WINDIR 'System32\cmd.exe')
        $command.Arguments | Should -Be '/d /s /c ""C:\ProgramData\Package Cache\{x}\Setup.exe" /uninstall /quiet"'
    }

    It 'uninstalls Windows Installer products by product code' {
        $entry = New-TestUninstallEntry -KeyName '{12345678-ABCD-ABCD-ABCD-1234567890AB}' -DisplayName 'McAfee Something' -UninstallString 'MsiExec.exe /I{12345678-ABCD-ABCD-ABCD-1234567890AB}' -WindowsInstaller '1'
        $command = Get-McAfeeUninstallCommand -Entry $entry
        $command.FilePath | Should -Be (Join-Path $env:WINDIR 'System32\msiexec.exe')
        $command.Arguments | Should -Be '/x {12345678-ABCD-ABCD-ABCD-1234567890AB} /qn /norestart'
    }

    It 'knows the silent switch of <DisplayName>' -ForEach @(
        @{ DisplayName = 'McAfee WebAdvisor'; UninstallString = 'C:\Program Files\McAfee\WebAdvisor\Uninstaller.exe'; File = 'C:\Program Files\McAfee\WebAdvisor\Uninstaller.exe'; Arguments = '/s' }
        @{ DisplayName = 'McAfee SiteAdvisor'; UninstallString = '"C:\Program Files (x86)\McAfee\SiteAdvisor\Uninstall.exe"'; File = 'C:\Program Files (x86)\McAfee\SiteAdvisor\Uninstall.exe'; Arguments = '/s' }
        @{ DisplayName = 'McAfee Security Scan Plus'; UninstallString = '"C:\Program Files (x86)\McAfee Security Scan\uninstall.exe"'; File = 'C:\Program Files (x86)\McAfee Security Scan\uninstall.exe'; Arguments = '/s /inner' }
    ) {
        $command = Get-McAfeeUninstallCommand -Entry (New-TestUninstallEntry -DisplayName $DisplayName -UninstallString $UninstallString)
        $command.FilePath | Should -Be $File
        $command.Arguments | Should -Be $Arguments
    }

    It 'leaves <DisplayName> to the removal engine (interactive uninstaller only)' -ForEach @(
        @{ KeyName = 'MSC'; DisplayName = 'McAfee LiveSafe'; UninstallString = '"C:\Program Files\McAfee\MSC\mcuihost.exe" /body:misp://MSCJsRes.dll::uninstall.html /id:uninstall' }
        @{ KeyName = 'McAfee.WPS'; DisplayName = 'McAfee'; UninstallString = '"C:\Program Files\McAfee\WPS\1.2.3\mc-update.exe" /uninstall' }
    ) {
        Get-McAfeeUninstallCommand -Entry (New-TestUninstallEntry -KeyName $KeyName -DisplayName $DisplayName -UninstallString $UninstallString) | Should -BeNullOrEmpty
    }

    It 'plans each uninstaller once and lists what is left to the engine' {
        Mock Get-McAfeeKnownUninstaller {
            [pscustomobject]@{ Name = 'McAfee WebAdvisor'; FilePath = 'C:\Program Files\McAfee\WebAdvisor\Uninstaller.exe'; Arguments = '/s' }
        }
        $footprint = [pscustomobject]@{ Products = @(
                (New-TestUninstallEntry -DisplayName 'McAfee WebAdvisor' -UninstallString 'C:\Program Files\McAfee\WebAdvisor\uninstaller.exe')
                (New-TestUninstallEntry -KeyName 'MSC' -DisplayName 'McAfee LiveSafe' -UninstallString '"C:\Program Files\McAfee\MSC\mcuihost.exe" /id:uninstall')
            ) }

        $plan = Get-McAfeeUninstallPlan -Footprint $footprint
        @($plan.Commands).Count | Should -Be 1 -Because 'the registry entry and the file on disk are the same uninstaller'
        @($plan.EngineOnly).Count | Should -Be 1
        $plan.EngineOnly[0] | Should -Match "^'McAfee LiveSafe'"
    }
}

Describe 'Resolve-ServiceBinaryPath' {
    It 'resolves <ImagePath>' -ForEach @(
        @{ ImagePath = '\SystemRoot\System32\drivers\mfehidk.sys'; Name = 'mfehidk'; IsDriver = $true; Expected = (Join-Path $env:WINDIR 'System32\drivers\mfehidk.sys') }
        @{ ImagePath = 'system32\DRIVERS\mfesec.sys'; Name = 'mfesec'; IsDriver = $true; Expected = (Join-Path $env:WINDIR 'system32\DRIVERS\mfesec.sys') }
        @{ ImagePath = '\??\C:\Program Files\McAfee\x\driver.sys'; Name = 'x'; IsDriver = $true; Expected = 'C:\Program Files\McAfee\x\driver.sys' }
        @{ ImagePath = '"C:\Program Files\McAfee\WebAdvisor\ServiceHost.exe" /McCoreSvc'; Name = 'x'; IsDriver = $false; Expected = 'C:\Program Files\McAfee\WebAdvisor\ServiceHost.exe' }
        @{ ImagePath = 'C:\Program Files\McAfee\WPS\1.2\mc-update.exe /service'; Name = 'x'; IsDriver = $false; Expected = 'C:\Program Files\McAfee\WPS\1.2\mc-update.exe' }
        @{ ImagePath = ''; Name = 'mfeelamk'; IsDriver = $true; Expected = (Join-Path $env:WINDIR 'System32\drivers\mfeelamk.sys') }
    ) {
        Resolve-ServiceBinaryPath -ImagePath $ImagePath -Name $Name -IsDriver $IsDriver | Should -Be $Expected
    }

    It 'cannot tell for a service registered without a path' {
        Resolve-ServiceBinaryPath -ImagePath '' -Name 'x' -IsDriver $false | Should -BeNullOrEmpty
    }
}

Describe 'Get-McAfeeRemovalOutcome' {
    It 'exits 0 and clears the bookkeeping when McAfee is gone' {
        $outcome = Get-McAfeeRemovalOutcome -IsPresent $false -RestartPending $false -RestartRequests 1 -RestartOutstanding $true
        $outcome.ExitCode | Should -Be 0
        $outcome.ClearState | Should -BeTrue
    }

    It 'asks for a restart (3010) when McAfee is still installed, and counts it' {
        $outcome = Get-McAfeeRemovalOutcome -IsPresent $true -RestartPending $false -RestartRequests 0 -RestartOutstanding $false
        $outcome.ExitCode | Should -Be 3010
        $outcome.RestartRequests | Should -Be 1
    }

    It 'asks for a restart when only queued deletions are left' {
        (Get-McAfeeRemovalOutcome -IsPresent $false -RestartPending $true -RestartRequests 0 -RestartOutstanding $false).ExitCode | Should -Be 3010
    }

    It 'does not count again while the restart it asked for has not happened' {
        $outcome = Get-McAfeeRemovalOutcome -IsPresent $true -RestartPending $false -RestartRequests 2 -RestartOutstanding $true
        $outcome.ExitCode | Should -Be 3010
        $outcome.RestartRequests | Should -Be 2
    }

    It 'gives up with exit code 1 when McAfee survived the allowed restarts' {
        $outcome = Get-McAfeeRemovalOutcome -IsPresent $true -RestartPending $true -RestartRequests 2 -RestartOutstanding $false -MaxRestartRequests 2
        $outcome.ExitCode | Should -Be 1
        $outcome.ClearState | Should -BeFalse
    }

    It 'stops asking for restarts once McAfee is uninstalled, even if deletions stay queued' {
        $outcome = Get-McAfeeRemovalOutcome -IsPresent $false -RestartPending $true -RestartRequests 2 -RestartOutstanding $false -MaxRestartRequests 2
        $outcome.ExitCode | Should -Be 0
    }

    It 'fails without asking for a restart when nothing was found but an inventory was unreadable' {
        $outcome = Get-McAfeeRemovalOutcome -IsPresent $false -RestartPending $true -InventoryIncomplete $true -RestartRequests 1 -RestartOutstanding $false
        $outcome.ExitCode | Should -Be 1 -Because 'success is unproven and a restart would not prove it'
        $outcome.ClearState | Should -BeFalse
        $outcome.RestartRequests | Should -Be 1
    }

    It 'treats found McAfee as usual when an inventory was unreadable on top' {
        (Get-McAfeeRemovalOutcome -IsPresent $true -RestartPending $false -InventoryIncomplete $true -RestartRequests 0 -RestartOutstanding $false).ExitCode | Should -Be 3010
    }
}

Describe 'Invoke-McAfeeRemoval' {
    BeforeEach {
        Mock Write-RemovalLog { }
        Mock Get-CimInstance { [pscustomobject]@{ Manufacturer = 'LENOVO'; Model = 'Test' } }
        Mock Get-RegisteredAntivirus { }
        Mock Get-McAfeeEnterpriseMarker { }
        Mock Get-McAfeeKnownUninstaller { }
        Mock Invoke-McAfeeProductUninstaller { }
        Mock Stop-McAfeeService { }
        Mock Remove-McAfeeScheduledTask { }
        Mock Invoke-McAfeeEngine { [pscustomobject]@{ Available = $true; Passes = 1; LastExitCode = 0 } }
        Mock Copy-McAfeeEngineLog { }
        Mock Remove-McAfeeAppx { }
        Mock Remove-McAfeeResidue { }
        Mock Test-McAfeeRestartPending { $false }
        Mock Get-McAfeeRemovalState { [pscustomobject]@{ RestartRequests = 0; RestartOutstanding = $false } }
        Mock Set-McAfeeRemovalState { }

        # The device as the footprint sees it; the last removal step switches it to its end state
        $script:deviceNow = New-TestFootprint
        $script:deviceAfterRemoval = New-TestFootprint
        Mock Get-McAfeeFootprint { $script:deviceNow }
        Mock Remove-McAfeeOrphanService { $script:deviceNow = $script:deviceAfterRemoval }
    }

    It 'does nothing on a clean device and reports success' {
        @(Invoke-McAfeeRemoval)[-1] | Should -Be 0
        Should -Invoke Invoke-McAfeeEngine -Times 0 -Exactly
        Should -Invoke Remove-McAfeeAppx -Times 0 -Exactly
        Should -Invoke Set-McAfeeRemovalState -Times 1 -Exactly -ParameterFilter { $Clear }
    }

    It 'runs every step when McAfee is installed and reports success once it is gone' {
        $script:deviceNow = New-TestFootprint -Active "app 'McAfee LiveSafe' 16.0"

        @(Invoke-McAfeeRemoval)[-1] | Should -Be 0
        Should -Invoke Invoke-McAfeeProductUninstaller -Times 1 -Exactly
        Should -Invoke Stop-McAfeeService -Times 1 -Exactly
        Should -Invoke Invoke-McAfeeEngine -Times 1 -Exactly
        Should -Invoke Remove-McAfeeAppx -Times 1 -Exactly
        Should -Invoke Remove-McAfeeOrphanService -Times 1 -Exactly
    }

    It 'asks for a restart and counts it when McAfee is still installed afterwards' {
        $script:deviceNow = New-TestFootprint -Active 'service mc-fw-host'
        $script:deviceAfterRemoval = New-TestFootprint -Active 'service mc-fw-host'

        @(Invoke-McAfeeRemoval)[-1] | Should -Be 3010
        Should -Invoke Set-McAfeeRemovalState -Times 1 -Exactly -ParameterFilter { $RestartRequests -eq 1 -and -not $Clear }
    }

    It 'only tries the Store packages when nothing was found but their inventory was unreadable - and does not report success' {
        $script:deviceNow = New-TestFootprint -Unknown 'Store packages could not be read: access denied'

        @(Invoke-McAfeeRemoval)[-1] | Should -Be 1
        Should -Invoke Remove-McAfeeAppx -Times 1 -Exactly
        Should -Invoke Invoke-McAfeeEngine -Times 0 -Exactly -Because 'there is no known product for the engine to remove'
        Should -Invoke Invoke-McAfeeProductUninstaller -Times 0 -Exactly
        Should -Invoke Set-McAfeeRemovalState -Times 0 -Exactly -Because 'an unreadable inventory is no reason to ask for a restart'
    }

    It 'reports success when the inventory is readable again after the Store package step' {
        $script:deviceNow = New-TestFootprint -Unknown 'Provisioned Store packages could not be read: DISM failed'
        Mock Remove-McAfeeAppx { $script:deviceNow = New-TestFootprint }

        @(Invoke-McAfeeRemoval)[-1] | Should -Be 0
    }

    It 'changes nothing next to a managed McAfee business product' {
        $script:deviceNow = New-TestFootprint -Active "app 'McAfee Agent' 5.7"
        Mock Get-McAfeeEnterpriseMarker { 'HKLM\SOFTWARE\Network Associates\ePolicy Orchestrator\Application Plugins\EPOAGENT3000 [Registry32]' }

        @(Invoke-McAfeeRemoval)[-1] | Should -Be 1
        Should -Invoke Invoke-McAfeeEngine -Times 0 -Exactly
        Should -Invoke Invoke-McAfeeProductUninstaller -Times 0 -Exactly
        Should -Invoke Remove-McAfeeAppx -Times 0 -Exactly
    }

    It 'changes nothing in report-only mode' {
        $script:deviceNow = New-TestFootprint -Active "app 'McAfee LiveSafe' 16.0"

        @(Invoke-McAfeeRemoval -ReportOnly)[-1] | Should -Be 0
        Should -Invoke Invoke-McAfeeEngine -Times 0 -Exactly
        Should -Invoke Invoke-McAfeeProductUninstaller -Times 0 -Exactly
        Should -Invoke Remove-McAfeeAppx -Times 0 -Exactly
        Should -Invoke Set-McAfeeRemovalState -Times 0 -Exactly
    }
}

Describe 'Leftover cleanup stays inside the McAfee locations' {
    BeforeEach {
        Mock Write-RemovalLog { }
        Mock Remove-Item { }
    }

    It 'only offers rooted paths whose last part is a McAfee name' {
        $candidates = @(Get-McAfeeResiduePathCandidate)
        $candidates.Count | Should -BeGreaterThan 5
        foreach ($candidate in $candidates) {
            [System.IO.Path]::IsPathRooted($candidate) | Should -BeTrue
            (Split-Path $candidate -Leaf) | Should -Match '^McAfee'
            ($candidate -split '\\').Count | Should -BeGreaterThan 2 -Because "$candidate must not sit directly in a drive root"
        }
    }

    It 'skips a root whose environment variable is not set instead of building a relative path' {
        $saved = $env:ProgramW6432
        try {
            $env:ProgramW6432 = $null
            foreach ($candidate in @(Get-McAfeeResiduePathCandidate)) {
                [System.IO.Path]::IsPathRooted($candidate) | Should -BeTrue
            }
        }
        finally {
            $env:ProgramW6432 = $saved
        }
    }

    It 'deletes a known McAfee folder' {
        $path = Join-Path $env:ProgramData 'McAfee'
        Remove-McAfeeResidue -Footprint ([pscustomobject]@{ Paths = @($path); RegistryRoots = @() })
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $path }
    }

    It 'refuses a path that is not one of the known McAfee locations' {
        Remove-McAfeeResidue -Footprint ([pscustomobject]@{ Paths = @($env:WINDIR, 'C:\Program Files'); RegistryRoots = @() })
        Should -Invoke Remove-Item -Times 0 -Exactly
    }
}

Describe 'Invoke-McAfeeEngine' {
    BeforeAll {
        $engineDir = Join-Path $TestDrive 'engine'
        New-Item -ItemType Directory -Path $engineDir -Force | Out-Null
        Set-Content -Path (Join-Path $engineDir 'mccleanup.exe') -Value 'not a real engine'
    }

    BeforeEach {
        Mock Write-RemovalLog { }
        Mock Start-Sleep { }
    }

    It 'reports a package without engine instead of throwing' {
        $result = Invoke-McAfeeEngine -EngineDirectory (Join-Path $TestDrive 'no-such-folder')
        $result.Available | Should -BeFalse
        $result.Passes | Should -Be 0
    }

    It 'starts the engine in its own folder with the product list, verbose and silent' {
        Mock Invoke-RemovalProcess { [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Seconds = 120 } }
        $result = Invoke-McAfeeEngine -EngineDirectory $engineDir
        $result.Passes | Should -Be 1 -Because 'a clean pass ends the loop'
        Should -Invoke Invoke-RemovalProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path $engineDir 'mccleanup.exe') -and $WorkingDirectory -eq $engineDir -and
            $Arguments -match '^-p StopServices,.*,WPS,.*,RESIDUE -v -s$' -and $Arguments -notmatch 'WMIRemover'
        }
    }

    It 'runs further passes while the engine reports work left' {
        Mock Invoke-RemovalProcess { [pscustomobject]@{ ExitCode = 2; TimedOut = $false; Seconds = 180 } }
        $result = Invoke-McAfeeEngine -EngineDirectory $engineDir -MaxPasses 3
        $result.Passes | Should -Be 3
        $result.LastExitCode | Should -Be 2
    }

    It 'does not repeat an engine that ended within seconds (refused to run)' {
        Mock Invoke-RemovalProcess { [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Seconds = 2 } }
        (Invoke-McAfeeEngine -EngineDirectory $engineDir -MaxPasses 3).Passes | Should -Be 1
    }

    It 'starts no pass that could run into the 60-minute limit of the Intune agent' {
        Mock Invoke-RemovalProcess { [pscustomobject]@{ ExitCode = 2; TimedOut = $false; Seconds = 180 } }
        Mock Get-RemovalSecondsLeft { 300 }
        (Invoke-McAfeeEngine -EngineDirectory $engineDir -MaxPasses 3).Passes | Should -Be 0
        Should -Invoke Invoke-RemovalProcess -Times 0 -Exactly
    }
}

Describe 'Services' {
    BeforeEach {
        Mock Write-RemovalLog { }
        Mock Start-Sleep { }
        Mock Remove-ServiceRegistration { }
    }

    It 'stops and disables services but leaves the kernel drivers alone' {
        Mock Invoke-ServiceControl { 0 }
        Stop-McAfeeService -Footprint ([pscustomobject]@{ Services = @(
                    [pscustomobject]@{ Name = 'McAfee WebAdvisor'; ImagePath = 'x'; IsDriver = $false }
                    [pscustomobject]@{ Name = 'mfehidk'; ImagePath = 'x'; IsDriver = $true }
                ) })

        Should -Invoke Invoke-ServiceControl -Times 1 -Exactly -ParameterFilter { ($Arguments -join '|') -eq 'stop|McAfee WebAdvisor' }
        Should -Invoke Invoke-ServiceControl -Times 1 -Exactly -ParameterFilter { ($Arguments -join '|') -eq 'config|McAfee WebAdvisor|start=|disabled' }
        Should -Invoke Invoke-ServiceControl -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'mfehidk' }
    }

    Context 'Remove-McAfeeOrphanService' {
        BeforeAll {
            $existingBinary = Join-Path $TestDrive 'still-there.exe'
            Set-Content -Path $existingBinary -Value 'x'
            $goneBinary = Join-Path $TestDrive 'gone.exe'
        }

        It 'never unregisters a service whose program still exists' {
            Mock Invoke-ServiceControl { 0 }
            Remove-McAfeeOrphanService -Footprint ([pscustomobject]@{ Services = @([pscustomobject]@{ Name = 'mfemms'; ImagePath = "`"$existingBinary`" /svc"; IsDriver = $false }) })
            Should -Invoke Invoke-ServiceControl -Times 0 -Exactly
            Should -Invoke Remove-ServiceRegistration -Times 0 -Exactly
        }

        It 'unregisters a service whose program is gone' {
            Mock Invoke-ServiceControl { 0 }
            Remove-McAfeeOrphanService -Footprint ([pscustomobject]@{ Services = @([pscustomobject]@{ Name = 'mc-wps-update'; ImagePath = $goneBinary; IsDriver = $false }) })
            Should -Invoke Invoke-ServiceControl -Times 1 -Exactly -ParameterFilter { ($Arguments -join '|') -eq 'delete|mc-wps-update' }
            Should -Invoke Remove-ServiceRegistration -Times 0 -Exactly
        }

        It 'removes the registry entry when the service control manager refuses (protected service)' {
            Mock Invoke-ServiceControl { 5 }
            Remove-McAfeeOrphanService -Footprint ([pscustomobject]@{ Services = @([pscustomobject]@{ Name = 'mc-fw-host'; ImagePath = $goneBinary; IsDriver = $false }) })
            Should -Invoke Remove-ServiceRegistration -Times 1 -Exactly -ParameterFilter { $Name -eq 'mc-fw-host' }
        }

        It 'leaves a service alone when its program cannot be told' {
            Mock Invoke-ServiceControl { 0 }
            Remove-McAfeeOrphanService -Footprint ([pscustomobject]@{ Services = @([pscustomobject]@{ Name = 'odd'; ImagePath = ''; IsDriver = $false }) })
            Should -Invoke Invoke-ServiceControl -Times 0 -Exactly
        }
    }
}

Describe 'Intune app configuration (McAfeeRemoval)' {
    BeforeAll {
        $config = Get-ScriptAppConfig -AppName 'McAfeeRemoval' -Version '1.2.3' -SetupFile 'Remove-McAfee.ps1'
        $uploadedScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($config.DetectionRules.scriptContent))
    }

    It 'names the app after the family convention and carries the package version' {
        $config.DisplayName | Should -Be 'McAfee Removal 1'
        $config.AppVersion | Should -Be '1.2.3'
        (Resolve-AppFamily -DisplayName $config.DisplayName -Families (Get-AppFamilyCatalog)).AppConfigName | Should -Be 'McAfeeRemoval'
    }

    It 'runs the removal script as install command and has nothing to uninstall' {
        $config.InstallCommandLine | Should -Be 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Remove-McAfee.ps1"'
        $config.UninstallCommandLine | Should -Be 'cmd.exe /c exit 0'
    }

    It 'lets Intune act on the restart code, unlike every other app' {
        $config.RestartBehavior | Should -Be 'basedOnReturnCode'
        (Get-FileAppConfig -AppName 'Firefox' -Version '143.0.1' -SetupFile 'Firefox-Setup-143.0.1-de.exe').RestartBehavior | Should -Be 'suppress'
    }

    It 'uploads the detection script as 64-bit script rule with the version injected' {
        $config.DetectionRules.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppPowerShellScriptDetection'
        $config.DetectionRules.runAs32Bit | Should -BeFalse
        $uploadedScript | Should -Match ([regex]::Escape("`$RequiredVersion = '1.2.3'"))
        $uploadedScript | Should -Not -Match 'param\(\s*\[string\]\$RequiredVersion'
    }

    It 'the uploaded detection script still parses' {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($uploadedScript, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'is part of the deployable catalog' {
        (Get-AppFamilyCatalog | Where-Object AppConfigName -eq 'McAfeeRemoval').Pattern | Should -Be 'McAfeeRemoval-*.intunewin'
    }
}

Describe 'AppConfig policy for assembled packages' {
    BeforeAll {
        $valid = Get-AppConfiguration -AppName 'McAfeeRemoval'
    }

    It 'accepts the shipped configuration' {
        @(Get-AppConfigAppViolation -Name 'McAfeeRemoval' -Configuration $valid).Count | Should -Be 0
    }

    It 'rejects an ingredient without a usable <_> pin' -ForEach 'McprSha256', 'McprEngineSha256' {
        $broken = $valid.Clone()
        $broken[$_] = 'ABC123'
        @(Get-AppConfigAppViolation -Name 'McAfeeRemoval' -Configuration $broken) -join ' ' | Should -Match "$_ must be a 64-character SHA-256"
    }

    It 'rejects ingredients without a named publisher' {
        $broken = $valid.Clone()
        $broken.ExpectedPublisher = ''
        @(Get-AppConfigAppViolation -Name 'McAfeeRemoval' -Configuration $broken) -join ' ' | Should -Match 'ExpectedPublisher is required'
    }

    It 'rejects an ingredient URL that is not HTTPS' {
        $broken = $valid.Clone()
        $broken.McprEngineArchiveUrls = @('https://example.test/a.zip', 'http://example.test/b.zip')
        @(Get-AppConfigAppViolation -Name 'McAfeeRemoval' -Configuration $broken) -join ' ' | Should -Match "must be an https:// URL \(found 'http://example.test/b.zip'\)"
    }

    It 'rejects an unknown RestartBehavior on any app' {
        @(Get-AppConfigAppViolation -Name 'X' -Configuration @{ RestartBehavior = 'basedOnReturnCodes' }) -join ' ' | Should -Match 'RestartBehavior must be'
    }
}

Describe 'Package builder' {
    Context 'Get-McAfeeRemovalPackageVersion' {
        It 'reads the version the removal script declares' {
            $version = Get-McAfeeRemovalPackageVersion -ScriptPath $removeScript
            $version | Should -Match '^\d+\.\d+\.\d+$'
            { [version]$version } | Should -Not -Throw
        }

        It 'returns nothing for a script without a version' {
            $other = Join-Path $TestDrive 'no-version.ps1'
            Set-Content -Path $other -Value '# $script:McAfeeRemovalVersion is only mentioned here'
            Get-McAfeeRemovalPackageVersion -ScriptPath $other | Should -BeNullOrEmpty
        }
    }

    Context 'Save-ZipEntryMatchingHash' {
        BeforeAll {
            $zipSource = Join-Path $TestDrive 'zip-source'
            New-Item -ItemType Directory -Path (Join-Path $zipSource 'MCPR\OldCert') -Force | Out-Null
            Set-Content -Path (Join-Path $zipSource 'MCPR\mccleanup.exe') -Value 'wanted engine' -NoNewline
            Set-Content -Path (Join-Path $zipSource 'MCPR\OldCert\mccleanup.exe') -Value 'other engine' -NoNewline
            $zipPath = Join-Path $TestDrive 'archive.zip'
            [System.IO.Compression.ZipFile]::CreateFromDirectory($zipSource, $zipPath)
            $wantedHash = (Get-FileHash (Join-Path $zipSource 'MCPR\mccleanup.exe') -Algorithm SHA256).Hash
        }

        It 'extracts the entry with the pinned content, wherever it sits in the archive' {
            $destination = Join-Path $TestDrive 'engine-out.exe'
            Save-ZipEntryMatchingHash -ArchivePath $zipPath -EntryName 'mccleanup.exe' -Sha256 $wantedHash.ToLowerInvariant() -Destination $destination | Should -BeTrue
            Get-Content $destination -Raw | Should -Be 'wanted engine'
            Test-Path "$destination.candidate" | Should -BeFalse
        }

        It 'writes nothing when no entry matches the pin' {
            $destination = Join-Path $TestDrive 'engine-none.exe'
            Save-ZipEntryMatchingHash -ArchivePath $zipPath -EntryName 'mccleanup.exe' -Sha256 ('0' * 64) -Destination $destination | Should -BeFalse
            Test-Path $destination | Should -BeFalse
            Test-Path "$destination.candidate" | Should -BeFalse
        }
    }

    Context 'Get-McAfeeRemovalEngine' {
        BeforeEach {
            $appFolder = Join-Path $TestDrive "engine-app-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
            $appConfig = (Get-AppConfiguration -AppName 'McAfeeRemoval').Clone()
            $enginePath = Join-Path $appFolder "mccleanup-$($appConfig.McprEngineVersion).exe"
        }

        It 'uses a stored engine that verifies, without any download' {
            Set-Content -Path $enginePath -Value 'engine'
            Mock Test-McAfeeRemovalIngredient { $true }
            Mock Save-McAfeeRemovalEngineFromArchive { $false }

            Get-McAfeeRemovalEngine -AppConfig $appConfig -AppFolder $appFolder | Should -Be $enginePath
            Should -Invoke Save-McAfeeRemovalEngineFromArchive -Times 0 -Exactly
        }

        It 'tries the next archive when one does not deliver the engine' {
            Mock Test-McAfeeRemovalIngredient { $true }
            $script:archiveCalls = 0
            Mock Save-McAfeeRemovalEngineFromArchive {
                $script:archiveCalls++
                if ($script:archiveCalls -lt 2) { return $false }
                Set-Content -Path $Destination -Value 'engine'
                return $true
            }

            Get-McAfeeRemovalEngine -AppConfig $appConfig -AppFolder $appFolder | Should -Be $enginePath
            Should -Invoke Save-McAfeeRemovalEngineFromArchive -Times 2 -Exactly
        }

        It 'discards a fetched engine that fails pin or signature' {
            Mock Test-McAfeeRemovalIngredient { $false }
            Mock Save-McAfeeRemovalEngineFromArchive { Set-Content -Path $Destination -Value 'tampered'; return $true }

            Get-McAfeeRemovalEngine -AppConfig $appConfig -AppFolder $appFolder | Should -BeNullOrEmpty
            Test-Path $enginePath | Should -BeFalse
        }

        It 'returns nothing when no archive delivers the engine' {
            Mock Save-McAfeeRemovalEngineFromArchive { $false }
            Get-McAfeeRemovalEngine -AppConfig $appConfig -AppFolder $appFolder | Should -BeNullOrEmpty
        }
    }

    Context 'New-McAfeeRemovalPackage' {
        BeforeEach {
            $appFolder = Join-Path $TestDrive "build-app-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
            Copy-Item $removeScript, $detectScript -Destination $appFolder
            $appConfig = (Get-AppConfiguration -AppName 'McAfeeRemoval').Clone()
            $version = Get-McAfeeRemovalPackageVersion -ScriptPath $removeScript
            $expectedPackage = Join-Path $appFolder "McAfeeRemoval-$version.intunewin"
            $storedEngine = Join-Path $appFolder 'mccleanup-stored.exe'
            Set-Content -Path $storedEngine -Value 'unattended engine' -NoNewline

            Mock Find-SevenZip { 'C:\fake\7z.exe' }
            Mock Get-McAfeeRemovalTool { Join-Path $AppFolder 'MCPR-stored.exe' }
            Mock Get-McAfeeRemovalEngine { $storedEngine }
            Mock Test-FileSha256 { $true }
            Mock Expand-McAfeeRemovalTool {
                New-Item -ItemType Directory -Path (Join-Path $Destination 'WPS') -Force | Out-Null
                Set-Content -Path (Join-Path $Destination 'master.ini') -Value '[PRODUCTS]'
                Set-Content -Path (Join-Path $Destination 'mccleanup.exe') -Value 'engine that refuses to run unattended' -NoNewline
                Set-Content -Path (Join-Path $Destination 'WPS\wps.ini') -Value '[VERSIONS]'
                return $true
            }
            $script:packagedFiles = $null
            $script:packagedEngine = $null
            Mock New-IntuneWinPackage {
                $script:packagedFiles = @(Get-ChildItem -LiteralPath $SourceFolder -Recurse -File | ForEach-Object { $_.FullName.Substring($SourceFolder.Length + 1) } | Sort-Object)
                $script:packagedEngine = Get-Content (Join-Path $SourceFolder 'MCPR\mccleanup.exe') -Raw
                Set-Content -Path (Join-Path $OutputFolder ([System.IO.Path]::ChangeExtension($SetupFile, '.intunewin'))) -Value 'package'
                return $true
            }
        }

        It 'packages exactly the two scripts and the tool, with the engine exchanged' {
            New-McAfeeRemovalPackage -AppConfig $appConfig -AppFolder $appFolder | Should -BeTrue

            Test-Path $expectedPackage | Should -BeTrue
            $script:packagedFiles | Should -Be @('Detect-McAfeeRemoval.ps1', 'MCPR\master.ini', 'MCPR\mccleanup.exe', 'MCPR\WPS\wps.ini', 'Remove-McAfee.ps1')
            $script:packagedEngine | Should -Be 'unattended engine'
            Should -Invoke New-IntuneWinPackage -Times 1 -Exactly -ParameterFilter { $SetupFile -eq 'Remove-McAfee.ps1' }
        }

        It 'replaces the package of an older version' {
            $oldPackage = Join-Path $appFolder 'McAfeeRemoval-0.0.1.intunewin'
            Set-Content -Path $oldPackage -Value 'old'

            New-McAfeeRemovalPackage -AppConfig $appConfig -AppFolder $appFolder | Should -BeTrue
            Test-Path $oldPackage | Should -BeFalse
            Test-Path $expectedPackage | Should -BeTrue
        }

        It 'skips a version that is already packaged, before fetching anything' {
            Set-Content -Path $expectedPackage -Value 'existing'

            New-McAfeeRemovalPackage -AppConfig $appConfig -AppFolder $appFolder | Should -BeFalse
            Should -Invoke Get-McAfeeRemovalTool -Times 0 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
            Get-Content $expectedPackage -Raw | Should -Match 'existing'
        }

        It 'builds nothing without 7-Zip' {
            Mock Find-SevenZip { $null }
            New-McAfeeRemovalPackage -AppConfig $appConfig -AppFolder $appFolder | Should -BeFalse
            Test-Path $expectedPackage | Should -BeFalse
        }

        It 'builds nothing when an ingredient cannot be verified' {
            Mock Get-McAfeeRemovalEngine { $null }
            New-McAfeeRemovalPackage -AppConfig $appConfig -AppFolder $appFolder | Should -BeFalse
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
        }

        It 'builds nothing when the exchanged engine is not the pinned one' {
            Mock Test-FileSha256 { $false }
            New-McAfeeRemovalPackage -AppConfig $appConfig -AppFolder $appFolder | Should -BeFalse
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
        }
    }
}

Describe 'Stored ingredients match their pins (real files)' -Tag 'LocalOnly' {
    # Needs the binaries Download-And-Package-Software.ps1 keeps in packages\mcafee-removal,
    # which are not in git
    BeforeAll {
        $realFolder = Join-Path $repoRoot 'packages\mcafee-removal'
        $realConfig = Get-AppConfiguration -AppName 'McAfeeRemoval'
    }

    It 'the official MCPR download is the pinned, McAfee-signed build' {
        $path = Join-Path $realFolder "MCPR-$($realConfig.McprVersion).exe"
        Test-Path $path | Should -BeTrue -Because 'run .\Download-And-Package-Software.ps1 -AppName McAfeeRemoval first'
        Test-McAfeeRemovalIngredient -FilePath $path -Sha256 $realConfig.McprSha256 -ExpectedPublisher $realConfig.ExpectedPublisher | Should -BeTrue
    }

    It 'the unattended engine is the pinned, McAfee-signed build and predates the parent check' {
        $path = Join-Path $realFolder "mccleanup-$($realConfig.McprEngineVersion).exe"
        Test-Path $path | Should -BeTrue -Because 'run .\Download-And-Package-Software.ps1 -AppName McAfeeRemoval first'
        Test-McAfeeRemovalIngredient -FilePath $path -Sha256 $realConfig.McprEngineSha256 -ExpectedPublisher $realConfig.ExpectedPublisher | Should -BeTrue
        (Get-Item $path).VersionInfo.ProductVersion | Should -Be $realConfig.McprEngineVersion
        [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($path)) | Should -Not -Match 'ValidateParentProcess'
    }
}
