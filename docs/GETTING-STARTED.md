# Getting started

A complete walk-through: what to install, how to sign in, and how to run each script. Written
for someone who has not seen this repository before. Every version and error message here came
from actually running it, not from a specification.

---

## 1. What you need before you start

**A machine.** Windows with PowerShell 5.1 (built in) or PowerShell 7. macOS and Linux work
for the assessment side; the deployment scripts are written for PowerShell and run on 7 too.

**An Azure account with the right access.**

| What you want to do | Access needed |
|---|---|
| Export and assess an existing estate | **Reader** on the subscriptions in scope |
| Deploy a new environment | **Contributor** on the target subscription |
| Domain-join the storage account | Permission to create the identity object in the chosen OU |

**One thing that catches people out.** Many tenants require the account to have signed in with
multi-factor authentication before *any* write is allowed. A session authenticated without MFA
can read everything and create nothing, and the error mentions neither RBAC nor your role:

```
RequestDisallowedByAzure: You are receiving this error because you tried to create,
update or delete Azure resources without authenticating through MFA.
```

If you see that, run `az logout` then `az login` and complete the MFA prompt. It is not a
permissions problem, and granting yourself more roles will not help.

---

## 2. Install the dependencies

### Azure CLI

```powershell
winget install --exact --id Microsoft.AzureCLI
# or download from https://aka.ms/installazurecliwindows
az version
```

Tested with **2.84.0**.

### The dns-resolver extension

Needed only if you deploy the Azure DNS Private Resolver. It is an extension, not part of the
base CLI, and without it every `az dns-resolver` command fails as an unrecognised command
group rather than as a missing extension:

```powershell
az extension add --name dns-resolver
az extension list --query "[?name=='dns-resolver'].version" -o tsv    # expect 1.2.0 or later
```

`Deploy-AfsEnvironment.ps1` installs this for you during preflight if it is missing.

### PowerShell modules

The **export** script needs only `Az.Accounts`:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
```

The **assessment** script needs nothing at all - it reads a zip file offline.

To run the codex procedures by hand rather than through the deployment script, install the
modules they use. These exact versions were used to validate every cmdlet and parameter in
this repository:

```powershell
Install-Module Az.Storage          -Scope CurrentUser    # 9.6.0
Install-Module Az.StorageSync      -Scope CurrentUser    # 2.6.0
Install-Module Az.RecoveryServices -Scope CurrentUser    # 7.14.1
Install-Module Az.Network          -Scope CurrentUser    # 8.2.0
Install-Module Az.PrivateDns       -Scope CurrentUser    # 1.3.0
Install-Module Az.DnsResolver      -Scope CurrentUser    # 2.0.0
Install-Module Az.Compute          -Scope CurrentUser    # 11.9.0
```

Two more are **not** on the PowerShell Gallery:

- **AzFilesHybrid** provides `Join-AzStorageAccount` and `Debug-AzStorageAccountAuth` for the
  AD DS domain join. Microsoft distributes it from GitHub: download the release, unblock the
  files, and run `.\CopyToPSPath.ps1`.
- **The Azure File Sync agent** provides `Debug-StorageSyncServer` and
  `Invoke-StorageSyncFileRecall`. These exist only on a server with the agent installed.

### If you use Git Bash on Windows, read this

Git Bash rewrites any argument beginning with `/` into a Windows path. Every Azure resource ID
begins with `/subscriptions/`, so commands that pass one fail with a confusing usage error:

```
ERROR: usage error: --resource ID | --resource NAME --resource-group NAME ...
```

Either run from PowerShell, or set this first:

```bash
export MSYS_NO_PATHCONV=1
```

---

## 3. Sign in

```powershell
az login                                   # complete MFA if prompted
az account set --subscription "<name or id>"
az account show --query "{sub:name, user:user.name}" -o table
```

For the export script, sign in to PowerShell as well:

```powershell
Connect-AzAccount -Tenant <tenant-id>
```

---

## 4. Which path are you on?

**You have an existing estate and want it reviewed** - section 5.

**You are building from nothing, or the customer will not share their configuration** -
section 6. Read [../advise/SESSION-GUIDE.md](../advise/SESSION-GUIDE.md) first if the design
is not agreed yet.

---

## 5. Assess an existing estate

### Step 1 - export (run by whoever has Reader access)

```powershell
.\Export-AzFileSyncEnvironment.ps1
```

Options worth knowing:

```powershell
# only certain subscriptions
.\Export-AzFileSyncEnvironment.ps1 -SubscriptionId <id1>,<id2>

# look further back for backup jobs, and skip metrics to run faster
.\Export-AzFileSyncEnvironment.ps1 -JobLookbackDays 60 -SkipMetrics

