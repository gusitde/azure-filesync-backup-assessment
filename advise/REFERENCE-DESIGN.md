# Reference design - Azure File Sync and Azure Backup for a VMware-to-Azure migration

**Scope.** Windows file servers and general server workloads moving from on-premises VMware
to Azure via Azure Migrate, connected over ExpressRoute private peering, with Azure File Sync
for the file estate and Azure Backup for everything that lands. Written for a regulated enterprise
profile: AD DS forest, Infoblox for DNS and IPAM, records-retention obligations, and a
security review that will ask about public exposure.

**How to read it.** Every design point is a numbered **decision** with a stated **default**,
the **reason**, and the **reversal cost** - what it costs to change your mind later. Take the
default unless the customer gives you a reason not to, and record the reason when they do.
Decisions marked **ONE WAY** are expensive or impossible to reverse; close those in the
session, not by email.

---

## 0. The shape of the thing

```
On-premises (VMware)                    Azure
+---------------------+                 +-----------------------------------+
| vCenter             |                 | Hub VNet                          |
|  file servers       |  ExpressRoute   |  ER gateway, DNS Private Resolver  |
|  app servers        |<--------------->|  (Infoblox forwards privatelink.*) |
|  Azure Migrate      |  private peering|                                    |
|   appliance         |                 | Spoke VNet                         |
+---------------------+                 |  migrated VMs (IaaS)               |
                                        |  private endpoints: file, Afs      |
                                        |                                    |
                                        | Storage account (SMB shares)       |
                                        | Storage Sync Service               |
                                        | Recovery Services vault            |
                                        +-----------------------------------+
```

Three protection surfaces, not one. They are commonly conflated and they have different
designs, different traffic paths and different failure modes:

| Surface | What it protects | Product | Traffic path |
|---|---|---|---|
| **Migrated VM** | The server: OS, apps, local data | Azure Backup for Azure VMs | Azure-internal; no customer network path |
| **Azure file share** | The authoritative copy of file data | Azure Backup for Azure Files | Azure-internal; no customer network path |
| **File Sync server** | Nothing - it is a *cache* | none, by design | SMB and sync over the private path |

The third row is the one people get wrong. See decision **D-14**.

---

## 1. Landing the workloads

### D-01 - Migration tool
**Default: Azure Migrate agentless replication from VMware.** ONE WAY per wave.

Agentless avoids touching guest operating systems, which matters when the organization's server
team does not own every application. Agent-based replication is the fallback for servers
agentless cannot handle (unsupported VMware version, disks above the agentless limit, or a
server that must be replicated from inside the guest).

*Reversal cost:* low before cutover, high after. You can re-replicate a server, but you
cannot un-cut-over one without a rollback plan.

### D-02 - Private path for replication
**Default: replication over ExpressRoute using Private Link.**

The Azure Migrate project, its Key Vault, its usage storage account, the Recovery Services
vault and the **cache/replication storage account** each get a private endpoint, and the
appliance must resolve the corresponding `privatelink` zones. The cache account takes a
**blob** private endpoint; Microsoft documents blob for the cache account, and a queue
endpoint is not part of that guidance.

Codex: `blueprint-azure-migrate-private-link-landing`,
`playbook-azure-migrate-private-link-cache-storage`.

*Reversal cost:* medium. Moving from public to private replication mid-wave means
re-registering the appliance and re-resolving DNS.

### D-03 - VM generation and security type
**Default: land migrated VMs as Trusted Launch where the guest supports it.**

This decision reaches into backup and is routinely missed: **Trusted Launch VMs are protected
with the Enhanced backup policy.** If your standard policy is Standard subtype, a Trusted
Launch VM will not attach to it through the portal path, and you will discover it during the
first protection run of the wave rather than during design.

*Reversal cost:* high. Changing a VM's security type after migration is a rebuild, and
**a VM protected with an Enhanced policy cannot be moved back to a Standard policy.**

---

## 2. What happens to each file server

### D-04 - File server disposition - ONE WAY
**Default: decide per server, from this tree, before the wave is planned.**

```
Does the data need to stay on a Windows server after migration?
|
+-- No, clients can mount an Azure file share directly
|     -> DISPOSITION C: retire the server, go direct to Azure Files
|        Requires: AD DS identity-based auth, private endpoint reachable from clients,
|        DFS-N or a namespace change so UNC paths keep working.
|        Backup: Azure Backup for Azure Files only.
|
+-- Yes, but only as a local cache for performance or legacy access
|     -> DISPOSITION B: migrate the VM, then attach Azure File Sync
|        The Azure file share becomes authoritative; the server keeps a tiered cache.
|        Backup: Azure Backup for Azure Files (the share). NOT the server. See D-14.
|
+-- Yes, the server itself matters (local apps, drivers, non-SMB workloads on the same box)
      -> DISPOSITION A: lift and shift the VM, no File Sync
         Backup: Azure Backup for Azure VMs.
```

