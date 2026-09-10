# Proof of work

What was built, how it was verified, and what the verification found. Every number here comes
from a command that was run; nothing is asserted from a specification.

**Period covered:** 2026-09-02 to 2026-09-10. Counts re-measured at `V 2026.09.10.001`.
**Environment used for validation:** Azure CLI 2.84.0, Windows PowerShell 5.1, a live Azure
tenant with five subscriptions, a lab resource group, and an on-premises lab with a Windows
Server 2022 file server and Active Directory domain controllers.

---

## 1. What exists

| Deliverable | Size | What it does |
|---|---|---|
| Guided front door | `start.ps1`, 14 menu options | Checks requirements, asks what you want to do, and runs the right scripts in order - a dry run first for anything that writes |
| Assessment tooling | 3 PowerShell scripts, plus an HTML renderer with 7 subject tabs | Read-only export of an Azure File Sync, storage, backup and private-networking estate; a per-server diagnostic bundle; an assessor with 94 rules that turns an export into `assessment.md`, `findings.json` and a 13-tab `assessment.html` |
| Governance | 1 script | Wraps the Azure Governance Visualizer for policy, RBAC, management groups, locks and Defender coverage |
| Advisory track | 4 documents | A decision-led design path for a customer who will not or cannot share their configuration: 18 numbered decisions with defaults and reversal costs, a two-hour session guide, the design interview, a gated build sequence |
| Deployment kit | two phases, 15 build steps | Four operator inputs; phase 1 creates a least-privilege deployment identity; phase 2 builds unattended and idempotently; a teardown with a safety inventory; an as-built generated from live reads |
| On-premises scripts | 3 scripts, a shared library and 2 removal helpers | The File Sync agent and server endpoint, DNS conditional forwarders, and the AD DS domain join - each with `-WhatIf` and `-Remove` |
| Requirements check | `deploy/AfsRequirements.ps1` | This machine, Azure (resource providers, the right to create role assignments), DNS servers, AD DS and the file server, in three states - ok, missing, unknown |
| Codex library | 25 entries | 7 blueprints (target state), 13 playbooks (how to build), 5 runbooks (when it breaks) |
| Diagram library | 97 diagrams | Grouped into 8 architecture principles, 9 to 13 per principle, deliberately mixed in kind |
| Reference library | 73 sources | Microsoft reference architectures, Well-Architected and Cloud Adoption Framework guidance, security baselines, product documentation, each with a specific take-away |
| Test suite | 195 checks | Offline, against a synthetic fixture: the rule catalogue, rule severities, private-traffic mode, zip input, every report tab, the menu wiring, and a parse of the wizard |

---

## 2. Verification performed, and the result

| Layer | Method | Result |
|---|---|---|
| Technical claims in the codex | Every claim extracted and checked against Microsoft documentation, then each reported error re-checked by an independent pass before being applied (2026-09-03, 20 entries at the time) | **898 claims examined, 62 errors confirmed and corrected** |
| `az` commands | Command path and every flag resolved against the installed CLI (same corpus) | **89 / 89 valid** |
| PowerShell cmdlets | Every cmdlet resolved with `Get-Command`, every parameter checked against its real parameter set including aliases (same corpus) | **48 cmdlets, 111 parameter references, 0 invalid** |
| Read-only gate and verify commands | Executed against live Azure resources | **33 / 36 pass** |
| Exporter ARM contract | Every API version and resource path called against live ARM | **23 / 23 return 200** |
| Codex format | `codex\import-to-luca.mjs --dry-run` against the strict validator (2026-09-10) | **25 / 25 would seed, 0 errors** |
| Diagrams | Every file posted to a mermaid renderer | **97 / 97 render** |
| Reference URLs | Every unique URL fetched | **57 / 57 return 200** |
| Assessor, reports and wizard wiring | Offline fixture suite (2026-09-10) | **195 / 195 checks green** |
| Deployment | What-if, then a real build in a lab subscription | **built end to end; a second run skipped what already existed** |
| On-premises File Sync | Agent installed over PowerShell remoting, server registered, sync group and endpoints created | **files synced up** |
| AD DS join | The join script against a lab domain | **joined as a computer object; `Debug-AzStorageAccountAuth` checks pass; a second run reports already joined** |
| Backup and restore | On-demand backup under the 60-day policy; item-level restore of a folder to another location; forced change detection | **restore completed in 78 s, and the folder synced back down to the server** |
| Requirements check | Against the lab estate | **41 checks; found a missing OU the join would have misreported as a permissions failure** |
| Teardown | Against a vault whose soft delete a policy keeps always on, and against a group holding unrelated resources | **removed everything else and printed the retry date; correctly refused** |

