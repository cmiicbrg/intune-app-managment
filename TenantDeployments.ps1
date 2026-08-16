#Requires -Version 7.4

# TenantDeployments.ps1
# Per-tenant deployment plans: which apps a tenant gets, and how each one is assigned.
#
# Deploy-ToIntune.ps1 applies its -AssignToAllUsers / -AssignToAllDevices / -AssignToGroupName
# switches to every app in a run, so apps needing different assignments used to require one
# hand-run command each. A plan makes that declarative: one entry per app, one command per tenant.
#
# The plan lives in TenantDeployments.json (git-ignored, like intune-tenants.json, because it names
# real tenants and Entra ID groups). TenantDeployments.example.json documents the schema.
#
# The same file also carries the optional version-retention policy ("Retention" blocks per tenant,
# overridable per app) that the inventory and cleanup tooling evaluate. Deploy-ToIntune.ps1 only
# validates those blocks; it never deletes anything.

# Import configuration for app-name validation, unless a caller already loaded it.
# Deploy-ToIntune.ps1 dot-sources SharedFunctions.ps1, which dot-sources AppConfig.ps1, so an
# unconditional import here would rebuild $script:AppConfigurations and re-run the version-cache
# overlay a second time on every run for no benefit.
if (-not (Get-Command Get-AllAppNames -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "AppConfig.ps1")
}

$script:TenantDeploymentsPath = Join-Path $PSScriptRoot "TenantDeployments.json"

# True when a plan file is present. Deliberately does not parse it: callers that are about to
# ignore the plan (because explicit assignment switches were supplied) must not be blocked by a
# malformed file or a stale app name in a tenant they are not even deploying.
function Test-TenantDeploymentPlanFile {
    return (Test-Path $script:TenantDeploymentsPath)
}

# Reads the deployment plan for a tenant.
#
# Returns an ordered hashtable of canonical app name -> assignment spec:
#     @{ AllUsers = $bool; AllDevices = $bool; Groups = @(@{Name=''; Intent=''}) }
# Returns $null when there is no plan file, or the file has no entry for this tenant - callers
# treat that as "no plan" and fall back to their previous behaviour.
#
# Throws on a malformed file or an unknown app name. A silently skipped app is precisely the
# failure mode this is meant to replace, so bad input must be loud.
function Get-TenantDeploymentPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantName
    )

    $tenant = Get-TenantDeploymentEntry -TenantName $TenantName
    if ($null -eq $tenant) {
        return $null
    }
    $tenantKey = $tenant.Key
    $tenantEntry = $tenant.Entry

    if (-not $tenantEntry.Apps) {
        throw "Tenant '$tenantKey' in '$script:TenantDeploymentsPath' has no 'Apps' object."
    }

    # A malformed tenant-level Retention block fails here, at plan load, like every other input error
    $tenantPolicy = ConvertTo-RetentionPolicy -Spec $tenantEntry -Base $script:DefaultRetentionPolicy -Context $tenantKey

    # Canonical app names, for case-insensitive resolution of entries like "Gimp" or "Openshot"
    $knownApps = @(Get-AllAppNames)

    $plan = [ordered]@{}
    foreach ($appEntry in $tenantEntry.Apps.PSObject.Properties) {
        $canonical = $knownApps | Where-Object { $_ -eq $appEntry.Name } | Select-Object -First 1
        if (-not $canonical) {
            throw "Tenant '$tenantKey' lists unknown app '$($appEntry.Name)' in '$script:TenantDeploymentsPath'. Known apps: $($knownApps -join ', ')"
        }

        $plan[$canonical] = ConvertTo-AssignmentSpec -Spec $appEntry.Value -Context "$tenantKey/$canonical"
        $null = ConvertTo-RetentionPolicy -Spec $appEntry.Value -Base $tenantPolicy -Context "$tenantKey/$canonical"
    }

    return $plan
}

# Reads and parses TenantDeployments.json. Returns $null when there is no file.
function Read-TenantDeploymentDocument {
    if (-not (Test-Path $script:TenantDeploymentsPath)) {
        return $null
    }

    try {
        $document = Get-Content -Path $script:TenantDeploymentsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Could not parse '$script:TenantDeploymentsPath': $($_.Exception.Message)"
    }

    if (-not $document.Tenants) {
        throw "'$script:TenantDeploymentsPath' has no 'Tenants' object. See TenantDeployments.example.json."
    }

    return $document
}

