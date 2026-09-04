<#
.SYNOPSIS
  Point on-premises DNS at the Azure DNS Private Resolver, so the storage account and the
  Storage Sync Service resolve to their private addresses from your own network.

.DESCRIPTION
  The second of the three steps the Azure build does not do, because it changes a DNS server
  you own. It is also the most dangerous of the three, and the script is shaped around that.

  WHICH ZONE TO FORWARD - the part almost everyone gets wrong.

    A client asks for   contosofs01.file.core.windows.net
    Azure answers       CNAME -> contosofs01.privatelink.file.core.windows.net -> A <address>

    and it returns that whole chain in ONE answer. So a conditional forwarder on
    privatelink.file.core.windows.net is NEVER CONSULTED: the name the client asked for does
    not end in that suffix, and the chain never leaves the upstream server. Such a forwarder
    looks right, passes a "did the zone get created" check, and does nothing at all.

    Microsoft's guidance is to forward the PUBLIC zone - file.core.windows.net and
    afs.azure.net - which is what this script does.

  WHY THAT IS DANGEROUS, AND WHAT THE SCRIPT DOES ABOUT IT.

    Forwarding the public zone means every query for it now goes to the resolver. If the
    resolver cannot be reached, on-premises clients get SERVFAIL after about eleven seconds
    for EVERY storage endpoint under that suffix - not just this storage account. And a
    resolver that answers wrongly (REFUSED, or NXDOMAIN because the private DNS zone is not
    linked to its virtual network) is worse still: that answer is returned to the client
    immediately and no fallback is attempted.

    So the script does not test whether the resolver is reachable. It tests whether the
    resolver returns the PRIVATE address for a name it should know, and refuses to write
    anything otherwise. -Force exists, and prints what it is overriding.

  The reverse path removes the forwarder and clears the cache, which puts resolution back
  exactly as it was.

.PARAMETER Context
  deployment-context.json from phase 1. The resolver address and the zones come from it.

.PARAMETER DnsServer
  The DNS servers to change. AD-integrated replication only reaches domain controllers that
  run the DNS role, so name every resolver that answers for your clients - member servers and
  appliances included.

.PARAMETER ResolverIpAddress
  The resolver inbound endpoint address. Read from the deployment when not given.

.PARAMETER Zone
  Zones to forward. Defaults to the public zones for Azure Files and Azure File Sync.

.PARAMETER ReplicationScope
  Forest (default), Domain, Legacy, or None. None creates a server-local forwarder that does
  not replicate - use it for a member server or a one-off test.

.PARAMETER ForwarderTimeout
  Seconds to wait for the resolver, 0 to 15. Default 3 rather than the Windows default of 5:
  with two masters and a 5-second timeout the server's own recursion budget expires before it
  can fall back, so a lower value is what makes the fallback reachable at all.

.PARAMETER UpdateExisting
  Repoint a forwarder that already exists with different masters. Off by default - an
  existing forwarder is usually somebody's deliberate design.

.PARAMETER Force
  Write even though the resolver did not return a private address. Prints what is being
  overridden. There is one good reason to use it: the network path to Azure is being built
  in the same change window and you know the forwarder will start working shortly.

.PARAMETER Remove
  Remove the forwarders and clear the cache.

.EXAMPLE
  .\Set-AfsDnsForwarders.ps1 -Context ..\deploy\deployment-context.json -DnsServer dc01,dc02 -WhatIf

.EXAMPLE
  .\Set-AfsDnsForwarders.ps1 -Context ..\deploy\deployment-context.json -DnsServer dc01,dc02 -Remove

.NOTES
  Needs the DnsServer module locally (RSAT-DNS-Server) or PowerShell remoting to each DNS
  server. Membership of DnsAdmins or Domain Admins is the documented minimum.

  Infoblox, BIND and other non-Windows resolvers are not changed by this script; it prints
  the equivalent for them, because AD replication never reaches them either.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$Context,
    [Parameter(Mandatory)][string[]]$DnsServer,
    [string]$ResolverIpAddress,
    [string[]]$Zone,
    [ValidateSet('Forest', 'Domain', 'Legacy', 'None')][string]$ReplicationScope = 'Forest',
    [ValidateRange(0, 15)][int]$ForwarderTimeout = 3,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$UpdateExisting,
    [switch]$Force,
    [switch]$Remove
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AfsOnPrem.ps1')
if (-not $env:AFS_LOG_FILE) { Start-AfsLog -Level Verbose -Name 'dnsforwarders' | Out-Null }
Write-Host ('  log: ' + $env:AFS_LOG_FILE) -ForegroundColor DarkGray
Confirm-AfsCanPrompt -BoundParameters $PSBoundParameters -ScriptName 'onprem\Set-AfsDnsForwarders.ps1'

