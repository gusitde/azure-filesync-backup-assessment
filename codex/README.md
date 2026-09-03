# Codex library - Azure Files with private endpoints, secure storage accounts, hybrid DNS, File Sync, Migrate and Backup (Contoso profile)

Twenty-two codex entries (blueprints, playbooks, runbooks) plus 97 mermaid diagrams grouped by
architecture principle, written in the Luca codex format (`_MANIFEST.md` v1: 17 front-matter keys, the
six-section body frame, executable `## Steps`, fenced gate rules, anchored references) so they
can be imported into a codex (`blueprint.blueprints`) with `import-to-luca.mjs` and still be read
here as plain markdown. Every fact was read on Microsoft Learn, the Azure Verified Modules
registry or the Azure Policy built-ins on 2026-09-03; each entry lists its sources at the end.

## Index

| Slug | Type | What it answers |
| --- | --- | --- |
| `blueprint-azure-files-secure-storage-account` | blueprint | What a secure storage account for Azure file shares looks like, and which controls must stay open for File Sync and Backup |
| `blueprint-azure-files-private-endpoint` | blueprint | How a share becomes reachable over ExpressRoute: private endpoint, zone, Infoblox forwarder, lock-down, oracle |
| `blueprint-azure-dns-for-private-endpoints` | blueprint | The DNS services to use with private endpoints: Azure DNS Private Resolver, the zone set (Files, File Sync, Migrate, Key Vault, Backup), Infoblox forwarders, three resolution flows |
| `blueprint-azure-file-sync-private-path` | blueprint | File Sync over ExpressRoute: Storage Sync Service endpoint (four names), storage endpoint, what stays Microsoft-internal, managed identity, cut-over |
| `blueprint-azure-migrate-private-link-landing` | blueprint | Azure Migrate over Private Link: project, Key Vault, usage storage, cache storage account (blob), zones, appliance DNS, what stays public |
| `blueprint-azure-files-backup-protection` | blueprint | Backup design for synced shares: vault hardening, snapshot + vault tiers, restores, why ExpressRoute is not involved |
| `blueprint-azure-vm-backup-for-migrated-servers` | blueprint | Azure VM backup for servers migrated from VMware: the three protection surfaces, the one-way Enhanced policy decision, restore paths, and why a File Sync cache is never backed up |
| `playbook-deploy-secure-storage-account-and-share` | playbook | Bicep (AVM 0.33.0) deployment of the baseline with a file private endpoint |
| `playbook-add-file-private-endpoint-and-dns` | playbook | Add the file endpoint + DNS zone group + Infoblox forwarder to an existing account, verify from Contoso |
| `playbook-harden-existing-storage-account` | playbook | Retrofit order that never breaks sync or backup, ending with Deny + trusted services |
| `playbook-deploy-dns-private-resolver-and-forwarders` | playbook | Bicep (AVM dns-resolver 0.5.8, dns-forwarding-ruleset 0.5.4, private-dns-zone 0.8.1) + Infoblox forwarders |
| `playbook-enable-file-sync-private-endpoint-and-cutover` | playbook | Storage Sync Service private endpoint, managed identity, AllowVirtualNetworksOnly with gates and rollback |
| `playbook-enable-identity-based-auth-ad-ds` | playbook | AzFilesHybrid AD DS join (AES-256), share-level RBAC, Kerberos-only SMB |
| `playbook-install-file-sync-agent-and-server-endpoint` | playbook | Agent install, server registration, sync group, cloud endpoint and server endpoint - and the identity split the cloud endpoint forces |
| `playbook-point-on-premises-dns-at-the-private-resolver` | playbook | The on-premises conditional forwarders: which zone to forward and why, the gate that refuses a resolver that is not answering, and the reverse path |
| `playbook-azure-migrate-private-link-cache-storage` | playbook | Cache storage account + blob endpoint + vault identity + appliance DNS verification |
| `playbook-enable-azure-backup-for-file-shares` | playbook | Vault (GRS + CRR first), policies with vault tier, protect every share, alert and restore tests |
| `playbook-protect-a-migration-wave-with-azure-backup` | playbook | Enhanced VM policy, protect every VM in the wave, first backups, the File Sync agent check, and the evidence that closes the wave gate |
| `runbook-private-endpoint-name-resolution-and-reachability` | runbook | Public IP, NXDOMAIN, stale IP, TCP failure, pending approval, appliance proxy, outbound class |
| `runbook-file-sync-broken-after-network-lockdown` | runbook | Trusted services removed, public access disabled, SSS endpoint disabled too early, storage path, proxy/cert/time, regional URLs |
| `runbook-storage-key-rotation-and-shared-key-incidents` | runbook | Key compromise, wrong rotation order, shared key disabled breaking Backup, NTLMv2 removal, AD object password |
| `runbook-restore-file-share-and-share-soft-delete` | runbook | Previous versions, item-level restore, ransomware full-share restore, share undelete, cross-region, restore constraints |

