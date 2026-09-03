# Diagram library

Every diagram is a standalone mermaid file that renders on its own. All 97 were verified
against a mermaid renderer; a diagram that does not render is treated as a defect.

Diagrams are grouped by **architecture principle**. Each principle carries at least six views,
deliberately of different kinds - a topology is not a substitute for a sequence, and neither
answers the question a decision tree answers.

| Principle | Folder | Diagrams |
|---|---|---|
| Private connectivity | [`private-connectivity/`](private-connectivity/) | 12 |
| Hybrid name resolution | [`hybrid-dns/`](hybrid-dns/) | 9 |
| Storage account security baseline | [`storage-security/`](storage-security/) | 12 |
| Identity and access | [`identity-access/`](identity-access/) | 10 |
| File Sync topology and cloud tiering | [`file-sync-topology/`](file-sync-topology/) | 12 |
| Data protection and recovery | [`data-protection/`](data-protection/) | 11 |
| Migration into Azure | [`migration/`](migration/) | 13 |
| Operations and governance | [`operations-governance/`](operations-governance/) | 11 |
| Cross-cutting | `.` | 7 |
| **Total** | | **97** |

## Private connectivity

| Diagram | Kind | Shows |
|---|---|---|
| [`afs-four-names-in-use.mmd`](private-connectivity/afs-four-names-in-use.mmd) | sequence | which one carries which conversation, and what happens when only three of them resolve |
| [`backup-privacy-boundary.mmd`](private-connectivity/backup-privacy-boundary.mmd) | flowchart | what a Recovery Services vault private endpoint actually covers, and why none of it applies to Azure Files |
| [`connectivity-option-tradeoffs.mmd`](private-connectivity/connectivity-option-tradeoffs.mmd) | quadrant | how private it actually makes the traffic against what it costs to build and run |
| [`cutover-phases-and-gates.mmd`](private-connectivity/cutover-phases-and-gates.mmd) | timeline | nine phases and the gate that must pass on every server before the next phase starts |
| [`expressroute-hub-spoke-transit.mmd`](private-connectivity/expressroute-hub-spoke-transit.mmd) | flowchart | the transit path, the two peering flags and the routing that carries it |
| [`lockdown-blast-radius.mmd`](private-connectivity/lockdown-blast-radius.mmd) | flowchart | each switch you can throw, what it breaks first, how far the damage reaches, and what contains it |
| [`pe-subnet-nsg-and-udr-controls.mmd`](private-connectivity/pe-subnet-nsg-and-udr-controls.mmd) | flowchart | the four privateEndpointNetworkPolicies values, the /32 system route and the NSG caveats |
| [`private-endpoint-connection-lifecycle.mmd`](private-connectivity/private-endpoint-connection-lifecycle.mmd) | state | the four Azure states plus the two operational states that decide whether traffic actually flows |
| [`private-path-resource-graph.mmd`](private-connectivity/private-path-resource-graph.mmd) | entity | every Azure object between a Contoso file server and a share, how they reference each other, and the real limits on ea |
| [`private-vs-service-endpoint-decision.mmd`](private-connectivity/private-vs-service-endpoint-decision.mmd) | flowchart | private endpoint, service endpoint, IP rule or trusted-services bypass, one answer per traffic source |
| [`storage-firewall-evaluation.mmd`](private-connectivity/storage-firewall-evaluation.mmd) | sequence | the private endpoint path versus the public endpoint firewall, with the 403 failure branch that a lock-down produces |
| [`traffic-leg-privacy-map.mmd`](private-connectivity/traffic-leg-privacy-map.mmd) | flowchart | who initiates it, whether it can be made private, and who owns the control |

## Hybrid name resolution

