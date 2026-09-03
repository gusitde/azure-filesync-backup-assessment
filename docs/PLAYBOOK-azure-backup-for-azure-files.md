# Playbook - design and set up Azure Backup for Azure file shares (incl. Azure File Sync)

**Use when** the customer asks "go over and set up Azure Backup and recovery for the data
stored in Azure" and the data is (mostly) Azure file shares behind Azure File Sync. The
outcome is a **protected estate** - every share on a policy, vault hardened, alerts on, a
restore proven - and a one-page **backup design** the customer keeps.

Prerequisite: the export + assessment from
[PLAYBOOK-azure-file-sync-assessment.md](PLAYBOOK-azure-file-sync-assessment.md). The
assessor's `BKP-*` rows and the **File share backup coverage** table in `summary.md` are the
input to this playbook.

## 0. The three facts that shape the design

1. **Back up the Azure file share, not the servers.** With cloud tiering on, a server-side
   backup sees reparse points: tiered files are skipped or recalled (egress + broken
   restores); bare-metal / VM / system restores are unsupported on tiered volumes. The full
   data set lives in the Azure file share - protect it there. Server-side backup is only
   valid for a server endpoint with tiering **off** and no tiered files.
2. **Two tiers, one policy.** *Snapshot tier* = share snapshots in the same storage account
   (fast item-level restores, up to 200 recovery points, same blast radius as the data).
   *Vault-standard tier* (GA) = changed blocks copied into the Recovery Services vault after
   each snapshot: offsite, immutable, soft-deleted, cross-region restorable; full-share
   restore to an alternate location, up to 10 TB / 10 million files per share. Ransomware and
   "someone deleted the storage account" are only covered by the vault tier.
3. **Backup traffic never crosses the customer network.** The Backup service talks to the
   storage account over Microsoft's trusted-services path; the vault transfer is
   Azure-internal. A private endpoint on the vault does not apply to Azure Files. So an
   ExpressRoute requirement changes nothing here - only the File Sync path (previous
   playbook) and the management plane are client-side. Restores land in the Azure file share
   and reach the servers through File Sync (background change detection is triggered
   automatically for restored paths).

Hard requirements to check before starting (they are assessor rules):

| Requirement | Why | Rule |
|---|---|---|
| Vault in the **same region** as the storage account | Azure Files backup is regional | `BKP-14` |
| Storage account **Allow storage account key access = enabled** | Backup/restore use it | `BKP-18`, `SEC-04` |
| Storage firewall: **Allow Azure services on the trusted services list** if default is Deny | Backup service must reach the share | `AFS-14`, `SEC-03` |
| **Share soft delete** on (Backup sets 14 days; keep >= 14) | protects the share and its snapshots from deletion | `DATA-02` |
| Vault redundancy decided **before** the first item is protected | cannot change afterwards | `BKP-09` |
| NFS shares are not supported; SMB shares in GPv2 / FileStorage accounts | support matrix | - |

## 1. Design (fill the table with the customer)

| Decision | Default recommendation | Notes |
|---|---|---|
| Vault | One Recovery Services vault per region holding file shares, e.g. `rsv-<org>-<region>` | Keep VM/SQL backups in the same vault if simpler; MUA/immutability apply to the whole vault |
| Vault redundancy | **GeoRedundant + Cross Region Restore** | LRS/ZRS only if data must not leave the region; decide before protecting anything |
| Vault security | Soft delete **always-on**, 14-180 days; **Immutability** Unlocked now, Locked after the first restore test; **MUA** via a Resource Guard owned by a second admin | Rules `BKP-06/07/08` |
| Policy - File Sync shares (active data) | Snapshot every **4 h** during business hours (RPO 4 h), snapshot retention **30 days**; vault tier daily, retention **90 days** daily + **12 months** monthly + **7 years** yearly (or the records schedule) | `BKP-04/05/13` |
| Policy - archive / cold shares | Daily snapshot, 30 days; vault daily 30 days + monthly 12 + yearly per schedule | cheaper vault churn |
| Retention driver | The customer's **records-retention schedule** (public sector) and the ransomware dwell-time assumption (>= 30 days of daily points) | write the schedule reference into the policy name |
| Alerts | Azure Monitor alerts for all job failures -> action group (email + Teams/ITSM) | `BKP-11` |
| Reports | Diagnostic settings -> Log Analytics; Backup reports workbook monthly | `BKP-12` |
| Protection | **Every** share in the coverage table; File Sync cloud endpoints first | `BKP-01` |
| Locks / tags | CanNotDelete on vault and storage accounts; owner/environment/dataClassification tags | `BKP-16`, `SEC-10`, `OPS-01` |
| Restore runbook | Item-level from snapshot (self-service by the storage team), full-share to alternate location from vault (DR), cross-region restore (regional outage) | section 4 |

Cost drivers: protected-instance fee per storage account size band, snapshot storage
(billed as file share capacity), vault storage for the vaulted copy (changed blocks) at the
vault's redundancy rate, and egress only on cross-region restore. Use the Azure Backup
pricing estimator with the coverage table sizes.

## 2. Set up (portal or PowerShell - the PowerShell path is repeatable)

