<#
.SYNOPSIS
  Remove everything Deploy-AfsEnvironment.ps1 created, using the same parameter file.

.DESCRIPTION
  Reads the same parameter file as the deployment and removes the objects it names.
  Two safety behaviours worth knowing about:

  1. It removes the RESOURCE GROUP, which is the only reliable way to be sure nothing is
     left behind. It refuses to do that if the group contains resources the parameter file
     does not mention, unless you pass -Force. That check is what stops a demo teardown
     from deleting somebody else's work in a shared group.

  2. A Recovery Services vault will not delete while it protects anything. The script
     disables protection with data deletion first, and says so before it does it.

.PARAMETER Context
  The deployment context phase 1 wrote - the same one phase 2 used.

.PARAMETER InputFile
  Alternatively, the four operator inputs.

.PARAMETER Force
  Delete the resource group even if it holds resources the parameter file does not name.

.EXAMPLE
  .\Remove-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf
  .\Remove-AfsEnvironment.ps1 -Context .\deployment-context.json
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Context')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Context')][string]$Context,
    [Parameter(Mandatory, ParameterSetName = 'Inputs')][string]$InputFile,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AfsConfig.ps1')
. (Join-Path $PSScriptRoot 'AfsLog.ps1')
if (-not $env:AFS_LOG_FILE) { Start-AfsLog -Level Verbose -Name 'remove' | Out-Null }
Write-Host ('  log: ' + $env:AFS_LOG_FILE) -ForegroundColor DarkGray

$script:StepNo = 0
$script:StepTotal = 4
$script:ProgressActivity = 'Teardown'
function Write-Step {
    param([string]$T)
    $script:StepNo++
    Write-AfsLog -Level STEP -Message ('[' + $script:StepNo + '/' + $script:StepTotal + '] ' + $T)
    Write-Host ''
    Write-AfsPhaseStrip -Done ($script:StepNo - 1) -Total $script:StepTotal
    Write-Host ("-> [{0}/{1}] {2}" -f $script:StepNo, $script:StepTotal, $T) -ForegroundColor Cyan
    Write-AfsProgress -Activity $script:ProgressActivity -Status $T -Step $script:StepNo -Total $script:StepTotal
}
function Write-Ok   { param([string]$T) Write-AfsLog -Level INFO -Message ("ok: " + $T); Write-Host ("   OK   " + $T) -ForegroundColor Green }
function Write-Warn2 { param([string]$T) Write-AfsLog -Level WARN -Message $T; Write-Host ("   WARN " + $T) -ForegroundColor Yellow }

function Invoke-Az {
    # every CLI call goes through the shared logger so the run is fully recorded
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFailure)
    if ($AllowFailure) { return Invoke-AfsAz -Args $Args -AllowFailure }
    return Invoke-AfsAz -Args $Args
}

