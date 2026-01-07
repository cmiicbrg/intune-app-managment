# Application Configuration File
# Centralized configuration for all software packages
# Author: GitHub Copilot
# Date: October 11, 2025

# Application definitions with all metadata
$script:AppConfigurations = @{
    Firefox = @{
        Name = "Firefox"
        DisplayNameTemplate = "Mozilla Firefox {0} (German)"
        Publisher = "Mozilla"
        Description = "Mozilla Firefox web browser - German version (auto-updates enabled)"
        Folder = "firefox"
        IconFile = "firefox-logo.png"
        IntuneWinPattern = "Firefox-Setup-*-de.intunewin"
        DownloadUrl = "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=de"
        VersionApiUrl = "https://product-details.mozilla.org/1.0/firefox_versions.json"
        VersionApiProperty = "LATEST_FIREFOX_VERSION"
        FilenameTemplate = "Firefox-Setup-{0}-de.exe"
        PackageType = "EXE"
        InstallCommandTemplate = '"{0}" /S'
        UninstallCommandTemplate = '"C:\Program Files\Mozilla Firefox\uninstall\helper.exe" /S'
        DetectionPath = "C:\Program Files\Mozilla Firefox"
        DetectionFile = "firefox.exe"
        DetectionType = "File"
        DetectionOperator = "greaterThanOrEqual"
        AutoUpdate = $true
    }
    
    Chrome = @{
        Name = "Chrome"
        DisplayNameTemplate = "Google Chrome {0}"
        Publisher = "Google LLC"
        Description = "Google Chrome Enterprise web browser (auto-updates enabled)"
        Folder = "chrome"
        IconFile = "chrome-logo.png"
        IntuneWinPattern = "GoogleChrome-*-Enterprise-x64.intunewin"
        DownloadUrl = "https://dl.google.com/chrome/install/googlechromestandaloneenterprise64.msi"
        FilenameTemplate = "GoogleChrome-{0}-Enterprise-x64.msi"
        FilenameTempate = "googlechromestandaloneenterprise64.msi"
        PackageType = "MSI"
        InstallCommandTemplate = 'msiexec /i "{0}" /qn'
        UninstallCommandTemplate = 'msiexec /x {0} /qn'  # {0} will be MSI product code
        DetectionType = "File"  # Use file detection instead of MSI for auto-update support
        DetectionPath = "C:\Program Files\Google\Chrome\Application"
        DetectionFile = "chrome.exe"
        DetectionOperator = "greaterThanOrEqual"
        VersionExtraction = "AppLocker"  # Extract version after download using Get-AppLockerFileInformation
        AutoUpdate = $true
    }
    
    SevenZip = @{
        Name = "7-Zip"
        DisplayNameTemplate = "7-Zip {0}"
        Publisher = "Igor Pavlov"
        Description = "7-Zip file archiver"
        Folder = "7zip"
        IconFile = "7zip-logo.png"
        IntuneWinPattern = "7z*-x64.intunewin"
        DownloadPageUrl = "https://www.7-zip.org/download.html"
        DownloadUrlRegex = 'href="([^"]*(7z\d+)-x64\.msi)"'
        DownloadUrlTemplate = "https://www.7-zip.org/{0}"
        FallbackUrl = "https://www.7-zip.org/a/7z2408-x64.msi"
        FallbackVersion = "7z2408"
        FilenameTemplate = "{0}-x64.msi"
        PackageType = "MSI"
        InstallCommandTemplate = 'msiexec /i "{0}" /qn'
        UninstallCommandTemplate = 'msiexec /x {0} /qn'  # {0} will be MSI product code
        DetectionType = "MSI"
        DetectionOperator = "ProductCodeOnly"  # Simple product code detection, no version operator needed
        VersionFormat = "NoPrefix"  # Version like "7z2501" needs special handling
        AutoUpdate = $false
    }
    
    GIMP = @{
        Name = "GIMP"
        DisplayNameTemplate = "GIMP {0}"
        Publisher = "The GIMP Team"
        Description = "GIMP - GNU Image Manipulation Program"
        Folder = "gimp"
        IconFile = "gimp-logo.png"
        IntuneWinPattern = "gimp-*-setup*.intunewin"
        DownloadPageUrl = "https://www.gimp.org/downloads/"
        DownloadUrlRegex = 'gimp-(\d+\.\d+\.\d+)-setup.*?\.exe'
        DownloadUrlTemplate = "https://download.gimp.org/gimp/v{0}/windows/gimp-{1}-setup.exe"  # {0}=majorMinor, {1}=fullVersion
        FallbackUrl = "https://download.gimp.org/gimp/v3.0/windows/gimp-3.0.6-setup.exe"
        FallbackVersion = "3.0.6"
        FilenameTemplate = "gimp-{0}-setup.exe"
        PackageType = "EXE"
        InstallCommandTemplate = '"{0}" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /ALLUSERS'
        UninstallCommandTemplate = '"C:\Program Files\GIMP 3\uninst\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        DetectionPath = "C:\Program Files\GIMP 3\bin"
        DetectionFile = "gimp-3.0.exe"
        DetectionType = "File"
        DetectionOperator = "equal"
        AutoUpdate = $false
    }
    
    VLC = @{
        Name = "VLC"
        DisplayNameTemplate = "VLC Media Player {0}"
        Publisher = "VideoLAN"
        Description = "VLC media player"
        Folder = "vlc"
        IconFile = "vlc-logo.png"
        IntuneWinPattern = "vlc-*-win64.intunewin"
        DownloadPageUrl = "https://get.videolan.org/vlc/last/win64/"
        DownloadUrlRegex = 'href="(vlc-([\d\.]+)-win64\.exe)"'
        DownloadUrlTemplate = "https://get.videolan.org/vlc/last/win64/{0}"
        FallbackUrl = "https://get.videolan.org/vlc/3.0.21/win64/vlc-3.0.21-win64.exe"
        FallbackVersion = "3.0.21"
        FilenameTemplate = "vlc-{0}-win64.exe"
        PackageType = "EXE"
        InstallCommandTemplate = '"{0}" /S'
        UninstallCommandTemplate = '"C:\Program Files\VideoLAN\VLC\uninstall.exe" /S'
        DetectionPath = "C:\Program Files\VideoLAN\VLC"
        DetectionFile = "vlc.exe"
        DetectionType = "File"
        DetectionOperator = "equal"
        AutoUpdate = $false
    }
    
    NotepadPlusPlus = @{
        Name = "Notepad++"
        DisplayNameTemplate = "Notepad++ {0}"
        Publisher = "Notepad++ Team"
        Description = "Notepad++ text and source code editor"
        Folder = "npp"
        IconFile = "notepadplusplus-logo.png"
        IntuneWinPattern = "npp.*Installer.x64.intunewin"
        GitHubRepo = "notepad-plus-plus/notepad-plus-plus"
        GitHubApiUrl = "https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest"
        GitHubAssetPattern = "Installer\.x64\.exe$"
        FallbackUrl = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.6.9/npp.8.6.9.Installer.x64.exe"
        FallbackVersion = "8.6.9"
        FilenamePattern = "npp.{0}.Installer.x64.exe"
        PackageType = "EXE"
        InstallCommandTemplate = '"{0}" /S'
        UninstallCommandTemplate = '"C:\Program Files\Notepad++\uninstall.exe" /S'
        DetectionPath = "C:\Program Files\Notepad++"
        DetectionFile = "notepad++.exe"
        DetectionType = "File"
        DetectionOperator = "equal"
        AutoUpdate = $false
    }
    
    AffinityStudio = @{
        Name = "Affinity Studio"
        DisplayNameTemplate = "Affinity Studio {0}"
        Publisher = "Affinity"
        Description = "Affinity Studio - Creative suite for design, photo editing, and publishing"
        Folder = "affinity"
        IconFile = "affinity-logo.png"
        IntuneWinPattern = "Affinity*.intunewin"
        DownloadUrl = "https://downloads.affinity.studio/Affinity%20x64.exe"
        FilenameTemplate = "Affinity-{0}-x64.exe"
        PackageType = "MSI"  # Note: Downloaded as EXE, must be extracted to MSI manually
        InstallCommandTemplate = 'msiexec /i "{0}" /qn ALLUSERS=1'
        UninstallCommandTemplate = 'msiexec /x {0} /qn'  # {0} will be MSI product code
        DetectionType = "MSI"
        DetectionOperator = "ProductCodeOnly"
        VersionExtraction = "AppLocker"  # Extract version after download using Get-AppLockerFileInformation
        ManualExtraction = $true  # Requires manual extraction: Run downloaded EXE with /extract /defaults
        ExtractionCommand = '"{0}" /extract /defaults'  # Command to extract MSI from EXE
        AutoUpdate = $false
    }
    
    Inkscape = @{
        Name = "Inkscape"
        DisplayNameTemplate = "Inkscape {0}"
        Publisher = "Inkscape Project"
        Description = "Inkscape - Professional vector graphics editor"
        Folder = "inkscape"
        IconFile = "inkscape-logo.png"
        IntuneWinPattern = "inkscape-*.intunewin"
        DownloadPageUrl = "https://inkscape.org/release/"
        DownloadUrlRegex = 'href="/release/([\d\.]+)/"'  # Extract version from main page
        PlatformsUrlTemplate = "https://inkscape.org/release/{0}/platforms/"  # {0} = version
        DownloadLinkRegex = 'https://inkscape\.org/gallery/item/\d+/(inkscape-[\d\.]+-\d{4}-\d{2}-\d{2}_[a-f0-9]+-x64\.msi)'  # Extract MSI filename
        FallbackUrl = "https://inkscape.org/gallery/item/56340/inkscape-1.4.2_2025-05-13_f4327f4-x64.msi"
        FallbackVersion = "1.4.2"
        FilenameTemplate = "inkscape-{0}-x64.msi"  # Simplified name for storage
        PackageType = "MSI"
        InstallCommandTemplate = 'msiexec /i "{0}" /qn ALLUSERS=1'
        UninstallCommandTemplate = 'msiexec /x {0} /qn'  # {0} will be MSI product code
        DetectionType = "MSI"
        DetectionOperator = "ProductCodeOnly"
        AutoUpdate = $false
    }
    
    Audacity = @{
        Name = "Audacity"
        DisplayNameTemplate = "Audacity {0}"
        Publisher = "Audacity Team"
        Description = "Audacity - Free, open source, cross-platform audio software"
        Folder = "audacity"
        IconFile = "audacity-logo.png"
        IntuneWinPattern = "audacity-*.intunewin"
        GitHubRepo = "audacity/audacity"
        GitHubApiUrl = "https://api.github.com/repos/audacity/audacity/releases/latest"
        GitHubAssetPattern = "audacity-win-[\d\.]+-64bit\.exe$"
        FallbackUrl = "https://github.com/audacity/audacity/releases/download/Audacity-3.7.5/audacity-win-3.7.5-64bit.exe"
        FallbackVersion = "3.7.5"
        FilenamePattern = "audacity-win-{0}-64bit.exe"
        PackageType = "EXE"
        InstallCommandTemplate = '"{0}" /VERYSILENT /ALLUSERS /NORESTART'
        UninstallCommandTemplate = '"C:\Program Files\Audacity\unins000.exe" /VERYSILENT'
        DetectionPath = "C:\Program Files\Audacity"
        DetectionFile = "Audacity.exe"
        DetectionType = "File"
        DetectionOperator = "greaterThanOrEqual"
        AutoUpdate = $false
    }
    
    LibreOffice = @{
        Name = "LibreOffice"
        DisplayNameTemplate = "LibreOffice {0} (German)"
        Publisher = "The Document Foundation"
        Description = "LibreOffice - Free and powerful office suite - German version (Enterprise/Business)"
        Folder = "libreoffice"
        IconFile = "libreoffice-logo.png"
        IntuneWinPattern = "LibreOffice_*.intunewin"
        DownloadPageUrl = "https://de.libreoffice.org/download/download/"
        DownloadUrlRegex = 'type=win-x86_64&version=([\d\.]+)&lang=de'
        DownloadUrlTemplate = "https://download.documentfoundation.org/libreoffice/stable/{0}/win/x86_64/LibreOffice_{0}_Win_x86-64.msi"  # {0}=version
        FallbackUrl = "https://download.documentfoundation.org/libreoffice/stable/25.2.7/win/x86_64/LibreOffice_25.2.7_Win_x86-64.msi"
        FallbackVersion = "25.2.7"
        FilenameTemplate = "LibreOffice_{0}_Win_x86-64.msi"
        PackageType = "MSI"
        InstallCommandTemplate = 'msiexec /i "{0}" /qn ALLUSERS=1'
        UninstallCommandTemplate = 'msiexec /x {0} /qn'  # {0} will be MSI product code
        DetectionType = "MSI"
        DetectionOperator = "ProductCodeOnly"
        AutoUpdate = $false
    }
    
    OpenShot = @{
        Name = "OpenShot"
        DisplayNameTemplate = "OpenShot {0}"
        Publisher = "OpenShot Studios, LLC"
        Description = "OpenShot Video Editor - Free, open-source video editor"
        Folder = "openshot"
        IconFile = "openshot-logo.png"
        IntuneWinPattern = "OpenShot-v*-x86_64.intunewin"
        GitHubRepo = "OpenShot/openshot-qt"
        GitHubApiUrl = "https://api.github.com/repos/OpenShot/openshot-qt/releases/latest"
        GitHubAssetPattern = "OpenShot-v[\d\.]+-x86_64\.exe$"
        FallbackUrl = "https://github.com/OpenShot/openshot-qt/releases/download/v3.3.0/OpenShot-v3.3.0-x86_64.exe"
        FallbackVersion = "3.3.0"
        FilenamePattern = "OpenShot-v{0}-x86_64.exe"
        PackageType = "EXE"
        InstallCommandTemplate = '"{0}" /S'
        UninstallCommandTemplate = '"C:\Program Files\OpenShot Video Editor\uninstall.exe" /S'
        DetectionPath = "C:\Program Files\OpenShot Video Editor"
        DetectionFile = "OpenShot Video Editor.exe"
        DetectionType = "File"
        DetectionOperator = "greaterThanOrEqual"
        AutoUpdate = $true
    }
    
    GeoGebra = @{
        Name = "GeoGebra"
        DisplayNameTemplate = "GeoGebra {0}"
        Publisher = "International GeoGebra Institute"
        Description = "GeoGebra - Dynamic mathematics software for all levels of education"
        Folder = "geogebra"
        IconFile = "geogebra-logo.png"
        IntuneWinPattern = "GeoGebra-Windows-Installer-6-*.intunewin"
        DownloadUrl = "https://download.geogebra.org/package/win-msi6"
        FallbackVersion = "6.0.906.2"
        FilenameTemplate = "GeoGebra-Windows-Installer-6-{0}.msi"
        PackageType = "MSI"
        InstallCommandTemplate = 'msiexec /i "{0}" ALLUSERS=2 /qn'
        UninstallCommandTemplate = 'msiexec /x {0} /qn'  # {0} will be MSI product code
        DetectionType = "Script"  # Use PowerShell script detection (MSI Product Code doesn't change between versions)
        DetectionOperator = "ScriptOnly"
        DetectionScriptPath = "packages\geogebra\Detect-GeoGebraVersion.ps1"  # Custom script to extract version from HTML files
        VersionExtraction = "AppLocker"  # Extract version after download using Get-AppLockerFileInformation
        SupersedenceType = "Replace"  # Use Replace instead of Update (uninstalls old version)
        AutoUpdate = $false  # GeoGebra Classic 6 does not auto-update in mass installations
        # Note: GeoGebra doesn't update MSI Product Code or GeoGebra.exe version between releases
        # Real version is stored in latestVersion variable in HTML files (main.js or ggb-config.js)
    }
    
    Stellarium = @{
        Name = "Stellarium"
        DisplayNameTemplate = "Stellarium {0}"
        Publisher = "Stellarium team"
        Description = "Stellarium - Free open source planetarium for your computer"
        Folder = "stellarium"
        IconFile = "stellarium-logo.png"
        IntuneWinPattern = "stellarium-*.intunewin"
        GitHubRepo = "Stellarium/stellarium"
        GitHubApiUrl = "https://api.github.com/repos/Stellarium/stellarium/releases/latest"
        GitHubAssetPattern = "stellarium-[\d\.]+-qt6-win64\.exe$"
        FallbackUrl = "https://github.com/Stellarium/stellarium/releases/download/v24.3/stellarium-24.3-qt6-win64.exe"
        FallbackVersion = "24.3"
        FilenamePattern = "stellarium-{0}-qt6-win64.exe"
        PackageType = "EXE"
        InstallCommandTemplate = '"{0}" /VERYSILENT /NORESTART /ALLUSERS'
        UninstallCommandTemplate = '"C:\Program Files\Stellarium\unins000.exe" /VERYSILENT /NORESTART'
        DetectionPath = "C:\Program Files\Stellarium"
        DetectionFile = "stellarium.exe"
        DetectionType = "File"
        DetectionOperator = "greaterThanOrEqual"
        AutoUpdate = $false
    }
    
    GoogleDrive = @{
        Name = "GoogleDrive"
        DisplayNameTemplate = "Google Drive {0}"
        Publisher = "Google LLC"
        Description = "Google Drive for Desktop - Access your Google Drive files directly from your computer"
        Folder = "googledrive"
        IconFile = "googledrive-logo.png"
        IntuneWinPattern = "GoogleDriveSetup-*.intunewin"
        DownloadUrl = "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe"
        FallbackVersion = "Latest"
        FilenameTemplate = "GoogleDriveSetup-{0}.exe"
        PackageType = "EXE"
        InstallCommandTemplate = '"{0}" --silent --desktop_shortcut --skip_launch_new --gsuite_shortcuts=false'
        UninstallCommandTemplate = '"C:\Program Files\Google\Drive File Stream\{0}\GoogleDriveFS.exe" --uninstall --silent'
        DetectionType = "Registry"
        DetectionPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{6BBB3539-2232-434A-A4E5-9A33560C6283}"
        DetectionValueName = "DisplayVersion"
        DetectionOperator = "greaterThanOrEqual"
        VersionExtraction = "AppLocker"
        AutoUpdate = $true
    }
}

# Common settings
$script:CommonSettings = @{
    Architecture = "x64"
    MinimumOS = "W11_21H2"
    InstallExperience = "system"
    RestartBehavior = "suppress"
    DetectionOperator = "greaterThanOrEqual"
    Check32BitOn64System = $false
}

# Export function to get app configuration
function Get-AppConfiguration {
    param(
        [Parameter(Mandatory=$true)]
        [string]$AppName
    )
    
    if (-not $script:AppConfigurations.ContainsKey($AppName)) {
        Write-Host "Unknown application: $AppName" -ForegroundColor Red
        Write-Host "Available applications: $($script:AppConfigurations.Keys -join ', ')" -ForegroundColor Yellow
        return $null
    }
    
    return $script:AppConfigurations[$AppName]
}

# Export function to get all app names
function Get-AllAppNames {
    return $script:AppConfigurations.Keys | Sort-Object
}

# Export function to get common settings
function Get-CommonSettings {
    return $script:CommonSettings
}
