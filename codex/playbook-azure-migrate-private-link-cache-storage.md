---
slug: playbook-azure-migrate-private-link-cache-storage
doc_type: playbook
kind: azure-migrate-private-link-cache-storage
category: ops
title: Prepare the Azure Migrate cache storage account and DNS for replication over Private Link
summary: Create the hardened GPv2 cache storage account with a blob private endpoint, grant the vault identity, keep trusted services, download the project DNS settings, add the Infoblox forwarders, and verify every private link name.
when_to_use: A private-endpoint Azure Migrate project is about to replicate VMs, or the appliance cannot resolve the migrate, vault, key vault or storage names.
applies_to: [ops, devstation]
tags: [azure-migrate, private-link, storage-account, dns, infoblox, replication, contoso]
persona_run: eng-netops
ticket_kind: ops
status: published
version: 1
execution: assisted
last_verified: 2026-09-03T05:00 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

The Migrate project was created with **Connectivity method = Private endpoint** and the
appliance key was generated (Azure created the project, Key Vault, usage-storage and vault
endpoints and their zones). Before **Replicate** can select a cache storage account over the
private path, Contoso must provide that account with a `blob` private
endpoint, the vault identity must have rights on it, and the appliance must resolve every
private link FQDN privately. This is Contoso-owned half of
[[blueprint-azure-migrate-private-link-landing]].

## Reuse before reinvent (GR11)

```yaml
- primitive: playbook-deploy-secure-storage-account-and-share (module + baseline)
  path: codex/playbook-deploy-secure-storage-account-and-share.md
  why: the cache account is the same AVM module with a privateEndpoint for blob
       instead of file and no shares; the security baseline is identical
- primitive: Download DNS settings (Migrate project properties)
  path: codex/blueprint-azure-migrate-private-link-landing.md
  why: the exported FQDN/IP list is the only authoritative source of the names the appliance
       must resolve; guessing zone contents is how the hosts-file workaround becomes permanent
- primitive: hub DNS (Private Resolver + Infoblox)
  path: codex/blueprint-azure-dns-for-private-endpoints.md
  why: the four Migrate zones forward through the same inbound endpoint as the Files and File
       Sync zones
```

## Procedure

1. **Preconditions.** Contributor on the migration resource group, Owner or User Access
   Administrator on the cache account (role assignment), the vault name and managed identity id
   from Migration and modernization > Properties, the private-endpoint spoke selected at project
   creation (or one connected to it), the central `privatelink.blob.core.windows.net` zone.
