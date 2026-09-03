# Deploy from a parameter file

One script, one parameter file. Everything the deployment creates comes from the parameter
file, so the same script serves a demo and a production build - only the values change.

```powershell
# 1. copy the sample and edit the values
Copy-Item parameters.sample.jsonc parameters.json

# 2. see exactly what would happen, without changing anything
.\Deploy-AfsEnvironment.ps1 -ParameterFile .\parameters.json -WhatIf

# 3. build it
.\Deploy-AfsEnvironment.ps1 -ParameterFile .\parameters.json

# 4. remove it again when you are done
.\Remove-AfsEnvironment.ps1 -ParameterFile .\parameters.json -WhatIf
.\Remove-AfsEnvironment.ps1 -ParameterFile .\parameters.json
```

## What it builds

| Section of the parameter file | What appears in Azure |
|---|---|
| `resourceGroup`, `location`, `tags` | The resource group everything lands in |
| `storageAccountName`, `storageSku` | A StorageV2 account: TLS 1.2 minimum, HTTPS only, no public blob access, large file shares on |
| `shares` | One Azure file share per entry, with its quota, plus 14-day share soft delete |
| `network` | A virtual network and a private endpoint subnet, or the existing ones you name |
| `privateLink` | Private endpoints for the storage account (`file`) and the Storage Sync Service (`Afs`), the `privatelink` DNS zones, and the zone groups that keep their records current |
| `dnsResolver` | An Azure DNS Private Resolver with a delegated inbound subnet - the address your on-premises DNS forwards to |
| `backup` | A Recovery Services vault with redundancy and cross-region restore set **before** anything is protected |
| `identity` | Left off by default; AD DS join is run separately from a domain-joined machine |

## Things the script does on purpose

**It is idempotent.** Every object is checked before it is created, so a re-run after a
failure continues from where it stopped rather than starting again or erroring.

**Every step is verified.** The run ends by printing a verification command for each object
it created. A step is finished when something reads it back, not when a command returned 0.

**It will not lock you out.** `disableStoragePublicAccess` and
`restrictFileSyncToVirtualNetworksOnly` default to `false`. Build first, confirm the private
endpoints resolve, then re-run with those set to `true`. Closing the public path before a
private endpoint resolves is the single most common way to break sync, so it is deliberately
not the default.

**Redundancy is set before protection.** Vault storage redundancy and cross-region restore
cannot be changed once the vault protects anything, so the script sets them immediately after
creating the vault and warns you if items already exist.

**Teardown refuses to be careless.** `Remove-AfsEnvironment.ps1` deletes the resource group,
which is the only reliable way to leave nothing behind - but it first inventories the group
and refuses if it finds resources the parameter file does not name. Pass `-Force` when that
is expected. It also disables backup protection with data deletion first, because a vault
will not delete while it protects anything.

## What is deliberately not automated

Three things need a human on a specific machine, and pretending otherwise would produce a
script that fails confusingly:

1. **The Azure File Sync agent.** Installing it on the file server, registering the server
   against the Storage Sync Service, and creating the server endpoint. Run from the server.
2. **On-premises DNS forwarders.** The script prints the resolver's inbound IP; pointing your
   DNS at it is a change in your DNS product, and forwarding should cover the `privatelink`
   zones only, never the parent `core.windows.net`.
3. **AD DS domain join of the storage account.** Uses the AzFilesHybrid module from a
   domain-joined machine with permission to create the identity object in the chosen OU.

## Running on Windows

Run from **PowerShell**, not Git Bash. Git Bash rewrites any argument that begins with `/`
into a Windows path, which corrupts Azure resource IDs - they all start with `/subscriptions/`.
If you must use Git Bash, `export MSYS_NO_PATHCONV=1` first. This is not theoretical: it was
found by running these commands both ways.

## Prerequisites

- Azure CLI. The script checks the version and tells you if it is missing.
- The `dns-resolver` extension, only when `dnsResolver.enabled` is true. The script installs
  it for you.
- Permission to create resources in the target subscription. Note that many tenants require
  the signing-in account to have authenticated with MFA before any write is allowed; a
  non-MFA session fails every create with `RequestDisallowedByAzure`.
