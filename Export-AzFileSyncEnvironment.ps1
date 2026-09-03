#Requires -Version 5.1
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
  Export the ENTIRE current configuration of a customer's Azure File Sync estate and the
  Azure Backup protection of its Azure file shares - read-only, secrets never captured.

.DESCRIPTION
  Walks every subscription in scope and captures, as raw ARM JSON (full fidelity, no
  cmdlet re-shaping):

    Azure File Sync   Storage Sync Services, sync groups, cloud endpoints, server endpoints
                      (sync + cloud-tiering status), registered servers (agent, OS, heartbeat,
                      auth type), private endpoint connections, RBAC, locks, diagnostics,
                      7-day health metrics.
    Storage           every storage account (account properties: network rules, TLS, shared
                      key, identity-based auth, encryption, redundancy), file service
                      properties (soft delete, SMB protocol settings), every file share
                      (quota, usage, tier, snapshots, soft-deleted shares), RBAC, locks,
                      Defender for Storage, diagnostics, 7-day capacity/availability metrics.
    Azure Backup      every Recovery Services vault (security settings: soft delete,
                      immutability, MUA, redundancy, cross-region restore, alerts), vault
                      config, storage config, backup policies, protection containers,
                      protected items, jobs (last N days), resource-guard proxies, RBAC,
                      diagnostics; plus Data Protection backup vaults (blob/disk backups).
    Network           privatelink.file.* and privatelink.afs.* private DNS zones (+ VNet
                      links) and the private endpoints that target storage accounts or
                      Storage Sync Services (+ DNS zone groups).

  Output: a folder of JSON files + summary.md + manifest.json (sha256 of every file), zipped.
  Feed the zip to Assess-AzFileSyncExport.ps1 (or to an analyst) for findings.

  READ-ONLY. Every call is an ARM GET. Storage account keys, SAS tokens and certificates are
  never requested; a redaction pass additionally blanks any well-known secret field names.
  Reader on the subscriptions is sufficient.

.PARAMETER SubscriptionId
  One or more subscription IDs. Default: every enabled subscription visible to the signed-in
  account in the current tenant.

.PARAMETER OutputPath
  Folder to create. Default: .\afs-export-<yyyyMMdd-HHmmss>

.PARAMETER JobLookbackDays
  How many days of Azure Backup jobs to export (default 30).

.PARAMETER MetricsLookbackDays
  How many days of Azure Monitor metrics to export (default 7).

.PARAMETER SkipMetrics
  Skip Azure Monitor metric calls (faster; loses health/capacity trends).

.PARAMETER NoZip
  Leave the output folder unzipped.

.EXAMPLE
  Connect-AzAccount -Tenant <tenant-id>
  .\Export-AzFileSyncEnvironment.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

.EXAMPLE
  .\Export-AzFileSyncEnvironment.ps1 -OutputPath C:\temp\organization-afs -JobLookbackDays 60

.NOTES
  Requires: PowerShell 5.1+ (Windows PowerShell or PowerShell 7), Az.Accounts 2.x+.
  Install:  Install-Module Az.Accounts -Scope CurrentUser
  Author:   Luca Express - change-management/contoso-azure-file-sync-backup (codex
            playbook-azure-file-sync-assessment). Version 1.0.0.
#>
[CmdletBinding()]
param(
  [string[]]$SubscriptionId,
  [string]$OutputPath,
  [ValidateRange(1, 365)][int]$JobLookbackDays = 30,
  [ValidateRange(1, 30)][int]$MetricsLookbackDays = 7,
  [switch]$SkipMetrics,
  [switch]$NoZip
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'

# -- API versions (verified against Microsoft Learn REST references, 2026-09-02) -----------
$Api = [ordered]@{
  StorageSync      = '2022-09-01'
  Storage          = '2024-01-01'
  RecoveryServices = '2024-04-01'   # vaults
  Backup           = '2024-04-01'   # backupPolicies / backupProtectedItems / backupJobs / vaultconfig
  DataProtection   = '2024-04-01'
  PrivateDns       = '2020-06-01'
  Network          = '2023-11-01'
  Diagnostics      = '2021-05-01-preview'
  Authorization    = '2022-04-01'
  Locks            = '2020-05-01'
  SecurityPricing  = '2024-01-01'
  DefenderStorage  = '2022-12-01-preview'
  Metrics          = '2018-01-01'
  MetricAlerts     = '2018-03-01'
  Subscriptions    = '2022-12-01'
  ResourceGraph    = '2021-03-01'
}

# -- state --------------------------------------------------------------------------------
$script:Errors = New-Object System.Collections.ArrayList
$script:Files = New-Object System.Collections.ArrayList
$script:RoleDefCache = @{}
$script:Counts = [ordered]@{ storageSyncServices = 0; syncGroups = 0; cloudEndpoints = 0; serverEndpoints = 0; registeredServers = 0; storageAccounts = 0; fileShares = 0; recoveryServicesVaults = 0; backupPolicies = 0; protectedItems = 0; backupJobs = 0; dataProtectionVaults = 0; privateDnsZones = 0; privateEndpoints = 0 }

# -- helpers ------------------------------------------------------------------------------
function Write-Step([string]$Message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }

function Add-ExportError([string]$Where, [string]$Detail) {
  [void]$script:Errors.Add([ordered]@{ where = $Where; detail = $Detail; at = (Get-Date).ToUniversalTime().ToString('o') })
  Write-Warning ("{0}: {1}" -f $Where, $Detail)
}

function Get-ArmBase {
  $ctx = Get-AzContext
  if (-not $ctx) { throw 'No Azure context. Run Connect-AzAccount first.' }
  return $ctx.Environment.ResourceManagerUrl.TrimEnd('/')
}

function Invoke-ArmGet {
  <# GET one ARM resource or one paged list (follows nextLink). Returns $null on error (error recorded). #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$ApiVersion,
    [string]$Query,
    [switch]$List,
    [string]$Label
  )
  if (-not $Label) { $Label = $Path }
  $uri = if ($Path -like 'https://*') { $Path } else {
    $sep = if ($Path.Contains('?')) { '&' } else { '?' }
    $u = "$script:ArmBase$Path${sep}api-version=$ApiVersion"
    if ($Query) { $u += "&$Query" }
    $u
  }
  $all = New-Object System.Collections.ArrayList
  $pages = 0
  while ($uri) {
    try {
      $resp = Invoke-AzRestMethod -Method GET -Uri $uri
    } catch {
      Add-ExportError $Label $_.Exception.Message
      return $null
    }
    if ($resp.StatusCode -ge 400) {
      $msg = "HTTP $($resp.StatusCode)"
      try { $e = $resp.Content | ConvertFrom-Json; if ($e.error) { $msg += " $($e.error.code): $($e.error.message)" } } catch { $msg += " $($resp.Content)" }
      Add-ExportError $Label $msg
      return $null
    }
    if ([string]::IsNullOrWhiteSpace($resp.Content)) { if ($List) { return ,@() } else { return $null } }
    $obj = $resp.Content | ConvertFrom-Json
    if (-not $List) { return $obj }
    $pages++
    if ($obj.PSObject.Properties['value'] -and $obj.value) { foreach ($v in @($obj.value)) { [void]$all.Add($v) } }
    $uri = $null
    if ($obj.PSObject.Properties['nextLink'] -and $obj.nextLink) { $uri = $obj.nextLink }
    if ($pages -gt 500) { Add-ExportError $Label 'aborted paging after 500 pages'; break }
  }
  return ,@($all.ToArray())
}

function Get-SafeName([string]$Name) { return ($Name -replace '[^\w.\-]', '_') }

