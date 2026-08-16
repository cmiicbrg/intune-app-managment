# Quick Setup - Install Prerequisites for Intune Deployment
# Run this first before deploying to Intune

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Intune Deployment - Prerequisites Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check PowerShell version. This script intentionally has no '#Requires -Version 7.4' gate
# so it still runs on Windows PowerShell 5.1 and can explain how to install PowerShell 7.
$psVersion = $PSVersionTable.PSVersion
Write-Host "PowerShell Version: $($psVersion.Major).$($psVersion.Minor)" -ForegroundColor Cyan

if ($psVersion.Major -lt 7 -or ($psVersion.Major -eq 7 -and $psVersion.Minor -lt 4)) {
    Write-Host "ERROR: PowerShell 7.4 or higher is required (you are running $psVersion)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Install the latest PowerShell 7 with:" -ForegroundColor Yellow
    Write-Host "  winget install --id Microsoft.PowerShell --source winget" -ForegroundColor Gray
    Write-Host "Then run this script again from a 'pwsh' terminal." -ForegroundColor Yellow
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

# Configure the git merge driver used by .gitattributes for AppVersions.json.
# Without it, a pull can raise an ordinary (harmless) conflict in that file; with it,
# your locally refreshed versions always win and pulls stay clean.
Write-Host "Configuring git merge driver for AppVersions.json..." -ForegroundColor Cyan
try {
    $gitCommand = Get-Command git -ErrorAction Stop
    $null = & $gitCommand.Source -C $PSScriptRoot rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) {
        & $gitCommand.Source -C $PSScriptRoot config merge.ours.driver true
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Merge driver configured" -ForegroundColor Green
        }
        else {
            Write-Host "[SKIP] Could not set merge driver (non-fatal)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[SKIP] Not a git repository" -ForegroundColor Gray
    }
}
catch {
    Write-Host "[SKIP] git not available" -ForegroundColor Gray
}

Write-Host ""

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
    @{Name="Microsoft.Graph.Groups"; Description="Microsoft Graph Groups Management"}
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
