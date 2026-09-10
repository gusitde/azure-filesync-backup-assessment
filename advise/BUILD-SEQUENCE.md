# Build sequence - agreed design to running estate

Ordered, gated, and mapped to the codex playbooks that do the work. Each phase ends in a
**gate**: a command whose output is the evidence the phase is done. A phase that has not
passed its gate does not unblock the next one, regardless of the calendar.

Codex entries referenced here live in [../codex/](../codex/). Decisions (D-nn) are in
[REFERENCE-DESIGN.md](REFERENCE-DESIGN.md).

---

## Phase 0 - close the decisions (before anything is built)

| Step | Output | Blocks |
|---|---|---|
| 0.1 | Decision log: D-01 to D-18, value, default or changed, owner | everything |
| 0.2 | File server disposition table: every file server marked A, B or C (D-04) | phases 3, 4 |
| 0.3 | Dataset sizing and seed window arithmetic (D-09) | phase 4 |
| 0.4 | Retention values from the records schedule, not product defaults (E1) | phase 5 |
| 0.5 | Named owners: Infoblox change, retention schedule, wave rollback authority | phases 1, 3 |

**Gate 0.** The four one-way decisions (D-03, D-07, D-13, D-16) are recorded with an owner.
Nothing in phase 2 or later is reversible cheaply if these are still open.

---

## Phase 1 - landing zone: network and name resolution

| Step | Codex playbook | Gate |
|---|---|---|
| 1.1 Confirm hub-and-spoke and gateway transit | - | Spoke-to-hub route present; ER gateway reachable |
| 1.2 Deploy DNS Private Resolver inbound endpoint in the hub | `playbook-deploy-dns-private-resolver-and-forwarders` | Inbound endpoint has a private IP in the delegated subnet |
| 1.3 Create the `privatelink` zones and link them to the VNets | same | Zone list matches the design; one zone per name, centrally owned |
| 1.4 Infoblox conditional forwarders for the public zones (`file.core.windows.net`, `afs.azure.net`), not the `privatelink` ones | same | From on-premises, the public name of a test account resolves to its private IP through the resolver |
| 1.5 NSG and UDR review for the private endpoint subnets | `blueprint-azure-files-private-endpoint` | No rule blocks 445 or the endpoint subnet |

**Gate 1.** From an on-premises client, `<account>.file.core.windows.net` resolves through the
`privatelink` alias to a private IP. A forwarder on the `privatelink` zone instead of the
public one is the common defect here: it is created, looks right, and is never consulted,
because the whole CNAME chain comes back in one answer.

---

## Phase 2 - storage foundation

| Step | Codex playbook | Gate |
|---|---|---|
| 2.1 Create storage accounts per D-06 and D-07 | `playbook-deploy-secure-storage-account-and-share` | Redundancy correct at creation; it cannot be changed later |
| 2.2 Create the file shares, quotas, soft delete | same | Share soft delete enabled with the agreed retention |
| 2.3 `file` private endpoint plus DNS zone group | `playbook-add-file-private-endpoint-and-dns` | Name resolves to the private IP from a spoke VM and from on-premises |
| 2.4 Harden: firewall Deny, trusted-services bypass, TLS, SMB settings | `playbook-harden-existing-storage-account` | `publicNetworkAccess` Disabled; `bypass` contains AzureServices |
| 2.5 Domain-join the storage account, share-level RBAC | `playbook-enable-identity-based-auth-ad-ds` | A domain user mounts the share and sees the expected NTFS permissions |

**Gate 2.** A domain-joined test client mounts the share over the private path with correct
permissions, and the account refuses a connection from a public address.

Do not proceed to phase 4 until gate 2 passes. File Sync attached to an unreachable or
misconfigured account produces confusing failures that look like sync problems.

---

## Phase 3 - migrate the workloads

| Step | Codex playbook | Gate |
|---|---|---|
| 3.1 Private Link landing for Azure Migrate | `blueprint-azure-migrate-private-link-landing` | Project, Key Vault, vault and cache account all have private endpoints |
| 3.2 Cache/replication storage account with its `blob` private endpoint | `playbook-azure-migrate-private-link-cache-storage` | Appliance resolves the cache account privately |
| 3.3 Discovery and assessment | - | Every in-scope server appears with a readiness result |
| 3.4 Replication for wave N | - | Replication healthy; RPO within target |
| 3.5 Test migration for wave N | - | Test VM boots, application validated, test cleaned up |
| 3.6 Cutover for wave N | - | Production VM running; source powered off, not deleted |
| 3.7 **Protect the wave** (see phase 5) | `playbook-enable-azure-backup-for-file-shares` and VM backup | First backup succeeded for every VM in the wave |

