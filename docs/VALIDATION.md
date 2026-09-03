# Validation record

What in this repository has been executed, what has only been checked against documentation,
and what could not be tested. The distinction matters: a command verified on paper can still
be wrong for a given CLI version, region or resource state.

Last run: 2026-09-03. Azure CLI 2.84.0, Windows PowerShell 5.1, a live Azure tenant.

## Summary

| Layer | Method | Result |
|---|---|---|
| Every `az` command in the codex | Command path and every flag resolved against the installed CLI | **89 / 89 valid** |
| Read-only gate and verify commands | Executed against live Azure resources | **33 / 36 pass** (see below) |
| Exporter ARM API versions and resource paths | Live GET/POST against ARM | **23 / 23 return 200** |
| Assessor rules and report generation | Synthetic fixture, offline | **108 / 108 checks green** |
| Deployment and teardown scripts | Parsed, and run end to end in `-WhatIf` against a live subscription | **pass** |
| Mutating `az` commands | **Not executed** | see limitations |
| Every PowerShell cmdlet and parameter in the codex | Resolved against the real modules | **48 cmdlets, 111 parameter references, 0 invalid** |
| On-server File Sync cmdlets | **Not executed** | needs a registered server |

## What execution found that documentation review did not

These are the defects only running the commands could surface.

**0. Two rounds of extraction defects in the checker itself, worth recording because they
are the reason to distrust a green result you did not interrogate.** The first parameter
extraction reported three invalid parameters. All three were artifacts: two picked up a
`-WorkloadType` belonging to an outer cmdlet after a closing parenthesis, and one matched
`-Connection` inside the quoted value `'<sss>-Connection'`. Fixing the extractor to stop at
`)` and to blank single-quoted values dropped the count to zero - but the first fix over-
corrected and blanked the `powershell -Command "..."` wrapper itself, silently reducing the
corpus from 56 cmdlets to 8 while still reporting a clean pass. A validator that shrinks its
own input reports success by finding nothing. Both were caught by checking the corpus size
alongside the result.

**1. A backup gate rule needed an array index, and it is now proven.** The audit had already
corrected `az backup vault backup-properties show ... --query "properties.storageModelType"`
to `"[0].properties.storageModelType"`. Running both forms against two real vaults confirms
it: the indexed form returns the value, the bare form returns nothing at all - silently, with
exit code 0. A gate rule using the bare form would have passed while checking nothing.

**2. Git Bash corrupts Azure resource IDs.** Any command that takes a full resource ID
(`--resource`, `--scope`) fails with a usage error under Git Bash on Windows, because MSYS
rewrites arguments beginning with `/` into Windows paths and every ARM id starts with
`/subscriptions/`. `MSYS_NO_PATHCONV=1` fixes it. Now documented in `deploy/README.md`.

**3. `az dns-resolver` is a CLI extension, not built in.** Without it every DNS resolver
command fails as an unrecognised command group. The deployment script now installs it during
preflight rather than failing halfway through a build.

**4. A stderr-handling defect in the deployment script.** `az` writes to stderr, and with
`$ErrorActionPreference = 'Stop'` PowerShell converts that into a terminating
`NativeCommandError` - so an expected "does this exist?" probe killed the script. Fixed by
relaxing the preference around the call and taking the outcome from the exit code.

**5. An array-nesting defect in the teardown script.** `@(Invoke-Az ...)` does not flatten:
a function returning an `Object[]` is emitted as a single item, so the array subexpression
yields one element containing the array. The teardown's safety inventory reported "1 resource"
for a group holding two, and concatenated their names. Fixed with an explicit normaliser and
re-verified against a real group.

**6. The normaliser itself had a one-element hole.** `return $array` hands the array to the
pipeline, which unwraps a one-element array back to its scalar - and a `PSCustomObject` has
no `.Count`. The as-built reported the deployment identity's single role assignment as
"not readable" for exactly that reason. `return ,$array` fixes it, in all four copies.

**7. `dns-zone-group show` answers `{}` with exit code 0 when nothing is attached.** The
first live build tested the exit code, believed the zone group existed, and never wrote an
A record: both privatelink zones held only their SOA, and the private endpoints resolved
publicly. The test is now for an actual zone configuration, and the as-built lists the
records so the gap is visible.

