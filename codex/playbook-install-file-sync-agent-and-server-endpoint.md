---
slug: playbook-install-file-sync-agent-and-server-endpoint
doc_type: playbook
kind: install-file-sync-agent-and-server-endpoint
category: ops
title: Install the Azure File Sync agent on a file server, register it, and sync a folder to an Azure file share
summary: One idempotent run that checks the server, installs the agent silently, registers it, and creates the sync group, cloud endpoint and server endpoint - with the identity split the cloud endpoint forces.
when_to_use: A file server has to start syncing to an Azure file share, or an existing registration has to be repaired or removed.
applies_to: [ops, devstation]
tags: [azure-file-sync, agent, server-endpoint, cloud-endpoint, sync-group, winrm, contoso]
persona_run: eng-sysops
ticket_kind: ops
status: published
version: 1
execution: assisted
last_verified: 2026-09-03T16:30 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

The Azure side is built ([[playbook-deploy-secure-storage-account-and-share]] and the Storage
Sync Service from [[blueprint-azure-file-sync-private-path]]) and a file server now has to sync
a folder into one of the shares. Also used to repair a half-finished registration, and - with
`-Remove` - to take a server back out cleanly.

## Reuse before reinvent (GR11)

```yaml
- primitive: onprem/Install-AfsServerEndpoint.ps1
  path: onprem/Install-AfsServerEndpoint.ps1
  why: does every step below idempotently, with -WhatIf and a reverse path; run it rather than
       repeating the cmdlets by hand
- primitive: deploy/deployment-context.json
  path: deploy/Phase1-New-DeploymentIdentity.ps1
  why: names, subscription and the deployment identity all come from the context, so the
       on-premises run cannot disagree with what was built
- primitive: deploy/AfsLog.ps1
  path: deploy/AfsLog.ps1
  why: the same log, jsonl and transcript as the Azure build - one run, one record
```

## Procedure

1. **Two identities, and the reason.** Registering the server and creating the sync group need
   Contributor, which the deployment identity has. **Creating the cloud endpoint does not**: it
   grants the Azure File Sync service `Reader and Data Access` on the storage account, and that
   is a role assignment. Contributor carries `Microsoft.Authorization/*/Write` in its
   `notActions`, so it cannot create one. That step runs as a signed-in operator holding Owner,
   User Access Administrator, or Azure File Sync Administrator on the storage account. The
   script checks before it tries and prints the exact grant if not.
2. **Server prerequisites.** Windows Server 2016, 2019, 2022 or 2025; .NET Framework 4.7.2 or
   later (registry `Release` >= 461808); PowerShell 5.1; the server endpoint path on a local
   NTFS volume - never a mapped drive or a UNC path, and never the system volume if cloud
   tiering is wanted. `Az.Accounts` and `Az.StorageSync` must be **on the file server**, because
   `Register-AzStorageSyncServer` only runs there. A fresh server usually lacks the NuGet
   provider, so the script bootstraps it and falls back to copying the modules from the operator
   machine when the Gallery is unreachable.
3. **The agent install must be detached.** The installer closes PowerShell sessions while it
   runs, which kills the very remoting session that started it. Run it from a scheduled task as
   SYSTEM and poll the registry for the version. Use `/qn /norestart`: `/qn` alone will reboot
   the server if the MSI decides it needs to.
4. **Registration.** Runs inside the session on the server, signed in as the deployment identity
   with `-Scope Process` so the secret never lands in a profile on disk. Internet Explorer
   Enhanced Security is relaxed first (documented requirement) and the previous value recorded.
5. **One sync group per share.** A sync group holds exactly one cloud endpoint, so the name is
   `sg-<prefix>-<share>` and not one group for everything.
6. **Cloud endpoint, then server endpoint.** Creating the cloud endpoint takes a share snapshot
   that Azure never deletes - repeated build and teardown cycles accumulate them.
7. **Reading health.** The server knows before Azure does. Events 9301, 9302 and 9102 in
   `Microsoft-FileSync-Agent/Telemetry` are the first signal; the portal and ARM lag about
   fifteen minutes. A newly created cloud endpoint on a non-empty share reports `0x80c8300f`
   (replica not ready) for a while, which just means wait.
8. **Reverse order is not a preference.** Server endpoint, cloud endpoint, sync group,
   unregister. Recall tiered files first: a tiered file on disk is a pointer, and removing the
   endpoint leaves it pointing at nothing.

## Steps

