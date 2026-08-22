#Requires -Version 7.4

# Tests for the pure inventory assembly and analysis in AppInventory.ps1, driven by a synthetic
# tenant that reproduces the real-world findings the inventory exists to surface: a family at
# the supersedence graph limit, older versions of a >=-detected family still assigned (Company
# Portal duplicate rows), a superseding version without auto-update, a hand-deployed app under
# a non-conforming name, a protected dependency target, and a duplicate version.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    foreach ($file in 'AppInventory.ps1', 'SharedFunctions.ps1', 'AppConfig.ps1', 'IntuneInterop.ps1', 'AppRetention.ps1') {
        Copy-Item (Join-Path $repoRoot $file) $workDir
    }
    . (Join-Path $workDir 'AppInventory.ps1')

    $script:now = [datetime]::new(2026, 8, 17, 12, 0, 0, [DateTimeKind]::Utc)
    $script:families = @(Get-AppFamilyCatalog)

    # --- synthetic Graph objects -------------------------------------------------------------
    function New-GraphApp {
        param([string]$Id, [string]$Name, [string]$Version, [double]$WeeksOld, [string]$Operator = 'greaterThanOrEqual', [string]$RuleType = 'win32LobAppFileSystemDetection')
        [PSCustomObject]@{
            id              = $Id
            displayName     = $Name
            displayVersion  = $Version
            publisher       = 'Test'
            createdDateTime = $script:now.AddDays(-7 * $WeeksOld).ToString('o')
            isAssigned      = $true
            publishingState = 'published'
            size            = 1000
            largeIcon       = @{ type = 'image/png'; value = 'AAAA' }
            detectionRules  = @([PSCustomObject]@{ '@odata.type' = "#microsoft.graph.$RuleType"; operator = $Operator })
        }
    }
    function New-Assignment { param([string]$Intent = 'available', [string]$Target = 'AllUsers', $AutoUpdate = $null)
        [PSCustomObject]@{ Id = [guid]::NewGuid().ToString(); Intent = $Intent; Target = $Target; GroupId = $null; AutoUpdateSuperseded = $AutoUpdate }
    }
    function New-Supersedes { param([string]$TargetId, [string]$Version)
        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = $TargetId; targetDisplayName = 'x'; targetDisplayVersion = $Version; targetType = 'child'; supersedenceType = 'update' }
    }
    function New-SupersededBy { param([string]$TargetId, [string]$Version)
        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = $TargetId; targetDisplayName = 'x'; targetDisplayVersion = $Version; targetType = 'parent'; supersedenceType = 'update' }
    }
    function New-DependencyOf { param([string]$TargetId)
        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = $TargetId; targetDisplayName = 'x'; targetDisplayVersion = '1'; targetType = 'parent'; dependencyType = 'autoInstall' }
    }
    function New-DependsOn { param([string]$TargetId)
        [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = $TargetId; targetDisplayName = 'x'; targetDisplayVersion = '1'; targetType = 'child'; dependencyType = 'autoInstall' }
    }

    # Chrome: 11-node chain, all superseded versions still assigned available (>= detection)
    $chromeVersions = @('141.0.1', '142.0.1', '142.0.2', '143.0.1', '143.0.2', '146.0.1', '146.0.2', '147.0.1', '148.0.1', '151.0.1', '151.0.2')
    $script:chromeApps = @()
    for ($i = 0; $i -lt $chromeVersions.Count; $i++) {
        $script:chromeApps += New-GraphApp -Id "chrome-$i" -Name "Google Chrome $($chromeVersions[$i].Split('.')[0])" -Version $chromeVersions[$i] -WeeksOld (2 * ($chromeVersions.Count - $i))
    }

    $script:records = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $script:chromeApps.Count; $i++) {
        $rels = @()
        if ($i -gt 0) { $rels += New-Supersedes -TargetId "chrome-$($i - 1)" -Version $chromeVersions[$i - 1] }
        if ($i -lt $script:chromeApps.Count - 1) { $rels += New-SupersededBy -TargetId "chrome-$($i + 1)" -Version $chromeVersions[$i + 1] }
        $autoUpdate = if ($i -gt 0) { $true } else { $null }
        $script:records.Add((ConvertTo-AppInventoryRecord -App $script:chromeApps[$i] -Assignments @((New-Assignment -AutoUpdate $autoUpdate), (New-Assignment -Intent 'required' -Target 'AllDevices')) -Relationships $rels -InstallSummary ([PSCustomObject]@{ installedDeviceCount = 10 - $i; pendingInstallDeviceCount = 0; failedDeviceCount = 0 }) -Families $script:families))
    }

    # Stellarium: 3 versions, newest supersedes middle without auto-update; older two still assigned
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'stel-1' -Name 'Stellarium 25' -Version '25.4' -WeeksOld 30) -Assignments @((New-Assignment)) -Relationships @((New-SupersededBy -TargetId 'stel-2' -Version '26.1')) -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'stel-2' -Name 'Stellarium 26' -Version '26.1' -WeeksOld 12) -Assignments @((New-Assignment)) -Relationships @((New-Supersedes -TargetId 'stel-1' -Version '25.4'), (New-SupersededBy -TargetId 'stel-3' -Version '26.2')) -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'stel-3' -Name 'Stellarium 26' -Version '26.2' -WeeksOld 1) -Assignments @((New-Assignment -AutoUpdate $false)) -Relationships @((New-Supersedes -TargetId 'stel-2' -Version '26.1')) -InstallSummary $null -Families $script:families))

    # 7-Zip: product-code detection, two versions, clean auto-update
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'zip-1' -Name '7-Zip 25' -Version '25.01.00.0' -WeeksOld 20 -RuleType 'win32LobAppProductCodeDetection' -Operator $null) -Assignments @((New-Assignment)) -Relationships @((New-SupersededBy -TargetId 'zip-2' -Version '26.02.00.0')) -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'zip-2' -Name '7-Zip 26' -Version '26.02.00.0' -WeeksOld 3 -RuleType 'win32LobAppProductCodeDetection' -Operator $null) -Assignments @((New-Assignment -AutoUpdate $true)) -Relationships @((New-Supersedes -TargetId 'zip-1' -Version '25.01.00.0')) -InstallSummary $null -Families $script:families))

    # VCRedist: 'vc-old' is a dependency target of KeePassXC -> protected although rank 4 and 60 weeks
    # old; 'vc-ancient' is rank 5, unprotected -> delete; newest unassigned but HideFromPortal
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'vc-ancient' -Name 'Visual C++ Redistributable 14' -Version '14.30.1' -WeeksOld 70 -RuleType 'win32LobAppRegistryDetection' -Operator 'notConfigured') -Assignments @() -Relationships @() -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'vc-old' -Name 'Visual C++ Redistributable 14' -Version '14.40.1' -WeeksOld 60 -RuleType 'win32LobAppRegistryDetection' -Operator 'notConfigured') -Assignments @() -Relationships @((New-DependencyOf -TargetId 'kpx-1')) -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'vc-1' -Name 'Visual C++ Redistributable 14' -Version '14.44.1' -WeeksOld 40 -RuleType 'win32LobAppRegistryDetection' -Operator 'notConfigured') -Assignments @() -Relationships @() -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'vc-2' -Name 'Visual C++ Redistributable 14' -Version '14.44.2' -WeeksOld 30 -RuleType 'win32LobAppRegistryDetection' -Operator 'notConfigured') -Assignments @() -Relationships @() -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'vc-3' -Name 'Visual C++ Redistributable 14' -Version '14.44.3' -WeeksOld 20 -RuleType 'win32LobAppRegistryDetection' -Operator 'notConfigured') -Assignments @() -Relationships @() -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'kpx-1' -Name 'KeePassXC 2' -Version '2.7.12' -WeeksOld 5) -Assignments @((New-Assignment)) -Relationships @((New-DependsOn -TargetId 'vc-old')) -InstallSummary $null -Families $script:families))

    # GIMP: a duplicate version
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'gimp-1' -Name 'GIMP 3' -Version '3.2.4' -WeeksOld 4 -Operator 'equal') -Assignments @((New-Assignment)) -Relationships @() -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'gimp-2' -Name 'GIMP 3' -Version '3.2.4' -WeeksOld 5 -Operator 'equal') -Assignments @() -Relationships @() -InstallSummary $null -Families $script:families))

    # Unmanaged: a near miss and a foreign app
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'foreign-1' -Name 'Google Chrome Remote Desktop' -Version '2.0' -WeeksOld 80) -Assignments @((New-Assignment)) -Relationships @() -InstallSummary $null -Families $script:families))
    $script:records.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'foreign-2' -Name 'Adobe Reader DC' -Version '24.1' -WeeksOld 80) -Assignments @() -Relationships @() -InstallSummary $null -Families $script:families))

    $script:policyResolver = { param($name) @{ KeepNewest = 3; KeepNewerThanWeeks = 10; Source = 'default'; OptIn = $false } }
    $script:appConfigs = @{}
    foreach ($f in $script:families) { $script:appConfigs[$f.AppConfigName] = Get-AppConfiguration -AppName $f.AppConfigName }

    $script:analysis = Get-AppInventoryAnalysis -Records @($script:records) -Families $script:families -PolicyResolver $script:policyResolver -PlanAppNames @('Chrome', 'SevenZip', 'KeePassXC', 'VCRedist') -AppConfigs $script:appConfigs -Now $script:now
}

