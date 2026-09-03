# Design interview - the inputs, as questions

This is the export, asked out loud. Every question exists because
`Export-AzFileSyncEnvironment.ps1` would have answered it from ARM, and something in the
design depends on it.

**How to use it.** You will not get through all of it in one session, and you should not try.
[SESSION-GUIDE.md](SESSION-GUIDE.md) covers the subset that closes the one-way decisions.
This document is the full set, for the follow-up sessions and for the questions that surface
when a build step stalls.

**Columns.** *Feeds* is the decision in [REFERENCE-DESIGN.md](REFERENCE-DESIGN.md) that
consumes the answer. *If unanswered* is what you will assume. *Risk of assuming* is what it
costs when the assumption is wrong - this is the column that gets a reluctant customer to
answer, because it tells them what they are accepting by silence.

---

## A. The migration

| # | Question | Feeds | If unanswered | Risk of assuming |
|---|---|---|---|---|
| A1 | How many servers are moving, in how many waves, and when is wave 1? | D-01, D-18 | One wave, date unknown | No wave gate; servers land unprotected |
| A2 | Which are file servers, and how much data does each hold? | D-04, D-09 | Unknown; sizing unvalidated | Seed duration is a guess; ExpressRoute may saturate in business hours |
| A3 | vCenter version and VMware edition? | D-01 | Supported for agentless | A wave planned agentless has to be replanned agent-based |
| A4 | Is the Azure Migrate appliance deployed, and is replication private or over the internet today? | D-02 | Not deployed | Private Link landing work is discovered late |
| A5 | Any server that cannot be touched by an agent (unsupported OS, vendor-locked appliance)? | D-01 | None | Agentless assumed for a server that needs agent-based |
| A6 | Are migrated VMs landing as Trusted Launch? | D-03, D-13 | Yes, Trusted Launch | **Backup policy subtype is wrong and cannot be reversed** |
| A7 | Which VMs will use Ultra Disk or Premium SSD v2? | D-13 | None | Standard policy attached to a VM it cannot protect |
| A8 | Is there a rollback plan per wave, and who authorises a rollback? | D-01 | None | A failed cutover has no defined exit |

## B. The file estate

| # | Question | Feeds | If unanswered | Risk of assuming |
|---|---|---|---|---|
| B1 | For each file server: does anything else run on it? | D-04 | No | A server marked C is retired while an app on it still matters |
| B2 | Are users willing to have UNC paths change, or must they be preserved? | D-04 | Must be preserved, via DFS-N | Namespace work discovered after cutover |
| B3 | Are there hard-coded UNC paths in scripts, shortcuts, GIS or line-of-business apps? | D-04 | Yes, unknown extent | Cutover breaks applications nobody inventoried |
| B4 | What is the NTFS ACL model - departmental groups, or per-user? | D-11, D-12 | Departmental AD groups | Share-level RBAC design does not fit the real permission model |
| B5 | Any share holding criminal-justice, health or otherwise restricted data? | out of scope, escalate | Assume yes until told otherwise | Data lands somewhere it may not lawfully be |
| B6 | Existing DFS Namespace or DFS Replication in use? | D-04 | None | Cutover plan ignores an existing namespace |
| B7 | Largest single file, and deepest path? | D-12 | Within limits | A copy fails late on a path-length or size limit |
| B8 | Open-file behaviour: are these shares in use 24/7, or is there a quiet window? | D-12 | Business hours only | Copy runs against open files and the fidelity check fails |

## C. Network and name resolution

