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
- **McAfee removal** - one package that takes the preinstalled McAfee software off new devices (see [McAfee Removal](#mcafee-removal))
- **Multi-tenant support** with flexible authentication
- **Single-app or batch processing**

## Supported Applications

| Application | Type | Version Detection |
| --- | --- | --- |
| Mozilla Firefox (German) | EXE | Mozilla Product Details API |
| Google Chrome Enterprise | MSI | Web scraping (AppLocker XML) |
| 7-Zip | MSI | Winget manifest (SHA-256 pinned) |
| GIMP | EXE | Web scraping |
| VLC Media Player | EXE | Winget manifest (SHA-256 pinned) |
| Notepad++ | EXE | GitHub Releases |
| Affinity Studio | MSI | AppLocker XML extraction |
| Inkscape | MSI | Winget manifest (SHA-256 pinned) |
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
| McAfee Removal | Script | Own package version (assembled package, see [McAfee Removal](#mcafee-removal)) |

## Download Integrity

Every installer download is verified before it is packaged (`Invoke-FileDownload` → `Test-DownloadedFileIntegrity` in `SharedFunctions.ps1`); an unverified file is deleted and the app is skipped for that run. Only HTTPS URLs are accepted. There are two trust tiers:

1. **Authenticode-signed vendors** (default): the download must carry a *valid* Authenticode signature, and the certificate subject must contain the `ExpectedPublisher` configured in `AppConfig.ps1`.
2. **Unsigned/unreliably signed vendors** (7-Zip, VLC, Inkscape): version, download URL and SHA-256 are taken as one bundle from the package's community [winget manifest](https://github.com/microsoft/winget-pkgs) (`WingetPackageId` in `AppConfig.ps1`), which Microsoft's validation pipeline independently downloads, hashes and scans before merge. The download is verified against that pinned hash, and the manifest's URL must match the app's `AllowedDownloadUrlPrefixes` so a manifest can never redirect downloads away from the vendor's own infrastructure. If no manifest exists yet for a new release, the app is skipped until one is merged (typically hours to a few days) - for these apps that lag is accepted as a deliberate quarantine window.

The policy is enforced at load time: `AppConfig.ps1` refuses to load a configuration in which an app sets `AllowUnsignedInstaller` without a winget pin or an explicit `ExpectedSha256` (`Get-AppConfigPolicyViolation`). There is deliberately no unverified fallback URL for winget-pinned apps.

The [McAfee Removal](#mcafee-removal) package is assembled from two McAfee files instead of one installer. Both are held to both tiers at once: each must match a SHA-256 pinned in `AppConfig.ps1` **and** carry a valid Authenticode signature of McAfee, LLC. The load-time policy rejects the configuration when a pin, the publisher or an HTTPS URL is missing.

## Prerequisites

### Required Software

- Windows 10/11 or Windows Server 2016+
- PowerShell 7.4 or later (`winget install --id Microsoft.PowerShell --source winget`)
- Internet connection

### Required PowerShell Modules

```powershell
Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force
Install-Module -Name Microsoft.Graph.Groups -Scope CurrentUser -Force   # only needed for group assignments
```

Intune API calls are made natively through Microsoft Graph — no third-party Intune module is required.

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
- **7-Zip** - only for building the [McAfee Removal](#mcafee-removal) package (`winget install --id 7zip.7zip`); every other app is packaged without it

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
├── IntuneInterop.ps1                      # Native Microsoft Graph Intune API layer
├── IntuneSession.ps1                      # Tenant session bootstrap (credentials, modules, connect)
├── AppRetention.ps1                       # Version retention evaluation (inventory/cleanup)
├── AppInventory.ps1                       # Inventory assembly and analysis (pure)
├── IntuneInventory.ps1                    # Graph read path shared by inventory and cleanup
├── AppCleanup.ps1                         # Cleanup planner (pure)
├── IntuneCleanup.ps1                      # Cleanup executor + audit log (shared by cleanup and deploy)
├── Get-IntuneAppInventory.ps1             # Read-only tenant inventory script
├── Remove-OldIntuneAppVersions.ps1        # Retention-based cleanup script
├── inventory/                             # Inventory reports and cleanup logs (git-ignored)
├── TenantConfig.ps1                       # Secure tenant credential management
├── TenantDeployments.ps1                  # Per-tenant deployment plan loader
├── TenantDeployments.json                 # Per-tenant app/assignment plans (git-ignored)
├── TenantDeployments.example.json         # Deployment plan schema reference
├── AuthenticationManager.ps1              # Microsoft Graph authentication
├── Download-And-Package-Software.ps1      # Download & packaging script
├── McAfeeRemovalPackage.ps1               # Builder of the McAfee removal package
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
│   ├── mcafee-removal/
│   │   ├── Remove-McAfee.ps1              # removal script (in git)
│   │   ├── Detect-McAfeeRemoval.ps1       # detection rule (in git)
│   │   ├── MCPR-10.5.374.0.exe            # verified ingredient (downloaded)
│   │   ├── mccleanup-10.4.123.0.exe       # verified ingredient (downloaded)
│   │   └── McAfeeRemoval-1.0.0.intunewin
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
| `Retention` | Optional version-retention policy, on the tenant and/or on an app (see below) |

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

### Version Retention (inventory and cleanup)

Every deployment of a new version leaves the previous versions in Intune. That is what makes
supersedence work, but unbounded it hits Intune's supersedence-graph limit (11 nodes) and clutters
the Company Portal. A retention policy in the same plan file states how much history to keep:

```json
"Tenants": {
  "School": {
    "Retention": { "KeepNewest": 3, "KeepNewerThanWeeks": 10 },
    "Apps": {
      "Chrome": { "AllUsers": true, "AllDevices": true, "Retention": { "KeepNewest": 2 } }
    }
  }
}
```

A version is **kept** when it is among the newest `KeepNewest` versions **or** was still the
current version at some point within the last `KeepNewerThanWeeks` weeks — that is, the first
newer version was created less than that many weeks ago. The window is about devices, not about
a version's own age: a device that last checked in N weeks ago runs whatever was current back
then, and that version must still exist in Intune for supersedence and auto-update to pick the
device up. (A fast-moving app can have three builds younger than the window and still need last
month's build kept.) Defaults are 3 / 10 when omitted — choose the window by how long your
devices can stay away, e.g. 14 weeks for schools with long holidays; an app's block overrides
the tenant's, which overrides the defaults. `KeepNewest` can never go below 2 — Intune irrevocably
drops Company Portal auto-update tracking for a superseded app whose assignment disappears, so the
immediate predecessor must always survive. Always kept regardless of policy: dependency targets,
unparseable versions, and versions with an unknown creation date. Duplicate version numbers are
flagged for manual review, never deleted automatically — as is any version whose relationships
could not be read from Graph (it might be a dependency target the tooling cannot see; re-run the
inventory).

A tenant-level `Retention` block is the opt-in for automated cleanup: `Remove-OldIntuneAppVersions.ps1`
applies the policy to the whole tenant interactively, and `Deploy-ToIntune.ps1` applies it to
each family it deploys, unattended, right after the new version is in place (`-NoRetention` skips
that for a run). Without the block nothing is ever deleted; the inventory still reports what the
policy would do.

Only apps whose display name follows the family's naming convention (`DisplayNameTemplate` in
`AppConfig.ps1`, e.g. `Google Chrome 151` or `Mozilla Firefox 153 (German)`) count as versions of
that family. An app deployed by hand under a different name — a bare `Google Chrome`, or an
unrelated app that merely shares the prefix such as `Google Chrome Remote Desktop 2.0` — is not
managed by this tooling: it is never superseded and never deleted. To bring a hand-deployed
version under management, rename it in Intune to match the template.

### App Inventory

`Get-IntuneAppInventory.ps1` takes a **read-only** snapshot of a tenant's Win32 apps and writes
it to `inventory/` (git-ignored) as JSON plus a Markdown report:

```powershell
.\Get-IntuneAppInventory.ps1 -TenantName "School"                       # full inventory
.\Get-IntuneAppInventory.ps1 -TenantName "School" -AppName "Chrome"     # one family (only its apps and the unmanaged ones are read in detail)
.\Get-IntuneAppInventory.ps1 -TenantName "School" -SkipInstallSummary   # skip the install counts
```

For every app it records assignments (with the auto-update flag), supersedence and dependency
relationships, and the install summary; maps the app to its AppConfig family and version; and
evaluates the retention policy above. Per family it reports the version count, the size of the
supersedence graph against Intune's limit of 11 nodes, and the retention verdict for every
version (keep / delete candidate / review), plus anomalies:

- older versions assigned *available* but not superseded by any version (a chain split at the
  graph limit, or a version that was never linked) — the Company Portal hides superseded
  versions behind the newest one, but an unlinked one shows up as a separate app;
- superseding versions assigned *available* without auto-update although `AutoUpdate` is on;
- duplicate version numbers, unassigned newest versions, families near the graph limit;
- apps that look like a family but break the naming convention (with a rename suggestion).

Install counts on older versions of families with version-comparison detection
(`greaterThanOrEqual`, script rules) are inflated — a device with a newer version also detects
every older one — and are marked as such in the report. A superseded version keeping its
*available* assignment is normal and required (it is what keeps supersedence and auto-update
working); the report never flags that. Nothing is changed in Intune.

### Version Cleanup

`Remove-OldIntuneAppVersions.ps1` deletes what the inventory marks as delete candidates — the
versions outside the newest `KeepNewest` **and** older than `KeepNewerThanWeeks` — for every
family in the tenant's deployment plan, oldest version first. It always evaluates the tenant
live (the same read and analysis as the inventory; a saved report is never the authority for
a delete):

```powershell
.\Remove-OldIntuneAppVersions.ps1 -TenantName "School" -WhatIf            # preview, nothing changes
.\Remove-OldIntuneAppVersions.ps1 -TenantName "School"                    # confirms each deletion ("Yes to All" approves the rest)
.\Remove-OldIntuneAppVersions.ps1 -TenantName "School" -AppName "Chrome"  # one family
.\Remove-OldIntuneAppVersions.ps1 -TenantName "School" -Confirm:$false    # unattended
```

Guard rails, none of which a parameter can override:

- the tenant must opt in with a tenant-level `Retention` block in `TenantDeployments.json`
  (the script prints the snippet to add otherwise);
- only families in the tenant's deployment plan are touched; apps that do not follow the naming
  convention are not even considered;
- never deleted: the newest version, anything within the keep window, dependency targets,
  duplicate version numbers (`Review`), and versions whose relationships could not be read;
- after each confirmation the app's relationships are re-read, and an app that became a
  dependency target in the meantime is skipped untouched;
- every decision is logged to `inventory/<Tenant>-cleanup-<timestamp>.json` (one file per run,
  never overwritten).

Intune refuses to delete an app that is still part of a supersedence relationship, so the
script first unlinks the version — the version that supersedes it gets its relationship set
updated without it, exactly what "Remove relationship" in the admin center does — and then
deletes it. Nothing else in the chain is touched; it shrinks to the kept versions. Re-run the
inventory afterwards to verify. Recommended first run: `-WhatIf`, then one family, then the
full tenant.

#### Retention after deploy

For an opted-in tenant, `Deploy-ToIntune.ps1` runs the same evaluation and executor for each
family right after deploying it (new version created, or an existing one reconciled): the
family is re-read, and versions outside the policy are removed unattended — the one that was
rank 3 before the deploy and is rank 4 now, once it was superseded longer ago than the window.
The deployment summary reports what was removed, and every pass — also one that found nothing
to remove — writes the same `inventory/<Tenant>-cleanup-<timestamp>.json` log with
`Trigger: Deploy`. `-NoRetention` skips the step; `-ShowPlan` shows whether it would run.

The deploy also checks the supersedence graph *before* uploading: if the version to be
superseded already sits in a full graph (11 nodes), the app is not uploaded and the run tells
you to clean up first — and a supersedence that fails after the upload now fails the deployment
loudly (the new version is left unassigned, never as an unlinked Company Portal entry).

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

## McAfee Removal

Notebook manufacturers preinstall McAfee. `McAfeeRemoval` is a package that takes it off again, so that Microsoft Defender (configured through your Intune policies) is the device's antivirus. It removes:

- the classic suite (McAfee LiveSafe, Total Protection, Internet Security) and the newer "McAfee" app (WPS) that replaced it on current devices
- McAfee WebAdvisor / SiteAdvisor, Safe Connect, Security Scan Plus and True Key
- the McAfee Store apps (McAfee Personal Security, the shell integration package)
- what they leave behind: services, drivers, scheduled tasks, folders, shortcuts and registry keys

It does not touch McAfee's managed business products (ePolicy Orchestrator agent, VirusScan Enterprise): next to those it stops and changes nothing.

### How it behaves in Intune

The app is "installed" when no McAfee product is left. Its detection rule and the removal script use the same definition (`Get-McAfeeFootprint` in `packages/mcafee-removal/Detect-McAfeeRemoval.ps1`): an entry in *Installed apps*, a Store package (installed for a user, or provisioned in the Windows image for future users), a service or a driver means McAfee is present; folders and registry leftovers alone do not.

A device is only reported as free of McAfee when every one of these inventories could be read. If the Store package lists cannot be read, the detection answers "Cannot confirm that McAfee is gone" and the app is not detected: Intune checks again on its next cycle, and a McAfee Store app can never hide behind a failed read. The removal script follows the same rule and ends with exit code 1 instead of claiming success.

- A device **without McAfee** is detected at once. It never downloads the package and nothing runs.
- A device **with McAfee** runs `Remove-McAfee.ps1` as SYSTEM, without any dialog. This takes a few minutes.
- **A restart is part of the removal.** Files that are in use or protected by McAfee's drivers can only be deleted while Windows starts. The script then ends with exit code 3010, and Intune asks the user to restart - it never forces the restart (this app sets `RestartBehavior = "basedOnReturnCode"`; every other app keeps `suppress`). Only a real restart counts: shutting down with Fast Startup does not process the pending deletions.
- In the lab tests this package follows (see [Credits](#credits)), the classic suite was gone after that one restart, while **the newer McAfee app (WPS) needed a second run**: its main service is protected against being stopped, so the first run can only disable what surrounds it. After the restart Intune finds McAfee still present, runs the script again, and that run finishes the job. Until then the app shows as *pending restart* or *failed* in Intune - that is the expected intermediate state, not an error to act on.
- The script asks for a restart for at most two restarts in a row. If McAfee is still installed after that it ends with exit code 1, the app stays *failed*, and the log names what is left.

Deploy it as a required app for devices, in the tenant's deployment plan:

```json
"McAfeeRemoval": { "AllDevices": true }
```

If your Enrollment Status Page blocks device use until required apps are installed, keep this app out of the blocking apps: an app that needs a restart, and possibly a second run after it, is not "installed" at the point where the status page checks.

### Logs

Everything is written to the Intune Management Extension log folder, so **Collect diagnostics** in Intune returns it:

- `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\McAfeeRemoval.log` - what was found, each step with its exit code, what is left, the exit code of the run
- `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\McAfeeRemoval-mccleanup.log` - the very detailed log of McAfee's removal engine

### Try it on one device first

McAfee changes what it preinstalls, and no two device models carry quite the same set. Before assigning the app to all devices, look at one device of each model:

```powershell
# On the device, from the package folder: lists what is installed and what would be done, changes nothing
powershell.exe -ExecutionPolicy Bypass -File .\Remove-McAfee.ps1 -ReportOnly
```

Then assign the app to a test group (`"Groups": [{ "Name": "...", "Intent": "Required" }]`) and read `McAfeeRemoval.log` after the first run and after the restart. For products without a silent uninstaller the log also records the uninstall command the product registered - useful when a new McAfee generation needs a new approach.

### How the package is built

`Download-And-Package-Software.ps1 -AppName McAfeeRemoval` assembles the package (`McAfeeRemovalPackage.ps1`) from the two scripts in `packages/mcafee-removal/` and McAfee's own removal tool, MCPR. It needs **7-Zip** on the packaging machine and two McAfee files:

| Ingredient | Why | Source |
| --- | --- | --- |
| `MCPR.exe` 10.5.374.0 | The removal recipes for every McAfee consumer product. It is a self-extractor that only starts an interactive wizard, so it is unpacked with 7-Zip instead of being run. | McAfee's official download |
| `mccleanup.exe` 10.4.123.0 | The engine that executes the recipes. The engine inside current MCPR builds validates its parent process and removes nothing unless that wizard started it; 10.4.123.0 is the last build that runs unattended. It replaces the engine in the unpacked tool. | Community archives (McAfee no longer offers this build) |

Both files are pinned by SHA-256 in `AppConfig.ps1` and must carry McAfee's signature (see [Download Integrity](#download-integrity)). The verified files stay in the package folder and are re-verified on every build, so a build does not depend on the archives staying online; if they ever disappear, a copy of that `mccleanup.exe` saved as `packages/mcafee-removal/mccleanup-10.4.123.0.exe` is accepted on the same terms.

MCPR is pinned on purpose rather than taken as "latest": when McAfee publishes a new build, the packaging run stops and says so. Review the new build, then update `McprVersion` and `McprSha256`.

The version of the package is declared in `Remove-McAfee.ps1` (`$script:McAfeeRemovalVersion`). **Raise it with every change** to the two scripts or to the pins: a changed package under an unchanged version is never rolled out, because the deployment finds the version already in Intune. A new version supersedes the old one like any other app; devices where McAfee is already gone are detected by the new version too and run nothing.

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
- **McAfee Removal**: Assembled from scripts and pinned McAfee ingredients instead of one installer; asks for a restart through exit code 3010

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
- Old versions in Intune: `Get-IntuneAppInventory.ps1` shows what the retention policy would
  remove, `Remove-OldIntuneAppVersions.ps1` removes it (see [Version Cleanup](#version-cleanup))

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

- **IntuneWinAppUtil**: Microsoft Win32 Content Prep Tool
- **IntuneWin32App Module** by [Nickolaj Andersen](https://github.com/MSEndpointMgr/IntuneWin32App): powered deployments through v3.1; the native Graph implementation in `IntuneInterop.ps1` was informed by its request sequences
- **McAfee Removal for Intune** by [Kevin Malinoski](https://github.com/kevinmalinoski/Intune-Blog-Resources/tree/main/McAfee%20Removal), building on Tbone and SMB to the Cloud: documented that current MCPR engines refuse unattended runs and lab-tested the engine build and product list the McAfee removal package uses
- **Development Assistance**: Created with assistance from GitHub Copilot (Claude Sonnet 4.5)