function Remove-Secrets($Node) {
  <# Belt and braces: ARM GETs never return key material, but blank well-known secret fields anyway. #>
  $secretNames = @('serverCertificate', 'primaryKey', 'secondaryKey', 'connectionString', 'sasToken', 'accessToken', 'password', 'clientSecret', 'sharedKey', 'primaryMasterKey', 'keys')
  if ($null -eq $Node) { return }
  if ($Node -is [System.Collections.IList]) { foreach ($i in $Node) { Remove-Secrets $i }; return }
  if ($Node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in @($Node.PSObject.Properties)) {
      if ($secretNames -contains $p.Name) { $p.Value = '[REDACTED]' }
      elseif ($p.Value -is [System.Management.Automation.PSCustomObject] -or $p.Value -is [System.Collections.IList]) { Remove-Secrets $p.Value }
    }
  }
}

function Save-Json([string]$RelativePath, $Object) {
  Remove-Secrets $Object
  $full = Join-Path $script:Out $RelativePath
  $dir = Split-Path $full -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $json = if ($null -eq $Object) { 'null' } else { $Object | ConvertTo-Json -Depth 64 }
  [System.IO.File]::WriteAllText($full, $json, (New-Object System.Text.UTF8Encoding($false)))
  [void]$script:Files.Add($RelativePath)
}

function Get-DiagnosticSettings([string]$ResourceId, [string]$Label) {
  return Invoke-ArmGet -Path "$ResourceId/providers/Microsoft.Insights/diagnosticSettings" -ApiVersion $Api.Diagnostics -List -Label "diagnostics:$Label"
}

function Get-RoleAssignments([string]$Scope, [string]$Label) {
  $ras = Invoke-ArmGet -Path "$Scope/providers/Microsoft.Authorization/roleAssignments" -ApiVersion $Api.Authorization -Query ('$filter=' + [uri]::EscapeDataString('atScope()')) -List -Label "rbac:$Label"
  if ($null -eq $ras) { return $null }
  $out = New-Object System.Collections.ArrayList
  foreach ($ra in $ras) {
    $rdId = $ra.properties.roleDefinitionId
    if (-not $script:RoleDefCache.ContainsKey($rdId)) {
      $rd = Invoke-ArmGet -Path $rdId -ApiVersion $Api.Authorization -Label "roledef:$rdId"
      $script:RoleDefCache[$rdId] = if ($rd) { $rd.properties.roleName } else { '(unresolved)' }
    }
    [void]$out.Add([ordered]@{
      id = $ra.id; scope = $ra.properties.scope; roleName = $script:RoleDefCache[$rdId]; roleDefinitionId = $rdId
      principalId = $ra.properties.principalId; principalType = $ra.properties.principalType
      condition = $ra.properties.condition; createdOn = $ra.properties.createdOn
    })
  }
  return ,@($out.ToArray())
}

function Get-Locks([string]$Scope, [string]$Label) {
  return Invoke-ArmGet -Path "$Scope/providers/Microsoft.Authorization/locks" -ApiVersion $Api.Locks -List -Label "locks:$Label"
}

function Get-Metrics([string]$ResourceId, [string]$MetricNames, [string]$Aggregation, [string]$Interval, [string]$Filter, [string]$Label, [int]$Days) {
  if ($SkipMetrics) { return $null }
  $end = (Get-Date).ToUniversalTime()
  $start = $end.AddDays(-1 * $Days)
  $q = 'metricnames=' + [uri]::EscapeDataString($MetricNames) + '&timespan=' + [uri]::EscapeDataString(($start.ToString('o') + '/' + $end.ToString('o'))) + "&interval=$Interval&aggregation=$Aggregation"
  if ($Filter) { $q += '&$filter=' + [uri]::EscapeDataString($Filter) }
  $r = Invoke-ArmGet -Path "$ResourceId/providers/Microsoft.Insights/metrics" -ApiVersion $Api.Metrics -Query $q -Label "metrics:$Label"
  if ($null -eq $r -and $Filter) {
    # dimension filter rejected -> retry without it (aggregate only)
    $q2 = 'metricnames=' + [uri]::EscapeDataString($MetricNames) + '&timespan=' + [uri]::EscapeDataString(($start.ToString('o') + '/' + $end.ToString('o'))) + "&interval=$Interval&aggregation=$Aggregation"
    $r = Invoke-ArmGet -Path "$ResourceId/providers/Microsoft.Insights/metrics" -ApiVersion $Api.Metrics -Query $q2 -Label "metrics-nofilter:$Label"
  }
  return $r
}

function ConvertTo-GiB($Bytes) { if ($null -eq $Bytes) { return '' }; return [math]::Round([double]$Bytes / 1GB, 1) }

function Get-Prop($Obj, [string]$Name, $Default = $null) {
  if ($null -eq $Obj) { return $Default }
  $p = $Obj.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# -- preflight ----------------------------------------------------------------------------
$ctx = Get-AzContext
if (-not $ctx) { throw 'No Azure context. Run Connect-AzAccount first.' }
$script:ArmBase = Get-ArmBase
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location).Path "afs-export-$runStamp" }
$script:Out = (New-Item -ItemType Directory -Path $OutputPath -Force).FullName
Write-Step "Export-AzFileSyncEnvironment v$ToolVersion -> $script:Out"
Write-Step "Signed in as $($ctx.Account.Id) , tenant $($ctx.Tenant.Id) , cloud $($ctx.Environment.Name)"

$subs = @()
if ($SubscriptionId) {
  foreach ($s in $SubscriptionId) {
    $so = Invoke-ArmGet -Path "/subscriptions/$s" -ApiVersion $Api.Subscriptions -Label "subscription:$s"
    if ($so) { $subs += $so } else { throw "Subscription $s is not visible to $($ctx.Account.Id)" }
  }
} else {
  $all = Invoke-ArmGet -Path '/subscriptions' -ApiVersion $Api.Subscriptions -List -Label 'subscriptions'
  if ($null -eq $all) { throw 'Could not list subscriptions (see the warning above). Run Connect-AzAccount [-Tenant <id>] and retry, or pass -SubscriptionId explicitly.' }
  $subs = @($all | Where-Object { (Get-Prop $_ 'state' '') -eq 'Enabled' -and (Get-Prop $_ 'tenantId' '') -eq $ctx.Tenant.Id })
}
if ($subs.Count -eq 0) { throw 'No subscriptions in scope.' }
Write-Step ("Scope: {0} subscription(s): {1}" -f $subs.Count, (($subs | ForEach-Object { "$($_.displayName) ($($_.subscriptionId))" }) -join ', '))

$inventory = [ordered]@{ storageSyncServices = @(); storageAccounts = @(); recoveryServicesVaults = @(); dataProtectionVaults = @(); privateDnsZones = @(); privateEndpoints = @() }
$summary = New-Object System.Collections.ArrayList   # lines of summary.md
[void]$summary.Add("# Azure File Sync + Azure Backup - environment export")
[void]$summary.Add("")
[void]$summary.Add("- Exported: $((Get-Date).ToUniversalTime().ToString('u')) by $($ctx.Account.Id) , tenant $($ctx.Tenant.Id) , tool v$ToolVersion")
[void]$summary.Add("- Subscriptions: " + (($subs | ForEach-Object { "$($_.displayName) (``$($_.subscriptionId)``)" }) -join ', '))
[void]$summary.Add("- Read-only export. No keys, SAS tokens or certificates were requested; well-known secret fields are blanked.")
[void]$summary.Add("")

# Cross-reference maps
$afsStorageAccounts = @{}     # storage account id (lower) -> list of "syncService/syncGroup/share"
$protectedShares = @{}        # "<storageAccountName>/<share>" (lower) -> protected item summary
$policyByName = @{}

