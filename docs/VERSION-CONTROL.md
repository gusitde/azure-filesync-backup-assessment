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
