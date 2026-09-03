---
slug: playbook-protect-a-migration-wave-with-azure-backup
doc_type: playbook
kind: protect-a-migration-wave-with-azure-backup
category: ops
title: Protect a migration wave with Azure Backup before the wave is allowed to close
summary: Create the Enhanced VM policy, protect every VM that landed in the wave, run and verify first backups, confirm no file agent targets a File Sync cache, and produce the evidence that closes the wave gate.
when_to_use: A migration wave has cut over and the VMs are running but unprotected, or a wave is about to be declared complete.
applies_to: [ops, devstation]
tags: [azure-backup, azure-vm-backup, migration-wave, azure-migrate, enhanced-policy, wave-gate, contoso]
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

A wave of servers has cut over from VMware through Azure Migrate and is running in Azure. The
VMs work, so nothing looks wrong - which is exactly the problem. Run this before the wave is
declared complete and before any source server is powered off for good. Target state is
[[blueprint-azure-vm-backup-for-migrated-servers]]; the share side is
[[playbook-enable-azure-backup-for-file-shares]].

## Reuse before reinvent (GR11)

```yaml
- primitive: the regional Recovery Services vault already built for the file share estate
  path: codex/playbook-enable-azure-backup-for-file-shares.md
  why: one vault per region holds both workload types, so the hardening, alerting and
       cross-region restore decision are made once rather than diverging between two vaults
- primitive: Az.RecoveryServices policy and protection cmdlets
  path: codex/playbook-enable-azure-backup-for-file-shares.md
  why: the Enhanced VM policy object is only creatable through the PowerShell schedule-policy
       object or the portal, and the same protection loop shape already protects the shares
- primitive: the wave plan and disposition table
  path: advise/REFERENCE-DESIGN.md
  why: which VMs are in the wave and which are disposition B (File Sync attached, so the share
       is protected instead of the volume) is decided there, not re-derived here
```

## Procedure

1. **Preconditions.** Backup Contributor on the vault resource group and Virtual Machine
   Contributor on the wave's VMs. The wave plan listing every VM that cut over. The
   disposition table marking which of them have File Sync attached. The retention values from
   Contoso records-retention schedule. Confirm the vault's `BackupStorageRedundancy` and
   cross-region restore are already set - if the vault has no protected items yet, this is the
   last moment to change them.
2. **Confirm the security type of what landed.** Query the wave's VMs for `securityType`. Any
   Trusted Launch VM, any Ultra Disk and any Premium SSD v2 requires the **Enhanced** policy.
   Azure Migrate lands Trusted Launch by default where the guest supports it, so expect this to
   be the normal case rather than the exception.
3. **Create the Enhanced policy once per region.** Build it from the schedule-policy object
   with `-PolicySubType Enhanced`, set the schedule (daily unless the wave contains a workload
   with a sub-daily recovery point requirement), set `SnapshotRetentionInDays` (1 to 30, and
   lower where the hourly frequency caps it - 17 days at a 4-hour frequency, 22 at 6), and set
   retention from the records schedule rather than the portal defaults of 180 days daily, 12
   weeks weekly, 60 months monthly and 10 years yearly. **This choice is one-way**: a VM
   protected with an Enhanced policy cannot later be moved to a Standard policy.
4. **Protect every VM in the wave.** Loop the wave list and enable protection. Skip nothing
   silently - a VM deliberately left unprotected is recorded as an exception in the change
   ticket with the reason and an owner.
5. **Decide selective disk backup deliberately.** If non-critical data disks are excluded to
   save cost, record which disks on which VMs, because an excluded disk is an unprotected disk
   and the restore experience will not remind anyone.
6. **Run and verify first backups.** Trigger an on-demand backup for every newly protected
   item rather than waiting for the schedule, and confirm every job completes. Billing begins
   only after the first successful backup, so an unprotected VM is invisible on the invoice as
   well as in the portal.