| Diagram | Kind | Shows |
|---|---|---|
| [`dns-buildout-and-cutover-gates.mmd`](hybrid-dns/dns-buildout-and-cutover-gates.mmd) | timeline | DNS is always built before the first private endpoint, never after |
| [`dns-control-plane-resource-graph.mmd`](hybrid-dns/dns-control-plane-resource-graph.mmd) | entity | what references what, which cardinality is a hard limit, and where the Infoblox half of the estate attaches |
| [`dns-failure-blast-radius.mmd`](hybrid-dns/dns-failure-blast-radius.mmd) | flowchart | what each fault takes down, what it silently does NOT touch, and the boundary that contains it |
| [`dns-ownership-boundaries.mmd`](hybrid-dns/dns-ownership-boundaries.mmd) | flowchart | the three boundaries that decide who can fix a DNS incident, and the two things nobody at Contoso can change |
| [`file-sync-four-name-resolution.mmd`](hybrid-dns/file-sync-four-name-resolution.mmd) | sequence | the four Storage Sync Service names, the storage account name, and the branch where one forwarder is missing |
| [`forwarder-scope-tradeoff.mmd`](hybrid-dns/forwarder-scope-tradeoff.mmd) | flowchart | what each one captures, what it breaks, what it costs to run, and Contoso verdict |
| [`privatelink-record-lifecycle.mmd`](hybrid-dns/privatelink-record-lifecycle.mmd) | state | the only supported state, the four drift states that look identical from the client, and how each one is left |
| [`resolution-order-decision.mmd`](hybrid-dns/resolution-order-decision.mmd) | flowchart | the documented precedence for an Azure client and for a Contoso client, and every branch that ends in a public IP |
| [`resolver-endpoints-and-ports.mmd`](hybrid-dns/resolver-endpoints-and-ports.mmd) | flowchart | both resolver endpoints, the port each leg actually uses, and the documented limits |

## Storage account security baseline

| Diagram | Kind | Shows |
|---|---|---|
| [`account-key-and-sas-lifecycle.mmd`](storage-security/account-key-and-sas-lifecycle.mmd) | state | and the one ordering that causes an outage |
| [`cmk-enablement-and-revocation.mmd`](storage-security/cmk-enablement-and-revocation.mmd) | sequence | Turning on customer-managed keys for Contoso Files account, and the failure branch when the key is revoked |
| [`defender-and-audit-coverage.mmd`](storage-security/defender-and-audit-coverage.mmd) | flowchart | Defender for Storage coverage, its documented gaps for SMB shares, and the audit trail that has to fill them |
| [`deletion-protection-chain.mmd`](storage-security/deletion-protection-chain.mmd) | state | which delete is reversible, for how long, and what the reversal does NOT bring back |
| [`encryption-layers-and-ownership.mmd`](storage-security/encryption-layers-and-ownership.mmd) | flowchart | the four layers, who owns each key, and which legs are Contoso's to configure |
| [`hardening-order-and-gates.mmd`](storage-security/hardening-order-and-gates.mmd) | timeline | what goes first, what goes last, and the gate that must pass before the next phase |
| [`network-rule-evaluation.mmd`](storage-security/network-rule-evaluation.mmd) | flowchart | the order in which one request is actually decided |
| [`policy-guardrail-tradeoff.mmd`](storage-security/policy-guardrail-tradeoff.mmd) | quadrant | control value against the risk of breaking File Sync or Backup |
| [`shared-key-blast-radius.mmd`](storage-security/shared-key-blast-radius.mmd) | flowchart | what still depends on the key, what breaks, what contains it |
| [`smb-security-profile-decision.mmd`](storage-security/smb-security-profile-decision.mmd) | flowchart | driven by the OLDEST client that must keep mounting |
| [`smb-session-negotiation.mmd`](storage-security/smb-session-negotiation.mmd) | sequence | every check the hardened account makes, in order, and where it returns STATUS_ACCESS_DENIED |
| [`storage-account-resource-graph.mmd`](storage-security/storage-account-resource-graph.mmd) | entity | every resource that points at stmryfiles01 and the property that carries the reference |

## Identity and access

