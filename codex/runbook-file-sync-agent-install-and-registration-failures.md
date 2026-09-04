---
slug: runbook-file-sync-agent-install-and-registration-failures
doc_type: runbook
kind: file-sync-agent-install-and-registration-failures
category: infra
title: Repair an Azure File Sync agent install or registration that will not complete
summary: The install failure classes seen in practice - a filter driver still loaded awaiting a restart, a concurrent installer, a missing module on the server, and a registration that reaches Azure but records a different name than expected.
when_to_use: The agent install times out or returns a fatal MSI error, or the server installs but never appears as a registered server.
applies_to: [ops, devstation]
tags: [azure-file-sync, agent, msiexec, incident, registration, storagesync, contoso]
persona_run: eng-sysops
ticket_kind: bug-known
status: published
version: 1
execution: advisory
last_verified: 2026-09-04T09:20 EST (UTC-4)
artifacts: []
supersedes: []
---

## When to use

The agent step will not finish. Either the installer never reports success and the step waits out
its timeout, or it returns a fatal MSI code, or the agent installs cleanly and the server still
does not show up as registered.

The single most common cause is also the least obvious: **the previous agent is still there.**
Uninstalling the Azure File Sync agent returns **3010 - success, restart required**, because its
file system filter cannot be unloaded while Windows is running. Until that restart happens the
product is half-removed, and installing it again fails with a generic **1603** about seven seconds
in. Nothing in that failure names a restart.

## Reuse before reinvent (GR11)

```yaml
- primitive: onprem/Install-AfsServerEndpoint.ps1
  path: onprem/
  why: the preflight, the scheduled-task launch and the exit-code translation all live there -
       extend that script rather than writing a second installer with different behaviour
- primitive: onprem/AfsServerEndpointRemove.ps1
  path: onprem/
  why: the uninstall is what creates the pending-restart state; its 3010 message is the first
       place to make the requirement visible
- primitive: Get-AfsRegisteredServer
  path: onprem/AfsOnPrem.ps1
  why: registration compares the first label of the computer name, because Azure may hold the
       short name where the caller passed an FQDN - do not re-derive that comparison
```

## Response

1. **Read the exit code before reading the log.** An MSI verbose log ends with its own teardown,
   so the last lines name nothing. The codes that matter:

   | Code | Meaning | Action |
   |---|---|---|
   | 0 | installed | none |
   | 3010 | done, restart required | restart before installing or uninstalling again |
   | 1603 | fatal error | almost always the pending-restart case below |
   | 1618 | another install in progress | wait for it, then retry |
   | 1638 | another version already installed | remove it first |
   | 1601 | Windows Installer service unreachable | check the service on the server |

2. **1603 - check for the half-removed agent first.** On the server:

   ```powershell
   fltmc filters | Select-String StorageSync
   (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
     -Name PendingFileRenameOperations -EA SilentlyContinue).PendingFileRenameOperations |
     Where-Object { $_ -match 'StorageSync' }
   ```

   A loaded filter or a pending rename, with **no** agent in
   `HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\Agent`, is the signature. **Restart the server.**
   No amount of retrying installs over it. The install step now refuses to start in this state
   rather than failing eight seconds later with a message that names nothing.

3. **A timeout is not the same as a failure, and the difference is the task.** The install runs
   from a scheduled task because the installer closes PowerShell sessions - which would kill the
   remote session that started it. That means the poll loop must ask the task for its result, not
   only watch for the success key; otherwise a dead install and a slow one look identical and the
   wait runs to the deadline. `Get-ScheduledTaskInfo -TaskName AfsAgentInstall` carries
   `LastTaskResult`; `267011` means it has not run yet.

4. **Installed but not registered.** Registration must run **on the server** - it writes a
   certificate and a machine identity that cannot be created remotely. It also needs
   `Az.Accounts` and `Az.StorageSync` present *there*, not on the workstation. Where the PowerShell
   Gallery is unreachable, the module is copied from the calling machine.

5. **Registered but "missing".** Azure may record the short computer name where the caller passed
   an FQDN, so an exact-string comparison reports a server as unregistered and registers it twice.
   Compare the first label only.

6. **Confirm before moving on.** The agent version on the server and the registered-server row in
   Azure must agree; a server endpoint created against a stale registration syncs nothing and
   reports healthy for about fifteen minutes while Azure's telemetry catches up.

## How a persona runs this (-> ticket)

- **Persona:** `eng-sysops`
- **Devstation flavor:** `netops-v`
- **Gate pull:** `kind: file-sync-agent-install-and-registration-failures`
- **CR file:** `change-management/CR-<date>-file-sync-agent-install-repair.md`
- **Closure:** the agent version reads back from the server, the registered server appears in the
  Storage Sync Service, a server endpoint exists, and a file written on the server arrives in the
  share - the topology in [[blueprint-azure-file-sync-private-path]] holding end to end

## Gate rules

```json
[
  {"rule": "no half-removed agent before installing", "severity": "error", "check": "powershell -Command \"fltmc filters\" on the server returns no StorageSync line while HKLM:\\SOFTWARE\\Microsoft\\Azure\\StorageSync\\Agent is absent"},
  {"rule": "the installer result was read, not guessed", "severity": "error", "check": "powershell -Command \"Get-ScheduledTaskInfo -TaskName AfsAgentInstall | Select-Object -ExpandProperty LastTaskResult\" returns 0 or 3010"},
  {"rule": "the agent is installed", "severity": "error", "check": "powershell -Command \"(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Azure\\StorageSync\\Agent').Version\" prints a version"},
  {"rule": "the server is registered exactly once", "severity": "error", "check": "az storagesync registered-server list -g <rg> --storage-sync-service <sss> --query \"length([?starts_with(friendlyName, '<short name>')])\" -o tsv returns 1"}
]
```

## Reference

```yaml
- path: onprem/Install-AfsServerEndpoint.ps1
  anchor: "loaded, waiting for a restart"
  why: the preflight that refuses the install, and the exit-code translation
- path: onprem/AfsServerEndpointRemove.ps1
  anchor: "3010"
  why: where the pending-restart state is created, and where it is first reported
- path: codex/playbook-install-file-sync-agent-and-server-endpoint.md
  anchor: "## Procedure"
  why: the normal path this runbook is the failure side of
```

Observed 2026-09-04 on a Windows Server file server: an uninstall returned 3010 at 11:28, no
restart was taken, and the reinstall at 13:10 failed with 1603 seven seconds after the MSI started
while the calling script waited out its full twenty-minute timeout. Both behaviours - the fatal
install and the wasted wait - are fixed in the script; the underlying Windows requirement is not
something a script can remove, so it is documented here.