Describe 'ConvertTo-AppInventoryRecord' {
    It 'maps the app to its family, drops the icon, and normalizes assignments and relationships' {
        $r = $script:records | Where-Object Id -eq 'chrome-10'
        $r.Family | Should -Be 'Chrome'
        $r.PSObject.Properties.Name | Should -Not -Contain 'largeIcon'
        $r.ParsedVersion | Should -Be ([version]'151.0.2')
        $r.Assignments.Count | Should -Be 2
        ($r.Assignments | Where-Object Target -eq 'AllUsers').AutoUpdateSuperseded | Should -BeTrue
        $r.Supersedes.Count | Should -Be 1
        $r.Supersedes[0].TargetId | Should -Be 'chrome-9'
        $r.SupersededBy.Count | Should -Be 0
        $r.InstallSummary.installedDeviceCount | Should -Be 0
    }

    It 'flags version-comparison detection as inflating and product-code detection as not' {
        ($script:records | Where-Object Id -eq 'chrome-0').InflatingDetection | Should -BeTrue
        ($script:records | Where-Object Id -eq 'zip-1').InflatingDetection | Should -BeFalse
        ($script:records | Where-Object Id -eq 'gimp-1').InflatingDetection | Should -BeFalse
    }

    It 'records dependency directions' {
        ($script:records | Where-Object Id -eq 'kpx-1').DependsOn[0].TargetId | Should -Be 'vc-old'
        ($script:records | Where-Object Id -eq 'vc-old').DependencyOf[0].TargetId | Should -Be 'kpx-1'
    }

    It 'marks a non-conforming name as a near miss of its family and a foreign app as plain unmanaged' {
        $near = $script:records | Where-Object Id -eq 'foreign-1'
        $near.Family | Should -BeNullOrEmpty
        $near.FamilyNearMiss | Should -Be 'Chrome'
        $far = $script:records | Where-Object Id -eq 'foreign-2'
        $far.Family | Should -BeNullOrEmpty
        $far.FamilyNearMiss | Should -BeNullOrEmpty
    }

    It 'notes when assignments could not be read' {
        $r = ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'x' -Name 'GIMP 3' -Version '3.0' -WeeksOld 1) -Assignments $null -Relationships @() -InstallSummary $null -Families $script:families
        $r.AssignmentsUnavailable | Should -BeTrue
        $r.RelationshipsUnavailable | Should -BeFalse
    }

    It 'distinguishes a failed relationship read from an empty relationship set' {
        $r = ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'x' -Name 'GIMP 3' -Version '3.0' -WeeksOld 1) -Assignments @() -Relationships $null -InstallSummary $null -Families $script:families
        $r.RelationshipsUnavailable | Should -BeTrue
        $r.DependencyOf.Count | Should -Be 0
    }
}