| Diagram | Kind | Shows |
|---|---|---|
| [`ad-ds-join-object-model.mmd`](identity-access/ad-ds-join-object-model.mmd) | entity | the objects created and how they reference each other |
| [`authentication-decision-tree.mmd`](identity-access/authentication-decision-tree.mmd) | flowchart | identity source, share-permission model and ACL tooling |
| [`file-sync-identity-state-machine.mmd`](identity-access/file-sync-identity-state-machine.mmd) | state | shared key to managed identity and back |
| [`identity-enablement-timeline.mmd`](identity-access/identity-enablement-timeline.mmd) | timeline | the phase order and the gate that opens the next phase |
| [`identity-failure-blast-radius.mmd`](identity-access/identity-failure-blast-radius.mmd) | flowchart | the trigger, the symptom on the wire, how far it spreads and what contains it |
| [`identity-source-tradeoffs.mmd`](identity-access/identity-source-tradeoffs.mmd) | quadrant | what it costs to stand up against what it can enforce |
| [`identity-traffic-ports-and-boundaries.mmd`](identity-access/identity-traffic-ports-and-boundaries.mmd) | flowchart | every leg, its port, and the legs that cannot be made private |
| [`kerberos-mount-sequence.mmd`](identity-access/kerberos-mount-sequence.mmd) | sequence | name resolution, ticket, share RBAC, NTFS ACL |
| [`least-privilege-role-map.mmd`](identity-access/least-privilege-role-map.mmd) | flowchart | least privilege for Contoso operators and for the platform's own identities |
| [`share-rbac-and-ntfs-combination.mmd`](identity-access/share-rbac-and-ntfs-combination.mmd) | flowchart |  |

## File Sync topology and cloud tiering

| Diagram | Kind | Shows |
|---|---|---|
| [`multi-site-sync-and-dfs-namespace.mmd`](file-sync-topology/multi-site-sync-and-dfs-namespace.mmd) | flowchart |  |
| [`recall-storm-blast-radius.mmd`](file-sync-topology/recall-storm-blast-radius.mmd) | flowchart | what starts one, how far the damage travels, and the exact control that contains each source |
| [`responsibility-split-file-sync.mmd`](file-sync-topology/responsibility-split-file-sync.mmd) | flowchart | Contoso, Microsoft and the delivery team - and where each hand-off happens |
| [`server-agent-anatomy-and-ports.mmd`](file-sync-topology/server-agent-anatomy-and-ports.mmd) | flowchart | agent processes, what consumes the volume, and every port that leaves the box |
| [`share-onboarding-rollout-timeline.mmd`](file-sync-topology/share-onboarding-rollout-timeline.mmd) | timeline | Phased rollout of one Contoso department share into a sync group, with the gate that must pass before each next phase |
| [`share-to-sync-group-mapping.mmd`](file-sync-topology/share-to-sync-group-mapping.mmd) | flowchart | map an on-premises share or volume to an Azure file share and a sync group |
| [`sync-group-cardinality-model.mmd`](file-sync-topology/sync-group-cardinality-model.mmd) | entity |  |
| [`sync-session-and-change-enumeration.mmd`](file-sync-topology/sync-session-and-change-enumeration.mmd) | sequence | server change detection by USN journal, cloud change detection by the 24 hour enumeration job, and the failure branche |
| [`tiered-file-lifecycle.mmd`](file-sync-topology/tiered-file-lifecycle.mmd) | state | states, attributes and what moves it |
| [`tiering-policy-engine-and-free-space-math.mmd`](file-sync-topology/tiering-policy-engine-and-free-space-math.mmd) | flowchart | What the tiering job actually evaluates every 60 minutes, the free-space arithmetic, and the road into low disk space  |
| [`tiering-policy-tradeoffs.mmd`](file-sync-topology/tiering-policy-tradeoffs.mmd) | quadrant | local capacity kept against recall egress |
| [`volume-feature-interop-decision.mmd`](file-sync-topology/volume-feature-interop-decision.mmd) | flowchart | which features coexist with cloud tiering, which change its timing, and which must be switched off |

## Data protection and recovery

