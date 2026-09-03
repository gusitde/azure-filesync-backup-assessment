<#
  The reverse path for Set-AfsDnsForwarders.ps1. Dot-sourced by it when -Remove is given.

  This direction is the safe one. With the forwarder gone and the cache cleared, the next
  query resolves the way it did before the change: the public chain, straight from the
  upstream server. Nothing else on the DNS server is touched.

  It does need the cache clear, though, and for the opposite reason to the forward path: the
  server is now holding PRIVATE addresses. Leave them cached with the forwarder gone and
  clients keep being sent to an address they may no longer have a route to.
#>

Write-AfsStep 'Remove the conditional forwarders'

$removed = 0
foreach ($s in $DnsServer) {
    foreach ($z in $Zone) {
        $existing = Invoke-Dns -Server $s -What ('read ' + $z + ' on ' + $s) -AllowFailure -ArgumentList @($z) -Body {
            param($srv, $zone)
            $p = @{ Name = $zone; ErrorAction = 'SilentlyContinue' }
            if ($srv) { $p.ComputerName = $srv }
            Get-DnsServerZone @p | Select-Object ZoneName, ZoneType, MasterServers
        }
        if (-not $existing) { Write-AfsOk ($z + ' is not present on ' + $s); continue }
        if ($existing.ZoneType -ne 'Forwarder') {
            Write-AfsWarn ($z + ' on ' + $s + ' is a ' + $existing.ZoneType + ' zone, not a forwarder - left alone')
            continue
        }
        $masters = (ConvertTo-AfsArray $existing.MasterServers | ForEach-Object { [string]$_ }) -join ', '
        if ($PSCmdlet.ShouldProcess(($z + ' on ' + $s), ('remove the conditional forwarder (currently -> ' + $masters + ')'))) {
            # There is no Remove-DnsServerConditionalForwarderZone; the generic zone cmdlet
            # removes every zone type, conditional forwarders included.
            [void](Invoke-Dns -Server $s -What ('remove ' + $z) -ArgumentList @($z) -Body {
                param($srv, $zone)
                $p = @{ Name = $zone; Force = $true; ErrorAction = 'Stop' }
                if ($srv) { $p.ComputerName = $srv }
                Remove-DnsServerZone @p
            })
            Write-AfsOk ('removed ' + $z + ' from ' + $s)
            $removed++
        }
    }
}

Write-AfsStep 'Clear the cached private answers'
Write-AfsSay 'The forwarder is gone but the private addresses it fetched are still cached, and would be served until they expire.'
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

Complete-AfsSteps -Outcome $(if ($WhatIfPreference) { 'WHAT-IF complete. Nothing was changed.' } else { ('Reverse path complete - ' + $removed + ' forwarder(s) removed.') })

Write-Host 'Confirm resolution is back to the public path:' -ForegroundColor White
Write-Host '  Clear-DnsClientCache'
Write-Host ("  Resolve-DnsName $sa.file.core.windows.net")
Write-Host '  # expect the privatelink CNAME and then a PUBLIC address again'
Write-Host ''
Write-Host 'Any resolver added by hand - a member server, Infoblox, BIND - still has its' -ForegroundColor White
Write-Host 'forwarder and must be reverted the same way.'

Stop-AfsLog -Outcome 'dns forwarders removed'