---

## 3. What the verification actually caught

Verification that finds nothing has usually not been done properly. This found real defects at
every layer.

### 3.1 In the written content - 62 corrections from 898 claims

The substantive ones, each of which would have been visible to the customer:

- **The Storage Sync Service private endpoint publishes four FQDNs with the role token inside
  the first label** (`<sss>management.<region>.afs.azure.net`), not the bare
  `<sss>.<region>.afs.azure.net` pattern the library had. The printed pattern resolves nothing,
  and would have been copied into DNS and IPAM.
- **Azure File Sync is on the storage trusted-services list and is not a supported
  resource-instance-rule type.** The library had prescribed a resource instance rule as a
  belt-and-braces control. That configuration does not exist.
- **The Azure Migrate cache account takes a `blob` private endpoint**, not blob and queue.
- **Azure Backup does not depend on the account key path** in the way the library stated.
- **The backup vault private endpoint scope** covers SQL Server and SAP HANA in Azure VMs, MARS
  and DPM/MABS - and file recovery from a private-endpoint-enabled vault is restricted to
  virtual networks holding a vault private endpoint.

### 3.2 In behaviour - five defects that only execution could find

**A gate rule that passed while checking nothing.** `az backup vault backup-properties show`
returns an **array**. The un-indexed query `--query "properties.storageModelType"` returns
empty output and exit code 0 - it looks like a pass. Proven against two live vaults: the
indexed form returns the value, the bare form returns nothing.

```
G20  CORRECTED FORM: [0] index returns the value      -> LocallyRedundant
G21  PROOF the index is required: bare form is empty   -> CONFIRMED
G27  same form on a second vault                       -> GeoRedundant
```

**Git Bash corrupts Azure resource IDs.** MSYS rewrites any argument beginning with `/` into a
Windows path, and every ARM ID begins `/subscriptions/`. Commands taking `--resource` or
`--scope` fail with a usage error that names neither the cause nor the fix. `MSYS_NO_PATHCONV=1`
resolves it. Now documented in the getting-started guide and the deployment README.

**`az dns-resolver` is a CLI extension, not built in.** Without it every DNS resolver command
fails as an unrecognised command group. The deployment script now installs it during preflight
rather than failing part way through a build.

**A terminating-error defect in the deployment script.** `az` writes to stderr, and under
`$ErrorActionPreference = 'Stop'` the `2>&1` merge converts that into a terminating
`NativeCommandError` - so an expected "does this exist?" probe killed the script at step 2.

**An array-nesting defect in the teardown script.** `@(Invoke-Az ...)` does not flatten: a
function returning an `Object[]` is emitted as a single item, so the array subexpression yields
one element containing the array. The teardown safety inventory reported "1 resource" for a
group holding two and ran their names together - in the check whose entire purpose is to stop a
teardown deleting somebody else's work.

### 3.3 In the verification tooling itself

Recorded because it is the reason to distrust a green result nobody interrogated. The first
parameter check reported three invalid parameters; all three were extraction artifacts. The fix
for them over-corrected and blanked the `powershell -Command "..."` wrapper, silently shrinking
the corpus from 56 cmdlets to 8 - **while still reporting a clean pass**. A validator that
shrinks its own input reports success by finding nothing. Corpus size is now asserted alongside
the result.

