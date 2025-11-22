# Quick Setup - Install Prerequisites for Intune Deployment
# Run this first before deploying to Intune

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Intune Deployment - Prerequisites Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "PowerShell Version: $($psVersion.Major).$($psVersion.Minor)" -ForegroundColor Cyan

if ($psVersion.Major -lt 5) {
    Write-Host "ERROR: PowerShell 5.1 or higher is required" -ForegroundColor Red
    Write-Host "Please upgrade PowerShell and try again" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] PowerShell version OK" -ForegroundColor Green
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "NOTE: Not running as Administrator" -ForegroundColor Yellow
    Write-Host "Installing modules for current user only" -ForegroundColor Yellow
    Write-Host ""
}
else {
    Write-Host "[OK] Running as Administrator" -ForegroundColor Green
    Write-Host ""
}

# Install NuGet provider if needed
Write-Host "Checking NuGet provider..." -ForegroundColor Cyan
$nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue

if (-not $nuget) {
    Write-Host "Installing NuGet provider..." -ForegroundColor Yellow
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Write-Host "[OK] NuGet provider installed" -ForegroundColor Green
}
else {
    Write-Host "[OK] NuGet provider already installed" -ForegroundColor Green
}

Write-Host ""

# Set PSGallery as trusted
Write-Host "Configuring PowerShell Gallery..." -ForegroundColor Cyan
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Write-Host "[OK] PowerShell Gallery configured" -ForegroundColor Green
Write-Host ""

# Install required modules
$modules = @(
    @{Name="Microsoft.Graph.Authentication"; Description="Microsoft Graph Authentication"},
    @{Name="IntuneWin32App"; Description="Intune Win32 App Management"}
)

foreach ($module in $modules) {
    Write-Host "Checking module: $($module.Name)..." -ForegroundColor Cyan
    
    $installed = Get-Module -ListAvailable -Name $module.Name | Sort-Object Version -Descending | Select-Object -First 1
    
    if ($installed) {
        Write-Host "  Current version: $($installed.Version)" -ForegroundColor Gray
        Write-Host "  Checking for updates..." -ForegroundColor Gray
        
        try {
            $online = Find-Module -Name $module.Name -ErrorAction SilentlyContinue
            if ($online -and ($online.Version -gt $installed.Version)) {
                Write-Host "  Updating to version $($online.Version)..." -ForegroundColor Yellow
                Update-Module -Name $module.Name -Force -ErrorAction Stop
                Write-Host "  [OK] Updated to latest version" -ForegroundColor Green
            }
            else {
                Write-Host "  [OK] Already up to date" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "  [OK] Module installed (update check skipped)" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  Installing $($module.Name)..." -ForegroundColor Yellow
        try {
            Install-Module -Name $module.Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Host "  [OK] Installed successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "  [ERROR] Failed to install: $_" -ForegroundColor Red
            Write-Host ""
            Write-Host "Please install manually:" -ForegroundColor Yellow
            Write-Host "  Install-Module -Name $($module.Name) -Scope CurrentUser -Force" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# Test connection capability
Write-Host "Testing Microsoft Graph connectivity..." -ForegroundColor Cyan
try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Write-Host "[OK] Microsoft Graph module loaded" -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] Failed to load Microsoft Graph module" -ForegroundColor Red
}

Write-Host ""

try {
    Import-Module IntuneWin32App -ErrorAction Stop
    Write-Host "[OK] IntuneWin32App module loaded" -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] Failed to load IntuneWin32App module" -ForegroundColor Red
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Download and package software:" -ForegroundColor White
Write-Host "   .\Download-And-Package-Software.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Deploy to Intune:" -ForegroundColor White
Write-Host "   .\Deploy-ToIntune.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "3. Or deploy with automatic assignment:" -ForegroundColor White
Write-Host "   .\Deploy-ToIntune.ps1 -AssignToAllUsers" -ForegroundColor Gray
Write-Host ""
Write-Host "For more information, see:" -ForegroundColor Cyan
Write-Host "  DEPLOYMENT-GUIDE.md" -ForegroundColor Gray
Write-Host ""