7. **Confirm the File Sync prohibition holds.** For every disposition B server in the wave,
   verify that no file-level backup agent is running against the server endpoint volume. This
   is the check that prevents a full recall of the tiered dataset. Either the agent is absent,
   or the server endpoint path is excluded and the exclusion is recorded.
8. **Restore test, once per wave.** Restore one file from one VM recovery point and record the
   evidence: which VM, which recovery point, how long it took. A wave whose restore path has
   never been exercised is not protected, it is only backed up.
9. **Close the gate.** Produce the evidence set: protected count equals wave count, every
   first backup completed, exceptions recorded, restore evidence attached. Only then may the
   source servers be powered off.

## Steps

```yaml
vars:
  - name: vault
    describe: regional Recovery Services vault, e.g. rsv-contoso-westus
    required: true
  - name: rg
    describe: resource group holding the vault
    required: true
  - name: policy
    describe: Enhanced VM policy name, e.g. VM-Enhanced-Daily-7d-Records
    required: true
  - name: wave-rg
    describe: resource group holding the migrated VMs of this wave
    required: true
steps:
  - name: vault redundancy is already decided
    run: az backup vault backup-properties show -n <vault> -g <rg> --query "[0].properties.[storageModelType, crossRegionRestoreFlag]" -o tsv
    verify: prints the agreed redundancy and cross-region restore flag; if any item is already protected these can no longer be changed
  - name: security type of what landed
    run: az vm list -g <wave-rg> --query "[].{name:name, securityType:securityProfile.securityType}" -o table
    verify: every Trusted Launch VM is accounted for; if any is present the policy must be the Enhanced subtype
  - name: create the Enhanced policy
    run: powershell -Command "$v=Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>; $sch=Get-AzRecoveryServicesBackupSchedulePolicyObject -WorkloadType AzureVM -BackupManagementType AzureVM -PolicySubType Enhanced -ScheduleRunFrequency Daily; $ret=Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType AzureVM; New-AzRecoveryServicesBackupProtectionPolicy -Name <policy> -WorkloadType AzureVM -RetentionPolicy $ret -SchedulePolicy $sch -VaultId $v.ID"
    verify: powershell -Command "Get-AzRecoveryServicesBackupProtectionPolicy -PolicySubType Enhanced -VaultId (Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>).ID | Select-Object Name" lists <policy>
  - name: set snapshot retention
    run: powershell -Command "$v=Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>; $p=Get-AzRecoveryServicesBackupProtectionPolicy -Name <policy> -VaultId $v.ID; $p.SnapshotRetentionInDays=7; Set-AzRecoveryServicesBackupProtectionPolicy -policy $p -VaultId $v.ID"
    verify: powershell -Command "(Get-AzRecoveryServicesBackupProtectionPolicy -Name <policy> -VaultId (Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>).ID).SnapshotRetentionInDays" prints 7
  - name: protect every VM in the wave
    run: powershell -Command "$v=Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>; $p=Get-AzRecoveryServicesBackupProtectionPolicy -Name <policy> -VaultId $v.ID; Get-AzVM -ResourceGroupName <wave-rg> | ForEach-Object { Enable-AzRecoveryServicesBackupProtection -Policy $p -Name $_.Name -ResourceGroupName <wave-rg> -VaultId $v.ID }"
    verify: az backup item list -v <vault> -g <rg> --backup-management-type AzureIaasVM --query "[].properties.friendlyName" -o tsv lists every VM in the wave plan
  - name: first backups
    run: powershell -Command "$v=Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>; $c=Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -VaultId $v.ID; $c | ForEach-Object { $i=Get-AzRecoveryServicesBackupItem -Container $_ -WorkloadType AzureVM -VaultId $v.ID; Backup-AzRecoveryServicesBackupItem -Item $i -VaultId $v.ID }"
    verify: az backup job list -v <vault> -g <rg> --backup-management-type AzureIaasVM --operation Backup --query "[].{name:properties.entityFriendlyName, status:properties.status}" -o table shows Completed for every VM
  - name: no file agent on a File Sync cache
    run: powershell -Command "Get-Service -Name '*backup*','*veeam*','*commvault*','*netbackup*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running' | Select-Object Name,Status"
    verify: returns nothing on every disposition B server, or the change ticket records the server endpoint path exclusion configured in the agent
  - name: restore test
    run: powershell -Command "$v=Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>; $c=Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName <vm> -VaultId $v.ID; $i=Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -VaultId $v.ID; $rp=Get-AzRecoveryServicesBackupRecoveryPoint -Item $i -VaultId $v.ID | Select-Object -First 1; Get-AzRecoveryServicesBackupRPMountScript -RecoveryPoint $rp -VaultId $v.ID"
    verify: the mount script is produced and, when run on a recovery host, the recovery point mounts and a test file is readable; record VM, recovery point time and duration, then dismiss the mount
  - name: close the wave gate
    run: az backup item list -v <vault> -g <rg> --backup-management-type AzureIaasVM --query "length([?properties.protectionState=='Protected'])" -o tsv
    verify: the count equals the number of VMs in the wave plan minus any recorded exceptions, and the restore evidence is attached to the change ticket
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: protect-a-migration-wave-with-azure-backup`
- **CR file:** `change-management/CR-<date>-protect-migration-wave-<n>.md`
- **Closure:** every VM in the wave protected with a completed first backup, exceptions
  recorded with an owner, the File Sync prohibition verified on every disposition B server,
  one restore evidenced, and the source servers not powered off until all of it holds

