# Two-phase deployment

You supply four things. Phase 1 runs once, interactively, as an Entra administrator. Phase 2
runs unattended, as many times as you like.

```
        inputs.json                    Phase 1                        Phase 2
   +------------------+      +--------------------------+     +---------------------+
   | 1 Entra admin    |      | signs in as the admin    |     | signs in AS THE     |
   | 2 subscription   | ---> | creates the Entra        | --> | IDENTITY, no human  |
   | 3 AD admin       |      |   deployment identity    |     | builds everything   |
   | 4 AD basics      |      | grants it RBAC on one RG |     | verifies each step  |
   +------------------+      | writes deployment-       |     +---------------------+
                             |   context.json           |
                             +--------------------------+
```

Phase 1 exists for one reason: most tenants require multi-factor authentication for every ARM
write, so something human has to sign in once. After that, the identity it creates is not
subject to that policy and everything else is automatic.

---

## What you fill in

Copy `inputs.sample.jsonc` to `inputs.json` and set four things:

| # | Input | Why it is needed |
|---|---|---|
| 1 | **Entra global admin** | Phase 1 only. Creates the deployment identity and grants it a role. Never used again. |
| 2 | **Azure subscription** + a `namePrefix` | Where it is built, and the one naming decision you make - every resource name derives from it |
| 3 | **AD admin account** | Domain-joins the storage account. Needs only permission to create an object in the OU below - not Domain Admin |
| 4 | **AD basics** | Domain FQDN, NetBIOS name, the OU for the identity object, and the object type |

Everything else - resource group, storage account, share names, virtual network, subnets, DNS
zones, resolver, vault, backup policy - is derived. See exactly what you will get, before
anything runs:

```powershell
.\Deploy-AfsEnvironment.ps1 -InputFile .\inputs.json -ShowResolved
```

`namePrefix: contoso` in `eastus` produces `rg-contoso-filesync`, `stcontosofs01`,
`sss-contoso-filesync`, `vnet-contoso-filesync`, `dnspr-contoso-eastus`, `rsv-contoso-eastus`.
Override any of them in the `overrides` section if your naming standard differs.

---

## Phase 1 - once

```powershell
.\Phase1-New-DeploymentIdentity.ps1 -InputFile .\inputs.json
```

A browser opens; sign in as the administrator and complete MFA. Then it:

1. Expands your four inputs into the full configuration and prints it.
2. Creates the resource group - which is also the proof that this session may write. If it
   cannot, you get one clear message naming the likely cause instead of a half-built estate.
3. Creates the Entra application and service principal.
4. Grants it Contributor **on that resource group**, not on the subscription.
5. Writes `deployment-context.json` - the resolved configuration plus the identity. This is
   the artifact that joins the two phases.
6. Signs in as the new identity and reads the scope back, so a broken identity is discovered
   now rather than during a build.

For a pipeline, issue no secret at all:

```powershell
.\Phase1-New-DeploymentIdentity.ps1 -InputFile .\inputs.json -Federate -GitHubRepo owner/repo
```

That adds a federated credential, so GitHub Actions authenticates with OIDC and there is no
secret to store or rotate.

**What the administrator needs:** Application Administrator or higher in Entra ID to create
the identity, and Owner on the subscription - phase 1 creates the resource group as well as
granting the role, which User Access Administrator alone cannot do.
Nothing else in this kit needs privilege that high.

---

## Phase 2 - as often as you like

```powershell
.\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf
.\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json
```

No prompts, no browser, no MFA. It signs in as the deployment identity and builds:

