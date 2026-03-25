# Install-KeePassXC.ps1
# Wrapper script: installs KeePassXC MSI and deploys default keepassxc.ini to all user profiles
param(
    # Absorb any extra arguments appended by Intune Management Extension (MSI metadata detection)
    [Parameter(ValueFromRemainingArguments=$true)]
    [object[]]$RemainingArgs
)

# $PSScriptRoot is always the absolute directory of the script (reliable under powershell.exe -File)
$scriptDir = $PSScriptRoot

# --- Find the MSI dynamically (avoids hard-coded filename) ---
$msiItem = Get-ChildItem -Path $scriptDir -Filter "KeePassXC-*.msi" | Select-Object -First 1
if (-not $msiItem) {
    Write-Host "No KeePassXC MSI found in $scriptDir"
    exit 1
}
$msiPath = $msiItem.FullName
Write-Host "Installing $($msiItem.Name)..."

# --- Install MSI ---
$msiArgs = @("/i", "`"$msiPath`"", "/qn", "ALLUSERS=1", "/norestart")
$process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
$exitCode = $process.ExitCode

if ($exitCode -ne 0) {
    Write-Host "MSI installation failed with exit code: $exitCode"
    exit $exitCode
}

# --- Deploy default INI to user profiles ---
$iniSource = Join-Path $scriptDir "keepassxc.ini"
if (-not (Test-Path $iniSource)) {
    Write-Host "keepassxc.ini not found in package, skipping config deployment"
    exit 0
}

# System accounts to skip when enumerating C:\Users
$excludedProfiles = @('Public', 'All Users', 'Default User')

# Get all user profile folders (real users + Default)
$profileRoot = "$env:SystemDrive\Users"
$profiles = Get-ChildItem -Path $profileRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $excludedProfiles }

foreach ($profile in $profiles) {
    $targetDir = Join-Path $profile.FullName "AppData\Roaming\KeePassXC"
    $targetFile = Join-Path $targetDir "keepassxc.ini"

    # Skip if user already has a config (preserve customizations)
    if (Test-Path $targetFile) {
        Write-Host "Config already exists for $($profile.Name), skipping"
        continue
    }

    # Verify AppData\Roaming exists (skip profiles without it, e.g. stale folders)
    $roamingDir = Join-Path $profile.FullName "AppData\Roaming"
    if (-not (Test-Path $roamingDir)) {
        continue
    }

    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Copy-Item -Path $iniSource -Destination $targetFile -Force
    Write-Host "Deployed config to $($profile.Name)"
}

exit 0