| Diagram | Kind | Shows |
|---|---|---|
| [`backup-data-path-and-ownership.mmd`](data-protection/backup-data-path-and-ownership.mmd) | flowchart | the answer to the ExpressRoute question |
| [`backup-item-and-recovery-point-lifecycle.mmd`](data-protection/backup-item-and-recovery-point-lifecycle.mmd) | state | the backup item states and the two kinds of recovery point they produce |
| [`backup-resource-graph.mmd`](data-protection/backup-resource-graph.mmd) | entity | The Azure objects that make up Contoso backup, how they reference each other, and the hard cardinality limits between  |
| [`file-share-deletion-and-undelete-states.mmd`](data-protection/file-share-deletion-and-undelete-states.mmd) | state | the states between live and permanently gone, and the deliberate path an attacker uses to skip them |
| [`full-share-restore-sequence.mmd`](data-protection/full-share-restore-sequence.mmd) | sequence | the real order of operations and the three ways the job fails |
| [`mua-resource-guard-critical-operations.mmd`](data-protection/mua-resource-guard-critical-operations.mmd) | sequence | the Resource Guard between Contoso backup admin and every destructive vault operation |
| [`protection-tier-tradeoff.mmd`](data-protection/protection-tier-tradeoff.mmd) | quadrant | recovery speed against how far each copy sits from the storage account blast radius |
| [`ransomware-blast-radius.mmd`](data-protection/ransomware-blast-radius.mmd) | flowchart | what each stolen credential reaches, and the exact control that stops it |
| [`restore-path-decision-tree.mmd`](data-protection/restore-path-decision-tree.mmd) | flowchart | the decision an engineer follows at the console |
| [`retention-design-from-records-schedule.mmd`](data-protection/retention-design-from-records-schedule.mmd) | flowchart | which knob carries which requirement, and the ceiling on each knob |
| [`vault-build-order-and-irreversible-gates.mmd`](data-protection/vault-build-order-and-irreversible-gates.mmd) | timeline | which decisions are one-way doors, what must be true before the next phase, and where the clocks run |

## Migration into Azure

| Diagram | Kind | Shows |
|---|---|---|
| [`appliance-registration-dns-sequence.mmd`](migration/appliance-registration-dns-sequence.mmd) | sequence | project creation, DNS proof, registration and first replication, with the name-resolution failure branch |
| [`data-box-seed-lifecycle.mmd`](migration/data-box-seed-lifecycle.mmd) | state | order states, the copy rules that decide whether the seed is usable, and the File Sync attach decision |
| [`data-movement-tool-decision.mmd`](migration/data-movement-tool-decision.mmd) | flowchart | the decision an engineer follows per share, not per project |
| [`dfs-n-root-consolidation-topology.mmd`](migration/dfs-n-root-consolidation-topology.mmd) | flowchart | the referral path, the ports, and why the namespace server is not in the data path |
| [`discovery-vs-replication-planes.mmd`](migration/discovery-vs-replication-planes.mmd) | flowchart | discovery and assessment versus replication and cutover - what differs and what is irreversible |
| [`file-data-movement-paths.mmd`](migration/file-data-movement-paths.mmd) | flowchart | the four transports, their ports, and the legs that cannot be made private |
| [`migrate-private-link-resource-graph.mmd`](migration/migrate-private-link-resource-graph.mmd) | entity | the resource graph, who creates each object and how they reference each other |
| [`migrate-replication-lifecycle.mmd`](migration/migrate-replication-lifecycle.mmd) | state | the states a server passes through and where it falls back |
| [`migration-cutover-blast-radius.mmd`](migration/migration-cutover-blast-radius.mmd) | flowchart | what breaks, what it takes with it, what contains it |
| [`migration-responsibility-layers.mmd`](migration/migration-responsibility-layers.mmd) | flowchart | Microsoft, Contoso, and the consulting team |
| [`seeding-path-tradeoffs.mmd`](migration/seeding-path-tradeoffs.mmd) | quadrant |  |
| [`share-wave-cutover-sequence.mmd`](migration/share-wave-cutover-sequence.mmd) | sequence | seeded copy, freeze, final MIR pass, DFS-N name takeover, and the rollback branch |
| [`share-wave-timeline-and-gates.mmd`](migration/share-wave-timeline-and-gates.mmd) | timeline |  |

