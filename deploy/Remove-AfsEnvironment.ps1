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

function Write-Step { param([string]$T) Write-Host ''; Write-Host ("-> " + $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ("   OK   " + $T) -ForegroundColor Green }
function Write-Warn2 { param([string]$T) Write-Host ("   WARN " + $T) -ForegroundColor Yellow }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFailure)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @Args 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        throw ("az " + ($Args -join ' ') + "`n" + (($out | Out-String).Trim()))
    }
    $out = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $text = ($out | Out-String).Trim()
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $text }
}

function ConvertTo-Array {
    <#  @(Invoke-Az ...) does NOT flatten: a function that returns an Object[] is emitted
        as a single item, so the array subexpression yields one element containing the
        array. That silently turned a 2-resource inventory into "1 resource". Normalise
        here instead: null becomes empty, a scalar becomes one element, an array stays. #>
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return $Value }
    return @($Value)
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

# names the parameter file accounts for
$known = New-Object System.Collections.ArrayList
foreach ($n in @($cfg.storageAccountName, $cfg.storageSyncServiceName, $cfg.vaultName,
                 $cfg.vnetName, $cfg.dnsResolverName)) {
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
            Write-Ok 'vault deleted'
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
if ($PSCmdlet.ShouldProcess($ResourceGroup, 'DELETE the resource group and everything in it')) {
    Invoke-Az @('group', 'delete', '-n', $ResourceGroup, '--yes', '--no-wait', '-o', 'none') | Out-Null
    Write-Ok 'delete issued (asynchronous)'
    Write-Host ''
    Write-Host 'Confirm it is gone with:' -ForegroundColor White
    Write-Host ("  az group exists -n " + $ResourceGroup)
}
Write-Host ''
