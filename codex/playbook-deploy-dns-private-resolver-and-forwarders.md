---
slug: playbook-deploy-dns-private-resolver-and-forwarders
doc_type: playbook
kind: deploy-dns-private-resolver-and-forwarders
category: iac
title: Deploy the hub DNS Private Resolver, the privatelink zones and the Infoblox forwarders
summary: Repeatable deployment of the hybrid DNS layer: delegated subnets, DNS Private Resolver with static inbound and outbound endpoints, forwarding ruleset for contoso.local, seven privatelink zones linked to hub and spokes, Infoblox forwarders and IPAM.
when_to_use: Before the first private endpoint, or when private endpoints resolve publicly from Contoso, or when Azure VMs must resolve Contoso AD names.
applies_to: [ops, devstation]
tags: [dns, private-resolver, private-dns-zone, infoblox, bicep, avm, expressroute, contoso]
persona_run: eng-netops
ticket_kind: ops
status: published
version: 1
execution: assisted
last_verified: 2026-09-03T05:00 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

You decided to build [[blueprint-azure-dns-for-private-endpoints]]: the hub VNet exists with
ExpressRoute private peering to Contoso, the Infoblox grid is Contoso's DNS and IPAM,
and the first private endpoints (Azure Files, Azure File Sync, Azure Migrate) are about to be
created. Run it once per region hub; re-run to add zones or rules.

## Reuse before reinvent (GR11)

```yaml
- primitive: avm/res/network/dns-resolver 0.5.8, avm/res/network/dns-forwarding-ruleset 0.5.4, avm/res/network/private-dns-zone 0.8.1
  path: codex/playbook-deploy-dns-private-resolver-and-forwarders.md
  why: the three modules cover resolver, endpoints, ruleset, rules, zones and VNet links with
       locks and tags; hand-written ARM for the same resources is what drifts on the next API
       version
- primitive: Add-DnsServerConditionalForwarderZone pattern from the Azure Files DNS guide
  path: codex/blueprint-azure-dns-for-private-endpoints.md
  why: the Microsoft article uses Windows DNS; the Infoblox equivalent is a forward zone
       (forward-only) per privatelink zone with the same target - one pattern, documented once
```

## Procedure

1. **Preconditions.** Hub VNet with two free /28 blocks; Network Contributor on the hub;
   Private DNS Zone Contributor on `rg-dns-privatezones`; the list of spoke VNet ids to link;
   the Infoblox grid member IPs that will receive `contoso.local` queries from Azure; an
   Infoblox change ticket for forwarders and IPAM.
2. **Deploy `dns.bicep`** (Contoso profile):

```bicep
targetScope = 'resourceGroup'
param location string = resourceGroup().location
param hubVnetId string
param inboundSubnetId string     // /28, delegated to Microsoft.Network/dnsResolvers
param outboundSubnetId string    // /28, delegated to Microsoft.Network/dnsResolvers
param inboundStaticIp string     // e.g. 10.100.20.4 - goes into Infoblox forwarders
param spokeVnetIds array         // spokes that must resolve privatelink zones and contoso.local
param infobloxMembers array = [ '10.1.10.10', '10.1.10.11' ]
param tags object = { owner: 'itd-network', environment: 'prod' }

var zones = [
  'privatelink.file.core.windows.net'
  'privatelink.afs.azure.net'
  'privatelink.blob.core.windows.net'
  'privatelink.queue.core.windows.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.prod.migration.windowsazure.com'
  'privatelink.siterecovery.windowsazure.com'
]
var allVnets = concat([hubVnetId], spokeVnetIds)

module resolver 'br/public:avm/res/network/dns-resolver:0.5.8' = {
  name: 'dnsresolver'
  params: {
    name: 'dnspr-hub-${location}-01'
    location: location
    virtualNetworkResourceId: hubVnetId
    inboundEndpoints: [ { name: 'inbound-01', subnetResourceId: inboundSubnetId, privateIpAllocationMethod: 'Static', privateIpAddress: inboundStaticIp } ]
    outboundEndpoints: [ { name: 'outbound-01', subnetResourceId: outboundSubnetId } ]
    lock: { kind: 'CanNotDelete', name: 'lock-dnspr' }
    tags: tags
  }
}

module ruleset 'br/public:avm/res/network/dns-forwarding-ruleset:0.5.4' = {
  name: 'dnsruleset'
  params: {
    name: 'dnsfrs-hub-${location}-01'
    location: location
    dnsForwardingRulesetOutboundEndpointResourceIds: [ resolver.outputs.outboundEndpointsObject[0].resourceId ]
    forwardingRules: [
      { name: 'organization-local', domainName: 'contoso.local.', forwardingRuleState: 'Enabled', targetDnsServers: [for ip in infobloxMembers: { ipAddress: ip, port: 53 }] }
      // add reverse zones for Contoso prefixes, e.g. { name: 'rev-10-1', domainName: '1.10.in-addr.arpa.', ... }
    ]
    virtualNetworkLinks: [for (id, i) in allVnets: { name: 'link-${i}', virtualNetworkResourceId: id }]
    tags: tags
  }
}

module pdz 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for z in zones: {
  name: 'pdz-${replace(z, '.', '-')}'
  params: {
    name: z
    virtualNetworkLinks: [for (id, i) in allVnets: { name: 'link-${i}', virtualNetworkResourceId: id, registrationEnabled: false }]
    lock: { kind: 'CanNotDelete', name: 'lock-pdz' }
    tags: tags
  }
}]
output inboundIp string = inboundStaticIp
```

   If the resolver module's output name differs in the pinned version, read the outbound
   endpoint id with `az dns-resolver outbound-endpoint show` and pass it as a parameter.
