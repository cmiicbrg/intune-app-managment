# Google Drive for Desktop Version Detection Script
# Returns exit code 0 if installed version >= required version, 1 otherwise
# Used by Intune Win32 app detection
#
# Intune only treats the app as installed when the script exits 0 AND writes to STDOUT;
# exit 0 with empty output counts as "not installed". Every path therefore writes one line.
#
# Google Drive installs GoogleDriveFS.exe in versioned subfolders:
#   C:\Program Files\Google\Drive File Stream\123.0.1.0\GoogleDriveFS.exe
# This script finds the newest installed version and compares it.

param(
    [string]$RequiredVersion
)

# Deploy-ToIntune.ps1 replaces the param block above with a literal assignment. A script uploaded
# by hand arrives without it - and a *mandatory* parameter would then make PowerShell prompt for
# input, so the Intune agent waits for its 60-minute script timeout and every other app on the
# device queues behind it. Fail fast instead.
if ([string]::IsNullOrWhiteSpace($RequiredVersion)) {
    Write-Output "RequiredVersion was not injected - deploy this script through Deploy-ToIntune.ps1"
    exit 1
}

function Get-GoogleDriveVersion {
    # Method 1: Scan Drive File Stream folder for newest version subfolder (most accurate after auto-update)
    $driveStreamPath = "C:\Program Files\Google\Drive File Stream"
    
    if (Test-Path $driveStreamPath) {
        # Get all version folders (format: X.X.X.X) that contain GoogleDriveFS.exe
        $versionFolders = Get-ChildItem -Path $driveStreamPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
            ForEach-Object {
                $exePath = Join-Path $_.FullName "GoogleDriveFS.exe"
                if (Test-Path $exePath) {
                    try {
                        [PSCustomObject]@{
                            Name = $_.Name
                            Version = [version]$_.Name
                        }
                    }
                    catch {
                        $null
                    }
                }
            } |
            Where-Object { $_ } |
            Sort-Object Version -Descending
        
        if ($versionFolders -and $versionFolders.Count -gt 0) {
            return $versionFolders[0].Name
        }
    }
    
    # Method 2: Fallback to registry (may lag behind after auto-update)
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{6BBAE539-2232-434A-A4E5-9A33560C6283}"
    
    if (Test-Path $regPath) {
        $displayVersion = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).DisplayVersion
        if ($displayVersion) {
            return $displayVersion
        }
        
        # Extract version from InstallLocation path
        $installLocation = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).InstallLocation
        if ($installLocation -and $installLocation -match '(\d+\.\d+\.\d+\.\d+)') {
            return $matches[1]
        }
    }
    
    return $null
}

# Get installed version
$installedVersion = Get-GoogleDriveVersion

if (-not $installedVersion) {
    Write-Output "Google Drive not found"
    exit 1
}

# Compare versions
try {
    $installedVer = [version]$installedVersion
    $requiredVer = [version]$RequiredVersion

    if ($installedVer -ge $requiredVer) {
        # Compliant: installed version is >= required
        Write-Output "Google Drive $installedVersion is installed (required: $RequiredVersion)"
        exit 0
    }
    else {
        # Non-compliant: needs update
        Write-Output "Google Drive $installedVersion is older than required $RequiredVersion"
        exit 1
    }
}
catch {
    # Version comparison failed - assume non-compliant
    Write-Output "Error comparing Google Drive version '$installedVersion' with '$RequiredVersion': $_"
    exit 1
}
