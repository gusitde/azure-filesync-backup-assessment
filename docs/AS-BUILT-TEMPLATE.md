# As-built document

> **Status: TEMPLATE, not yet completed.** No environment has been deployed, so no evidence has
> been captured. Fill this in as `AS-BUILT-<environment>-<date>.md` immediately after running
> `deploy/Deploy-AfsEnvironment.ps1`, while the deployment output is still on screen.
>
> Each section names the exact command whose output is the evidence, and the exact portal view
> to screenshot. Capture both: the command output proves the configuration, the screenshot makes
> it reviewable by someone who will not run commands.

**Environment:** _______________   **Subscription:** _______________
**Deployed by:** _______________   **Date:** _______________
**Parameter file used:** attach a copy, with any secrets removed
**Deployment log:** attach the full console output of the deployment run

---

## How to capture the evidence

```powershell
# capture everything the run printed, so the as-built is written from a record rather than memory
.\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json *>&1 |
    Tee-Object -FilePath ..\as-built-deploy-log.txt
```

Screenshots: use the Azure portal, full browser window, with the resource name visible in the
breadcrumb. Name them `NN-<feature>.png` so they sort in build order.

---

## 1. Resource group and tagging

**What was deployed.** A single resource group holding every object, tagged so it can be found
and, when it is a demo, so it can be identified as disposable.

**How it was built.** From `resourceGroup`, `location` and `tags` in the parameter file.

| Field | Value |
|---|---|
| Resource group | |
| Region | |
| Tags | |

```powershell
az group show -n <rg> --query "{name:name, location:location, tags:tags}" -o json
```

**Screenshot `01-resource-group.png`:** Resource group > Overview, showing the resource list.

---

## 2. Storage account - the security baseline

**What was deployed.** A StorageV2 account holding the Azure file shares, built to a hardened
baseline rather than defaults.

**Why each setting.** TLS 1.2 is the minimum accepted; HTTPS is enforced; public blob access is
off because these are SMB file shares and blob anonymous access has no purpose here; large file
shares are enabled because it cannot be turned on later without recreating the account; shared
key access stays on because Azure Backup for Azure Files requires it.

**Redundancy is a one-way decision** - changing it later is a data migration, not a setting.

| Field | Value |
|---|---|
| Account name | |
| Redundancy (SKU) | |
| Minimum TLS version | |
| HTTPS only | |
| Public blob access | |
| Large file shares | |
| Shared key access | |

```powershell
az storage account show -n <account> -g <rg> --query "{sku:sku.name, tls:minimumTlsVersion, https:enableHttpsTrafficOnly, blobPublic:allowBlobPublicAccess, largeShares:largeFileSharesState, sharedKey:allowSharedKeyAccess}" -o json
```

**Screenshot `02-storage-configuration.png`:** Storage account > Settings > Configuration.

---

## 3. File shares and soft delete

**What was deployed.** One Azure file share per entry in `shares`, each with its quota, and
share soft delete set to 14 days.

**Why soft delete.** It is the recovery path for a deleted share itself, which backup does not
cover - a deleted share takes its snapshots with it.

| Share | Quota (GiB) | Purpose |
|---|---|---|
| | | |

```powershell
az storage share-rm list --storage-account <account> -g <rg> --query "[].{name:name, quota:properties.shareQuota}" -o table
az storage account file-service-properties show --account-name <account> -g <rg> --query shareDeleteRetentionPolicy -o json
```

**Screenshot `03-file-shares.png`:** Storage account > Data storage > File shares.

---

## 4. Virtual network and the private endpoint subnet

**What was deployed.** Either a new virtual network with a dedicated private endpoint subnet, or
private endpoints placed into an existing network.

| Field | Value |
|---|---|
| Virtual network | |
| Address space | |
| Private endpoint subnet | |
| Subnet prefix | |

```powershell
az network vnet show -n <vnet> -g <rg> --query "{name:name, prefixes:addressSpace.addressPrefixes, subnets:subnets[].{name:name,prefix:addressPrefix}}" -o json
```

**Screenshot `04-vnet-subnets.png`:** Virtual network > Settings > Subnets.

---

## 5. Private endpoints - Azure Files and Azure File Sync

**What was deployed.** A private endpoint on the storage account (sub-resource `file`) and, where
enabled, one on the Storage Sync Service (sub-resource `Afs`).

**Note on the File Sync endpoint.** One `Afs` private endpoint publishes **four** host names, and
the role token sits inside the first label:

```
<sss>management.<region>.afs.azure.net
<sss>syncp.<region>.afs.azure.net
<sss>syncs.<region>.afs.azure.net
<sss>monitoring.<region>.afs.azure.net
```

Record all four addresses; they are what on-premises DNS and IPAM must know about.

**What stays on the Microsoft network.** The Storage Sync Service to storage account leg does not
traverse the customer network and cannot be routed over ExpressRoute. Azure Backup traffic for
Azure Files is likewise Azure-internal. Say so in this document, because "everything is private"
is the claim people remember and only part of it is achievable.

| Endpoint | Sub-resource | Private IP(s) | Connection state |
|---|---|---|---|
| | file | | |
| | Afs | | |

```powershell
az network private-endpoint list -g <rg> --query "[].{name:name, group:privateLinkServiceConnections[0].groupIds[0], ip:customDnsConfigs[0].ipAddresses[0], state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o table
```

**Screenshot `05-private-endpoints.png`:** each private endpoint > Overview, showing the private
IP and Approved state.

---

## 6. Private DNS zones and records

