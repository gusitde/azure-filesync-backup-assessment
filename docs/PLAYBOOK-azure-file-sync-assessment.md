# Playbook - scope and assess a customer's Azure File Sync environment, then recommend

**Use when** a customer asks "review our Azure File Sync configuration and make sure it is
set up correctly and securely" - typically inside a short advisory window (a half-day
session plus a report). The outcome is a **findings + recommendations report** grounded in
the customer's exported configuration, not in interviews, and a **target design** when the
customer has a routing requirement (for example: sync traffic must use ExpressRoute).

Companion: [PLAYBOOK-azure-backup-for-azure-files.md](PLAYBOOK-azure-backup-for-azure-files.md)
for the backup half of the ask.

## 0. Outcomes and time box

| Deliverable | Form | Effort |
|---|---|---|
| Configuration export (evidence) | `afs-export-<stamp>.zip` + optional server bundles | 30-60 min customer time |
| Assessment | `assessment.md` / `findings.json` from the assessor, reviewed by the consultant | 1-2 h |
| Recommendations | Prioritised roadmap (do now / this engagement / backlog) with effort and risk | 1-2 h |
| Target design (if private routing is required) | Diagram + cut-over steps (section 5) | 2 h |
| Session with the customer | Walk the scorecard, agree priorities, hand over the runbook of changes | 2 h |

## 1. Scope (before touching anything)

Confirm in writing, in this order:

1. **Which subscriptions and which Storage Sync Services** are in scope (one tenant?). The
   exporter walks every enabled subscription the account can read; narrow with
   `-SubscriptionId` if the customer wants a subset.
2. **Which registered servers** exist (name, site, OS), and whether the customer can run the
   server-side bundle on them (needs local admin, elevated PowerShell). Without bundles the
   server checks (`SRV-*`) are skipped and the report says so.
3. **The non-functional requirements** that turn Info into High:
   - Private routing: "File Sync traffic must go over our ExpressRoute / VPN" -> run the
     assessor with `-PrivateTrafficRequired`.
   - Data residency / redundancy expectations (zone, region).
   - Records retention (public sector: the retention schedule drives backup policy).
   - Identity model: do users ever mount the Azure file share directly, or only through the
     Windows Servers?
4. **Who owns what**: storage, network (ExpressRoute, DNS/Infoblox), Windows Server, backup.
   The recommendations are assigned to these owners.
5. **Access**: an account with **Reader** on the subscriptions (nothing more). Reader is
   enough for every call the exporter makes; a 403 in `errors.json` means the scope is
   narrower than declared.

Log the scope, the requirement flags and the owners at the top of the assessment.