# Locates a tenant's entry in the plan file (case-insensitive name match, like the rest of the
# script's string comparisons). Returns @{ Key = <canonical key>; Entry = <object> } or $null.
function Get-TenantDeploymentEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantName
    )

    $document = Read-TenantDeploymentDocument
    if ($null -eq $document) {
        return $null
    }

    $tenantKey = $document.Tenants.PSObject.Properties.Name | Where-Object { $_ -eq $TenantName } | Select-Object -First 1
    if (-not $tenantKey) {
        return $null
    }

    return @{ Key = $tenantKey; Entry = $document.Tenants.$tenantKey }
}

#region Version retention policy

# Built-in defaults: keep the newest 3 versions of every app family, plus everything created in
# the last 10 weeks. Runs are at most weekly, and a client that has not updated in 10 weeks is
# outdated by any measure. Tenants may override both, and apps may override the tenant.
$script:DefaultRetentionPolicy = @{ KeepNewest = 3; KeepNewerThanWeeks = 10 }

# The immediate predecessor of the newest version must always survive: Intune drops the
# auto-update tracking for users who installed an app from the Company Portal as soon as that
# app's assignment goes away, and it never comes back. Two is therefore the floor.
$script:MinimumKeepNewest = 2

# Effective retention policy for a tenant, or for one app within a tenant.
#
# Resolution: app override -> tenant "Retention" block -> built-in defaults. Returns:
#     @{ KeepNewest = <int>; KeepNewerThanWeeks = <int>; Source = 'app'|'tenant'|'default'; OptIn = <bool> }
# OptIn is true only when the tenant has an explicit tenant-level "Retention" block. The inventory
# evaluates the policy either way; the cleanup tooling acts only on opted-in tenants.
# Missing plan file or unknown tenant/app simply yields the defaults (Source 'default', OptIn false).
function Get-TenantRetentionPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantName,

        [string]$AppName
    )

    $policy = @{
        KeepNewest         = $script:DefaultRetentionPolicy.KeepNewest
        KeepNewerThanWeeks = $script:DefaultRetentionPolicy.KeepNewerThanWeeks
        Source             = 'default'
        OptIn              = $false
    }

    $tenant = Get-TenantDeploymentEntry -TenantName $TenantName
    if ($null -eq $tenant) {
        return $policy
    }
    $tenantKey = $tenant.Key
    $tenantEntry = $tenant.Entry

    if ($tenantEntry.PSObject.Properties.Name -contains 'Retention') {
        $resolved = ConvertTo-RetentionPolicy -Spec $tenantEntry -Base $policy -Context $tenantKey
        $policy.KeepNewest = $resolved.KeepNewest
        $policy.KeepNewerThanWeeks = $resolved.KeepNewerThanWeeks
        $policy.Source = 'tenant'
        $policy.OptIn = $true
    }

    if ($AppName -and $tenantEntry.Apps) {
        $appKey = $tenantEntry.Apps.PSObject.Properties.Name | Where-Object { $_ -eq $AppName } | Select-Object -First 1
        if ($appKey) {
            $appEntry = $tenantEntry.Apps.$appKey
            if ($null -ne $appEntry -and $appEntry.PSObject.Properties.Name -contains 'Retention') {
                $resolved = ConvertTo-RetentionPolicy -Spec $appEntry -Base $policy -Context "$tenantKey/$appKey"
                $policy.KeepNewest = $resolved.KeepNewest
                $policy.KeepNewerThanWeeks = $resolved.KeepNewerThanWeeks
                $policy.Source = 'app'
            }
        }
    }

    return $policy
}