2. **Create the cache account** with the storage module: `StorageV2`, `Standard_LRS` (cache
   data is transient; a Premium replication account needs a separate Standard cache), TLS 1.2,
   HTTPS only, `defaultAction Deny` + `bypass AzureServices` (Migrate documents "Allow trusted
   Microsoft services"), private endpoint `blob` with a zone group, key expiration
   policy, diagnostics, lock, tags. No shares, no identity-based auth.
3. **Grant the vault identity**: `Contributor` and `Storage Blob Data Contributor` on the cache
   account (`Storage Blob Data Owner` instead of `Storage Blob Data Contributor` only when the
   account being granted is itself Premium; a Standard cache account always takes `Contributor`
   + `Storage Blob Data Contributor`, and a Premium replication account needs `Contributor` +
   `Storage Blob Data Owner` on that Premium account plus its own private endpoint). Add a
   resource instance rule for the Recovery Services vault (`Microsoft.RecoveryServices/vaults` -
   the managed identity that actually reads and writes the cache account) if resource-scoped
   access is wanted, but keep `bypass AzureServices` permanently: Microsoft requires "Allow
   trusted Microsoft services to access this storage account" for replication, and the cache
   account must stay reachable on its public endpoint (`publicNetworkAccess Enabled` with
   `defaultAction Deny`) because Azure Migrate moves data from the cache account to the replica
   managed disks over it - so the bypass is never removed.
4. **DNS.** Confirm the Infoblox forwarders exist for `privatelink.prod.migration.windowsazure.com`,
   `privatelink.vaultcore.azure.net`, `privatelink.blob.core.windows.net`,
   `privatelink.siterecovery.windowsazure.com`, and that
   the Migrate-created zones are linked to the hub (or merged into the central zones). Download
   DNS settings from both Migrate properties pages.
5. **Verify from the appliance**: every FQDN in the DNS settings file and
   `<cache>.blob.core.windows.net` resolve to the listed private IPs; `Test-NetConnection -Port
   443` succeeds to each; if the appliance uses a proxy, add bypass entries for the private link
   FQDNs.
6. **Select the cache account** in Replicate > Target settings (only accounts in the selected
   target region and the Migrate project subscription are listed; the private endpoint must be
   created and approved for the replication traffic to take the private path), start a test
   replication of one VM, and watch the private endpoint's Data Bytes In metric increase.
7. **Evidence.** Store the DNS settings file, the `nslookup` transcript and the metric
   screenshot in the change record; run the kit assessor - the cache account should show only
   documented exceptions.

## Steps

```yaml
vars:
  - name: rg
    describe: migration resource group
    required: true
  - name: cache
    describe: cache storage account name
    required: true
  - name: pe_subnet_id
    describe: private-endpoint subnet id (project VNet or connected VNet)
    required: true
  - name: blob_zone_id
    describe: resource id of privatelink.blob.core.windows.net
    required: true
  - name: vault_principal
    describe: managed identity object id of the Recovery Services vault created by Migrate
    required: true
steps:
  - name: preconditions
    run: az network private-dns zone show --ids <blob_zone_id> --query name -o tsv
    verify: prints privatelink.blob.core.windows.net
  - name: deploy the cache account
    run: az deployment group create -g <rg> -f cache.bicep -p accountName=<cache> peSubnetResourceId=<pe_subnet_id> blobZoneResourceId=<blob_zone_id>
    verify: provisioningState Succeeded; az storage account show -g <rg> -n <cache> --query "[kind, networkRuleSet.defaultAction, networkRuleSet.bypass, length(privateEndpointConnections)]" -o tsv prints StorageV2 Deny AzureServices 1
  - name: grant the vault identity
    run: az role assignment create --assignee-object-id <vault_principal> --assignee-principal-type ServicePrincipal --role Contributor --scope $(az storage account show -g <rg> -n <cache> --query id -o tsv) && az role assignment create --assignee-object-id <vault_principal> --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope $(az storage account show -g <rg> -n <cache> --query id -o tsv)
    verify: az role assignment list --scope <cache-id> --assignee <vault_principal> --query "[].roleDefinitionName" -o tsv lists both roles
  - name: dns settings from the project
    run: (portal) Azure Migrate > Discovery and assessment > Properties > Download DNS settings; Migration and modernization > Properties > Download DNS settings
    verify: two files listing FQDN and private IP pairs for the project, key vault, usage storage and vault endpoints
  - name: confirm the effect from the appliance
    run: powershell -Command "Get-Content .\dns-settings.txt | % { $f=($_ -split '\s+')[0]; if ($f -match '\.') { '{0} -> {1}' -f $f, ((Resolve-DnsName $f -Type A -ErrorAction SilentlyContinue).IP4Address -join ',') } }; (Resolve-DnsName <cache>.blob.core.windows.net -Type A).IP4Address; (Test-NetConnection <cache>.blob.core.windows.net -Port 443).TcpTestSucceeded"
    verify: every name resolves to the private IP listed in the file, the cache account resolves to 10.x, and the TCP test prints True
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-netops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: azure-migrate-private-link-cache-storage`
- **CR file:** `change-management/CR-<date>-azure-migrate-private-link-cache-storage.md`
- **Closure:** a test replication completes with bytes counted on the cache account's blob private endpoint

## Gate rules

```json
[
  {"rule": "the cache account is GPv2 with a blob private endpoint", "severity": "error", "check": "az storage account show -g <rg> -n <cache> --query \"[kind, privateEndpointConnections[].privateEndpoint.id]\" -o tsv prints StorageV2 and one endpoint id"},
  {"rule": "trusted services remain allowed", "severity": "error", "check": "az storage account show -g <rg> -n <cache> --query networkRuleSet.bypass -o tsv contains AzureServices"},
  {"rule": "the appliance resolves the cache account privately", "severity": "error", "check": "nslookup <cache>.blob.core.windows.net on the appliance prints a 10.x address"},
  {"rule": "no hosts-file entries remain after go-live", "severity": "warn", "check": "powershell -Command \"Select-String -Path C:\\Windows\\System32\\drivers\\etc\\hosts -Pattern privatelink\" on the appliance prints nothing"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-migrate-private-link-landing.md
  anchor: "Zone and endpoint map"
  why: which endpoint and zone each Migrate resource uses
- path: codex/runbook-private-endpoint-name-resolution-and-reachability.md
  anchor: "Download DNS settings"
  why: the incident path when a name still resolves publicly
- path: codex/playbook-deploy-secure-storage-account-and-share.md
  anchor: "privateEndpoints"
  why: the module block to adapt with service blob
```

Microsoft Learn (read 2026-09-03): Migrate servers to Azure by using Private Link (cache
storage account, vault permissions, private endpoint on blob, GPv2 requirement); Troubleshoot
network connectivity issues - Azure Migrate (Download DNS settings, verification, proxy bypass);
Discover and assess using Azure Private Link; Trusted Azure services
(Microsoft.RecoveryServices/vaults, Microsoft.Migrate/migrateprojects).