Describe 'Get-AppInventoryAnalysis with incomplete relationship data' {
    BeforeAll {
        # Four old Stellarium versions; under keep-3 the oldest would be deleted - but its
        # relationship read failed, so it could be an invisible dependency target.
        $script:partial = [System.Collections.Generic.List[object]]::new()
        $script:partial.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'p-0' -Name 'Stellarium 24' -Version '24.1' -WeeksOld 60) -Assignments @((New-Assignment)) -Relationships $null -InstallSummary $null -Families $script:families))
        $script:partial.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'p-1' -Name 'Stellarium 25' -Version '25.1' -WeeksOld 40) -Assignments @((New-Assignment)) -Relationships @((New-SupersededBy -TargetId 'p-2' -Version '26.1')) -InstallSummary $null -Families $script:families))
        $script:partial.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'p-2' -Name 'Stellarium 26' -Version '26.1' -WeeksOld 30) -Assignments @((New-Assignment)) -Relationships @((New-Supersedes -TargetId 'p-1' -Version '25.1'), (New-SupersededBy -TargetId 'p-3' -Version '26.2')) -InstallSummary $null -Families $script:families))
        $script:partial.Add((ConvertTo-AppInventoryRecord -App (New-GraphApp -Id 'p-3' -Name 'Stellarium 26' -Version '26.2' -WeeksOld 20) -Assignments @((New-Assignment)) -Relationships @((New-Supersedes -TargetId 'p-2' -Version '26.1')) -InstallSummary $null -Families $script:families))
        $script:partialAnalysis = Get-AppInventoryAnalysis -Records @($script:partial) -Families $script:families -PolicyResolver $script:policyResolver -PlanAppNames $null -AppConfigs $script:appConfigs -Now $script:now
    }

    It 'never turns an app with unreadable relationships into a delete candidate' {
        $oldest = $script:partial | Where-Object Id -eq 'p-0'
        $oldest.Retention.Action | Should -Be 'Review'
        $oldest.Retention.Reasons | Should -Contain 'relationships could not be read - may be a dependency target; deletion suppressed, re-run the inventory'
        $family = $script:partialAnalysis.Families | Where-Object Family -eq 'Stellarium'
        $family.DeleteCandidateCount | Should -Be 0
        $family.DeleteCandidates.Count | Should -Be 0
        $family.ReviewCount | Should -Be 1
        $script:partialAnalysis.Summary.DeleteCandidates | Should -Be 0
        $script:partialAnalysis.Summary.AppsWithUnavailableRelationships | Should -Be 1
    }

    It 'reports the incomplete data as an anomaly and in the markdown summary' {
        $anomaly = $script:partialAnalysis.Anomalies | Where-Object Type -eq 'RelationshipsUnavailable'
        $anomaly.Family | Should -Be 'Stellarium'
        $anomaly.AppIds | Should -Be @('p-0')
        $md = Format-AppInventoryMarkdown -TenantName 'Partial' -GeneratedUtc $script:now -Analysis $script:partialAnalysis -Records @($script:partial)
        $md | Should -Match 'Incomplete data'
    }

    It 'only reports OlderVersionsStillAssigned for versions Intune actually links as superseded' {
        # p-0 is older and assigned available but has no SupersededBy relationship (unlinked)
        $older = $script:partialAnalysis.Anomalies | Where-Object Type -eq 'OlderVersionsStillAssigned'
        ($older.AppIds | Sort-Object) | Should -Be @('p-1', 'p-2')
    }

    It 'leaves the full fixture untouched' {
        $script:analysis.Summary.AppsWithUnavailableRelationships | Should -Be 0
        ($script:analysis.Anomalies | Where-Object Type -eq 'RelationshipsUnavailable') | Should -BeNullOrEmpty
    }
}

