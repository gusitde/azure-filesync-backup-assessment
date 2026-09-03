---
slug: runbook-private-endpoint-name-resolution-and-reachability
doc_type: runbook
kind: private-endpoint-name-resolution-and-reachability
category: infra
title: Respond to a private endpoint that resolves publicly, NXDOMAINs or cannot be reached
summary: Incident classes for Azure Files, File Sync, Migrate and Key Vault private endpoints: public IP answered, NXDOMAIN, stale IP, TCP failure, pending approval, appliance proxy, outbound - each with its diagnostic and recovery.
when_to_use: A client on Contoso network or an Azure VM gets a public IP, NXDOMAIN, a stale IP or a TCP failure for a name that should reach a private endpoint.
applies_to: [ops, devstation]
tags: [private-endpoint, dns, infoblox, private-resolver, expressroute, azure-files, azure-migrate, incident, contoso]
persona_run: eng-netops
ticket_kind: bug-known
status: published
version: 1
execution: advisory
last_verified: 2026-09-03T05:00 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

Loud: a mount fails with "network path not found", File Sync shows server endpoints in
Error after a firewall change, the Migrate appliance reports `AgentNotConnected` or
`ForbiddenToAccessKeyVault`, Key Vault returns 403 from the appliance. Silent: everything works
but `nslookup` returns a public IP, meaning traffic never left the internet path and the
firewall lock-down will break it. Applies to any privatelink zone in
[[blueprint-azure-dns-for-private-endpoints]].

## Reuse before reinvent (GR11)

```yaml
- primitive: Resolve-DnsName / nslookup expected outputs from the Microsoft articles
  path: codex/blueprint-azure-files-private-endpoint.md
  why: the CNAME chain (name -> privatelink name -> A) is the single diagnostic that separates
       DNS classes from network classes; every class below starts with it
- primitive: Azure Migrate "Download DNS settings"
  path: codex/blueprint-azure-migrate-private-link-landing.md
  why: the project's own FQDN/IP list is the oracle for Migrate names; the hosts file is the
       documented testing-only fallback
- primitive: Get-AfsServerDiagnostics.ps1 (Debug-StorageSyncServer -TestNetworkConnectivity, DNS tests)
  path: Get-AfsServerDiagnostics.ps1
  why: captures the resolution and connectivity evidence from a file server in one bundle
```

## Response

1. **Answer is a public IP (no `privatelink` A record in the chain) - forwarder class.**
   Cause: the on-premises DNS has no conditional forwarder for the service's PUBLIC DNS zone
   pointing at the Private Resolver inbound endpoint, so the name was answered from public DNS -
   which returns the CNAME to `<x>.privatelink.<zone>` together with the public A record in the
   same response, so a forwarder scoped to `privatelink.*` is never consulted. Diagnose:
   `Resolve-DnsName <name>` shows CNAME to `<x>.privatelink.<zone>` then a public A;
   `Resolve-DnsName <x>.privatelink.<zone> -Server <inbound-ip>` returns the private IP.
   Recovery: on the Infoblox grid create the forward-only conditional forwarder for the
   service's documented public zone forwarder - `file.core.windows.net` (Azure Files),
   `afs.azure.net` (Azure File Sync), `vault.azure.net` / `vaultcore.azure.net` (Key Vault),
   `prod.migration.windowsazure.com` (Azure Migrate), `blob.core.windows.net` (cache/replication
   storage) - to the Private Resolver inbound endpoint IP, then `Clear-DnsClientCache` and
   retest. Microsoft: "The conditional forwarding must be made to the recommended public DNS
   zone forwarder. For example: `database.windows.net` instead of
   **privatelink**.database.windows.net." Accept the documented blast radius: every name in that
   public zone then resolves through Azure DNS, which breaks access to a private-endpoint-enabled
   storage account in another tenant. (Real case: the Azure Files DNS article's on-premises
   output shows exactly this chain ending in `52.239.x.x`.)
2. **NXDOMAIN for the privatelink name - zone class.** Cause: the forwarder works but the
   private DNS zone has no A record (zone group missing, or the query hit a duplicate zone of
   the same name linked to the VNet that holds no record). Diagnose: `az network private-dns
   record-set a list -z <zone>` lacks the name; `az network private-dns zone list` shows two
   zones with that name. Recovery: create the DNS zone group on the private endpoint pointing
   at the central zone; delete or unlink the duplicate zone; never hand-create the A record
   unless no zone group is possible. (Real case: Azure Migrate creates its own zones in the
   project RG - link them or merge, do not duplicate.)
