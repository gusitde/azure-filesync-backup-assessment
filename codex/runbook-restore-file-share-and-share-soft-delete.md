---
slug: runbook-restore-file-share-and-share-soft-delete
doc_type: runbook
kind: restore-file-share-and-share-soft-delete
category: infra
title: Respond to deleted or corrupted data on an Azure file share behind File Sync
summary: Incident classes for data loss on synced shares: user deletion, ransomware on a server endpoint, share deleted, account or region lost, restore failing on free space - each mapped to the right recovery source and the File Sync interaction.
when_to_use: Files or a whole share are missing or encrypted on an Azure file share or on the File Sync servers, or a restore job fails.
applies_to: [ops, devstation]
tags: [azure-backup, azure-files, restore, soft-delete, ransomware, azure-file-sync, incident, contoso]
persona_run: eng-sysops
ticket_kind: bug-known
status: published
version: 1
execution: advisory
last_verified: 2026-09-03T05:00 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

Loud: a department reports a folder gone or files renamed with a ransomware extension on the
server share; the share disappeared from the storage account; a restore job failed with a
free-space error. Silent: a file was overwritten days ago and only now noticed; a share was
soft-deleted and the retention clock is running. Applies to any share protected per
[[blueprint-azure-files-backup-protection]]; without that protection only share soft delete
and VSS previous versions remain.

## Reuse before reinvent (GR11)

```yaml
- primitive: Azure Backup item-level and full-share restore (snapshot and vault tiers)
  path: docs/PLAYBOOK-azure-backup-for-azure-files.md
  why: restores from Backup notify the Storage Sync Service so the servers pick up the restored
       paths through change detection; copying files back by hand on a server re-uploads them
       and can conflict with tiered versions
- primitive: share soft delete (undelete)
  path: codex/blueprint-azure-files-secure-storage-account.md
  why: a deleted share and its snapshots are recoverable inside the retention window with one
       operation; recreating the share from backup takes hours and loses the snapshot chain
- primitive: self-service restore (VSS previous versions) on File Sync volumes
  path: Get-AfsServerDiagnostics.ps1
  why: the cheapest class - users recover their own files without a ticket - when it was enabled
       per volume beforehand
```

## Response

1. **A user deleted or overwrote files recently - self-service class.** Cause: normal user
   error on a server endpoint. Recovery: on the server, right-click > Previous Versions (VSS
   self-service restore must have been enabled on that volume with
   `Enable-StorageSyncSelfServiceRestore`); otherwise class 2. Verify the file reappears on
   the share within minutes via sync.
2. **Files or folders lost, snapshots exist - item-level class.** Cause: deletion or corruption
   propagated through sync. Recovery: Vault > Protected items > share > **File Recovery**
   (item-level, up to 99 items per job) from the newest clean snapshot recovery point, to the
   original location (conflict: Overwrite) or to an alternate folder; Azure Backup triggers
   File Sync change detection for the restored paths, so the servers receive the restored
   versions without waiting for the 24-hour enumeration. Item names longer than 2 KB or with
   trailing dots cannot be restored from snapshots. (Real case: Microsoft's restore article
   notes the trailing-dot and length limits.)
3. **Ransomware on a server endpoint - full-share class.** Cause: a server endpoint encrypted
   files and sync uploaded them. Recovery: stop the spread - stop the `FileSyncSvc` (Storage
   Sync Agent) service on the affected server, or take that server off the network, so it
   cannot upload; there is no pause/suspend operation for a server endpoint, and do NOT delete
   the server endpoint as a containment step (Microsoft: "Removing a server endpoint is a
   destructive operation, and tiered files within the server endpoint won't be 'reconnected'
   to their locations on the Azure file share after the server endpoint is recreated", and
   tiered files outside the endpoint namespace "might be permanently lost" - tiered files can
   exist even if cloud tiering was never enabled); identify the last clean recovery point from
   the snapshot chain; **full share restore** to the original location (Overwrite) from the
   snapshot, or, if snapshots were tampered with or deleted, from the **vault tier** to an
   alternate location (a vault-tier-only recovery point can only go to an alternate location,
   because an original-location restore requires a Snapshot or Snapshot-and-Vault-tier point;
   the target share needs free space of at least 120 % of the data being restored - Azure
   Backup requires at least 20 percent more free space than the size of the source data to
   stage the temporary `MABRestoreScratchFolder`, and the job fails during pre-validation,
   before any data transfer, if that space is missing); re-add the server endpoint with initial
   download policy *Namespace then modified files* after the server is rebuilt - if the
   endpoint was nevertheless removed, the recreate on that path fails with 0x80c80077 until
   orphaned tiered-file cleanup finishes (Telemetry Event ID 6662 = started, 6661 = complete).
   Immutability and soft delete on the vault are what guarantee the vault copy survived.
