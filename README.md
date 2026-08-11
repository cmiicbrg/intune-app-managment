# Intune Software Deployment Automation

Automated download, packaging, and deployment of Windows applications to Microsoft Intune.

## ⚠️ Upgrading from 2.x

Version 3.0.0 is a **breaking release**: the baseline moved from Windows PowerShell 5.1 to PowerShell 7.4+, and tenant secrets are now encrypted with AES-256-GCM. Old `intune-tenants.json` files (AES-CBC, no `version` field) are rejected — there is no migration path.

To upgrade:

1. Install PowerShell 7.4+ if needed: `winget install --id Microsoft.PowerShell --source winget`
2. Open your old `intune-tenants.json` and copy each tenant's name, `tenantId`, and `clientId` (these are stored in plain text — only the secret is encrypted)
3. Delete `intune-tenants.json`
4. Re-add each tenant: `. .\TenantConfig.ps1` then `Add-IntuneTenant -Name "YourTenant" -TenantId "..." -ClientId "..."` — you'll need the client secret from the Azure portal (create a new one if you no longer have the value)

## Features

- **Automatic version detection** for 20 applications
- **Silent installation** with pre-configured commands
- **Supersedence management** - automatically replaces older versions
- **Icon support** for Company Portal
- **Multi-tenant support** with flexible authentication
- **Single-app or batch processing**

## Supported Applications

| Application | Type | Version Detection |
| --- | --- | --- |
| Mozilla Firefox (German) | EXE | Mozilla Product Details API |
| Google Chrome Enterprise | MSI | Web scraping (AppLocker XML) |
| 7-Zip | MSI | GitHub Releases |
| GIMP | EXE | Web scraping |
| VLC Media Player | EXE | Web scraping |
| Notepad++ | EXE | GitHub Releases |
| Affinity Studio | MSI | AppLocker XML extraction |
| Inkscape | MSI | Web scraping |
| Audacity | EXE | GitHub Releases |
| LibreOffice (German) | MSI | Web scraping (Enterprise version) |
| OpenShot Video Editor | EXE | GitHub Releases |
| KeePassXC | EXE | GitHub Releases |
| GeoGebra | MSI | Direct download (version in filename) |
| Stellarium | EXE | GitHub Releases |
| Google Drive | EXE | AppLocker XML extraction |
| Google Earth Pro | EXE | Web scraping (Release notes) |
| GPG4Win (Kleopatra) | EXE | Direct download |
| Visual C++ Redistributable | EXE | Web scraping (Microsoft) |
| NextExam Teacher | MSI | Manual update |
| NextExam Student | MSI | Manual update |

## Prerequisites

### Required Software

- Windows 10/11 or Windows Server 2016+
- PowerShell 7.4 or later (`winget install --id Microsoft.PowerShell --source winget`)
- Internet connection

### Required PowerShell Modules

```powershell
Install-Module -Name IntuneWin32App -Scope CurrentUser -Force
Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force
```

### Required Azure AD App Registration (Recommended)

**App-based authentication is the preferred method** for automated deployments and avoids interactive authentication issues.

#### Step 1: Create App Registration

