---
slug: playbook-enable-azure-backup-for-file-shares
doc_type: playbook
kind: enable-azure-backup-for-file-shares
category: ops
title: Enable Azure Backup with snapshot and vaulted tiers for every Azure file share
summary: Create and harden the regional Recovery Services vault (GRS and cross-region restore first, soft delete always-on, immutability, MUA, alerts), create the policies, protect every share, run first backups and one documented restore.
when_to_use: Shares are unprotected (BKP-01), snapshot-only (BKP-04) or the vault fails hardening checks (BKP-06 to BKP-11), or a restore test is due.
applies_to: [ops, devstation]
tags: [azure-backup, azure-files, recovery-services-vault, vaulted-backup, policy, restore, contoso]
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

You decided to implement [[blueprint-azure-files-backup-protection]] on Contoso's file
share estate. The storage accounts already meet the prerequisites (key access allowed, share
soft delete 14 days, firewall Deny with trusted services, same region as the vault). Run it
once per region; re-run to protect newly created shares.

## Reuse before reinvent (GR11)

```yaml
- primitive: Az.RecoveryServices cmdlets (New-AzRecoveryServicesVault, Set-AzRecoveryServicesBackupProperty, Enable-AzRecoveryServicesBackupProtection, Backup-AzRecoveryServicesBackupItem)
  path: docs/PLAYBOOK-azure-backup-for-azure-files.md
  why: the same cmdlets protect every share idempotently; the portal wizard is fine for the
       vaulted-tier policy and MUA, but the per-share loop belongs in PowerShell
- primitive: backup/share-coverage.json from the exporter
  path: Export-AzFileSyncEnvironment.ps1
  why: the list of shares to protect and the after-evidence come from the same export, so
       nothing is protected twice or forgotten
```

## Procedure

1. **Preconditions.** Backup Contributor on the vault resource group, Contributor on the
   storage accounts, the coverage table from the latest export, Contoso records-retention
   schedule (drives the vault retention), a second administrator for the Resource Guard, the
   Log Analytics workspace id, the action group for alerts. Shares whose used size exceeds
   10 TB or which hold more than 10 million files and folders cannot use the Vault-standard
   tier - protect those with a snapshot-tier policy and record the exception in the change
   ticket.
2. **Vault** (`rsv-<org>-<region>`): create, set `BackupStorageRedundancy GeoRedundant` and
   enable cross-region restore **before** any item is protected, enable soft delete and set it
   to always-on (portal > Properties > Security settings: 14-180 days), enable immutability
   (Unlocked), enable Azure Monitor alerts for all job failures, add the diagnostic settings,
   add the `CanNotDelete` lock and tags.
3. **Resource Guard + MUA.** The second administrator creates a Resource Guard in their
   subscription and grants the vault operator Reader on it; enable multi-user authorization on
   the vault (portal > Properties > Multi-user authorization).
4. **Policies.** `AFS-Active-4h-30d-Vault-90d` (snapshot + vault-standard, hourly every 4 h in
   an 8-hour window, snapshots 30 days, vault daily 90 d / monthly 12 / yearly 7 y, Pacific)
   and `AFS-Archive-1d-30d-Vault-1y`. The vaulted tier is easiest in the portal wizard
   (Backup tier: Vault-standard); PowerShell uses
   `$schedulePolicy = Get-AzRecoveryServicesBackupSchedulePolicyObject -WorkloadType
   AzureFiles` and `$retentionPolicy = Get-AzRecoveryServicesBackupRetentionPolicyObject
   -WorkloadType AzureFiles -BackupTier VaultStandard` (set
   $retentionPolicy.SnapshotRetentionInDays and the vault daily/monthly/yearly schedules),
   then `New-AzRecoveryServicesBackupProtectionPolicy -VaultId $v.ID -Name <policy>
   -WorkloadType AzureFiles -SchedulePolicy $schedulePolicy -RetentionPolicy
   $retentionPolicy`. Without `-BackupTier VaultStandard` on the retention object the result
   is a snapshot-only policy (BKP-04). Azure PowerShell does not support hourly-schedule
   Azure Files policies - create those in the portal.
