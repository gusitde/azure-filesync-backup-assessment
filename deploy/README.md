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
the identity, and Owner or User Access Administrator on the subscription to grant the role.
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

It is idempotent, so a re-run after a failure continues rather than starting over, and it ends
by printing a verification command for every object it created.

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

## What is deliberately still manual

Three things need a human on a specific machine, and automating them badly would fail
confusingly:

1. **The Azure File Sync agent** - install on the file server, register it, create the server
   endpoint.
2. **On-premises DNS forwarders** - point them at the resolver inbound IP the deployment
   printed, for the `privatelink` zones only, never the parent `core.windows.net`.
3. **The AD DS domain join** - run from a domain-joined machine with AzFilesHybrid, using the
   AD admin account and OU from your inputs file.

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
