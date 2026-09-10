# Luca AZ Consulting Helper - Version Control

**By Gustavo Assuncao**

This document is the product's change ledger - every feature, fix, and document change is recorded
here like a commit + pull-request history. **A change is not finished until it is recorded here.**

Same scheme as the sibling Server-Ops product, deliberately: a person who has kept one of these
ledgers can keep the other without being told how.

---

## Versioning scheme

`V YYYY.MM.DD.NNN`

- `YYYY.MM.DD` - the date of the change
- `NNN` - the ordinal of the change on that day (`001` = first change of the day; resets daily)
- The stamp lives in **one place in code**: `deploy\AfsLog.ps1` (`$script:AfsProductVersion`),
  read through `Get-AfsProductInfo`. The banner, the run logs, the as-built documents and any
  shipped zip all read it from there. There is no second copy to fall out of step.

## The change-reporting process (mandatory)

Every change to the product - wizard, deployment phase, on-premises script, assessor rule,
codex entry, or document - follows the same three steps, exactly like a commit + PR:

1. **Bump the stamp** in `deploy\AfsLog.ps1`
   (same day -> increment `NNN`; new day -> new date + `001`).
2. **Record the change** as a new row at the TOP of the Change Log below:
   `Version | Date | Type | Component | Description | Author`.
   - `Type` is conventional-commit style: `feat` (new capability), `fix` (defect repair),
     `docs` (documentation), `test` (certification/validation), `chore` (housekeeping).
   - The Description states WHAT changed and WHY - readable by someone who wasn't in the room.
3. **Validate before you ship it**: parse-check every touched file
   (`[System.Management.Automation.Language.Parser]::ParseFile`), run `tests\run-tests.ps1`
   to green, and run the relevant proof - a `-WhatIf` dry run for deploy/teardown/on-premises
   changes, a fixture assessment for assessor-rule changes, and
   `codex\import-to-luca.mjs --dry-run` for codex changes.

Releases (a zip shipped to a customer) reference the stamp they were cut at, in the Releases
table at the bottom.

**Why this exists.** The kit builds and deletes real infrastructure in a customer tenant. When
something behaves unexpectedly six weeks from now, the first question is "which version, and what
changed in it?" A ledger answers that in seconds; `git log` alone answers it in an afternoon, and
only for someone with the repository in front of them.

---

## Change Log

