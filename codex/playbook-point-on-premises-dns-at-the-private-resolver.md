---
slug: playbook-point-on-premises-dns-at-the-private-resolver
doc_type: playbook
kind: point-on-premises-dns-at-the-private-resolver
category: ops
title: Point on-premises DNS at the Azure DNS Private Resolver
summary: The on-premises half of hybrid name resolution: forward the public zone rather than the privatelink one, gate the change on the resolver actually answering privately, and keep an exact reverse path.
when_to_use: On-premises clients resolve an Azure private endpoint to its public address, and a DNS Private Resolver inbound endpoint exists to forward to.
applies_to: [ops, devstation]
tags: [dns, conditional-forwarder, private-resolver, private-endpoint, windows-dns, infoblox, contoso]
persona_run: eng-netops
ticket_kind: ops
status: published
version: 1
execution: assisted
last_verified: 2026-09-03T16:30 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

[[playbook-deploy-dns-private-resolver-and-forwarders]] built the Azure side: the resolver, the
inbound endpoint and the private zones. This is the on-premises half - the conditional
forwarders that make a client on your own network resolve the storage account to its private
address. Also used to reverse that.

## Reuse before reinvent (GR11)

```yaml
- primitive: onprem/Set-AfsDnsForwarders.ps1
  path: onprem/Set-AfsDnsForwarders.ps1
  why: does the whole procedure including the safety gate; the gate is the reason to use the
       script rather than the two cmdlets
- primitive: codex/blueprint-azure-dns-for-private-endpoints.md
  path: codex/blueprint-azure-dns-for-private-endpoints.md
  why: the zone set and the resolution flows this playbook implements
```

## Procedure

1. **Forward the PUBLIC zone, not the privatelink zone.** This is the step almost everyone gets
   wrong, so it is first.

   A client asks for `<account>.file.core.windows.net`. Azure answers with a CNAME to
   `<account>.privatelink.file.core.windows.net` and then the address - **and a recursive
   resolver returns that entire chain in one answer**. So a conditional forwarder on
   `privatelink.file.core.windows.net` is never consulted: the name the client asked for does
   not end in that suffix, and no separate query for the privatelink name is ever issued. The
   forwarder is created, looks correct, passes a "does the zone exist" check, and does nothing.

   The exception is a resolver that performs its own iterative resolution from root hints: it
   receives the CNAME, restarts resolution for the privatelink name, and at that point does
   consult its forwarders. That is the narrow case in which a privatelink forwarder works - and
   it is not the common case, because most on-premises resolvers forward to an upstream server.

   Microsoft's guidance leaves no room: forward the public zone. For Azure Files that is
   `file.core.windows.net`, and for Azure File Sync `afs.azure.net`. Forwarding the whole
   `core.windows.net` also works and is what the Azure Files runbook shows, but it drags blob,
   queue, table, dfs and web along with it, and it breaks access to storage accounts in other
   tenants that have private endpoints. Prefer the narrower zone.

2. **Understand the blast radius before writing.** Once `file.core.windows.net` is forwarded,
   every on-premises query for every storage account under that suffix goes to the resolver. If
   the resolver cannot be reached, clients get SERVFAIL after about eleven seconds per query -
   with the default five-second forwarder timeout and two masters, the server's own eight-second
   recursion budget expires before it can fall back, so the documented fallback to root hints
   never actually happens. Set the forwarder timeout to 2 or 3 seconds to make that fallback
   reachable, and never set `UseRecursion` to false, which removes it entirely.

3. **A wrong answer is worse than no answer.** A resolver that replies REFUSED, or NXDOMAIN
   because the private DNS zone is not linked to its virtual network, has its reply passed
   straight back to the client with no fallback and no delay. So the gate is not "can I reach
   the resolver" but "does the resolver return a private address for a name it should know".
   The script refuses to write otherwise.

4. **Replication does not reach everything.** `-ReplicationScope Forest` reaches domain
   controllers **that run the DNS Server role** - not member servers running DNS, not Infoblox,
   not BIND. Name every resolver your clients actually use and verify each one.

5. **Windows Server DNS.** `Add-DnsServerConditionalForwarderZone -Name <public zone>
   -MasterServers <inbound IP> -ReplicationScope Forest`. Omitting `-ReplicationScope` silently
   selects the file-backed parameter set and creates a forwarder local to that one server.
   There is no `Remove-DnsServerConditionalForwarderZone`; removal is `Remove-DnsServerZone`.

6. **Infoblox.** Data Management > DNS > Zones > Add > Zone > Add Forward Zone, name = the
   public zone, forwarding to the inbound endpoint address. Over WAPI the object is
   `zone_forward`; `fqdn` is the only required field, but a zone with **no forwarding member**
   (`forwarding_servers` or `ns_group`) is accepted by the API and never written into
   `named.conf`, so it silently does nothing and queries go to the root servers. Each
   `forward_to` entry needs both `address` and `name`.

7. **Clear the cache, in both directions.** After adding the forwarder the server still holds
   the public addresses it looked up earlier and will serve them until they expire. After
   removing it, it holds private addresses that clients may no longer be able to route to.
   `Clear-DnsServerCache -Force` both times - it flushes the whole cache, so expect a brief
   upstream spike.

