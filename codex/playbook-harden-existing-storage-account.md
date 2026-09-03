---
slug: playbook-harden-existing-storage-account
doc_type: playbook
kind: harden-existing-storage-account
category: ops
title: Harden an existing Azure Files storage account without breaking File Sync or Backup
summary: Ordered retrofit of the secure baseline on a live account: TLS and HTTPS, SMB hardening, soft delete, key policy, diagnostics, Defender, lock, then the firewall to Deny with trusted services - each step verified against sync health and backup jobs.
when_to_use: The assessor reports SEC-* or DATA-* findings on a storage account that already serves Azure File Sync cloud endpoints or backed-up shares.
applies_to: [ops, devstation]
tags: [azure-files, storage-account, hardening, firewall, smb, azure-file-sync, azure-backup, contoso]
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

Contoso's existing account (LRS, TLS 1.0 allowed, firewall Allow, soft delete off or 7
days, default SMB settings, no lock, no key policy) must reach
[[blueprint-azure-files-secure-storage-account]] while File Sync keeps syncing and Azure
Backup keeps running. The order matters: everything that cannot break sync goes first, the
network lock-down goes last and only after the private endpoint resolves from every server.

## Reuse before reinvent (GR11)

```yaml
- primitive: Assess-AzFileSyncExport.ps1 before/after
  path: Assess-AzFileSyncExport.ps1
  why: the same rule set that found the gaps proves they are closed; hand-written checklists
       drift from the rules on the next kit release
- primitive: playbook-add-file-private-endpoint-and-dns
  path: codex/playbook-add-file-private-endpoint-and-dns.md
  why: the private path must exist before the public one is denied; this playbook only locks,
       it does not create the endpoint
- primitive: trusted-services bypass (defaultAction Deny + bypass AzureServices) for the Storage Sync Service and Azure Backup
  path: codex/blueprint-azure-file-sync-private-path.md
  why: the Microsoft-documented way to keep the Storage Sync Service and Azure Backup reaching
       the account once the default action is Deny
```

## Procedure

1. **Baseline evidence.** Export + assess; keep `assessment.md` as the "before". Note every
   client that mounts the share directly with the account key (NTLMv2) - they break when
   NTLMv2 is removed or the public endpoint is denied without a private path.
2. **Non-disruptive settings (any time, no sync impact).** `minimumTlsVersion TLS1_2`,
   `supportsHttpsTrafficOnly true` (File Sync already uses HTTPS), `allowBlobPublicAccess
   false`, `allowCrossTenantReplication false`, share soft delete 14 days, `largeFileSharesState
   Enabled` (irreversible, no cost), diagnostics for `fileServices/default` to Log Analytics,
   Defender for Storage, tags, `CanNotDelete` lock. Verify: the next File Sync 9102 event has
   HResult 0 and the next backup job completes.
3. **SMB hardening (may affect direct SMB clients, never File Sync).** Set
   `versions SMB3.0;SMB3.1.1`, `kerberosTicketEncryption AES-256`, `channelEncryption
   AES-128-GCM;AES-256-GCM`, keep `authenticationMethods NTLMv2;Kerberos` until identity-based
   auth is live and every key-based mount is gone, then `Kerberos`. Enable **Require Encryption
   in Transit for SMB**. Verify with a test mount from a Windows Server 2019+ client.
4. **Keys.** Rotate key2, then key1 (unless File Sync managed identities are enabled, both the
   Storage Sync Service and Azure Backup authenticate to the share with the storage account
   key - "Allow storage account key access" must stay enabled, and no backup or restore job may
   be in flight during rotation; account and service SAS tokens signed with the rotated key are
   revoked and must be reissued), set `keyExpirationPeriodInDays 180`. Verify after each
   rotation: key-based clients repointed, sync session and backup job green.
5. **Private endpoint present and resolving** from every registered server and every direct
   SMB client ([[playbook-add-file-private-endpoint-and-dns]]). Do not continue until
   `Resolve-DnsName` returns the private IP everywhere.
6. **Firewall.** `defaultAction Deny`, `bypass AzureServices` (the trusted-services exception
   that covers both the Storage Sync Service and Azure Backup), IP rules for admin egress only.
   Keep `publicNetworkAccess Enabled`.
   Verify within the hour: File Sync 9102 HResult 0 on every server, a cloud change
   enumeration completes (portal cloud endpoint), an on-demand backup job completes, the
   portal file browser works from the admin IP.
7. **Identity.** Hand over to [[playbook-enable-identity-based-auth-ad-ds]] to remove NTLMv2 and
   key-based mounts; then re-evaluate SEC-04 (shared key stays while File Sync has no managed
   identity and while Azure Backup protects the shares).
8. **After evidence.** Re-export + re-assess; store both assessments with the change record.

## Steps

