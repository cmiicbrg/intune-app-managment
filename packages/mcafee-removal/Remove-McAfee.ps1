<#
.SYNOPSIS
    Removes the McAfee consumer software that device manufacturers preinstall.

.DESCRIPTION
    Install command of the "McAfee Removal" Intune app (see AppConfig.ps1, McAfeeRemoval). The
    app is "installed" when no McAfee product is left on the device - the detection rule is
    Detect-McAfeeRemoval.ps1, and this script uses the very same definition (Get-McAfeeFootprint)
    to decide what to do and whether it is finished.

    Covered: McAfee LiveSafe / Total Protection / Internet Security (the classic suite), the
    newer "McAfee" app (WPS), WebAdvisor / SiteAdvisor, Safe Connect, Security Scan Plus,
    True Key and the McAfee Store packages.

    Order of work:
      1. Products that bring their own silent uninstaller (WebAdvisor, Security Scan, MSI and
         bundle based products) are uninstalled with it.
      2. McAfee services are stopped and disabled, McAfee scheduled tasks are removed.
      3. McAfee's own removal engine (MCPR, mccleanup.exe in the MCPR folder of the package)
         removes the suites - up to three passes, each one gets further than the last.
      4. The McAfee Store packages are removed for all users.
      5. Services whose program file is gone are unregistered, leftover folders, shortcuts and
         registry roots are deleted once nothing is installed any more.

    A restart is part of the removal: the engine cannot delete files that are in use or
    protected by McAfee's drivers and schedules them for the next restart. The script then
    exits with 3010 (soft reboot), Intune asks the user to restart, and the next run after the
    restart finishes the job. The newer McAfee app (WPS) usually needs exactly this second run.
    A restart is requested for at most two restarts in a row; if McAfee is still there after
    that, the script exits with 1 and the log says what is left.

    Runs as SYSTEM under Windows PowerShell 5.1: keep the syntax 5.1-compatible and the file
    pure ASCII (tests/McAfeeRemoval.Tests.ps1 checks both).

.PARAMETER ReportOnly
    Log what is installed and what would be done, change nothing. For a first look at a new
    device model:  powershell.exe -ExecutionPolicy Bypass -File .\Remove-McAfee.ps1 -ReportOnly

.PARAMETER MaxEnginePasses
    Upper limit of removal engine passes per run (the loop ends early on a clean pass).

.PARAMETER LogPath
    Log file. Defaults to the Intune Management Extension log folder, so "Collect diagnostics"
    in Intune picks it up; falls back to the temp folder when that is not writable.

.OUTPUTS
    Exit code 0    - no McAfee product is installed (any more)
    Exit code 3010 - a restart is needed to finish (or to make the next attempt possible)
    Exit code 1    - McAfee is still installed and a further restart would not help, or it
                     could not be confirmed that McAfee is gone (an inventory was unreadable)
#>

[CmdletBinding()]
param(
    [switch]$ReportOnly,

    [ValidateRange(1, 5)]
    [int]$MaxEnginePasses = 3,

    [string]$LogPath
)

# Version of this removal package. Download-And-Package-Software.ps1 reads it for the package
# name and Deploy-ToIntune.ps1 turns it into the version of the Intune app.
# BUMP IT with every change to this script, to Detect-McAfeeRemoval.ps1 or to the pinned MCPR
# ingredients in AppConfig.ps1: a changed package under an unchanged version is never rolled
# out, because the deployment finds "version already exists".
$script:McAfeeRemovalVersion = '1.0.1'

# Captured before anything is dot-sourced below
$script:RemovalDotSourced = ($MyInvocation.InvocationName -eq '.')
$script:RemovalScriptPath = $PSCommandPath
$script:RemovalScriptRoot = $PSScriptRoot

# The shared definition of "McAfee is present" (also the Intune detection rule)
. (Join-Path $script:RemovalScriptRoot 'Detect-McAfeeRemoval.ps1')

# Product list handed to the removal engine. This is McAfee's own list from StartCleanup.bat in
# the MCPR package plus WPS (the newer McAfee app), minus WMIRemover: master.ini references that
# module but no MCPR build ships it, so it fails on every run and turns every result into
# "incomplete". The list is the one lab-tested in the community reference this package follows
# (github.com/kevinmalinoski/Intune-Blog-Resources, "McAfee Removal") - change it only together
# with a test on a real device.
$script:EngineProducts = 'StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,mc-fw-host,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,WPS,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,RESIDUE'

# Where the script remembers across runs how often it has asked for a restart
$script:StateKeyPath = 'SOFTWARE\IntuneAppManagement\McAfeeRemoval'
$script:MaxRestartRequests = 2

# Intune ends an installation after 60 minutes. The long steps check this budget before they
# start, so a run always gets to its verdict and its log instead of being cut off.
$script:RemovalBudgetMinutes = 50
$script:RemovalDeadline = $null