## Operations and governance

| Diagram | Kind | Shows |
|---|---|---|
| [`agent-lifecycle-and-update-policy.mmd`](operations-governance/agent-lifecycle-and-update-policy.mmd) | state | the states a version passes through and the update policy that decides who moves it |
| [`alert-to-runbook-triage.mmd`](operations-governance/alert-to-runbook-triage.mmd) | flowchart | the decision path from signal to codex runbook |
| [`capacity-and-quota-entity-model.mmd`](operations-governance/capacity-and-quota-entity-model.mmd) | entity | the objects Contoso operates, how they reference each other, and the ceiling that stops each one |
| [`cost-drivers-and-meters.mmd`](operations-governance/cost-drivers-and-meters.mmd) | flowchart | which operational act lands on which billing meter, for Contoso File Sync and Backup estate |
| [`cost-lever-tradeoffs.mmd`](operations-governance/cost-lever-tradeoffs.mmd) | quadrant | which ones to pull first |
| [`file-sync-alert-rule-catalog.mmd`](operations-governance/file-sync-alert-rule-catalog.mmd) | flowchart | every metric alert rule that must exist, with its metric, threshold, window and route |
| [`iac-avm-and-drift-detection.mmd`](operations-governance/iac-avm-and-drift-detection.mmd) | flowchart | Infrastructure as code with Azure Verified Modules, and the drift loop that catches what the template cannot see |
| [`monitoring-signal-chain.mmd`](operations-governance/monitoring-signal-chain.mmd) | flowchart | where every File Sync, Azure Files and Backup signal originates and where it lands |
| [`operations-cadence-and-handover.mmd`](operations-governance/operations-cadence-and-handover.mmd) | timeline | the handover gate and the recurring work that keeps the design true |
| [`ownership-split-and-monitoring-gaps.mmd`](operations-governance/ownership-split-and-monitoring-gaps.mmd) | flowchart | Microsoft, Contoso, the consulting team - and the gaps where no signal exists |
| [`policy-assignment-and-remediation.mmd`](operations-governance/policy-assignment-and-remediation.mmd) | sequence | assignment, evaluation timing and the remediation task, including the branch where remediation fails |

## Cross-cutting

| Diagram | Kind | Shows |
|---|---|---|
| [`azure-files-backup-flow.mmd`](azure-files-backup-flow.mmd) | flowchart | data paths, tiers and restores |
| [`azure-files-private-endpoint-architecture.mmd`](azure-files-private-endpoint-architecture.mmd) | flowchart |  |
| [`azure-migrate-private-link.mmd`](azure-migrate-private-link.mmd) | flowchart | endpoints, zones and what stays public |
| [`file-sync-cutover-sequence.mmd`](file-sync-cutover-sequence.mmd) | sequence |  |
| [`file-sync-private-path.mmd`](file-sync-private-path.mmd) | flowchart | the three legs and who initiates them |
| [`hybrid-dns-resolution-flows.mmd`](hybrid-dns-resolution-flows.mmd) | sequence | three resolution flows |
| [`secure-storage-account-anatomy.mmd`](secure-storage-account-anatomy.mmd) | flowchart | controls and what must stay open |

## Rendering

```bash
curl -sS -o out.svg -X POST -H "Content-Type: text/plain" \
  --data-binary @codex/diagrams/<principle>/<file>.mmd https://kroki.io/mermaid/svg
```

Mermaid conventions this library holds to, because these are the ones that break silently:
edge labels use the pipe form `A -->|label| B`, never the `A -- label --> B` form; any node
label containing a colon or parentheses is quoted; no arrow glyph appears inside a label;
files are ASCII only.