# leave the output as a folder instead of a zip
.\Export-AzFileSyncEnvironment.ps1 -NoZip
```

It produces `afs-export-<timestamp>.zip`. This is **read-only**: only ARM `GET` calls, no
`listKeys`, no SAS, no certificates, and a redaction pass blanks well-known secret field names
anyway. It contains resource names and settings, no file data and no credentials.

### Step 2 - per-server detail (optional, on each file server, elevated)

```powershell
.\Get-AfsServerDiagnostics.ps1 -OutputPath C:\temp
.\Get-AfsServerDiagnostics.ps1 -OutputPath C:\temp -SampleTieredFiles   # adds a tiered-file census
```

Drop each resulting server zip into `servers\<hostname>\` inside the unzipped export.

### Step 3 - assess (no Azure access needed)

```powershell
.\Assess-AzFileSyncExport.ps1 -ExportPath .\afs-export-20260903-090000.zip -CustomerName "Contoso"

# if sync and backup traffic must stay on a private path, add this - it turns on the
# ExpressRoute target-state rules and escalates the public-path findings
.\Assess-AzFileSyncExport.ps1 -ExportPath .\afs-export-...zip -CustomerName "Contoso" -PrivateTrafficRequired

# see every rule the assessor applies
.\Assess-AzFileSyncExport.ps1 -ListRules
```

You get `assessment.md` - a scorecard, findings by severity with evidence and a Microsoft
reference for each, and a prioritised roadmap - plus `findings.json`, the same data for a deck
or a tracker.

---

## 6. Build an environment

You supply four things. Phase 1 runs once, interactively. Phase 2 runs unattended.

### Step 1 - fill in the four inputs

```powershell
cd deploy
Copy-Item inputs.sample.jsonc inputs.json
notepad inputs.json
```

| # | What you enter | Why |
|---|---|---|
| 1 | **Entra global admin** account | Phase 1 only - creates the deployment identity and grants it a role. Never used again |
| 2 | **Azure subscription** and a short `namePrefix` | Where it is built, and the one naming decision you make |
| 3 | **AD admin account** | Domain-joins the storage account. Needs only permission to create an object in the OU below, not Domain Admin |
| 4 | **AD basics** - domain FQDN, NetBIOS name, the OU for the identity object, object type | What the join actually needs to know |

Everything else is derived. See exactly what you will get before anything runs:

```powershell
.\Deploy-AfsEnvironment.ps1 -InputFile .\inputs.json -ShowResolved
```

With `namePrefix: contoso` in `eastus` you get `rg-contoso-filesync`, `stcontosofs01`,
`sss-contoso-filesync`, `vnet-contoso-filesync`, `dnspr-contoso-eastus`, `rsv-contoso-eastus`.
Override any of them in the `overrides` section if your naming standard differs.

### Step 2 - phase 1, once

```powershell
.\Phase1-New-DeploymentIdentity.ps1 -InputFile .\inputs.json
```

A browser opens. Sign in as the administrator and complete MFA - this is the single human step
in the whole process, and it exists because most tenants require MFA for every ARM write.

Phase 1 then creates the resource group (which is also how it proves the session may write),
creates the Entra deployment identity, grants it Contributor **on that resource group only**,
writes `deployment-context.json`, and finally signs in as the new identity to prove it works.
If the identity is broken you find out here, not during a build.

For a pipeline, issue no secret at all:

```powershell
.\Phase1-New-DeploymentIdentity.ps1 -InputFile .\inputs.json -Federate -GitHubRepo owner/repo
```

That adds a federated credential so GitHub Actions authenticates with OIDC - nothing to store,
nothing to rotate.

**The administrator needs** Application Administrator or higher in Entra ID to create the
identity, and Owner or User Access Administrator on the subscription to grant the role.

### Step 3 - phase 2, unattended

```powershell
.\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf
.\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json
```

No prompts, no browser, no MFA - it signs in as the identity phase 1 created. Always run the
what-if first; it executes the real preflight checks (CLI version, sign-in, subscription
access, the dns-resolver extension, storage account name availability) and then shows every
step without changing anything.

The script is idempotent, so if something fails you fix the cause and run it again rather than
starting over. When it finishes it prints a verification command for every object it created.
Run them.

### Step 4 - verify, then lock down

Confirm the private endpoint resolves before you close any public path. From a machine on the
network:

```powershell
Resolve-DnsName <storageaccount>.file.core.windows.net
# expect a CNAME to <account>.privatelink.file.core.windows.net and a PRIVATE address
Test-NetConnection <storageaccount>.file.core.windows.net -Port 445
```

Only once that is right, set these two to `true` in the `overrides` section of your inputs
file and re-run phase 2:

```jsonc
"disableStoragePublicAccess": true,
"restrictFileSyncToVirtualNetworksOnly": true
```

Closing the public path before the private endpoint resolves is the most common way to break
sync, which is why it is not the default.

### Step 5 - the three things the script does not do

These need a human on a specific machine.

**Install and register the File Sync agent**, on the file server:

```powershell
# download the agent for your OS from Microsoft, install, then:
Register-AzStorageSyncServer -ResourceGroupName <rg> -StorageSyncServiceName <sss>
```

Then create the server endpoint pointing at the local path you want synced.

**Point your on-premises DNS at the resolver.** The deployment printed the inbound endpoint IP.
Create conditional forwarders for the `privatelink` zones only:

- `privatelink.file.core.windows.net`
- `privatelink.afs.azure.net`

Do **not** forward the parent `core.windows.net`. That sends every storage lookup through the
resolver, including accounts with no private endpoint, and those then fail.

**Domain-join the storage account**, from a domain-joined machine with AzFilesHybrid:

```powershell
Import-Module .\AzFilesHybrid.psd1
Join-AzStorageAccount -ResourceGroupName <rg> -StorageAccountName <account> `
    -DomainAccountType ComputerAccount -OrganizationalUnitDistinguishedName "<OU DN>"
```