# =========================================================================================
# 1. AZURE FILE SYNC
# =========================================================================================
[void]$summary.Add("## 1. Azure File Sync")
[void]$summary.Add("")
foreach ($sub in $subs) {
  $sid = $sub.subscriptionId
  Write-Step "[$($sub.displayName)] Storage Sync Services"
  $services = Invoke-ArmGet -Path "/subscriptions/$sid/providers/Microsoft.StorageSync/storageSyncServices" -ApiVersion $Api.StorageSync -List -Label "storageSyncServices:$sid"
  if ($null -eq $services) { continue }
  foreach ($svc in $services) {
    $script:Counts.storageSyncServices++
    $svcName = $svc.name; $svcId = $svc.id; $dir = "storagesync/" + (Get-SafeName "$($sub.displayName)__$svcName")
    Write-Step "  Storage Sync Service $svcName"
    $inventory.storageSyncServices += [ordered]@{ id = $svcId; name = $svcName; subscription = $sid; location = $svc.location }
    Save-Json "$dir/service.json" $svc
    $pecs = Invoke-ArmGet -Path "$svcId/privateEndpointConnections" -ApiVersion $Api.StorageSync -List -Label "sss-pec:$svcName"
    Save-Json "$dir/privateendpointconnections.json" $pecs
    $servers = Invoke-ArmGet -Path "$svcId/registeredServers" -ApiVersion $Api.StorageSync -List -Label "registeredServers:$svcName"
    if ($servers) { $script:Counts.registeredServers += $servers.Count }
    Save-Json "$dir/registeredservers.json" $servers
    $groups = Invoke-ArmGet -Path "$svcId/syncGroups" -ApiVersion $Api.StorageSync -List -Label "syncGroups:$svcName"
    Save-Json "$dir/syncgroups.json" $groups
    $allCloud = New-Object System.Collections.ArrayList; $allServer = New-Object System.Collections.ArrayList
    foreach ($g in @($groups)) {
      $script:Counts.syncGroups++
      $ce = Invoke-ArmGet -Path "$($g.id)/cloudEndpoints" -ApiVersion $Api.StorageSync -List -Label "cloudEndpoints:$svcName/$($g.name)"
      foreach ($c in @($ce)) { $script:Counts.cloudEndpoints++; [void]$allCloud.Add($c)
        $said = [string](Get-Prop $c.properties 'storageAccountResourceId' '')
        if ($said) { $k = $said.ToLower(); if (-not $afsStorageAccounts.ContainsKey($k)) { $afsStorageAccounts[$k] = New-Object System.Collections.ArrayList }; [void]$afsStorageAccounts[$k].Add("$svcName/$($g.name)/$(Get-Prop $c.properties 'azureFileShareName' '')") }
      }
      $se = Invoke-ArmGet -Path "$($g.id)/serverEndpoints" -ApiVersion $Api.StorageSync -List -Label "serverEndpoints:$svcName/$($g.name)"
      foreach ($s in @($se)) { $script:Counts.serverEndpoints++; [void]$allServer.Add($s) }
    }
    Save-Json "$dir/cloudendpoints.json" @($allCloud.ToArray())
    Save-Json "$dir/serverendpoints.json" @($allServer.ToArray())
    Save-Json "$dir/diagnostics.json" (Get-DiagnosticSettings $svcId $svcName)
    Save-Json "$dir/roleassignments.json" (Get-RoleAssignments $svcId $svcName)
    Save-Json "$dir/locks.json" (Get-Locks $svcId $svcName)
    if (-not $SkipMetrics) {
      $m = [ordered]@{}
      $m.ServerSyncSessionResult = Get-Metrics $svcId 'ServerSyncSessionResult' 'Maximum,Minimum,Count' 'P1D' "ServerEndpointName eq '*' and SyncDirection eq '*'" "$svcName/ServerSyncSessionResult" $MetricsLookbackDays
      $m.StorageSyncServerHeartbeat = Get-Metrics $svcId 'StorageSyncServerHeartbeat' 'Maximum,Count' 'P1D' "ServerName eq '*'" "$svcName/Heartbeat" $MetricsLookbackDays
      $m.StorageSyncSyncSessionPerItemErrorsCount = Get-Metrics $svcId 'StorageSyncSyncSessionPerItemErrorsCount' 'Average,Maximum' 'P1D' "ServerEndpointName eq '*'" "$svcName/PerItemErrors" $MetricsLookbackDays
      $m.StorageSyncRecallTotalSizeBytes = Get-Metrics $svcId 'StorageSyncRecallTotalSizeBytes' 'Total' 'P1D' "ServerName eq '*'" "$svcName/RecallSize" $MetricsLookbackDays
      $m.StorageSyncLowDiskModeCount = Get-Metrics $svcId 'StorageSyncLowDiskModeCount' 'Maximum' 'P1D' "ServerEndpointName eq '*'" "$svcName/LowDiskMode" $MetricsLookbackDays
      $m.StorageSyncAgentVersionExpirationDays = Get-Metrics $svcId 'StorageSyncAgentVersionExpirationDays' 'Maximum' 'P1D' "ServerName eq '*'" "$svcName/AgentExpiration" $MetricsLookbackDays
      $m.StorageSyncBatchTransferredFileBytes = Get-Metrics $svcId 'StorageSyncBatchTransferredFileBytes' 'Total' 'P1D' "ServerEndpointName eq '*' and SyncDirection eq '*'" "$svcName/BytesSynced" $MetricsLookbackDays
      Save-Json "$dir/metrics.json" $m
    }

    # -- summary block --
    [void]$summary.Add("### Storage Sync Service ``$svcName`` - $($sub.displayName), $($svc.location)")
    [void]$summary.Add("")
    [void]$summary.Add("- Incoming traffic policy: **$(Get-Prop $svc.properties 'incomingTrafficPolicy' '(n/a)')** , private endpoint connections: $(@($pecs).Count) , managed identity in use (useIdentity): $(Get-Prop $svc.properties 'useIdentity' '(n/a)') , identity: $(Get-Prop (Get-Prop $svc 'identity') 'type' 'none')")
    [void]$summary.Add("")
    [void]$summary.Add("| Registered server | OS | Agent | Agent status | Agent expires | Last heartbeat | Auth type | State |")
    [void]$summary.Add("|---|---|---|---|---|---|---|---|")
    foreach ($s in @($servers)) { $p = $s.properties
      [void]$summary.Add("| $(Get-Prop $p 'friendlyName' (Get-Prop $p 'serverName' $s.name)) | $(Get-Prop $p 'serverOSVersion' '')  | $(Get-Prop $p 'agentVersion' '') | $(Get-Prop $p 'agentVersionStatus' '') | $(Get-Prop $p 'agentVersionExpirationDate' '') | $(Get-Prop $p 'lastHeartBeat' '') | $(Get-Prop $p 'activeAuthType' (Get-Prop $p 'serverRole' '')) | $(Get-Prop $p 'provisioningState' '') |")
    }
    [void]$summary.Add("")
    foreach ($g in @($groups)) {
      [void]$summary.Add("#### Sync group ``$($g.name)``")
      [void]$summary.Add("")
      foreach ($c in @($allCloud | Where-Object { $_.id -like "$($g.id)/*" })) { $p = $c.properties
        $sa = ([string](Get-Prop $p 'storageAccountResourceId' '')).Split('/')[-1]
        $ces = Get-Prop $p 'changeEnumerationStatus'
        $lastEnum = if ($ces) { Get-Prop (Get-Prop $ces 'lastCompletedEnumeration') 'completedTimestamp' '' } else { '' }
        [void]$summary.Add("- **Cloud endpoint** -> storage account ``$sa`` share ``$(Get-Prop $p 'azureFileShareName' '')`` , backupEnabled(flag)=$(Get-Prop $p 'backupEnabled' '') , last change enumeration: $lastEnum , state $(Get-Prop $p 'provisioningState' '')")
      }
      [void]$summary.Add("")
      [void]$summary.Add("| Server endpoint (server , path) | Tiering | VFS % | Date policy (days) | Initial download | Local cache | Combined health | Upload / Download | Persistent not syncing | Last sync (up / down) | Tiering health | Cache hit % | Space saved |")
      [void]$summary.Add("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
      foreach ($s in @($allServer | Where-Object { $_.id -like "$($g.id)/*" })) { $p = $s.properties; $ss = Get-Prop $p 'syncStatus'; $ct = Get-Prop $p 'cloudTieringStatus'
        $up = Get-Prop (Get-Prop $ss 'uploadStatus') 'lastSyncSuccessTimestamp' ''; $down = Get-Prop (Get-Prop $ss 'downloadStatus') 'lastSyncSuccessTimestamp' ''
        $cache = Get-Prop (Get-Prop $ct 'cachePerformance') 'cacheHitRatio' ''
        $saved = Get-Prop (Get-Prop $ct 'spaceSavings') 'spaceSavingsBytes' ''
        [void]$summary.Add("| $(Get-Prop $p 'serverName' (Get-Prop $p 'friendlyName' $s.name)) , ``$(Get-Prop $p 'serverLocalPath' '')`` | $(Get-Prop $p 'cloudTiering' '') | $(Get-Prop $p 'volumeFreeSpacePercent' '') | $(Get-Prop $p 'tierFilesOlderThanDays' '') | $(Get-Prop $p 'initialDownloadPolicy' '') | $(Get-Prop $p 'localCacheMode' '') | $(Get-Prop $ss 'combinedHealth' '') | $(Get-Prop $ss 'uploadHealth' '') / $(Get-Prop $ss 'downloadHealth' '') | $(Get-Prop $ss 'totalPersistentFilesNotSyncingCount' '') | $up / $down | $(Get-Prop $ct 'health' '') | $cache | $(ConvertTo-GiB $saved) GiB |")
      }
      [void]$summary.Add("")
    }
  }
}
if ($script:Counts.storageSyncServices -eq 0) { [void]$summary.Add("_No Storage Sync Service found in scope._"); [void]$summary.Add("") }

# =========================================================================================
# 2. STORAGE ACCOUNTS + FILE SHARES
# =========================================================================================
[void]$summary.Add("## 2. Storage accounts and Azure file shares")
[void]$summary.Add("")
$shareRows = New-Object System.Collections.ArrayList
foreach ($sub in $subs) {
  $sid = $sub.subscriptionId
  Write-Step "[$($sub.displayName)] Storage accounts"
  $subLocks = Get-Locks "/subscriptions/$sid" "subscription:$sid"
  Save-Json ("locks/" + (Get-SafeName $sub.displayName) + ".json") $subLocks
  $pricing = Invoke-ArmGet -Path "/subscriptions/$sid/providers/Microsoft.Security/pricings/StorageAccounts" -ApiVersion $Api.SecurityPricing -Label "defender-pricing:$sid"
  Save-Json ("defender/" + (Get-SafeName $sub.displayName) + "-pricing-StorageAccounts.json") $pricing
  $accounts = Invoke-ArmGet -Path "/subscriptions/$sid/providers/Microsoft.Storage/storageAccounts" -ApiVersion $Api.Storage -List -Label "storageAccounts:$sid"
  if ($null -eq $accounts) { continue }
  foreach ($acct in $accounts) {
    $script:Counts.storageAccounts++
    $aid = $acct.id; $aname = $acct.name; $p = $acct.properties
    $referenced = $afsStorageAccounts.ContainsKey($aid.ToLower())
    $dir = "storage/" + (Get-SafeName "$($sub.displayName)__$aname")
    Write-Step "  Storage account $aname$(if ($referenced) { ' (Azure File Sync cloud endpoint)' })"
    $inventory.storageAccounts += [ordered]@{ id = $aid; name = $aname; subscription = $sid; location = $acct.location; referencedByAzureFileSync = $referenced; syncEndpoints = @(if ($referenced) { $afsStorageAccounts[$aid.ToLower()].ToArray() }) }
    Save-Json "$dir/account.json" $acct
    $fs = Invoke-ArmGet -Path "$aid/fileServices/default" -ApiVersion $Api.Storage -Label "fileService:$aname"
    Save-Json "$dir/fileservice.json" $fs
    $shares = Invoke-ArmGet -Path "$aid/fileServices/default/shares" -ApiVersion $Api.Storage -Query ('$expand=snapshots') -List -Label "shares+snapshots:$aname"
    $deleted = Invoke-ArmGet -Path "$aid/fileServices/default/shares" -ApiVersion $Api.Storage -Query ('$expand=deleted') -List -Label "shares+deleted:$aname"
    # live shares carry shareUsageBytes only on the single-share GET with $expand=stats
    $liveShares = @($shares | Where-Object { -not (Get-Prop $_.properties 'snapshotTime') })
    $detailed = New-Object System.Collections.ArrayList
    foreach ($sh in $liveShares) {
      $d = Invoke-ArmGet -Path "$aid/fileServices/default/shares/$($sh.name)" -ApiVersion $Api.Storage -Query ('$expand=stats') -Label "share-stats:$aname/$($sh.name)"
      if ($d) { [void]$detailed.Add($d) } else { [void]$detailed.Add($sh) }
    }
    $script:Counts.fileShares += $liveShares.Count
    Save-Json "$dir/shares.json" ([ordered]@{ shares = @($detailed.ToArray()); snapshots = @($shares | Where-Object { Get-Prop $_.properties 'snapshotTime' }); softDeleted = @($deleted | Where-Object { Get-Prop $_.properties 'deleted' }) })
    Save-Json "$dir/diagnostics-account.json" (Get-DiagnosticSettings $aid $aname)
    Save-Json "$dir/diagnostics-fileservice.json" (Get-DiagnosticSettings "$aid/fileServices/default" "$aname/file")
    Save-Json "$dir/roleassignments.json" (Get-RoleAssignments $aid $aname)
    Save-Json "$dir/locks.json" (Get-Locks $aid $aname)
    Save-Json "$dir/defender.json" (Invoke-ArmGet -Path "$aid/providers/Microsoft.Security/defenderForStorageSettings/current" -ApiVersion $Api.DefenderStorage -Label "defender:$aname")
    if (-not $SkipMetrics -and $liveShares.Count -gt 0) {
      $m = [ordered]@{}
      $m.FileCapacity = Get-Metrics "$aid/fileServices/default" 'FileCapacity,FileShareSnapshotSize,FileShareSnapshotCount,FileCount' 'Average' 'PT1H' "FileShare eq '*'" "$aname/capacity" 1
      $m.TransactionsByAuth = Get-Metrics "$aid/fileServices/default" 'Transactions' 'Total' 'P1D' "Authentication eq '*'" "$aname/txn-auth" $MetricsLookbackDays
      $m.TransactionsByResponse = Get-Metrics "$aid/fileServices/default" 'Transactions' 'Total' 'P1D' "ResponseType eq '*'" "$aname/txn-response" $MetricsLookbackDays
      $m.Availability = Get-Metrics "$aid/fileServices/default" 'Availability' 'Average,Minimum' 'P1D' $null "$aname/availability" $MetricsLookbackDays
      Save-Json "$dir/metrics.json" $m
    }
    # -- summary --
    $na = Get-Prop $p 'networkAcls'; $enc = Get-Prop $p 'encryption'; $idauth = Get-Prop $p 'azureFilesIdentityBasedAuthentication'
    $pe = @(Get-Prop $p 'privateEndpointConnections' @()).Count
    $sd = Get-Prop (Get-Prop $fs.properties 'shareDeleteRetentionPolicy') 'enabled' ''
    $sdd = Get-Prop (Get-Prop $fs.properties 'shareDeleteRetentionPolicy') 'days' ''
    $smb = Get-Prop (Get-Prop (Get-Prop $fs.properties 'protocolSettings') 'smb')
    [void]$summary.Add("### Storage account ``$aname`` - $($sub.displayName), $($acct.location)$(if ($referenced) { ' - **Azure File Sync cloud endpoint(s): ' + ($afsStorageAccounts[$aid.ToLower()] -join ', ') + '**' })")
    [void]$summary.Add("")
    [void]$summary.Add("| Setting | Value |")
    [void]$summary.Add("|---|---|")
    [void]$summary.Add("| SKU / kind / access tier | $($acct.sku.name) / $($acct.kind) / $(Get-Prop $p 'accessTier' '') |")
    [void]$summary.Add("| Large file shares | $(Get-Prop $p 'largeFileSharesState' '') |")
    [void]$summary.Add("| Minimum TLS / HTTPS only | $(Get-Prop $p 'minimumTlsVersion' '') / $(Get-Prop $p 'supportsHttpsTrafficOnly' '') |")
    [void]$summary.Add("| Public network access | $(Get-Prop $p 'publicNetworkAccess' '(n/a)') |")
    [void]$summary.Add("| Firewall default action / bypass | $(Get-Prop $na 'defaultAction' '') / $(Get-Prop $na 'bypass' '') |")
    [void]$summary.Add("| IP rules / VNet rules / resource-instance rules | $(@(Get-Prop $na 'ipRules' @()).Count) / $(@(Get-Prop $na 'virtualNetworkRules' @()).Count) / $(@(Get-Prop $na 'resourceAccessRules' @()).Count) |")
    [void]$summary.Add("| Private endpoint connections | $pe |")
    [void]$summary.Add("| Shared key access allowed | $(Get-Prop $p 'allowSharedKeyAccess' 'true (default)') |")
    [void]$summary.Add("| Default to Entra auth in portal | $(Get-Prop $p 'defaultToOAuthAuthentication' '') |")
    [void]$summary.Add("| Identity-based auth (directory service) | $(Get-Prop $idauth 'directoryServiceOptions' 'None') |")
    [void]$summary.Add("| Encryption key source / infra encryption | $(Get-Prop $enc 'keySource' '') / $(Get-Prop $enc 'requireInfrastructureEncryption' '') |")
    [void]$summary.Add("| Key creation (key1 / key2) | $(Get-Prop (Get-Prop $p 'keyCreationTime') 'key1' '') / $(Get-Prop (Get-Prop $p 'keyCreationTime') 'key2' '') |")
    [void]$summary.Add("| Key expiration policy (days) | $(Get-Prop (Get-Prop $p 'keyPolicy') 'keyExpirationPeriodInDays' 'none') |")
    [void]$summary.Add("| Share soft delete | $sd ($sdd days) |")
    [void]$summary.Add("| SMB versions / auth methods / Kerberos enc / channel enc | $(Get-Prop $smb 'versions' '(default)') / $(Get-Prop $smb 'authenticationMethods' '(default)') / $(Get-Prop $smb 'kerberosTicketEncryption' '(default)') / $(Get-Prop $smb 'channelEncryption' '(default)') |")
    [void]$summary.Add("| Resource locks | $(@(Get-Prop (Get-Locks $aid "$aname-summary") @()).Count) |")
    [void]$summary.Add("")
    [void]$summary.Add("| File share | Quota GiB | Used GiB | Access tier | Protocol | Snapshots | Lease | Azure File Sync |")
    [void]$summary.Add("|---|---|---|---|---|---|---|---|")
    foreach ($d in $detailed) { $sp = $d.properties
      $snapCount = @($shares | Where-Object { $_.name -eq $d.name -and (Get-Prop $_.properties 'snapshotTime') }).Count
      $isAfs = if ($referenced) { @($afsStorageAccounts[$aid.ToLower()] | Where-Object { $_ -like "*/$($d.name)" }).Count -gt 0 } else { $false }
      [void]$summary.Add("| ``$($d.name)`` | $(Get-Prop $sp 'shareQuota' '') | $(ConvertTo-GiB (Get-Prop $sp 'shareUsageBytes')) | $(Get-Prop $sp 'accessTier' '') | $(Get-Prop $sp 'enabledProtocols' 'SMB') | $snapCount | $(Get-Prop $sp 'leaseStatus' '') | $(if ($isAfs) { 'yes' } else { '' }) |")
      [void]$shareRows.Add([ordered]@{ subscription = $sub.displayName; storageAccount = $aname; share = $d.name; key = ("$aname/$($d.name)").ToLower(); afs = $isAfs })
    }
    if ($detailed.Count -eq 0) { [void]$summary.Add("| _(no file shares)_ | | | | | | | |") }
    [void]$summary.Add("")
  }
}

# =========================================================================================
# 3. AZURE BACKUP
# =========================================================================================
[void]$summary.Add("## 3. Azure Backup")
[void]$summary.Add("")
$jobFrom = (Get-Date).ToUniversalTime().AddDays(-1 * $JobLookbackDays)
$jobTo = (Get-Date).ToUniversalTime()
foreach ($sub in $subs) {
  $sid = $sub.subscriptionId
  Write-Step "[$($sub.displayName)] Recovery Services vaults"
  $vaults = Invoke-ArmGet -Path "/subscriptions/$sid/providers/Microsoft.RecoveryServices/vaults" -ApiVersion $Api.RecoveryServices -List -Label "vaults:$sid"
  foreach ($v in @($vaults)) {
    $script:Counts.recoveryServicesVaults++
    $vid = $v.id; $vname = $v.name; $dir = "backup/" + (Get-SafeName "$($sub.displayName)__$vname")
    Write-Step "  Recovery Services vault $vname"
    $inventory.recoveryServicesVaults += [ordered]@{ id = $vid; name = $vname; subscription = $sid; location = $v.location }
    Save-Json "$dir/vault.json" $v
    $vcfg = Invoke-ArmGet -Path "$vid/backupconfig/vaultconfig" -ApiVersion $Api.Backup -Label "vaultconfig:$vname"
    Save-Json "$dir/vaultconfig.json" $vcfg
    $scfg = Invoke-ArmGet -Path "$vid/backupstorageconfig/vaultstorageconfig" -ApiVersion $Api.Backup -Label "vaultstorageconfig:$vname"
    Save-Json "$dir/storageconfig.json" $scfg
    $pols = Invoke-ArmGet -Path "$vid/backupPolicies" -ApiVersion $Api.Backup -List -Label "backupPolicies:$vname"
    if ($pols) { $script:Counts.backupPolicies += $pols.Count }
    Save-Json "$dir/policies.json" $pols
    $containers = Invoke-ArmGet -Path "$vid/backupProtectionContainers" -ApiVersion $Api.Backup -Query ('$filter=' + [uri]::EscapeDataString("backupManagementType eq 'AzureStorage'")) -List -Label "containers:$vname"
    Save-Json "$dir/containers.json" $containers
    $items = Invoke-ArmGet -Path "$vid/backupProtectedItems" -ApiVersion $Api.Backup -List -Label "protectedItems:$vname"
    if ($items) { $script:Counts.protectedItems += $items.Count }
    Save-Json "$dir/protecteditems.json" $items
    $jf = "startTime eq '{0}' and endTime eq '{1}'" -f $jobFrom.ToString('yyyy-MM-dd hh:mm:ss tt', [cultureinfo]::InvariantCulture), $jobTo.ToString('yyyy-MM-dd hh:mm:ss tt', [cultureinfo]::InvariantCulture)
    $jobs = Invoke-ArmGet -Path "$vid/backupJobs" -ApiVersion $Api.Backup -Query ('$filter=' + [uri]::EscapeDataString($jf)) -List -Label "jobs:$vname"
    if ($jobs) { $script:Counts.backupJobs += $jobs.Count }
    Save-Json "$dir/jobs.json" $jobs
    Save-Json "$dir/resourceguardproxies.json" (Invoke-ArmGet -Path "$vid/backupResourceGuardProxies" -ApiVersion $Api.Backup -List -Label "resourceGuardProxies:$vname")
    Save-Json "$dir/diagnostics.json" (Get-DiagnosticSettings $vid $vname)
    Save-Json "$dir/roleassignments.json" (Get-RoleAssignments $vid $vname)
    Save-Json "$dir/locks.json" (Get-Locks $vid $vname)
    # -- summary --
    $vp = $v.properties; $sec = Get-Prop $vp 'securitySettings'; $red = Get-Prop $vp 'redundancySettings'; $mon = Get-Prop (Get-Prop $vp 'monitoringSettings') 'azureMonitorAlertSettings'
    [void]$summary.Add("### Recovery Services vault ``$vname`` - $($sub.displayName), $($v.location)")
    [void]$summary.Add("")
    [void]$summary.Add("| Setting | Value |")
    [void]$summary.Add("|---|---|")
    [void]$summary.Add("| Storage redundancy / cross-region restore | $(Get-Prop $red 'standardTierStorageRedundancy' (Get-Prop $scfg.properties 'storageModelType' '')) / $(Get-Prop $red 'crossRegionRestore' (Get-Prop $scfg.properties 'crossRegionRestoreFlag' '')) |")
    [void]$summary.Add("| Soft delete (state / days / always-on) | $(Get-Prop (Get-Prop $sec 'softDeleteSettings') 'softDeleteState' (Get-Prop $vcfg.properties 'softDeleteFeatureState' '')) / $(Get-Prop (Get-Prop $sec 'softDeleteSettings') 'softDeleteRetentionPeriodInDays' '') / $(Get-Prop (Get-Prop $sec 'softDeleteSettings') 'enhancedSecurityState' (Get-Prop $vcfg.properties 'enhancedSecurityState' '')) |")
    [void]$summary.Add("| Immutability | $(Get-Prop (Get-Prop $sec 'immutabilitySettings') 'state' 'Disabled') |")
    [void]$summary.Add("| Multi-user authorization (Resource Guard) | $(Get-Prop (Get-Prop $sec 'multiUserAuthorization') 'state' (Get-Prop $sec 'multiUserAuthorization' 'Disabled')) |")
    [void]$summary.Add("| Public network access | $(Get-Prop $vp 'publicNetworkAccess' '') |")
    [void]$summary.Add("| Azure Monitor alerts for all job failures | $(Get-Prop $mon 'alertsForAllJobFailures' '(n/a)') |")
    [void]$summary.Add("| Encryption (CMK) | $(if (Get-Prop (Get-Prop $vp 'encryption') 'keyVaultProperties') { 'customer-managed' } else { 'platform-managed' }) |")
    [void]$summary.Add("")
    [void]$summary.Add("| Backup policy (AzureStorage) | Schedule | Snapshot retention | Vault tier | Protected items |")
    [void]$summary.Add("|---|---|---|---|---|")
    foreach ($pol in @($pols | Where-Object { (Get-Prop $_.properties 'backupManagementType') -eq 'AzureStorage' })) { $pp = $pol.properties
      $policyByName[$pol.name.ToLower()] = $pol
      $schp = Get-Prop $pp 'schedulePolicy'; $freq = Get-Prop $schp 'scheduleRunFrequency' ''
      $sched = "$freq"
      if ($freq -eq 'Hourly') { $h = Get-Prop $schp 'hourlySchedule'; $sched += " every $(Get-Prop $h 'interval' '')h from $(Get-Prop $h 'scheduleWindowStartTime' '') for $(Get-Prop $h 'scheduleWindowDuration' '')h" } else { $sched += " at $(@(Get-Prop $schp 'scheduleRunTimes' @()) -join ',')" }
      $ret = Get-Prop $pp 'retentionPolicy'; $dr = Get-Prop (Get-Prop (Get-Prop $ret 'dailySchedule') 'retentionDuration') 'count' ''
      $wr = Get-Prop (Get-Prop (Get-Prop $ret 'weeklySchedule') 'retentionDuration') 'count' ''; $mr = Get-Prop (Get-Prop (Get-Prop $ret 'monthlySchedule') 'retentionDuration') 'count' ''; $yr = Get-Prop (Get-Prop (Get-Prop $ret 'yearlySchedule') 'retentionDuration') 'count' ''
      $vr = Get-Prop $pp 'vaultRetentionPolicy'
      $vaultTier = if ($vr) { "snapshots $(Get-Prop $vr 'snapshotRetentionInDays' '')d , vault daily $(Get-Prop (Get-Prop (Get-Prop (Get-Prop $vr 'vaultRetention') 'dailySchedule') 'retentionDuration') 'count' '')d weekly $(Get-Prop (Get-Prop (Get-Prop (Get-Prop $vr 'vaultRetention') 'weeklySchedule') 'retentionDuration') 'count' '')w monthly $(Get-Prop (Get-Prop (Get-Prop (Get-Prop $vr 'vaultRetention') 'monthlySchedule') 'retentionDuration') 'count' '')m yearly $(Get-Prop (Get-Prop (Get-Prop (Get-Prop $vr 'vaultRetention') 'yearlySchedule') 'retentionDuration') 'count' '')y" } else { 'snapshot-only' }
      [void]$summary.Add("| ``$($pol.name)`` | $sched ($(Get-Prop $pp 'timeZone' '')) | daily $dr d , weekly $wr w , monthly $mr m , yearly $yr y | $vaultTier | $(Get-Prop $pp 'protectedItemsCount' '') |")
    }
    [void]$summary.Add("")
    [void]$summary.Add("| Protected item | Type | Policy | Protection state | Last backup | Last backup time | Recovery points | Oldest RP |")
    [void]$summary.Add("|---|---|---|---|---|---|---|---|")
    foreach ($it in @($items)) { $ip = $it.properties
      $x = Get-Prop $ip 'extendedInfo'
      [void]$summary.Add("| $(Get-Prop $ip 'friendlyName' $it.name) | $(Get-Prop $ip 'workloadType' (Get-Prop $ip 'protectedItemType' '')) | $(Get-Prop $ip 'policyName' '') | $(Get-Prop $ip 'protectionState' '') | $(Get-Prop $ip 'lastBackupStatus' '') | $(Get-Prop $ip 'lastBackupTime' '') | $(Get-Prop $x 'recoveryPointCount' '') | $(Get-Prop $x 'oldestRecoveryPoint' '') |")
      if ((Get-Prop $ip 'workloadType' '') -eq 'AzureFileShare') {
        $srcId = [string](Get-Prop $ip 'sourceResourceId' ''); $san = if ($srcId) { $srcId.Split('/')[-1] } else { ([string](Get-Prop $ip 'containerName' '')).Split(';')[-1] }
        $protectedShares[("$san/$(Get-Prop $ip 'friendlyName' '')").ToLower()] = [ordered]@{ vault = $vname; policy = Get-Prop $ip 'policyName' ''; state = Get-Prop $ip 'protectionState' ''; lastBackupStatus = Get-Prop $ip 'lastBackupStatus' '' }
      }
    }
    [void]$summary.Add("")
    $jstats = @($jobs | Group-Object { "$(Get-Prop $_.properties 'operation' '')/$(Get-Prop $_.properties 'status' '')" } | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })
    [void]$summary.Add("- Jobs (last $JobLookbackDays days): " + $(if ($jstats.Count) { $jstats -join ' , ' } else { 'none' }))
    [void]$summary.Add("")
  }
  # Data Protection vaults (blob / disk / AKS backups)
  $dpv = Invoke-ArmGet -Path "/subscriptions/$sid/providers/Microsoft.DataProtection/backupVaults" -ApiVersion $Api.DataProtection -List -Label "dataProtectionVaults:$sid"
  foreach ($bv in @($dpv)) {
    $script:Counts.dataProtectionVaults++
    $dir = "backup-dataprotection/" + (Get-SafeName "$($sub.displayName)__$($bv.name)")
    $inventory.dataProtectionVaults += [ordered]@{ id = $bv.id; name = $bv.name; subscription = $sid; location = $bv.location }
    Save-Json "$dir/vault.json" $bv
    Save-Json "$dir/policies.json" (Invoke-ArmGet -Path "$($bv.id)/backupPolicies" -ApiVersion $Api.DataProtection -List -Label "dp-policies:$($bv.name)")
    Save-Json "$dir/instances.json" (Invoke-ArmGet -Path "$($bv.id)/backupInstances" -ApiVersion $Api.DataProtection -List -Label "dp-instances:$($bv.name)")
  }
}
if ($script:Counts.recoveryServicesVaults -eq 0) { [void]$summary.Add("_No Recovery Services vault found in scope._"); [void]$summary.Add("") }