**What was deployed.** The `privatelink` zones, linked to the virtual network, with a DNS zone
group on each private endpoint so the A records are created and maintained automatically.

**Why a zone group rather than manual records.** A hand-written A record is the drift that breaks
the moment an endpoint IP changes.

| Zone | VNet link | A records |
|---|---|---|
| privatelink.file.core.windows.net | | |
| privatelink.afs.azure.net | | |

```powershell
az network private-dns zone list -g <rg> --query "[].{zone:name, records:numberOfRecordSets, links:numberOfVirtualNetworkLinks}" -o table
az network private-dns record-set a list -g <rg> -z privatelink.file.core.windows.net --query "[].{name:name, ip:aRecords[0].ipv4Address}" -o table
```

**Screenshot `06-private-dns.png`:** Private DNS zone > Overview, showing the record set.

---

## 7. Azure DNS Private Resolver - the bridge from on-premises DNS

**What was deployed.** A DNS Private Resolver with an inbound endpoint in its own delegated
subnet. The inbound endpoint IP is the address on-premises DNS forwards to.

**Direction matters.** The **inbound** endpoint lets on-premises resolve Azure private names.
An **outbound** endpoint with a forwarding ruleset does the reverse. Most deployments need only
inbound.

| Field | Value |
|---|---|
| Resolver name | |
| Inbound subnet | |
| **Inbound endpoint IP** | |
| Outbound endpoint | |

```powershell
az dns-resolver inbound-endpoint show -g <rg> --dns-resolver-name <resolver> -n inbound-01 --query "ipConfigurations[0].privateIpAddress" -o tsv
```

**Screenshot `07-dns-resolver.png`:** DNS Private Resolver > Settings > Inbound endpoints.

**On-premises forwarders configured:** record the DNS product, who made the change, and when.
Forward the **public** zones - a forwarder on a `privatelink` zone is never consulted, because
the whole CNAME chain comes back in one answer.

| Zone forwarded | Target IP | Changed by | Date |
|---|---|---|---|
| file.core.windows.net | | | |
| afs.azure.net | | | |

**Proof it works** - run from an on-premises client, not from Azure:

```powershell
Resolve-DnsName <account>.file.core.windows.net
Test-NetConnection <account>.file.core.windows.net -Port 445
```

**Screenshot `08-onprem-resolution.png`:** the terminal output showing the private IP.

---

## 8. Azure File Sync

**What was deployed.** A Storage Sync Service, the sync group, and the cloud endpoint pointing at
the Azure file share.

| Field | Value |
|---|---|
| Storage Sync Service | |
| Sync group | |
| Cloud endpoint (share) | |
| Incoming traffic policy | |

**Registered servers and server endpoints** - completed manually on each file server:

| Server | Agent version | Local path | Cloud tiering | Volume free space policy |
|---|---|---|---|---|

```powershell
az resource show -g <rg> -n <sss> --resource-type Microsoft.StorageSync/storageSyncServices --query "{name:name, policy:properties.incomingTrafficPolicy}" -o json
```

**Screenshot `09-file-sync.png`:** Storage Sync Service > Sync groups, showing endpoints healthy.

---

## 9. Azure Backup

**What was deployed.** A Recovery Services vault, its policy, and protection on each share.

**Two settings that had to be right before anything was protected**, because they cannot be
changed afterwards: storage redundancy and cross-region restore.

**Which tier, and why it matters for restore.** Item-level restore of a single file comes from
the **snapshot tier**. The vault-standard tier supports full-share restore only - file-level
recovery is not available from it. If the requirement includes restoring one file, the snapshot
tier is what satisfies it.

| Field | Value |
|---|---|
| Vault name | |
| Storage redundancy | |
| Cross-region restore | |
| Soft delete | |
| Policy name | |
| Daily retention | |
| Shares protected | |

```powershell
# note the [0] index - backup-properties returns an array, and the un-indexed query
# returns nothing at all while still exiting 0
az backup vault backup-properties show -n <vault> -g <rg> --query "[0].properties.[storageModelType, crossRegionRestoreFlag]" -o tsv
az backup item list -v <vault> -g <rg> --query "[].{share:properties.friendlyName, state:properties.protectionState}" -o table
```

**Screenshot `10-backup-vault.png`:** Recovery Services vault > Properties, showing redundancy.
**Screenshot `11-backup-items.png`:** vault > Backup items, showing each share protected.

**Restore test performed** - a backup that has never been restored is not protection:

| Step | Result | Evidence |
|---|---|---|
| Test file created on the server | | |
| Synced up to the Azure share | | |
| On-demand backup taken | | |
| File deleted on the server, deletion synced | | |
| File restored with item-level restore | | |
| **File synced back down to the server** | | |

**Screenshot `12-restore-job.png`:** vault > Backup jobs, showing the completed restore.

---

## 10. Identity

**What was deployed.** AD DS domain join of the storage account, if enabled.

| Field | Value |
|---|---|
| Directory service | |
| Domain | |
| Identity object type | |
| OU distinguished name | |
| Password rotation owner | |
| Next rotation due | |

```powershell
az storage account show -n <account> -g <rg> --query azureFilesIdentityBasedAuthentication -o json
```

**Screenshot `13-identity.png`:** Storage account > File shares > Active Directory, showing
configured.

---

## 11. What was deliberately not done

List anything left open, so the next person does not assume it was missed:

| Item | Why | Owner | Target date |
|---|---|---|---|
| | | | |

---

## 12. Sign-off

| Role | Name | Date |
|---|---|---|
| Built by | | |
| Verified by (not the builder) | | |
| Accepted by | | |