```powershell
Install-Module Az.RecoveryServices -Scope CurrentUser
Connect-AzAccount -Tenant <tenant-id>
$rg = 'rg-<org>-backup'; $loc = 'westus2'; $vaultName = "rsv-<org>-$loc"

# 1. Vault - redundancy BEFORE anything is protected
$vault = New-AzRecoveryServicesVault -ResourceGroupName $rg -Name $vaultName -Location $loc
Set-AzRecoveryServicesBackupProperty -Vault $vault -BackupStorageRedundancy GeoRedundant
Set-AzRecoveryServicesVaultProperty -VaultId $vault.ID -SoftDeleteFeatureState Enable   # then set AlwaysON + retention in the portal (Properties > Security settings)
# Immutability (Unlocked) + Azure Monitor alerts: portal > vault > Properties; MUA: portal > vault > Properties > Multi-user authorization (needs a Resource Guard)
Set-AzRecoveryServicesVaultContext -Vault $vault

# 2. Policy - snapshot every 4 h + vaulted copies (portal wizard is simplest for vaulted tier;
#    PowerShell: Get-AzRecoveryServicesBackupSchedulePolicyObject / RetentionPolicyObject -WorkloadType AzureFiles,
#    then New-AzRecoveryServicesBackupProtectionPolicy -Name 'AFS-Active-4h-30d-Vault-90d' -WorkloadType AzureFiles -BackupManagementType AzureStorage
#    -SchedulePolicy $sched -RetentionPolicy $ret -VaultId $vault.ID; see the Microsoft Learn article for the vaulted-tier parameters)

# 3. Protect every share from the coverage table
$acct = 'stcontosofiles01'
foreach ($share in @('home-drives', 'dept-shares', 'archive')) {
  Enable-AzRecoveryServicesBackupProtection -StorageAccountName $acct -Name $share -Policy (Get-AzRecoveryServicesBackupProtectionPolicy -Name 'AFS-Active-4h-30d-Vault-90d' -VaultId $vault.ID) -VaultId $vault.ID
}

# 4. First backup now, then verify
$c = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -FriendlyName $acct -VaultId $vault.ID
foreach ($i in Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureFiles -VaultId $vault.ID) { Backup-AzRecoveryServicesBackupItem -Item $i -VaultId $vault.ID }
Get-AzRecoveryServicesBackupJob -VaultId $vault.ID -From (Get-Date).AddHours(-2).ToUniversalTime() | Format-Table Operation, Status, WorkloadName, StartTime
```

Order of operations that avoids the two classic failures:

1. Storage firewall: if default is Deny, tick **Allow Azure services on the trusted services
   list** first (otherwise `Enable-AzRecoveryServicesBackupProtection` and every job fail).
2. Confirm **Allow storage account key access** is enabled on the account.
3. Register the storage account with the vault (happens on first protection).
4. Protect the File Sync cloud endpoint shares first (highest exposure), then the rest.
5. Run an on-demand backup for each item and check the jobs before leaving.
6. Only after the restore test: lock immutability, enable MUA, add CanNotDelete locks.

Interaction with File Sync: Azure Backup tells the Storage Sync Service which paths were
restored; change detection runs for them and the servers pick up the restored versions
without waiting for the 24-hour enumeration. Backup takes a lease on its snapshots so they
cannot be deleted by mistake, which also blocks a one-click share deletion.

## 3. Verify (what "done" looks like)

Re-run the export + assessor after the changes; the target is:

| Check | Expected |
|---|---|
| Coverage table | every share `protected = true`, protection state `Protected`, last backup `Healthy` |
| `BKP-01/02/03/14/18` | none |
| `BKP-04` | none (vaulted tier on every policy for File Sync shares) |
| `BKP-06/07/08/09/10/11` | none (soft delete always-on, immutability, MUA, GRS + CRR, alerts) |
| Jobs (last 7 days) | `Backup/Completed` only |
| Alert rule test | a forced failure (temporarily set the firewall to Deny without trusted services on a test share, run an on-demand backup) produces an alert e-mail; revert |

## 4. Restore runbook (test it once during the engagement, keep it)

| Scenario | Path | Notes |
|---|---|---|
| A user deleted a file/folder yesterday | Vault > Backup items > share > Restore > **Item level** > original location or alternate folder | up to 99 files/folders per restore; File Sync propagates the restore to servers |
| Whole share corrupted (ransomware on a server endpoint) | Stop the affected server endpoint's sync (remove endpoint or stop the agent), then **Full share restore** from the last clean snapshot to the original location, then re-add the endpoint with initial download policy Namespace-then-modified | The vault tier's immutable copy is the fallback if snapshots were deleted |
| Storage account deleted / region unavailable | **Cross Region Restore** from the vaulted copy into a storage account in the paired region, then point a new cloud endpoint at it | requires GRS + CRR enabled before the incident |
| Self-service previous versions on the server | `Enable-StorageSyncSelfServiceRestore` on tiered volumes (VSS) | complements, does not replace, Azure Backup |

Record for the test: item restored, time to restore, who executed, evidence (job id,
screenshot), and add it to the customer's DR documentation.

## 5. Extending to "all data stored in Azure"

The same vault protects Azure VMs (including the Azure-hosted file servers, with the caveat
that VM backup of a tiered server endpoint is not a data backup), SQL in VMs and SAP; blob
and managed-disk backups use a Data Protection (Backup) vault. The exporter already lists
Data Protection vaults (`BKP-17`) and non-file items (`BKP-19`) so the coverage conversation
can be extended without a second discovery.

## 6. Close-out

- [ ] Coverage table 100 % protected, first backups green, alerts tested.
- [ ] Vault hardened (soft delete always-on, immutability locked, MUA, GRS + CRR, locks).
- [ ] Restore test executed and documented.
- [ ] Design table (section 1) and the PowerShell in section 2 handed over as the customer's
      runbook; policy names reference the retention schedule.
- [ ] Re-export + re-assess stored with the report (before / after).
