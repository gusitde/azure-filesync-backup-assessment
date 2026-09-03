<#
.SYNOPSIS
  Generate the as-built document from what actually exists in Azure after a deployment.

.DESCRIPTION
  Reads the deployment context, queries Azure for every object the build produced, and
  writes the as-built as markdown and as a self-contained tabbed HTML page - the same
  structure as docs/AS-BUILT-TEMPLATE.md, but filled in from the live estate rather than by
  hand. Every value comes from a read call against Azure at generation time.

  Output: <repo>/as-built/AS-BUILT-<prefix>-<stamp>.md and .html

  Sections (one tab each):
    Summary        who built what, where, when, as which identity
    Resources      every resource in the group
    Storage        the account's security baseline and the shares
    Network        vnet and subnets, private endpoints with their addresses, private DNS
                   zones and records, the resolver inbound address to forward to
    File Sync      the Storage Sync Service and its traffic policy
    Backup         vault redundancy, cross-region restore, soft delete, policies, items
    Identity       the deployment identity and its role assignment
    Verify         the read-back command for every object, to prove the document
    Still manual   the three steps no script does: agent, forwarders, AD DS join

.PARAMETER Context
  The deployment-context.json written by phase 1.

.PARAMETER OutputDirectory
  Where to write. Default: <repo>/as-built

.EXAMPLE
  .\Export-AfsAsBuilt.ps1 -Context .\deployment-context.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Context,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AfsConfig.ps1')
. (Join-Path $PSScriptRoot 'AfsLog.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Render-AfsAssessmentHtml.ps1')
# Strict mode is deliberately OFF here, and it must be set AFTER the dot-sources above (each of
# them switches strict mode on for the caller's scope). This script reads whatever Azure
# returns, and nested properties such as azureFilesIdentityBasedAuthentication are legitimately
# null on a freshly built estate. Under strict mode a null parent throws; here it renders as '-'.
Set-StrictMode -Off
if (-not $env:AFS_LOG_FILE) { Start-AfsLog -Level Verbose -Name 'asbuilt' | Out-Null }

function ConvertTo-Array {
    # @(Q ...) does not flatten a returned Object[]; normalise here (same helper as Deploy).
    param($Value)
    if ($null -eq $Value) { return @() }
    # the unary comma matters: 'return $array' goes through the pipeline, which unwraps a
    # ONE-element array back to its scalar, and a PSCustomObject has no .Count - the as-built
    # reported the deployment identity's single role as 'not readable' because of exactly that
    if ($Value -is [System.Array]) { return ,$Value }
    return ,@($Value)
}
function Q { param([string[]]$A) return (Invoke-AfsAz -Args $A -AllowFailure) }
function T { param($v) if ($null -eq $v -or $v -eq '') { return '-' } return [string]$v }

$ctx = Read-AfsJsonc -Path $Context
$cfg = $ctx.config
$sub = $cfg.subscriptionId
$env:AFS_SUBSCRIPTION_ID = $sub   # every az call is pinned to it (see Invoke-AfsAz)
$rg  = $cfg.resourceGroup
if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'as-built' }
if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

Invoke-AfsAz -Args @('account', 'set', '--subscription', $sub) -AllowFailure | Out-Null
$who = Q @('account', 'show', '--query', 'user.name', '-o', 'tsv')
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmm')
$base = Join-Path $OutputDirectory ("AS-BUILT-{0}-{1}" -f $cfg.namePrefix, $stamp)

Write-Host ''
Write-Host ("As-built for {0} in {1}" -f $rg, $sub) -ForegroundColor Cyan
$md = New-Object System.Collections.ArrayList
function L { param([string]$s) [void]$md.Add($s) }
$verify = New-Object System.Collections.ArrayList
function V { param([string]$what, [string]$cmd) [void]$verify.Add([pscustomobject]@{ what = $what; cmd = $cmd }) }

