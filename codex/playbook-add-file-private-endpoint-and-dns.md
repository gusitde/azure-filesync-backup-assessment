---
slug: playbook-add-file-private-endpoint-and-dns
doc_type: playbook
kind: add-file-private-endpoint-and-dns
category: ops
title: Add a file private endpoint to an existing storage account and resolve it from Contoso
summary: Create the file private endpoint, DNS zone group and privatelink.file.core.windows.net record for an existing account, register the IP in Infoblox IPAM, add the forwarder, and verify resolution and SMB reachability over ExpressRoute.
when_to_use: An existing storage account with file shares must become reachable over ExpressRoute or VPN, or the assessor reports NET-06 or NET-02 for it.
applies_to: [ops, devstation]
tags: [azure-files, private-endpoint, dns, infoblox, expressroute, azure-cli, contoso]
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

The storage account already holds Contoso's shares (and File Sync cloud endpoints) on the
public endpoint. You decided to add the private path first and lock the public endpoint later
([[playbook-harden-existing-storage-account]]). The hub DNS design exists
([[blueprint-azure-dns-for-private-endpoints]]); if not, deploy it first - a private endpoint
nobody can resolve is the top cause in Microsoft's Private Link troubleshooting guide.

## Reuse before reinvent (GR11)

```yaml
- primitive: az network private-endpoint create + dns-zone-group create
  path: codex/playbook-add-file-private-endpoint-and-dns.md
  why: the DNS zone group keeps the A record in step with the endpoint IP; the manual
       record-set commands in the Microsoft article are only needed when no zone group exists
- primitive: privatelink.file.core.windows.net zone (one per estate)
  path: codex/blueprint-azure-dns-for-private-endpoints.md
  why: a second private DNS zone with the same name cannot even be linked to the same VNet -
       Azure rejects the link with "A virtual network cannot be linked to multiple zones with
       overlapping namespaces"; the one linked zone then answers NXDOMAIN for every name in
       that namespace it holds no record for (unless the link is set to --resolution-policy
       NxDomainRedirect, which falls back to public resolution); reuse the central zone
```

## Procedure

1. **Preconditions.** Network Contributor on the spoke VNet, Contributor on the storage account
   resource group, Private DNS Zone Contributor on the zone's resource group; the
   private-endpoint subnet has `privateEndpointNetworkPolicies` Disabled (or an NSG that allows
   445/443 from Contoso prefixes); an Infoblox change window for the forwarder and the IPAM
   reservation.
2. **Create the private endpoint** for sub-resource `file` with a connection name that
   identifies the account; it auto-approves when the creator owns the account, otherwise
   approve it under the account's Private endpoint connections.
3. **Attach the DNS zone group** referencing the central `privatelink.file.core.windows.net`
   zone; confirm the A record `<account>` appears with the endpoint NIC's private IP.
4. **IPAM.** Reserve the endpoint IP in Infoblox with the FQDN `<account>.privatelink.file.core.windows.net`
   and the extensible attribute `azure-resource-id` = the private endpoint id.
5. **Infoblox forwarder.** If not yet present, add the conditional forwarder
   `privatelink.file.core.windows.net` -> Private Resolver inbound endpoint IP on every grid
   member that serves the file servers; forward-only. Clear the DNS client cache on the test
   server (`Clear-DnsClientCache`).
6. **Verify** from a Contoso file server (and from the File Sync servers): the CNAME chain and
   private IP, TCP 445 and 443 reachability, and a mount with an AD identity. Microsoft:
   "Azure File Shares must be remounted if connected to the public endpoint" - before step 7,
   on every Contoso file server clear the DNS client cache (`Clear-DnsClientCache`), then
   disconnect and remount each existing mapping (`net use <drive> /delete` then remount, or
   reboot) and re-run this verify, so no session is still bound to the public endpoint when
   the firewall goes to Deny. Watch the File Sync Telemetry log for the next 9102 event with
   HResult 0 - the agent now uploads and recalls through the private endpoint.
7. **Only then** proceed to the storage firewall lock-down in
   [[playbook-harden-existing-storage-account]].

## Steps

