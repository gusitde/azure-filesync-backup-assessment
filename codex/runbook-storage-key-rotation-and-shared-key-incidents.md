---
slug: runbook-storage-key-rotation-and-shared-key-incidents
doc_type: runbook
kind: storage-key-rotation-and-shared-key-incidents
category: infra
title: Respond to a key leak, an expired key policy, or breakage after disabling shared key
summary: Incident classes around storage account keys on Azure Files accounts: suspected compromise, rotation reminder, shared key disabled breaking File Sync or Backup, SAS revocation, AD object password expiry - with the safe rotation order.
when_to_use: Defender alerts on key use, the key policy reports expired keys, or File Sync, Backup or a mount fails right after a key change.
applies_to: [ops, devstation]
tags: [storage-account, keys, shared-key, rotation, azure-file-sync, azure-backup, incident, contoso]
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

Loud: an operator regenerated key1 and every key-based mount or backup job failed;
`allowSharedKeyAccess` was set to false and Azure Backup jobs fail while File Sync cloud
endpoint operations error; Defender for Storage raised "access from a suspicious IP using the
account key". Silent: Azure Policy "Storage account keys should not be expired" reports
non-compliance for months; the AD computer object password for the storage account is about
to expire. Applies to every account in [[blueprint-azure-files-secure-storage-account]].

## Reuse before reinvent (GR11)

```yaml
- primitive: key rotation procedure (rotate key2, switch, rotate key1) and key expiration policy
  path: codex/playbook-harden-existing-storage-account.md
  why: the same order keeps clients online; a single regenerate of the key in use is the
       outage class below
- primitive: managed identity for Azure File Sync
  path: codex/blueprint-azure-file-sync-private-path.md
  why: removes File Sync's dependency on the account key; the only durable way to disable
       shared key on a File Sync account - Azure Backup for Azure Files still needs it
- primitive: Update-AzStorageAccountADObjectPassword (AzFilesHybrid)
  path: codex/playbook-enable-identity-based-auth-ad-ds.md
  why: the Kerberos key for the AD object is a storage key (kerb1/kerb2) with its own rotation
```

## Response

1. **Suspected key compromise - rotate now class.** Cause: a key appeared in a script, a
   ticket, or a Defender alert shows anomalous key-authenticated access. Recovery, in order:
   confirm which key clients use (storage resource logs - for `Account Key` auth the
   `identity/tokenHash` field is formatted `key1(<SHA-256 hash>)` or `key2(<SHA-256 hash>)`;
   the Transactions metric's `Authentication` dimension only distinguishes AccountKey / SAS /
   DelegationSas / OAuth / Anonymous, never key1 vs key2); regenerate the *other* key, repoint
   any legitimate client to it, regenerate the compromised key; account and service SAS tokens
   die with the key - regenerate them; File Sync (no managed identity) re-reads the key
   automatically, Azure Backup uses the trusted-services path, both continue; verify the next
   9102 (HResult 0) and the next backup job. Then set the key expiration policy. (Real case:
   Microsoft's key-management article requires rotating each key at least once before an
   expiration policy can be set on older accounts.)
2. **All key-based clients fail after one regenerate - wrong-order class.** Cause: the key in
   use was regenerated first. Diagnose: `Get-AzStorageAccount ... KeyCreationTime` shows the
   just-rotated key is the one clients referenced; mounts fail with access denied. Recovery:
   update the clients to the untouched key, then continue the rotation in the right order;
   move direct SMB clients to Kerberos ([[playbook-enable-identity-based-auth-ad-ds]]) so they
   stop depending on keys.
3. **Azure Backup jobs fail, cloud endpoint ops fail, after `allowSharedKeyAccess false` -
   shared-key-disabled class.** Cause: Azure Backup for Azure Files requires "Allow storage
   account key access"; File Sync without managed identity authenticates with the key. Diagnose:
   `az storage account show --query allowSharedKeyAccess` prints false; backup job error names
   key access; assessor BKP-18. Recovery: set `allowSharedKeyAccess true`; if the intent was
   least privilege, migrate File Sync to managed identity first and accept that Backup keeps
   the requirement until Microsoft lifts it. (Real case: the Azure Files backup support matrix
   states the requirement explicitly.)