3. **Infoblox forwarders.** For each zone in `zones`, create a forward zone (forward-only) to
   the inbound endpoint IP on the grid members serving the file servers, the Migrate appliance
   and the workstations. Register the inbound and outbound endpoint IPs in IPAM.
4. **Verify from Contoso** (`Resolve-DnsName` of an existing private endpoint name returns
   a 10.x address; if no endpoint exists yet, `Resolve-DnsName privatelink.file.core.windows.net
   -Type SOA -Server <inbound-ip>` returns the Azure SOA `azureprivatedns-host.microsoft.com`).
5. **Verify from Azure** (a spoke VM resolves `dc01.contoso.local`).
6. **Record** the inbound IP in the landing-zone design and in
   [[blueprint-azure-dns-for-private-endpoints]] (Contoso profile table).

## Steps

```yaml
vars:
  - name: rg
    describe: connectivity resource group for DNS resources
    required: true
  - name: hub_vnet_id
    describe: resource id of the hub VNet
    required: true
  - name: inbound_subnet_id
    describe: delegated /28 subnet id for the inbound endpoint
    required: true
  - name: outbound_subnet_id
    describe: delegated /28 subnet id for the outbound endpoint
    required: true
  - name: inbound_ip
    describe: static IP for the inbound endpoint (not one of the subnet's reserved addresses)
    required: true
  - name: spoke_ids
    describe: JSON array of spoke VNet ids
    required: true
steps:
  - name: preconditions (delegations)
    run: az network vnet subnet show --ids <inbound_subnet_id> --query "delegations[0].serviceName" -o tsv && az network vnet subnet show --ids <outbound_subnet_id> --query "delegations[0].serviceName" -o tsv
    verify: prints Microsoft.Network/dnsResolvers twice
  - name: deploy
    run: az deployment group create -g <rg> -f dns.bicep -p hubVnetId=<hub_vnet_id> inboundSubnetId=<inbound_subnet_id> outboundSubnetId=<outbound_subnet_id> inboundStaticIp=<inbound_ip> spokeVnetIds='<spoke_ids>'
    verify: provisioningState Succeeded; output inboundIp equals <inbound_ip>
  - name: resolver state
    run: az dns-resolver show -g <rg> -n dnspr-hub-<region>-01 --query dnsResolverState -o tsv
    verify: prints Connected
  - name: zones and links
    run: az network private-dns zone list -g <rg> --query "[].name" -o tsv && az network private-dns link vnet list -g <rg> -z privatelink.file.core.windows.net --query "length(@)"
    verify: seven zone names and a link count equal to 1 + number of spokes
  - name: confirm the effect from Contoso
    run: powershell -Command "Resolve-DnsName privatelink.file.core.windows.net -Type SOA -Server <inbound_ip> | Select Name,NameAdministrator"
    verify: NameAdministrator is azureprivatedns-host.microsoft.com (the query reached Azure DNS through the inbound endpoint over ExpressRoute)
  - name: confirm on-premises forwarding from Azure
    run: powershell -Command "(Resolve-DnsName dc01.contoso.local -Type A).IP4Address"
    verify: prints the domain controller IP when run on a linked spoke VM
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-netops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: deploy-dns-private-resolver-and-forwarders`
- **CR file:** `change-management/CR-<date>-deploy-dns-private-resolver-and-forwarders.md`
- **Closure:** every `verify:` passes and the Infoblox forwarders for all seven zones point at the inbound endpoint IP

## Gate rules

```json
[
  {"rule": "the inbound endpoint IP is static and documented", "severity": "error", "check": "az dns-resolver inbound-endpoint show -g <rg> --dns-resolver-name dnspr-hub-<region>-01 -n inbound-01 --query \"ipConfigurations[0].[privateIpAllocationMethod, privateIpAddress]\" -o tsv prints Static and the documented IP"},
  {"rule": "no wildcard rule without a public-capable target", "severity": "warn", "check": "az dns-resolver forwarding-rule list -g <rg> --ruleset-name dnsfrs-hub-<region>-01 --query \"[?domainName=='.'] | length(@)\" prints 0"},
  {"rule": "each zone exists once", "severity": "error", "check": "az network private-dns zone list --query \"[?starts_with(name,'privatelink.')].name\" -o tsv | sort | uniq -d prints nothing"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-dns-for-private-endpoints.md
  anchor: "Resolution walk-throughs"
  why: the expected answers this deployment must produce
- path: codex/playbook-add-file-private-endpoint-and-dns.md
  anchor: "Infoblox forwarder"
  why: the first consumer of the inbound endpoint
- path: Assess-AzFileSyncExport.ps1
  anchor: "NET-10"
  why: the check that fires when the topology has no gateway for the private path
```

Microsoft Learn / registries (read 2026-09-03): Azure DNS Private Resolver overview (subnet
/28, delegation, limits, FastPath); Create an Azure DNS Private Resolver using PowerShell
(cmdlet sequence); Configure DNS forwarding for Azure Files; AVM module READMEs and MCR tag
lists for dns-resolver (0.5.8), dns-forwarding-ruleset (0.5.4), private-dns-zone (0.8.1).