# share <-> backup cross-reference
[void]$summary.Add("### File share backup coverage")
[void]$summary.Add("")
[void]$summary.Add("| Storage account | Share | Azure File Sync | Protected by | Policy | State | Last backup |")
[void]$summary.Add("|---|---|---|---|---|---|---|")
$coverage = New-Object System.Collections.ArrayList
foreach ($r in $shareRows) {
  $pr = if ($protectedShares.ContainsKey($r.key)) { $protectedShares[$r.key] } else { $null }
  [void]$summary.Add("| ``$($r.storageAccount)`` | ``$($r.share)`` | $(if ($r.afs) { 'yes' } else { '' }) | $(if ($pr) { $pr.vault } else { '**NOT PROTECTED**' }) | $(if ($pr) { $pr.policy } else { '' }) | $(if ($pr) { $pr.state } else { '' }) | $(if ($pr) { $pr.lastBackupStatus } else { '' }) |")
  [void]$coverage.Add([ordered]@{ subscription = $r.subscription; storageAccount = $r.storageAccount; share = $r.share; azureFileSync = $r.afs; protected = [bool]$pr; vault = $(if ($pr) { $pr.vault } else { $null }); policy = $(if ($pr) { $pr.policy } else { $null }); protectionState = $(if ($pr) { $pr.state } else { $null }); lastBackupStatus = $(if ($pr) { $pr.lastBackupStatus } else { $null }) })
}
if ($shareRows.Count -eq 0) { [void]$summary.Add("| _(no file shares)_ | | | | | | |") }
[void]$summary.Add("")
Save-Json "backup/share-coverage.json" @($coverage.ToArray())

