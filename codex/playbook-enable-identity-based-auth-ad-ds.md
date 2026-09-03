---
slug: playbook-enable-identity-based-auth-ad-ds
doc_type: playbook
kind: enable-identity-based-auth-ad-ds
category: ops
title: Enable AD DS Kerberos authentication and share-level RBAC on an Azure Files account
summary: Join the storage account to Contoso Active Directory with AzFilesHybrid (AES-256), assign share-level RBAC to AD-synced groups, keep NTFS ACLs, set the SMB security profile to Kerberos, and prove a private-endpoint mount with an AD identity.
when_to_use: Users or apps mount shares directly and must use Contoso AD credentials instead of the account key, or SEC-07 fires on a share not fronted by File Sync.
applies_to: [ops, devstation]
tags: [azure-files, identity, ad-ds, kerberos, azfileshybrid, rbac, smb, contoso]
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

Some Contoso shares (scans, GIS) are mounted directly from workstations or application servers,
not through File Sync, and today they use the account key over NTLMv2. You decided to enforce
on-premises ACLs in the cloud: domain-join the storage account, give AD groups share-level
roles, remove NTLMv2. File Sync itself does not need this (servers enforce NTFS ACLs), so run
it per account where direct access exists. Note the July 2026 Windows change that makes AES-256
the AD DS default - RC4 configurations start failing mounts.

## Reuse before reinvent (GR11)

```yaml
- primitive: onprem/Join-AfsStorageAccountToAdDs.ps1
  path: onprem/Join-AfsStorageAccountToAdDs.ps1
  why: runs the whole procedure below idempotently, with the preflight that catches the two
       things that make the join fail confusingly (missing RSAT, and a -WhatIf that is not
       inert), a deterministic SamAccountName, and a reverse path in the right order
- primitive: AzFilesHybrid module v0.3.2 (Join-AzStorageAccount, Debug-AzStorageAccountAuth, Update-AzStorageAccountADObjectPassword, Move-OnPremSharePermissionsToAzureFileShare)
  path: codex/playbook-enable-identity-based-auth-ad-ds.md
  why: the module performs the offline domain join, sets the SPN/UPN and AES-256 correctly;
       the manual path in the Microsoft article is where the UPN/SPN mismatch (error 1396)
       originates
- primitive: share-level built-in roles (Storage File Data SMB Share Reader / Contributor / Elevated Contributor)
  path: codex/blueprint-azure-files-secure-storage-account.md
  why: share-level RBAC to synced AD groups plus NTFS ACLs is the Microsoft-recommended model;
       a default share-level permission for all authenticated users is the fallback when groups
       cannot be synced
```

## Procedure

1. **Preconditions.** A domain-joined Windows machine with PowerShell 5.1, .NET Framework
   4.7.2+, Az PowerShell with Az.Storage 8.1.0+, the Active Directory PowerShell module,
   AzFilesHybrid v0.3.2 unzipped; an AD account allowed to create computer objects in the target
   OU (`OU=AzureFiles,OU=Servers,DC=contoso,DC=local`, password expiry disabled); Reader on the
   resource group and Contributor on the storage account; AD groups synced to Entra ID
   (Microsoft Entra Connect / Cloud Sync) for share-level RBAC.
2. **Join the account** with `Join-AzStorageAccount` (computer account, AES-256 by default in
   v0.3.x, SamAccountName without `$`, max 15 chars for NetBIOS safety).
3. **Confirm**: `AzureFilesIdentityBasedAuth.DirectoryServiceOptions` = `AD`,
   `ActiveDirectoryProperties` populated; `Debug-AzStorageAccountAuth` passes.
4. **Share-level RBAC.** Assign `Storage File Data SMB Share Contributor` (or Reader /
   Elevated Contributor) to the AD-synced groups at the share scope; optionally migrate the
   root ACL with `Move-OnPremSharePermissionsToAzureFileShare`. If groups cannot be synced,
   set a default share-level permission instead.