**8. The Windows `az.cmd` wrapper cannot carry a `)` in any argument.** The MSI install's
launcher is a single batch block, `@IF EXIST "..\python.exe" ( ... -IBm azure.cli %* )`, so
a closing parenthesis inside an argument ends the block early and the command dies with
`-o was unexpected at this time` (exit code 255). Every JMESPath function call has one:
`length(@)`, `contains(...)`, `join(...)`. A tolerated read then returns nothing, which is
how the redundancy step saw zero protected items, the wizard's read-back probe accused a
working account of having no access, and phase 1 re-granted a role it had already granted.
Filters such as `[?name=='x']` are unaffected, and the same commands work from Git Bash or
Linux, which is why it survived earlier testing. `Invoke-AfsAz` now starts the bundled
`python.exe -IBm azure.cli` directly when it finds that layout, and the scripts read lists
and count in PowerShell. The 28 gate checks in the codex that use `length(...)` are correct
as written for bash; a Windows PowerShell operator must run them through a wrapper that
avoids `az.cmd` or count a plain list instead.

**9. A multi-line `-o tsv` answer is one string.** `Invoke-AfsAz` returns non-JSON output
as a single string, so a two-share list never matched either name and both shares were
"protected" a second time (Azure treats that as a no-op). Lists are now read as JSON.

**10. The Azure CLI's default subscription is shared by every window on the machine.** An
`az login` in a second PowerShell window during a build retargeted the very next call to a
different subscription, and a share lost its protection step to `ResourceGroupNotFound`.
Every call is now pinned with `--subscription`.

**11. A dot-sourced script with a `param` block binds those parameters in the caller's
scope.** The HTML renderer blanked the assessor's `$OutputPath` that way, and the report
failed with "parameter 'Path' is an empty string". The renderer is a param-less library now.

**12. The vault could not be deleted after protection was removed.** Soft delete keeps the
removed backup data for its retention period (14 days here, and `AlwaysON` where a policy
enforces it, which cannot be switched off). The teardown now detects the blocked vault,
removes every other resource individually, and prints the date it can be retried.

## The three read-only checks that did not pass

Two were defects in the test, not the library, and are recorded rather than hidden:

- `az monitor metrics list` failed with a time-grain error because the test omitted
  `--interval`. The library's own usage already specifies `--interval P1D` and is correct.
- `az monitor diagnostic-settings list --query "length(value)"` throws when a resource has no
  diagnostic settings, because `value` is null rather than an empty array. This was the test's
  query, not a library pattern.
- `az role assignment list --scope ...` returns `MissingSubscription` in this tenant. The same
  read succeeds through `az rest` against the Authorization API, so it is a CLI-layer quirk in
  this environment rather than a permissions problem or a defect in the command.

## Limitations - what could not be validated here, and why

**Mutating commands were not executed.** The tenant available for testing requires MFA for
every write: any create, update or delete returns

```
RequestDisallowedByAzure: ... tried to create, update or delete Azure resources without
authenticating through MFA.
```

No resource could be created, so `storage account create`, `private-endpoint create`,
`backup vault create` and the rest are documentation-verified and shape-verified only. To
close this, run the deployment script against a subscription with an MFA-authenticated
session or a service principal holding Contributor.

**PowerShell cmdlets are now fully resolved.** `Az.Accounts`, `Az.Resources`, `Az.Storage`,
`Az.StorageSync` 2.6.0, `Az.RecoveryServices` 7.14.1, `Az.Network` 8.2.0, `Az.PrivateDns` 1.3.0,
`Az.DnsResolver` 2.0.0 and `Az.Compute` 11.9.0 were installed and every cmdlet the codex names
was resolved with `Get-Command`, then every `-Parameter` it passes was checked against that
cmdlet's real parameter set including aliases. **48 cmdlets, 111 parameter references, zero
invalid.** Five cmdlets remain unresolvable here because they do not ship in a PowerShell
Gallery module: `Debug-StorageSyncServer` and `Invoke-StorageSyncFileRecall` install with the
Azure File Sync agent on a registered server; `Join-AzStorageAccount` and
`Debug-AzStorageAccountAuth` come from AzFilesHybrid, which Microsoft distributes from GitHub;
`Get-ADComputer` needs RSAT.

**On-server File Sync commands need a registered server.** `Debug-StorageSyncServer`,
`Get-StorageSyncAgentVersion` and the Telemetry event-log checks require a Windows server
running the agent and registered to a Storage Sync Service.

## Reproducing this

```powershell
# structural validation of every az command in the codex
python scripts\validate-az.py          # if published; otherwise see docs/VALIDATION.md history

# the offline suite
python fixtures\make-fixture.py
.\tests\run-tests.ps1

# the deployment script, without changing anything
cd deploy
.\Deploy-AfsEnvironment.ps1 -ParameterFile .\parameters.json -WhatIf
```