1. Sign in to [Azure Portal](https://portal.azure.com) as **Global Administrator**
2. Navigate to **Azure Active Directory** → **App registrations**
3. Click **+ New registration**
4. Configure the registration:
   - **Name**: `Intune Software Deployment` (or any descriptive name)
   - **Supported account types**: `Accounts in this organizational directory only (Single tenant)`
   - **Redirect URI**: Leave empty
5. Click **Register**

#### Step 2: Note the Application (client) ID

1. On the app's **Overview** page, copy the **Application (client) ID**
2. Also copy the **Directory (tenant) ID**
3. Save these values - you'll need them later

#### Step 3: Create a Client Secret

1. In the left menu, click **Certificates & secrets**
2. Click **+ New client secret**
3. Configure the secret:
   - **Description**: `IntuneDeploymentKey` (or any descriptive name)
   - **Expires**: Select expiration period (recommend: 24 months)
4. Click **Add**
5. **IMPORTANT**: Copy the **Value** immediately - it won't be shown again!
6. Store the secret securely (e.g., password manager)

#### Step 4: Grant API Permissions

1. In the left menu, click **API permissions**
2. Click **+ Add a permission**
3. Select **Microsoft Graph**
4. Select **Application permissions** (not Delegated)
5. Search for and add these permissions:
   - `DeviceManagementApps.ReadWrite.All`
   - `DeviceManagementConfiguration.ReadWrite.All` (optional, for assignments)
   - `Group.Read.All` (required for custom group assignments)
6. Click **Add permissions**
7. Click **✓ Grant admin consent for [Your Organization]**
8. Confirm by clicking **Yes**
9. Verify all permissions show green checkmarks under "Status"

#### Step 5: Save Tenant Configuration (Recommended)

Instead of passing secrets on the command line, save your tenant configuration securely:

```powershell
# Import the tenant configuration module
. .\TenantConfig.ps1

# Add your tenant (interactive wizard with credential testing)
Add-IntuneTenant -Name "School"
```

The wizard will:

1. Guide you through finding your Tenant ID and creating an app registration
2. Prompt for your Client Secret (entered securely, not shown)
3. **Test the credentials** before saving
4. Encrypt the secret with a master password you choose
5. Save to `intune-tenants.json` (excluded from git)

**Session workflow:**

- First command in a new PowerShell session prompts for your encryption password
- Password is cached in memory for the session (no repeated prompts)
- Secrets never appear in command history or process lists

#### Alternative: Direct Credentials (for CI/CD)

For automated pipelines, you can still pass credentials directly:

```powershell
.\Deploy-ToIntune.ps1 -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -AppName "Chrome"
```

> **Note:** `Deploy-ToIntune.ps1` currently supports only client-secret-based authentication
> (via stored tenant credentials or direct parameters as shown above). An interactive
> user sign-in flow is **not** available at this time.

### Required Files

- **`IntuneWinAppUtil.exe`** - [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases)
  - ⚠️ **Not included** - Download separately from Microsoft
  - Place in the script directory before running
  - Latest version: Check releases page above
- `AppConfig.ps1` - Application configuration (included)
- `SharedFunctions.ps1` - Common functions (included)
- `TenantConfig.ps1` - Secure tenant credential management (included)

## Quick Start

### 1. Configure Your Tenant (One-Time Setup)

```powershell
# Import tenant configuration module
. .\TenantConfig.ps1

# Add a tenant - interactive wizard guides you through Azure AD setup
Add-IntuneTenant -Name "School"
```

### 2. Download and Package Software

Download latest versions and create IntuneWin packages:

```powershell
# All applications
.\Download-And-Package-Software.ps1

# Single application
.\Download-And-Package-Software.ps1 -AppName "Chrome"
```

### 3. Deploy to Intune

Upload packages to Intune with automatic configuration:

```powershell
# Deploy the tenant's apps from its deployment plan (see "Per-Tenant Deployment Plans")
.\Deploy-ToIntune.ps1 -TenantName "School"

# Preview first - shows apps and assignments, connects to nothing, needs no password
.\Deploy-ToIntune.ps1 -TenantName "School" -ShowPlan

# Deploy all applications with one assignment for every app (ignores the plan)
.\Deploy-ToIntune.ps1 -TenantName "School" -AssignToAllUsers

# Deploy single application
.\Deploy-ToIntune.ps1 -TenantName "School" -AppName "Chrome" -AssignToAllUsers

# Deploy to devices instead of users
.\Deploy-ToIntune.ps1 -TenantName "School" -AssignToAllDevices
```

### Alternative: Direct Credentials (CI/CD Pipelines)

For automated deployments where secrets come from environment variables or vault:

```powershell
.\Deploy-ToIntune.ps1 `
    -TenantId $env:INTUNE_TENANT_ID `
    -ClientId $env:INTUNE_CLIENT_ID `
    -ClientSecret $env:INTUNE_CLIENT_SECRET `
    -AssignToAllUsers
```

## Usage Examples

### Download Only

```powershell
# Download and package all apps
.\Download-And-Package-Software.ps1

# Download specific app
.\Download-And-Package-Software.ps1 -AppName "Firefox"
```

### Deploy to Multiple Tenants

```powershell
# Configure tenants once
. .\TenantConfig.ps1
Add-IntuneTenant -Name "School"
Add-IntuneTenant -Name "District"

# Deploy to different tenants (same encryption password for both)
.\Deploy-ToIntune.ps1 -TenantName "School" -AssignToAllUsers
.\Deploy-ToIntune.ps1 -TenantName "District" -AssignToAllDevices

# List configured tenants
Get-AllIntuneTenants
```

### Update Existing Apps

```powershell
# Download new versions
.\Download-And-Package-Software.ps1

# Deploy updates (new versions supersede old ones automatically)
.\Deploy-ToIntune.ps1 -TenantName "School"
```

## File Structure

```pre
intune-app-management/
├── AppConfig.ps1                          # Application configuration
├── AppVersions.json                       # Version cache (machine-maintained)
├── SharedFunctions.ps1                    # Shared functions
├── IntuneInterop.ps1                      # Boundary to the IntuneWin32App module
├── TenantConfig.ps1                       # Secure tenant credential management
├── TenantDeployments.ps1                  # Per-tenant deployment plan loader
├── TenantDeployments.json                 # Per-tenant app/assignment plans (git-ignored)
├── TenantDeployments.example.json         # Deployment plan schema reference
├── AuthenticationManager.ps1              # Microsoft Graph authentication
├── Download-And-Package-Software.ps1      # Download & packaging script
├── Deploy-ToIntune.ps1                    # Deployment script
├── VERSION.txt                            # Version tracking
├── intune-tenants.json                    # Encrypted tenant config (git-ignored)
├── packages/                              # Application packages
│   ├── firefox/
│   │   ├── Firefox-Setup-145.0.2-de.exe
│   │   ├── Firefox-Setup-145.0.2-de.intunewin
│   │   └── firefox-logo.png
│   ├── chrome/
│   │   ├── GoogleChrome-142.0-Enterprise-x64.msi
│   │   └── GoogleChrome-142.0-Enterprise-x64.intunewin
│   └── ... (other apps)
└── LICENSE
```

## Configuration

### Adding a New Application

Edit `AppConfig.ps1` and add a new configuration block:

```powershell
NewApp = @{
    Name = "NewApp"
    DisplayNameTemplate = "New App {0}"
    Publisher = "Publisher Name"
    Description = "App description"
    Folder = "newapp"
    IconFile = "newapp-logo.png"
    IntuneWinPattern = "newapp-*.intunewin"
    DownloadUrl = "https://example.com/download"
    FilenameTemplate = "newapp-{0}.exe"
    PackageType = "EXE"
    InstallCommandTemplate = '"{0}" /S'
    UninstallCommandTemplate = '"C:\Program Files\NewApp\uninstall.exe" /S'
    DetectionPath = "C:\Program Files\NewApp"
    DetectionFile = "newapp.exe"
    DetectionType = "File"
    DetectionOperator = "greaterThanOrEqual"
    AutoUpdate = $true  # Enable "require superseding app" on Intune assignments
}
```

### Customizing Settings

Edit `AppConfig.ps1` to modify:

- Download URLs and version detection methods
- Install/uninstall commands
- Detection rules
- Version formats
- Auto-update behavior

### Per-Tenant Deployment Plans

`Deploy-ToIntune.ps1`'s assignment switches apply to **every app in a run**, so a tenant where Chrome
needs All Users + All Devices, KeePassXC needs All Users, and an exam tool needs a group assignment
cannot be deployed in one command — it takes one hand-run command line per app.

A deployment plan makes that declarative. Copy `TenantDeployments.example.json` to
`TenantDeployments.json` (git-ignored, because it names real tenants and Entra ID groups) and list
each tenant's apps:

```json
{
  "Tenants": {
    "School": {
      "Apps": {
        "Chrome":          { "AllUsers": true, "AllDevices": true },
        "KeePassXC":       { "AllUsers": true },
        "VCRedist":        { },
        "NextExamTeacher": { "Groups": [{ "Name": "Teachers", "Intent": "Required" }] }
      }
    }
  }
}
```

Then the whole tenant deploys with one command:

```powershell
.\Deploy-ToIntune.ps1 -TenantName "School" -ShowPlan   # preview, no credentials needed
.\Deploy-ToIntune.ps1 -TenantName "School"             # deploy
```

Schema:

| Key | Meaning |
| --- | --- |
| `AllUsers` | Assign to All Users with intent `available` |
| `AllDevices` | Assign to All Devices with intent `required` |
| `Groups` | Array of `{ "Name": ..., "Intent": "Available" \| "Required" }`. `Intent` defaults to `Available` |
| `{ }` | Deploy with no assignment — for dependency-only apps such as `VCRedist` |

Notes:

- App names must match the keys in `AppConfig.ps1` and are matched case-insensitively, but an
  unknown name is a **hard error** naming the tenant and the bad key. A silently skipped app is
  the failure mode this replaces.
- Precedence: passing `-AssignToAllUsers`, `-AssignToAllDevices` or `-AssignToGroupName` ignores the
  plan entirely and behaves exactly as before, so existing command lines keep working. `-AppName`
  narrows a plan run to one app while keeping that app's assignments from the plan.
- Assignments are reconciled even when the app version is already in Intune. Adopting a plan for
  apps you have already deployed therefore applies the new assignments instead of skipping them;
  targets that are already assigned are left alone rather than duplicated.
- `AllUsers` and `AllDevices` must be JSON booleans. `"AllUsers": "false"` is rejected rather than
  coerced — PowerShell treats every non-empty string as true, so guessing here would assign an app
  to the whole tenant.
- With no plan file, or no entry for the tenant, the script behaves exactly as it did before.
- Dependencies still resolve against the full app list, so a tenant that lists `KeePassXC` without
  `VCRedist` still gets VCRedist auto-deployed.

### Version Cache

Every app config carries a `FallbackVersion` / `FallbackUrl` pair, used only when live version
detection fails (vendor site down, API rate-limited, download page restructured). Left alone these
go stale, so the safety net degrades exactly when you need it — which is what happened when 7-Zip
moved to GitHub Releases and the fallback was still pointing at a 2024 build.

`Download-And-Package-Software.ps1` therefore records the version, URL and filename of every
installer it successfully downloads **and verifies** into `AppVersions.json`. `AppConfig.ps1`
overlays those onto the fallbacks at load time, so they track reality on their own.

```powershell
# Opt out for a run (e.g. in CI) and leave AppVersions.json untouched
.\Download-And-Package-Software.ps1 -NoVersionCacheUpdate
```

Notes:

- `AppVersions.json` is machine-maintained — edit the seed values in `AppConfig.ps1` instead.
- Where both parse as version numbers, the **higher** of seed and cache wins, so a stale cache can
  never drag a freshly pulled `AppConfig.ps1` backwards.
- Deleting the file is safe; it regenerates on the next run.

#### Keeping pulls conflict-free

Because the file changes on every machine that runs a download, two clones will diverge. It holds
nothing but regenerable data, so `.gitattributes` marks it `merge=ours` — your local values win on
a pull rather than conflicting. This needs a one-time setting per clone, which
`Setup-Prerequisites.ps1` applies for you:

```powershell
git config merge.ours.driver true
```

Without it you get an ordinary conflict confined to `AppVersions.json`, safe to resolve either way:
the next download run re-syncs it to whatever the vendors are actually shipping. This is
deliberately **not** applied to `AppConfig.ps1`, where it would silently discard upstream changes
such as newly added applications.

## Features in Detail

### Version Detection Methods

| Method | Applications |
| --- | --- |
| **Mozilla API** | Firefox |
| **GitHub Releases** | 7-Zip, Notepad++, Audacity, OpenShot, KeePassXC, Stellarium |
| **Web Scraping** | GIMP, VLC, Inkscape, LibreOffice, Google Earth Pro, Visual C++ Redist |
| **AppLocker XML** | Chrome, Google Drive, Affinity Studio |
| **Direct Download** | GeoGebra, GPG4Win |
| **Manual Update** | NextExam Teacher, NextExam Student |

### Special Handling

- **Affinity Studio**: Automatic MSI extraction from EXE with user dialog
- **Inkscape**: Two-step download (main page → platforms page)
- **LibreOffice**: Enterprise version selection (stable vs. fresh)
- **Chrome**: File-based detection for auto-update support
- **GeoGebra**: PowerShell script detection (MSI product code doesn't change between versions)
- **KeePassXC**: Custom install script with silent INI config deployment
- **Google Earth Pro**: Uses OMAHA=1 flag for built-in auto-update

### Supersedence

- Automatically detects older versions in Intune
- Creates supersedence relationships with "Update" behavior
- Flexible version matching across different naming conventions

### Icons

- Optional PNG/JPG icons for Company Portal
- Automatic base64 conversion
- Configure per-app with `IconFile` property

## Troubleshooting

### Module Installation Issues

```powershell
# Update PowerShellGet first
Install-Module -Name PowerShellGet -Force -AllowClobber
# Restart PowerShell, then install required modules
```

### Download Fails

- Check internet connection
- Verify download URLs in `AppConfig.ps1`
- Check for filename validation errors in output

### Deployment Fails

Error: **"Application with identifier 'd1ddf0e4-d672-4dae-b554-9d5bdfd93547' was not found"**

This error occurs with interactive authentication when the Microsoft Graph PowerShell app is not registered in your tenant.

**Solution**: Use app-based authentication instead (recommended):

1. Follow the **Azure AD App Registration** steps in Prerequisites
2. Deploy with: `.\Deploy-ToIntune.ps1 -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret`

Error: **"Intune service request for operation 'AzureStorageUriRequest' failed"**

This error indicates Azure Storage upload failures, typically caused by:

**Rate Limiting/Throttling**: Most common cause - tenant has hit upload limits

**Symptoms:**

- App metadata is created in Intune portal but without installer package
- Error message: "Das Argument ist NULL oder leer" (The argument is NULL or empty)
- Multiple apps fail to upload in succession
- Works fine in another tenant or after waiting

**Solution:**

1. **Wait 1-2 hours** (or until next day) before retrying
2. **Delete incomplete apps** from Intune portal (apps without installers)
3. **Space out deployments**: Deploy 1-2 apps at a time with 30-second delays
4. **Avoid rapid retries**: Retrying immediately makes throttling worse

**Prevention:**

- Deploy large apps (>200 MB) one at a time
- Wait 30-60 seconds between app deployments
- Avoid uploading multiple versions of the same app in short succession
- Clean up old/duplicate apps regularly

**Note**: Microsoft does not provide a way to check current quota usage. Throttling limits typically reset after 1-2 hours.

**Other authentication issues:**

- Verify app permissions were granted admin consent
- Check client secret hasn't expired (in Azure Portal → App registrations → Your app → Certificates & secrets)
- Ensure TenantId, ClientId, and ClientSecret are correct
- Verify account has Intune Administrator role

**General deployment issues:**

- Ensure .intunewin files exist in app folders
- Check app folder names match configuration in `AppConfig.ps1`
- Verify network connectivity to Intune service

### Version Already Exists

- Script skips if version already packaged (by design)
- Delete old .intunewin file to force re-packaging
- Check for existing MSI/EXE before downloading

## Maintenance

### Monthly Updates

```powershell
# 1. Download latest versions
.\Download-And-Package-Software.ps1

# 2. Deploy to Intune
.\Deploy-ToIntune.ps1 -TenantName "School"
```

### Cleanup Old Versions

- Old installer files are automatically removed after packaging
- Old .intunewin files are kept (one per version)
- Manually retire old versions in Intune portal if needed

### Tenant Management

```powershell
# Import module
. .\TenantConfig.ps1

# List all configured tenants
Get-AllIntuneTenants

# Remove a tenant
Remove-IntuneTenant -Name "OldTenant"

# Clear cached credentials (e.g., before leaving workstation)
Clear-IntuneTenantCache
```

## Security Considerations

- **Tenant Configuration File** (`intune-tenants.json`):
  - Client secrets are AES-256-GCM encrypted (authenticated encryption) with PBKDF2 key derivation (600,000 iterations, SHA-256)
  - Each secret has a unique random salt and nonce; tampering or a wrong password is detected via the GCM authentication tag
  - File is portable — can be copied to other machines
  - **Excluded from git** via `.gitignore`
  - Master password is cached in memory only (global PowerShell variable), never written to disk
  
- **Session Security**:
  - Decrypted secrets exist only in memory during PowerShell session
  - Run `Clear-IntuneTenantCache` before leaving workstation
  - Closing PowerShell automatically clears cached credentials
  - **One checkout per session**: The credential cache is session-global. Do not use multiple copies of this repository in the same PowerShell window — use separate sessions instead
  
- **App Registration Secrets**:
  - Set appropriate expiration periods (e.g., 24 months)
  - Rotate secrets before expiration (delete and re-add tenant)
  - Use different app registrations per environment (dev/test/prod)
  
- **Permissions**:
  - Use least privilege - app registration only needs `DeviceManagementApps.ReadWrite.All`
  - For users: Intune Administrator role (not Global Administrator)
  - Regularly review API permissions in Azure AD
  
- **Audit**:
  - Enable Intune audit logging
  - Monitor app registration sign-in logs in Azure AD

## Time Estimates

- **Download & Package**: 10-30 minutes (all apps, depends on connection)
- **Deploy to Intune**: 5-15 minutes (all apps)
- **Single App**: 2-5 minutes per app

## Support

For issues or questions:

1. Check script output for error messages
2. Review Intune portal for deployment status
3. Verify configuration in `AppConfig.ps1`
4. Check Azure AD sign-in logs for authentication issues

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

Third-party software notices - see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Credits

- **IntuneWin32App Module**: [Nickolaj Andersen](https://github.com/MSEndpointMgr/IntuneWin32App)
- **IntuneWinAppUtil**: Microsoft Win32 Content Prep Tool
- **Development Assistance**: Created with assistance from GitHub Copilot (Claude Sonnet 4.5)
