---
slug: playbook-hand-the-kit-to-another-engineer
doc_type: playbook
kind: hand-the-kit-to-another-engineer
category: ops
title: Hand the deployment kit to another engineer without sitting next to them
summary: The long-form guide the wizard opens - one self-contained page, a tab per task, the one-way doors called out - so someone who has never seen the kit can run it correctly on their own.
when_to_use: Somebody else is about to run a build, a teardown, or the on-premises steps, and you will not be in the room.
applies_to: [ops, devstation]
tags: [documentation, onboarding, wizard, handover, offline, contoso]
persona_run: eng-sysops
ticket_kind: ops
status: published
version: 1
execution: assisted
last_verified: 2026-09-04T06:40 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

The kit is only as safe as the person driving it. Most of its steps are idempotent and offer a
dry run; a handful are not reversible at all, and two of those are not obviously irreversible
while you are choosing them. A colleague who reads the menu and starts clicking will get a
working environment - and may also pick a storage redundancy they cannot change later.

This entry covers the guide that closes that gap, and how to hand the kit over using it.

## Reuse before reinvent (GR11)

```yaml
- primitive: docs/HOW-TO-USE.html
  path: start.ps1 -> Invoke-HowToUseFlow
  why: one page, no external assets, no build step - so it opens from a file share, a customer
       laptop, or an air-gapped jump box, which is exactly where a handover happens
- primitive: the wizard's own explain/note/warn vocabulary
  path: start.ps1
  why: the guide repeats the wording the reader will see on screen, so the document and the
       tool teach the same thing rather than two overlapping half-truths
- primitive: docs/GETTING-STARTED.md and the codex triple
  path: docs/, codex/
  why: the guide orients and links; it does not restate the reference material, which would
       leave two copies to drift apart
```

## Procedure

1. **Open it from the wizard, not from a path.** `start.ps1` -> *How to use it*. The menu lists
   the ten sections and opens the browser at the one asked for, because "read the DNS part"
   should not mean "open it and hunt".
2. **It is one file, deliberately.** No stylesheet, no script tag, no font, no image - the page
   carries its own CSS and its four diagrams as inline SVG. Copy `docs/HOW-TO-USE.html` onto a
   USB stick and it still renders, which is the whole point of a handover document.
3. **Send someone to the tab, not the top.** Every section is addressable by fragment:
   `HOW-TO-USE.html#connect` for the on-premises steps, `#trouble` for the error table,
   `#teardown` before anyone deletes anything.
4. **Point at the one-way doors first.** The Reference tab lists them in one place: storage and
   vault redundancy, cross-region restore, the Enhanced backup policy, the resource group name,
   a server endpoint path. Redundancy is the one that catches people, because the build sets it
   *before* the first protected item precisely so it can still be chosen.
5. **The DNS section is the one to read in full.** Forwarding a public zone changes name
   resolution for every storage endpoint under that suffix, for every client, not only yours.
   The guide explains why a forwarder on the `privatelink` name looks correct and never fires -
   which is the single most common way this design is got wrong.
6. **The troubleshooting table is evidence, not documentation.** Every message in it came out of
   a real run against a real tenant. When a message is not in the table, that is worth a
   correction rather than a shrug - see `CONTRIBUTING.md`.
7. **Keep it honest.** The guide names the 17 build steps, the 10 menu options and the 10 tabs.
   Change the wizard and change the guide in the same commit, or the first thing a new engineer
   learns from it is that it cannot be trusted.

## Steps

```yaml
vars:
  - name: guide
    describe: path to the guide, normally docs/HOW-TO-USE.html
    required: false
steps:
  - name: open it the way the reader will
    run: powershell -File start.ps1
    verify: the first menu entry is "How to use it"; choosing it lists ten sections and opens the browser
  - name: confirm the guide still matches the tool
    run: powershell -File tests/run-tests.ps1
    verify: section 5 reports 10 tabs, every tab backed by a section, every section offered by the wizard, no external asset fetched, four closed diagrams with unique marker ids; section 6 reports start.ps1 parses clean; the run ends ALL GREEN
  - name: hand it over
    run: copy docs\HOW-TO-USE.html <wherever the other engineer will read it>
    verify: it opens and renders on a machine with no access to this repository
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: hand-the-kit-to-another-engineer`
- **CR file:** `change-management/CR-<date>-kit-handover.md`
- **Closure:** the receiving engineer has completed a dry run of the build and of the teardown
  on their own, without asking what an option does, and can name the one-way doors from
  [[blueprint-azure-files-secure-storage-account]] and
  [[blueprint-azure-files-backup-protection]] before touching either

## Gate rules

```json
[
  {"rule": "the guide ships with the kit and the wizard opens it", "severity": "error", "check": "powershell -File tests/run-tests.ps1 prints PASS for 'docs/HOW-TO-USE.html ships with the kit', 'the wizard menu offers it' and 'the flow behind the menu entry exists'"},
  {"rule": "every section the menu offers exists, and every tab has a section", "severity": "error", "check": "powershell -File tests/run-tests.ps1 prints PASS for 'every tab button has a section behind it' and 'every section the wizard offers exists in the page'"},
  {"rule": "it renders with no network", "severity": "error", "check": "powershell -File tests/run-tests.ps1 prints PASS for 'no external asset is fetched'"},
  {"rule": "the diagrams are intact", "severity": "error", "check": "powershell -File tests/run-tests.ps1 prints PASS for 'every <svg> is closed', 'all four diagrams are present' and 'arrowhead marker ids are unique across diagrams'"},
  {"rule": "the wizard it documents still runs", "severity": "error", "check": "powershell -File tests/run-tests.ps1 prints PASS for 'start.ps1 parses clean' and exits 0"}
]
```

## Reference

```yaml
- path: docs/HOW-TO-USE.html
  anchor: "The mistake almost everyone makes"
  why: the DNS explanation that stops a forwarder being pointed at the privatelink zone
- path: start.ps1
  anchor: "function Invoke-HowToUseFlow"
  why: the menu entry, the ten addressable sections and the fallback when no browser is set
- path: codex/playbook-point-on-premises-dns-at-the-private-resolver.md
  anchor: "## Procedure"
  why: the executable form of what the Connect tab explains in prose
- path: docs/GETTING-STARTED.md
  anchor: "Dependencies"
  why: the reference the guide links to rather than restating
```

The guide states no fact this repository has not already verified: the build step count comes
from `deploy/Deploy-AfsEnvironment.ps1`, the error table from runs recorded in
`docs/VALIDATION.md`, and every Azure behaviour it cites is carried by the blueprint or playbook
it links to. It is an orientation layer over the codex, not a second source of truth.