Most enterprise file servers land on **B**. Disposition B is what "set up Azure File Sync for our
migrated VMs" actually means, and it is the only one of the three where both backup products
are in play at once.

*Reversal cost:* B to C is a namespace change and a server decommission - moderate.
A to B is easy. C back to A or B means rebuilding a server and re-seeding data - high.

### D-05 - Seeding order for disposition B
**Default: migrate the VM first, then attach File Sync to the already-landed server.**

Attaching File Sync on-premises before migration and letting the cloud endpoint seed over
ExpressRoute is the alternative, and it is better when the initial upload is large and the
migration window is short - the bytes move before cutover instead of during it. Choose it
deliberately, not by accident, and size the ExpressRoute for it (D-09).

*Reversal cost:* low.

---

## 3. The file estate

### D-06 - Storage account shape
**Default: one StorageV2 account per data class per region, ZRS, large file shares enabled,
`allowBlobPublicAccess` false, `publicNetworkAccess` Disabled, TLS 1.2 minimum,
`defaultAction: Deny` with `bypass: AzureServices`.**

The trusted-services bypass is how the Storage Sync Service and Azure Backup reach a
firewalled account. **Azure File Sync is on the trusted-services list; it is not one of the
resource types supported by storage resource instance rules**, so do not attempt to scope it
with a resource instance rule - configure the bypass.

Codex: `blueprint-azure-files-secure-storage-account`,
`playbook-deploy-secure-storage-account-and-share`.

*Reversal cost:* low for the network settings, **high for redundancy** - see D-07.

### D-07 - Redundancy - ONE WAY
**Default: ZRS for shares whose recovery point is the backup, GRS where the organization's DR plan
requires a second region.**

Redundancy is chosen when the account is created and changing it later is a data movement,
not a setting. Decide it against the records-retention schedule, not by habit.

*Reversal cost:* high. Account-level redundancy changes are migrations.

### D-08 - Private endpoints
**Default: a `file` private endpoint on each storage account and an `Afs` private endpoint on
the Storage Sync Service, both resolved through the hub.**

The Storage Sync Service private endpoint publishes **four** names, and the role token is
inside the first label, not a separate label:

```
<sss>management.<region>.afs.azure.net
<sss>syncp.<region>.afs.azure.net
<sss>syncs.<region>.afs.azure.net
<sss>monitoring.<region>.afs.azure.net
```

Zones: `privatelink.file.core.windows.net` and `privatelink.afs.azure.net`.

**The Storage Sync Service to storage account leg stays inside Microsoft** on the
trusted-services path. You cannot route it over the ExpressRoute and you do not need to.

Codex: `blueprint-azure-files-private-endpoint`, `blueprint-azure-file-sync-private-path`.

### D-09 - ExpressRoute sizing for the initial upload
**Default: size the circuit for the seed, not the steady state, and schedule the seed.**

The first File Sync upload moves the entire dataset across the ExpressRoute. Steady-state
sync is small; the seed is not. Ask for the total dataset size in the interview and do the
arithmetic in front of the customer.

*Reversal cost:* none technically, but a saturated circuit during business hours is the most
visible failure this project can produce.

### D-10 - Name resolution
**Default: Azure DNS Private Resolver inbound endpoint in the hub; Infoblox conditional
forwarders for the `privatelink.*` zones only.**

Forward the specific `privatelink` zones, never the whole of `core.windows.net` - forwarding
the parent zone sends public storage traffic through the resolver for no reason and breaks
name resolution for accounts that have no private endpoint.

Codex: `blueprint-azure-dns-for-private-endpoints`,
`playbook-deploy-dns-private-resolver-and-forwarders`.

### D-11 - Identity
**Default: AD DS identity-based authentication on the storage account, share-level RBAC for
coarse access, NTFS ACLs preserved from the source for fine-grained access.**

Share-level RBAC and NTFS ACLs both apply; the effective permission is the intersection. The
organization's existing NTFS ACLs are the fine-grained model and must survive the copy - see D-12.

Codex: `playbook-enable-identity-based-auth-ad-ds`.

### D-12 - Data movement fidelity
**Default: RoboCopy with full fidelity flags for the copy, and a verification pass that
compares ACLs, timestamps and counts before cutover.**

Losing NTFS ACLs or timestamps in the copy is the defect that gets discovered weeks later by
a department that cannot open its own files, and by then the source may be gone.

*Reversal cost:* very high once the source is decommissioned. Do not decommission a source
until the fidelity check has passed and been signed off.

---

## 4. Protecting what landed

### D-13 - Azure VM backup policy
**Default: Enhanced policy, daily, instant restore retention 7 days, retention aligned to the
organization's records schedule rather than the product defaults.**

Verified product behaviour to design against:

| Property | Value |
|---|---|
| Policy subtypes | Standard, Enhanced |
| Enhanced backup frequency | Hourly (interval 4, 6, 8, 12 or 24 hours), Daily or Weekly |
| Enhanced hourly RPO | minimum 4 hours, maximum 24 hours |
| Instant restore (snapshot) retention | 1 to 30 days, default 7 |
| Max snapshot retention at 4-hour frequency | 17 days |
| Max snapshot retention at 6-hour frequency | 22 days |
| Portal default retention | daily 180 days, weekly 12 weeks, monthly 60 months, yearly 10 years |
| Trusted Launch, Ultra Disk, Premium SSD v2 | Enhanced policy |
| Enhanced snapshot resiliency | zone-redundant |

**ONE WAY:** a VM protected with an Enhanced policy cannot be moved to a Standard policy.
Standard to Enhanced migration exists but is a separate, preview-gated operation. Choose
Enhanced for the migrated estate unless there is a stated reason not to; it is the only
subtype that covers the disk types and VM security types the migration will produce.

*Selective disk backup* excludes non-critical data disks from the backup to save cost. Use it
deliberately - an excluded disk is an unprotected disk, and nothing in the restore experience
will remind you.

### D-14 - What NOT to back up - ONE WAY in consequence
**Default: never point a file-level backup product at a File Sync server endpoint.**

A server endpoint's tiered files are reparse points. A backup agent that walks the volume
recalls every tiered file to read it. The result is a full recall of the dataset: the cache
volume fills, cloud tiering fights the backup, egress is charged, and the server enters low
disk space mode. **Back up the Azure file share, not the cache.**

For a disposition B server, that means:
- Azure Backup for Azure Files protects the **share** (the authoritative data).
- Azure VM backup protects the **server** for rebuild purposes - and the server endpoint
  volume should be excluded from it, or the server should be rebuilt from the playbook
  rather than restored.

### D-15 - Azure Files backup
**Default: Azure Backup for Azure Files, snapshot tier for operational recovery plus vault
tier where an offsite, immutable copy is required.**

Backup traffic for Azure Files is **Azure-internal**. There is no private endpoint for it and
nothing to route over the ExpressRoute. This answers the standing question directly: the
ExpressRoute requirement applies to the File Sync and SMB paths, not to backup.

Codex: `blueprint-azure-files-backup-protection`,
`playbook-enable-azure-backup-for-file-shares`.

### D-16 - Vault posture - ONE WAY
**Default: one Recovery Services vault per region; soft delete on, immutability on,
multi-user authorization with a Resource Guard in a separate subscription, GRS with
cross-region restore enabled before the first item is protected.**

**Redundancy and cross-region restore must be set before anything is protected.** Once a
vault holds a protected item, these become difficult or impossible to change.

### D-17 - Vault private endpoint
**Default: none, unless the organization later protects SQL Server or SAP HANA in Azure VMs, uses
the MARS agent, or uses DPM/MABS.**

Vault private endpoints serve those workloads. Azure VM backup and restore of disks needs no
private endpoint. The exception worth recording: **file recovery from an Azure VM backup, in
a vault that has private endpoints, is restricted to virtual networks containing a vault
private endpoint** - so if the organization wants item-level recovery from VM backups over the
ExpressRoute, that is the reason to add one.

### D-18 - When backup is enabled
**Default: at cutover, as a gate on the wave, not afterwards.**

A migrated VM with no backup is the highest-consequence gap in a migration, and it is
invisible - the VM works perfectly. Make "protected and first backup succeeded" an exit
criterion for every wave, and verify it with a query rather than a checkbox.

---

## 5. What the defaults cost to reverse

| Decision | Reversibility |
|---|---|
| D-03 VM security type, D-13 Enhanced policy | **One way.** Rebuild or unsupported. |
| D-07 Storage redundancy | **One way in practice.** A data migration. |
| D-16 Vault redundancy and cross-region restore | **One way.** Must precede first protection. |
| D-04 File server disposition | Expensive. Namespace and decommission work. |
| D-12 Copy fidelity | **Irreversible** once the source is gone. |
| D-06 Network settings, D-10 DNS, D-15 backup policy detail | Cheap. Change freely. |

---

## 6. What this design does not decide

These are out of scope here and need their own decisions if the organization raises them: data
classification and whether any share holds criminal-justice data that constrains where it may
land; customer-managed keys; Defender for Storage response ownership; cost chargeback to
departments; and the Terraform-versus-Bicep question if the organization has an infrastructure-as-code
standard. Each is a named gap rather than an omission.

---

*Product behaviour verified against Microsoft Learn on 2026-09-03: Azure VM backup overview,
Enhanced policy, Azure Backup private endpoints, Azure File Sync networking endpoints, and
the storage trusted-services list. Re-verify before quoting numbers to a customer more than a
quarter from now.*