5. **Protect every share** in the coverage table (File Sync cloud endpoints first) and run an
   on-demand backup per item; wait for `Completed`.
6. **Alert test.** Temporarily set a test storage account's firewall bypass to none, run an
   on-demand backup, confirm the failure alert e-mail, revert.
7. **Restore test.** Item-level restore of one folder from the newest snapshot recovery point
   to an alternate folder on the same share; then confirm the File Sync servers received it.
   Changes written directly to the Azure file share are picked up by the cloud-endpoint change
   detection job, which starts only once every 24 hours; to see the restored folder on the
   servers immediately, force detection with `Invoke-AzStorageSyncChangeDetection
   -ResourceGroupName <rg> -StorageSyncServiceName <sss> -SyncGroupName <sg>
   -Name <cloud-endpoint-guid> -DirectoryPath 'restore-test' -Recursive` (scoped runs detect
   at most 10,000 items; omit -DirectoryPath for full share-level detection). Record job id,
   duration and evidence.
8. **Lock immutability** (portal > Properties > Immutability > Locked) once the restore test
   passed; this is irreversible by design.
9. **Evidence.** Re-export + re-assess; coverage 100 %, no BKP-01..BKP-03, BKP-06..BKP-12,
   and no BKP-04 on any share eligible for the vault tier (documented snapshot-tier
   exceptions excluded).

## Steps

```yaml
vars:
  - name: rg
    describe: vault resource group
    required: true
  - name: loc
    describe: region (same as the storage accounts)
    required: true
  - name: vault
    describe: vault name, e.g. rsv-contoso-westus
    required: true
  - name: policy
    describe: policy name for active shares, e.g. AFS-Active-4h-30d-Vault-90d
    required: true
  - name: account
    describe: storage account holding the shares to protect
    required: true
steps:
  - name: preconditions
    run: az storage account show -g <sa-rg> -n <account> --query "[allowSharedKeyAccess, networkRuleSet.bypass, location]" -o tsv && az storage account file-service-properties show -g <sa-rg> -n <account> --query shareDeleteRetentionPolicy.days -o tsv
    verify: prints true (or null), AzureServices, <loc>, and >= 14
  - name: vault and redundancy (before any item)
    run: powershell -Command "$v=New-AzRecoveryServicesVault -ResourceGroupName <rg> -Name <vault> -Location <loc>; Set-AzRecoveryServicesBackupProperty -Vault $v -BackupStorageRedundancy GeoRedundant; Set-AzRecoveryServicesVaultProperty -VaultId $v.ID -SoftDeleteFeatureState Enable; Get-AzRecoveryServicesBackupProperty -Vault $v"
    verify: BackupStorageRedundancy GeoRedundant; then in the portal set soft delete always-on, immutability Unlocked, cross-region restore Enabled, alerts for all job failures Enabled
  - name: policies
    run: (portal) Vault > Backup policies > Add > Azure Files: name <policy>, Backup tier Vault-standard, hourly every 4 h 08:00-16:00 Pacific, snapshot retention 30 days, vault retention daily 90 / monthly 12 / yearly 7; repeat for AFS-Archive-1d-30d-Vault-1y with daily schedule
    verify: powershell -Command "Get-AzRecoveryServicesBackupProtectionPolicy -VaultId (Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>).ID -WorkloadType AzureFiles | Select Name" lists both policies
  - name: protect every share
    run: powershell -Command "$v=Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>; $p=Get-AzRecoveryServicesBackupProtectionPolicy -Name <policy> -VaultId $v.ID; foreach ($s in (az storage share-rm list --storage-account <account> --query '[].name' -o tsv)) { Enable-AzRecoveryServicesBackupProtection -StorageAccountName <account> -Name $s -Policy $p -VaultId $v.ID }"
    verify: Get-AzRecoveryServicesBackupItem -Container (Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -FriendlyName <account> -VaultId $v.ID) -WorkloadType AzureFiles -VaultId $v.ID lists every share with ProtectionState Protected
  - name: first backups
    run: powershell -Command "$v=Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>; $c=Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -FriendlyName <account> -VaultId $v.ID; Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureFiles -VaultId $v.ID | % { Backup-AzRecoveryServicesBackupItem -Item $_ -VaultId $v.ID }; Get-AzRecoveryServicesBackupJob -VaultId $v.ID -From (Get-Date).AddHours(-2).ToUniversalTime() | Format-Table Operation,Status,WorkloadName"
    verify: every Backup job status is Completed
  - name: restore test
    run: powershell -Command "$v=Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>; $c=Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -FriendlyName <account> -VaultId $v.ID; $i=Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureFiles -FriendlyName <share> -VaultId $v.ID; $rp=Get-AzRecoveryServicesBackupRecoveryPoint -Item $i -VaultId $v.ID | Select -First 1; Restore-AzRecoveryServicesBackupItem -RecoveryPoint $rp -TargetStorageAccountName <account> -TargetFileShareName <share> -TargetFolder 'restore-test' -SourceFilePath '<folder>' -SourceFileType Directory -ResolveConflict Overwrite -VaultId $v.ID -VaultLocation $v.Location"
    verify: the restore job completes, the folder appears under restore-test on the share, and on the File Sync servers after change detection is invoked or within 24 h
  - name: confirm the effect
    run: powershell -File Assess-AzFileSyncExport.ps1 -ExportPath <export-after.zip> -CustomerName "Contoso"
    verify: findings.json contains no BKP-01, BKP-02, BKP-03, BKP-06, BKP-07, BKP-08, BKP-09, BKP-10, BKP-11, BKP-12, and no BKP-04 except the documented snapshot-tier exceptions for shares outside the vault-tier limits
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: enable-azure-backup-for-file-shares`
- **CR file:** `change-management/CR-<date>-enable-azure-backup-for-file-shares.md`
- **Closure:** coverage 100 % protected, vaulted policies on every share within the vault-tier limits (<= 10 TB, <= 10 million files and folders), documented snapshot-tier exceptions for the rest, alert test received, restore test documented, immutability locked

