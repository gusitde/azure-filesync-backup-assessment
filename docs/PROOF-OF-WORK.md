# Proof of work

What was built, how it was verified, and what the verification found. Every number here comes
from a command that was run; nothing is asserted from a specification.

**Period covered:** 2026-09-02 to 2026-09-03
**Environment used for validation:** Azure CLI 2.84.0, Windows PowerShell 5.1, a live Azure
tenant with five subscriptions.

---

## 1. What exists

| Deliverable | Size | What it does |
|---|---|---|
| Assessment tooling | 3 PowerShell scripts | Read-only export of an Azure File Sync, storage, backup and private-networking estate; a per-server diagnostic bundle; an assessor with ~80 rules that turns an export into a findings report |
| Advisory track | 4 documents | A decision-led design path for a customer who will not or cannot share their configuration: 18 numbered decisions with defaults and reversal costs, a two-hour session guide, the design interview, a gated build sequence |
| Codex library | 20 entries | 7 blueprints (target state), 9 playbooks (how to build), 4 runbooks (when it breaks) |
| Diagram library | 97 diagrams | Grouped into 8 architecture principles, 9 to 13 per principle, deliberately mixed in kind |
| Reference library | 73 sources | Microsoft reference architectures, Well-Architected and Cloud Adoption Framework guidance, security baselines, product documentation, each with a specific take-away |
| Deployment kit | 4 files | A commented parameter file, an idempotent deployment script with what-if, a teardown script with a safety inventory, and a guide |
| Test suite | 108 checks | Offline, against a synthetic fixture |

---

## 2. Verification performed, and the result

| Layer | Method | Result |
|---|---|---|
| Technical claims in the codex | Every claim extracted and checked against Microsoft documentation, then each reported error re-checked by an independent pass before being applied | **898 claims examined, 62 errors confirmed and corrected** |
| `az` commands | Command path and every flag resolved against the installed CLI | **89 / 89 valid** |
| PowerShell cmdlets | Every cmdlet resolved with `Get-Command`, every parameter checked against its real parameter set including aliases | **48 cmdlets, 111 parameter references, 0 invalid** |
| Read-only gate and verify commands | Executed against live Azure resources | **33 / 36 pass** |
| Exporter ARM contract | Every API version and resource path called against live ARM | **23 / 23 return 200** |
| Codex format | Strict validator | **20 / 20 entries valid, 0 errors** |
| Diagrams | Every file posted to a mermaid renderer | **97 / 97 render** |
| Reference URLs | Every unique URL fetched | **57 / 57 return 200** |
| Assessor logic | Offline fixture suite | **108 / 108 checks green** |
| Deployment scripts | Parsed, then run end to end in what-if against a live subscription | **pass, 13 steps** |
| Teardown safety refusal | Run against a real resource group holding unrelated resources | **correctly refused** |

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

---

## 4. Evidence captured

| Evidence | Where |
|---|---|
| Full validation record, method and limitations | [VALIDATION.md](VALIDATION.md) |
| The assessor rule catalogue | [RULES.md](RULES.md) |
| Verified reference sources with take-aways | [ARCHITECTURE-REFERENCES.md](ARCHITECTURE-REFERENCES.md) |
| Diagram index by principle and kind | [../codex/diagrams/README.md](../codex/diagrams/README.md) |
| Commit history | One commit per change, each describing what was verified |

---

## 5. What has NOT been done, and why

Stated plainly rather than left for someone to discover.

**No Azure resources have been created.** The tenant available for validation requires
multi-factor authentication for every write:

```
RequestDisallowedByAzure: ... tried to create, update or delete Azure resources
without authenticating through MFA.
```

The available account also holds only User Access Administrator, which manages role assignments
and grants no resource-creation rights, and self-elevation hits the same MFA wall. So:

- **Mutating commands are documentation-verified and shape-verified, not executed.** Every
  `create`, `update` and `delete` has had its command path and flags resolved against the real
  CLI, and the deployment script has been run end to end in what-if - but nothing has been
  built.
- **There is no as-built document and no screenshots**, because there is no deployment to
  photograph. [AS-BUILT-TEMPLATE.md](AS-BUILT-TEMPLATE.md) is ready to be filled in, and states
  exactly which command output and which portal view to capture for each feature.

**To close this**, one of the following is needed:

1. An interactive `az login` completing MFA on the machine that runs the deployment, or
2. A service principal with Contributor on the target subscription, which is not subject to the
   user MFA policy and is the better choice for repeatable automation.

With either in place, `Deploy-AfsEnvironment.ps1` builds the environment from the parameter
file and the as-built template can be completed from its output.

**Also not executed:** five cmdlets that do not ship in a PowerShell Gallery module -
`Debug-StorageSyncServer` and `Invoke-StorageSyncFileRecall` install with the Azure File Sync
agent on a registered server; `Join-AzStorageAccount` and `Debug-AzStorageAccountAuth` come from
AzFilesHybrid, distributed from GitHub; `Get-ADComputer` needs RSAT.