# ---------------------------------------------------------------- summary ---
L "# As-built - $($cfg.namePrefix) - $rg"
L ''
L "Generated $((Get-Date).ToUniversalTime().ToString('u')) from the live estate by $who. Every value below was read from Azure at generation time; nothing is transcribed by hand."
L ''
L '## Summary'
L ''
L '| Field | Value |'
L '|---|---|'
L "| Subscription | ``$sub`` |"
L "| Resource group | ``$rg`` |"
L "| Region | $($cfg.location) |"
L "| Name prefix | $($cfg.namePrefix) |"
L "| Built via | phase 1 by $($ctx.createdBy) at $($ctx.createdUtc); phase 2 as $who |"
L "| Deployment identity | $($ctx.identity.displayName) (``$($ctx.identity.appId)``), $($ctx.identity.role) on the resource group |"
L ''
V 'resource group' "az group show -n $rg --query name -o tsv"

# -------------------------------------------------------------- resources ---
L '## Resources'
L ''
$res = ConvertTo-Array (Q @('resource', 'list', '-g', $rg, '--query', '[].{name:name,type:type,location:location}', '-o', 'json'))
L "| Name | Type | Region |"
L '|---|---|---|'
foreach ($r in ($res | Sort-Object type, name)) { L ("| ``{0}`` | {1} | {2} |" -f $r.name, $r.type, $r.location) }
L ''
L ("{0} resources in the group." -f $res.Count)
L ''
V 'resource inventory' "az resource list -g $rg -o table"

# ---------------------------------------------------------------- storage ---
L '## Storage'
L ''
$sa = Q @('storage', 'account', 'show', '-n', $cfg.storageAccountName, '-g', $rg, '-o', 'json')
if ($sa) {
    L '| Setting | Value |'
    L '|---|---|'
    L "| Account | ``$($sa.name)`` |"
    L "| Redundancy (one-way) | $($sa.sku.name) |"
    L "| Kind / access tier | $($sa.kind) / $(T $sa.accessTier) |"
    L "| Minimum TLS | $($sa.minimumTlsVersion) |"
    L "| HTTPS only | $($sa.enableHttpsTrafficOnly) |"
    L "| Public blob access | $(T $sa.allowBlobPublicAccess) |"
    L "| Public network access | $(T $sa.publicNetworkAccess) |"
    L "| Firewall default / bypass | $(T $sa.networkRuleSet.defaultAction) / $(T $sa.networkRuleSet.bypass) |"
    L "| Shared key access | $(T $sa.allowSharedKeyAccess) (Azure Backup for Azure Files requires it) |"
    L "| Large file shares | $(T $sa.largeFileSharesState) |"
    L "| Identity-based auth | $(T $sa.azureFilesIdentityBasedAuthentication.directoryServiceOptions) |"
    L ''
    $fs = Q @('storage', 'account', 'file-service-properties', 'show', '--account-name', $cfg.storageAccountName, '-g', $rg, '-o', 'json')
    if ($fs) { L ("Share soft delete: {0}, {1} days." -f $fs.shareDeleteRetentionPolicy.enabled, $fs.shareDeleteRetentionPolicy.days); L '' }
    $shares = ConvertTo-Array (Q @('storage', 'share-rm', 'list', '--storage-account', $cfg.storageAccountName, '-g', $rg, '-o', 'json'))
    L '| Share | Quota (GiB) | Access tier | Protocols |'
    L '|---|---|---|---|'
    foreach ($s in $shares) { L ("| ``{0}`` | {1} | {2} | {3} |" -f $s.name, (T $s.shareQuota), (T $s.accessTier), (T $s.enabledProtocols)) }
    L ''
    V 'storage baseline' "az storage account show -n $($cfg.storageAccountName) -g $rg --query '[sku.name,minimumTlsVersion,enableHttpsTrafficOnly,allowBlobPublicAccess,publicNetworkAccess,networkRuleSet.defaultAction]' -o tsv"
    V 'share soft delete' "az storage account file-service-properties show --account-name $($cfg.storageAccountName) -g $rg --query shareDeleteRetentionPolicy -o json"
    V 'shares' "az storage share-rm list --storage-account $($cfg.storageAccountName) -g $rg --query '[].name' -o tsv"
} else { L "_Storage account $($cfg.storageAccountName) not found._"; L '' }

