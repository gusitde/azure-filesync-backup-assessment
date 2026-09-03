---
slug: playbook-deploy-secure-storage-account-and-share
doc_type: playbook
kind: deploy-secure-storage-account-and-share
category: iac
title: Deploy a hardened storage account with file shares and a file private endpoint (Bicep AVM)
summary: Repeatable Bicep deployment of the secure storage account baseline: StorageV2, ZRS or GRS, TLS 1.2, Deny plus trusted services, file private endpoint with DNS zone group, shares with soft delete and hardened SMB, lock, diagnostics.
when_to_use: A new storage account for Contoso file shares (File Sync cloud endpoints or direct SMB) must be created to the baseline rather than by hand in the portal.
applies_to: [ops, devstation]
tags: [azure-files, storage-account, bicep, avm, private-endpoint, iac, contoso]
persona_run: eng-sysops
ticket_kind: ops
status: published
version: 1
execution: assisted
last_verified: 2026-09-03T05:00 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

You decided to create a storage account for Azure file shares that will be cached by Azure
File Sync and protected by Azure Backup, and the target is
[[blueprint-azure-files-secure-storage-account]]. The private DNS zone
`privatelink.file.core.windows.net` and the private-endpoint subnet already exist
([[blueprint-azure-dns-for-private-endpoints]]); identity-based auth and backup are enabled
afterwards by their own playbooks.

## Reuse before reinvent (GR11)

```yaml
- primitive: avm/res/storage/storage-account 0.33.0
  path: codex/playbook-deploy-secure-storage-account-and-share.md
  why: one module carries networkAcls, privateEndpoints with privateDnsZoneGroup, fileServices
       (shares, shareDeleteRetentionPolicy, protocolSettings.smb), lock, diagnosticSettings and
       roleAssignments, so the baseline is a parameter file rather than fifteen portal blades
- primitive: Assess-AzFileSyncExport.ps1
  path: Assess-AzFileSyncExport.ps1
  why: the post-deployment oracle; a fresh account should produce no SEC/DATA finding other than
       SEC-04 (shared key documented) and SEC-14 (platform keys)
```

## Procedure

1. **Preconditions.** Bicep CLI 0.30+ (`az bicep upgrade`), **Contributor plus User Access
   Administrator (or Owner)** on the target resource group - the module creates a
   `CanNotDelete` lock, which requires `Microsoft.Authorization/locks/*` (granted only by Owner
   / User Access Administrator, not by Contributor) - Network Contributor on the
   private-endpoint subnet, Private DNS Zone Contributor on `rg-dns-privatezones`, the zone
   `privatelink.file.core.windows.net` linked to the hub, a naming decision
   (`st<org><class><region>01`, lowercase, 3-24 chars). (Alternative: drop `lock` from the
   module parameters and apply it in a separate step run by an Owner-scoped identity.)
2. **Write `main.bicep`** (module reference pinned; parameters below are Contoso profile):

