# Working session guide - two hours, no export required

**Use when** you are in front of the customer and the outcome you need is a set of closed
design decisions, not a findings report. Written for the case where the customer has not
shared their configuration and may not intend to.

**Outcome of the session:** decisions D-01 to D-18 in
[REFERENCE-DESIGN.md](REFERENCE-DESIGN.md) either accepted as default or changed with a
recorded reason, and a named owner for the four that cannot be reversed.

---

## Before you walk in

- Read [REFERENCE-DESIGN.md](REFERENCE-DESIGN.md). You are proposing it, not discovering it.
- Have the three-surface table (VM / file share / File Sync cache) ready. Most of the
  confusion in these conversations is that "backup" means three different things.
- Know which four decisions are one-way: **D-03** VM security type, **D-07** storage
  redundancy, **D-13** Enhanced backup policy, **D-16** vault redundancy and cross-region
  restore. If the session achieves nothing else, close these.
- Do not open with a request for an export. If they offer one, take it and run Door A after.

---

## The agenda

| Time | Segment | What you are actually getting |
|---|---|---|
| 0:00 | Frame the three surfaces | Shared vocabulary; stops "we already have backup" |
| 0:10 | The migration picture | Wave plan, what is moving, what is staying |
| 0:30 | File server disposition (D-04) | The list of servers sorted A / B / C |
| 0:55 | The private path and DNS (D-08, D-10) | Whether they own the DNS change or Infoblox does |
| 1:10 | Backup design (D-13 to D-18) | The four one-way decisions, closed |
| 1:35 | Sizing and the seed (D-09, D-12) | Dataset size, circuit bandwidth, copy window |
| 1:50 | Owners and next step | Who does what; whether Door A ever happens |

---

## Segment 1 - frame the three surfaces (10 min)

Draw this before anything else:

> A migrated **VM** is backed up by Azure Backup for Azure VMs.
> An Azure **file share** is backed up by Azure Backup for Azure Files.
> A File Sync **server** is a cache. It is not backed up at all, on purpose.

Then ask one question: *"When you say you want backup for the migrated servers, which of
those three do you mean?"* The answer tells you whether you are designing one product or
three, and it usually reveals whether they have already assumed a file-level backup agent on
the file servers.

**If they say they plan to run their existing backup agent on the File Sync servers, stop and
handle it now.** That is decision D-14 and it is the single most damaging default in this
project: an agent that walks a tiered volume recalls the entire dataset.

---

## Segment 2 - the migration picture (20 min)

Questions that change the design, in priority order:

1. How many servers are moving, in how many waves, and when is wave 1?
2. Which of them are file servers, and how much data does each hold?
3. Is Azure Migrate already deployed, and is replication going over the ExpressRoute or the
   internet today?
4. What is the ExpressRoute circuit bandwidth, and what else uses it?
5. Are the migrated VMs landing as Trusted Launch?

Question 5 looks like trivia and is not. Trusted Launch drives the Enhanced backup policy
(D-03, D-13), and Enhanced is one-way.

**If they will not answer 1 and 2**, you cannot size anything. Say so plainly, take the
defaults, and record that the sizing is unvalidated. That is a legitimate outcome; a design
built on a number you invented is not.

---

## Segment 3 - file server disposition (25 min)

Walk the decision tree in D-04 for the file servers named in segment 2. For each server you
want one letter:

- **A** - lift and shift, no File Sync. Backed up as a VM.
- **B** - migrate, then attach File Sync. The share is authoritative and is backed up; the
  server is a cache and is not.
- **C** - retire the server, clients use the Azure file share directly.

Most will be **B**. The two things that push a server to **C** are that nothing else runs on
it and the organization is willing to change what users type. The thing that pushes a server to
**A** is a local application on the same box.

Capture the answer as a table. This table is the migration plan for the file estate, and
almost everything downstream depends on it.

---

## Segment 4 - private path and DNS (15 min)

You are establishing two things:

1. **That the traffic that can be private will be.** The SMB path and the File Sync path get
   private endpoints. The Storage Sync Service to storage account leg stays inside Microsoft
   and cannot be routed over the ExpressRoute. Backup traffic is Azure-internal. Say all three
   explicitly - the requirement is usually stated as "everything over the ExpressRoute", and
   two thirds of that is not achievable or necessary.
2. **Who makes the DNS change.** The `privatelink` zones need conditional forwarders from
   Infoblox to a DNS Private Resolver inbound endpoint in the hub. Ask who owns Infoblox and
   what their change process is. This is the dependency most likely to delay the build.

---

## Segment 5 - backup design (25 min)

Close the four one-way decisions. Use the defaults; the reason is written next to each in the
reference design.

| Decision | Default to propose | The question to ask |
|---|---|---|
| **D-13** VM backup policy | Enhanced, daily, instant restore 7 days | "Do any of these need a recovery point more often than daily?" |
| **D-16** Vault posture | One vault per region, soft delete on, immutability on, MUA with a Resource Guard, GRS with cross-region restore | "Does your DR plan require restoring into a second region?" |
| **D-07** Storage redundancy | ZRS, GRS where the DR plan requires it | Same question, different product |
| **D-03** VM security type | Trusted Launch where the guest supports it | "Is your VM landing standard Trusted Launch?" |

Then the retention conversation, which is not a technical one: **retention comes from the
organization's records-retention schedule, not from the product defaults.** The portal's defaults
(180 days daily, 12 weeks weekly, 60 months monthly, 10 years yearly) are a starting point,
not a policy. Ask who owns the retention schedule and whether anyone from that side of the
organization should be in the next session.

Finish with D-18: **backup enabled and first backup verified is an exit gate for every
migration wave.** Get agreement that a wave is not done until that query returns clean.

---

## Segment 6 - sizing and the seed (15 min)

Three numbers, on the whiteboard, in front of them:

- Total file data to move.
- ExpressRoute bandwidth available for the seed, and the window it may run in.
- Resulting seed duration.

If the answer is measured in weeks, that is the finding of the session, and it changes the
plan (seed before cutover, or seed from a Data Box). Do this arithmetic live. It is the
moment the customer understands why the questions in segment 2 mattered.

Then D-12: the copy must preserve NTFS ACLs and timestamps, and there is a verification pass
before any source is decommissioned. Get explicit agreement that **no source server is
decommissioned until the fidelity check passes.**

---

## Segment 7 - owners and next step (10 min)

- Name an owner for each decision that changed from the default.
- Name the Infoblox change owner and the retention-schedule owner.
- Offer Door A once more, now that they have seen the design: *"If you can export the current
  configuration, we can validate this design against what you actually have in about a day."*
  Customers who declined at the start often accept here, because the export is now clearly in
  service of a design they helped write rather than an audit of their work.

---

## After the session

1. Write the decision log - every decision, its value, whether it was the default, who owns it.
2. Run [BUILD-SEQUENCE.md](BUILD-SEQUENCE.md) against the agreed design.
3. If an export arrives, run Door A and reconcile: any finding that contradicts a recorded
   decision is either a change of mind or a build defect, and the log tells you which.