$ctx = Read-AfsContext -Path $Context
$cfg = $ctx.config
$sub = $cfg.subscriptionId
$rg  = $cfg.resourceGroup
$sa  = $cfg.storageAccountName
$env:AFS_SUBSCRIPTION_ID = $sub

# The public zones, not the privatelink ones - see the note at the top of this file.
if (-not $Zone -or $Zone.Count -eq 0) {
    $zoneFile = [string](Get-AfsProperty $cfg 'zoneFile' 'privatelink.file.core.windows.net')
    $zoneAfs  = [string](Get-AfsProperty $cfg 'zoneAfs'  'privatelink.afs.azure.net')
    $Zone = @(($zoneFile -replace '^privatelink\.', ''), ($zoneAfs -replace '^privatelink\.', ''))
}
foreach ($z in $Zone) {
    if ($z -like 'privatelink.*') {
        Write-AfsWarn ("$z is a privatelink zone, and a conditional forwarder on it never fires.")
        Write-AfsSay "Clients ask for the PUBLIC name, and the privatelink name only ever appears
inside an answer that has already been resolved. Forward $($z -replace '^privatelink\.', '') instead."
        throw ('Refusing to create a forwarder for ' + $z + ' - it would have no effect.')
    }
}

# powershell -File passes every argument as a single string, so -DnsServer a,b arrives as one
# element "a,b" rather than two. Split it back out; a real array is unaffected.
$DnsServer = @($DnsServer | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })

Set-AfsStepTotal -Total $(if ($Remove) { 3 } else { 5 }) -Activity 'Azure File Sync - on-premises DNS'

Write-Host ''
Write-Host ("  DNS servers : " + ($DnsServer -join ', ')) -ForegroundColor White
Write-Host ("  zones       : " + ($Zone -join ', '))
Write-Host ("  replication : " + $ReplicationScope)

$verify = New-Object System.Collections.ArrayList
function Add-Verify { param([string]$What, [string]$Cmd) [void]$verify.Add([pscustomobject]@{ What = $What; Cmd = $Cmd }) }

function Invoke-Dns {
    <# Run a DnsServer command against one server. Uses the local module with -ComputerName
       when it is installed (better errors), and falls back to running it inside a remoting
       session on the DNS server itself, where the module always exists. #>
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][scriptblock]$Body, [object[]]$ArgumentList, [string]$What = 'dns command', [switch]$AllowFailure)
    if (Get-Module -ListAvailable -Name DnsServer) {
        try { return (& $Body $Server @ArgumentList) }
        catch { if (-not $AllowFailure) { Write-AfsLog -Level DEBUG -Message ('local DnsServer module failed for ' + $What + ': ' + $_.Exception.Message) } }
    }
    $p = @{ ComputerName = $Server; ScriptBlock = $Body; ArgumentList = (@($null) + $ArgumentList); ErrorAction = 'Stop' }
    if ($Credential) { $p.Credential = $Credential }
    try { return (Invoke-Command @p) }
    catch { if ($AllowFailure) { return $null }; throw }
}

try {

# ================================================================== preflight ==

Write-AfsStep 'Preflight'

if (-not $ResolverIpAddress) {
    $ResolverIpAddress = Invoke-AfsAz -Args @('dns-resolver', 'inbound-endpoint', 'show', '-g', $rg,
        '--dns-resolver-name', $cfg.dnsResolverName, '-n', 'inbound-01',
        '--query', 'ipConfigurations[0].privateIpAddress', '-o', 'tsv') -AllowFailure
}
if (-not $ResolverIpAddress) { throw 'No resolver address. Pass -ResolverIpAddress, or deploy the DNS Private Resolver first.' }
Write-AfsOk ('resolver inbound endpoint: ' + $ResolverIpAddress)

foreach ($s in $DnsServer) {
    $zoneRead = Invoke-Dns -Server $s -What ('read zones on ' + $s) -AllowFailure -Body {
        param($srv)
        if ($srv) { Get-DnsServerZone -ComputerName $srv -ErrorAction Stop | Select-Object ZoneName, ZoneType }
        else { Get-DnsServerZone -ErrorAction Stop | Select-Object ZoneName, ZoneType }
    }
    if (-not $zoneRead) { throw ("Cannot read DNS zones on $s. Check that it runs the DNS Server role, that WinRM or RPC reaches it, and that you are in DnsAdmins or Domain Admins.") }
    Write-AfsOk ($s + ' answers - ' + (ConvertTo-AfsArray $zoneRead).Count + ' zones')
}

if ($Remove) { . (Join-Path $PSScriptRoot 'AfsDnsForwardersRemove.ps1'); return }

# ============================================================ does it work? ===

Write-AfsStep 'Does the resolver actually answer with a private address?'

Write-AfsSay @"
Reachability is not the test. A resolver that answers REFUSED, or NXDOMAIN because
the private DNS zone is not linked to its virtual network, returns that straight to
the client with no fallback - which is worse than one that is simply down.
"@

$probeName = $sa + '.privatelink.file.core.windows.net'
$answer = $null
try {
    $answer = Resolve-DnsName -Name $probeName -Server $ResolverIpAddress -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
} catch {
    Write-AfsInfo ('the resolver did not answer for ' + $probeName + ': ' + $_.Exception.Message)
}

$private = $null
foreach ($r in (ConvertTo-AfsArray $answer)) {
    if ($r.PSObject.Properties['IP4Address'] -and $r.IP4Address) {
        $ip = [string]$r.IP4Address
        if ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)') { $private = $ip; break }
    }
}