5. **NTFS ACLs.** Mount once with the account key (or the SMB Admin role) from an admin
   machine and set NTFS permissions with `icacls` / Explorer as on any file server; File Sync
   shares already carry the ACLs from the servers.
6. **SMB profile.** Set `authenticationMethods Kerberos` and `kerberosTicketEncryption AES-256`
   on the file service once every key-based mount is gone (File Sync agents are unaffected).
7. **Verify** from a domain-joined workstation on Contoso network: `klist purge`, mount
   `\\<account>.file.core.windows.net\<share>` without credentials, `klist` shows a ticket for
   `cifs/<account>.file.core.windows.net` with AES-256; the mount used the private endpoint
   (`(Resolve-DnsName <account>.file.core.windows.net -Type A).IP4Address` - or
   `(Test-NetConnection <account>.file.core.windows.net -Port 445).RemoteAddress` - returns the
   private endpoint IP; `Get-SmbConnection` reports only
   ServerName/ShareName/UserName/Credential/Dialect/Encrypted/NumOpens and never an IP. On
   premium/SSD shares with SMB Multichannel enabled, `Get-SmbMultichannelConnection` also shows
   `ServerIpAddress`).
8. **Operations.** Set a reminder to rotate the AD object password with
   `Update-AzStorageAccountADObjectPassword` before any OU-enforced expiry; document the
   computer object and the Kerberos key name (`kerb1`) in the runbook.

## What the current module does, and what older instructions get wrong

Verified against AzFilesHybrid v0.3.2 source on 2026-09-03:

- **`-EncryptionType` no longer exists.** It was removed in v0.2.9; AES-256 is unconditional and
  the object is created with `KerberosEncryptionType = AES256`. Passing the parameter to a
  current module is a binding error. Any instruction that includes it predates 2024.
- **Never use positional parameters.** `-OrganizationalUnitDistinguishedName` and
  `-ADObjectNameOverride` are both declared at position 5 in the shipped source, so a positional
  argument binds to the wrong one. This is the origin of the "Cannot bind positional parameters"
  error people hit.
- **Always pass `-SamAccountName`.** Left to itself, for a storage account name longer than 15
  characters the module takes the first 10 characters and appends **five random ones** - so two
  runs create two differently named accounts and no idempotency check can ever match.
- **`-WhatIf` is not inert.** The cmdlet validates in its `begin` block, which runs regardless:
  Windows, domain-joined, and RSAT present. On a machine without RSAT it will try to install it,
  which needs elevation, and the error - "This cmdlet requires an elevated PowerShell session" -
  names the wrong problem entirely. Check the prerequisites yourself first.
- **Always give an OU.** Without one the object is created wherever the *running machine's*
  computer account lives, not at the domain root as some articles claim.
- **A successful join leaves the AD password on kerb2**, because the join ends by rotating.
  A verification that only checks kerb1 will report a healthy join as broken.
- **The reverse parameter is `-EnableActiveDirectoryDomainServicesForFile $false`.** The
  similarly named `-EnableAzureActiveDirectoryDomainServicesForFile` is a different feature
  (Entra Domain Services) and will not undo this join.
- **Capture the AD object before disabling AD DS.** `Get-AzStorageAccountADObject` resolves
  through the storage account's own properties, and disabling erases them.

## Steps