Diagrams: **97 mermaid files** under `diagrams/`, grouped into eight architecture principles
(private connectivity, hybrid name resolution, storage account security baseline, identity and
access, File Sync topology and cloud tiering, data protection and recovery, migration into
Azure, operations and governance), 9 to 13 per principle, plus seven cross-cutting diagrams
embedded in the blueprints. Each principle mixes topology, sequence, decision-tree, state,
failure and blast-radius, ownership, timeline, trade-off and entity views. Every diagram was
render-verified. Index: [diagrams/README.md](diagrams/README.md). Paste any file into
mermaid.live or a Markdown viewer with mermaid support; draw.io imports mermaid via
Arrange > Insert > Advanced > Mermaid.

Architecture references for the same eight principles - 73 verified sources with a stated
take-away each - are in [../docs/ARCHITECTURE-REFERENCES.md](../docs/ARCHITECTURE-REFERENCES.md).

## Contoso profile (values the entries assume)

| Variable | Value / decision |
| --- | --- |
| Connectivity | ExpressRoute private peering to the hub VNet; File Sync and direct SMB traffic must use it |
| DNS / IPAM | Infoblox grid on-premises (authoritative `contoso.local`, IPAM); Azure DNS Private Resolver in the hub; Infoblox vNIOS in Azure optional (one pattern, not both) |
| Identity | Contoso AD DS; groups synced to Entra ID; AES-256 Kerberos |
| Storage | One StorageV2 account per data class, ZRS or GRS (never RA-GRS), large file shares, soft delete 14 d |
| File Sync | Registered Windows Servers (agent v20+, Arc-enabled for managed identity), cloud tiering, self-service restore on tiered volumes |
| Backup | Regional Recovery Services vault, GRS + cross-region restore, soft delete always-on, immutability, MUA; 4-hourly snapshots + vaulted copies; retention from Contoso records schedule |
| Migrate | Project with private endpoint connectivity; Contoso-owned cache storage account with blob (+ queue) private endpoints |
| Zones | privatelink.file.core.windows.net, privatelink.afs.azure.net, privatelink.blob.core.windows.net, privatelink.queue.core.windows.net, privatelink.vaultcore.azure.net, privatelink.prod.migration.windowsazure.com, privatelink.siterecovery.windowsazure.com |
| Policy | Built-in definitions by GUID listed in the secure storage account blueprint; File Sync policies b35dddd9 / 0e07b2e9 / 21a8cd35 |

The key design facts Contoso asked about:

- **File Sync over ExpressRoute**: two legs the servers initiate go private (Storage Sync
  Service endpoint with four names, storage account file endpoint); the leg Microsoft initiates
  (Storage Sync Service to storage account) stays on the trusted-services path and cannot be
  moved; identity, ARM, PKI and agent updates stay public.
- **Backup over ExpressRoute**: not applicable - snapshots and vault transfers are Azure-internal
  and a vault private endpoint does not cover Azure Files; restores reach the servers through
  File Sync's private path.
- **Azure Migrate**: project, Key Vault, usage storage and vault endpoints are created by Azure;
  the cache storage account and its blob/queue endpoints are Contoso's; the appliance must
  resolve every name in "Download DNS settings" through Infoblox forwarders.
- **DNS**: forward the PUBLIC service zones - `file.core.windows.net`, `afs.azure.net` - from Infoblox to
  the Private Resolver inbound endpoint; use the outbound endpoint + ruleset for `contoso.local`
  from Azure.

## Import into the Luca codex

```bash
node codex/import-to-luca.mjs --luca-root E:/apps/Luca-express-prod            # copy + validate (dry run for the DB)
node codex/import-to-luca.mjs --luca-root E:/apps/Luca-express-prod --seed     # also print the seed SQL via scripts/codex/seed-codex.mjs
```

The script copies `codex/*.md` into `aios-core-apps/domains/design/apps/lucadesigns/codex/`,
copies `diagrams/*.mmd` beside them under `codex/diagrams/`, merges `ref-dispositions.json`
(the kit-relative paths cited in `Reuse` and `Reference` blocks are recorded as
`external-repo` references to this repository), runs `scripts/codex/validate-manifest.mjs`
on every copied entry and stops on the first error. Entries carry `status: published`,
`execution: assisted` (playbooks with `## Steps`) or `advisory` (blueprints, runbooks).

## Conventions

- Front matter per `_MANIFEST.md` v1; `slug` = filename; `kind` unique; `category` `infra`
  (blueprints, runbooks), `ops` / `iac` (playbooks); `applies_to: [ops, devstation]`;
  `persona_run` `eng-netops` (network, DNS, Migrate) or `eng-sysops` (storage, File Sync,
  Backup).
- `## When to use` first paragraph under 600 characters and written as a trigger.
- `## Reuse before reinvent (GR11)` cites the kit's scripts and the sibling entries.
- `## Gate rules` checks are commands that can pass on a healthy system.
- `## Reference` cites path + searchable anchor; Microsoft Learn sources are listed in prose
  after it.
- ASCII only; mermaid diagrams use `flowchart` and `sequenceDiagram` with labels free of
  unbalanced brackets.