#region Logging

function Initialize-RemovalLog {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\McAfeeRemoval.log'
    }

    try {
        $folder = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
        }
        # Roll at 2 MB so repeated attempts cannot grow one file without limit
        $existing = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -gt 2MB) {
            Move-Item -LiteralPath $Path -Destination "$Path.old" -Force -ErrorAction Stop
        }
        [System.IO.File]::AppendAllText($Path, '')
    }
    catch {
        # Not elevated or no Intune agent on this device: log next to the user's temp files
        $Path = Join-Path ([System.IO.Path]::GetTempPath()) 'McAfeeRemoval.log'
    }

    $script:RemovalLogPath = $Path
}

function Write-RemovalLog {
    param(
        [string]$Message = '',
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $line

    if (-not $script:RemovalLogPath) { return }
    try {
        [System.IO.File]::AppendAllText($script:RemovalLogPath, $line + [Environment]::NewLine)
    }
    catch {
        # A log that cannot be written must never stop the removal
        Write-Verbose "Log write failed: $($_.Exception.Message)"
    }
}

function Write-McAfeeFootprintLog {
    param(
        [string]$Title,
        $Footprint
    )

    if ($Footprint.IsPresent) {
        Write-RemovalLog "${Title}: $(@($Footprint.Active).Count) McAfee component(s) installed:"
        foreach ($item in @($Footprint.Active)) { Write-RemovalLog "    $item" }
    }
    elseif ($Footprint.IsClean) {
        Write-RemovalLog "${Title}: no McAfee product is installed."
    }
    else {
        Write-RemovalLog "${Title}: no McAfee product found, but not everything could be checked." 'WARN'
    }
    foreach ($item in @($Footprint.Residue)) { Write-RemovalLog "    leftover: $item" }
    foreach ($item in @($Footprint.Unknown)) { Write-RemovalLog "    not checked: $item" 'WARN' }
}

#endregion

#region Helpers

# Seconds left of the run's time budget (unlimited when no run is in progress, e.g. in tests).
function Get-RemovalSecondsLeft {
    if (-not $script:RemovalDeadline) { return [int]::MaxValue }
    return [int]($script:RemovalDeadline - (Get-Date)).TotalSeconds
}

# 64-bit Windows PowerShell as seen from a 32-bit process; $null when this process is already
# native. The Intune agent is a 32-bit process, and from there half of what this script has to
# look at is redirected (registry, System32) or unavailable (the DISM cmdlets).
function Get-NativePowerShellPath {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return (Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe')
    }
    return $null
}

# Runs a program hidden and waits for it, but never longer than the timeout: an uninstaller that
# opens a dialog nobody can see would otherwise block the Intune agent until its own timeout.
function Invoke-RemovalProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string]$Arguments,

        [string]$WorkingDirectory,

        [int]$TimeoutSeconds = 600
    )

    $startParams = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
    if ($Arguments) { $startParams['ArgumentList'] = $Arguments }
    if ($WorkingDirectory) { $startParams['WorkingDirectory'] = $WorkingDirectory }

    $started = Get-Date
    $process = Start-Process @startParams
    # Reading the handle now is what keeps ExitCode readable after the process has ended
    $null = $process.Handle

    $exitCode = $null
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        & (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $process.Id /T /F 2>&1 | Out-Null
    }
    else {
        $exitCode = $process.ExitCode
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        Seconds  = [int]((Get-Date) - $started).TotalSeconds
    }
}

# The program a command line starts: the quoted first token, or everything up to the first ".exe".
function Get-CommandExecutablePath {
    param([string]$CommandLine)

    if ($CommandLine -match '^\s*"([^"]+)"') { return $matches[1] }
    if ($CommandLine -match '^\s*(.+?\.exe)(\s|$)') { return $matches[1] }
    return $null
}

# The file a service or driver registration points at, or $null when that cannot be told.
# Handles the notations the service control manager accepts: quoted paths with arguments,
# \SystemRoot\..., system32\..., \??\C:\... and drivers registered without any path.
function Resolve-ServiceBinaryPath {
    param(
        [string]$ImagePath,
        [string]$Name,
        [bool]$IsDriver
    )

    $path = "$ImagePath".Trim()
    if (-not $path) {
        if ($IsDriver -and $Name) { return (Join-Path $env:WINDIR "System32\drivers\$Name.sys") }
        return $null
    }

    if ($path -match '^"([^"]+)"') { $path = $matches[1] }
    elseif ($path -match '^(.+?\.(exe|sys|dll))(\s|$)') { $path = $matches[1] }

    $path = $path -replace '^\\\?\?\\', ''
    if ($path -match '^\\SystemRoot\\') { $path = Join-Path $env:WINDIR $path.Substring(12) }
    elseif ($path -match '^system32\\') { $path = Join-Path $env:WINDIR $path }

    return [Environment]::ExpandEnvironmentVariables($path)
}

