---
slug: runbook-file-sync-broken-after-network-lockdown
doc_type: runbook
kind: file-sync-broken-after-network-lockdown
category: infra
title: Respond to Azure File Sync failing after a firewall or private endpoint change
summary: Incident classes when sync, change enumeration or recalls stop after a network hardening step: trusted services removed, public access disabled, Storage Sync Service endpoint disabled too early, afs names public, proxy, certificate, time.
when_to_use: Server endpoints turn Error or Appears Offline, cloud endpoint operations fail, or recalls stop within hours of a firewall or endpoint change.
applies_to: [ops, devstation]
tags: [azure-file-sync, incident, firewall, private-endpoint, storage-sync-service, dns, contoso]
persona_run: eng-sysops
ticket_kind: bug-known
status: published
version: 1
execution: advisory
last_verified: 2026-09-03T05:00 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

Loud: users report stale files, the portal shows server endpoints in **Error** or registered
servers **Appears Offline**, Telemetry event 9102 logs a non-zero HResult, tiered files fail
to open. Silent: sync sessions still complete but cloud change enumeration never finishes, or
the storage account metrics show every request from the servers hitting the public IP. The
trigger class is a network change made by [[playbook-harden-existing-storage-account]] or
[[playbook-enable-file-sync-private-endpoint-and-cutover]] in the last 24 hours.

## Reuse before reinvent (GR11)

```yaml
- primitive: Debug-StorageSyncServer -Diagnose / -TestNetworkConnectivity / -FileSyncErrorsReport
  path: Get-AfsServerDiagnostics.ps1
  why: Microsoft merged AFSDiag, the errors report and the connectivity test into one cmdlet;
       it separates server-side causes (certificate, time, proxy) from cloud-side ones
- primitive: assessor rules AFS-11, AFS-14, SEC-05, NET-05..NET-08
  path: Assess-AzFileSyncExport.ps1
  why: the cloud-side misconfigurations below are exactly the ones the assessor names, so a
       rerun of the export pinpoints the class without guessing
- primitive: rollback commands in the private-path blueprint
  path: codex/blueprint-azure-file-sync-private-path.md
  why: AllowAllTraffic and defaultAction Allow restore service in minutes while the root cause
       is fixed
```

## Response

1. **Cloud endpoint operations and change enumeration fail; server sessions may still run -
   trusted-services class.** Cause: the storage firewall was set to Deny without `bypass
   AzureServices` (or the bypass was removed later), so the Storage Sync Service cannot reach
   the share. Diagnose: `az storage account show --query networkRuleSet.bypass` lacks
   `AzureServices`; cloud endpoint shows a failed last operation; assessor AFS-14. Recovery:
   `az storage account update --bypass AzureServices`; retry the cloud endpoint operation.
   There is no storage resource instance rule for File Sync - `Microsoft.StorageSync` is listed
   only among trusted services registered in the Entra tenant, not in the managed-identity
   resource-instance table, so `bypass AzureServices` is the only supported path. (Real case: the
   Microsoft File Sync networking article warns the trusted-services checkbox is required for the
   sync service when the public endpoint is restricted.)