```yaml
vars:
  - name: sub
    describe: subscription id
    required: true
  - name: rg
    describe: resource group of the storage account
    required: true
  - name: account
    describe: storage account name
    required: true
  - name: sam
    describe: AD computer account name for the storage account (no trailing $, <= 15 chars)
    required: true
  - name: ou_dn
    describe: distinguished name of the target OU
    required: true
  - name: share
    describe: share name for the RBAC and mount test
    required: true
  - name: group_object_id
    describe: AD-synced group - Microsoft Entra object id of the group (groups have no UPN) that gets Contributor on the share
    required: true
steps:
  - name: preconditions
    run: powershell -Command "$PSVersionTable.PSVersion.ToString(); (Get-Module -ListAvailable Az.Storage | Sort Version -Descending | Select -First 1).Version.ToString(); (Get-Module -ListAvailable ActiveDirectory) -ne $null"
    verify: prints 5.1.x, a version >= 8.1.0 and True
  - name: join the account
    run: powershell -Command "Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force; .\CopyToPSPath.ps1; Import-Module AzFilesHybrid; Connect-AzAccount; Select-AzSubscription -SubscriptionId <sub>; Join-AzStorageAccount -ResourceGroupName <rg> -StorageAccountName <account> -SamAccountName <sam> -DomainAccountType ComputerAccount -OrganizationalUnitDistinguishedName '<ou_dn>'"
    verify: no error; Get-ADComputer <sam> exists in <ou_dn> with KerberosEncryptionType AES256
  - name: confirm and debug
    run: powershell -Command "$a=Get-AzStorageAccount -ResourceGroupName <rg> -Name <account>; $a.AzureFilesIdentityBasedAuth.DirectoryServiceOptions; $a.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties; Debug-AzStorageAccountAuth -StorageAccountName <account> -ResourceGroupName <rg> -Verbose"
    verify: prints AD, the domain properties, and the debug checks pass
  - name: share-level rbac
    run: az role assignment create --role "Storage File Data SMB Share Contributor" --assignee-object-id <group_object_id> --assignee-principal-type Group --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<account>/fileServices/default/fileshares/<share>"
    verify: az role assignment list --scope ".../fileshares/<share>" lists the group with the role (allow up to 30 minutes to propagate)
  - name: smb profile to kerberos
    run: az storage account file-service-properties update -g <rg> -n <account> --auth-methods "Kerberos" --kerb-ticket-encryption "AES-256"
    verify: az storage account file-service-properties show prints Kerberos and AES-256
  - name: confirm the effect (mount test)
    run: powershell -Command "klist purge; net use Z: \\<account>.file.core.windows.net\<share>; klist | Select-String cifs/<account>; (Resolve-DnsName <account>.file.core.windows.net -Type A).IP4Address"
    verify: mount succeeds without a prompt, klist shows a cifs ticket with AES-256, the address is the private endpoint IP
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: enable-identity-based-auth-ad-ds`
- **CR file:** `change-management/CR-<date>-enable-identity-based-auth-ad-ds.md`
- **Closure:** every `verify:` passes and no client mounts the share with the account key any more (Transactions metric by Authentication shows no AccountKey)

## Gate rules

```json
[
  {"rule": "AES-256 Kerberos, never RC4", "severity": "error", "check": "powershell -Command \"(Get-ADComputer <sam> -Properties KerberosEncryptionType).KerberosEncryptionType\" prints AES256"},
  {"rule": "the account reports AD as identity source", "severity": "error", "check": "az storage account show -g <rg> -n <account> --query azureFilesIdentityBasedAuthentication.directoryServiceOptions -o tsv prints AD"},
  {"rule": "share-level access is granted to groups, not users", "severity": "warn", "check": "az role assignment list --scope <share-scope> --query \"[?principalType=='User'] | length(@)\" prints 0"},
  {"rule": "key-based SMB mounts have stopped before NTLMv2 is removed", "severity": "error", "check": "az monitor metrics list --resource <account-id>/fileServices/default --metric Transactions --filter \"Authentication eq 'AccountKey'\" --interval P1D --query \"value[0].timeseries[0].data[-1].total\" prints 0 or null"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-files-secure-storage-account.md
  anchor: "Identity."
  why: the identity decision this playbook implements
- path: codex/runbook-storage-key-rotation-and-shared-key-incidents.md
  anchor: "Update-AzStorageAccountADObjectPassword"
  why: the AD object password rotation this feature adds to operations
- path: Assess-AzFileSyncExport.ps1
  anchor: "SEC-07"
  why: the finding that triggers this playbook
```

Microsoft Learn (read 2026-09-03): Enable AD DS authentication for Azure Files (AzFilesHybrid
v0.3.2, AES-256, July 2026 default change, UPN/SPN note); Assign share-level permissions
(built-in roles, default share permission, group-based access for non-synced users); SMB file
shares in Azure Files (authentication methods, Kerberos ticket encryption).
