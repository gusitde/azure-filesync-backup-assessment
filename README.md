# Azure File Sync and Azure Backup - assess, design, build, prove

**Luca AZ Consulting Helper** (`V 2026.09.10.001`) is a PowerShell kit and a reference library
for one kind of estate: Windows file servers syncing to Azure file shares over a private path,
with Azure Backup protecting the data. It reviews an estate that already exists, designs one with
a customer who will not share their configuration, builds one from four inputs, connects your
own servers to it, and shows you - with a command and the answer to expect - that each piece
actually works.

Measured from this repository at that stamp: **195** offline test checks green, **94** assessor
rules, a **15**-step build, a **14**-option guided menu, **25** codex entries and **97** diagrams.

**Contents:** [What it can do](#what-it-can-do) - [Quick start](#quick-start) -
[Make it work](#make-it-work) - [How to tell it works](#how-to-tell-it-works) -
[Proven against live Azure](#proven-against-live-azure) - [When it goes wrong](#when-it-goes-wrong) -
[Decisions that are expensive to reverse](#decisions-that-are-expensive-to-reverse) -
[Repository layout](#repository-layout) - [Accuracy and contributing](#accuracy-and-contributing)

## What it can do

| Capability | What you get | Where | Changes |
|---|---|---|---|
| **Assess** an existing estate | A read-only export of File Sync, storage accounts, Azure Backup, private endpoints, private DNS, the ExpressRoute topology and alert rules; 94 rules applied offline; a scorecard, findings with the evidence and a Microsoft reference for each, and a roadmap - as `assessment.md`, `findings.json` and a self-contained 13-tab `assessment.html` | `Export-AzFileSyncEnvironment.ps1`, `Assess-AzFileSyncExport.ps1` | nothing - ARM `GET` calls only |
| **Diagnose a file server** | Agent version, services, volumes, filter drivers, sync errors, network tests and telemetry events, as one zip per server, with an optional tiered-file census | `Get-AfsServerDiagnostics.ps1` | nothing |
| **Assess governance** | Policy assignments, RBAC, the management-group tree, locks and Defender coverage across the tenant, by wrapping the Azure Governance Visualizer | `Invoke-AfsGovernanceAssessment.ps1` | nothing |
| **Advise** when there is nothing to assess | 18 design decisions, each with a default, a reason and a reversal cost; a two-hour session guide; the export asked as interview questions; a gated build sequence | [advise/](advise/) | nothing |
| **Build** a new environment | Storage account and shares, virtual network, private endpoints for Azure Files and for File Sync, both private DNS zones, a DNS Private Resolver, the Storage Sync Service, a Recovery Services vault, a daily backup policy with 60-day retention, and every share protected | [deploy/](deploy/), in two phases | one resource group and one Entra application |
| **Connect your servers** | Install the File Sync agent, register the server and sync a folder; forward on-premises DNS to the resolver; domain-join the storage account for AD DS authentication | [onprem/](onprem/) | your file server, DNS and Active Directory |
| **Prove it** | A requirements check before you start, a what-if before every write, a verify command for every object afterwards, an as-built generated from live reads, and a restore test | `start.ps1` options 8 and 13, `deploy/Export-AfsAsBuilt.ps1` | nothing |
| **Remove it** | A teardown that inventories first and refuses to delete what it did not build | `deploy/Remove-AfsEnvironment.ps1` | the resource group |
| **Look it up** | 7 blueprints (target state), 13 playbooks (how to build, including handing the kit to another engineer), 5 runbooks (when it breaks), 97 diagrams, [73 verified Microsoft references](docs/ARCHITECTURE-REFERENCES.md), and a one-page offline guide | [codex/](codex/), [docs/](docs/) | - |

## Quick start

```powershell
git clone https://github.com/gusitde/azure-filesync-backup-assessment.git
cd azure-filesync-backup-assessment
.\start.ps1
```

Run it from **Windows PowerShell 5.1** in an ordinary PowerShell window - not Git Bash, which
corrupts Azure resource IDs. If Windows refuses to run the script, allow it for this window
only with `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`. Then choose **8, Check
requirements** - it reports what is missing and the exact command to fix each gap before anything
changes - and **1, How to use it** for the offline guide, [docs/HOW-TO-USE.html](docs/HOW-TO-USE.html).
Every step that changes something shows a dry run first and asks before it goes ahead.

| # | Menu option | What it does |
|---|---|---|
| 1 | How to use it | Opens the offline guide at the tab you pick |
| 2 | Deployment settings | Edits `deploy/inputs.json` - names, region, network, backup, directory - and marks which values are derived |
| 3 | Build a new Azure File Sync environment | Phase 1 (the identity), then phase 2 (the build), dry run first |
| 4 | Assess an existing environment | Export, optional server diagnostics, assess |
| 5 | See the assessment results | Opens any tab of a report, or prints the severity counts and top findings in the terminal |
| 6 | Assess policy and governance across the tenant | Runs the governance wrapper |
| 7 | Remove an environment I built | The teardown, dry run first |
| 8 | Check requirements | This machine, Azure, your DNS servers, AD DS and the file server. Read-only |
| 9 | Read the documentation | Every guide, with what each one is for |
| 10 | Browse the blueprints, playbooks and runbooks | The codex library |
| 11 | Connect your on-premises servers | Agent and server endpoint, DNS forwarders, AD DS join, dry run first |
| 12 | Resume the last build | A dry run, then the build again - it is idempotent; up to five attempts, asking before each retry |
| 13 | Open the findings and as-built reports | Every report produced so far, or generate the as-built now |
| 14 | Quit | |

Every run writes `logs\<run>.log`, a `.jsonl` copy for tooling and a console transcript. Add
`-LogLevel Debug` for full Azure CLI traces, or `-LogLevel Quiet` for warnings and errors only.

## Make it work

### 1. The machine

| You need | For | How to get it |
|---|---|---|
| Windows PowerShell 5.1 | everything; the AD DS join runs only on 5.1 | built into Windows |
| Azure CLI (tested with 2.84.0) | build, teardown, on-premises steps, as-built | `winget install --exact --id Microsoft.AzureCLI`, or <https://aka.ms/installazurecliwindows> |
| The `dns-resolver` CLI extension | the DNS Private Resolver step | `az extension add --name dns-resolver` - the build's preflight installs it if it is missing |
| `Az.Accounts` | the export | `Install-Module Az.Accounts -Scope CurrentUser` |
| `Az.Storage`, `Az.StorageSync` | registering a server, creating its endpoints, closing the File Sync public path | `Install-Module <name> -Scope CurrentUser` |
| `Az.RecoveryServices` | the restore procedure in the codex runbook (the CLI's `az backup restore restore-azurefiles` also restores single files) | `Install-Module Az.RecoveryServices -Scope CurrentUser` |
| RSAT Active Directory module | the AD DS join | once, elevated: `Install-WindowsFeature RSAT-AD-PowerShell` (Windows Server) or `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` (Windows client) |
| RSAT DNS Server module | the DNS forwarders | once, elevated: `Install-WindowsFeature RSAT-DNS-Server` or `Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0` |
| PowerShell 7 | governance only | `pwsh` on the path, or a portable copy unzipped into `.pwsh7\` - no administrator needed |
| PowerShell remoting (WinRM, HTTP port 5985) to the file server | the agent install | the requirements check reads the rest from the server: OS build, .NET 4.7.2, and that each folder is on a local NTFS volume other than the system drive |

Installing the two RSAT modules is the only step that needs local administrator on your own
machine, and only once.

### 2. The access

| Step | Who runs it | What that account needs |
|---|---|---|
| Export | anyone | **Reader** on the subscriptions in scope |
| Assess | anyone | nothing - it reads the export offline |
| Governance | anyone | **Reader** at the management group (the tenant root by default) |
| Build, phase 1 - once | an Entra administrator, interactively, with MFA | **Application Administrator** or higher in Entra ID, and **Owner** on the subscription - phase 1 creates the resource group as well as granting a role, and User Access Administrator alone cannot create it. Register the five resource providers now too (see step 4) |
| Build, phase 2 - as often as you like | the deployment identity phase 1 creates | **Contributor on the one resource group** - phase 1 grants exactly that |
| Create a cloud endpoint (part of connecting a server) | you | the right to create role assignments on the storage account - **Owner**, **User Access Administrator** or **Azure File Sync Administrator**. Contributor is refused, because the endpoint grants the File Sync service a role |
| Forward DNS | you, or `-Credential` | the right to create zones on the DNS servers (DnsAdmins or equivalent) |
| AD DS join | you | permission to create a computer object in the target OU - **not** Domain Admin. Delegate it with `dsacls "<OU DN>" /I:T /G "<DOMAIN>\<user>:CC;computer"` |
| File server | you, or `-Credential` | local administrator on the server |

**If a write fails with `RequestDisallowedByAzure ... without authenticating through MFA`**, the
session signed in without multi-factor and no role will fix it: run `az logout`, then `az login`
and complete the prompt. If the CLI prints an `az login --scope ... --claims-challenge ...`
command, run exactly that one - a plain `az login` reuses the cached token.

### 3. Assess an existing estate (read-only)

```powershell
Install-Module Az.Accounts -Scope CurrentUser                  # once
Connect-AzAccount -Tenant <tenant-id>                           # an account with Reader
.\Export-AzFileSyncEnvironment.ps1                              # every enabled subscription; -SubscriptionId <id> to narrow
.\Get-AfsServerDiagnostics.ps1 -OutputPath C:\temp              # optional, on each file server, elevated; -SampleTieredFiles adds a tiered-file census
.\Assess-AzFileSyncExport.ps1 -ExportPath .\afs-export-<stamp> -CustomerName "Contoso"
```

`-ExportPath` takes the export folder or its zip. With server bundles, put each server zip in
`servers\<hostname>\` inside the export **folder** (unzip the export first if you only have the
zip) and assess the folder - a zip passed to the assessor never contains `servers\`
([#1](https://github.com/gusitde/azure-filesync-backup-assessment/issues/1)). Add
`-PrivateTrafficRequired` when sync must stay on ExpressRoute or another private path - it turns
on the private-network rules and escalates the public-path findings. `-ListRules` prints the
catalogue, also in [docs/RULES.md](docs/RULES.md). The export carries resource names and
settings - no file data, no keys, no SAS tokens - and a redaction pass blanks well-known secret
fields anyway. Walk-through: [docs/PLAYBOOK-azure-file-sync-assessment.md](docs/PLAYBOOK-azure-file-sync-assessment.md).

### 4. Build a new environment

You enter four things; everything else is derived from them.

```powershell
cd deploy
Copy-Item inputs.sample.jsonc inputs.json                                   # then fill in the four inputs below
.\Deploy-AfsEnvironment.ps1 -InputFile .\inputs.json -ShowResolved          # every name it will use; calls nothing
.\Phase1-New-DeploymentIdentity.ps1 -InputFile .\inputs.json                # once, as the administrator, with MFA
.\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf      # the real preflight, then every step; changes nothing
.\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json              # unattended, as the deployment identity
```

| # | Input | Why it is asked |
|---|---|---|
| 1 | Entra administrator and tenant | Phase 1 only: creates the deployment identity and grants it Contributor on the resource group |
| 2 | Subscription, region and a short `namePrefix` | Every resource name derives from it: `contoso` in `eastus` gives `rg-contoso-filesync`, `stcontosofs01`, `sss-contoso-filesync`, `rsv-contoso-eastus` and so on |
| 3 | AD admin account | For the domain join. It needs the create-computer right in the OU, not Domain Admin |
| 4 | AD basics | Domain FQDN, NetBIOS name, the OU and the object type |

Phase 1 proves the session may write by creating the resource group, creates the identity, grants
it Contributor on that group only, writes `deployment-context.json`, then signs in as the new
identity to prove it works (`-Federate -GitHubRepo owner/repo` issues a GitHub OIDC credential
instead of a secret). **While you are signed in as the administrator, register the five resource
providers** the build needs - `az provider register -n <namespace>` for `Microsoft.Storage`,
`Microsoft.Network`, `Microsoft.StorageSync`, `Microsoft.RecoveryServices` and
`Microsoft.Insights`. Phase 2's preflight checks them, but its identity is scoped to one resource
group and cannot register them.

Phase 2 runs 15 steps: preflight; the resource group, storage account, 14-day share soft delete
and shares; the network and private DNS zones; the storage private endpoint, the Storage Sync
Service and its private endpoint; the resolver; the vault, with its redundancy and cross-region
restore set before anything is protected; the backup policy; and protection for each share. It
is idempotent - fix the cause of a failure and run it again, or use menu option 12 - and it ends
by printing a verify command for every object and writing the as-built. Details:
[deploy/README.md](deploy/README.md).

**Close the public paths by hand, once the private path is proven.** The build leaves them open:
in this version its lock-down step is not reachable from the inputs file
([#1](https://github.com/gusitde/azure-filesync-backup-assessment/issues/1)). When a client on
your network resolves the storage account to a private address (see
[How to tell it works](#how-to-tell-it-works)):

```powershell
az storage account update -g <rg> -n <account> --default-action Deny --bypass AzureServices
Set-AzStorageSyncService -ResourceGroupName <rg> -Name <sss> -IncomingTrafficPolicy AllowVirtualNetworksOnly
```

The checks and the rollback are in
[codex/playbook-harden-existing-storage-account.md](codex/playbook-harden-existing-storage-account.md)
and [codex/playbook-enable-file-sync-private-endpoint-and-cutover.md](codex/playbook-enable-file-sync-private-endpoint-and-cutover.md).
Closing the public path before the private endpoint resolves is the most common way to break sync.

### 5. Connect your on-premises servers

Three steps run against machines you own. Each script under [onprem/](onprem/) is idempotent,
supports `-WhatIf`, and reverses with `-Remove`. Menu option 11 runs them for you, dry run first.

```powershell
# the file server: install the agent, register it, create the sync group, cloud endpoint and server endpoint
.\onprem\Install-AfsServerEndpoint.ps1 -Context .\deploy\deployment-context.json -FileServer fs01 -SharePath 'dept-shares=D:\Shares\dept' -WhatIf

# on-premises DNS: forward the PUBLIC zones to the resolver's inbound address
.\onprem\Set-AfsDnsForwarders.ps1 -Context .\deploy\deployment-context.json -DnsServer dc01,dc02 -WhatIf

# Active Directory: domain-join the storage account for identity-based access
.\onprem\Join-AfsStorageAccountToAdDs.ps1 -Context .\deploy\deployment-context.json -OrganizationalUnit 'OU=AzureFiles,DC=corp,DC=contoso,DC=com' -WhatIf
```

Drop `-WhatIf` to run them for real. Two things decide whether they work:

- **Forward the public zones, not the `privatelink` ones.** A client asks for
  `<account>.file.core.windows.net`, and a recursive resolver returns the whole chain - public
  name, `privatelink` alias, private address - in one answer, so a forwarder on
  `privatelink.file.core.windows.net` is never consulted. The script forwards
  `file.core.windows.net` and `afs.azure.net`, and refuses to write until the resolver is proven
  to answer with a private address, because from then on every lookup under those names depends
  on it.
- **The join creates the AD object as whoever runs it.** `Join-AzStorageAccount` has no
  credential parameter, so the account running the script needs the create-computer right in the
  OU; the script prints the `dsacls` line when it is missing. `-CreateOrganizationalUnit` with
  `-AdCredential` covers an OU that does not exist yet.

### 6. Protect the data, then prove a restore

The build protects every **Azure file share** under a daily snapshot policy (60 days by default,
`backupDailyRetentionDays` in `overrides`). It deliberately does not back up the server: a File
Sync server endpoint is a cache, and a file-level backup agent walking tiered files recalls the
whole dataset. Migrated VMs are a third, separate surface -
[codex/blueprint-azure-vm-backup-for-migrated-servers.md](codex/blueprint-azure-vm-backup-for-migrated-servers.md).

A backup is not protection until a restore has worked:

1. Put a test file in a server endpoint folder and confirm it appears in the Azure file share.
2. Take an on-demand backup of that share and wait for the job to complete.
3. Delete the file on the server and let the delete sync up.
4. Restore the file from the recovery point, to its original place or to another folder. Single
   files come back only from the **snapshot** tier; the vault-standard tier restores whole shares.
5. Force change detection on the cloud endpoint (`Invoke-AzStorageSyncChangeDetection`), so the
   restored file does not wait for the next 24-hour enumeration.
6. Confirm the file is back **on the server** - the step that proves the whole loop.

Commands: [codex/runbook-restore-file-share-and-share-soft-delete.md](codex/runbook-restore-file-share-and-share-soft-delete.md)
and [docs/PLAYBOOK-azure-backup-for-azure-files.md](docs/PLAYBOOK-azure-backup-for-azure-files.md).

### 7. Assess governance

```powershell
.\Invoke-AfsGovernanceAssessment.ps1 -Context .\deploy\deployment-context.json   # or -SubscriptionId <id> -TenantId <id>
```

It feeds the Azure Governance Visualizer the subscription and tenant from your build, first checks
you can read the management group - without Reader there the report comes back nearly empty and
looks like a broken tool - and writes to `governance\`.

### 8. Advise, when there is nothing to assess

Start at [advise/SESSION-GUIDE.md](advise/SESSION-GUIDE.md): a two-hour session that closes the
decisions in [advise/REFERENCE-DESIGN.md](advise/REFERENCE-DESIGN.md), uses
[advise/DESIGN-INTERVIEW.md](advise/DESIGN-INTERVIEW.md) in place of an export, and ends in
[advise/BUILD-SEQUENCE.md](advise/BUILD-SEQUENCE.md) - day 1 to day 90, gated, covering the whole
path a VMware estate takes into Azure.

### 9. Remove it

Do it in this order: Azure refuses to remove a cloud endpoint while a server endpoint still uses
it, and the AD object and the DNS forwarders live outside the resource group.

```powershell
# 1. sync: server endpoints, cloud endpoints, sync groups, then unregister (-UninstallAgent also removes the agent)
.\onprem\Install-AfsServerEndpoint.ps1 -Context .\deploy\deployment-context.json -FileServer fs01 -Remove
# 2. the AD object and the DNS forwarders
.\onprem\Join-AfsStorageAccountToAdDs.ps1 -Context .\deploy\deployment-context.json -Remove
.\onprem\Set-AfsDnsForwarders.ps1 -Context .\deploy\deployment-context.json -DnsServer dc01,dc02 -Remove
# 3. Azure, dry run first
cd deploy
.\Remove-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf
.\Remove-AfsEnvironment.ps1 -Context .\deployment-context.json
```

Share data is never deleted by the on-premises scripts. The teardown inventories the resource
group and refuses if it holds anything your configuration does not name (`-Force` when that is
expected), disables backup protection first, and - where a policy keeps vault soft delete always
on - removes everything else and prints the date the vault can be deleted. The Entra deployment
identity also lives outside the group; the as-built names it and the command to remove it.

## How to tell it works

Each row is a question, the command that answers it, and the answer that means yes. Start at the
top: a green kit on a machine that passes the requirements check rules out most of what can go
wrong before you touch Azure.

| Question | Run | It works when |
|---|---|---|
| Is this copy of the kit intact? | `.\tests\run-tests.ps1` | It ends `ALL GREEN (195 checks)`. It runs offline against a synthetic export and covers the rule catalogue, rule severities, private-traffic mode, zip input, every report tab, the menu wiring and a parse of the wizard |
| Can this machine and account do the run? | menu option **8** | The summary reads `0 blocker(s)` and `everything the run needs is in place.` Anything it could not check is reported as unknown and counted - never as ok |
| What exactly will be built? | `.\Deploy-AfsEnvironment.ps1 -InputFile .\inputs.json -ShowResolved` | Every name, address range and setting is printed, and nothing is contacted |
| Will the build succeed? | `.\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf` | The preflight passes for real - CLI, sign-in, subscription, extension, storage name availability - and every step is listed without anything changing. A dry run neither registers providers nor fails on a missing one; menu option **8** checks them |
| Did the build do what it says? | the `Verify with:` commands phase 2 prints, and `as-built\AS-BUILT-<prefix>-<stamp>.html` | Each verify command returns its object. The as-built is read from Azure after the build, not written from the plan, and its Verify tab gives the read-back command for every row. Regenerate it with `.\deploy\Export-AfsAsBuilt.ps1 -Context .\deploy\deployment-context.json` |
| Do the private endpoints have DNS records? | `az network private-dns record-set a list -g <rg> -z privatelink.file.core.windows.net -o table`, and the same for `privatelink.afs.azure.net` | One A record for the storage account and four for the Storage Sync Service. A zone holding only its SOA means the endpoint resolves publicly |
| Does the name resolve privately from your network? | from an on-premises client: `Resolve-DnsName <account>.file.core.windows.net` and `Test-NetConnection <account>.file.core.windows.net -Port 445` | A CNAME to `<account>.privatelink.file.core.windows.net`, a **private** address, and `TcpTestSucceeded : True`. Only then close the public paths |
| Is the server syncing? | the `Microsoft-FileSync-Agent/Telemetry` event log on the server (also collected by `Get-AfsServerDiagnostics.ps1`) | Event **9102** (sync session complete) with `HResult` 0, and the server's files visible in the share. The portal's sync health lags by about 15 minutes, so read the server first. The agent's `Debug-StorageSyncServer -TestNetworkConnectivity` tests every endpoint - documented by Microsoft, not run in this kit's lab record |
| Does identity-based access work? | `Debug-AzStorageAccountAuth -StorageAccountName <account> -ResourceGroupName <rg> -Verbose` (from AzFilesHybrid), and `az storage account show -g <rg> -n <account> --query azureFilesIdentityBasedAuthentication.directoryServiceOptions -o tsv` | Every check passes and the second command prints `AD`. Running the join again reports that it is already joined |
| Are the shares protected? | `az backup item list --resource-group <rg> --vault-name <vault> --backup-management-type AzureStorage --workload-type AzureFileShare -o table` | Every share is listed as protected under the policy. `IRPending` is normal until the first backup runs |
| Can you get a file back? | the restore test in [step 6](#6-protect-the-data-then-prove-a-restore) | The deleted file is back on the file server |
| Is the governance report current? | menu option **6** | Files written by this run are listed as output; older files in `governance\` are named as leftovers with their date |
| What went wrong in a failed run? | `logs\<run>.log` | The `[ERROR]` line carries the message, the script line that threw, and the stack |

## Proven against live Azure

Before publication, the 89 `az` commands and 48 PowerShell cmdlets in the codex (its 20 entries at
the time) were resolved against the real CLI and modules, and 33 of 36 read-only checks passed
against live resources. Since then the build and the on-premises steps have run for real, on
2026-09-03 and 2026-09-04, in a lab subscription and an on-premises lab with a Windows Server 2022
file server and Active Directory:

- **The two-phase build, end to end** - identity, storage and two shares, both private endpoints
  (the File Sync one with its four names), both private DNS zones with their A records, the
  Storage Sync Service, the resolver, a geo-redundant vault with cross-region restore, the 60-day
  policy and both shares protected. An on-demand backup completed; a second run skipped what
  already existed.
- **The agent and sync** - installed over PowerShell remoting, server registered, sync group and
  both endpoints created, files synced up.
- **The AD DS join** - the storage account joined the domain as a computer object, and
  `Debug-AzStorageAccountAuth` passed its checks.
- **The restore loop** - a folder restored item-level to another location in 78 seconds, and after
  change detection it synced back down to the server.
- **The requirements check** - 41 checks against that estate, including a missing OU the join would
  have misreported as a permissions failure.
- **The teardown** - against a vault whose soft delete a policy keeps always on: everything else
  removed, and the retry date printed.

Running it found defects that reading had not - a DNS zone-group check that passed on an empty
answer so no A records were written, the Windows `az.cmd` wrapper breaking on any `)` in a query,
a shared CLI profile retargeting a build in mid-run, `powershell -File` silently dropping
`-Confirm:$false` - each fixed and recorded in [docs/VALIDATION.md](docs/VALIDATION.md).

**Not claimed as proven live:** the DNS forwarder write (at the time of the lab runs the resolver
was not reachable from on-premises, and the forwarder script refused to write, as designed); the
lock-down; ExpressRoute routing, with no circuit in the lab; and the Azure Migrate and migrated-VM
backup procedures, whose commands resolve but have not been run. Full record:
[docs/PROOF-OF-WORK.md](docs/PROOF-OF-WORK.md). **Known defects** - the unreachable lock-down,
provider registration under the deployment identity, the step counter, server bundles with zip
input - are [#1](https://github.com/gusitde/azure-filesync-backup-assessment/issues/1); diagrams
that still draw a forwarder on a `privatelink` zone are
[#2](https://github.com/gusitde/azure-filesync-backup-assessment/issues/2).

## When it goes wrong

| You see | It means | Do this |
|---|---|---|
| `RequestDisallowedByAzure ... without authenticating through MFA` | The session signed in without MFA. Reads work, writes do not | `az logout`, then `az login` and complete MFA |
| `AuthorizationFailed` creating a cloud endpoint | Contributor cannot create role assignments, and a cloud endpoint creates one | Owner, User Access Administrator or Azure File Sync Administrator on the storage account |
| Preflight waits, then `resource providers did not finish registering in 10 minutes` | The deployment identity cannot register providers - that needs the subscription | Register them once as the administrator: `az provider register -n <namespace>` |
| `-o was unexpected at this time.` | On Windows `az` is a batch file, and a `)` inside an argument - any `--query` with a function call - ends one of its blocks early | Query a plain list and filter in PowerShell. The kit calls the bundled Python directly to avoid it |
| `usage error: --resource ID \| --resource NAME ...` | Git Bash rewrote a resource ID into a Windows path | Run from PowerShell, or `export MSYS_NO_PATHCONV=1` |
| The private endpoint exists but the name resolves publicly | No A records were written | Run phase 2 again, then check with `az network private-dns record-set a list` |
| Sync stops right after a network change | The public path was closed before the private endpoint resolved | Re-open it, prove resolution, close it again - [runbook](codex/runbook-file-sync-broken-after-network-lockdown.md) |
| A run hangs with no output | It is waiting on a prompt no console can answer; `powershell -File` silently drops `-Confirm:$false` | Run from a real console, or use `powershell -Command "& '.\script.ps1' ... -Confirm:$false"` |

More, with the reasoning: [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md#8-when-something-goes-wrong)
and the *When it goes wrong* tab of [docs/HOW-TO-USE.html](docs/HOW-TO-USE.html).

## Decisions that are expensive to reverse

- **Vault storage redundancy and cross-region restore** are fixed once the first item is
  protected; the build sets them before it protects anything. **Vault soft delete set to
  always-on** cannot be switched off, and holds the vault until its retention runs out.
- **Trusted Launch VMs need the Enhanced VM backup policy, and Enhanced cannot go back to
  Standard.** Azure Migrate lands VMs as Trusted Launch by default, so decide it on purpose.
- **Azure Migrate locks the target region and the cache storage account** once replication starts.
  Choose the target resource group, network and subnet at replication time: a network interface
  cannot move between virtual networks afterwards.
- **Forwarding a public DNS zone** makes the resolver a dependency of every name under it - see
  [codex/playbook-point-on-premises-dns-at-the-private-resolver.md](codex/playbook-point-on-premises-dns-at-the-private-resolver.md).

The full list, with the reasons, is in [advise/REFERENCE-DESIGN.md](advise/REFERENCE-DESIGN.md).

## Repository layout

| Path | What it is |
|---|---|
| `start.ps1` | The guided front door - everything is reachable from here |
| `Export-AzFileSyncEnvironment.ps1`, `Get-AfsServerDiagnostics.ps1`, `Assess-AzFileSyncExport.ps1` | Export, per-server bundle, assessor |
| `Render-AfsAssessmentHtml.ps1`, `render/` | The HTML report, with one renderer per subject tab |
| `Invoke-AfsGovernanceAssessment.ps1` | The governance wrapper |
| `deploy/` | The four inputs, both phases, the teardown, the as-built generator, the requirements check and run logging |
| `onprem/` | Agent and server endpoint, DNS forwarders, AD DS join |
| `advise/`, `codex/` | The design path, and the blueprints, playbooks, runbooks and diagrams (`codex/import-to-luca.mjs` imports them into a Luca codex) |
| `docs/` | The offline guide, getting started, the playbooks, rules, references, validation record, proof of work, as-built template and change log |
| `fixtures/`, `tests/` | The synthetic export and the offline test suite |
| Never committed | `deploy/deployment-identity.json` (the deployment identity's **secret**, if one was issued - move it to a secret store), `deploy/inputs.json`, `deploy/deployment-context.json`, `afs-export-*` and other `*.zip`, `assessment-latest/`, `as-built/`, `logs/`, `governance/` - they name real resources and tenants |

## Accuracy and contributing

On 2026-09-03 the codex library - its 20 entries at the time - was fact-checked against Microsoft's
own documentation: 898 technical claims were extracted, an independent pass upheld 62 as errors,
and all 62 were corrected. Today all 25 entries pass the codex validator with 0 errors, all 97
diagrams render, and every reference URL was opened and checked. Re-verify anything that carries a
version, a limit or a module number before quoting it more than a quarter from now. Method and
limits: [docs/VALIDATION.md](docs/VALIDATION.md).

If a command does not behave as written, or something you needed is not here, report it - neither
needs write access. See [CONTRIBUTING.md](CONTRIBUTING.md) for the issue templates and the three
house rules. Every change bumps the stamp in `deploy\AfsLog.ps1` and adds a row to
[docs/VERSION-CONTROL.md](docs/VERSION-CONTROL.md). The scripts are ASCII-only, so Windows
PowerShell 5.1 parses them the same way in every locale; most also carry a UTF-8 byte-order mark.