# =========================================================================================
# 4. NETWORK (private DNS + private endpoints relevant to Files / File Sync)
# =========================================================================================
[void]$summary.Add("## 4. Private networking for Azure Files / Azure File Sync")
[void]$summary.Add("")
$zonesOut = New-Object System.Collections.ArrayList; $pesOut = New-Object System.Collections.ArrayList
foreach ($sub in $subs) {
  $sid = $sub.subscriptionId
  Write-Step "[$($sub.displayName)] Private DNS zones + private endpoints"
  $zones = Invoke-ArmGet -Path "/subscriptions/$sid/providers/Microsoft.Network/privateDnsZones" -ApiVersion $Api.PrivateDns -List -Label "privateDnsZones:$sid"
  foreach ($z in @($zones | Where-Object { $_.name -like 'privatelink.file.*' -or $_.name -like 'privatelink.afs.*' -or $_.name -like '*.privatelink.afs.*' })) {
    $script:Counts.privateDnsZones++
    $links = Invoke-ArmGet -Path "$($z.id)/virtualNetworkLinks" -ApiVersion $Api.PrivateDns -List -Label "vnetLinks:$($z.name)"
    $recs = Invoke-ArmGet -Path "$($z.id)/A" -ApiVersion $Api.PrivateDns -List -Label "aRecords:$($z.name)"
    [void]$zonesOut.Add([ordered]@{ zone = $z; virtualNetworkLinks = @($links); aRecords = @($recs) })
    $inventory.privateDnsZones += [ordered]@{ id = $z.id; name = $z.name; subscription = $sid }
    [void]$summary.Add("- Private DNS zone ``$($z.name)`` ($($sub.displayName)): $(@($links).Count) VNet link(s), $(@($recs).Count) A record(s): " + ((@($recs) | ForEach-Object { "$($_.name)->$(@($_.properties.aRecords | ForEach-Object { $_.ipv4Address }) -join '/')" }) -join ', '))
  }
  $pes = Invoke-ArmGet -Path "/subscriptions/$sid/providers/Microsoft.Network/privateEndpoints" -ApiVersion $Api.Network -List -Label "privateEndpoints:$sid"
  foreach ($pe in @($pes)) {
    $targets = @(@(Get-Prop $pe.properties 'privateLinkServiceConnections' @()) + @(Get-Prop $pe.properties 'manualPrivateLinkServiceConnections' @()))
    $relevant = @($targets | Where-Object { $t = [string](Get-Prop $_.properties 'privateLinkServiceId' ''); $t -match '/Microsoft\.Storage/storageAccounts/' -or $t -match '/Microsoft\.StorageSync/storageSyncServices/' })
    if ($relevant.Count -eq 0) { continue }
    $script:Counts.privateEndpoints++
    $zg = Invoke-ArmGet -Path "$($pe.id)/privateDnsZoneGroups" -ApiVersion $Api.Network -List -Label "dnsZoneGroups:$($pe.name)"
    [void]$pesOut.Add([ordered]@{ privateEndpoint = $pe; privateDnsZoneGroups = @($zg) })
    $inventory.privateEndpoints += [ordered]@{ id = $pe.id; name = $pe.name; subscription = $sid; targets = @($relevant | ForEach-Object { [ordered]@{ target = $_.properties.privateLinkServiceId; groupIds = @($_.properties.groupIds) } }) }
    [void]$summary.Add("- Private endpoint ``$($pe.name)`` ($($sub.displayName)) -> " + (($relevant | ForEach-Object { "$(([string]$_.properties.privateLinkServiceId).Split('/')[-1]) [$(@($_.properties.groupIds) -join ',')] $(Get-Prop (Get-Prop $_.properties 'privateLinkServiceConnectionState') 'status' '')" }) -join '; ') + " , DNS zone groups: $(@($zg).Count) , subnet ``$(([string](Get-Prop (Get-Prop $pe.properties 'subnet') 'id' '')).Split('/')[-1])``")
  }
}
# Hybrid-connectivity topology via Azure Resource Graph (ExpressRoute, gateways, connections, VNets, DNS Private Resolver)
Write-Step "Hybrid connectivity topology (Resource Graph)"
$topo = @()
try {
  $q = "Resources | where type in~ ('microsoft.network/expressroutecircuits','microsoft.network/virtualnetworkgateways','microsoft.network/expressroutegateways','microsoft.network/connections','microsoft.network/virtualnetworks','microsoft.network/dnsresolvers','microsoft.network/dnsforwardingrulesets','microsoft.network/virtualhubs','microsoft.network/azurefirewalls') | project id, name, type, location, resourceGroup, subscriptionId, properties"
  $payload = @{ subscriptions = @($subs | ForEach-Object { $_.subscriptionId }); query = $q; options = @{ resultFormat = 'objectArray' } } | ConvertTo-Json -Depth 6
  $resp = Invoke-AzRestMethod -Method POST -Uri "$script:ArmBase/providers/Microsoft.ResourceGraph/resources?api-version=$($Api.ResourceGraph)" -Payload $payload
  if ($resp.StatusCode -lt 400) { $j = $resp.Content | ConvertFrom-Json; $topo = @(Get-Prop $j 'data' @()) } else { Add-ExportError 'resourceGraph:topology' "HTTP $($resp.StatusCode) $($resp.Content)" }
} catch { Add-ExportError 'resourceGraph:topology' $_.Exception.Message }
Save-Json "network/topology.json" $topo
$byType = @($topo | Group-Object { ([string]$_.type).ToLower() } | Sort-Object Name | ForEach-Object { "$($_.Name.Split('/')[-1])=$($_.Count)" })
[void]$summary.Add("- Hybrid connectivity topology (Resource Graph): " + $(if ($byType.Count) { $byType -join ', ' } else { 'none found / not captured' }))
foreach ($t in @($topo | Where-Object { ([string]$_.type) -match 'expressRouteCircuits|virtualNetworkGateways|connections|dnsResolvers$' })) {
  $tp = Get-Prop $t 'properties'
  $extra = ''
  if ([string]$t.type -match 'expressRouteCircuits') { $spp = Get-Prop $tp 'serviceProviderProperties'; $extra = "provider=$(Get-Prop $spp 'serviceProviderName' '') $(Get-Prop $spp 'peeringLocation' '') $(Get-Prop $spp 'bandwidthInMbps' '')Mbps state=$(Get-Prop $tp 'circuitProvisioningState' '')/$(Get-Prop $tp 'serviceProviderProvisioningState' '') peerings=$((@(Get-Prop $tp 'peerings' @()) | ForEach-Object { $_.name }) -join ',')" }
  elseif ([string]$t.type -match 'virtualNetworkGateways') { $extra = "type=$(Get-Prop $tp 'gatewayType' '') sku=$(Get-Prop (Get-Prop $tp 'sku') 'name' '')" }
  elseif ([string]$t.type -match 'connections') { $extra = "type=$(Get-Prop $tp 'connectionType' '') status=$(Get-Prop $tp 'connectionStatus' '')" }
  elseif ([string]$t.type -match 'dnsResolvers$') { $extra = "vnet=$(([string](Get-Prop (Get-Prop $tp 'virtualNetwork') 'id' '')).Split('/')[-1])" }
  [void]$summary.Add("  - $(([string]$t.type).Split('/')[-1]) ``$($t.name)`` ($($t.location)) $extra")
}
Save-Json "network/privatednszones.json" @($zonesOut.ToArray())
Save-Json "network/privateendpoints.json" @($pesOut.ToArray())
if ($script:Counts.privateDnsZones -eq 0 -and $script:Counts.privateEndpoints -eq 0) { [void]$summary.Add("_No privatelink.file / privatelink.afs DNS zone and no storage/File Sync private endpoint found - public endpoints are in use._") }
[void]$summary.Add("")