# ---------------------------------------------------------------- network ---
L '## Network'
L ''
$vnetRg = if ($cfg.PSObject.Properties['vnetResourceGroup'] -and $cfg.vnetResourceGroup) { $cfg.vnetResourceGroup } else { $rg }
$vn = Q @('network', 'vnet', 'show', '-n', $cfg.vnetName, '-g', $vnetRg, '-o', 'json')
if ($vn) {
    L ("Virtual network ``{0}`` - address space {1}" -f $vn.name, (($vn.addressSpace.addressPrefixes) -join ', '))
    L ''
    L '| Subnet | Prefix | Delegation |'
    L '|---|---|---|'
    foreach ($sn in @($vn.subnets)) {
        $del = '-'
        if ($sn.PSObject.Properties['delegations'] -and $sn.delegations) { $del = (@($sn.delegations | ForEach-Object { $_.serviceName }) -join ', ') }
        L ("| ``{0}`` | {1} | {2} |" -f $sn.name, (T $sn.addressPrefix), $del)
    }
    L ''
    V 'vnet' "az network vnet show -n $($cfg.vnetName) -g $vnetRg --query provisioningState -o tsv"
} else { L "_Virtual network $($cfg.vnetName) not found._"; L '' }

$pes = ConvertTo-Array (Q @('network', 'private-endpoint', 'list', '-g', $rg, '-o', 'json'))
L '### Private endpoints'
L ''
L '| Endpoint | Sub-resource | Private IP(s) | FQDNs | State |'
L '|---|---|---|---|---|'
foreach ($pe in $pes) {
    $grp = '-'; $state = '-'
    if ($pe.privateLinkServiceConnections -and $pe.privateLinkServiceConnections.Count) {
        $c = $pe.privateLinkServiceConnections[0]
        $grp = (@($c.groupIds) -join ',')
        $state = $c.privateLinkServiceConnectionState.status
    }
    $ips = @(); $fq = @()
    foreach ($d in @($pe.customDnsConfigs)) { $ips += @($d.ipAddresses); $fq += $d.fqdn }
    L ("| ``{0}`` | {1} | {2} | {3} | {4} |" -f $pe.name, $grp, (($ips | Sort-Object -Unique) -join ', '), ($fq -join '<br>'), $state)
}
if ($pes.Count -eq 0) { L '| _none_ | | | | |' }
L ''
L 'The Storage Sync Service to storage account leg and Azure Backup traffic for Azure Files stay inside Microsoft; the SMB and File Sync paths above are what can be private.'
L ''
V 'private endpoints' "az network private-endpoint list -g $rg --query '[].{name:name,ip:customDnsConfigs[0].ipAddresses[0],state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}' -o table"

$zones = ConvertTo-Array (Q @('network', 'private-dns', 'zone', 'list', '-g', $rg, '-o', 'json'))
L '### Private DNS zones'
L ''
L '| Zone | Records | VNet links |'
L '|---|---|---|'
foreach ($z in $zones) { L ("| ``{0}`` | {1} | {2} |" -f $z.name, (T $z.numberOfRecordSets), (T $z.numberOfVirtualNetworkLinks)) }
if ($zones.Count -eq 0) { L '| _none_ | | |' }
L ''
foreach ($z in $zones) {
    $recs = ConvertTo-Array (Q @('network', 'private-dns', 'record-set', 'a', 'list', '-g', $rg, '-z', $z.name, '-o', 'json'))
    foreach ($rec in $recs) {
        $ip = ''
        if ($rec.aRecords) { $ip = (@($rec.aRecords | ForEach-Object { $_.ipv4Address }) -join ', ') }
        L ("- ``{0}.{1}`` -> {2}" -f $rec.name, $z.name, $ip)
    }
}
L ''
V 'private dns zones' "az network private-dns zone list -g $rg --query '[].{zone:name,records:numberOfRecordSets,links:numberOfVirtualNetworkLinks}' -o table"

