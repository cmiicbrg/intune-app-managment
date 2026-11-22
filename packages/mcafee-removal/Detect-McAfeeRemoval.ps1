# McAfee removal - detection rule and the shared definition of "McAfee is present"
#
# This file has two jobs and deliberately one definition for both:
#
#   1. Intune detection rule of the "McAfee Removal" app (uploaded by Deploy-ToIntune.ps1).
#      The app counts as installed when no McAfee product is left on the device: exit code 0
#      plus a line on STDOUT. A device that never had McAfee is therefore detected right away
#      and never even downloads the package.
#   2. Remove-McAfee.ps1 dot-sources the copy inside the package and uses Get-McAfeeFootprint
#      to decide what to remove and whether it is finished. Because both sides ask the same
#      function, "detected" and "nothing left to remove" can never disagree.
#
# Runs on the client under Windows PowerShell 5.1: keep the syntax 5.1-compatible and the file
# pure ASCII (5.1 reads a BOM-less file as ANSI). tests/McAfeeRemoval.Tests.ps1 checks both.
#
# What counts (see Get-McAfeeFootprint):
#   Active  - something that is still installed or still registered to run: an entry in
#             "Installed apps", a Store package, a service or kernel driver. Any of these means
#             "McAfee present".
#   Residue - inert leftovers (folders, registry roots, shortcuts). Reported and cleaned up by
#             the removal script, but they never make the detection fail: the removal tool
#             schedules locked files for deletion at the next restart, and an empty folder must
#             not keep the app in a "failed" state until then.
#   Unknown - an inventory that could not be read (the Store package lists need the AppX and
#             DISM services). Unknown is not clean: a device is only reported as free of McAfee
#             when every inventory was read and came back empty (IsClean). Otherwise a McAfee
#             Store package behind a failed read would be reported as "removed" for good.

param(
    [string]$RequiredVersion
)

# Deploy-ToIntune.ps1 replaces the param block above with a literal assignment of the package
# version. The version is only reported, never compared - detection is about the state of the
# device, not about which package version ran.

# Both registry views on 64-bit Windows, so the answer does not depend on the bitness of the
# host that happens to run this script.
function Get-McAfeeRegistryView {
    if ([Environment]::Is64BitOperatingSystem) {
        return @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
    }
    return @([Microsoft.Win32.RegistryView]::Default)
}

# $true for an "Installed apps" entry that belongs to McAfee. Matches the name or the publisher
# (LiveSafe, Total Protection, WebAdvisor, Safe Connect, Security Scan, the newer "McAfee" app
# whose key is McAfee.WPS) and the True Key password manager of the Intel Security era.
function Test-McAfeeUninstallEntry {
    param($Entry)

    if ("$($Entry.DisplayName)" -match '\bMcAfee\b') { return $true }
    if ("$($Entry.Publisher)" -match '\bMcAfee\b') { return $true }
    if ("$($Entry.KeyName)" -match '^McAfee\.') { return $true }
    if ("$($Entry.DisplayName)" -match '\bTrue Key\b' -and "$($Entry.Publisher)" -match 'Intel Security') { return $true }
    return $false
}

# Every McAfee entry under the machine-wide Uninstall keys (both registry views).
function Get-McAfeeUninstallEntry {
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($view in @(Get-McAfeeRegistryView)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        $uninstall = $null
        try {
            $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $uninstall) { continue }

            foreach ($keyName in $uninstall.GetSubKeyNames()) {
                $key = $uninstall.OpenSubKey($keyName)
                if (-not $key) { continue }
                try {
                    $entry = [pscustomobject]@{
                        KeyName              = $keyName
                        View                 = "$view"
                        DisplayName          = "$($key.GetValue('DisplayName'))"
                        Publisher            = "$($key.GetValue('Publisher'))"
                        DisplayVersion       = "$($key.GetValue('DisplayVersion'))"
                        UninstallString      = "$($key.GetValue('UninstallString'))"
                        QuietUninstallString = "$($key.GetValue('QuietUninstallString'))"
                        WindowsInstaller     = "$($key.GetValue('WindowsInstaller'))"
                    }
                }
                finally {
                    $key.Dispose()
                }
                if (Test-McAfeeUninstallEntry -Entry $entry) { $entries.Add($entry) }
            }
        }
        finally {
            if ($uninstall) { $uninstall.Dispose() }
            $base.Dispose()
        }
    }

    return $entries
}

