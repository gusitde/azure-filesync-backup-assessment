# Azure File Sync + Azure Backup assessment and advisory kit

Tooling, playbooks and a codex library for two jobs on the same estate: **assess** a
customer's existing Azure File Sync and Azure Backup configuration and recommend
enhancements, and **design and build** it from nothing when there is nothing to assess -
including the case where the servers are still on VMware and the customer wants sync and
backup traffic on their ExpressRoute.

## Two doors

| | **Assess** | **Advise** |
|---|---|---|
| Use when | The customer will export their configuration | They will not, cannot, or have nothing to export yet |
| Input | `afs-export-<stamp>.zip` | A working session, using [advise/DESIGN-INTERVIEW.md](advise/DESIGN-INTERVIEW.md) |
| Engine | `Assess-AzFileSyncExport.ps1`, ~80 rules | [advise/REFERENCE-DESIGN.md](advise/REFERENCE-DESIGN.md), 18 decisions with defaults |
| Output | `assessment.md` - findings against what exists | A target design, a build sequence and a decision log |
| Start at | [docs/PLAYBOOK-azure-file-sync-assessment.md](docs/PLAYBOOK-azure-file-sync-assessment.md) | [advise/SESSION-GUIDE.md](advise/SESSION-GUIDE.md) |

Both doors converge on [codex/](codex/), which holds the target-state blueprints, the
playbooks that build them and the runbooks for when they break.

## Door A - assess

Three scripts, one flow:

| Step | Script | Runs where | Needs | Produces |
|---|---|---|---|---|
| 1. Export the cloud side | `Export-AzFileSyncEnvironment.ps1` | any workstation with `Az.Accounts` | Reader on the subscriptions | `afs-export-<stamp>.zip` (raw ARM JSON + `summary.md`) |
| 2. Export the server side (optional, per registered server) | `Get-AfsServerDiagnostics.ps1` | on each Windows Server running the agent, elevated | local admin | `<host>-afs-server-<stamp>.zip` |
| 3. Assess | `Assess-AzFileSyncExport.ps1` | analyst workstation, no Azure access needed | the zip(s) | `assessment.md` + `findings.json` |

Everything is **read-only**: only ARM `GET` calls, no `listKeys`, no SAS, no certificates; a
redaction pass blanks well-known secret field names anyway. The export contains resource
names and IDs (needed to write recommendations) but no data, no keys, no credentials.

```powershell
Install-Module Az.Accounts -Scope CurrentUser          # once
Connect-AzAccount -Tenant <tenant-id>                   # an account with Reader on the subscriptions
.\Export-AzFileSyncEnvironment.ps1                      # all enabled subscriptions in the tenant
```

Then, on the analyst side:

```powershell
.\Assess-AzFileSyncExport.ps1 -ExportPath .\afs-export-20260903-090000 -CustomerName "Contoso of X"
# customer requires ExpressRoute / private routing for File Sync traffic:
.\Assess-AzFileSyncExport.ps1 -ExportPath .\afs-export-20260903-090000.zip -CustomerName "Contoso of X" -PrivateTrafficRequired
.\Assess-AzFileSyncExport.ps1 -ListRules > docs\RULES.md   # the rule catalog
```

`assessment.md` has a scorecard, findings by severity (evidence + recommendation + Microsoft
Learn reference for each), a roadmap (do now / this engagement / backlog) and the assessment
gaps. `findings.json` is the same data for a deck or tracker.

Optionally, on each registered file server (elevated PowerShell):

```powershell
.\Get-AfsServerDiagnostics.ps1 -OutputPath C:\temp      # add -SampleTieredFiles for a tiered-file census
```

## Door B - advise

For the customer who will not be assessed, or whose estate does not exist yet.

| Document | What it is |
|---|---|
| [advise/SESSION-GUIDE.md](advise/SESSION-GUIDE.md) | A two-hour working session: agenda, the decisions to close, the default for each |
| [advise/REFERENCE-DESIGN.md](advise/REFERENCE-DESIGN.md) | 18 numbered decisions, each with a default, a reason and a reversal cost |
| [advise/DESIGN-INTERVIEW.md](advise/DESIGN-INTERVIEW.md) | The export, asked out loud - every question mapped to the decision it feeds |
| [advise/BUILD-SEQUENCE.md](advise/BUILD-SEQUENCE.md) | Day 1 to day 90, gated, mapped to the codex playbooks |

The design covers the whole path a VMware estate takes into Azure: the landing, the
disposition of each file server, the private network path, and **three protection surfaces**
that are commonly conflated - the migrated VM, the Azure file share, and the File Sync server
endpoint, which is a cache and is deliberately never backed up.

## What the export captures

- **Azure File Sync**: Storage Sync Services (traffic policy, managed identity), sync groups,
  cloud endpoints (share, change enumeration), server endpoints (tiering policy, sync
  health, per-item errors, tiering health, cache hit ratio, low-disk mode), registered
  servers (OS, agent version + expiry, heartbeat, auth type), private endpoint connections,
  RBAC, locks, 7-day metrics (sync results, heartbeats, recall volume, agent expiry).
- **Storage accounts**: every account in scope with account properties (TLS, HTTPS-only,
  firewall + bypass + resource rules, public network access, shared key, identity-based
  auth, encryption, key age/policy, redundancy, large file shares), file service settings
  (share soft delete, SMB protocol hardening), every file share (quota, usage, tier,
  snapshots, soft-deleted shares), RBAC, locks, Defender for Storage, diagnostics, metrics.