L '### DNS Private Resolver'
L ''
$inbound = $null
if ($cfg.deployDnsResolver) {
    $inbound = Q @('dns-resolver', 'inbound-endpoint', 'show', '-g', $rg, '--dns-resolver-name', $cfg.dnsResolverName, '-n', 'inbound-01', '-o', 'json')
}
if ($inbound) {
    $ip = $inbound.ipConfigurations[0].privateIpAddress
    L ("Resolver ``{0}``, inbound endpoint ``inbound-01`` at **{1}**." -f $cfg.dnsResolverName, $ip)
    L ''
    L 'Point on-premises conditional forwarders at that address for these zones only - never the parent core.windows.net:'
    L ''
    L "- ``$($cfg.zoneFile)``"
    L "- ``$($cfg.zoneAfs)``"
    L ''
    V 'resolver inbound IP' "az dns-resolver inbound-endpoint show -g $rg --dns-resolver-name $($cfg.dnsResolverName) -n inbound-01 --query 'ipConfigurations[0].privateIpAddress' -o tsv"
} else { L '_No DNS Private Resolver in this deployment._'; L '' }

# -------------------------------------------------------------- file sync ---
L '## File Sync'
L ''
$sss = Q @('resource', 'show', '-g', $rg, '-n', $cfg.storageSyncServiceName, '--resource-type', 'Microsoft.StorageSync/storageSyncServices', '-o', 'json')
if ($sss) {
    L '| Setting | Value |'
    L '|---|---|'
    L "| Storage Sync Service | ``$($sss.name)`` |"
    L "| Incoming traffic policy | $(T $sss.properties.incomingTrafficPolicy) |"
    L "| Provisioning state | $(T $sss.properties.provisioningState) |"
    L ''
    L 'Registered servers and server endpoints are created on the file server itself (see Still manual).'
    L ''
    V 'storage sync service' "az resource show -g $rg -n $($cfg.storageSyncServiceName) --resource-type Microsoft.StorageSync/storageSyncServices --query properties.incomingTrafficPolicy -o tsv"
} else { L "_Storage Sync Service $($cfg.storageSyncServiceName) not found._"; L '' }

# ----------------------------------------------------------------- backup ---
L '## Backup'
L ''
$vault = $null
if ($cfg.deployBackup) { $vault = Q @('backup', 'vault', 'show', '-n', $cfg.vaultName, '-g', $rg, '-o', 'json') }
if ($vault) {
    # backup-properties returns an ARRAY - the [0] index is required; a bare query returns nothing
    $bp = Q @('backup', 'vault', 'backup-properties', 'show', '-n', $cfg.vaultName, '-g', $rg, '-o', 'json')
    $props = $null; if ($bp) { $props = (ConvertTo-Array $bp)[0].properties }
    L '| Setting | Value |'
    L '|---|---|'
    L "| Vault | ``$($vault.name)`` |"
    L "| Storage redundancy (one-way) | $(if ($props) { T $props.storageModelType } else { '-' }) |"
    L "| Cross-region restore | $(if ($props) { T $props.crossRegionRestoreFlag } else { '-' }) |"
    L "| Soft delete | $(T $vault.properties.securitySettings.softDeleteSettings.softDeleteState) |"
    L "| Immutability | $(T $vault.properties.securitySettings.immutabilitySettings.state) |"
    L ''
    $pols = ConvertTo-Array (Q @('backup', 'policy', 'list', '-v', $cfg.vaultName, '-g', $rg, '--query', '[].{name:name,type:properties.backupManagementType}', '-o', 'json'))
    L '| Policy | Management type |'
    L '|---|---|'
    foreach ($p in $pols) { L ("| ``{0}`` | {1} |" -f $p.name, $p.type) }
    L ''
    $items = ConvertTo-Array (Q @('backup', 'item', 'list', '-v', $cfg.vaultName, '-g', $rg, '--query', '[].{name:properties.friendlyName,state:properties.protectionState,type:properties.workloadType}', '-o', 'json'))
    L ("Protected items: {0}" -f $items.Count)
    foreach ($i in $items) { L ("- ``{0}`` ({1}) - {2}" -f $i.name, $i.type, $i.state) }
    L ''
    V 'vault redundancy + CRR' "az backup vault backup-properties show -n $($cfg.vaultName) -g $rg --query '[0].properties.[storageModelType,crossRegionRestoreFlag]' -o tsv"
    V 'protected items' "az backup item list -v $($cfg.vaultName) -g $rg --query 'length(@)' -o tsv"
} else { L '_No Recovery Services vault in this deployment._'; L '' }