if ($private) {
    Write-AfsOk ($probeName + ' -> ' + $private + ' (a private address, through the resolver)')
} else {
    Write-AfsWarn ('the resolver did not return a private address for ' + $probeName)
    Write-AfsSay @"
What this usually means, in order of likelihood:

  1. On-premises has no network path to $ResolverIpAddress. The resolver is only
     reachable over a VPN or ExpressRoute connection to the virtual network -
     there is no public route to it, by design.
  2. The private DNS zones are not linked to the resolver's virtual network, so
     it answers with the public address instead of the private one.
  3. The private endpoint has no address record for this storage account.

Until one of those is fixed, forwarding $($Zone -join ' and ') would send every
query for those zones into a hole, and on-premises clients would lose access to
EVERY storage account under them - not just this one - after about eleven seconds
of waiting per query.
"@
    if (-not $Force) {
        throw 'The resolver did not return a private address. Nothing was changed. Re-run with -Force only if you are building the network path in this same change window.'
    }
    Write-AfsWarn 'proceeding anyway because -Force was given'
    Write-AfsSay ('Until the path to ' + $ResolverIpAddress + ' works, on-premises clients will fail to resolve ' + ($Zone -join ' and ') + '.')
    if (-not $PSCmdlet.ShouldProcess(($Zone -join ', '), 'forward a zone to a resolver that is not answering')) { return }
}

# =================================================================== write ====

Write-AfsStep 'Conditional forwarders'

$state = New-Object System.Collections.ArrayList
foreach ($s in $DnsServer) {
    foreach ($z in $Zone) {
        $existing = Invoke-Dns -Server $s -What ('read ' + $z + ' on ' + $s) -AllowFailure -ArgumentList @($z) -Body {
            param($srv, $zone)
            $p = @{ Name = $zone; ErrorAction = 'SilentlyContinue' }
            if ($srv) { $p.ComputerName = $srv }
            Get-DnsServerZone @p | Select-Object ZoneName, ZoneType, MasterServers, ForwarderTimeout, IsDsIntegrated, ReplicationScope
        }
        if ($existing) {
            if ($existing.ZoneType -ne 'Forwarder') {
                throw ("$z already exists on $s as a $($existing.ZoneType) zone. This script will not touch it - a zone of that type is authoritative data, not a forwarder.")
            }
            $current = @(ConvertTo-AfsArray $existing.MasterServers | ForEach-Object { [string]$_ }) | Sort-Object
            if ($current -contains $ResolverIpAddress -and $current.Count -eq 1) {
                Write-AfsOk ($z + ' on ' + $s + ' already forwards to ' + $ResolverIpAddress)
                continue
            }
            Write-AfsWarn ($z + ' on ' + $s + ' forwards to ' + ($current -join ', ') + ', not ' + $ResolverIpAddress)
            if (-not $UpdateExisting) {
                Write-AfsSay 'Somebody configured that deliberately. Re-run with -UpdateExisting to repoint it.'
                continue
            }
            [void]$state.Add([pscustomobject]@{ Server = $s; Zone = $z; PreviousMasters = ($current -join ',') })
            if ($PSCmdlet.ShouldProcess(($z + ' on ' + $s), ('repoint to ' + $ResolverIpAddress))) {
                [void](Invoke-Dns -Server $s -What ('repoint ' + $z) -ArgumentList @($z, $ResolverIpAddress, $ForwarderTimeout) -Body {
                    param($srv, $zone, $ip, $timeout)
                    $p = @{ Name = $zone; MasterServers = $ip; ForwarderTimeout = $timeout; ErrorAction = 'Stop' }
                    if ($srv) { $p.ComputerName = $srv }
                    Set-DnsServerConditionalForwarderZone @p
                })
                Write-AfsOk ($z + ' on ' + $s + ' repointed to ' + $ResolverIpAddress)
            }
            continue
        }
        if ($PSCmdlet.ShouldProcess(($z + ' on ' + $s), ('forward to ' + $ResolverIpAddress))) {
            [void](Invoke-Dns -Server $s -What ('create ' + $z) -ArgumentList @($z, $ResolverIpAddress, $ForwarderTimeout, $ReplicationScope) -Body {
                param($srv, $zone, $ip, $timeout, $scope)
                $p = @{ Name = $zone; MasterServers = $ip; ForwarderTimeout = $timeout; ErrorAction = 'Stop' }
                if ($srv) { $p.ComputerName = $srv }
                # Without -ReplicationScope the cmdlet quietly uses its file-backed parameter
                # set, producing a forwarder local to this one server that never replicates.
                if ($scope -ne 'None') { $p.ReplicationScope = $scope }
                Add-DnsServerConditionalForwarderZone @p
            })
            Write-AfsOk ($z + ' on ' + $s + ' now forwards to ' + $ResolverIpAddress)
            [void]$state.Add([pscustomobject]@{ Server = $s; Zone = $z; PreviousMasters = '' })
        }
    }
}