## 2. Export (customer runs, or consultant with Reader)

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Connect-AzAccount -Tenant <tenant-id>
.\Export-AzFileSyncEnvironment.ps1 -JobLookbackDays 60
```

- Output: `afs-export-<stamp>\` and `afs-export-<stamp>.zip`. `summary.md` inside is a
  readable inventory (sync topology, server health, storage settings, backup coverage,
  private networking, alert rules) - open it first.
- `errors.json` lists every failed call. Zero is the target; each error is an assessment
  gap the report must mention (rule `OPS-02`).
- On each registered server (elevated):
  `.\Get-AfsServerDiagnostics.ps1 -OutputPath C:\temp` -> copy the zip into the export
  folder under `servers\<hostname>\`. Add `-SampleTieredFiles` for a bounded census of
  tiered files per endpoint (useful to size caches and to show the backup problem).
- Nothing in the export is secret: keys, SAS and certificates are never requested and a
  redaction pass blanks well-known secret fields. It does contain resource IDs and names.

## 3. Assess

```powershell
.\Assess-AzFileSyncExport.ps1 -ExportPath .\afs-export-<stamp>.zip -CustomerName "Contoso of X" [-PrivateTrafficRequired] [-IncludeCatalog]
```

Read `assessment.md` top-down:

1. **Scope line + scorecard** - counts by severity and by area. If `OPS-03` lists servers
   without bundles, decide whether to chase them before the session.
2. **High findings** - each row has the evidence (the property values that triggered it),
   the recommendation and the Microsoft Learn reference. Verify each against `summary.md`
   or the raw JSON before you present it; the assessor is a first pass, the consultant signs.
3. **Medium / Low / Info** - the roadmap groups them; Info items are design notes (for
   example `SEC-04` explains why shared-key access must stay on while Azure Backup protects
   the shares).
4. **Recommendation roadmap** - do now / this engagement window / backlog. Re-order by the
   customer's priorities and add effort + owner per line.
5. **Assessment gaps** - export errors and missing bundles; state them in the report.

What the rules cover (full catalog: [RULES.md](RULES.md)):

| Area | Examples |
|---|---|
| Sync health / topology | endpoint not healthy, persistent per-item errors, stalled sync, nested endpoints, system-volume endpoint, cloud-only sync groups, cross-region service/account |
| Registered servers | offline, agent expired/expiring/old major, unsupported OS, clustered (no auto-update), certificate vs managed identity |
| Cloud tiering | disabled (full copy), unhealthy, low-disk mode, aggressive free-space policy, low cache hit ratio, recall storms (> 500 GiB/day) |
| Storage security | HTTPS-only, TLS 1.2, firewall open, trusted-services bypass for File Sync, shared key (with the Backup caveat), key age/policy, identity-based auth, SMB hardening, Defender for Storage, locks, RBAC hygiene |
| Durability | LRS vs ZRS/GRS, share soft delete >= 14 days, quota headroom, snapshot limit, large file shares, RA-GRS misuse |
| Backup | unprotected shares (File Sync cloud endpoints called out), unhealthy items, failed jobs, snapshot-only policies, retention, vault soft delete / immutability / MUA / redundancy / CRR / alerts / diagnostics, missing vault in region, key access required |
| Networking | public endpoints (Info, or High with private routing required), private endpoints without DNS, unapproved connections, missing DNS zone groups; private mode: no PE on the Storage Sync Service / storage account, public endpoints still open after PE, no ExpressRoute/VPN gateway, no DNS Private Resolver, and the note that Azure Files backup never crosses the customer network |
| Monitoring | recommended File Sync alerts, storage availability alert, file service logs |
| Server side | agent service/filters, backup or AV products on tiered endpoints, disk headroom vs policy, Windows Search / DFS-R, clock skew, failing 9102 sessions, self-service restore, cluster size, version mismatch, dedup interplay |

## 4. Recommend (turn findings into a plan the customer can execute)

Structure the recommendation section by owner, and for each item give: what, why (the
finding id and evidence), how (portal path or PowerShell), risk / user impact, rollback,
effort. The order that works for an advisory session:

1. **Stop data loss first** - unprotected shares (`BKP-01`), share soft delete (`DATA-02`),
   quota headroom (`DATA-03`), unhealthy endpoints and servers (`AFS-01/04/05`).
2. **Close the security gaps that are one click** - TLS 1.2, HTTPS-only, Defender for
   Storage, key expiration policy, delete locks, alerts (`MON-01`, `BKP-11`).
3. **Network posture** - firewall Deny + trusted services (+ private endpoints if required;
   see section 5). Always test sync after each network change.
4. **Identity** - managed identities for the Storage Sync Service and servers (agent v20+,
   Arc for on-premises servers), then revisit shared-key access (mind Azure Backup).
5. **Backup design** - policy tiers, retention, vault hardening: hand over to the backup
   playbook.
6. **Operations** - agent auto-update with a maintenance window, monthly review of the five
   recommended alerts, tagging, runbook for restores.

Write the customer report from the assessment, not the other way round: every
recommendation cites its evidence line, so the customer (and their auditor) can re-check it
against their own export.

## 5. Target design when File Sync traffic must use ExpressRoute

Azure File Sync has **two** cloud endpoints, and both must be private for the requirement
to hold:

| Traffic | From | To | Make it private with |
|---|---|---|---|
| Sync control + metadata (HTTPS 443) | registered servers | Storage Sync Service (`*.afs.azure.net`, 4 names: management, sync primary/secondary, monitoring) | private endpoint on the Storage Sync Service (sub-resource `afs`) + `privatelink.afs.azure.net` zone; then `incomingTrafficPolicy = AllowVirtualNetworksOnly` |
| File data upload/download + recalls (FileREST over HTTPS 443, never SMB) | registered servers | storage account file endpoint (`<account>.file.core.windows.net`) | private endpoint on the storage account (sub-resource `file`) + `privatelink.file.core.windows.net` zone; then firewall default **Deny** with **Allow Azure services on the trusted services list** |
| Storage Sync Service -> storage account (change enumeration, cloud endpoint operations) | Microsoft service | storage account | stays inside Microsoft's network via the trusted-services bypass - it never leaves Azure and cannot be forced onto ExpressRoute; keep the bypass on or sync breaks |
| Azure Backup -> storage account | Microsoft service | storage account | Azure-internal; a private endpoint on the vault does not apply to Azure Files; nothing to route (see the backup playbook) |

Design steps (they map to `NET-05`..`NET-11`):

1. **Landing zone prerequisites**: ExpressRoute circuit with private peering, ExpressRoute
   gateway in the hub VNet, spoke VNets peered with gateway transit. Private endpoints can
   live in a shared-services spoke; on-premises reaches them through the hub gateway.
2. **DNS**: Azure DNS Private Resolver inbound endpoint in the hub; on-premises DNS (for
   example an Infoblox grid) gets conditional forwarders for `privatelink.file.core.windows.net`
   and `privatelink.afs.azure.net` (or the parent zones) pointing at the inbound endpoint.
   Link both private zones to the hub (and any VNet hosting Azure-side servers). Register
   the private endpoint IPs in IPAM.
3. **Storage account private endpoint** (`file`) + DNS zone group. Verify from a registered
   server: `Resolve-DnsName <account>.file.core.windows.net` returns the private IP through
   the `privatelink` CNAME.
4. **Storage Sync Service private endpoint** (`afs`) + DNS zone group. Verify from a server
   with `Debug-StorageSyncServer -TestNetworkConnectivity` and `Resolve-DnsName` for the four
   `*.afs.azure.net` names (they are listed in the service's private endpoint DNS config).
5. **Cut over, one lock at a time**: storage firewall to Deny + trusted services (+ admin IP
   rules) -> confirm sync sessions (event 9102, HResult 0) and a cloud change enumeration ->
   set `incomingTrafficPolicy = AllowVirtualNetworksOnly` -> confirm again. Never disable the
   public endpoint before the private endpoint resolves from every server.
6. **What stays public**: Azure Backup (Azure-internal), portal / PowerShell management,
   and Microsoft Update for the agent. Azure File Sync does not support the Internet routing
   preference and does not support service endpoints for the Storage Sync Service - private
   endpoints are the only private option for it.
7. **Rollback**: `incomingTrafficPolicy = AllowAllTraffic` and firewall default Allow restore
   the public path in minutes; keep the private endpoints in place.

## 6. Session agenda (2 hours)

1. Scope and evidence (10 min) - what was exported, when, gaps.
2. Scorecard and the High findings (30 min) - agree they are real; assign owners.
3. Target design (30 min, if private routing) - the table above on one slide.
4. Backup (30 min) - hand over to the backup playbook; agree tiers, retention, restore test.
5. Roadmap and next steps (20 min) - what gets done inside the engagement window, what is
   backlog, what the customer wants written up.

## 7. Close-out checklist

- [ ] Export zip archived with the report (evidence), server bundles included or gaps stated.
- [ ] Every High/Medium finding has an owner, an action and a verification step.
- [ ] Changes made during the engagement re-exported and re-assessed (before/after counts).
- [ ] Restore test performed and documented (backup playbook).
- [ ] Customer has the exporter + assessor so they can re-run the assessment quarterly.
