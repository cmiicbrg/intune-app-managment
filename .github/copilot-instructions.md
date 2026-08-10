# Project Guidelines

## Language & Runtime

- PowerShell 7.4+ (LTS) is required. Entry-point and dot-sourced scripts carry `#Requires -Version 7.4`; the only exception is `Setup-Prerequisites.ps1`, which must run on Windows PowerShell 5.1 so it can tell users how to install PowerShell 7.
- Modern syntax (ternary operator, null-coalescing, `&&`/`||`, `clean` blocks) is allowed and preferred where it improves readability. Don't rewrite working code just to modernize it.
- `[System.Security.Cryptography.*]` .NET 8 classes are available (including `AesGcm`).

## Architecture

- **Single-checkout model**: Only one copy of this repository is used per PowerShell session. The credential cache (`$global:__IntuneCachedMasterKey`, `$global:__IntuneCachedTenantSecrets`) is intentionally session-global so that consecutive `Deploy-ToIntune.ps1` runs don't re-prompt for the master password. Do not suggest scoping the cache per config file path — this is a deliberate design trade-off documented in TenantConfig.ps1 and README.md.
- **Cache invalidation is by design minimal**: The cached master key and tenant secrets are not revalidated against `intune-tenants.json` on each use. Out-of-band config changes (manual file edits, git pulls) require `Clear-IntuneTenantCache` or a new PowerShell session. Client-secret rotation uses the documented remove+re-add flow (`Remove-IntuneTenant` then `Add-IntuneTenant`), which clears the relevant cache entries. Do not suggest adding cache-invalidation logic or config-file change detection.
- `TenantConfig.ps1` is dot-sourced by `Deploy-ToIntune.ps1` — `$script:` scoped variables would not persist across runs, which is why `$global:` is used for caching.
- `AppConfig.ps1` defines all application metadata as a hashtable. New apps are added there.

## Cryptography Design Decisions

- **AES-256-GCM** (AEAD) protects client secrets in `intune-tenants.json`. Blob layout (base64): salt (16 bytes) + nonce (12 bytes) + tag (16 bytes) + ciphertext. The GCM tag authenticates the ciphertext, so a wrong password or tampering is detected deterministically at decrypt time. The threat model remains casual exposure (accidental commits, screen visibility), not active attackers with filesystem write access.
- **PBKDF2 with 600,000 iterations and SHA-256** for key derivation — meets current OWASP recommendations. Uses the static `[Rfc2898DeriveBytes]::Pbkdf2()` method.
- **Config format version 3 is the only supported format.** `intune-tenants.json` carries a top-level `"version": 3`. Older (v2.x, AES-CBC) files are rejected with instructions to re-add tenants — there is intentionally no migration or legacy-decrypt path. Do not suggest adding backward compatibility for pre-3.0 configs.
- `Unprotect-Secret` catches `CryptographicException` and returns `$null` on wrong password or tampered data.

## Code Patterns

- `AutoUpdate` in `AppConfig.ps1` controls whether the Intune assignment setting "If superseded app(s) have been installed by the user from Company Portal, require superseding app to be installed" is enabled. It does **not** control `DetectionOperator` — those are independent properties. `DetectionOperator` determines version comparison logic (`greaterThanOrEqual`, `equal`, `ProductCodeOnly`, `ScriptOnly`) and is set explicitly per app.
- Use `SecureString` + `SecureStringToBSTR` for user-facing password input; internal crypto helpers accept plain strings (suppressed via `PSScriptAnalyzer` attributes at file level).
- Always dispose `IDisposable` crypto objects (`AesGcm`, `RandomNumberGenerator`) in `try/finally` blocks.
- Always free BSTR pointers with `ZeroFreeBSTR` in `finally` blocks.
- `Read-TenantConfig` throws on parse/schema errors rather than returning empty config (prevents silent data loss on corrupt JSON).

## Build & Test

- Syntax validation: `[System.Management.Automation.Language.Parser]::ParseFile()` — used in CI via `.github/workflows/pwsh-validate.yml`
- No Pester test suite currently
