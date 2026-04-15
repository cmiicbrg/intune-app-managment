# Google Drive for Desktop Version Detection Script
# Returns exit code 0 if installed version >= required version, 1 otherwise
# Used by Intune Win32 app detection
#
# Google Drive installs GoogleDriveFS.exe in versioned subfolders:
#   C:\Program Files\Google\Drive File Stream\123.0.1.0\GoogleDriveFS.exe
# This script finds the newest installed version and compares it.

param(
    [Parameter(Mandatory=$true)]
    [string]$RequiredVersion
)

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
    # Not installed
    exit 1
}

# Compare versions
try {
    $installedVer = [version]$installedVersion
    $requiredVer = [version]$RequiredVersion
    
    if ($installedVer -ge $requiredVer) {
        # Compliant: installed version is >= required
        exit 0
    }
    else {
        # Non-compliant: needs update
        exit 1
    }
}
catch {
    # Version comparison failed - assume non-compliant
    exit 1
}
