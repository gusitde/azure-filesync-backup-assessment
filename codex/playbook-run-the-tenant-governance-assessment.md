---
slug: playbook-run-the-tenant-governance-assessment
doc_type: playbook
kind: run-the-tenant-governance-assessment
category: ops
title: Run the tenant policy and governance assessment alongside the File Sync one
summary: Wrap the Azure Governance Visualizer rather than reinventing it, feed it the subscription and tenant from the deployment context, and read its report next to the File Sync assessment.
when_to_use: The question moves from the File Sync estate to the tenant around it - policy, RBAC, management groups, locks, Defender coverage.
applies_to: [ops, devstation]
tags: [governance, azure-policy, rbac, management-group, azgovviz, assessment, contoso]
persona_run: eng-sysops
ticket_kind: ops
status: published
version: 2
execution: assisted
last_verified: 2026-09-04T05:15 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

`Assess-AzFileSyncExport.ps1` answers one question: is this File Sync and Backup estate built
well? It says nothing about the tenant around it. When the customer asks about policy coverage,
who can do what, whether anything is locked, or how the management groups are shaped, that is a
different question - and a mature tool already answers it.

## Reuse before reinvent (GR11)

```yaml
- primitive: Azure Governance Visualizer (AzGovViz)
  path: Invoke-AfsGovernanceAssessment.ps1
  why: policy, RBAC, management group hierarchy, locks, Defender coverage and blueprints are
       already covered by a maintained Microsoft tool; writing eighty more assessor rules to
       reproduce it would be the definition of reinventing
- primitive: deploy/deployment-context.json
  path: deploy/Phase1-New-DeploymentIdentity.ps1
  why: the subscription and tenant come from what was actually built, so the governance report
       covers the right estate rather than whatever the shell's context happened to be
```

## Procedure

1. **Two reports, two questions.** Keep them separate and read them together. `assessment.html`
   judges the File Sync and Backup estate against 94 rules. The governance report judges the
   tenant. Neither subsumes the other, and merging them would blur which finding an owner has
   to act on.
2. **PowerShell 7 is required, and this kit runs on 5.1.** That is not an oversight: the AD DS
   join uses AzFilesHybrid, which Microsoft documents as PowerShell 5.1 only. So the two shells
   coexist and the wrapper shells out. The script finds `pwsh` in three places, in order: the
   `-PwshPath` you pass, a portable copy in `.pwsh7` beside the repository, then PATH.
3. **You may not need an administrator.** Windows Server has no winget, and the PowerShell MSI
   needs local administrator - but the same release ships as a plain zip that needs neither.
   Extract it to `.pwsh7` and the wrapper finds it. That is what unblocks a governance run on a
   locked-down jump box.
4. **Reader at the management group is the whole point.** AzGovViz walks the hierarchy from the
   group you name, defaulting to the tenant root, whose id is the tenant id. Without Reader
   there the run completes and reports almost nothing - which reads like a broken tool rather
   than a missing role, so the wrapper checks first and prints the grant.
5. **Read-only.** Both the wrapper and AzGovViz only read. It is safe to run against a customer
   tenant during an engagement, which is the usual reason to want it.
6. **Where the output goes.** `governance/` beside the other reports, and the wizard's reports
   option lists it labelled `governance` next to `assessment` and `as-built`.

## Steps

```yaml
vars:
  - name: context
    describe: path to deployment-context.json
    required: false
  - name: mg
    describe: management group to assess from; defaults to the tenant root
    required: false
steps:
  - name: dry run
    run: powershell -File Invoke-AfsGovernanceAssessment.ps1 -Context <context> -WhatIf
    verify: five steps listed; PowerShell 7 located; the management group reported readable; the exact pwsh command shown
  - name: get PowerShell 7 without an administrator, if needed
    run: powershell -Command "$r = Invoke-RestMethod https://api.github.com/repos/PowerShell/PowerShell/releases/latest; $a = $r.assets | Where-Object name -like 'PowerShell-*-win-x64.zip' | Select-Object -First 1; Invoke-WebRequest $a.browser_download_url -OutFile $env:TEMP\ps7.zip -UseBasicParsing; Expand-Archive $env:TEMP\ps7.zip -DestinationPath .\.pwsh7 -Force"
    verify: .\.pwsh7\pwsh.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' prints 7.0.3 or later
  - name: confirm the scope is readable before blaming the tool
    run: az account management-group show -n <mg> --query name -o tsv
    verify: prints the management group name; if it fails, grant Reader at that scope first
  - name: run it
    run: powershell -File Invoke-AfsGovernanceAssessment.ps1 -Context <context>
    verify: the run finishes with exit code 0 and governance/ holds an HTML report plus CSV and JSON exports
  - name: read the two together
    run: powershell -File start.ps1
    verify: the reports option lists the governance report beside assessment.html and the as-built
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: run-the-tenant-governance-assessment`
- **CR file:** `change-management/CR-<date>-tenant-governance-assessment.md`
- **Closure:** a governance report exists for the tenant, its findings are triaged alongside the
  File Sync assessment, and anything that overlaps the storage estate is reconciled with the
  guardrails in [[blueprint-azure-files-secure-storage-account]]

## Gate rules

```json
[
  {"rule": "PowerShell 7.0.3 or later is available to the wrapper", "severity": "error", "check": "pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' prints 7.0.3 or higher, from PATH or from .pwsh7"},
  {"rule": "the assessing account can read the management group", "severity": "error", "check": "az account management-group show -n <mg> --query name -o tsv prints the name"},
  {"rule": "the run produced a report", "severity": "error", "check": "governance/ contains at least one .html file written by the run"},
  {"rule": "nothing was changed", "severity": "error", "check": "az monitor activity-log list --start-time <run start> --query \"[?authorization.action!=null && !contains(authorization.action, '/read')].authorization.action\" -o tsv returns nothing for the run window"}
]
```

## Reference

```yaml
- path: Invoke-AfsGovernanceAssessment.ps1
  anchor: "IT DOES NOT MODIFY ANYTHING"
  why: the wrapper, its preflight and the three places it looks for PowerShell 7
- path: codex/blueprint-azure-files-secure-storage-account.md
  anchor: "Governance - Azure Policy guardrails"
  why: the storage guardrails the tenant report should agree with
- path: docs/RULES.md
  anchor: "Storage security"
  why: what the File Sync assessor already covers, so the two reports are read without overlap
```

Azure Governance Visualizer (AzGovViz) 6.7.2, read 2026-09-04: it requires PowerShell 7.0.3 or
later, takes `-ManagementGroupId`, `-OutputPath`, `-SubscriptionId4AzContext` and
`-TenantId4AzContext`, and exports HTML, markdown, CSV and JSON. PowerShell release assets read
from the GitHub releases API on the same date.