# =================================================================== cache ====

Write-AfsStep 'Clear the cached public answers'
Write-AfsSay 'The server still holds the public addresses it looked up before the change, and would keep serving them until they expire.'
foreach ($s in $DnsServer) {
    if ($PSCmdlet.ShouldProcess($s, 'clear the DNS server cache')) {
        [void](Invoke-Dns -Server $s -What ('clear the cache on ' + $s) -AllowFailure -Body {
            param($srv)
            $p = @{ Force = $true; ErrorAction = 'Stop' }
            if ($srv) { $p.ComputerName = $srv }
            Clear-DnsServerCache @p
        })
        Write-AfsOk ($s + ' cache cleared')
    }
}

# ================================================================== verify ====

Write-AfsStep 'Verify'

foreach ($s in $DnsServer) {
    foreach ($z in $Zone) {
        Add-Verify ($z + ' on ' + $s) ("Get-DnsServerZone -Name $z -ComputerName $s | Select-Object ZoneName,ZoneType,MasterServers,ForwarderTimeout")
    }
}
Add-Verify 'what a client now gets' ("Clear-DnsClientCache; Resolve-DnsName $sa.file.core.windows.net")
Add-Verify 'whether SMB actually reaches it' ("Test-NetConnection $sa.file.core.windows.net -CommonTCPPort SMB")

Complete-AfsSteps -Outcome $(if ($WhatIfPreference) { 'WHAT-IF complete. Nothing was changed.' } else { 'Conditional forwarders in place.' })

Write-Host 'Verify with:' -ForegroundColor White
foreach ($v in $verify) { Write-Host ('  # ' + $v.What) -ForegroundColor DarkGray; Write-Host ('  ' + $v.Cmd) }

Write-Host ''
Write-Host 'Test from a CLIENT that uses these DNS servers, not from the DNS server itself,' -ForegroundColor White
Write-Host 'and not with -Server: that is the only test that exercises the forwarder.'
Write-Host ''
Write-Host 'Two things that are true even when DNS is now correct:' -ForegroundColor White
Write-Host '  A client with no route to the private endpoint now fails at SMB instead of at DNS.'
Write-Host '  Shares mounted against the public address must be remounted.'
Write-Host ''
Write-Host 'Resolvers this script did not change:' -ForegroundColor White
Write-Host '  Active Directory replicates these zones only to domain controllers that run the'
Write-Host '  DNS role. Member-server resolvers, Infoblox, BIND and anything else need the same'
Write-Host '  forwarder added by hand. On Infoblox that is a Forward Zone:'
Write-Host ('    Data Management > DNS > Add > Zone > Add Forward Zone, name ' + $Zone[0] + ',')
Write-Host ('    forwarding to ' + $ResolverIpAddress + '.')
Write-Host ''
Write-Host ('Reverse it with: .\Set-AfsDnsForwarders.ps1 -Context ' + $Context + ' -DnsServer ' + ($DnsServer -join ',') + ' -Remove')

} finally {
    Stop-AfsLog -Outcome 'dns forwarder run ended'
}