Describe 'Get-AppInventoryAnalysis' {
    It 'summarizes counts' {
        $s = $script:analysis.Summary
        $s.TotalWin32Apps | Should -Be $script:records.Count
        $s.UnmanagedApps | Should -Be 2
        $s.ManagedApps | Should -Be ($script:records.Count - 2)
        $s.FamiliesPresent | Should -Be 6
    }

    It 'applies the retention policy per family and orders delete candidates oldest first' {
        $chrome = $script:analysis.Families | Where-Object Family -eq 'Chrome'
        $chrome.VersionCount | Should -Be 11
        $chrome.Newest.Version | Should -Be '151.0.2'
        # newest 3 by rank (151.0.2, 151.0.1, 148.0.1) + anything younger than 10 weeks (147.0.1 at 8w, 146.0.2 at 10w? 2*3=6w... ) -> check via reasons
        $chrome.DeleteCandidateCount | Should -BeGreaterThan 0
        $chrome.DeleteCandidates[0].Version | Should -Be '141.0.1'
        [version]$chrome.DeleteCandidates[0].Version | Should -BeLessThan ([version]$chrome.DeleteCandidates[-1].Version)
        ($script:records | Where-Object Id -eq 'chrome-10').Retention.Action | Should -Be 'Keep'
        ($script:records | Where-Object Id -eq 'chrome-0').Retention.Action | Should -Be 'Delete'
    }

    It 'sizes the supersedence graph and warns near the limit' {
        ($script:analysis.Families | Where-Object Family -eq 'Chrome').SupersedenceGraphNodes | Should -Be 11
        ($script:analysis.Families | Where-Object Family -eq 'Stellarium').SupersedenceGraphNodes | Should -Be 3
        ($script:analysis.Families | Where-Object Family -eq 'GIMP').SupersedenceGraphNodes | Should -Be 1
        $script:analysis.Summary.FamiliesNearGraphLimit | Should -Be 1
        ($script:analysis.Anomalies | Where-Object { $_.Type -eq 'SupersedenceGraphNearLimit' }).Family | Should -Be 'Chrome'
    }

    It 'flags superseded versions still assigned available, with the Company Portal note for inflating families' {
        $stel = $script:analysis.Anomalies | Where-Object { $_.Type -eq 'OlderVersionsStillAssigned' -and $_.Family -eq 'Stellarium' }
        $stel | Should -Not -BeNullOrEmpty
        ($stel.AppIds | Sort-Object) | Should -Be @('stel-1', 'stel-2') -Because 'both older versions still carry an available assignment'
        $stel.Message | Should -Match 'Company Portal'
        $zip = $script:analysis.Anomalies | Where-Object { $_.Type -eq 'OlderVersionsStillAssigned' -and $_.Family -eq 'SevenZip' }
        $zip.Message | Should -Not -Match 'Company Portal' -Because 'product-code detection does not inflate'
    }

    It 'flags superseding versions whose available assignment lacks auto-update' {
        $gap = $script:analysis.Anomalies | Where-Object { $_.Type -eq 'AutoUpdateNotEnabled' -and $_.Family -eq 'Stellarium' }
        # stel-3 (auto-update explicitly off) and stel-2 (no autoUpdateSettings at all) both supersede something
        ($gap.AppIds | Sort-Object) | Should -Be @('stel-2', 'stel-3')
        ($script:analysis.Anomalies | Where-Object { $_.Type -eq 'AutoUpdateNotEnabled' -and $_.Family -eq 'SevenZip' }) | Should -BeNullOrEmpty
        ($script:analysis.Anomalies | Where-Object { $_.Type -eq 'AutoUpdateNotEnabled' -and $_.Family -eq 'Chrome' }) | Should -BeNullOrEmpty
    }

    It 'protects dependency targets from deletion' {
        $vcOld = $script:records | Where-Object Id -eq 'vc-old'
        $vcOld.Retention.Action | Should -Be 'Keep'
        $vcOld.Retention.Reasons | Should -Contain 'protected (dependency target)'
        $vcOld.Retention.Rank | Should -Be 4 -Because 'outside the newest 3 and 60 weeks old, it survives only through protection'
        # vc-ancient is rank 5, 70 weeks old and not a dependency target -> deleted
        ($script:records | Where-Object Id -eq 'vc-ancient').Retention.Action | Should -Be 'Delete'
    }

    It 'does not flag an unassigned newest version for HideFromPortal families' {
        ($script:analysis.Anomalies | Where-Object { $_.Type -eq 'NewestUnassigned' -and $_.Family -eq 'VCRedist' }) | Should -BeNullOrEmpty
    }

    It 'flags duplicate versions for review' {
        $dup = $script:analysis.Anomalies | Where-Object { $_.Type -eq 'DuplicateVersion' -and $_.Family -eq 'GIMP' }
        $dup.AppIds | Should -Contain 'gimp-1'
        $dup.AppIds | Should -Contain 'gimp-2'
        ($script:analysis.Families | Where-Object Family -eq 'GIMP').ReviewCount | Should -Be 2
    }

    It 'flags a near-miss name with a rename suggestion and lists unmanaged apps' {
        $naming = $script:analysis.Anomalies | Where-Object Type -eq 'NamingConventionMismatch'
        $naming.Family | Should -Be 'Chrome'
        $naming.Message | Should -Match "Google Chrome Remote Desktop"
        $naming.Message | Should -Match 'Rename it'
        $script:analysis.Unmanaged.Count | Should -Be 2
        ($script:analysis.Unmanaged | Where-Object DisplayName -eq 'Google Chrome Remote Desktop').LooksLike | Should -Be 'Chrome'
        ($script:analysis.Unmanaged | Where-Object DisplayName -eq 'Adobe Reader DC').LooksLike | Should -BeNullOrEmpty
    }

    It 'reports whether each family is in the deployment plan' {
        ($script:analysis.Families | Where-Object Family -eq 'Chrome').InPlan | Should -BeTrue
        ($script:analysis.Families | Where-Object Family -eq 'Stellarium').InPlan | Should -BeFalse
    }

    It 'treats every family as in scope when there is no plan' {
        $noPlan = Get-AppInventoryAnalysis -Records @($script:records) -Families $script:families -PolicyResolver $script:policyResolver -PlanAppNames $null -AppConfigs $script:appConfigs -Now $script:now
        ($noPlan.Families | Where-Object Family -eq 'Stellarium').InPlan | Should -BeTrue
    }

    It 'scopes cleanly to one family: other families are neither reported nor called unmanaged' {
        # Mirrors the -AppName flow of the script: classification against the full catalog,
        # analysis over the selected family's members plus the unmanaged records
        $scopeFamilies = @($script:families | Where-Object AppConfigName -eq 'Chrome')
        $scopedRecords = @($script:records | Where-Object { $_.Family -eq 'Chrome' -or $null -eq $_.Family })
        $scoped = Get-AppInventoryAnalysis -Records $scopedRecords -Families $scopeFamilies -PolicyResolver $script:policyResolver -PlanAppNames $null -AppConfigs $script:appConfigs -Now $script:now

        $scoped.Families.Family | Should -Be @('Chrome')
        # Stellarium apps are classified (Family set), so they are not in the unmanaged list
        $scoped.Unmanaged.DisplayName | Should -Not -Contain 'Stellarium 26'
        $scoped.Unmanaged.Count | Should -Be 2
        # The Chrome near miss still fires with the rename suggestion
        ($scoped.Anomalies | Where-Object Type -eq 'NamingConventionMismatch').Family | Should -Be 'Chrome'
        # A near miss of an out-of-scope family would keep its LooksLike but raise no anomaly
        $stellariumScope = @($script:families | Where-Object AppConfigName -eq 'Stellarium')
        $stellariumScoped = Get-AppInventoryAnalysis -Records $scopedRecords -Families $stellariumScope -PolicyResolver $script:policyResolver -PlanAppNames $null -AppConfigs $script:appConfigs -Now $script:now
        ($stellariumScoped.Anomalies | Where-Object Type -eq 'NamingConventionMismatch') | Should -BeNullOrEmpty
        ($stellariumScoped.Unmanaged | Where-Object DisplayName -eq 'Google Chrome Remote Desktop').LooksLike | Should -Be 'Chrome'
    }
}

Describe 'Format-AppInventoryMarkdown' {
    It 'renders every section' {
        $md = Format-AppInventoryMarkdown -TenantName 'Test' -GeneratedUtc $script:now -Analysis $script:analysis -Records @($script:records)
        $md | Should -Match '# Intune Win32 app inventory - Test'
        $md | Should -Match '## Families'
        $md | Should -Match '## Delete candidates'
        $md | Should -Match '## Anomalies'
        $md | Should -Match '## Versions'
        $md | Should -Match '## Unmanaged apps'
        $md | Should -Match '\| Chrome \| yes \| 11 \|'
        $md | Should -Match 'Google Chrome Remote Desktop'
        $md | Should -Match 'SupersedenceGraphNearLimit'
    }

    It 'omits install columns when the summary was skipped' {
        $md = Format-AppInventoryMarkdown -TenantName 'Test' -GeneratedUtc $script:now -Analysis $script:analysis -Records @($script:records) -IncludesInstallSummary $false
        $md | Should -Not -Match 'Installed / Pending / Failed'
    }
}