# McAfee Store packages provisioned in the Windows image: the copy that is installed for every
# new user account. This is a separate inventory from the installed packages below (DISM, not
# the AppX deployment service) - a package can be provisioned without being installed for
# anyone yet, and removing it for all users does not take it out of the image.
# Returns @{ Packages; Warning } like Get-McAfeeAppxPackage.
function Get-McAfeeProvisionedPackage {
    $result = @{ Packages = @(); Warning = $null }
    try {
        $result.Packages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
            Where-Object { "$($_.DisplayName) $($_.PackageName)" -match 'McAfee' } |
            ForEach-Object { [pscustomobject]@{ Name = "$($_.DisplayName)"; PackageName = "$($_.PackageName)" } })
    }
    catch {
        $result.Warning = "Provisioned Store packages could not be read: $("$($_.Exception.Message)" -replace '\s+', ' ')"
    }
    return $result
}

# McAfee Store packages installed for any user (McAfee Personal Security, the
# McAfeeWPSSparsePackage shell integration). Returns @{ Packages; Warning }: when the AppX
# cmdlets cannot be used the list is empty and the reason is returned instead of thrown, so the
# registry and service findings are still reported - and Get-McAfeeFootprint turns the reason
# into "Unknown", which keeps the device from being called clean.
function Get-McAfeeAppxPackage {
    $result = @{ Packages = @(); Warning = $null }
    try {
        $result.Packages = @(Get-AppxPackage -AllUsers -ErrorAction Stop |
            Where-Object { $_.Name -match 'McAfee' } |
            ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; PackageFullName = "$($_.PackageFullName)" } })
    }
    catch {
        $result.Warning = "Store packages could not be read: $("$($_.Exception.Message)" -replace '\s+', ' ')"
    }
    return $result
}

# Name, ImagePath, type and deletion state of every registered service and driver.
function Get-ServiceRegistryRecord {
    $records = New-Object System.Collections.Generic.List[object]

    $services = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services')
    if (-not $services) { return $records }
    try {
        foreach ($name in $services.GetSubKeyNames()) {
            $key = $null
            try { $key = $services.OpenSubKey($name) } catch { $key = $null }
            if (-not $key) { continue }
            try {
                $records.Add([pscustomobject]@{
                    Name       = $name
                    ImagePath  = "$($key.GetValue('ImagePath'))"
                    Type       = $key.GetValue('Type')
                    DeleteFlag = $key.GetValue('DeleteFlag')
                })
            }
            finally {
                $key.Dispose()
            }
        }
    }
    finally {
        $services.Dispose()
    }

    return $records
}

# $true for a service or driver that belongs to McAfee:
#   - its binary lives in a McAfee folder (every user-mode service: Common Files\McAfee,
#     McAfee\WPS, McAfee\WebAdvisor, McAfee.com, ...), or
#   - it is one of McAfee's kernel drivers, which sit in System32\drivers and are recognizable
#     only by name: the mfe* family (mfehidk, mfefirek, mfesec, mfeelamk, ...) plus three
#     drivers outside that naming scheme.
# Deliberately no "Mc*" name rule: Windows ships McpManagementService and McmSvc.
function Test-McAfeeServiceRecord {
    param($Record)

    if ("$($Record.ImagePath)" -match '\\McAfee') { return $true }
    if ("$($Record.Name)" -match '^mfe[a-z0-9]+$') { return $true }
    return ("$($Record.Name)" -match '^(HipShieldK|McPvDrv|cfwids)$')
}

# The McAfee services and drivers on this device. PendingDelete marks those the service control
# manager has already been told to delete (they disappear with the next restart).
function Get-McAfeeService {
    return @(Get-ServiceRegistryRecord |
        Where-Object { Test-McAfeeServiceRecord -Record $_ } |
        ForEach-Object {
            [pscustomobject]@{
                Name          = $_.Name
                ImagePath     = $_.ImagePath
                # Service type 1 = kernel driver, 2 = file system driver
                IsDriver      = (($_.Type -as [int]) -in 1, 2)
                PendingDelete = (($_.DeleteFlag -as [int]) -eq 1)
            }
        })
}

# McAfee's registry roots under HKLM\SOFTWARE that exist, as "<view>|<path>" strings.
function Get-McAfeeRegistryRoot {
    $found = New-Object System.Collections.Generic.List[string]

    foreach ($view in @(Get-McAfeeRegistryView)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            foreach ($path in 'SOFTWARE\McAfee', 'SOFTWARE\McAfee.com', 'SOFTWARE\McAfee Safe Connect') {
                $key = $null
                try { $key = $base.OpenSubKey($path) } catch { $key = $null }
                if ($key) {
                    $key.Dispose()
                    $found.Add("$view|$path")
                }
            }
        }
        finally {
            $base.Dispose()
        }
    }

    return $found
}