## Gate rules

```json
[
  {"rule": "redundancy is decided before the first protected item", "severity": "error", "check": "az backup vault backup-properties show -n <vault> -g <rg> --query \"[0].properties.storageModelType\" -o tsv prints GeoRedundant (the command returns a two-element array, so the [0] index is required) while az backup item list -v <vault> -g <rg> --query length(@) is 0 at creation time (recorded in the change ticket)"},
  {"rule": "every share is protected", "severity": "error", "check": "az backup item list -v <vault> -g <rg> --backup-management-type AzureStorage --workload-type AzureFileShare --query \"[].properties.friendlyName\" -o tsv lists every share from backup/share-coverage.json"},
  {"rule": "the active policy carries a vault tier", "severity": "error", "check": "az backup policy show -v <vault> -g <rg> -n <policy> --query properties.vaultRetentionPolicy -o json is not null"},
  {"rule": "a restore was executed and documented", "severity": "error", "check": "az backup job list -v <vault> -g <rg> --operation Restore --status Completed --query length(@) prints >= 1"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-files-backup-protection.md
  anchor: "Restore paths"
  why: the restore model the test in step 7 exercises
- path: codex/runbook-restore-file-share-and-share-soft-delete.md
  anchor: "MABRestoreScratchFolder"
  why: the vault-tier restore constraint operators hit first
- path: Export-AzFileSyncEnvironment.ps1
  anchor: "share-coverage"
  why: where the list of shares to protect comes from
```

Microsoft Learn (read 2026-09-03): About Azure Files backup; Support matrix for Azure Files
backup (limits, key access, hourly schedule); Restore Azure Files (item level, alternate
location, scratch folder); Azure Backup security features (soft delete, immutability, MUA).