4. **The share itself was deleted - soft-delete class.** Cause: accidental or malicious share
   deletion. Diagnose: `az storage share-rm list --include-deleted` shows the share with
   `remainingRetentionDays`. Recovery: **Undelete** the share (portal or
   `az storage share-rm restore`) inside the retention window; its snapshots come back with
   it; File Sync cloud endpoint resumes. Azure Backup's snapshot leases also block a one-click
   deletion while items are protected.
5. **Storage account deleted or region unavailable - cross-region class.** Cause: account
   deletion beyond soft delete, or a regional outage. Recovery: with a GRS vault and Cross
   Region Restore enabled, restore the vaulted copy into a storage account in the paired region
   (alternate location), create a NEW sync group whose cloud endpoint is the restored share - a
   sync group holds exactly one cloud endpoint and a share can be the cloud endpoint of only
   one sync group, so the existing sync group cannot be re-pointed at it (attempting to delete
   and recreate the share inside the same sync group yields ECS_E_SYNC_REPLICA_ROOT_CHANGED,
   0x80c8027e, whose documented fix is deleting all server endpoints, the cloud endpoint and
   the sync group and recreating them); then delete the old server endpoints and sync group
   and, before adding server endpoints on those same paths, wait for orphaned tiered-file
   cleanup (Telemetry Event ID 6662 = cleanup started, 6661 = complete and the path is
   reusable), otherwise endpoint creation fails with 0x80c80077. If 6661 never appears
   (event-log rollover), remove them manually with `Get-StorageSyncOrphanedTieredFiles` /
   `Remove-StorageSyncOrphanedTieredFiles` - the server endpoint must be removed first, or
   deleting an orphaned tiered file on the server deletes the full file in the Azure file
   share. If the account was merely deleted, restore it yourself first in the Azure portal
   (Storage accounts > Restore deleted account) within 14 days - possible only if the account
   was ARM-deployed, no account with the same name has been recreated since, and the resource
   group still exists (a deleted resource group cannot be recovered, only recreated); the
   caller needs Microsoft.Storage/storageAccounts/write, and a CMK account needs its key vault
   restored first. Recovery is best-effort and not guaranteed, so keep the cross-region restore
   path above ready until it succeeds. Note the account's private endpoints are deleted with
   the account and are NOT recreated by the restore - re-add them and revalidate DNS per
   [[playbook-add-file-private-endpoint-and-dns]] before handing the share back.
6. **Restore job fails - constraint class.** Cause: target share has less free space than
   120 % of the data being restored (vault tier), the recovery point's snapshot no longer
   exists (original-location restore needs a snapshot-tier point), the storage firewall blocks
   the Backup service (trusted services removed), or key access is disabled. Recovery: raise
   the quota or restore to a larger alternate share; pick a snapshot-tier point for
   original-location restores; restore `bypass AzureServices` and `allowSharedKeyAccess true`;
   retry and monitor the job under Vault > Jobs.
7. **Verify** after any class: the restored items open on the share and on the File Sync
   servers with the expected timestamps; a fresh on-demand backup completes; the incident
   record carries the recovery point, job id, duration and who approved an overwrite.

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: restore-file-share-and-share-soft-delete`
- **CR file:** `change-management/CR-<date>-restore-file-share-and-share-soft-delete.md`
- **Closure:** the data is back on the share AND visible on the servers, and a new backup completed - not merely a restore job marked Completed

## Gate rules

```json
[
  {"rule": "a restore is verified on the server side, not only in the vault", "severity": "error", "check": "test -s incident/restore-job-id.txt && diff <(sort incident/share-listing.txt) <(sort incident/server-listing.txt) prints nothing"},
  {"rule": "the affected server endpoint is isolated before a ransomware restore", "severity": "error", "check": "grep -Eq 'FileSyncSvc stopped|server isolated' incident/timeline.txt && grep -Eq 'full-share restore started' incident/timeline.txt"},
  {"rule": "every symptom class names the real incident it was distilled from", "severity": "warn", "check": "grep -c 'Real case' in this file is >= 1"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-files-backup-protection.md
  anchor: "Restore paths"
  why: the recovery sources this runbook chooses between
- path: codex/playbook-enable-azure-backup-for-file-shares.md
  anchor: "Restore-AzRecoveryServicesBackupItem"
  why: the tested command shape for item-level restores
- path: Assess-AzFileSyncExport.ps1
  anchor: "DATA-05"
  why: the finding that lists soft-deleted shares still inside the retention window
```

Microsoft Learn (read 2026-09-03): Restore Azure Files (full share, item level, alternate
location, scratch folder, limits); About Azure Files backup (lease, File Sync change
detection); Prevent accidental deletion of Azure file shares (soft delete, undelete); Azure
File Sync deployment guide (self-service restore through previous versions and VSS).