# --------------------------------------------------------------- identity ---
L '## Identity'
L ''
$ra = ConvertTo-Array (Q @('role', 'assignment', 'list', '--assignee', $ctx.identity.appId, '--scope', "/subscriptions/$sub/resourceGroups/$rg", '--query', '[].{role:roleDefinitionName,scope:scope}', '-o', 'json'))
L '| Field | Value |'
L '|---|---|'
L "| Deployment identity | $($ctx.identity.displayName) |"
L "| Application (client) id | ``$($ctx.identity.appId)`` |"
L "| Auth mode | $($ctx.identity.authMode) |"
L "| Role at the resource group | $(if ($ra.Count) { (@($ra | ForEach-Object { $_.role }) -join ', ') } else { 'not readable from this session' }) |"
L "| AD DS join | $(if ($cfg.enableAdDsJoin) { 'configured for ' + $cfg.adDomainFqdn + ' (' + $cfg.adIdentityObjectType + ' in ' + $cfg.adOuDn + ')' } else { 'not configured in this deployment' }) |"
L ''
V 'identity role' "az role assignment list --assignee $($ctx.identity.appId) --scope /subscriptions/$sub/resourceGroups/$rg -o table"

# ----------------------------------------------------------------- verify ---
L '## Verify'
L ''
L 'Each command reads one object back. A row in this document is proven by its command, not by the document.'
L ''
L '| What | Command |'
L '|---|---|'
foreach ($v in $verify) { L ("| {0} | ``{1}`` |" -f $v.what, $v.cmd) }
L ''

# ----------------------------------------------------------- still manual ---
L '## Still manual'
L ''
L 'Three steps need a person on a specific machine, and this document is not complete until they are recorded here:'
L ''
L '| Step | Where | Status | Done by | Date |'
L '|---|---|---|---|---|'
L '| Install the Azure File Sync agent, register the server, create the server endpoint | the file server | pending | | |'
L "| On-premises conditional forwarders for the two privatelink zones -> $(if ($inbound) { $inbound.ipConfigurations[0].privateIpAddress } else { 'resolver inbound IP' }) | the DNS platform | pending | | |"
L '| AD DS domain join of the storage account (AzFilesHybrid) | a domain-joined machine | pending | | |'
L ''

# ------------------------------------------------------------------ write ---
$mdText = ($md -join "`n") + "`n"
[System.IO.File]::WriteAllText("$base.md", $mdText, (New-Object System.Text.UTF8Encoding($false)))