# Runs sc.exe (the service control program) and returns its exit code.
function Invoke-ServiceControl {
    param([string[]]$Arguments)

    & (Join-Path $env:WINDIR 'System32\sc.exe') @Arguments 2>&1 | Out-Null
    return $LASTEXITCODE
}

# Deletes a service's registry entry directly. Throws when that is not possible.
function Remove-ServiceRegistration {
    param([string]$Name)

    [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree("SYSTEM\CurrentControlSet\Services\$Name", $false)
}

# Antivirus products registered with Windows Security, for the log: shows whether McAfee is
# still registered and whether Microsoft Defender is.
function Get-RegisteredAntivirus {
    try {
        return @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
            ForEach-Object { '{0} (state 0x{1:X})' -f $_.displayName, [int]$_.productState })
    }
    catch {
        return @()
    }
}

# McAfee's business products (ePolicy Orchestrator agent, VirusScan Enterprise) are managed
# installations, not manufacturer bloat. The removal engine refuses to run next to them, and so
# does this script. Returns the registry keys that gave them away.
function Get-McAfeeEnterpriseMarker {
    $markers = New-Object System.Collections.Generic.List[string]
    $paths = @(
        'SOFTWARE\Network Associates\ePolicy Orchestrator\Application Plugins\EPOAGENT3000'
        'SOFTWARE\Network Associates\ePolicy Orchestrator\Application Plugins\VIRUSCAN8800'
        'SOFTWARE\Network Associates\TVD\Shared Components\Framework'
    )

    foreach ($view in @(Get-McAfeeRegistryView)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            foreach ($path in $paths) {
                $key = $base.OpenSubKey($path)
                if ($key) {
                    $key.Dispose()
                    $markers.Add("HKLM\$path [$view]")
                }
            }
        }
        finally {
            $base.Dispose()
        }
    }

    return $markers
}

#endregion

#region Product uninstallers

# The silent uninstall command of one "Installed apps" entry, or $null when the product has
# none and is left to the removal engine (the classic suite and the newer McAfee app only offer
# an interactive uninstaller).
function Get-McAfeeUninstallCommand {
    param($Entry)

    $name = "$($Entry.DisplayName)"

    # A silent command the product registered itself
    if (-not [string]::IsNullOrWhiteSpace($Entry.QuietUninstallString)) {
        return [pscustomobject]@{
            Name      = $name
            FilePath  = (Join-Path $env:WINDIR 'System32\cmd.exe')
            Arguments = '/d /s /c "' + $Entry.QuietUninstallString + '"'
        }
    }

    # Windows Installer products
    if ("$($Entry.KeyName)" -match '^\{[0-9A-Fa-f\-]{36}\}$' -and
        ("$($Entry.WindowsInstaller)" -eq '1' -or "$($Entry.UninstallString)" -match 'msiexec')) {
        return [pscustomobject]@{
            Name      = $name
            FilePath  = (Join-Path $env:WINDIR 'System32\msiexec.exe')
            Arguments = "/x $($Entry.KeyName) /qn /norestart"
        }
    }

    # Uninstallers with a known silent switch
    $executable = Get-CommandExecutablePath -CommandLine "$($Entry.UninstallString)"
    if ($executable -match '\\WebAdvisor\\Uninstaller\.exe$' -or $executable -match '\\SiteAdvisor\\Uninstall\.exe$') {
        return [pscustomobject]@{ Name = $name; FilePath = $executable; Arguments = '/s' }
    }
    if ($executable -match '\\McAfee Security Scan\\uninstall\.exe$') {
        return [pscustomobject]@{ Name = $name; FilePath = $executable; Arguments = '/s /inner' }
    }

    return $null
}

# Known uninstallers that are on disk, for products whose "Installed apps" entry is missing.
function Get-McAfeeKnownUninstaller {
    $commands = New-Object System.Collections.Generic.List[object]
    $roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($root in $roots) {
        $known = @(
            @{ Name = 'McAfee WebAdvisor'; Path = 'McAfee\WebAdvisor\Uninstaller.exe'; Arguments = '/s' }
            @{ Name = 'McAfee SiteAdvisor'; Path = 'McAfee\SiteAdvisor\Uninstall.exe'; Arguments = '/s' }
            @{ Name = 'McAfee Security Scan'; Path = 'McAfee Security Scan\uninstall.exe'; Arguments = '/s /inner' }
        )
        foreach ($item in $known) {
            $filePath = Join-Path $root $item.Path
            if (Test-Path -LiteralPath $filePath) {
                $commands.Add([pscustomobject]@{ Name = $item.Name; FilePath = $filePath; Arguments = $item.Arguments })
            }
        }
    }

    return $commands
}

