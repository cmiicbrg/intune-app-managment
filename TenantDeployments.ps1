# TenantDeployments.ps1
# Per-tenant deployment plans: which apps a tenant gets, and how each one is assigned.
#
# Deploy-ToIntune.ps1 applies its -AssignToAllUsers / -AssignToAllDevices / -AssignToGroupName
# switches to every app in a run, so apps needing different assignments used to require one
# hand-run command each. A plan makes that declarative: one entry per app, one command per tenant.
#
# The plan lives in TenantDeployments.json (git-ignored, like intune-tenants.json, because it names
# real tenants and Entra ID groups). TenantDeployments.example.json documents the schema.

# Import configuration for app-name validation
. (Join-Path $PSScriptRoot "AppConfig.ps1")

$script:TenantDeploymentsPath = Join-Path $PSScriptRoot "TenantDeployments.json"

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

    # Tenant names are matched case-insensitively, like the rest of the script's string comparisons
    $tenantKey = $document.Tenants.PSObject.Properties.Name | Where-Object { $_ -eq $TenantName } | Select-Object -First 1
    if (-not $tenantKey) {
        return $null
    }

    $tenantEntry = $document.Tenants.$tenantKey
    if (-not $tenantEntry.Apps) {
        throw "Tenant '$tenantKey' in '$script:TenantDeploymentsPath' has no 'Apps' object."
    }

    # Canonical app names, for case-insensitive resolution of entries like "Gimp" or "Openshot"
    $knownApps = @(Get-AllAppNames)

    $plan = [ordered]@{}
    foreach ($appEntry in $tenantEntry.Apps.PSObject.Properties) {
        $canonical = $knownApps | Where-Object { $_ -eq $appEntry.Name } | Select-Object -First 1
        if (-not $canonical) {
            throw "Tenant '$tenantKey' lists unknown app '$($appEntry.Name)' in '$script:TenantDeploymentsPath'. Known apps: $($knownApps -join ', ')"
        }

        $plan[$canonical] = ConvertTo-AssignmentSpec -Spec $appEntry.Value -Context "$tenantKey/$canonical"
    }

    return $plan
}

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
        AllUsers   = [bool]($Spec.AllUsers)
        AllDevices = [bool]($Spec.AllDevices)
        Groups     = $groups
    }
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