4. **Direct mounts with the key fail after SMB hardening - NTLMv2 class.** Cause: `authenticationMethods`
   was set to `Kerberos` while some client still mounts with the account key (NTLMv2).
   Diagnose: `STATUS_ACCESS_DENIED` at session setup; Transactions by Authentication shows
   AccountKey traffic. Recovery: temporarily restore `NTLMv2;Kerberos` (`az storage account
   file-service-properties update -n <account> -g <rg> --auth-methods "NTLMv2;Kerberos"` - the
   CLI takes ONE ';'-delimited string, not space-separated values), move the client to an AD
   identity. Do NOT re-harden to Kerberos-only on any account with an Azure File Sync cloud
   endpoint: File Sync's storage-account prerequisites require the SMB security settings to
   allow NTLM v2 (plus SMB 3.1.1 and AES-128-GCM), and removing NTLMv2 disallows every
   account-key SMB mount. Kerberos-only is safe only on accounts with no File Sync cloud
   endpoint and no remaining key-based mounts.
5. **Users lose access to a domain-joined account - AD object password class.** Cause: the
   storage account's computer or service logon account password expired under OU policy, or
   RC4 was disabled on the domain before the object moved to AES-256. Diagnose: mount errors
   1396 / `KRB_AP_ERR_MODIFIED`; `Debug-AzStorageAccountAuth` fails on the password or
   encryption check. Recovery (preferred): `Update-AzStorageAccountAuthForAES256
   -ResourceGroupName <rg> -StorageAccountName <account>` (AzFilesHybrid; rotates the kerb key,
   sets `msDS-SupportedEncryptionTypes`, and resets the AD password in one operation). Manual
   order, if the module can't be used: first `Set-ADComputer -Identity <domain-object-identity>
   -Server <domain-name> -KerberosEncryptionType "AES256"` (use `Set-ADUser -Identity
   <domain-object-identity> -Server <domain-name> -KerberosEncryptionType "AES256"` when the
   object is a service logon account - and for user-type objects set the UPN to match the
   `cifs/<account>.file.core.windows.net` SPN first), THEN
   `Update-AzStorageAccountADObjectPassword -RotateToKerbKey kerb2` to refresh the
   domain-object password so the AES-256 authentication metadata is generated (rotate back to
   kerb1 next cycle), then `klist purge` on clients, disable password expiry on the OU.
6. **Policy non-compliance only - hygiene class.** Cause: no key expiration policy or keys
   older than the policy. Recovery: rotate per class 1 order, `az storage account update
   --key-exp-days 180`; the built-in policy `044985bb-afe1-42cd-8a36-9d5d42424537` turns
   compliant on the next evaluation.
7. **Verify** after any class: File Sync 9102 HResult 0 on every server, latest backup job
   Completed, a Kerberos mount succeeds, Transactions by Authentication shows no unexpected
   AccountKey traffic, `keyPolicy.keyExpirationPeriodInDays` is set.

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: storage-key-rotation-and-shared-key-incidents`
- **CR file:** `change-management/CR-<date>-storage-key-rotation-and-shared-key-incidents.md`
- **Closure:** both keys rotated in the safe order with sync and backup green afterwards, and the policy compliant - not merely the alert closed

## Gate rules

```json
[
  {"rule": "rotation never regenerates the key in use first", "severity": "error", "check": "az storage account show -n <account> -g <rg> --query \"[keyCreationTime.key1, keyCreationTime.key2]\" -o tsv prints two timestamps at least one rotation apart"},
  {"rule": "shared key stays enabled while Azure Backup protects shares", "severity": "error", "check": "az storage account show -n <account> -g <rg> --query allowSharedKeyAccess -o tsv prints true (or null) while az backup item list lists AzureFileShare items for the account"},
  {"rule": "sync and backup verified after rotation", "severity": "error", "check": "grep -q 'HResult: 0' incident/telemetry-9102.txt && az backup job list -v <vault> -g <rg> --status Completed --operation Backup --query \"length(@)\" prints >= 1"},
  {"rule": "every symptom class names the real incident it was distilled from", "severity": "warn", "check": "grep -c 'Real case' in this file is >= 2"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-files-secure-storage-account.md
  anchor: "Identity."
  why: why shared key stays on and what replaces it over time
- path: Assess-AzFileSyncExport.ps1
  anchor: "BKP-18"
  why: the finding for shared key disabled on an account with protected shares
- path: codex/playbook-enable-identity-based-auth-ad-ds.md
  anchor: "Update-AzStorageAccountADObjectPassword"
  why: the AD object rotation in class 5
```

Microsoft Learn (read 2026-09-03): Manage account access keys (rotation order, expiration
policy, SAS revocation, trusted access note); Support matrix for Azure Files backup (key
access requirement); Enable AD DS authentication (password expiry, AES-256, error 1396);
How to use managed identities with Azure File Sync.