# What the uninstaller step will run (Commands, without duplicates) and which installed
# products have no silent uninstaller of their own (EngineOnly).
function Get-McAfeeUninstallPlan {
    param($Footprint)

    $commands = New-Object System.Collections.Generic.List[object]
    $engineOnly = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Footprint.Products)) {
        $command = Get-McAfeeUninstallCommand -Entry $entry
        if ($command) {
            $candidates.Add($command)
        }
        else {
            $engineOnly.Add("'$($entry.DisplayName)' (uninstall command: $($entry.UninstallString))")
        }
    }
    foreach ($command in @(Get-McAfeeKnownUninstaller)) { $candidates.Add($command) }

    foreach ($command in $candidates) {
        $key = "$($command.FilePath)|$($command.Arguments)".ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $commands.Add($command)
        }
    }

    # ToArray, not @(): Windows PowerShell 5.1 fails on @() around a List[object]
    # ("Argument types do not match")
    return [pscustomobject]@{ Commands = $commands.ToArray(); EngineOnly = $engineOnly.ToArray() }
}

function Invoke-McAfeeProductUninstaller {
    param($Footprint)

    $plan = Get-McAfeeUninstallPlan -Footprint $Footprint
    if (@($plan.Commands).Count -eq 0) {
        Write-RemovalLog 'No product with its own silent uninstaller found.'
        return
    }

    foreach ($command in @($plan.Commands)) {
        if (-not (Test-Path -LiteralPath $command.FilePath)) {
            Write-RemovalLog "Uninstaller of $($command.Name) is gone: $($command.FilePath)"
            continue
        }
        if ((Get-RemovalSecondsLeft) -lt 330) {
            Write-RemovalLog "No time left in this run for the uninstaller of $($command.Name)." 'WARN'
            continue
        }
        Write-RemovalLog "Uninstalling $($command.Name): `"$($command.FilePath)`" $($command.Arguments)"
        try {
            $result = Invoke-RemovalProcess -FilePath $command.FilePath -Arguments $command.Arguments -TimeoutSeconds 300
            if ($result.TimedOut) {
                Write-RemovalLog "Uninstaller of $($command.Name) did not finish within 300 seconds and was stopped." 'WARN'
            }
            else {
                Write-RemovalLog "Uninstaller of $($command.Name) ended after $($result.Seconds) s with exit code $($result.ExitCode)."
            }
        }
        catch {
            Write-RemovalLog "Uninstaller of $($command.Name) could not be started: $($_.Exception.Message)" 'WARN'
        }
    }

    # Some uninstallers hand over to a copy of themselves and return at once
    Start-Sleep -Seconds 10
}

#endregion

#region Services and scheduled tasks

# Stops and disables McAfee's services (not the kernel drivers). Disabling matters for the
# second run: what could not be removed now must not start again after the restart, or the
# same files are locked again. Services that McAfee protects against exactly this refuse with
# "access denied" - that is expected and left to the removal engine and the restart.
function Stop-McAfeeService {
    param($Footprint)

    $services = @($Footprint.Services | Where-Object { -not $_.IsDriver })
    if ($services.Count -eq 0) {
        Write-RemovalLog 'No McAfee service registered.'
        return
    }

    foreach ($service in $services) {
        $stopCode = Invoke-ServiceControl -Arguments 'stop', $service.Name
        $disableCode = Invoke-ServiceControl -Arguments 'config', $service.Name, 'start=', 'disabled'
        # 1062 = was not running; 5 = access denied (protected service)
        Write-RemovalLog "Service $($service.Name): stop returned $stopCode, disable returned $disableCode."
    }

    Start-Sleep -Seconds 5
}

# McAfee's scheduled tasks. Removed before the engine runs: the engine tries to delete their
# registry entries directly, which only the Task Scheduler service may do, and reports the
# attempt as a failure.
function Remove-McAfeeScheduledTask {
    $removed = 0
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop |
            Where-Object { $_.TaskPath -like '\McAfee\*' -or $_.TaskName -like 'McAfee*' })
        foreach ($task in $tasks) {
            try {
                Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
                Write-RemovalLog "Removed scheduled task $($task.TaskPath)$($task.TaskName)."
                $removed++
            }
            catch {
                Write-RemovalLog "Scheduled task $($task.TaskPath)$($task.TaskName) could not be removed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
    catch {
        Write-RemovalLog "Scheduled tasks could not be read: $($_.Exception.Message)" 'WARN'
    }

    # The then empty task folder
    & (Join-Path $env:WINDIR 'System32\schtasks.exe') /Delete /TN 'McAfee' /F 2>&1 | Out-Null
    Write-RemovalLog "Scheduled tasks removed: $removed."
}

#endregion

#region Removal engine (MCPR)

# What the exit codes of mccleanup.exe mean. McAfee documents none; these come from lab tests
# of the community reference and are logged as a hint only - the result that counts is the
# footprint after the run.
function Get-McAfeeEngineExitMeaning {
    param($ExitCode)

    switch ("$ExitCode") {
        '0' { return 'success' }
        '2' { return 'restart required to finish' }
        '3' { return 'components left over' }
        default { return 'meaning unknown' }
    }
}

# Runs McAfee's removal engine from the MCPR folder of the package. Returns
# @{ Available; Passes; LastExitCode }.
function Invoke-McAfeeEngine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EngineDirectory,

        [int]$MaxPasses = 3
    )

    $result = [pscustomobject]@{ Available = $false; Passes = 0; LastExitCode = $null }

    $engine = Join-Path $EngineDirectory 'mccleanup.exe'
    if (-not (Test-Path -LiteralPath $engine)) {
        Write-RemovalLog "Removal engine not found at $engine - the package is incomplete." 'ERROR'
        return $result
    }
    $result.Available = $true

    $version = (Get-Item -LiteralPath $engine).VersionInfo.ProductVersion
    Write-RemovalLog "Removal engine: $engine (version $version)"
    if ("$version" -match '^(\d+)\.(\d+)' -and ([int]$matches[1] -gt 10 -or ([int]$matches[1] -eq 10 -and [int]$matches[2] -ge 5))) {
        # Engines from 10.5 on only run when McAfee's interactive wizard started them. Started
        # from a script they end within seconds and remove nothing.
        Write-RemovalLog 'This engine build refuses to run unattended (it validates its parent process). The package was built with the wrong engine - see the McprEngine settings in AppConfig.ps1.' 'ERROR'
    }

    $arguments = "-p $($script:EngineProducts) -v -s"
    for ($pass = 1; $pass -le $MaxPasses; $pass++) {
        if ((Get-RemovalSecondsLeft) -lt 810) {
            Write-RemovalLog "No time left in this run for engine pass $pass of $MaxPasses." 'WARN'
            break
        }
        try {
            $run = Invoke-RemovalProcess -FilePath $engine -Arguments $arguments -WorkingDirectory $EngineDirectory -TimeoutSeconds 780
        }
        catch {
            Write-RemovalLog "Removal engine could not be started: $($_.Exception.Message)" 'ERROR'
            break
        }

        $result.Passes = $pass
        $result.LastExitCode = $run.ExitCode
        if ($run.TimedOut) {
            Write-RemovalLog "Engine pass $pass of $MaxPasses did not finish within 13 minutes and was stopped." 'WARN'
            break
        }

        Write-RemovalLog "Engine pass $pass of $MaxPasses ran $($run.Seconds) s, exit code $($run.ExitCode) ($(Get-McAfeeEngineExitMeaning -ExitCode $run.ExitCode))."
        if ($run.ExitCode -eq 0) { break }
        if ($run.Seconds -lt 10) {
            Write-RemovalLog 'The engine ended within seconds - it probably refused to run. Look for "ValidateParentProcess failed" in its log.' 'WARN'
            break
        }
        if ($pass -lt $MaxPasses) { Start-Sleep -Seconds 5 }
    }

    return $result
}

# Copies the engine's own (very detailed) log next to this script's log before the McAfee
# folders are deleted, so it is part of what "Collect diagnostics" returns.
function Copy-McAfeeEngineLog {
    param([string]$EngineDirectory)

    $sources = @(
        (Join-Path $env:ProgramData 'McAfee\MCLOGS\mccleanup.log')
        (Join-Path $EngineDirectory 'mccleanup.log')
    )
    $target = Join-Path (Split-Path -Parent $script:RemovalLogPath) 'McAfeeRemoval-mccleanup.log'

    foreach ($source in $sources) {
        if (Test-Path -LiteralPath $source) {
            try {
                Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
                Write-RemovalLog "Engine log copied to $target"
            }
            catch {
                Write-RemovalLog "Engine log $source could not be copied: $($_.Exception.Message)" 'WARN'
            }
            return
        }
    }
}

#endregion

#region Store packages, orphaned services, leftovers

function Remove-McAfeeAppx {
    # The image copy that would be installed again for every new user
    try {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
            Where-Object { "$($_.DisplayName) $($_.PackageName)" -match 'McAfee' })
        foreach ($package in $provisioned) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
                Write-RemovalLog "Removed provisioned Store package $($package.PackageName)."
            }
            catch {
                Write-RemovalLog "Provisioned Store package $($package.PackageName) could not be removed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
    catch {
        Write-RemovalLog "Provisioned Store packages could not be read: $($_.Exception.Message)" 'WARN'
    }

    # What is installed for the existing users
    try {
        $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -match 'McAfee' })
        foreach ($package in $installed) {
            try {
                Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                Write-RemovalLog "Removed Store package $($package.PackageFullName) for all users."
            }
            catch {
                Write-RemovalLog "Store package $($package.PackageFullName) could not be removed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
    catch {
        Write-RemovalLog "Installed Store packages could not be read: $($_.Exception.Message)" 'WARN'
    }
}

# Unregisters McAfee services and drivers whose program file no longer exists. After the
# restart that deleted the files, these registrations are all that is left of the product -
# and all that keeps the detection from reporting the device as clean.
function Remove-McAfeeOrphanService {
    param($Footprint)

    foreach ($service in @($Footprint.Services)) {
        $binary = Resolve-ServiceBinaryPath -ImagePath $service.ImagePath -Name $service.Name -IsDriver $service.IsDriver
        if (-not $binary -or (Test-Path -LiteralPath $binary)) { continue }

        $deleteCode = Invoke-ServiceControl -Arguments 'delete', $service.Name
        Write-RemovalLog "Service $($service.Name) pointed at a file that is gone ($binary); unregistering returned $deleteCode."
        if ($deleteCode -eq 0) { continue }

        # The service control manager refuses to touch a service that was registered as
        # protected, even when its program no longer exists. What is left is a registry entry
        # that can never start anything; removing it directly takes effect with the next restart.
        try {
            Remove-ServiceRegistration -Name $service.Name
            Write-RemovalLog "Removed the registration of $($service.Name) from the registry."
        }
        catch {
            Write-RemovalLog "The registration of $($service.Name) could not be removed: $($_.Exception.Message)" 'WARN'
        }
    }
}

# Deletes leftover folders, shortcuts and registry roots. Only called once nothing is installed
# any more, and only ever touches the fixed list of McAfee locations.
function Remove-McAfeeResidue {
    param($Footprint)

    $allowedPaths = @(Get-McAfeeResiduePathCandidate)
    foreach ($path in @($Footprint.Paths)) {
        if ($allowedPaths -notcontains $path) {
            Write-RemovalLog "Skipping unexpected leftover path $path" 'WARN'
            continue
        }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-RemovalLog "Deleted $path"
        }
        catch {
            Write-RemovalLog "Could not delete $path yet (in use until the next restart?): $($_.Exception.Message)" 'WARN'
        }
    }

    $allowedRoots = @('SOFTWARE\McAfee', 'SOFTWARE\McAfee.com', 'SOFTWARE\McAfee Safe Connect')
    foreach ($root in @($Footprint.RegistryRoots)) {
        $view, $keyPath = $root -split '\|', 2
        if ($allowedRoots -notcontains $keyPath) { continue }

        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]$view)
        try {
            $base.DeleteSubKeyTree($keyPath, $false)
            Write-RemovalLog "Deleted registry key HKLM\$keyPath [$view]"
        }
        catch {
            Write-RemovalLog "Could not delete registry key HKLM\$keyPath [$view]: $($_.Exception.Message)" 'WARN'
        }
        finally {
            $base.Dispose()
        }
    }
}

#endregion

#region Restart bookkeeping and outcome

# $true while Windows still has McAfee files or services queued for deletion at the next restart.
function Test-McAfeeRestartPending {
    param($Footprint)

    if (@($Footprint.PendingServices).Count -gt 0) { return $true }

    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        return [bool](@($sessionManager.PendingFileRenameOperations) -match '\\McAfee')
    }
    catch {
        return $false
    }
}

# Reads the bookkeeping: how many restarts were asked for so far, and whether one that was asked
# for is still outstanding. The "outstanding" marker is a volatile registry key - Windows drops
# it with a real restart and keeps it through shutdown with Fast Startup, which is exactly the
# difference that matters here (only a real restart processes the queued deletions).
function Get-McAfeeRemovalState {
    $state = [pscustomobject]@{ RestartRequests = 0; RestartOutstanding = $false }
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:StateKeyPath)
        if ($key) {
            try {
                $state.RestartRequests = [int]$key.GetValue('RestartRequests', 0)
                $state.RestartOutstanding = (@($key.GetSubKeyNames()) -contains 'RestartOutstanding')
            }
            finally {
                $key.Dispose()
            }
        }
    }
    catch {
        Write-RemovalLog "Restart bookkeeping could not be read: $($_.Exception.Message)" 'WARN'
    }
    return $state
}

function Set-McAfeeRemovalState {
    param(
        [int]$RestartRequests,
        [bool]$Clear
    )

    try {
        if ($Clear) {
            [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($script:StateKeyPath, $false)
            return
        }
        $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($script:StateKeyPath)
        try {
            $key.SetValue('RestartRequests', $RestartRequests, [Microsoft.Win32.RegistryValueKind]::DWord)
            $marker = $key.CreateSubKey('RestartOutstanding', [Microsoft.Win32.RegistryKeyPermissionCheck]::Default, [Microsoft.Win32.RegistryOptions]::Volatile)
            if ($marker) { $marker.Dispose() }
        }
        finally {
            $key.Dispose()
        }
    }
    catch {
        Write-RemovalLog "Restart bookkeeping could not be written: $($_.Exception.Message)" 'WARN'
    }
}

# Decides how the run ends. Pure: everything it needs comes in as parameters.
#   ExitCode        - 0, 3010 or 1 (see the script help)
#   RestartRequests - the count to remember
#   ClearState      - $true when the bookkeeping is no longer needed
function Get-McAfeeRemovalOutcome {
    param(
        [bool]$IsPresent,
        [bool]$RestartPending,
        [bool]$InventoryIncomplete,
        [int]$RestartRequests = 0,
        [bool]$RestartOutstanding,
        [int]$MaxRestartRequests = 2
    )

    # Nothing found, but an inventory could not be read: that is neither "removed" (unproven)
    # nor a reason to ask the user for a restart. Failing makes Intune try again later.
    if (-not $IsPresent -and $InventoryIncomplete) {
        return [pscustomobject]@{ ExitCode = 1; RestartRequests = $RestartRequests; ClearState = $false; Reason = 'No McAfee product was found, but not every inventory could be read (see "not checked" above) - it cannot be confirmed that McAfee is gone.' }
    }

    if (-not $IsPresent -and -not $RestartPending) {
        return [pscustomobject]@{ ExitCode = 0; RestartRequests = 0; ClearState = $true; Reason = 'McAfee is removed.' }
    }

    $what = 'McAfee is still installed'
    if (-not $IsPresent) { $what = 'McAfee is uninstalled, the last files are deleted with the next restart' }

    if ($RestartOutstanding) {
        return [pscustomobject]@{ ExitCode = 3010; RestartRequests = $RestartRequests; ClearState = $false; Reason = "$what - the restart asked for earlier has not happened yet." }
    }

    if ($RestartRequests -ge $MaxRestartRequests) {
        if (-not $IsPresent) {
            return [pscustomobject]@{ ExitCode = 0; RestartRequests = 0; ClearState = $true; Reason = "$what." }
        }
        return [pscustomobject]@{ ExitCode = 1; RestartRequests = $RestartRequests; ClearState = $false; Reason = "$what after $RestartRequests restart(s) - giving up on restarts, see what is left above." }
    }

    return [pscustomobject]@{ ExitCode = 3010; RestartRequests = ($RestartRequests + 1); ClearState = $false; Reason = "$what - asking for a restart." }
}

#endregion

#region Main

function Invoke-McAfeeRemoval {
    param(
        [switch]$ReportOnly,
        [int]$MaxEnginePasses = 3
    )

    $started = Get-Date
    $script:RemovalDeadline = $started.AddMinutes($script:RemovalBudgetMinutes)
    $engineDirectory = Join-Path $script:RemovalScriptRoot 'MCPR'

    Write-RemovalLog ('=' * 78)
    Write-RemovalLog "McAfee Removal $($script:McAfeeRemovalVersion) on $env:COMPUTERNAME$(if ($ReportOnly) { ' (report only - nothing is changed)' })"
    Write-RemovalLog "Account: $([Security.Principal.WindowsIdentity]::GetCurrent().Name); PowerShell $($PSVersionTable.PSVersion), 64-bit process: $([Environment]::Is64BitProcess)"
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        Write-RemovalLog "Device: $($system.Manufacturer) $($system.Model); Windows $([Environment]::OSVersion.Version)"
    }
    catch {
        Write-RemovalLog "Device model could not be read: $($_.Exception.Message)" 'WARN'
    }

    $before = Get-McAfeeFootprint
    Write-McAfeeFootprintLog -Title 'Found' -Footprint $before
    Write-RemovalLog "Antivirus registered with Windows Security: $((Get-RegisteredAntivirus) -join '; ')"

    if ($ReportOnly) {
        $plan = Get-McAfeeUninstallPlan -Footprint $before
        foreach ($command in @($plan.Commands)) { Write-RemovalLog "Would uninstall $($command.Name) with: `"$($command.FilePath)`" $($command.Arguments)" }
        foreach ($product in @($plan.EngineOnly)) { Write-RemovalLog "Would leave to the removal engine: $product" }
        foreach ($marker in @(Get-McAfeeEnterpriseMarker)) { Write-RemovalLog "Managed McAfee business product found, a real run would refuse: $marker" 'WARN' }
        Write-RemovalLog "Removal engine present in the package: $(Test-Path -LiteralPath (Join-Path $engineDirectory 'mccleanup.exe'))"
        Write-RemovalLog "Restart pending for McAfee files: $(Test-McAfeeRestartPending -Footprint $before)"
        return 0
    }

    $engine = $null
    if ($before.IsPresent) {
        $markers = @(Get-McAfeeEnterpriseMarker)
        if ($markers.Count -gt 0) {
            Write-RemovalLog "A managed McAfee business product is installed ($($markers -join '; ')). This package only removes the preinstalled consumer products - nothing was changed." 'ERROR'
            return 1
        }

        Write-RemovalLog '--- Product uninstallers ---'
        Invoke-McAfeeProductUninstaller -Footprint $before

        Write-RemovalLog '--- Services and scheduled tasks ---'
        Stop-McAfeeService -Footprint (Get-McAfeeFootprint)
        Remove-McAfeeScheduledTask

        Write-RemovalLog '--- Removal engine ---'
        $engine = Invoke-McAfeeEngine -EngineDirectory $engineDirectory -MaxPasses $MaxEnginePasses
        Copy-McAfeeEngineLog -EngineDirectory $engineDirectory
    }

    # Also when nothing was found but a Store package inventory could not be read: this step
    # reads both inventories itself and removes what it finds
    if ($before.IsPresent -or @($before.Unknown).Count -gt 0) {
        Write-RemovalLog '--- Store packages ---'
        Remove-McAfeeAppx
    }

    if ($before.IsPresent) {
        # A product uninstaller that is still there after the engine gets a second chance
        $remaining = Get-McAfeeFootprint
        if (@((Get-McAfeeUninstallPlan -Footprint $remaining).Commands).Count -gt 0) {
            Write-RemovalLog '--- Product uninstallers (second attempt) ---'
            Invoke-McAfeeProductUninstaller -Footprint $remaining
        }

        Write-RemovalLog '--- Orphaned services ---'
        Remove-McAfeeOrphanService -Footprint (Get-McAfeeFootprint)
    }

    $after = Get-McAfeeFootprint
    if (-not $after.IsPresent -and @($after.Residue).Count -gt 0) {
        Write-RemovalLog '--- Leftovers ---'
        Remove-McAfeeResidue -Footprint $after
        $after = Get-McAfeeFootprint
    }

    Write-McAfeeFootprintLog -Title 'Result' -Footprint $after
    Write-RemovalLog "Antivirus registered with Windows Security: $((Get-RegisteredAntivirus) -join '; ')"

    if ($after.IsPresent -and $engine -and -not $engine.Available) {
        Write-RemovalLog 'McAfee is still installed and the package carries no removal engine - a restart would not change that.' 'ERROR'
        return 1
    }

    $state = Get-McAfeeRemovalState
    $outcome = Get-McAfeeRemovalOutcome -IsPresent $after.IsPresent -RestartPending (Test-McAfeeRestartPending -Footprint $after) `
        -InventoryIncomplete (@($after.Unknown).Count -gt 0) -RestartRequests $state.RestartRequests -RestartOutstanding $state.RestartOutstanding -MaxRestartRequests $script:MaxRestartRequests

    if ($outcome.ClearState) {
        Set-McAfeeRemovalState -Clear $true
    }
    elseif ($outcome.ExitCode -eq 3010) {
        Set-McAfeeRemovalState -RestartRequests $outcome.RestartRequests
    }

    $level = 'INFO'
    if ($outcome.ExitCode -eq 1) { $level = 'ERROR' }
    Write-RemovalLog "$($outcome.Reason) Exit code $($outcome.ExitCode) after $([int]((Get-Date) - $started).TotalSeconds) s." $level
    return $outcome.ExitCode
}

#endregion

# Dot-sourced by the tests: only the functions are wanted
if ($script:RemovalDotSourced) { return }

# Started from the 32-bit Intune agent: run again in the native 64-bit PowerShell
$nativePowerShell = Get-NativePowerShellPath
if ($nativePowerShell -and (Test-Path -LiteralPath $nativePowerShell)) {
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:RemovalScriptPath, '-MaxEnginePasses', "$MaxEnginePasses")
    if ($ReportOnly) { $forward += '-ReportOnly' }
    if ($LogPath) { $forward += @('-LogPath', $LogPath) }
    & $nativePowerShell @forward
    exit $LASTEXITCODE
}

Initialize-RemovalLog -Path $LogPath
try {
    # Last value only: whatever a cmdlet might write to the pipeline on the way must not turn
    # the exit code into an array
    $exitCode = [int](@(Invoke-McAfeeRemoval -ReportOnly:$ReportOnly -MaxEnginePasses $MaxEnginePasses) | Select-Object -Last 1)
}
catch {
    Write-RemovalLog "Unexpected error: $($_.Exception.Message) $($_.ScriptStackTrace)" 'ERROR'
    $exitCode = 1
}
exit $exitCode