```bicep
targetScope = 'resourceGroup'
param location string = resourceGroup().location
param accountName string
param peSubnetResourceId string
param fileZoneResourceId string      // privatelink.file.core.windows.net
param logAnalyticsWorkspaceResourceId string
param adminEgressIps array = []      // e.g. ['203.0.113.10']
param tags object = { owner: 'itd-storage', environment: 'prod', dataClassification: 'internal' }

module sa 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'sa-${accountName}'
  params: {
    name: accountName
    location: location
    kind: 'StorageV2'
    skuName: 'Standard_ZRS'            // Standard_GRS for region loss; never RA-GRS for Files
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true          // keep true until Azure File Sync managed identities are configured (agent v20.0.0.0+, Azure VM or Arc-enabled server, Set-AzStorageSyncServiceIdentity; servers without a system-assigned MI keep using shared keys); still required today by Azure Backup for Azure Files ("Allow storage account key access" must be enabled)
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Enabled'      // Deny + trusted services below; NOT Disabled (File Sync / Backup)
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: [for ip in adminEgressIps: { action: 'Allow', value: ip }]
      virtualNetworkRules: []
      resourceAccessRules: []
    }
    privateEndpoints: [
      {
        name: 'pe-${accountName}-file'
        service: 'file'
        subnetResourceId: peSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [ { privateDnsZoneResourceId: fileZoneResourceId } ]
        }
        tags: tags
      }
    ]
    fileServices: {
      diagnosticSettings: [
        { workspaceResourceId: logAnalyticsWorkspaceResourceId, logCategoriesAndGroups: [ { categoryGroup: 'allLogs' } ], metricCategories: [ { category: 'Transaction' } ] }
      ]
      shareDeleteRetentionPolicy: { enabled: true, days: 14 }
      protocolSettings: {
        smb: {
          versions: 'SMB3.0;SMB3.1.1'
          authenticationMethods: 'NTLMv2;Kerberos'   // switch to 'Kerberos' after AD DS join + validation
          kerberosTicketEncryption: 'AES-256'
          channelEncryption: 'AES-128-GCM;AES-256-GCM'
        }
      }
      shares: [
        { name: 'home-drives', shareQuota: 5120, accessTier: 'TransactionOptimized', enabledProtocols: 'SMB' }
        { name: 'dept-shares', shareQuota: 10240, accessTier: 'TransactionOptimized', enabledProtocols: 'SMB' }
        { name: 'archive', shareQuota: 5120, accessTier: 'Cool', enabledProtocols: 'SMB' }
      ]
    }
    diagnosticSettings: [
      { workspaceResourceId: logAnalyticsWorkspaceResourceId, metricCategories: [ { category: 'Transaction' } ] }
    ]
    lock: { kind: 'CanNotDelete', name: 'lock-${accountName}' }
    tags: tags
  }
}
output storageAccountResourceId string = sa.outputs.resourceId
```

3. **Deploy** with `az deployment group create` (step list below); the module is idempotent,
   re-running with the same parameters changes nothing.
4. **Encryption in transit for SMB.** Accounts created by CLI/Bicep leave **Require
   Encryption in Transit for SMB** unset; set it explicitly:
   `Update-AzStorageFileServiceProperty -ResourceGroupName <rg> -StorageAccountName <account> -SmbEncryptionInTransitRequired $true`.
5. **Key expiration policy.** Rotate both keys once (`az storage account keys renew --key
   primary` then `secondary`), then `az storage account update --key-exp-days 180`.
6. **Defender for Storage.** Subscription-level plan (`az security pricing create -n
   StorageAccounts --tier standard`) or per-account in Defender for Cloud.
7. **Register the endpoint IP in Infoblox IPAM** and confirm the Infoblox forwarder for
   `privatelink.file.core.windows.net` exists ([[blueprint-azure-dns-for-private-endpoints]]).
8. **Verify** from a Contoso file server (`Resolve-DnsName`, `Test-NetConnection`), then run
   the kit exporter + assessor; expected: no SEC/DATA findings other than SEC-04 and SEC-14,
   no NET-02.
9. **Hand over** to [[playbook-enable-identity-based-auth-ad-ds]] (AD DS join + share RBAC)
   and [[playbook-enable-azure-backup-for-file-shares]].
10. **Retire shared key access (follow-up).** Once every registered File Sync server
    authenticates with its managed identity (agent v20.0.0.0+,
    `Set-AzStorageSyncServiceIdentity`) and Azure Backup no longer requires it, set
    `allowSharedKeyAccess: false` and re-run the assessor (SEC-04 should clear).

## Steps

