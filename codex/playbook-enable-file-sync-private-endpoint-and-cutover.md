---
slug: playbook-enable-file-sync-private-endpoint-and-cutover
doc_type: playbook
kind: enable-file-sync-private-endpoint-and-cutover
category: ops
title: Move Azure File Sync onto the ExpressRoute path and disable its public endpoint
summary: Create the Storage Sync Service private endpoint (four afs names), integrate DNS through Infoblox, optionally switch to managed identities, verify every registered server, then set incomingTrafficPolicy to AllowVirtualNetworksOnly, with rollback.
when_to_use: The customer requires File Sync traffic on ExpressRoute or VPN, or the assessor reports NET-05 or NET-07 for a Storage Sync Service.
applies_to: [ops, devstation]
tags: [azure-file-sync, private-endpoint, storage-sync-service, expressroute, dns, managed-identity, cutover, contoso]
persona_run: eng-sysops
ticket_kind: ops
status: published
version: 2
execution: assisted
last_verified: 2026-09-03T05:00 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

The storage account private endpoint already resolves from every server
([[playbook-add-file-private-endpoint-and-dns]]) and the hub DNS is live. You decided to make
the remaining File Sync leg private per [[blueprint-azure-file-sync-private-path]]. Do this in a
maintenance window: the final step disables the public endpoint, and a server that still
resolves `*.afs.azure.net` publicly stops syncing at that moment.

## Reuse before reinvent (GR11)

```yaml
- primitive: Storage Sync Service private endpoint procedure (Az PowerShell, GroupId Afs)
  path: codex/blueprint-azure-file-sync-private-path.md
  why: Microsoft's PowerShell block creates the endpoint, the zone and the four A records; the
       Azure CLI cannot set incomingTrafficPolicy, so PowerShell is the tool for the whole run
- primitive: Set-AzStorageSyncServiceIdentity
  path: codex/blueprint-azure-file-sync-private-path.md
  why: one cmdlet enables the service identity, grants the roles on every storage account and
       switches every registered server; hand-assigning the roles misses the per-server grant
- primitive: Get-AfsServerDiagnostics.ps1
  path: Get-AfsServerDiagnostics.ps1
  why: captures Debug-StorageSyncServer -TestNetworkConnectivity and the Telemetry 9102/9301
       events that prove the private path works, in the same bundle the assessor reads
```

## Procedure

1. **Preconditions.** Agent 20.0.0.0+ on every registered server (AFS-06 clear), Az.StorageSync
   2.5.0+, Owner or Azure File Sync Administrator on the storage accounts (for MI), Network
   Contributor on the spoke, Private DNS Zone Contributor for `privatelink.afs.azure.net`,
   Infoblox change window, the servers Arc-enabled if managed identity is in scope.
2. **Create the Storage Sync Service private endpoint** (group id `Afs`) in the
   private-endpoint spoke with a DNS zone group for `privatelink.afs.azure.net`; the endpoint
   NIC receives four IPs; approve the connection if pending. Register the four IPs in IPAM.
3. **Infoblox.** Add the conditional forwarder for the public zone `afs.azure.net` -> Private
   Resolver inbound endpoint (if not already created by the DNS playbook) - not
   `privatelink.afs.azure.net`, which is never consulted because the whole CNAME chain comes
   back in one answer.
4. **Verify DNS on every server**: the four FQDNs from the endpoint's NIC resolve to 10.x
   addresses; `Debug-StorageSyncServer -TestNetworkConnectivity` succeeds.
5. **Managed identity (optional, recommended).** `Set-AzStorageSyncServiceIdentity` on the
   service; wait 15 minutes; `Get-AzStorageSyncServer` shows `ActiveAuthType ManagedIdentity`
   for Arc-enabled servers; servers without an identity keep using shared key.
6. **Storage account firewall** already Deny + AzureServices (+ resource instance rule) from
   [[playbook-harden-existing-storage-account]]; confirm a cloud change enumeration and a sync
   session completed after that change.
7. **Cut over**: `Set-AzStorageSyncService -IncomingTrafficPolicy AllowVirtualNetworksOnly`.
8. **Verify** within the hour on every server: Telemetry 9301 heartbeats continue, next 9102
   has HResult 0, portal shows every server Online and every endpoint Healthy; recall a tiered
   file (`Invoke-StorageSyncFileRecall`) to prove the data leg.
9. **Rollback** if any server fails and cannot be fixed inside the window:
   `Set-AzStorageSyncService -IncomingTrafficPolicy AllowAllTraffic`; keep the endpoint and DNS.
10. **Evidence.** Re-export + re-assess with `-PrivateTrafficRequired`: NET-05/NET-07 gone,
    AFS-11 absent; attach the after-assessment and a server bundle to the change record.

## Steps