# Reads an optional "Retention" block from a tenant or app entry, layered over $Base. Rejects
# anything that is not a whole JSON number, unknown keys (typos must not silently mean "default"),
# KeepNewest below the floor, and negative week counts. Returns @{ KeepNewest; KeepNewerThanWeeks }.
function ConvertTo-RetentionPolicy {
    param(
        $Spec,

        [Parameter(Mandatory = $true)]
        [hashtable]$Base,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $result = @{ KeepNewest = $Base.KeepNewest; KeepNewerThanWeeks = $Base.KeepNewerThanWeeks }

    if ($null -eq $Spec -or $Spec.PSObject.Properties.Name -notcontains 'Retention') {
        return $result
    }

    $retention = $Spec.Retention
    if ($null -eq $retention -or $retention -isnot [System.Management.Automation.PSCustomObject]) {
        throw "'Retention' for '$Context' must be an object like { `"KeepNewest`": 3, `"KeepNewerThanWeeks`": 10 }."
    }

    foreach ($property in $retention.PSObject.Properties) {
        $value = $property.Value
        switch ($property.Name) {
            'KeepNewest' {
                $result.KeepNewest = Get-StrictWholeNumber -Value $value -Name 'KeepNewest' -Context $Context -Minimum $script:MinimumKeepNewest
            }
            'KeepNewerThanWeeks' {
                $result.KeepNewerThanWeeks = Get-StrictWholeNumber -Value $value -Name 'KeepNewerThanWeeks' -Context $Context -Minimum 0
            }
            default {
                throw "'Retention' for '$Context' has unknown setting '$($property.Name)'. Allowed: KeepNewest, KeepNewerThanWeeks."
            }
        }
    }

    return $result
}

# Same philosophy as Get-StrictBoolean: a retention count that arrived as a string or a decimal is
# a mistake, and mistakes here decide what gets deleted, so they fail instead of being coerced.
function Get-StrictWholeNumber {
    param(
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter(Mandatory = $true)]
        [int]$Minimum
    )

    $isWhole = ($Value -is [int]) -or ($Value -is [long]) -or (($Value -is [double] -and [math]::Floor($Value) -eq $Value))
    if (-not $isWhole -or $Value -is [bool]) {
        $shown = if ($Value -is [string]) { "`"$Value`"" } else { "$Value" }
        throw "'$Name' for '$Context' must be a whole number, got $shown. Use JSON integers, not strings or decimals."
    }

    if ([int]$Value -lt $Minimum) {
        throw "'$Name' for '$Context' must be at least $Minimum, got $Value."
    }

    return [int]$Value
}

#endregion

# Normalizes one app's plan entry into the assignment spec Publish-App expects.
function ConvertTo-AssignmentSpec {
    param(
        $Spec,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $groups = @()
    if ($null -ne $Spec -and $Spec.PSObject.Properties.Name -contains 'Groups') {
        foreach ($group in @($Spec.Groups)) {
            if ([string]::IsNullOrWhiteSpace($group.Name)) {
                throw "Group entry for '$Context' is missing a 'Name'."
            }

            $intent = if ([string]::IsNullOrWhiteSpace($group.Intent)) { 'Available' } else { $group.Intent }
            if ($intent -notin @('Available', 'Required')) {
                throw "Group '$($group.Name)' for '$Context' has invalid Intent '$intent' (expected 'Available' or 'Required')."
            }

            $groups += @{ Name = $group.Name; Intent = $intent }
        }
    }

    return @{
        AllUsers   = Get-StrictBoolean -Spec $Spec -Name 'AllUsers' -Context $Context
        AllDevices = Get-StrictBoolean -Spec $Spec -Name 'AllDevices' -Context $Context
        Groups     = $groups
    }
}

# Reads a boolean flag from a plan entry, rejecting anything that is not a real JSON boolean.
#
# A plain [bool] cast would be actively dangerous here: PowerShell casts every non-empty string
# to $true, so "AllUsers": "false" would assign the app to every user in the tenant - the exact
# opposite of what was written. Assignment mistakes are hard to notice and wide-reaching, so a
# wrong type has to fail rather than be guessed at.
function Get-StrictBoolean {
    param(
        $Spec,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if ($null -eq $Spec -or $Spec.PSObject.Properties.Name -notcontains $Name) {
        return $false
    }

    $value = $Spec.$Name
    if ($value -isnot [bool]) {
        $shown = if ($value -is [string]) { "`"$value`"" } else { "$value" }
        throw "'$Name' for '$Context' must be true or false, got $shown. Use JSON booleans, not strings or numbers."
    }

    return $value
}

# One-line human summary of an assignment spec, for -ShowPlan and deployment logs.
function Format-AssignmentSpec {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Spec
    )

    $parts = @()
    if ($Spec.AllUsers) { $parts += 'All Users (available)' }
    if ($Spec.AllDevices) { $parts += 'All Devices (required)' }
    foreach ($group in @($Spec.Groups)) {
        $parts += "group '$($group.Name)' ($($group.Intent.ToLower()))"
    }

    if ($parts.Count -eq 0) { return 'no assignments' }
    return ($parts -join ', ')
}