# =========================================================================================
# 4b. MONITORING (metric alert rules scoped to the resources above)
# =========================================================================================
[void]$summary.Add("## 4b. Alert rules")
[void]$summary.Add("")
$watched = @{}
foreach ($x in @($inventory.storageSyncServices) + @($inventory.storageAccounts) + @($inventory.recoveryServicesVaults)) { $watched[([string]$x.id).ToLower()] = $x.name }
$alertsOut = New-Object System.Collections.ArrayList
foreach ($sub in $subs) {
  $sid = $sub.subscriptionId
  Write-Step "[$($sub.displayName)] Metric alert rules"
  $alerts = Invoke-ArmGet -Path "/subscriptions/$sid/providers/Microsoft.Insights/metricAlerts" -ApiVersion $Api.MetricAlerts -List -Label "metricAlerts:$sid"
  foreach ($a in @($alerts)) {
    $scopes = @(Get-Prop $a.properties 'scopes' @())
    $hit = @($scopes | Where-Object { $watched.ContainsKey(([string]$_).ToLower()) })
    if ($hit.Count -eq 0) { continue }
    [void]$alertsOut.Add($a)
    $sig = @()
    $crit = Get-Prop $a.properties 'criteria'
    if ($crit) { $sig = @(@(Get-Prop $crit 'allOf' @()) | ForEach-Object { "$(Get-Prop $_ 'metricName' '') $(Get-Prop $_ 'operator' '') $(Get-Prop $_ 'threshold' '')" }) }
    [void]$summary.Add("- ``$($a.name)`` ($($sub.displayName)) enabled=$(Get-Prop $a.properties 'enabled' '') severity=$(Get-Prop $a.properties 'severity' '') -> $(($hit | ForEach-Object { $watched[([string]$_).ToLower()] }) -join ', ') : $($sig -join '; ')")
  }
}
Save-Json "monitor/metricalerts.json" @($alertsOut.ToArray())
if ($alertsOut.Count -eq 0) { [void]$summary.Add("_No metric alert rule targets a Storage Sync Service, storage account or Recovery Services vault in scope._") }
[void]$summary.Add("")