3. **Stale or wrong private IP - cache/TTL class.** Cause: the endpoint was recreated and the
   client or an intermediate resolver cached the old A record; or a hand-made A record was
   never updated. Diagnose: `az network nic show` on the endpoint NIC shows a different IP than
   the answer. Recovery: fix the record (zone group), `Clear-DnsClientCache` on the client,
   purge the Infoblox cache for the zone, wait the record's actual TTL - read it with `az
   network private-dns record-set a show -g <rg> -z <zone> -n <name> --query ttl` (3600 s is the
   Azure CLI/portal default for a private-DNS record set; 600 s is not an Azure default). Then
   remove hand-made records for good.
4. **Correct private IP but TCP fails (445 or 443) - routing/firewall class.** Cause: the
   Contoso edge firewall or - only when the subnet's private-endpoint network policies are on - a
   NSG on the private-endpoint subnet blocks the port, the spoke has no route to on-premises
   (peering without gateway transit / use remote gateways), or an Azure Firewall/UDR intercepts
   the private-endpoint prefix. Check the policy setting first: `az network vnet subnet show -g
   <rg> --vnet-name <vnet> -n <subnet> --query privateEndpointNetworkPolicies`. Microsoft: "By
   default, network policies are disabled for a subnet in a virtual network"; NSG rules reach
   private-endpoint traffic only when the value is `Enabled` or `NetworkSecurityGroupEnabled`,
   and a UDR overrides the private endpoint's /32 route only when the value is `Enabled` or
   `RouteTableEnabled` and the UDR prefix is equal to or smaller than the VNet address space (a
   0.0.0.0/0 default route does not override it). If the value is `Disabled`, the NSG and the UDR
   are not the cause - look at Contoso edge firewall, the peering/gateway-transit flags and
   the ExpressRoute path instead. Diagnose: `Test-NetConnection <name> -Port 445` fails while
   `Resolve-DnsName` is private; `az network vnet peering show` flags; effective routes on the
   endpoint NIC (`az network nic show-effective-route-table`); private endpoint metrics show zero
   bytes. Recovery: open 445/443 from Contoso prefixes on the edge firewall (and on the NSG
   only where those network policies are on), fix peering flags (spoke: use remote gateway; hub:
   allow gateway transit), remove or scope the UDR where a route-table policy is in effect.
   ExpressRoute FastPath: private endpoint traffic needs FastPath private endpoint support or
   falls back to the gateway path - confirm which applies.
5. **Private endpoint connection Pending - approval class.** Cause: the endpoint was created
   by an identity without rights on the target resource. Diagnose: `az network private-endpoint
   show` connection state Pending; the target resource's Private endpoint connections blade
   lists it. Recovery: approve on the target (storage account, Storage Sync Service, Key Vault,
   Migrate project) or recreate with an authorised identity.
6. **Appliance-specific: proxy or hosts file - Migrate class.** Cause: the appliance's HTTP
   proxy resolves names publicly, or a hosts-file entry from testing points at an old IP.
   Diagnose: compare `nslookup` on the appliance with the project's DNS settings file; check
   `C:\Windows\System32\drivers\etc\hosts`. Recovery: add proxy bypass rules for the private
   link FQDNs (or let the proxy resolve privately), remove hosts entries once Infoblox forwards
   the zones, retry registration/discovery. (Real case: Microsoft's Migrate troubleshooting
   guide lists `ForbiddenToAccessKeyVault`, `AgentNotConnected` and the 504 on saving
   configuration as symptoms of exactly this.)
7. **Azure VM cannot resolve Contoso names - outbound class.** Cause: no forwarding ruleset
   link on the VNet or the rule targets an unreachable Infoblox member. Diagnose: `Resolve-DnsName
   dc01.contoso.local` NXDOMAIN on the VM; `az dns-resolver forwarding-rule list` shows the
   rule; `Test-NetConnection <infoblox-ip> -Port 53` fails. Note it cannot be run from the
   outbound endpoint subnet: that subnet is delegated to `Microsoft.Network/dnsResolvers` and,
   per Microsoft, is "a dedicated subnet ... with no other service running in the subnet", so no
   host can live there. Run it from a VM in another subnet of the same VNet, and - because
   `-Port` tests TCP only while a forwarding rule declares a target IP, port and protocol (UDP or
   TCP), commonly UDP 53 - also run `Resolve-DnsName dc01.contoso.local -Server <infoblox-ip>` to
   exercise the rule's actual protocol. Treat that result as indicative only (the source prefix
   differs) and separately confirm on Contoso firewall that the outbound endpoint subnet
   prefix itself is permitted to the grid members on UDP/TCP 53.
   Recovery: link the ruleset to the VNet, allow UDP/TCP 53 from the outbound endpoint subnet to
   the grid members on Contoso firewall.
8. **Verify end to end** after any recovery: `Resolve-DnsName` shows the privatelink CNAME and a
   10.x A record; `Test-NetConnection` on the service port succeeds; the service-level check
   passes (File Sync 9102 HResult 0, Migrate discovery running, mount works). Attach the
   transcript to the incident.

## How a persona runs this (-> ticket)

- **Persona:** `eng-netops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: private-endpoint-name-resolution-and-reachability`
- **CR file:** `change-management/CR-<date>-private-endpoint-name-resolution-and-reachability.md`
- **Closure:** the affected client resolves the name to the private IP AND the service operation (mount, sync session, discovery) completes - not merely the absence of the DNS error

## Gate rules

```json
[
  {"rule": "the recovery is proven by the service, not by DNS alone", "severity": "error", "check": "grep -Eq 'IP4Address *: *10\\.' incident/resolve-dnsname.txt && grep -Eq 'HResult: 0|TcpTestSucceeded *: *True|Running' incident/service-check.txt"},
  {"rule": "no hosts-file or hand-made A record survives closure", "severity": "warn", "check": "powershell -Command \"Select-String -Path C:\\Windows\\System32\\drivers\\etc\\hosts -Pattern privatelink\" | wc -l prints 0"},
  {"rule": "every symptom class names the real incident it was distilled from", "severity": "warn", "check": "grep -c 'Real case' in this file is >= 3"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-dns-for-private-endpoints.md
  anchor: "Resolution walk-throughs"
  why: the expected chain per client that each class is compared against
- path: codex/playbook-add-file-private-endpoint-and-dns.md
  anchor: "Clear-DnsClientCache"
  why: the verification sequence to rerun after recovery
- path: Assess-AzFileSyncExport.ps1
  anchor: "NET-03"
  why: the check for a pending private endpoint connection
```

Microsoft Learn (read 2026-09-03): Configure DNS forwarding for Azure Files (verify section);
Azure Private Endpoint private DNS zone values (duplicate-zone caution); Troubleshoot network
connectivity issues - Azure Migrate (DNS settings, hosts file, proxy, common errors); Azure DNS
Private Resolver overview (FastPath, outbound endpoints).