## Gate rules

```json
[
  {"rule": "every VM in the wave is protected", "severity": "error", "check": "az backup item list -v <vault> -g <rg> --backup-management-type AzureIaasVM --query \"length([?properties.protectionState=='Protected'])\" -o tsv prints a value equal to the wave VM count minus recorded exceptions"},
  {"rule": "the policy is the Enhanced subtype", "severity": "error", "check": "powershell -Command \"Get-AzRecoveryServicesBackupProtectionPolicy -PolicySubType Enhanced -VaultId (Get-AzRecoveryServicesVault -Name <vault> -ResourceGroupName <rg>).ID | Select-Object -ExpandProperty Name\" lists the wave policy"},
  {"rule": "every protected VM has a completed first backup", "severity": "error", "check": "az backup job list -v <vault> -g <rg> --backup-management-type AzureIaasVM --operation Backup --status Completed --query length(@) -o tsv prints a value equal to or greater than the protected VM count"},
  {"rule": "a restore was exercised for this wave", "severity": "error", "check": "az backup job list -v <vault> -g <rg> --backup-management-type AzureIaasVM --operation Restore --query length(@) -o tsv prints 1 or more, or the change ticket carries the file-recovery mount evidence"},
  {"rule": "no running file backup agent on a File Sync server endpoint", "severity": "error", "check": "powershell -Command \"Get-Service -Name '*backup*','*veeam*','*commvault*','*netbackup*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running'\" returns nothing on each disposition B server, or the ticket records the configured path exclusion"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-vm-backup-for-migrated-servers.md
  anchor: "three protection surfaces"
  why: the target state this playbook builds, including why the File Sync cache is excluded
- path: codex/playbook-enable-azure-backup-for-file-shares.md
  anchor: "vault"
  why: the vault and its security posture are created there and shared with this workload
- path: advise/BUILD-SEQUENCE.md
  anchor: "Gate 3"
  why: where this playbook sits in the wave sequence and what it blocks
```

Microsoft Learn (read 2026-09-03): Back up Azure VMs with the Enhanced policy (PolicySubType,
schedule-policy object, SnapshotRetentionInDays, one-way constraint); About Azure VM backup
(first backup, billing after first success, snapshot to vault transfer); Selective disk backup
and restore for Azure VMs; Recover files from an Azure VM backup (mount script).