8. **Test from a client, not from the DNS server, and not with `-Server`.** That is the only
   test that exercises the forwarder. Then test SMB: a client that now resolves to a private
   address it cannot route to fails at port 445 instead of at DNS, which is harder to diagnose.
   Shares mounted against the public address must be remounted.

## Steps

```yaml
vars:
  - name: context
    describe: path to deployment-context.json
    required: true
  - name: dns_servers
    describe: comma-separated DNS servers to change
    required: true
steps:
  - name: dry run, which is also the safety check
    run: powershell -File onprem/Set-AfsDnsForwarders.ps1 -Context <context> -DnsServer <dns_servers> -WhatIf
    verify: the zones listed are the PUBLIC ones (file.core.windows.net, afs.azure.net), and the run either proves the resolver returns a private address or refuses
  - name: prove the resolver answers correctly, by hand
    run: powershell -Command "Resolve-DnsName -Name <account>.privatelink.file.core.windows.net -Server <inbound_ip> -Type A -DnsOnly -QuickTimeout"
    verify: an A record with a PRIVATE address (10.x, 172.16-31.x, 192.168.x). A public address means the private DNS zone is not linked to the resolver's virtual network
  - name: apply
    run: powershell -File onprem/Set-AfsDnsForwarders.ps1 -Context <context> -DnsServer <dns_servers>
    verify: one forwarder per zone per server, then the cache cleared
  - name: the forwarder is there and points at the resolver
    run: powershell -Command "Get-DnsServerZone -Name file.core.windows.net -ComputerName <dns_server> | Select-Object ZoneName,ZoneType,MasterServers,ForwarderTimeout"
    verify: ZoneType Forwarder and MasterServers is the inbound endpoint address
  - name: confirm from a client
    run: powershell -Command "Clear-DnsClientCache; Resolve-DnsName <account>.file.core.windows.net"
    verify: a CNAME to the privatelink name and then a PRIVATE address
  - name: confirm SMB actually reaches it
    run: powershell -Command "Test-NetConnection <account>.file.core.windows.net -CommonTCPPort SMB"
    verify: TcpTestSucceeded True - DNS being right is not the same as being reachable
  - name: reverse it
    run: powershell -File onprem/Set-AfsDnsForwarders.ps1 -Context <context> -DnsServer <dns_servers> -Remove
    verify: the forwarders are gone, the cache is cleared, and a client resolves the public address again
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-netops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: point-on-premises-dns-at-the-private-resolver`
- **CR file:** `change-management/CR-<date>-on-premises-dns-forwarders.md`
- **Closure:** a client on the on-premises network resolves the storage account to its private
  address and reaches it on port 445, on every DNS server in the estate

## Gate rules

```json
[
  {"rule": "the forwarded zone is the public one, not privatelink", "severity": "error", "check": "Get-DnsServerZone -ComputerName <dns_server> | Where-Object ZoneType -eq 'Forwarder' lists file.core.windows.net and afs.azure.net, and does NOT rely on a privatelink.* forwarder, which is never consulted when the resolver forwards upstream"},
  {"rule": "the resolver returns a private address before any forwarder is created", "severity": "error", "check": "Resolve-DnsName -Name <account>.privatelink.file.core.windows.net -Server <inbound_ip> returns an RFC1918 address"},
  {"rule": "every resolver clients use was changed, not only the domain controllers", "severity": "error", "check": "for each DNS server in the estate, Get-DnsServerZone -Name file.core.windows.net -ComputerName <server> returns a Forwarder zone - AD replication reaches only domain controllers running the DNS role"},
  {"rule": "recursion fallback is still available", "severity": "warn", "check": "(Get-DnsServerZone -Name file.core.windows.net -ComputerName <server>).UseRecursion is not False, and ForwarderTimeout is 3 or less so the fallback is reachable within the recursion budget"},
  {"rule": "a client resolves privately and can reach it", "severity": "error", "check": "Clear-DnsClientCache; Resolve-DnsName <account>.file.core.windows.net returns a private address, and Test-NetConnection <account>.file.core.windows.net -CommonTCPPort SMB succeeds"}
]
```

## Reference

```yaml
- path: onprem/Set-AfsDnsForwarders.ps1
  anchor: "WHICH ZONE TO FORWARD"
  why: the mechanism, written where the operator running it will read it
- path: codex/blueprint-azure-dns-for-private-endpoints.md
  anchor: "On-premises conditional forwarders"
  why: the zone set and the design this implements
- path: codex/runbook-private-endpoint-name-resolution-and-reachability.md
  anchor: "Public IP"
  why: the symptom that brings someone here
```

Microsoft Learn (read 2026-09-03): Azure Private Endpoint DNS integration scenarios ("The
conditional forwarding must be made to the recommended public DNS zone forwarder ... for example
database.windows.net instead of privatelink.database.windows.net"); Configure DNS forwarding for
Azure Files; Azure Private Endpoint private DNS zone values (the "Public DNS zone forwarders"
column); Azure DNS Private Resolver overview and endpoints; DnsServer module reference;
KB2834250 forwarder resolution timeouts. Infoblox NIOS 9.0 Configuring a Forward-Mapping Zone
and the WAPI `zone_forward` reference.