| # | Question | Feeds | If unanswered | Risk of assuming |
|---|---|---|---|---|
| C1 | ExpressRoute circuit bandwidth, and what else uses it? | D-09 | Unknown | Seed saturates the circuit |
| C2 | Is there a change window for circuit-affecting work? | D-09 | Business hours excluded | Seed scheduled into peak |
| C3 | Hub-and-spoke topology in place, with gateway transit? | D-08 | Yes | Private endpoints unreachable from the spokes |
| C4 | Who owns Infoblox, and what is the change process and lead time? | D-10 | Contoso network team, days | **DNS is the dependency most likely to delay the build** |
| C5 | Is a DNS Private Resolver already deployed in the hub? | D-10 | No | Duplicate resolver, or forwarders pointed at nothing |
| C6 | Any existing `privatelink` zones, and who owns them? | D-10 | None | A second zone with the same name answers for records it does not hold |
| C7 | Are NSGs or UDRs applied to the subnets that will host private endpoints? | D-08 | Default | Private endpoint reachable in design, blocked in practice |
| C8 | Is there a firewall or NVA in the path between clients and the spoke? | D-08 | No | SMB blocked at cutover |

## D. Identity

| # | Question | Feeds | If unanswered | Risk of assuming |
|---|---|---|---|---|
| D1 | AD DS domain name, and is it synced to Entra ID? | D-11 | Synced | Identity-based auth design does not match the directory |
| D2 | Are all file-share users synced, or are some AD-only? | D-11 | All synced | Non-synced users cannot be granted share-level access directly |
| D3 | Which OU may hold the storage account computer object, and who can create it? | D-11 | Requires a delegated OU | Domain-join step blocks on a permission nobody has |
| D4 | Who holds privileged roles on storage and backup today? | out of scope, note it | Unknown | Least-privilege design has no baseline |
| D5 | Is PIM in use for privileged Azure roles? | out of scope, note it | No | Standing privilege on the file estate |

## E. Backup and recovery

| # | Question | Feeds | If unanswered | Risk of assuming |
|---|---|---|---|---|
| E1 | What is the records-retention schedule for this data, and who owns it? | D-13, D-15 | Product defaults | **Retention set by product default rather than by policy** |
| E2 | Required recovery point: daily, or more often? | D-13 | Daily | Enhanced hourly not configured when it was needed |
| E3 | Does the DR plan require restoring into a second region? | D-07, D-16 | Yes | **Cross-region restore cannot be enabled after items are protected** |
| E4 | Existing backup product, and will it be pointed at anything in Azure? | D-14 | Yes, and it will | **A file agent walks a tiered volume and recalls the dataset** |
| E5 | Who may approve destructive backup operations - is MUA acceptable? | D-16 | Yes, with a Resource Guard | Immutability and MUA retrofitted after protection begins |
| E6 | Will SQL Server or SAP HANA in Azure VMs be protected, or MARS, or DPM/MABS? | D-17 | No | Vault private endpoint and its DNS zone omitted from the design |
| E7 | Is item-level recovery from VM backups needed over the ExpressRoute? | D-17 | No | File recovery restricted to VNets with a vault private endpoint |
| E8 | Who watches backup failures, and through what channel? | D-18 | Nobody yet | Silent failure; discovered at restore time |
| E9 | Has a restore ever been tested, and against what evidence? | D-18 | No | Untested recovery path |

## F. Operations

| # | Question | Feeds | If unanswered | Risk of assuming |
|---|---|---|---|---|
| F1 | Who operates this estate after handover - in-house staff or a managed service? | out of scope, note it | In-house staff | Handover has no recipient |
| F2 | Is there an existing Log Analytics workspace and alerting channel? | out of scope, note it | Yes, unknown | Alerts land nowhere |
| F3 | Infrastructure-as-code standard: Bicep, Terraform, or neither? | out of scope, note it | Neither; portal and CLI | Deliverables in a language they will not maintain |
| F4 | Tagging and naming standard? | out of scope, note it | None enforced | Resources unattributable for chargeback |
| F5 | Who pays, and is there departmental chargeback? | out of scope, note it | Central IT | Cost model does not match the funding model |

---

## The five answers that matter most

If the customer will answer only a handful, make them these:

1. **A2** - how much file data, per server. Everything about time and cost follows from it.
2. **A6** - Trusted Launch or not. It decides a one-way backup policy.
3. **E3** - second-region recovery required. It decides two one-way redundancy settings.
4. **E4** - what their existing backup product will be pointed at. It prevents the recall trap.
5. **C4** - who owns the DNS change. It is the schedule risk.

Everything else has a defensible default. These five do not.