```yaml
vars:
  - name: sss_rg
    describe: resource group of the Storage Sync Service
    required: true
  - name: sss
    describe: Storage Sync Service name
    required: true
  - name: vnet_rg
    describe: resource group of the spoke VNet
    required: true
  - name: vnet
    describe: spoke VNet name
    required: true
  - name: subnet
    describe: private-endpoint subnet name
    required: true
  - name: zone_rg
    describe: resource group of privatelink.afs.azure.net
    required: true
steps:
  - name: preconditions
    run: powershell -Command "Get-AzStorageSyncServer -ResourceGroupName <sss_rg> -StorageSyncServiceName <sss> | Select FriendlyName,AgentVersion,LastHeartBeat,ActiveAuthType | Format-Table"
    verify: every AgentVersion starts with 20 or higher and every LastHeartBeat is within the last hour
  - name: create the endpoint
    run: powershell -Command "$s=Get-AzStorageSyncService -ResourceGroupName <sss_rg> -Name <sss>; $v=Get-AzVirtualNetwork -ResourceGroupName <vnet_rg> -Name <vnet>; $sn=$v.Subnets | ? Name -eq '<subnet>'; $c=New-AzPrivateLinkServiceConnection -Name '<sss>-Connection' -PrivateLinkServiceId $s.ResourceId -GroupId 'Afs'; New-AzPrivateEndpoint -ResourceGroupName <sss_rg> -Name 'pe-<sss>-afs' -Location $v.Location -Subnet $sn -PrivateLinkServiceConnection $c"
    verify: ProvisioningState Succeeded and the endpoint NIC lists four IP configurations
  - name: dns zone group
    run: az network private-endpoint dns-zone-group create -g <sss_rg> --endpoint-name pe-<sss>-afs -n default --zone-name afs --private-dns-zone $(az network private-dns zone show -g <zone_rg> -n privatelink.afs.azure.net --query id -o tsv)
    verify: az network private-dns record-set a list -g <zone_rg> -z privatelink.afs.azure.net --query "length(@)" prints 4 more than before
  - name: verify from every server
    run: powershell -Command "Import-Module 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll'; Debug-StorageSyncServer -TestNetworkConnectivity; Get-AzPrivateEndpoint -Name pe-<sss>-afs -ResourceGroupName <sss_rg> | Select -Expand NetworkInterfaces | % { Get-AzNetworkInterface -ResourceId $_.Id } | Select -Expand IpConfigurations | Select -Expand PrivateLinkConnectionProperties | Select -Expand Fqdns | % { Resolve-DnsName $_ | Select Name,IP4Address }"
    verify: connectivity test succeeds and all four names resolve to 10.x on EVERY registered server
  - name: managed identity (optional)
    run: powershell -Command "Set-AzStorageSyncServiceIdentity -ResourceGroupName <sss_rg> -StorageSyncServiceName <sss> -Verbose"
    verify: after 15 minutes Get-AzStorageSyncService shows UseIdentity True and Arc-enabled servers show ActiveAuthType ManagedIdentity
  - name: cut over
    run: powershell -Command "Set-AzStorageSyncService -ResourceGroupName <sss_rg> -Name <sss> -IncomingTrafficPolicy AllowVirtualNetworksOnly"
    verify: Get-AzStorageSyncService shows IncomingTrafficPolicy AllowVirtualNetworksOnly
  - name: confirm the effect
    run: powershell -Command "$f=@{LogName='Microsoft-FileSync-Agent/Telemetry'; StartTime=(Get-Date).AddMinutes(-30)}; Get-WinEvent -FilterHashtable ($f + @{Id=9301}) | Select -First 3 TimeCreated,Id; Get-WinEvent -FilterHashtable ($f + @{Id=9102}) | Select -First 3 TimeCreated,Id,Message | Format-List"
    verify: 9301 events keep arriving and the newest 9102 message contains HResult: 0 on every server
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: enable-file-sync-private-endpoint-and-cutover`
- **CR file:** `change-management/CR-<date>-enable-file-sync-private-endpoint-and-cutover.md`
- **Closure:** incomingTrafficPolicy is AllowVirtualNetworksOnly and every server endpoint stayed Healthy for 24 hours

## Gate rules

```json
[
  {"rule": "no cut-over before every server resolves the four names privately", "severity": "error", "check": "test -s change/verify-servers.txt && test change/verify-servers.txt -ot change/cutover.txt"},
  {"rule": "the public endpoint is disabled at the end", "severity": "error", "check": "az resource show --ids <sss-id> --query properties.incomingTrafficPolicy -o tsv prints AllowVirtualNetworksOnly"},
  {"rule": "sync is healthy after cut-over", "severity": "error", "check": "az resource show --ids <server-endpoint-id> --query properties.syncStatus.combinedHealth -o tsv prints Healthy for every server endpoint"},
  {"rule": "rollback path stays available", "severity": "warn", "check": "az network private-endpoint show -g <sss_rg> -n pe-<sss>-afs --query provisioningState -o tsv prints Succeeded (endpoint retained even if rolled back)"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-file-sync-private-path.md
  anchor: "Rollback"
  why: the documented way back if a server drops off
- path: codex/runbook-file-sync-broken-after-network-lockdown.md
  anchor: "AllowVirtualNetworksOnly"
  why: the incident classes seen after this cut-over
- path: Get-AfsServerDiagnostics.ps1
  anchor: "TestNetworkConnectivity"
  why: the bundle step that captures the connectivity proof
```

Microsoft Learn (read 2026-09-03): Configure Azure File Sync network endpoints (Storage Sync
Service private endpoint, disable public endpoint); How to use managed identities with Azure
File Sync; Azure File Sync on-premises firewall and proxy settings (Test-StorageSyncNetworkConnectivity).
