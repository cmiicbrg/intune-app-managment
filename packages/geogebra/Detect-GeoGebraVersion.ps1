# GeoGebra Version Detection Script
# Detects actual GeoGebra Classic 6 version from HTML files
# Returns 0 if version matches or is greater, 1 if not installed or older version

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

try {
    # GeoGebra Classic installation paths
    $installPaths = @(
        "C:\Program Files (x86)\GeoGebra Classic",
        "C:\Program Files\GeoGebra Classic"
    )
    
    $installedVersion = $null
    
    foreach ($path in $installPaths) {
        if (Test-Path $path) {
            # Search in resources\app\html folder where HTML files are located
            $htmlPath = Join-Path $path "resources\app\html"
            
            if (Test-Path $htmlPath) {
                # Find version in HTML files (like classic.html)
                $htmlFiles = Get-ChildItem -Path $htmlPath -Filter "*.html" -ErrorAction SilentlyContinue
                foreach ($htmlFile in $htmlFiles) {
                    $content = Get-Content $htmlFile.FullName -Raw -ErrorAction SilentlyContinue
                    if ($content -match 'var latestVersion\s*=\s*"([\d\.]+)"') {
                        $installedVersion = $matches[1]
                        break
                    }
                }
            }
            
            if ($installedVersion) { break }
        }
    }
    
    if (-not $installedVersion) {
        # GeoGebra not installed or version not found
        Write-Output "GeoGebra not found"
        exit 1
    }
    
    # Compare versions
    $installedVer = [version]$installedVersion
    $requiredVer = [version]$RequiredVersion
    
    if ($installedVer -gt $requiredVer) {
        Write-Output "GeoGebra $installedVersion is installed (required: $RequiredVersion)"
        exit 1
    } elseif ($installedVer -eq $requiredVer) {
        Write-Output "GeoGebra $installedVersion matches required version $RequiredVersion"
        exit 0
    } else {
        Write-Output "GeoGebra $installedVersion is older than required $RequiredVersion"
        exit 1
    }
}
catch {
    Write-Output "Error detecting GeoGebra: $_"
    exit 1
}