function ConvertTo-Array {
    <#  @(Invoke-Az ...) does NOT flatten: a function that returns an Object[] is emitted
        as a single item, so the array subexpression yields one element containing the
        array. That silently turned a 2-resource inventory into "1 resource". Normalise
        here instead: null becomes empty, a scalar becomes one element, an array stays. #>
    param($Value)
    # ,@() and not @(): an empty array returned bare goes through the pipeline as NOTHING,
    # so the caller gets $null and .Count throws under Set-StrictMode
    if ($null -eq $Value) { return ,@() }
    # the unary comma matters: 'return $array' goes through the pipeline, which unwraps a
    # ONE-element array back to its scalar, and a PSCustomObject has no .Count - the as-built
    # reported the deployment identity's single role as 'not readable' because of exactly that
    if ($Value -is [System.Array]) { return ,$Value }
    return ,@($Value)
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

if ($PSCmdlet.ParameterSetName -eq 'Context') {
    $ctx = Read-AfsJsonc -Path $Context
    $cfg = $ctx.config
} else {
    $cfg = Resolve-AfsConfig -Inputs (Read-AfsJsonc -Path $InputFile)
}

$SubscriptionId = $cfg.subscriptionId
$env:AFS_SUBSCRIPTION_ID = $SubscriptionId   # every az call is pinned to it (see Invoke-AfsAz)
$ResourceGroup  = $cfg.resourceGroup
$Backup         = [pscustomobject]@{ vaultName = $cfg.vaultName }

Write-Host ''
Write-Host 'Azure File Sync environment teardown' -ForegroundColor White
Write-Host ("  subscription : " + $SubscriptionId)
Write-Host ("  group        : " + $ResourceGroup)

Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

$rg = Invoke-Az @('group', 'show', '-n', $ResourceGroup, '-o', 'json') -AllowFailure
if (-not $rg) { Write-Ok 'resource group does not exist - nothing to remove'; return }

Write-Step 'Inventory'
$res = ConvertTo-Array (Invoke-Az @('resource', 'list', '-g', $ResourceGroup, '--query', '[].{name:name,type:type}', '-o', 'json') -AllowFailure)
Write-Host ("   " + $res.Count + " resource(s) in the group")
foreach ($r in $res) { Write-Host ("     - " + $r.name + "  (" + $r.type + ")") }

# Names this deployment accounts for. The private DNS zones belong here as much as the
# storage account does - the build creates them - and leaving them out made the safety check
# refuse a teardown of an estate it had just built, which teaches people to reach for -Force
# and defeats the point of the check.
$known = New-Object System.Collections.ArrayList
foreach ($n in @($cfg.storageAccountName, $cfg.storageSyncServiceName, $cfg.vaultName,
                 $cfg.vnetName, $cfg.dnsResolverName, $cfg.zoneFile, $cfg.zoneAfs)) {
    if ($n) { [void]$known.Add($n) }
}

$unknown = @($res | Where-Object {
    $name = $_.name
    -not ($known | Where-Object { $name -like ("*" + $_ + "*") })
})

if ($unknown.Count -and -not $Force) {
    Write-Warn2 ("the group holds " + $unknown.Count + " resource(s) the parameter file does not name:")
    foreach ($u in $unknown) { Write-Host ("     ! " + $u.name + "  (" + $u.type + ")") }
    Write-Warn2 'refusing to delete the group. Re-run with -Force if this is expected.'
    return
}

Write-Step 'Recovery Services vault'
$VaultName = Get-Prop $Backup 'vaultName'
$script:VaultBlocked = $false
if ($VaultName) {
    $v = Invoke-Az @('backup', 'vault', 'show', '-n', $VaultName, '-g', $ResourceGroup, '-o', 'json') -AllowFailure
    if ($v) {
        $items = ConvertTo-Array (Invoke-Az @('backup', 'item', 'list', '-v', $VaultName, '-g', $ResourceGroup,
            '--query', '[].{name:properties.friendlyName,container:properties.containerName}', '-o', 'json') -AllowFailure)
        if ($items.Count) {
            Write-Warn2 ("vault protects " + $items.Count + " item(s); backup data will be DELETED")
            foreach ($i in $items) {
                if ($PSCmdlet.ShouldProcess($i.name, 'disable protection and delete backup data')) {
                    Invoke-Az @('backup', 'protection', 'disable', '-v', $VaultName, '-g', $ResourceGroup,
                        '--container-name', $i.container, '--item-name', $i.name,
                        '--backup-management-type', 'AzureStorage', '--workload-type', 'AzureFileShare',
                        '--delete-backup-data', 'true', '--yes', '-o', 'none') -AllowFailure | Out-Null
                    Write-Ok ("protection removed: " + $i.name)
                }
            }
        } else { Write-Ok 'no protected items' }
        if ($PSCmdlet.ShouldProcess($VaultName, 'delete recovery services vault')) {
            Invoke-Az @('backup', 'vault', 'delete', '-n', $VaultName, '-g', $ResourceGroup, '--yes', '-o', 'none') -AllowFailure | Out-Null
            # Soft delete (on by default, and 'AlwaysON' where a policy enforces it) keeps the
            # removed backup data for a retention period, and Azure refuses to delete a vault
            # that still holds it. Check rather than assume; the first live teardown hit this.
            $still = Invoke-Az @('backup', 'vault', 'show', '-n', $VaultName, '-g', $ResourceGroup, '-o', 'json') -AllowFailure
            if ($still) {
                $script:VaultBlocked = $true
                $days = 14
                try { $days = [int]$still.properties.securitySettings.softDeleteSettings.softDeleteRetentionPeriodInDays } catch { }
                Write-Warn2 ("vault NOT deleted: soft delete keeps the removed backup data for " + $days + " days, and a vault holding soft-deleted items cannot be deleted")
                Write-Warn2 ("everything else is removed now; delete the vault and the group after " + (Get-Date).AddDays($days).ToString('yyyy-MM-dd') + " with:")
                Write-Host ("        az backup vault delete -n " + $VaultName + " -g " + $ResourceGroup + " --yes")
                Write-Host ("        az group delete -n " + $ResourceGroup + " --yes")
            } else { Write-Ok 'vault deleted' }
        }
    } else { Write-Ok 'vault not present' }
}

Write-Step 'Resource locks'
$locks = ConvertTo-Array (Invoke-Az @('lock', 'list', '-g', $ResourceGroup, '--query', '[].name', '-o', 'json') -AllowFailure)
foreach ($l in $locks) {
    if ($PSCmdlet.ShouldProcess($l, 'delete lock')) {
        Invoke-Az @('lock', 'delete', '-n', $l, '-g', $ResourceGroup) -AllowFailure | Out-Null
        Write-Ok ("lock removed: " + $l)
    }
}

Write-Step ('Resource group ' + $ResourceGroup)
if ($script:VaultBlocked) {
    # The group cannot go while the vault is in it, so everything else goes one by one.
    # Dependencies (endpoint before its NIC and subnet, inbound endpoint before the resolver)
    # sort themselves out across passes: whatever fails this pass is retried on the next.
    Write-Warn2 'resource group kept (the vault is still in it); removing every other resource individually'
    for ($pass = 1; $pass -le 4; $pass++) {
        $ids = ConvertTo-Array (Invoke-Az @('resource', 'list', '-g', $ResourceGroup, '--query', "[?type!='Microsoft.RecoveryServices/vaults'].id", '-o', 'json') -AllowFailure)
        if ($ids.Count -eq 0) { break }
        Write-Host ("      ..    pass " + $pass + ": " + $ids.Count + " resource(s) left") -ForegroundColor DarkGray
        foreach ($id in $ids) {
            if ($PSCmdlet.ShouldProcess($id, 'delete resource')) {
                Invoke-Az @('resource', 'delete', '--ids', $id, '-o', 'none') -AllowFailure | Out-Null
            }
        }
    }
    $left = ConvertTo-Array (Invoke-Az @('resource', 'list', '-g', $ResourceGroup, '--query', "[?type!='Microsoft.RecoveryServices/vaults'].name", '-o', 'json') -AllowFailure)
    if ($left.Count) { Write-Warn2 ("still present: " + ($left -join ', ')) } else { Write-Ok 'everything except the vault is gone' }
} elseif ($PSCmdlet.ShouldProcess($ResourceGroup, 'DELETE the resource group and everything in it')) {
    Invoke-Az @('group', 'delete', '-n', $ResourceGroup, '--yes', '--no-wait', '-o', 'none') | Out-Null
    Write-Ok 'delete issued (asynchronous)'
    Write-Host ''
    Write-Host 'Confirm it is gone with:' -ForegroundColor White
    Write-Host ("  az group exists -n " + $ResourceGroup)
}
Complete-AfsProgress -Activity $script:ProgressActivity
Write-AfsPhaseStrip -Done $script:StepTotal -Total $script:StepTotal
Write-Host ''
