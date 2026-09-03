# Advise track - designing the estate when you cannot assess it

This repository has **two doors**. They lead to the same target design and cite the same
codex library; they differ only in where the inputs come from.

| | Door A - **Assess** | Door B - **Advise** (this folder) |
|---|---|---|
| Use when | The customer will export their configuration | The customer will not, cannot, or has nothing to export yet |
| Input | `afs-export-<stamp>.zip` from `Export-AzFileSyncEnvironment.ps1` | Answers to [DESIGN-INTERVIEW.md](DESIGN-INTERVIEW.md), gathered in a session |
| Engine | `Assess-AzFileSyncExport.ps1`, ~80 rules | [REFERENCE-DESIGN.md](REFERENCE-DESIGN.md) defaults, applied by decision |
| Output | `assessment.md` - findings against what exists | A target design, a build sequence, and a decision log |
| Fails when | They say no | They say "just tell us what you would do" - which is what it is for |

**Both doors converge on the codex.** `../codex/` holds the blueprints (what the target looks
like), playbooks (how to build it) and runbooks (what to do when it breaks). Door A tells you
which playbooks to run against an existing estate. Door B tells you which to run against an
empty one.

## Why Door B exists

The assessment playbook states its own premise plainly: the report is *"grounded in the
customer's exported configuration, not in interviews."* That is the right way to review an
estate that exists. It is useless in three common situations:

1. **The customer declines to share configuration.** Public-sector security review, a
   procurement boundary, or simple reluctance. You still owe them a design.
2. **There is nothing to assess yet.** The workloads are still on VMware. The Azure file
   estate does not exist, so there is no export to take.
3. **They asked a build question, not a review question.** "How do we set up Azure File Sync
   and Azure Backup for the VMs we are migrating" is not answered by a findings report.

Contoso is all three at once. Their servers are on VMware and moving to Azure via
Azure Migrate; the file estate and the backup estate are being **created**, not reviewed.

## The four documents

| Document | What it is | When you use it |
|---|---|---|
| [SESSION-GUIDE.md](SESSION-GUIDE.md) | A two-hour working session: agenda, the decisions to close, and the default for each | In the room with the customer |
| [REFERENCE-DESIGN.md](REFERENCE-DESIGN.md) | The prescriptive target design and every default, with the reason and the reversal cost | Before the session, and as the design record after |
| [DESIGN-INTERVIEW.md](DESIGN-INTERVIEW.md) | The full intake - the same inputs the exporter would have produced, as questions | When you need the detail the session did not reach |
| [BUILD-SEQUENCE.md](BUILD-SEQUENCE.md) | Day 1 to day 90, ordered, gated, mapped to codex playbooks | After the design is agreed |

## The rule that makes this defensible

Every default in the reference design is stated as a **decision with a named owner, a
reason, and a reversal cost**. A default the customer never discussed is still a decision
they made by silence - so it is written down as one. When the estate is later assessed with
Door A, the assessor's findings should reconcile against this decision log. A finding that
contradicts a recorded decision is a change of mind or a build defect, and the log tells you
which.