| Step | What appears |
|---|---|
| Storage | StorageV2 account: TLS 1.2 minimum, HTTPS only, no public blob access, large file shares on |
| Shares | One per entry, with quota, plus 14-day share soft delete |
| Network | Virtual network and private endpoint subnet, or the existing ones you named |
| Private Link | Private endpoints for the storage account (`file`) and the Storage Sync Service (`Afs`), the `privatelink` zones, and zone groups that keep the records current |
| File Sync | Storage Sync Service and sync group |
| DNS | Azure DNS Private Resolver with a delegated inbound subnet - the address your on-premises DNS forwards to |
| Backup | Recovery Services vault with redundancy and cross-region restore set **before** anything is protected |
| Backup policy | A daily snapshot policy, 60-day retention by default (`backupDailyRetentionDays` in `overrides`) |
| Protection | Every share protected under that policy |
| Lock-down | **Not reachable from the inputs file in this version** ([issue #1](https://github.com/gusitde/azure-filesync-backup-assessment/issues/1)): the build leaves the public paths open. Close them by hand once the private endpoints resolve - `playbook-harden-existing-storage-account` and `playbook-enable-file-sync-private-endpoint-and-cutover` in `../codex/` |

That is 15 steps, counting preflight (the progress counter says 17 - [issue #1](https://github.com/gusitde/azure-filesync-backup-assessment/issues/1)).
The preflight checks the five resource providers the build needs; register any missing one once
as the administrator with `az provider register -n <namespace>`, because the deployment identity
is scoped to one resource group. It is idempotent, so a re-run after a failure continues
rather than starting over, and it ends by printing a verification command for every object it
created - and, when run with `-Context`, by writing the as-built from live reads into
`as-built/`.

You can also run phase 2 without a context, using whatever session you already have:

```powershell
.\Deploy-AfsEnvironment.ps1 -InputFile .\inputs.json -WhatIf
```

---

## Remove it

```powershell
.\Remove-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf
.\Remove-AfsEnvironment.ps1 -Context .\deployment-context.json
```

It deletes the resource group, which is the only reliable way to leave nothing behind. First
it inventories the group and **refuses** if it finds resources your configuration does not
name - pass `-Force` when that is expected. It also disables backup protection with data
deletion first, because a vault will not delete while it protects anything.

---

## The three steps on your own machines

Phase 2 stops at the edge of Azure. Three steps touch machines you own; each has a script
under [../onprem/](../onprem/), each runs a dry run with `-WhatIf`, and each reverses with
`-Remove`. `start.ps1` offers all three under option 11, *Connect your on-premises servers*.

1. **The Azure File Sync agent** - `Install-AfsServerEndpoint.ps1` installs it on the file
   server over PowerShell remoting, registers the server, and creates the sync group, cloud
   endpoint and server endpoint.
2. **On-premises DNS forwarders** - `Set-AfsDnsForwarders.ps1` forwards the **public** zones,
   `file.core.windows.net` and `afs.azure.net`, to the resolver inbound IP the deployment
   printed. Not the `privatelink` zones: a forwarder on one is never consulted, because the
   whole CNAME chain comes back in one answer. It refuses to write until the resolver answers
   with a private address.
3. **The AD DS domain join** - `Join-AfsStorageAccountToAdDs.ps1`, from a domain-joined machine
   with the RSAT Active Directory module. It creates the computer object as the account that
   runs it, so that account needs the create-computer right in the OU from your inputs file.

---

## Files

| File | What it is |
|---|---|
| `inputs.sample.jsonc` | Copy this. The only file you edit |
| `AfsConfig.ps1` | Shared resolver - turns four inputs into the full configuration. Both phases use it, so they cannot disagree |
| `Phase1-New-DeploymentIdentity.ps1` | Phase 1 - identity, RBAC, context |
| `Deploy-AfsEnvironment.ps1` | Phase 2 - the build |
| `Remove-AfsEnvironment.ps1` | Teardown, with a safety inventory |
| `deployment-context.json` | Written by phase 1, consumed by phase 2. Gitignored |
| `deployment-identity.json` | The secret, if one was issued. Gitignored - move it to your secret store |

## Running on Windows

Run from **PowerShell**, not Git Bash. Git Bash rewrites arguments beginning with `/` into
Windows paths, which corrupts Azure resource IDs - they all start with `/subscriptions/`. If
you must use Git Bash, `export MSYS_NO_PATHCONV=1` first.