2. **Everything File Sync fails on that account - public-network-disabled class.** Cause:
   `publicNetworkAccess` was set to `Disabled` (the portal's "Disable" button), which rejects
   every IP-rule and service-endpoint path to the public endpoint. It does not by itself cut the
   trusted-services path: Microsoft documents that access from trusted services takes the highest
   precedence, and any exceptions and resource instance rules configured before the switch -
   including `bypass AzureServices` - remain in effect, so the Storage Sync Service may still
   reach the share. This class breaks File Sync only where no `bypass AzureServices` exception
   was ever configured. Diagnose: `az storage account show --query publicNetworkAccess`
   prints Disabled; assessor SEC-05. Recovery: set `publicNetworkAccess Enabled` with
   `defaultAction Deny` + `bypass AzureServices`; keep the private endpoint for the servers.
3. **All registered servers Appears Offline, 9301 shows errors - Storage Sync Service
   endpoint class.** Cause: `incomingTrafficPolicy AllowVirtualNetworksOnly` was set while the
   servers still resolved `*.afs.azure.net` to public IPs (no forwarder, no zone record, or no
   private endpoint). Diagnose: on a server `Resolve-DnsName <sss>management.<region>.afs.azure.net`
   (and `<sss>syncp.`, `<sss>syncs.`, `<sss>monitoring.<region>.afs.azure.net` - the four names a
   Storage Sync Service private endpoint publishes, e.g. mysssmanagement.westus2.afs.azure.net)
   returns a public IP or NXDOMAIN; `Debug-StorageSyncServer -TestNetworkConnectivity` fails
   for the management and sync endpoints; assessor AFS-11 / NET-05. Recovery: immediately
   `Set-AzStorageSyncService -IncomingTrafficPolicy AllowAllTraffic` to restore sync, then fix
   the Storage Sync Service private endpoint, its DNS zone group and the Infoblox forwarder for
   `privatelink.afs.azure.net`, verify on every server, and cut over again.
4. **Servers sync control traffic but uploads, downloads or recalls fail - storage private
   path class.** Cause: the account firewall denies the servers' public IPs and
   `<account>.file.core.windows.net` still resolves publicly on the servers (missing
   `privatelink.file.core.windows.net` forwarder), or the private endpoint connection is
   Pending. Diagnose: 9102 sessions with per-item errors and recall errors (9006), storage
   account resource logs show 403 from the server IPs; `Resolve-DnsName` on the server returns
   a public IP. Recovery: fix DNS per [[runbook-private-endpoint-name-resolution-and-reachability]],
   approve the endpoint, or temporarily add the servers' egress IPs as IP rules.
5. **One server only - proxy, certificate or time class.** Cause: a machine-wide proxy that
   cannot resolve the private link names, an expired server certificate, or clock skew.
   Diagnose: `Debug-StorageSyncServer -Diagnose` reports certificate or time errors;
   `netsh winhttp show proxy` shows a proxy; `w32tm /query /status` shows a large phase
   offset. Recovery: set the File Sync app-specific proxy (`Set-StorageSyncProxyConfiguration`)
   or proxy bypass for `*.afs.azure.net` and `*.core.windows.net`, fix time sync, reset the
   server authentication certificate on the affected server with
   `Reset-AzStorageSyncServerCertificate -ResourceGroupName <rg> -StorageSyncServiceName <sss>` -
   Microsoft's documented remediation for ECS_E_AUTH_SRV_CERT_EXPIRED,
   ECS_E_AUTH_SRV_CERT_NOT_FOUND and ECS_E_SERVER_INVALID_OR_EXPIRED_CERTIFICATE; restarting
   FileSyncSvc does not renew it.
6. **After a GRS failover or region move - regional endpoint class.** Cause: Contoso
   firewall allow-list only contains the primary region's `https://<region>01.afs.azure.net`,
   not the paired region and discovery URL. Diagnose: connectivity test fails only for the
   paired-region URL. Recovery: add the paired region and `https://tm-<region>01.afs.azure.net`
   entries, or the `StorageSyncService` service tag ranges.
7. **Verify** after any recovery, on every server: `Debug-StorageSyncServer
   -TestNetworkConnectivity` succeeds; the next 9102 has HResult 0; 9301 heartbeats resume;
   a single tiered file recalls (`Invoke-StorageSyncFileRecall` scoped with -Pattern, never
   unqualified - an unqualified -Path recalls the entire tiered dataset); the cloud endpoint's
   last operation succeeded; the assessor with `-PrivateTrafficRequired` shows no AFS-11,
   AFS-14, SEC-05.

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: file-sync-broken-after-network-lockdown`
- **CR file:** `change-management/CR-<date>-file-sync-broken-after-network-lockdown.md`
- **Closure:** every server endpoint is Healthy, a cloud change enumeration completed after the fix, and a recall test succeeded - not merely the portal error disappearing

## Gate rules

```json
[
  {"rule": "recovery is verified by a completed sync session and a scoped single-file recall - never an unqualified -Path recall, which recalls the entire tiered dataset and fails outright if volume free space is insufficient", "severity": "error", "check": "powershell -Command \"(Get-WinEvent -FilterHashtable @{LogName='Microsoft-FileSync-Agent/Telemetry'; Id=9102; StartTime=(Get-Date).AddHours(-1)} | Select -First 1).Message\" contains HResult: 0 and Invoke-StorageSyncFileRecall -Path \"<server-endpoint-path>\" -Pattern <single-file-name> exits 0 and the recalled file loses its Offline (O) attribute"},
  {"rule": "the storage account keeps public network access Enabled with Deny + AzureServices", "severity": "error", "check": "az storage account show -n <account> -g <rg> --query \"[not_null(publicNetworkAccess,'Enabled'), networkRuleSet.defaultAction, networkRuleSet.bypass]\" -o tsv prints Enabled Deny AzureServices - use not_null, NOT coalesce, which is not a JMESPath function; publicNetworkAccess is an optional property and stays unset (empty tsv field) unless recovery materialises it with az storage account update -n <account> -g <rg> --public-network-access Enabled"},
  {"rule": "every symptom class names the real incident it was distilled from", "severity": "warn", "check": "grep -c 'Real case' in this file is >= 1"}
]
```

## Reference

```yaml
- path: codex/blueprint-azure-file-sync-private-path.md
  anchor: "Rollback"
  why: the reversible commands class 3 uses first
- path: codex/runbook-private-endpoint-name-resolution-and-reachability.md
  anchor: "forwarder class"
  why: the DNS classes that underlie classes 3 and 4
- path: Get-AfsServerDiagnostics.ps1
  anchor: "Debug-StorageSyncServer -TestNetworkConnectivity"
  why: the server-side evidence collected in one bundle
```

Microsoft Learn (read 2026-09-03): Configure Azure File Sync network endpoints (trusted
services, disable public endpoint warning); Azure File Sync on-premises firewall and proxy
settings (regional URLs, proxy cmdlets, connectivity test); Use Debug-StorageSyncServer
cmdlet; Troubleshoot Azure File Sync (general steps).