# =========================================================================================
# 5. MANIFEST + SUMMARY + ZIP
# =========================================================================================
Save-Json "inventory.json" $inventory
Save-Json "errors.json" @($script:Errors.ToArray())
[void]$summary.Add("## 5. Export health")
[void]$summary.Add("")
[void]$summary.Add("- Counts: " + (($script:Counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' , '))
[void]$summary.Add("- Calls that failed (see errors.json): $($script:Errors.Count)" + $(if ($script:Errors.Count) { ' - a 403 usually means the signed-in account lacks Reader on that resource; re-run with a broader role or note the gap in the assessment.' } else { '' }))
[void]$summary.Add("- Next step: ``.\Assess-AzFileSyncExport.ps1 -ExportPath <this folder or zip>`` produces findings + recommendations.")
$summaryPath = Join-Path $script:Out 'summary.md'
[System.IO.File]::WriteAllText($summaryPath, ($summary -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
[void]$script:Files.Add('summary.md')

$manifest = [ordered]@{
  tool = 'Export-AzFileSyncEnvironment.ps1'; toolVersion = $ToolVersion; schema = 'luca.afs-export/1'
  exportedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); exportedBy = $ctx.Account.Id; tenantId = $ctx.Tenant.Id; cloud = $ctx.Environment.Name
  subscriptions = @($subs | ForEach-Object { [ordered]@{ id = $_.subscriptionId; name = $_.displayName } })
  apiVersions = $Api; jobLookbackDays = $JobLookbackDays; metricsLookbackDays = $MetricsLookbackDays; metricsSkipped = [bool]$SkipMetrics
  counts = $script:Counts; errorCount = $script:Errors.Count
  files = @($script:Files | Sort-Object | ForEach-Object { $f = Join-Path $script:Out $_; [ordered]@{ path = $_; bytes = (Get-Item $f).Length; sha256 = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower() } })
}
$manifestJson = $manifest | ConvertTo-Json -Depth 16
[System.IO.File]::WriteAllText((Join-Path $script:Out 'manifest.json'), $manifestJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Step ("Done. {0} files, {1} failed call(s). Counts: {2}" -f ($script:Files.Count + 1), $script:Errors.Count, (($script:Counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
if (-not $NoZip) {
  $zip = "$script:Out.zip"
  if (Test-Path $zip) { Remove-Item $zip -Force }
  Compress-Archive -Path (Join-Path $script:Out '*') -DestinationPath $zip -CompressionLevel Optimal
  Write-Step "Zipped -> $zip  (send this file for assessment)"
}
Write-Host ""
Get-Content $summaryPath -Encoding UTF8 | Select-Object -First 12
Write-Host "... (full summary in summary.md)"