# tabbed html: one tab per ## section, same visual language as the assessment report
$sections = @()
$cur = $null
foreach ($line in $md) {
    if ($line -match '^## (.+)$') { if ($cur) { $sections += $cur }; $cur = @{ t = $Matches[1]; b = New-Object System.Collections.ArrayList }; continue }
    if ($cur) { [void]$cur.b.Add($line) }
}
if ($cur) { $sections += $cur }
$enc = [System.Net.WebUtility]
$h = New-Object System.Text.StringBuilder
[void]$h.Append('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>As-built - ' + $enc::HtmlEncode($rg) + '</title><style>')
[void]$h.Append(':root{--ink:#1b2430;--muted:#5b6673;--surface:#fff;--surface-2:#f4f6f8;--surface-3:#e9edf1;--line:#d8dde3;--accent:#0b5cab;--accent-strong:#083f78;--radius:8px}*{box-sizing:border-box}body{margin:0;background:var(--surface-2);color:var(--ink);font:14px/1.5 "Segoe UI",system-ui,Arial,sans-serif}header{background:var(--accent-strong);color:#fff;padding:20px 32px 0}header h1{margin:0 0 4px;font-size:22px;font-weight:600}header .meta{color:#cfe0f3;font-size:13px;margin-bottom:14px}nav.tabs{display:flex;gap:2px;flex-wrap:wrap}nav.tabs button{background:rgba(255,255,255,.08);color:#dbe7f3;border:0;border-radius:6px 6px 0 0;padding:9px 16px;cursor:pointer;font-size:13px}nav.tabs button.active{background:var(--surface-2);color:var(--ink);font-weight:600}main{max-width:1280px;margin:0 auto;padding:22px 32px}section.tab{display:none}section.tab.active{display:block}h2{font-size:16px;margin:0 0 10px}h3{font-size:14px;margin:18px 0 8px}h4{font-size:13px;margin:14px 0 6px;color:var(--muted)}table{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);overflow:hidden;margin:6px 0 14px}th,td{padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top;text-align:left}th{background:var(--surface-3);font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}tr:last-child td{border-bottom:0}code{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px;background:var(--surface-3);padding:1px 4px;border-radius:3px}p{margin:6px 0}footer{color:#8a95a1;font-size:12px;padding:24px 32px;text-align:center}@media print{nav.tabs{display:none}section.tab{display:block!important;page-break-before:always}}')
[void]$h.Append('</style></head><body><header><h1>As-built - ' + $enc::HtmlEncode($rg) + '</h1><div class="meta">Generated ' + $enc::HtmlEncode((Get-Date).ToUniversalTime().ToString('u')) + ' from the live estate by ' + $enc::HtmlEncode($who) + '</div><nav class="tabs">')
$i = 0
foreach ($s in $sections) { $cls = if ($i -eq 0) { ' class="active"' } else { '' }; [void]$h.Append('<button' + $cls + ' data-tab="t' + $i + '">' + $enc::HtmlEncode($s.t) + '</button>'); $i++ }
[void]$h.Append('</nav></header><main>')
$i = 0
foreach ($s in $sections) {
    $cls = if ($i -eq 0) { 'tab active' } else { 'tab' }
    [void]$h.Append('<section class="' + $cls + '" id="tab-t' + $i + '"><h2>' + $enc::HtmlEncode($s.t) + '</h2>')
    [void]$h.Append((ConvertTo-AfsHtmlFromMarkdown -Markdown (($s.b -join "`n"))))
    [void]$h.Append('</section>'); $i++
}
[void]$h.Append('</main><footer>Every value was read from Azure at generation time. Prove any row with its command on the Verify tab.</footer>')
[void]$h.Append('<script>(function(){function show(id){document.querySelectorAll("nav.tabs button").forEach(function(b){b.classList.toggle("active",b.dataset.tab===id);});document.querySelectorAll("section.tab").forEach(function(s){s.classList.toggle("active",s.id==="tab-"+id);});}document.querySelectorAll("nav.tabs button").forEach(function(b){b.addEventListener("click",function(){show(b.dataset.tab);});});})();</script></body></html>')
[System.IO.File]::WriteAllText("$base.html", $h.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-AfsLog -Level INFO -Message ("as-built written: " + $base + ".md / .html")
Write-Host ("  as-built: {0}.md" -f $base) -ForegroundColor Green
Write-Host ("  as-built: {0}.html" -f $base) -ForegroundColor Green
[pscustomobject]@{ Markdown = "$base.md"; Html = "$base.html"; Resources = $res.Count }