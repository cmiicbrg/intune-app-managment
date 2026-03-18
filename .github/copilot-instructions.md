# Project Guidelines

## Language & Runtime

- PowerShell 5.1 compatibility is required (ships with Windows 10/11)
- Do not use PowerShell 7+ features (ternary operator, null-coalescing, `&&`, parallel foreach, etc.)
- Use `[System.Security.Cryptography.*]` .NET classes available in .NET Framework 4.x

## Architecture

- **Single-checkout model**: Only one copy of this repository is used per PowerShell session. The credential cache (`$global:__IntuneCachedMasterKey`, `$global:__IntuneCachedTenantSecrets`) is intentionally session-global so that consecutive `Deploy-ToIntune.ps1` runs don't re-prompt for the master password. Do not suggest scoping the cache per config file path — this is a deliberate design trade-off documented in TenantConfig.ps1 and README.md.
- **Cache invalidation is by design minimal**: The cached master key and tenant secrets are not revalidated against `intune-tenants.json` on each use. Out-of-band config changes (manual file edits, git pulls) require `Clear-IntuneTenantCache` or a new PowerShell session. Client-secret rotation uses the documented remove+re-add flow (`Remove-IntuneTenant` then `Add-IntuneTenant`), which clears the relevant cache entries. Do not suggest adding cache-invalidation logic or config-file change detection.
- `TenantConfig.ps1` is dot-sourced by `Deploy-ToIntune.ps1` — `$script:` scoped variables would not persist across runs, which is why `$global:` is used for caching.
- `AppConfig.ps1` defines all application metadata as a hashtable. New apps are added there.

## Cryptography Design Decisions

- **AES-256-CBC without HMAC** is intentional. This is a PowerShell 5.1 compatibility choice — AES-GCM requires .NET Core / PowerShell 7+. The threat model is casual exposure (accidental commits, screen visibility), not active attackers with filesystem write access. Tampering with the ciphertext produces garbage that fails at the Graph API authentication step, not a security breach. Do not suggest adding HMAC or switching to AES-GCM.
- **PBKDF2 with 100,000 iterations and SHA-256** for key derivation — meets OWASP recommendations.
- `Unprotect-Secret` catches all exceptions and returns `$null` — no padding oracle is possible.

## Code Patterns

- Use `SecureString` + `SecureStringToBSTR` for user-facing password input; internal crypto helpers accept plain strings (suppressed via `PSScriptAnalyzer` attributes at file level).
- Always dispose `IDisposable` crypto objects (`Rfc2898DeriveBytes`, `Aes`, `ICryptoTransform`, `RandomNumberGenerator`) in `try/finally` blocks.
- Always free BSTR pointers with `ZeroFreeBSTR` in `finally` blocks.
- `Read-TenantConfig` throws on parse/schema errors rather than returning empty config (prevents silent data loss on corrupt JSON).

## Build & Test

- Syntax validation: `[System.Management.Automation.Language.Parser]::ParseFile()` — used in CI via `.github/workflows/pwsh-validate.yml`
- No Pester test suite currently