```yaml
vars:
  - name: context
    describe: path to deployment-context.json
    required: true
  - name: file_server
    describe: the file server to register, reachable over PowerShell remoting
    required: true
  - name: share_path
    describe: share=local path, e.g. dept-shares=D:\Shares\dept
    required: true
steps:
  - name: dry run
    run: powershell -File onprem/Install-AfsServerEndpoint.ps1 -Context <context> -FileServer <file_server> -SharePath '<share_path>' -WhatIf
    verify: eight steps listed, preflight all OK, and the cloud endpoint step reports that the signed-in account holds Owner, User Access Administrator or Azure File Sync Administrator
  - name: build it
    run: powershell -File onprem/Install-AfsServerEndpoint.ps1 -Context <context> -FileServer <file_server> -SharePath '<share_path>'
    verify: agent version printed, server registered, sync group and cloud endpoint created, server endpoint created
  - name: the agent is installed and running
    run: powershell -Command "Invoke-Command -ComputerName <file_server> -ScriptBlock { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\Agent').Version; (Get-Service FileSyncSvc).Status }"
    verify: a supported agent version and Running
  - name: the server is registered
    run: powershell -Command "Get-AzStorageSyncServer -ResourceGroupName <rg> -StorageSyncServiceName <sss> | Select-Object FriendlyName,AgentVersion,LastHeartBeat"
    verify: the server is listed and the heartbeat is recent
  - name: the endpoints exist
    run: powershell -Command "Get-AzStorageSyncGroup -ResourceGroupName <rg> -StorageSyncServiceName <sss> | ForEach-Object { Get-AzStorageSyncServerEndpoint -ParentObject $_ } | Select-Object ServerEndpointName,ServerLocalPath,@{n='Health';e={$_.SyncStatus.CombinedHealth}}"
    verify: one server endpoint per share, pointing at the intended local path
  - name: the data actually arrived
    run: az storage file list --account-name <account> --account-key <key> --share-name <share> -o table
    verify: the folders and files from the server path are present in the Azure file share
  - name: reverse it
    run: powershell -File onprem/Install-AfsServerEndpoint.ps1 -Context <context> -FileServer <file_server> -Remove
    verify: server endpoint, cloud endpoint and sync group removed, server unregistered; the file share and its contents untouched
```

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: install-file-sync-agent-and-server-endpoint`
- **CR file:** `change-management/CR-<date>-file-sync-server-endpoint.md`
- **Closure:** the server appears in `Get-AzStorageSyncServer` with a recent heartbeat, a server
  endpoint exists per share, and the files on the server are visible in the Azure file share

## Gate rules

```json
[
  {"rule": "the server is registered and heartbeating", "severity": "error", "check": "Get-AzStorageSyncServer -ResourceGroupName <rg> -StorageSyncServiceName <sss> returns the server with a LastHeartBeat within the last hour"},
  {"rule": "every share in scope has a cloud endpoint", "severity": "error", "check": "Get-AzStorageSyncGroup ... | Get-AzStorageSyncCloudEndpoint -ParentObject $_ lists one cloud endpoint per share, AzureFileShareName matching"},
  {"rule": "the sync service still accepts the server", "severity": "error", "check": "az resource show -g <rg> -n <sss> --resource-type Microsoft.StorageSync/storageSyncServices --query properties.incomingTrafficPolicy -o tsv prints AllowAllTraffic, or a private path exists for the server"},
  {"rule": "shared key access is allowed on the storage account", "severity": "error", "check": "az storage account show -n <account> -g <rg> --query allowSharedKeyAccess -o tsv is true or null - compare as a BOOLEAN, not against the string 'false'"},
  {"rule": "data has actually synced", "severity": "error", "check": "az storage file list --account-name <account> --share-name <share> shows the content of the server path"}
]
```

## Reference

```yaml
- path: onprem/Install-AfsServerEndpoint.ps1
  anchor: "WHO RUNS IT"
  why: the identity split the cloud endpoint forces, stated where an operator will read it
- path: onprem/AfsServerEndpointRemove.ps1
  anchor: "The order is not a preference"
  why: the teardown order and the tiered-file recall guard
- path: codex/blueprint-azure-file-sync-private-path.md
  anchor: "Storage Sync Service endpoint"
  why: what changes when the sync service is later locked to a private path
- path: codex/runbook-file-sync-broken-after-network-lockdown.md
  anchor: "SSS endpoint disabled too early"
  why: the failure this playbook's preflight warns about
```

Microsoft Learn (read 2026-09-03): Deploy Azure File Sync; Automate Azure File Sync agent
installation; Register/unregister a server with Azure File Sync; Azure File Sync agent release
notes; Troubleshoot Azure File Sync (AuthorizationFailed on cloud endpoint creation);
Az.StorageSync cmdlet reference.

Executed against a live estate on 2026-09-03: agent 22.4.0.0 installed on a Windows Server 2022
file server over WinRM, registered, sync group + cloud endpoint + server endpoint created, and
the server's files confirmed present in the Azure file share.