### 3.4 In the live runs

Running the build, the on-premises steps and the teardown for real found defects that neither
documentation review nor a what-if could: a DNS zone-group check that passed on an empty `{}`,
so no A records were written; the Windows `az.cmd` wrapper failing on any `)` in an argument; a
multi-line `tsv` answer read as one string; the CLI's shared default subscription retargeting a
running build; a dot-sourced renderer binding its parameters in the caller's scope; a resource
provider that had never been registered; a build that counted backup steps it did not yet have;
and `powershell -File` silently dropping `-Confirm:$false`. Each is fixed, and recorded in
[VALIDATION.md](VALIDATION.md) and the change log in [VERSION-CONTROL.md](VERSION-CONTROL.md).

---

## 4. Evidence captured

| Evidence | Where |
|---|---|
| Full validation record, method and limitations | [VALIDATION.md](VALIDATION.md) |
| The assessor rule catalogue | [RULES.md](RULES.md) |
| Verified reference sources with take-aways | [ARCHITECTURE-REFERENCES.md](ARCHITECTURE-REFERENCES.md) |
| Diagram index by principle and kind | [../codex/diagrams/README.md](../codex/diagrams/README.md) |
| The change log, one row per change, with the version stamp | [VERSION-CONTROL.md](VERSION-CONTROL.md) |
| As-built documents from the lab build, read live from Azure | generated under `as-built/`; not committed, because they name real resources |
| Run logs with timings and telemetry | `logs/`; not committed, for the same reason |
| Commit history | One commit per change, each describing what was verified |

---

## 5. What has NOT been done, and why

Stated plainly rather than left for someone to discover.

- **The DNS forwarder write, and the lock-down, against a live private path.** At the time of the
  lab runs the resolver's inbound address was not reachable from on-premises. The forwarder
  script refused to write, as designed, because the resolver did not answer with a private
  address - so the forwarding design rests on Microsoft's documentation and on the refusal path,
  not on a completed write. The build's lock-down step is not reachable from the inputs file in
  this version ([issue #1](https://github.com/gusitde/azure-filesync-backup-assessment/issues/1)), so closing the public paths is a manual step.
- **ExpressRoute.** There is no circuit in the lab. The private-traffic rules
  (`-PrivateTrafficRequired`) and the ExpressRoute design are documentation-verified.
- **Azure Migrate and migrated-VM backup.** The procedures - the private-link landing, the cache
  storage account, the Enhanced policy for Trusted Launch VMs - are shape-verified, with every
  command and parameter resolved, but not executed.
- **Key rotation and shared-key incidents.** That runbook is documentation- and shape-verified
  only.
- **A customer estate.** The assessor has run against the synthetic fixture and against exports
  of the lab tenant, not against a customer's export.
- **Two agent cmdlets.** `Debug-StorageSyncServer` and `Invoke-StorageSyncFileRecall` install
  with the Azure File Sync agent; this record does not claim either as executed. The AzFilesHybrid
  pair, `Join-AzStorageAccount` and `Debug-AzStorageAccountAuth`, has now run against a real
  domain.

**How the original blocker was cleared.** The first validation tenant required multi-factor
authentication for every write:

```
RequestDisallowedByAzure: ... tried to create, update or delete Azure resources
without authenticating through MFA.
```

and the account available held only User Access Administrator, which cannot create resources. It
was cleared by an administrator holding Owner on the lab subscription signing in once with MFA.
Phase 1 of the deployment is built around that: one interactive, MFA-completed sign-in creates a
deployment identity with Contributor on one resource group, and everything after that runs as the
identity, which the user MFA policy does not apply to. The code defects the README fact-check
found are tracked in [issue #1](https://github.com/gusitde/azure-filesync-backup-assessment/issues/1).