```yaml
vars:
  - name: rg
    describe: resource group for the storage account
    required: true
  - name: account
    describe: storage account name (3-24 lowercase alphanumerics)
    required: true
  - name: pe_subnet_id
    describe: resource id of the private-endpoint subnet in the spoke
    required: true
  - name: file_zone_id
    describe: resource id of privatelink.file.core.windows.net
    required: true
  - name: law_id
    describe: resource id of the Log Analytics workspace
    required: true
steps:
  - name: preconditions
    run: az bicep version && az network private-dns zone show --ids <file_zone_id> --query name -o tsv
    verify: prints a Bicep version and privatelink.file.core.windows.net
  - name: deploy
    run: az deployment group create -g <rg> -f main.bicep -p accountName=<account> peSubnetResourceId=<pe_subnet_id> fileZoneResourceId=<file_zone_id> logAnalyticsWorkspaceResourceId=<law_id>
    verify: provisioningState Succeeded and output storageAccountResourceId printed
  - name: smb encryption in transit
    run: powershell -Command "Update-AzStorageFileServiceProperty -ResourceGroupName <rg> -StorageAccountName <account> -SmbEncryptionInTransitRequired $true"
    verify: Get-AzStorageFileServiceProperty shows ProtocolSettings.Smb.EncryptionInTransit.Required : True
  - name: key policy
    run: az storage account keys renew -g <rg> -n <account> --key primary && az storage account keys renew -g <rg> -n <account> --key secondary && az storage account update -g <rg> -n <account> --key-exp-days 180
    verify: az storage account show -g <rg> -n <account> --query keyPolicy.keyExpirationPeriodInDays -o tsv prints 180
  - name: confirm the effect
    run: az storage account show -g <rg> -n <account> --query "[sku.name, minimumTlsVersion, networkRuleSet.defaultAction, networkRuleSet.bypass, length(privateEndpointConnections)]" -o tsv
    verify: prints Standard_ZRS (or GRS), TLS1_2, Deny, AzureServices, 1
  - name: private resolution from on-premises
    run: powershell -Command "(Resolve-DnsName <account>.file.core.windows.net -Type A).IP4Address; (Test-NetConnection <account>.file.core.windows.net -CommonTCPPort SMB).TcpTestSucceeded"
    verify: prints a 10.x address and True on a Contoso file server
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: deploy-secure-storage-account-and-share`
- **CR file:** `change-management/CR-<date>-deploy-secure-storage-account-and-share.md`
- **Closure:** every `verify:` above passes and the assessor reports no SEC/DATA finding other than SEC-04 and SEC-14

## Gate rules

```json
[
  {"rule": "the deployment is the module, not portal clicks", "severity": "error", "check": "grep -c \"br/public:avm/res/storage/storage-account:0.33.0\" main.bicep prints 1"},
  {"rule": "public network access stays Enabled with Deny + AzureServices", "severity": "error", "check": "az storage account show -g <rg> -n <account> --query \"[publicNetworkAccess, networkRuleSet.defaultAction, networkRuleSet.bypass]\" -o tsv prints Enabled, Deny, AzureServices"},
  {"rule": "the file private endpoint resolves privately from Contoso", "severity": "error", "check": "powershell -Command \"(Resolve-DnsName <account>.file.core.windows.net -Type A).IP4Address\" on a Contoso server prints a 10.x address"},
  {"rule": "share soft delete is 14 days or more", "severity": "error", "check": "az storage account file-service-properties show -g <rg> -n <account> --query shareDeleteRetentionPolicy.days -o tsv prints >= 14"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-files-secure-storage-account.md
  anchor: "Governance - Azure Policy guardrails"
  why: the target state and the policy set this deployment must satisfy
- path: codex/playbook-add-file-private-endpoint-and-dns.md
  anchor: "dns-zone-group"
  why: the standalone path when the endpoint is added to an existing account
- path: Assess-AzFileSyncExport.ps1
  anchor: "SEC-08"
  why: the SMB-defaults check the protocolSettings block satisfies
```

Microsoft Learn / registries (read 2026-09-03): Azure Verified Modules avm/res/storage/storage-account
README and MCR tag list (0.33.0); Configure Azure Files network endpoints; SMB file shares in
Azure Files (security settings, encryption in transit); Manage account access keys (key
expiration policy).