```yaml
vars:
  - name: rg
    describe: resource group of the storage account
    required: true
  - name: account
    describe: storage account name
    required: true
  - name: admin_ip
    describe: public egress IP of the admin network
    required: true
steps:
  - name: preconditions (before evidence)
    run: powershell -File Assess-AzFileSyncExport.ps1 -ExportPath <export-before.zip> -CustomerName "Contoso" -PrivateTrafficRequired
    verify: assessment.md written; note the SEC/DATA/NET findings for <account>
  - name: non-disruptive settings
    run: az storage account update -g <rg> -n <account> --min-tls-version TLS1_2 --https-only true --allow-blob-public-access false --allow-cross-tenant-replication false && az storage account file-service-properties update -g <rg> -n <account> --enable-delete-retention true --delete-retention-days 14 && az storage account update -g <rg> -n <account> --enable-large-file-share && az lock create -n lock-<account> -t CanNotDelete --resource-group <rg> --resource <account> --resource-type Microsoft.Storage/storageAccounts
    verify: az storage account show -g <rg> -n <account> --query "[minimumTlsVersion, enableHttpsTrafficOnly, largeFileSharesState]" -o tsv prints TLS1_2 true Enabled and the next 9102 event has HResult 0
  - name: smb hardening
    run: az storage account file-service-properties update -g <rg> -n <account> --versions "SMB3.0;SMB3.1.1" --kerb-ticket-encryption "AES-256" --channel-encryption "AES-128-GCM;AES-256-GCM" --auth-methods "NTLMv2;Kerberos" && az storage account file-service-properties update -g <rg> -n <account> --require-smb-encryption-in-transit --smb-eit true
    verify: a test mount from a Windows Server 2019 client succeeds and az storage account file-service-properties show prints the values
  - name: key rotation - key2
    run: az storage account keys renew -g <rg> -n <account> --key secondary
    verify: every key-based mount and SAS is repointed to the new key2, then the next File Sync 9102 event has HResult 0 and the next backup job status is Completed
  - name: key rotation - key1
    run: az storage account keys renew -g <rg> -n <account> --key primary
    verify: every key-based mount is repointed to the new key1 and every account and service SAS is reissued, then the next File Sync 9102 event has HResult 0 and the next backup job status is Completed
  - name: key expiration policy
    run: az storage account update -g <rg> -n <account> --key-exp-days 180
    verify: az storage account show -g <rg> -n <account> --query keyPolicy.keyExpirationPeriodInDays -o tsv prints 180
  - name: private path present
    run: powershell -Command "(Resolve-DnsName <account>.file.core.windows.net -Type A).IP4Address"
    verify: prints a 10.x address on EVERY registered server and direct SMB client
  - name: firewall lock-down
    run: az storage account network-rule add -g <rg> --account-name <account> --ip-address <admin_ip> && az storage account update -g <rg> -n <account> --default-action Deny --bypass AzureServices --public-network-access Enabled
    verify: az storage account show prints Deny/AzureServices; within 60 minutes every server endpoint shows Healthy, a cloud change enumeration completes and an on-demand backup job completes
  - name: confirm the effect (after evidence)
    run: powershell -File Assess-AzFileSyncExport.ps1 -ExportPath <export-after.zip> -CustomerName "Contoso" -PrivateTrafficRequired
    verify: no SEC-01/02/03/06/08/10/11/12, DATA-02, DATA-06, NET-06, NET-08 for <account>
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: harden-existing-storage-account`
- **CR file:** `change-management/CR-<date>-harden-existing-storage-account.md`
- **Closure:** the after-assessment shows the findings above cleared and sync + backup stayed green through every step

## Gate rules

```json
[
  {"rule": "the firewall is denied only after the private endpoint resolves everywhere", "severity": "error", "check": "az storage account show -g <rg> -n <account> --query \"[networkRuleSet.defaultAction, length(privateEndpointConnections)]\" -o tsv prints Deny and >= 1"},
  {"rule": "trusted services stay allowed", "severity": "error", "check": "az storage account show -g <rg> -n <account> --query networkRuleSet.bypass -o tsv contains AzureServices"},
  {"rule": "public network access is not Disabled on a File Sync account", "severity": "error", "check": "az storage account show -g <rg> -n <account> --query publicNetworkAccess -o tsv prints Enabled"},
  {"rule": "sync survived every step", "severity": "error", "check": "powershell -Command \"(Get-WinEvent -FilterHashtable @{LogName='Microsoft-FileSync-Agent/Telemetry'; Id=9102; StartTime=(Get-Date).AddHours(-1)} | Select -First 1).Message\" on each server contains HResult: 0"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-files-secure-storage-account.md
  anchor: "Build sequence"
  why: the target state each step moves toward
- path: codex/runbook-file-sync-broken-after-network-lockdown.md
  anchor: "trusted services"
  why: what to do if sync breaks after step 6
- path: Assess-AzFileSyncExport.ps1
  anchor: "SEC-05"
  why: why publicNetworkAccess Disabled is flagged on File Sync accounts
```

Microsoft Learn (read 2026-09-03): Azure Storage firewall rules and network access; Trusted
Azure services; SMB file shares in Azure Files; Manage account access keys; Configure Azure
File Sync network endpoints (restrict the storage account public endpoint).