- **Azure Backup**: Recovery Services vaults (soft delete, immutability, MUA, redundancy,
  cross-region restore, alerts, public access), vault/storage config, backup policies (incl.
  vaulted tier), containers, protected items, jobs, resource-guard proxies, diagnostics,
  RBAC, locks; Data Protection vaults; a **share -> backup coverage** table.
- **Network**: `privatelink.file.*` / `privatelink.afs.*` zones (+ VNet links, A records),
  private endpoints targeting storage accounts or Storage Sync Services (+ DNS zone groups),
  and a Resource Graph topology of ExpressRoute circuits, gateways, connections, VNets and
  DNS Private Resolvers.
- **Monitoring**: metric alert rules scoped to any of the above.

## Rules

The assessor evaluates ~80 rules across sync health, registered servers, cloud tiering,
storage security, durability, backup coverage/health/design, vault security, private
networking (with an ExpressRoute target-state mode), monitoring, hygiene and server-side
checks. See [docs/RULES.md](docs/RULES.md). Each rule carries the check, the recommendation
and the Microsoft Learn reference it is derived from.

## Playbooks

- [docs/PLAYBOOK-azure-file-sync-assessment.md](docs/PLAYBOOK-azure-file-sync-assessment.md) -
  scope, export, assess and recommend (including the ExpressRoute / Private Link design).
- [docs/PLAYBOOK-azure-backup-for-azure-files.md](docs/PLAYBOOK-azure-backup-for-azure-files.md) -
  design and set up Azure Backup for the synced shares (snapshot + vaulted tiers, vault
  hardening, restore test), and why backup traffic does not need the ExpressRoute.

## Codex library

[codex/](codex/) holds **20 codex-format entries** and **97 mermaid diagrams**:

- **Blueprints** (target state): secure storage account, Azure file share private endpoint,
  hybrid DNS for private endpoints, Azure File Sync on the private path, Azure Migrate over
  Private Link, Azure Files backup protection, and Azure VM backup for servers migrated from
  VMware.
- **Playbooks** (how to build): AVM Bicep deployment, private endpoint and DNS, hardening an
  existing account, DNS Private Resolver with Infoblox forwarders, the File Sync private-path
  cut-over, AD DS identity-based auth, the Azure Migrate cache account, Azure Backup for file
  shares, and protecting a migration wave.
- **Runbooks** (when it breaks): private endpoint name resolution, File Sync after a network
  lock-down, key rotation and shared-key incidents, and restoring a share.

Diagrams are grouped by architecture principle with 9 to 13 views each - topology, sequence,
decision tree, state machine, failure and blast-radius, ownership split, cut-over timeline,
trade-off matrix and resource entity model. Index: [codex/diagrams/README.md](codex/diagrams/README.md).

Entries import into a Luca codex with `node codex/import-to-luca.mjs --luca-root <checkout>`.
Index and Contoso profile: [codex/README.md](codex/README.md).

## Architecture references

[docs/ARCHITECTURE-REFERENCES.md](docs/ARCHITECTURE-REFERENCES.md) collects **73 verified
sources** across the same eight principles - reference architectures, Well-Architected and
Cloud Adoption Framework guidance, security baselines, product documentation, limits and
quotas, and official modules and samples. Every URL was opened and confirmed to cover what is
claimed, and each entry carries the specific constraint, decision rule or module to lift from
it rather than a vague endorsement.

## Accuracy

The codex library was adversarially fact-checked against Microsoft's own documentation on
2026-09-03: 898 technical claims were extracted and verified, an independent judge upheld 62
as errors, and all 62 were corrected. The codex validator reports 20/20 entries seedable with
0 errors, and all 97 diagrams were render-verified. Facts that carry a version, a limit or a
pinned module number should be re-verified before being quoted to a customer more than a
quarter from now.

**What "verified" means here, precisely** - see [docs/VALIDATION.md](docs/VALIDATION.md) for
the full record. In short: every `az` command in the library has had its command path and
every flag resolved against a real CLI (89 of 89 valid); the read-only gate and verify
commands have been executed against live Azure resources; all 23 ARM API versions the
exporter uses return 200 against live ARM; and the deployment scripts run end to end in
what-if mode. **Mutating commands have not been executed** - the test tenant requires MFA for
every write - so treat `create`, `update` and `delete` steps as rehearsal-first, in a scratch
resource group, before running them anywhere that matters.

Execution found five defects that documentation review had missed, including a backup gate
rule that returned nothing while exiting 0, and Git Bash silently corrupting Azure resource
IDs. They are listed in the validation record. If a command does not behave as written for
you, that is worth reporting - see [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

Corrections and gaps are both welcome, and neither needs write access. A wrong command is
found the first time someone runs it; a missing runbook is found at 2am during an incident, so
gap reports are the more valuable of the two. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
issue templates, the three house rules for edits, and where a new document belongs.

## Tests

```powershell
python fixtures\make-fixture.py     # regenerate the synthetic export
.\tests\run-tests.ps1               # 108 checks: rule catalog, fixture findings, private mode, zip input
```

## Requirements

Windows PowerShell 5.1 or PowerShell 7; `Az.Accounts` 2.x+ for the export. The scripts are
saved UTF-8 with BOM and ASCII-only so Windows PowerShell parses them regardless of locale.