```yaml
vars:
  - name: rg
    describe: resource group of the storage account
    required: true
  - name: account
    describe: storage account name
    required: true
  - name: pe_rg
    describe: resource group for the private endpoint (usually the spoke network RG)
    required: true
  - name: subnet_id
    describe: resource id of the private-endpoint subnet
    required: true
  - name: zone_rg
    describe: resource group of privatelink.file.core.windows.net
    required: true
  - name: location
    describe: region of the spoke VNet
    required: true
steps:
  - name: preconditions
    run: az network private-dns zone show -g <zone_rg> -n privatelink.file.core.windows.net --query name -o tsv && az network vnet subnet show --ids <subnet_id> --query privateEndpointNetworkPolicies -o tsv
    verify: prints the zone name and Disabled
  - name: create the endpoint
    run: az network private-endpoint create -g <pe_rg> -n pe-<account>-file -l <location> --subnet <subnet_id> --private-connection-resource-id $(az storage account show -g <rg> -n <account> --query id -o tsv) --group-id file --connection-name <account>-file-connection --nic-name nic-pe-<account>-file
    verify: provisioningState Succeeded and privateLinkServiceConnections[0].privateLinkServiceConnectionState.status is Approved
  - name: dns zone group
    run: az network private-endpoint dns-zone-group create -g <pe_rg> --endpoint-name pe-<account>-file -n default --zone-name file --private-dns-zone $(az network private-dns zone show -g <zone_rg> -n privatelink.file.core.windows.net --query id -o tsv)
    verify: az network private-dns record-set a show -g <zone_rg> -z privatelink.file.core.windows.net -n <account> prints the endpoint private IP
  - name: endpoint ip for ipam
    run: az network nic show --ids $(az network private-endpoint show -g <pe_rg> -n pe-<account>-file --query "networkInterfaces[0].id" -o tsv) --query "ipConfigurations[0].privateIPAddress" -o tsv
    verify: prints the IP; the same IP is reserved in Infoblox IPAM
  - name: confirm the effect from Contoso
    run: powershell -Command "Clear-DnsClientCache; Resolve-DnsName <account>.file.core.windows.net | Format-Table Name,Type,NameHost,IP4Address; (Test-NetConnection <account>.file.core.windows.net -CommonTCPPort SMB).TcpTestSucceeded; (Test-NetConnection <account>.file.core.windows.net -Port 443).TcpTestSucceeded"
    verify: CNAME to <account>.privatelink.file.core.windows.net, A record with the endpoint IP, and True twice - run on a Contoso file server
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-netops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: add-file-private-endpoint-and-dns`
- **CR file:** `change-management/CR-<date>-add-file-private-endpoint-and-dns.md`
- **Closure:** every `verify:` passes on every Contoso file server and the endpoint IP is reserved in Infoblox IPAM

## Gate rules

```json
[
  {"rule": "the endpoint has a DNS zone group (no hand-made A records)", "severity": "error", "check": "az network private-endpoint dns-zone-group list -g <pe_rg> --endpoint-name pe-<account>-file --query \"length(@)\" prints 1"},
  {"rule": "the zone holds exactly one A record for the account", "severity": "error", "check": "az network private-dns record-set a show -g <zone_rg> -z privatelink.file.core.windows.net -n <account> --query \"length(aRecords)\" prints 1"},
  {"rule": "on-premises resolution is private before any firewall change", "severity": "error", "check": "powershell -Command \"(Resolve-DnsName <account>.file.core.windows.net -Type A).IP4Address\" on a Contoso server prints the endpoint IP"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-files-private-endpoint.md
  anchor: "Sizing and naming (Contoso profile)"
  why: the names, subnet and IPAM conventions this playbook applies
- path: codex/blueprint-azure-dns-for-private-endpoints.md
  anchor: "Infoblox"
  why: the forwarder configuration step 5 depends on
- path: Assess-AzFileSyncExport.ps1
  anchor: "NET-04"
  why: the check for an endpoint without a DNS zone group
```

Microsoft Learn (read 2026-09-03): Configure Azure Files network endpoints (create a private
endpoint - Azure CLI, verify connectivity); Configure DNS forwarding for Azure Files; Azure
Private Endpoint private DNS zone values.