| Version | Date | Type | Component | Description | Author |
|---|---|---|---|---|---|
| V 2026.09.10.002 | 2026-09-10 | docs | Documentation | README rebuilt as a landing page for two readers. For a buyer: why teams use it, what you get, how the pieces fit, what it builds, what has been proven. For an engineer: a five-minute offline start, the 14 options grouped by job with what each one changes, and what is in the box. Two Mermaid diagrams, and screenshots of the wizard and of a report taken from the synthetic fixture, under `docs/img/`. New `docs/USER-GUIDE.md`: a first-hour tutorial (install, test, sample report, the wizard, four jobs start to finish, and how to tell it works); every menu option (what you will be asked, what it runs, what you see when it worked, what to do when it did not); logs and levels; a troubleshooting table; known behaviour and limitations; how it works; how to maintain the kit. New `docs/SCRIPT-REFERENCE.md`, split out of it because one file was too large to render comfortably: every script's parameters, examples, output and failures, and the settings file `deploy\inputs.json` with every override and derived name. Every statement was checked against the code, not against the older documents. That check found places where the kit behaves differently from what the documents said. The guide describes what the kit does, and the code defects are issue #3. One of them: a fresh clone fails nine checks until `python fixtures\make-fixture.py` runs, because `.gitignore` excludes the fixture's server bundle. GETTING-STARTED now points to the guide and no longer says every flow runs a dry run first. Printed text and documents only - no behaviour changed. | Gustavo Assuncao |
| V 2026.09.10.001 | 2026-09-10 | docs | Documentation | README rewritten as the front page: every capability in one table, a *make it work* path per job (machine, access, assess, build, connect, protect and restore, governance, advise, remove), a *how to tell it works* table giving the command and the answer that means working for each layer, what has and has not been proven against live Azure, the decisions that are expensive to reverse, and the layout. Every count re-measured from the tree: 195 checks, 94 rules, 15 build steps, 14 menu options, 25 codex entries. Contradictions fixed where they misled an operator: PROOF-OF-WORK and VALIDATION still said nothing had been built, although the lab build, the agent install and sync, the AD DS join and an item-level restore round trip all ran on 2026-09-03/04; GETTING-STARTED, deploy/README, AS-BUILT-TEMPLATE, the assessment playbook, the as-built generator and the wizard's closing message still said to forward the `privatelink` zones, which are never consulted - the public zones are what `onprem\Set-AfsDnsForwarders.ps1` forwards; the wizard, phase 2, the as-built and HOW-TO-USE cited menu numbers from before the menu grew to 14 (connect is 11, not 7). Two leftover real names replaced with Contoso ones (a ledger row and a code comment). The same text is corrected in advise/ (D-10, build step 1.4 and gate 1) and in three codex entries: `blueprint-azure-dns-for-private-endpoints` v3, `blueprint-azure-file-sync-private-path` v2 and `playbook-enable-file-sync-private-endpoint-and-cutover` v2 (`playbook-run-the-tenant-governance-assessment` v2 for its rule count). Printed text and documents only - no behaviour changed. The diagrams that still draw a `privatelink` forwarder (16 files, two inline diagrams and one ASCII sketch) are issue #2, because every diagram needs a render check. An adversarial fact-check also found documents promising behaviour the code lacks; they now say what it does - the lock-down is not reachable from the inputs file, provider registration needs subscription-level rights, server bundles are read only from an unzipped export, phase 1 needs Owner - and the code defects are issue #1. | Gustavo Assuncao |
| V 2026.09.04.011 | 2026-09-04 | feat | Requirements | Two more areas, both checking things this machine cannot see: **DNS servers** (which route the forwarder script will take, whether each named server answers WinRM, whether it will let you read its zones, whether an existing forwarder already points somewhere else, and whether every resolver the clients use is actually in the list) and the **AD DS join** (a writable DC answering ADWS, whether the OU *and its parent* exist, the create-computer right in it as the account that will run the join, a leftover object holding the SPN, clock skew against the DC, and the storage account's identity source). Run against the live estate: 41 checks, and it found a real blocker nobody had noticed - `OU=AzureFiles,OU=Servers,DC=corp,DC=contoso,DC=com` does not exist and neither does its parent, which the join would have reported as a permissions failure. | Gustavo Assuncao |
| - | 2026-09-04 | fix | Requirements | Three false blockers, each of which would have stopped a run on no evidence: an unresolvable DNS server was reported as WinRM-missing, an unreachable domain as having no writable DC, and (found by an adversarial audit of the generated code) a session failure as a proven credential problem. All three are now `unknown`. Windows' own wording makes the case - "The specified domain either does not exist or could not be contacted" refuses to say which, and neither should the check. | Gustavo Assuncao |
| V 2026.09.04.010 | 2026-09-04 | feat | Requirements | The check answered "what is installed on this machine", which is smaller than "will this run succeed" - and it returned `$true` while warning that the forwarder step would fail. New `deploy\AfsRequirements.ps1` adds the rest: the five resource providers, whether the signed-in account can create the **role assignment** a cloud endpoint needs (Contributor cannot), and the **file server itself** - OS build, .NET 4.7.2, WinRM on 5985 specifically (the kit has no `-UseSSL`), Task Scheduler, Az modules on the server, each endpoint path being local NTFS off the system volume, and the half-removed-agent state that cost twenty minutes today. Three states, not two: `unknown` is first-class, because reporting "I could not check" as ok is worse than not checking. Only a proven-missing blocker stops a run; an unknown one is counted and named. Menu 7 is now "Check requirements". | Gustavo Assuncao |
| V 2026.09.04.009 | 2026-09-04 | fix | Wizard | A report written before the subject tabs opened with a 10-entry menu while the documentation described 13 tabs, and nothing on screen explained the gap - an operator typed a number that did not exist. The results flow now detects a report with no subject tabs, says so, and offers to rebuild it from the export path the report records in its own `findings.json`. A test asserts the wizard's subject list matches the renderer's exactly, so adding a tab cannot silently rot the detection. Also fixed an `int + string` concatenation in the new branch that would have thrown on success. | Gustavo Assuncao |
| V 2026.09.04.008 | 2026-09-04 | fix | Assessment | **Every customer's report told them to align retention with Contoso's records schedule.** Six rule recommendations hardcoded the example customer name - SEC-07, SEC-14, DATA-01, BKP-01, BKP-05, NET-01 - so it appeared in the findings, the roadmap and the rule catalog of any assessment regardless of `-CustomerName`. The rules now carry a `{customer}` token substituted once at the catalog, before anything reads it, falling back to "your" when no name is given. Tested: with a name it reads "Northwind Traders records schedule", without one "your records schedule", and no token survives into the markdown, the HTML or the catalog. | Gustavo Assuncao |
| V 2026.09.04.007 | 2026-09-04 | feat | Assessment | A tab per subject in `assessment.html`, each with its own inline-SVG diagram: Storage, File Sync, Backup, Network, Servers, Guardrails, Export. The report previously carried findings and a scope summary; it now carries the estate itself, so a reviewer can check a verdict against the evidence without opening the raw JSON. 13 tabs, 11 diagrams, 71 tables, 324 KB, no external assets. Each renderer is its own file under `render\` and is isolated - a tab that failed would be replaced in place, leaving the rest of the report readable. | Gustavo Assuncao |
| V 2026.09.04.006 | 2026-09-04 | feat | Wizard | Renamed to **Luca AZ Consulting Helper** (owner, 2026-09-04). One line in `deploy\AfsLog.ps1`, which is the point of keeping the stamp in a single place; the banner, run logs and documents all followed. The 2026-09-03 ledger row keeps the old name because it records what was actually done that day. | Gustavo Assuncao |
| - | 2026-09-04 | feat | Wizard | Deployment settings now names the settings file on screen every time, and offers "Edit the JSON file directly" - open it, open its folder, open the annotated sample, or check that it still parses. The parse check is the useful one: a hand-edited file that does not parse otherwise fails halfway through a build. Verified against a trailing comma and an unescaped Windows backslash (the two usual causes) and against a half-filled file, which correctly reports parses-but-does-not-resolve-yet. | Gustavo Assuncao |
| V 2026.09.04.005 | 2026-09-04 | feat | Wizard | "See the assessment results" - a menu option that finds every assessment.html, names each by the customer read out of the report, and opens the whole report or any single tab by fragment. It also prints the severity counts and the top High findings in the terminal, for when a browser is not what you want. The tab list is read from the report rather than hard-coded, so a report made before a tab existed still opens and adding a tab needs no wizard change. | Gustavo Assuncao |
| - | 2026-09-04 | test | Wizard | Two checks that would have caught today's defects: the report's tabs must come back individually (a `return ,$x` whose caller also wraps in @() gives Count=1 and silently flattens every field - that shipped once already today), and every menu option must have exactly one switch branch with indices 0..n-1. The menu has been renumbered twice today and one of its entries is "Remove an environment". Both verified against deliberately broken input. | Gustavo Assuncao |
| V 2026.09.04.004 | 2026-09-04 | fix | Governance | Report what THIS run produced, not what is in the folder. The collect step listed every file in `governance/` as `[ok]`, so a what-if presented a previous assessment as its own output - and, far worse, a real run that produced nothing did the same, making a failed assessment look successful against stale data. It now stamps the start of the run and classifies by write time: fresh files are output, older ones are named as leftovers with their date and an explicit warning not to read them as current. | Gustavo Assuncao |
| V 2026.09.04.003 | 2026-09-04 | fix | Wizard | The prerequisite check called a missing RSAT DnsServer module "not fatal" because the forwarder script falls back to remoting. That fallback needs WinRM rights ON the domain controller, which a normal domain account does not have, so in practice it fails - as it did on 2026-09-04. The check now states it as a prerequisite, gives both install commands, and points at the credential prompt as the other half. | Gustavo Assuncao |
| V 2026.09.04.002 | 2026-09-04 | fix | Wizard | Splat a HASHTABLE, not an array. `@('-Context', $path)` binds positionally, so the literal string `-Context` landed in `$Context` - the governance option failed with "Deployment context not found: -Context" whenever a deployment context existed, and the assess option carried the identical defect unnoticed because nothing exercised it end to end. Both fixed, `$args` renamed off the automatic variable, and a static AST check added that flags any splatted variable built as an array of switch names. Verified by running the check against the pre-fix file: it reports all three sites. | Gustavo Assuncao |
| - | 2026-09-04 | docs | Codex | `runbook-file-sync-agent-install-and-registration-failures` - the MSI exit-code table, the half-removed-agent signature, and why a timeout is not a failure. DNS playbook gains the two prerequisites the live run exposed: the RSAT DnsServer module, and an account that may read zones. | Gustavo Assuncao |
| V 2026.09.04.001 | 2026-09-04 | chore | Product | Adopt the `V YYYY.MM.DD.NNN` scheme and this ledger, with the stamp in `deploy\AfsLog.ps1` as the single source. Branded banner in the lucaexpress.com indigo, truecolour where the console supports it and the Server-Ops Cyan everywhere else, so the two products read as one family. | Gustavo Assuncao |
| - | 2026-09-04 | fix | On-premises | DNS forwarders: name the actual failure. Reading zones failed and the message blamed the DNS role, reachability and group membership - none of which was true; the RSAT DnsServer module simply was not installed, so the cmdlet did not exist. Both routes now keep their error and the throw translates it, including the access-denied case that means "use -Credential". | Gustavo Assuncao |
| - | 2026-09-04 | fix | On-premises | Agent install: refuse to start while the previous agent's file system filter is still loaded awaiting a restart - that install cannot succeed and fails with MSI 1603. Detect a failed installer task within seconds instead of waiting out the 20-minute timeout, translate the MSI exit code, and surface the log lines that name the cause rather than the last 25 lines of teardown. | Gustavo Assuncao |
| - | 2026-09-04 | fix | Wizard | Discard keystrokes typed while a step was running. A twenty-minute step left buffered input that the next prompt swallowed instantly, answering a question that had not been asked - on a menu whose entries include Remove an environment. | Gustavo Assuncao |
| - | 2026-09-04 | fix | Wizard | Separate an example from a default. A remembered answer is offered and Enter takes it; an invented example is shown only, so Enter can never commit to a server or folder that does not exist. | Gustavo Assuncao |
| - | 2026-09-04 | feat | Documentation | `docs\HOW-TO-USE.html` - the long-form guide the wizard opens as its first option. Ten tabs, four inline SVG diagrams, the real error messages. One self-contained file, so it renders from a file share or a locked-down laptop. | Gustavo Assuncao |
| - | 2026-09-04 | feat | Wizard | Pre-fill the on-premises prompts from `inputs.json`, and write answers back, so the file server, folders and DNS servers are typed once and their expected format is always visible. | Gustavo Assuncao |
| - | 2026-09-04 | feat | Logging | Time every step, print where the time went, and stop Verbose burying the run in Azure CLI chatter. | Gustavo Assuncao |
| - | 2026-09-04 | feat | Wizard | Deployment settings editor - resource group, region, network, backup and directory, with derived values marked and overridable. Plus three teardown defects the live wipe exposed. | Gustavo Assuncao |
| - | 2026-09-04 | fix | Teardown | The safety check knew nothing about the private DNS zones, so it refused to proceed against resources it had created itself. | Gustavo Assuncao |
| - | 2026-09-04 | feat | Governance | Wrap the Azure Governance Visualizer and run it from the wizard, fed the subscription and tenant from the deployment context. | Gustavo Assuncao |
| - | 2026-09-04 | feat | As-built | Topology diagram, teardown tab, and a machine-readable manifest carrying the teardown order. | Gustavo Assuncao |
| - | 2026-09-03 | feat | Wizard | Name it Luca Az-Deploy plus. | Gustavo Assuncao |
| - | 2026-09-03 | fix | On-premises | AD DS join runs end to end - credential for the OU, module loaded before the idempotency check, and a real message when a prompt is impossible. | Gustavo Assuncao |
| - | 2026-09-03 | feat | On-premises | The three steps that run on your own machines - agent and server endpoint, DNS forwarders, AD DS join. | Gustavo Assuncao |
| - | 2026-09-03 | fix | CLI | Bypass the `az.cmd` wrapper, read lists as JSON, pin the subscription. Wizard resume verified live. | Gustavo Assuncao |
| - | 2026-09-03 | feat | Deployment | HTML findings report, generated as-built, backup protection, resume/retry, and the fixes the live build exposed. | Gustavo Assuncao |
| - | 2026-09-03 | feat | Deployment | Two-phase deployment driven by four operator inputs. | Gustavo Assuncao |
| - | 2026-09-03 | feat | Logging | Run logging with levels, telemetry and streaming, wired into the wizard and every deploy script. | Gustavo Assuncao |
| - | 2026-09-03 | feat | Wizard | Guided `start.ps1`, with the two defects mock-testing found. | Gustavo Assuncao |
| - | 2026-09-03 | feat | Assessor | Azure File Sync and Azure Backup assessment and advisory kit - initial release. | Gustavo Assuncao |

**Rows dated before the scheme was adopted carry `-` in the Version column.** They are the git
history, recorded here so the ledger is complete from the first commit rather than from the day
it was introduced. Everything from `V 2026.09.04.001` onward carries a stamp.

---

## Releases

A release is a zip handed to someone outside the repository. It names the stamp it was cut at,
what changed since the previous one, and what was verified before it went.

| Release | Stamp | Date | Contents | Verified by |
|---|---|---|---|---|
| _none yet_ | - | - | - | - |

### Cutting a release

1. The Change Log is current and the stamp is bumped.
2. `tests\run-tests.ps1` is green.
3. `codex\import-to-luca.mjs --dry-run` reports 0 errors.
4. A build and a teardown have each been dry-run since the last change to either.
5. Generated folders are excluded - `as-built\`, `logs\`, `governance\`, `deploy\inputs.json`
   and `deploy\deployment-context.json` name real resources and real tenants, and never ship.
6. Record the row above.