# Candidate locations of McAfee folders and shortcuts. Built from the environment of this
# process; a root that is not set is skipped, so a missing variable can never turn into a path
# relative to the drive root.
function Get-McAfeeResiduePathCandidate {
    $roots = @(
        $env:ProgramW6432
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:CommonProgramW6432
        $env:CommonProgramFiles
        ${env:CommonProgramFiles(x86)}
        $env:ProgramData
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        foreach ($leaf in 'McAfee', 'McAfee.com', 'McAfee Security Scan') {
            $candidates.Add((Join-Path $root $leaf))
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        $candidates.Add((Join-Path $startMenu 'McAfee'))
        $candidates.Add((Join-Path $startMenu 'McAfee.lnk'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PUBLIC)) {
        $candidates.Add((Join-Path $env:PUBLIC 'Desktop\McAfee.lnk'))
    }

    return $candidates
}

# The candidates that exist on this device.
function Get-McAfeeResiduePath {
    return @(Get-McAfeeResiduePathCandidate | Where-Object { Test-Path -LiteralPath $_ })
}

# Everything McAfee on this device, split into what is still installed (Active), what is only
# left over (Residue) and what could not be checked (Unknown). The two answers both the Intune
# detection and the removal script act on:
#   IsPresent - something is still installed
#   IsClean   - nothing is installed AND every inventory could be read; the only state that may
#               be reported as "McAfee is gone"
function Get-McAfeeFootprint {
    $products = @(Get-McAfeeUninstallEntry)
    $appx = Get-McAfeeAppxPackage
    $provisioned = Get-McAfeeProvisionedPackage
    $allServices = @(Get-McAfeeService)
    $services = @($allServices | Where-Object { -not $_.PendingDelete })
    $pendingServices = @($allServices | Where-Object { $_.PendingDelete })
    $registryRoots = @(Get-McAfeeRegistryRoot)
    $paths = @(Get-McAfeeResiduePath)

    $active = New-Object System.Collections.Generic.List[string]
    foreach ($product in $products) {
        $active.Add("app '$($product.DisplayName)' $($product.DisplayVersion)".Trim())
    }
    foreach ($package in @($appx.Packages)) {
        $active.Add("Store package $($package.Name)")
    }
    foreach ($package in @($provisioned.Packages)) {
        $active.Add("provisioned Store package $($package.Name)")
    }
    foreach ($service in $services) {
        $kind = 'service'
        if ($service.IsDriver) { $kind = 'driver' }
        $active.Add("$kind $($service.Name)")
    }

    $residue = New-Object System.Collections.Generic.List[string]
    foreach ($service in $pendingServices) { $residue.Add("service $($service.Name) (deleted at next restart)") }
    foreach ($root in $registryRoots) { $residue.Add("registry $(($root -split '\|')[1]) [$(($root -split '\|')[0])]") }
    foreach ($path in $paths) { $residue.Add($path) }

    $unknown = New-Object System.Collections.Generic.List[string]
    foreach ($warning in @($appx.Warning, $provisioned.Warning)) {
        if ($warning) { $unknown.Add($warning) }
    }

    return [pscustomobject]@{
        Products            = $products
        AppxPackages        = @($appx.Packages)
        ProvisionedPackages = @($provisioned.Packages)
        Services            = $services
        PendingServices     = $pendingServices
        RegistryRoots       = $registryRoots
        Paths               = $paths
        Active              = $active.ToArray()
        Residue             = $residue.ToArray()
        Unknown             = $unknown.ToArray()
        IsPresent           = ($active.Count -gt 0)
        IsClean             = ($active.Count -eq 0 -and $unknown.Count -eq 0)
    }
}

# Dot-sourced by Remove-McAfee.ps1 and by the tests: only the functions are wanted.
if ($MyInvocation.InvocationName -eq '.') { return }

# From here on this is the Intune detection rule. Like every detection script in this
# repository it refuses to run as a copy uploaded by hand (no injected version): the rule
# deployed through Deploy-ToIntune.ps1 is the only one that is tested.
if ([string]::IsNullOrWhiteSpace($RequiredVersion)) {
    Write-Output "RequiredVersion was not injected - deploy this script through Deploy-ToIntune.ps1"
    exit 1
}

$footprint = Get-McAfeeFootprint
if ($footprint.IsPresent) {
    # Non-zero exit = "not detected": Intune runs (or re-runs) the removal. The text ends up in
    # the Intune Management Extension log and names what is still there.
    Write-Output "McAfee is present: $(($footprint.Active | Select-Object -First 12) -join '; ')"
    exit 1
}

if (-not $footprint.IsClean) {
    # Nothing found, but not everything could be looked at. Reporting "installed" now would be
    # final for a device whose only McAfee component sits behind the failed read; "not detected"
    # is checked again on the next cycle and corrects itself as soon as the read works.
    Write-Output "Cannot confirm that McAfee is gone: $($footprint.Unknown -join '; ')"
    exit 1
}

Write-Output "No McAfee product is installed (removal package $RequiredVersion)"
exit 0