Remember that the identity object has a password that must be rotated, and that share-level
Azure roles and NTFS permissions both apply - a user needs both.

---

## 7. Remove it again

```powershell
.\Remove-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf
.\Remove-AfsEnvironment.ps1 -Context .\deployment-context.json
```

It deletes the resource group, which is the only reliable way to leave nothing behind. Before
it does, it inventories the group and **refuses** if it finds resources your parameter file
does not name - pass `-Force` when that is expected. It also disables backup protection with
data deletion first, because a vault will not delete while it protects anything.

---

## 8. When something goes wrong

**Every run is logged.** The wizard and each deploy script write three files under `logs/`:

| File | What it holds |
|---|---|
| `<run>.log` | One timestamped line per event, with a level: DEBUG, INFO, STEP, WARN, ERROR |
| `<run>.jsonl` | The same events as JSON, one per line, with the account, machine and tool versions - for telemetry |
| `<run>.transcript.txt` | Everything the console showed, so a crash is recorded even if it happened outside our code |

The wizard prints the log path when it starts. After a failure, the line to look for is the
`[ERROR]` entry - it carries the message, the script line that threw, and the stack.

Choose how much to capture with `-LogLevel`:

```powershell
.\start.ps1                     # Verbose (default): az adds --verbose, kept in the file only
.\start.ps1 -LogLevel Debug     # full Azure CLI HTTP traces, also echoed to the console
.\start.ps1 -LogLevel Quiet     # console shows warnings and errors only
```

The log always receives everything regardless of level; the level only decides what the
console shows and how chatty the Azure CLI is asked to be. Secrets passed on the command
line are masked before they reach the log.

**The errors you are most likely to see:**

| What you see | What it means | What to do |
|---|---|---|
| `RequestDisallowedByAzure ... without authenticating through MFA` | The session signed in without MFA. Reads work, writes do not. | `az logout`, then `az login` and complete MFA |
| `AuthorizationFailed ... does not have authorization to perform action` | A genuine RBAC gap | You need Contributor on the target scope |
| `ERROR: usage error: --resource ID \| --resource NAME ...` | Git Bash rewrote a resource ID into a Windows path | Run from PowerShell, or `export MSYS_NO_PATHCONV=1` |
| `az dns-resolver` is not a known command group | The extension is missing | `az extension add --name dns-resolver` |
| A `--query` on backup properties returns nothing, exit code 0 | `az backup vault backup-properties show` returns an **array** | Index it: `--query "[0].properties.storageModelType"` |
| Storage account name rejected as taken | The name is global | Choose another; `-WhatIf` catches this before anything is built |
| Sync stops right after a network change | The public path was closed before the private endpoint resolved | Re-open it, verify resolution, close it again. See `codex/runbook-file-sync-broken-after-network-lockdown.md` |
| A backup agent triggers a huge recall | A file-level product walked a tiered File Sync volume | Exclude the server endpoint path. Back up the **share**, never the cache |
| `Connect-AzAccount -AccessToken` connects but calls return 401 | A raw token context cannot service most Az cmdlets | Use an interactive `Connect-AzAccount`, or a service principal |

---

## 9. What is in this repository

| Path | What it is |
|---|---|
| `Export-AzFileSyncEnvironment.ps1` | Read-only export of the cloud side |
| `Get-AfsServerDiagnostics.ps1` | Per-server diagnostic bundle |
| `Assess-AzFileSyncExport.ps1` | Turns an export into a findings report |
| `deploy/` | The four inputs, the two phases, and the teardown script |
| `advise/` | The decision-led design path when there is nothing to assess |
| `codex/` | Blueprints (target state), playbooks (how to build), runbooks (when it breaks) |
| `codex/diagrams/` | 97 diagrams, grouped by architecture principle |
| `docs/RULES.md` | Every assessor rule with its recommendation and reference |
| `docs/ARCHITECTURE-REFERENCES.md` | 73 verified Microsoft sources, each with a take-away |
| `docs/VALIDATION.md` | What has been executed, what has not, and what execution found |

---

## 10. Getting help, and helping back

If a command does not behave as written, that is worth reporting - it is how the library gets
better. See [../CONTRIBUTING.md](../CONTRIBUTING.md). Corrections and gaps both go through
issue templates and need no special access.