**Gate 3, per wave.** No wave is complete until 3.7 returns clean for every VM in it. A
migrated VM with no backup works perfectly and is invisible until it is needed. Make this a
query, not a checkbox.

---

## Phase 4 - File Sync, for every disposition B server

| Step | Codex playbook | Gate |
|---|---|---|
| 4.1 Create the Storage Sync Service | - | Service exists in the target region |
| 4.2 `Afs` private endpoint plus the four FQDNs in DNS | `blueprint-azure-file-sync-private-path` | All four names resolve to private IPs |
| 4.3 Install and register the agent on the landed server | `playbook-enable-file-sync-private-endpoint-and-cutover` | Server registered; heartbeat current |
| 4.4 Sync group, cloud endpoint, server endpoint | same | Server endpoint health green |
| 4.5 Seed the data and let the first sync complete | same | Initial sync complete; item errors triaged, not ignored |
| 4.6 Verify copy fidelity: ACLs, timestamps, counts (D-12) | - | **Fidelity check signed off before any source is decommissioned** |
| 4.7 Enable cloud tiering with the agreed policy | same | Tiering active; free space within policy |
| 4.8 Set `incomingTrafficPolicy` to virtual networks only | `blueprint-azure-file-sync-private-path` | Public sync path closed |
| 4.9 Namespace cutover: DFS-N or client reconfiguration | - | Users reach the data by the agreed path |

**Gate 4.** Sync is healthy, tiering is working, fidelity is signed off, and the public sync
path is closed. Only now may a source server be decommissioned.

---

## Phase 5 - protection

| Step | Codex playbook | Gate |
|---|---|---|
| 5.1 Create the Recovery Services vault, **set redundancy and cross-region restore first** | `blueprint-azure-files-backup-protection` | GRS and CRR set before any item is protected |
| 5.2 Vault security: soft delete, immutability, MUA with a Resource Guard | same | MUA enforced; the Resource Guard is in a separate subscription |
| 5.3 VM backup policy per D-13 (Enhanced) | - | Policy subtype Enhanced; retention from the records schedule |
| 5.4 Protect every migrated VM | - | Every VM in every completed wave is protected |
| 5.5 Azure Files backup policy and protection for each share | `playbook-enable-azure-backup-for-file-shares` | Every share in the disposition table is protected |
| 5.6 Confirm no file-level backup agent targets a File Sync volume (D-14) | - | **Explicitly verified, not assumed** |
| 5.7 Restore test: one file, one share, one VM | `runbook-restore-file-share-and-share-soft-delete` | Evidence captured: what was restored, how long it took |

**Gate 5.** Every protected item has at least one successful recovery point, and one restore
of each type has been performed and evidenced. An untested restore path is not protection.

---

## Phase 6 - operations and handover

| Step | Gate |
|---|---|
| 6.1 Monitoring and alerts for sync health, agent expiry, backup failure, tiering | An induced failure produces an alert in the customer's alerting channel |
| 6.2 Named owner for each alert | Owner list signed |
| 6.3 Runbook handover: the four codex runbooks walked with the customer's operations staff | Staff have run one of them |
| 6.4 Decision log and as-built design handed over | Delivered |
| 6.5 Offer Door A: export and assess the estate you just built | Baseline assessment stored as the reference point |

**Gate 6.** Contoso staff have resolved one induced incident using the runbooks, without the
consultant driving.

---

## Rough shape in time

The calendar depends entirely on wave count and dataset size, but the dependencies do not:

```
Phase 0  decisions          | week 1
Phase 1  network and DNS    | week 1-2   <- Infoblox lead time is the usual delay
Phase 2  storage foundation | week 2-3
Phase 3  migration waves    | week 3 onward, repeating per wave
Phase 4  File Sync          | after gate 2, per disposition B server
Phase 5  protection         | gates every wave in phase 3
Phase 6  handover           | after the last wave
```

The two things that reliably slip: the Infoblox change in phase 1, and the seed duration in
phase 4 when nobody measured the dataset in phase 0. Both are visible in the interview
(questions C4 and A2) and both are cheap to de-risk early.
