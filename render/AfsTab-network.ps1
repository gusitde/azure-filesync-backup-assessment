function Add-AfsTabNetwork {
    <#
      The Network tab: private connectivity as EVIDENCE, not as a verdict.

      It answers one question end to end - can a registered server resolve and reach the storage
      account and the Storage Sync Service over a private path - by walking the only chain that
      matters: target -> endpoint connection -> subnet -> vnet -> DNS zone group -> zone -> the
      zone's vnet links -> A record -> IP. Every hop prints the value the export actually holds,
      and a hop the export cannot prove is labelled as such rather than left blank.

      Sources: network/privateendpoints.json, network/privatednszones.json, network/topology.json,
      cross-checked against manifest.json counts, errors.json, the storage / storagesync
      public-path fields and the server bundles.

      Shapes this renderer is built around (verified against real exports, not just the fixture):
        - privateendpoints.json is a WRAPPER: [{ privateEndpoint:{ARM}, privateDnsZoneGroups:[] }]
        - privatednszones.json is a WRAPPER: [{ zone:{ARM}, virtualNetworkLinks:[], aRecords:[] }]
        - topology.json is flat Resource Graph rows with a LOWERCASE .type
        - an empty result is written as a ZERO-BYTE file, not "[]" (ConvertTo-Json of an empty
          array pipes nothing), and a SINGLE result serialises as a bare object, not an array
        - properties.ipConfigurations / customDnsConfigs on a private endpoint come back EMPTY
          from the ARM list call, so the only IP source here is the zone-group record sets
        - resource ids come back with inconsistent casing, so every join is case-insensitive

      Findings, severities and judgement belong to the Findings tab. This tab names the rule each
      panel feeds (NET-01..NET-11, AFS-11, AFS-14, SEC-03, SEC-05) and stops there.
    #>
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
          [string]$ExportRoot)

    # ------------------------------------------------------------------ helpers
    function NEnc { param($v) if ($null -eq $v) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$v) }
    function NProp { param($o, [string]$n, $d = $null)
        if ($null -eq $o) { return $d }
        $p = $null
        try { $p = $o.PSObject.Properties[$n] } catch { return $d }
        if ($p -and $null -ne $p.Value) { return $p.Value }
        return $d
    }
    function NHas { param($o, [string]$n)
        if ($null -eq $o) { return $false }
        try { return ($null -ne $o.PSObject.Properties[$n]) } catch { return $false }
    }
    # ConvertFrom-Json hands back a bare object for a single-element file and $null for an
    # empty/zero-byte one; every caller wraps this in @(...), so it must NOT return a
    # comma-wrapped array or the wrap would nest instead of flatten.
    function NArr { param($o)
        if ($null -eq $o) { return @() }
        if ($o -is [string] -and [string]::IsNullOrWhiteSpace($o)) { return @() }
        return @($o)
    }
    function NJson { param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $t = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
        if ($null -eq $t) { return $null }
        $t = [string]$t
        if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
        if ([string]::IsNullOrWhiteSpace($t)) { return $null }
        if ($t.Trim() -eq 'null') { return $null }
        try { return ($t | ConvertFrom-Json) } catch { return $null }
    }
    function NPath { param([string]$a, [string]$c)
        if ([string]::IsNullOrWhiteSpace($a)) { return '' }
        try { return (Join-Path $a $c) } catch { return '' }
    }
    function NExists { param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return $false }
        try { return (Test-Path -LiteralPath $p) } catch { return $false }
    }
    function NLc { param($v) if ($null -eq $v) { return '' } return ([string]$v).ToLowerInvariant() }
    function NLeaf { param($v)
        if ($null -eq $v) { return '' }
        $s = ([string]$v).TrimEnd('/')
        if ($s -eq '') { return '' }
        $a = $s.Split('/')
        return $a[$a.Length - 1]
    }
    function NRx { param($v, [string]$rx)
        if ($null -eq $v) { return '' }
        $m = [regex]::Match([string]$v, $rx, 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }
    function NTrunc { param($v, [int]$n)
        if ($null -eq $v) { return '' }
        $s = [string]$v
        if ($s.Length -le $n) { return $s }
        return ($s.Substring(0, [Math]::Max(1, $n - 3)) + '...')
    }
    # a value the export did not contain: say which, never render an empty cell
    function NOr { param($v, [string]$alt = 'not in export')
        if ($null -eq $v -or ([string]$v) -eq '') { return ('<span class="nx-na">' + (NEnc $alt) + '</span>') }
        return (NEnc $v)
    }
    function NYesNo { param($v)
        if ($null -eq $v) { return '<span class="nx-na">not set</span>' }
        if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
        return (NEnc $v)
    }
    function NProvider { param($v)
        if ($null -eq $v) { return '' }
        $s = [string]$v
        $ix = $s.IndexOf('/providers/', [System.StringComparison]::OrdinalIgnoreCase)
        if ($ix -lt 0) { return '' }
        $parts = $s.Substring($ix + 11).Split('/')
        if ($parts.Length -ge 2) { return ($parts[0] + '/' + $parts[1]) }
        return $parts[0]
    }
    function NVnetIdOf { param($subnetId)
        if ($null -eq $subnetId) { return '' }
        $s = [string]$subnetId
        $ix = $s.IndexOf('/subnets/', [System.StringComparison]::OrdinalIgnoreCase)
        if ($ix -gt 0) { return $s.Substring(0, $ix) }
        return ''
    }
    function NIn { param($set, $v)
        $k = NLc $v
        if ($k -eq '') { return $false }
        foreach ($s in @($set)) { if ((NLc $s) -eq $k) { return $true } }
        return $false
    }
    # --- svg primitives: every colour is a page variable, so the picture follows the theme
    function NBox { param([int]$x, [int]$y, [int]$w, [int]$h, [string]$cls, $title, $lines)
        $s = New-Object System.Text.StringBuilder
        [void]$s.Append(('<rect class="b {0}" x="{1}" y="{2}" width="{3}" height="{4}" rx="4"/>' -f $cls, $x, $y, $w, $h))
        # a short box (a stacked record) needs tighter baselines than a full hop box
        $t0 = $y + 15; $l0 = $y + 27; $step = 11
        if ($h -lt 40) { $t0 = $y + 12; $l0 = $y + 23; $step = 10 }
        [void]$s.Append(('<text class="t" x="{0}" y="{1}">{2}</text>' -f ($x + 7), $t0, (NEnc (NTrunc $title ([Math]::Max(8, [int](($w - 12) / 6.2)))))))
        $ty = $l0
        foreach ($l in @($lines)) {
            if ($null -eq $l) { continue }
            if (([string]$l) -eq '') { continue }
            if ($ty -gt ($y + $h - 2)) { break }
            [void]$s.Append(('<text class="s" x="{0}" y="{1}">{2}</text>' -f ($x + 7), $ty, (NEnc (NTrunc $l ([Math]::Max(8, [int](($w - 12) / 5.0)))))))
            $ty += $step
        }
        return $s.ToString()
    }
    function NConn { param([int]$x1, [int]$y, [int]$x2, [string]$cls, $label)
        $s = New-Object System.Text.StringBuilder
        $mid = [int](($x1 + $x2) / 2)
        if ($cls -eq 'bad') {
            [void]$s.Append(('<line class="c bad" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f $x1, $y, ($mid - 9)))
            [void]$s.Append(('<line class="c bad" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f ($mid + 9), $y, ($x2 - 6)))
        } else {
            [void]$s.Append(('<line class="c {3}" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f $x1, $y, ($x2 - 6), $cls))
        }
        [void]$s.Append(('<path class="ah {0}" d="M{1} {2} l-6 -3.5 l0 7 z"/>' -f $cls, $x2, $y))
        if ($null -ne $label -and ([string]$label) -ne '') {
            $tc = 'lbl'
            if ($cls -eq 'bad') { $tc = 'badlbl' }
            $l1 = ''; $l2 = ''
            foreach ($w in (([string]$label) -split '\s+')) {
                if ($l1 -eq '') { $l1 = $w }
                elseif ($l2 -eq '' -and ($l1.Length + 1 + $w.Length) -le 12) { $l1 = $l1 + ' ' + $w }
                else { $l2 = ($l2 + ' ' + $w).Trim() }
            }
            [void]$s.Append(('<text class="{0}" x="{1}" y="{2}" text-anchor="middle">{3}</text>' -f $tc, $mid, ($y + 13), (NEnc (NTrunc $l1 13))))
            if ($l2 -ne '') { [void]$s.Append(('<text class="{0}" x="{1}" y="{2}" text-anchor="middle">{3}</text>' -f $tc, $mid, ($y + 23), (NEnc (NTrunc $l2 13)))) }
        }
        return $s.ToString()
    }

    $b = New-Object System.Text.StringBuilder

    # ------------------------------------------------------------------ scoped style
    [void]$b.Append(@'
<style>
#tab-network .nx-na{color:var(--faint);font-style:italic}
#tab-network .nx-ok{color:var(--good);font-weight:600}
#tab-network .nx-gap{color:var(--crit);font-weight:600}
#tab-network .nx-note{color:var(--muted);font-size:12px;margin:2px 0 10px}
#tab-network .nx-rule{font-family:"IBM Plex Mono",Consolas,monospace;font-size:11px;color:var(--accent);background:var(--info-soft);border-radius:3px;padding:1px 5px;white-space:nowrap}
#tab-network .nx-pre{font-family:"IBM Plex Mono",Consolas,monospace;font-size:11px;color:var(--muted);white-space:pre-wrap;word-break:break-word;max-width:560px;display:block}
#tab-network .nx-chip{display:inline-block;border:1px solid var(--line);border-radius:12px;padding:1px 8px;font-size:11px;color:var(--muted);margin:0 4px 4px 0;background:var(--surface-2)}
#tab-network .nx-chip.on{border-color:var(--good);color:var(--good);background:var(--good-soft)}
#tab-network .nx-chip.off{border-color:var(--crit);color:var(--crit);background:var(--crit-soft)}
#tab-network .nx svg{width:100%;height:auto;display:block}
#tab-network .nx .b{fill:var(--surface);stroke:var(--line);stroke-width:1.2}
#tab-network .nx .b.ok{stroke:var(--accent)}
#tab-network .nx .b.bad{stroke:var(--crit);stroke-dasharray:4 3}
#tab-network .nx .b.ghost{fill:var(--surface-2);stroke:var(--faint);stroke-dasharray:4 3}
#tab-network .nx .lanebox{fill:var(--surface-2);stroke:var(--line);stroke-width:1}
#tab-network .nx .band{fill:var(--surface-3);stroke:var(--line);stroke-dasharray:5 4}
#tab-network .nx text{font-family:"Segoe UI",system-ui,Arial,sans-serif;fill:var(--ink);stroke:none}
#tab-network .nx text.t{font-size:10.5px;font-weight:600}
#tab-network .nx text.s{font-size:9px;fill:var(--muted)}
#tab-network .nx text.lane{font-size:10px;font-weight:600;fill:var(--muted);letter-spacing:.06em}
#tab-network .nx text.lbl{font-size:8.5px;fill:var(--faint)}
#tab-network .nx text.badlbl{font-size:8.5px;fill:var(--crit);font-weight:600}
#tab-network .nx text.hd{font-size:11px;font-weight:600;fill:var(--muted)}
#tab-network .nx .c{stroke:var(--accent);stroke-width:1.6;fill:none}
#tab-network .nx .c.na,#tab-network .nx .c.ghost{stroke:var(--faint);stroke-width:1.2;stroke-dasharray:5 4}
#tab-network .nx .c.bad{stroke:var(--crit);stroke-width:1.8}
#tab-network .nx .ah{fill:var(--accent)}
#tab-network .nx .ah.na,#tab-network .nx .ah.ghost{fill:var(--faint)}
#tab-network .nx .ah.bad{fill:var(--crit)}
#tab-network table.mx td.y{background:var(--good-soft);color:var(--good);font-weight:600;text-align:center}
#tab-network table.mx td.n{background:var(--crit-soft);color:var(--crit);text-align:center}
#tab-network .nx-legend{display:flex;gap:18px;flex-wrap:wrap;color:var(--muted);font-size:12px;margin-top:10px}
#tab-network .nx-legend b{color:var(--ink)}
</style>
'@)

    [void]$b.Append('<h2>Private connectivity</h2>')

    try {
        # -------------------------------------------------------------- load
        $root = [string]$ExportRoot
        if (-not (NExists $root)) {
            [void]$b.Append('<div class="card"><p><b>No readable export directory was supplied to this tab.</b> Nothing below could be read from disk, so every panel states what it would have shown. Re-run the renderer with <code>-ExportRoot</code> pointing at the export folder.</p></div>')
        }
        $netDir = NPath $root 'network'
        $pePath = NPath $netDir 'privateendpoints.json'
        $dzPath = NPath $netDir 'privatednszones.json'
        $tpPath = NPath $netDir 'topology.json'

        # manifest.files is [] in every export, real ones included - stat the paths instead
        $files = @()
        foreach ($fp in @(@{ n = 'network/privateendpoints.json'; p = $pePath },
                          @{ n = 'network/privatednszones.json';  p = $dzPath },
                          @{ n = 'network/topology.json';         p = $tpPath })) {
            $ex = NExists $fp.p
            $bytes = 0
            if ($ex) { try { $bytes = [int](Get-Item -LiteralPath $fp.p -ErrorAction SilentlyContinue).Length } catch { $bytes = 0 } }
            $files += [pscustomobject]@{ name = $fp.n; exists = $ex; bytes = $bytes }
        }

        $pes      = @(NArr (NJson $pePath))
        $zones    = @(NArr (NJson $dzPath))
        $topo     = @(NArr (NJson $tpPath))
        $manifest = NJson (NPath $root 'manifest.json')
        $errs     = @(NArr (NJson (NPath $root 'errors.json')))

        $mCounts = NProp $manifest 'counts'
        $mZones  = NProp $mCounts 'privateDnsZones'
        $mPes    = NProp $mCounts 'privateEndpoints'
        $subs    = @(NArr (NProp $manifest 'subscriptions'))

        $accounts = @()
        $stDir = NPath $root 'storage'
        if (NExists $stDir) {
            foreach ($d in @(Get-ChildItem -LiteralPath $stDir -Directory -ErrorAction SilentlyContinue)) {
                $a = NJson (NPath $d.FullName 'account.json')
                if ($null -ne $a) { $accounts += $a }
            }
        }
        $syncs = @()
        $ssDir = NPath $root 'storagesync'
        if (NExists $ssDir) {
            foreach ($d in @(Get-ChildItem -LiteralPath $ssDir -Directory -ErrorAction SilentlyContinue)) {
                $svc = NJson (NPath $d.FullName 'service.json')
                $pec = @(NArr (NJson (NPath $d.FullName 'privateendpointconnections.json')))
                if ($null -ne $svc -or $pec.Count -gt 0) { $syncs += [pscustomobject]@{ dir = $d.Name; svc = $svc; pec = $pec } }
            }
        }
        $servers = @()
        $svDir = NPath $root 'servers'
        if (NExists $svDir) {
            foreach ($hd in @(Get-ChildItem -LiteralPath $svDir -Directory -ErrorAction SilentlyContinue)) {
                foreach ($bd in @(Get-ChildItem -LiteralPath $hd.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $nj = NJson (NPath $bd.FullName 'network.json')
                    $dbgPath = NPath $bd.FullName 'debug-network.txt'
                    $dbg = ''
                    if (NExists $dbgPath) {
                        $dbg = Get-Content -LiteralPath $dbgPath -Raw -ErrorAction SilentlyContinue
                        if ($null -eq $dbg) { $dbg = '' }
                    }
                    $servers += [pscustomobject]@{
                        host = $hd.Name; bundle = $bd.Name
                        ipcfg = @(NArr (NProp $nj 'ipConfiguration'))
                        dns   = @(NArr (NProp $nj 'dnsTests'))
                        debug = ([string]$dbg).Trim()
                    }
                }
            }
        }

        # -------------------------------------------------------------- model: zones
        $zoneRows = @()
        foreach ($zw in $zones) {
            $z = NProp $zw 'zone'
            if ($null -eq $z) { $z = $zw }
            $zp = NProp $z 'properties'
            $links = @(NArr (NProp $zw 'virtualNetworkLinks'))
            $arecs = @(NArr (NProp $zw 'aRecords'))
            $linkVnetIds = @()
            foreach ($l in $links) {
                $vid = NProp (NProp (NProp $l 'properties') 'virtualNetwork') 'id' ''
                if ($vid) { $linkVnetIds += [string]$vid }
            }
            $zoneRows += [pscustomobject]@{
                name = [string](NProp $z 'name' ''); id = [string](NProp $z 'id' '')
                rg = (NRx (NProp $z 'id' '') '/resourceGroups/([^/]+)')
                loc = [string](NProp $z 'location' ''); prov = [string](NProp $zp 'provisioningState' '')
                nRs = NProp $zp 'numberOfRecordSets'; nVl = NProp $zp 'numberOfVirtualNetworkLinks'
                nVlReg = NProp $zp 'numberOfVirtualNetworkLinksWithRegistration'
                links = $links; arecs = $arecs; vnetIds = $linkVnetIds
            }
        }

        # -------------------------------------------------------------- model: private endpoints
        $peRows = @()
        foreach ($w in $pes) {
            $p = NProp $w 'privateEndpoint'
            if ($null -eq $p) { $p = $w }
            $pp = NProp $p 'properties'
            $conns = @()
            foreach ($pair in @(@{ a = 'privateLinkServiceConnections'; m = $false },
                                @{ a = 'manualPrivateLinkServiceConnections'; m = $true })) {
                foreach ($c in @(NArr (NProp $pp $pair.a))) {
                    $cp = NProp $c 'properties'
                    $st = NProp $cp 'privateLinkServiceConnectionState'
                    $tid = [string](NProp $cp 'privateLinkServiceId' '')
                    # the two providers disagree on the spelling - read both
                    $ar = NProp $st 'actionsRequired'
                    if ($null -eq $ar) { $ar = NProp $st 'actionRequired' }
                    $conns += [pscustomobject]@{
                        name = [string](NProp $c 'name' ''); targetId = $tid; target = (NLeaf $tid)
                        provider = (NProvider $tid); groupIds = @(NArr (NProp $cp 'groupIds'))
                        status = [string](NProp $st 'status' ''); desc = [string](NProp $st 'description' '')
                        actions = $ar; manual = $pair.m
                    }
                }
            }
            $subnetId = [string](NProp (NProp $pp 'subnet') 'id' '')
            $zgs = @()
            foreach ($g in @(NArr (NProp $w 'privateDnsZoneGroups'))) {
                foreach ($cfg in @(NArr (NProp (NProp $g 'properties') 'privateDnsZoneConfigs'))) {
                    $cp2 = NProp $cfg 'properties'
                    $zid = [string](NProp $cp2 'privateDnsZoneId' '')
                    $recs = @()
                    foreach ($r in @(NArr (NProp $cp2 'recordSets'))) {
                        $recs += [pscustomobject]@{
                            type = [string](NProp $r 'recordType' ''); name = [string](NProp $r 'recordSetName' '')
                            fqdn = [string](NProp $r 'fqdn' ''); ttl = NProp $r 'ttl'
                            prov = [string](NProp $r 'provisioningState' ''); ips = @(NArr (NProp $r 'ipAddresses'))
                        }
                    }
                    $zgs += [pscustomobject]@{
                        group = [string](NProp $g 'name' ''); cfgName = [string](NProp $cfg 'name' '')
                        zoneId = $zid; zoneName = (NLeaf $zid); prov = [string](NProp $cp2 'provisioningState' '')
                        recs = $recs
                    }
                }
            }
            $gids = @()
            foreach ($c in $conns) { foreach ($g in @($c.groupIds)) { $gids += [string]$g } }
            $isAfs = $false
            foreach ($g in $gids) { if ((NLc $g) -eq 'afs') { $isAfs = $true } }
            $ips = @(); $recCount = 0
            foreach ($zg in $zgs) { $recCount += @($zg.recs).Count; foreach ($r in $zg.recs) { foreach ($i in @($r.ips)) { $ips += [string]$i } } }
            $peId = [string](NProp $p 'id' '')
            $peRows += [pscustomobject]@{
                name = [string](NProp $p 'name' ''); id = $peId
                rg = (NRx $peId '/resourceGroups/([^/]+)'); loc = [string](NProp $p 'location' '')
                prov = [string](NProp $pp 'provisioningState' ''); conns = $conns
                subnetId = $subnetId; subnet = (NLeaf $subnetId)
                vnet = (NRx $subnetId '/virtualNetworks/([^/]+)'); vnetId = (NVnetIdOf $subnetId)
                zgs = $zgs; gids = $gids; isAfs = $isAfs; ips = $ips; recCount = $recCount
            }
        }

        # -------------------------------------------------------------- model: topology
        $vnets = @(); $resolvers = @()
        foreach ($r in $topo) {
            $t = NLc (NProp $r 'type' '')
            if ($t -eq 'microsoft.network/virtualnetworks') { $vnets += $r }
            elseif ($t -eq 'microsoft.network/dnsresolvers') { $resolvers += $r }
        }
        $topoTypes = @(
            @{ k = 'microsoft.network/virtualnetworks';        l = 'Virtual networks' },
            @{ k = 'microsoft.network/dnsresolvers';           l = 'DNS Private Resolvers' },
            @{ k = 'microsoft.network/expressroutecircuits';   l = 'ExpressRoute circuits' },
            @{ k = 'microsoft.network/virtualnetworkgateways'; l = 'VNet gateways (VPN / ER)' },
            @{ k = 'microsoft.network/expressroutegateways';   l = 'ExpressRoute gateways (vWAN)' },
            @{ k = 'microsoft.network/connections';            l = 'Gateway connections' },
            @{ k = 'microsoft.network/virtualhubs';            l = 'Virtual WAN hubs' },
            @{ k = 'microsoft.network/azurefirewalls';         l = 'Azure Firewalls' },
            @{ k = 'microsoft.network/dnsforwardingrulesets';  l = 'DNS forwarding rulesets' }
        )

        # union of every vnet visible in any of the three files, keyed case-insensitively
        $vnetIdx = @{}
        foreach ($v in $vnets) {
            $vid = [string](NProp $v 'id' ''); $k = NLc $vid
            if ($k -ne '' -and -not $vnetIdx.ContainsKey($k)) { $vnetIdx[$k] = [pscustomobject]@{ id = $vid; name = [string](NProp $v 'name' ''); src = 'topology' } }
        }
        foreach ($z in $zoneRows) {
            foreach ($vid in $z.vnetIds) {
                $k = NLc $vid
                if ($k -ne '' -and -not $vnetIdx.ContainsKey($k)) { $vnetIdx[$k] = [pscustomobject]@{ id = [string]$vid; name = (NLeaf $vid); src = 'zone link only - not in topology' } }
            }
        }
        foreach ($pr in $peRows) {
            $k = NLc $pr.vnetId
            if ($k -ne '' -and -not $vnetIdx.ContainsKey($k)) { $vnetIdx[$k] = [pscustomobject]@{ id = $pr.vnetId; name = $pr.vnet; src = 'endpoint subnet only - not in topology' } }
        }

        # -------------------------------------------------------------- the resolution chain
        $chains = @()
        foreach ($pr in $peRows) {
            $issues = @()
            $conn = $null
            if (@($pr.conns).Count -gt 0) { $conn = @($pr.conns)[0] }
            if ($null -eq $conn) { $issues += 'the endpoint carries no privateLinkServiceConnection' }
            elseif ($conn.status -ne 'Approved') { $issues += ('connection status is ' + $conn.status + ', not Approved') }

            $zoneHits = @()
            foreach ($zg in $pr.zgs) {
                $zrow = $null
                foreach ($z in $zoneRows) {
                    if ((NLc $z.id) -eq (NLc $zg.zoneId) -or ((NLc $z.name) -ne '' -and (NLc $z.name) -eq (NLc $zg.zoneName))) { $zrow = $z; break }
                }
                $linked = $false
                if ($null -ne $zrow -and $pr.vnetId -ne '') { $linked = (NIn $zrow.vnetIds $pr.vnetId) }
                $mismatch = @()
                if ($null -ne $zrow) {
                    foreach ($r in $zg.recs) {
                        $za = $null
                        foreach ($ar in $zrow.arecs) { if ((NLc (NProp $ar 'name' '')) -eq (NLc $r.name)) { $za = $ar; break } }
                        if ($null -eq $za) { $mismatch += ($r.name + ': the zone holds no A record of that name'); continue }
                        $zips = @()
                        foreach ($e in @(NArr (NProp (NProp $za 'properties') 'aRecords'))) { $zips += [string](NProp $e 'ipv4Address' '') }
                        foreach ($ip in @($r.ips)) { if (-not (NIn $zips $ip)) { $mismatch += ($r.name + ': zone-group IP ' + $ip + ' is not the IP in the zone A record') } }
                    }
                }
                $zoneHits += [pscustomobject]@{ zg = $zg; zone = $zrow; linked = $linked; mismatch = $mismatch }
            }
            if (@($pr.zgs).Count -eq 0) { $issues += 'no private DNS zone group on the endpoint, so no record is managed for it' }
            foreach ($h in $zoneHits) {
                if ($null -eq $h.zone) { $issues += ('zone ' + $h.zg.zoneName + ' is referenced by the zone group but is not in the export') }
                elseif (-not $h.linked) { $issues += ('zone ' + $h.zg.zoneName + ' is not linked to ' + $pr.vnet + ' - the vnet the endpoint sits in') }
                foreach ($m in $h.mismatch) { $issues += $m }
            }
            $expected = 1
            $missingNames = @()
            if ($pr.isAfs) {
                $expected = 4
                foreach ($suffix in @('management', 'syncp', 'syncs', 'monitoring')) {
                    $found = $false
                    foreach ($zg in $pr.zgs) { foreach ($r in $zg.recs) { if ((NLc $r.name) -match $suffix) { $found = $true } } }
                    if (-not $found) { $missingNames += $suffix }
                }
            }
            if ($pr.recCount -lt $expected) {
                $miss = ''
                if ($missingNames.Count -gt 0) { $miss = ' (missing: ' + ($missingNames -join ', ') + ')' }
                $issues += ('' + $pr.recCount + ' of ' + $expected + ' expected name(s) published' + $miss)
            }
            if (@($pr.ips).Count -eq 0) { $issues += 'no private IP for this endpoint anywhere in the export' }

            $resolver = $null
            foreach ($rr in $resolvers) {
                $rv = [string](NProp (NProp (NProp $rr 'properties') 'virtualNetwork') 'id' '')
                if ($pr.vnetId -ne '' -and (NLc $rv) -eq (NLc $pr.vnetId)) { $resolver = $rr; break }
            }
            if ($null -eq $resolver -and $resolvers.Count -gt 0) { $resolver = $resolvers[0] }

            $chains += [pscustomobject]@{ pe = $pr; conn = $conn; zoneHits = $zoneHits; issues = $issues; expected = $expected; resolver = $resolver }
        }
        $chainsClean = @($chains | Where-Object { @($_.issues).Count -eq 0 }).Count

        # -------------------------------------------------------------- reverse index
        $peIds = @()
        foreach ($pr in $peRows) { if ($pr.id) { $peIds += $pr.id } }
        $refs = @()
        foreach ($a in $accounts) {
            foreach ($c in @(NArr (NProp (NProp $a 'properties') 'privateEndpointConnections'))) {
                $cp = NProp $c 'properties'
                $refPeId = [string](NProp (NProp $cp 'privateEndpoint') 'id' '')
                $st = NProp $cp 'privateLinkServiceConnectionState'
                $refs += [pscustomobject]@{
                    from = ('storage account ' + [string](NProp $a 'name' '')); conn = [string](NProp $c 'name' '')
                    peName = (NLeaf $refPeId); status = [string](NProp $st 'status' ''); known = (NIn $peIds $refPeId)
                }
            }
        }
        foreach ($s in $syncs) {
            $svcName = [string](NProp $s.svc 'name' $s.dir)
            $all = @($s.pec)
            foreach ($c in @(NArr (NProp (NProp $s.svc 'properties') 'privateEndpointConnections'))) { $all += $c }
            $seen = @()
            foreach ($c in $all) {
                $cp = NProp $c 'properties'
                $refPeId = [string](NProp (NProp $cp 'privateEndpoint') 'id' '')
                if ($refPeId -ne '' -and (NIn $seen $refPeId)) { continue }
                if ($refPeId -ne '') { $seen += $refPeId }
                $st = NProp $cp 'privateLinkServiceConnectionState'
                $refs += [pscustomobject]@{
                    from = ('Storage Sync Service ' + $svcName); conn = [string](NProp $c 'name' '')
                    peName = (NLeaf $refPeId); status = [string](NProp $st 'status' ''); known = (NIn $peIds $refPeId)
                }
            }
        }
        $dangling = @($refs | Where-Object { -not $_.known })

        $netErrs = @($errs | Where-Object { (NLc (NProp $_ 'where' '')) -match '^(privatednszones|vnetlinks|arecords|privateendpoints|dnszonegroups|resourcegraph)' })

        # -------------------------------------------------------------- verdict strip
        $vnetLinked = 0
        foreach ($k in @($vnetIdx.Keys)) {
            foreach ($z in $zoneRows) { if (NIn $z.vnetIds $vnetIdx[$k].id) { $vnetLinked++; break } }
        }
        [void]$b.Append('<div class="tiles">')
        [void]$b.Append(('<div class="tile"><div class="n">{0}</div><div class="l">private DNS zones</div></div>' -f $zoneRows.Count))
        [void]$b.Append(('<div class="tile"><div class="n">{0}</div><div class="l">private endpoints</div></div>' -f $peRows.Count))
        [void]$b.Append(('<div class="tile"><div class="n">{0}</div><div class="l">topology rows</div></div>' -f $topo.Count))
        [void]$b.Append(('<div class="tile"><div class="n">{0}</div><div class="l">vnets linked to a zone</div></div>' -f ("$vnetLinked/" + $vnetIdx.Count)))
        [void]$b.Append('</div>')

        [void]$b.Append('<div class="card"><div class="kv">')
        $zMis = ''; $pMis = ''
        if ($null -ne $mZones -and [int]$mZones -ne $zoneRows.Count) { $zMis = ' <span class="nx-gap">(does not match)</span>' }
        if ($null -ne $mPes -and [int]$mPes -ne $peRows.Count) { $pMis = ' <span class="nx-gap">(does not match)</span>' }
        [void]$b.Append('<div class="k">Reconciled against manifest.json</div><div>')
        [void]$b.Append(('privateDnsZones: manifest {0}, file {1}{2} &nbsp;&middot;&nbsp; privateEndpoints: manifest {3}, file {4}{5}' -f `
            (NOr $mZones 'not stated'), $zoneRows.Count, $zMis, (NOr $mPes 'not stated'), $peRows.Count, $pMis))
        [void]$b.Append('</div>')
        [void]$b.Append('<div class="k">Files on disk</div><div>')
        foreach ($f in $files) {
            $st = 'absent'; $cls = 'off'
            if ($f.exists -and $f.bytes -eq 0) { $st = 'present, zero bytes = no rows'; $cls = '' }
            elseif ($f.exists) { $st = ('present, ' + $f.bytes + ' bytes'); $cls = 'on' }
            [void]$b.Append(('<span class="nx-chip {0}">{1}: {2}</span>' -f $cls, (NEnc $f.name), (NEnc $st)))
        }
        [void]$b.Append('</div>')
        [void]$b.Append('<div class="k">Complete resolution chains</div><div>')
        if ($peRows.Count -eq 0) { [void]$b.Append('no private endpoint to walk') }
        else { [void]$b.Append(('' + $chainsClean + ' of ' + $peRows.Count + ' endpoint(s) have every hop this export can see')) }
        [void]$b.Append('</div>')
        [void]$b.Append('<div class="k">Collection errors on this tab</div><div>')
        if ($netErrs.Count -eq 0) { [void]$b.Append('none - so an object absent below is <b>not configured</b>, not <b>not collected</b>') }
        else { [void]$b.Append('<span class="nx-gap">' + $netErrs.Count + ' - an object absent below may be a collection failure; see Export integrity</span>') }
        [void]$b.Append('</div></div></div>')

        # -------------------------------------------------------------- headline for the zero case
        if ($peRows.Count -eq 0 -and $zoneRows.Count -eq 0) {
            [void]$b.Append('<div class="card">')
            [void]$b.Append('<p><b>No privatelink.file / privatelink.afs zone and no Storage or File Sync private endpoint in the exported subscriptions.</b> ')
            [void]$b.Append('Every File Sync and SMB byte therefore uses the public endpoints over HTTPS/443 with Microsoft routing - supported and normal. ')
            [void]$b.Append('The verdict on that is <span class="nx-rule">NET-01</span> on the Findings tab (Info, or High when the engagement declares private routing required); it is not restated here.</p>')
            [void]$b.Append('<h4>Zero has three different causes, and the export says which</h4>')
            [void]$b.Append('<table><thead><tr><th>Cause</th><th>Evidence it needs</th><th>Present here</th></tr></thead><tbody>')
            $countsStated = ($null -ne $mZones) -and ($null -ne $mPes)
            $countsZero = $countsStated -and ([int]$mZones -eq 0) -and ([int]$mPes -eq 0)
            $cell1 = 'no'
            if ($netErrs.Count -eq 0 -and $countsZero) { $cell1 = '<span class="nx-ok">yes - this is the case in this export</span>' }
            elseif ($netErrs.Count -eq 0) { $cell1 = 'likely - no error row, but manifest.json did not state the counts' }
            [void]$b.Append(('<tr><td>Not configured</td><td>errors.json holds no networking row and the manifest counts are 0</td><td>{0}</td></tr>' -f $cell1))
            $subNames = @()
            foreach ($s in $subs) { $subNames += [string](NProp $s 'name' (NProp $s 'id' '?')) }
            [void]$b.Append(('<tr><td>Outside the exported scope</td><td>a hub, zone or resolver in a platform / connectivity subscription that was not exported</td><td>possible - the export covers {0} subscription(s): {1}</td></tr>' -f `
                $subs.Count, (NOr ($subNames -join ', ') 'not stated')))
            $cell3 = 'no'
            if ($netErrs.Count -gt 0) { $cell3 = '<span class="nx-gap">yes - ' + $netErrs.Count + ' row(s)</span>' }
            [void]$b.Append(('<tr><td>Export failure</td><td>an errors.json row for privateDnsZones:&lt;sub&gt;, privateEndpoints:&lt;sub&gt; or resourceGraph:topology</td><td>{0}</td></tr>' -f $cell3))
            [void]$b.Append('</tbody></table>')
            if ($dangling.Count -gt 0) {
                [void]$b.Append('<p><b>The estate does, however, reference a private endpoint.</b> ')
                foreach ($d in $dangling) {
                    [void]$b.Append(('{0} declares a connection to <code>{1}</code>, which is not in network/privateendpoints.json. ' -f (NEnc $d.from), (NEnc $d.peName)))
                }
                [void]$b.Append('That endpoint lives in a subscription outside this export, or the Network list call did not return it. It is not evidence that no private endpoint exists.</p>')
            }
            [void]$b.Append('</div>')
        }

        # -------------------------------------------------------------- diagram
        [void]$b.Append('<h2>Resolution chain</h2>')
        [void]$b.Append('<p class="nx-note">One chain per private endpoint, left to right, in the three lanes the as-built uses. A <b>solid</b> line means the export holds evidence for that hop; a <b>dashed grey</b> line covers the two hops no ARM export can prove; a <b>broken red</b> line marks a hop the data shows is missing. The shaded band carries the two legs that never touch the customer network.</p>')
        [void]$b.Append('<div class="card nx">')

        $W = 1280
        $bx = @(8, 190, 372, 562, 748, 974, 1156)
        $bw = @(126, 126, 134, 140, 180, 126, 116)
        $laneTop = 4
        $rowTop = 34
        $bandH = 104

        $rowH = @()
        $pubTargets = @()
        if ($chains.Count -gt 0) {
            foreach ($c in $chains) { if ($c.pe.isAfs) { $rowH += 158 } else { $rowH += 88 } }
        } else {
            foreach ($s in $syncs) {
                $sp = NProp $s.svc 'properties'
                $pubTargets += [pscustomobject]@{
                    n  = [string](NProp $s.svc 'name' $s.dir)
                    d1 = ('incomingTrafficPolicy=' + [string](NProp $sp 'incomingTrafficPolicy' 'not set'))
                    d2 = ('private endpoint connections: ' + @($s.pec).Count)
                }
            }
            foreach ($a in $accounts) {
                $ap = NProp $a 'properties'; $acl = NProp $ap 'networkAcls'
                $pna = NProp $ap 'publicNetworkAccess'
                $pnaTxt = 'publicNetworkAccess not set (behaves as Enabled)'
                if ($null -ne $pna) { $pnaTxt = 'publicNetworkAccess=' + [string]$pna }
                $pubTargets += [pscustomobject]@{
                    n  = [string](NProp $a 'name' '')
                    d1 = $pnaTxt
                    d2 = ('defaultAction=' + [string](NProp $acl 'defaultAction' '?') + '   bypass=' + [string](NProp $acl 'bypass' '?'))
                }
            }
            if ($pubTargets.Count -eq 0) { $pubTargets += [pscustomobject]@{ n = 'no target in the export'; d1 = 'no storage account and no Storage Sync Service'; d2 = '' } }
            $rowH += 96
            $rowH += (28 + ($pubTargets.Count * 56))
        }
        $chainH = 0
        foreach ($r in $rowH) { $chainH += $r }
        $laneBottom = $rowTop + $chainH
        if ($chains.Count -eq 0) { $laneBottom = $rowTop + $rowH[0] }
        $bandY = $rowTop + $chainH + 14
        $H = $bandY + $bandH + 6

        $lbl = 'Resolution chain from a registered server through DNS to the Azure service, one row per private endpoint'
        if ($chains.Count -eq 0) { $lbl = 'No private path in this export: the private chain is drawn greyed and the live public route is drawn beneath it' }
        [void]$b.Append(('<svg viewBox="0 0 {0} {1}" role="img" aria-label="{2}">' -f $W, $H, (NEnc $lbl)))

        $vnetLabel = 'VNet'
        if ($chains.Count -gt 0 -and $chains[0].pe.vnet -ne '') { $vnetLabel = 'VNet ' + $chains[0].pe.vnet }
        elseif ($vnets.Count -gt 0) { $vnetLabel = 'VNet ' + [string](NProp $vnets[0] 'name' '') }
        foreach ($ln in @(@{ x = 0; w = 344; t = 'ON-PREMISES' }, @{ x = 350; w = 782; t = $vnetLabel }, @{ x = 1138; w = 142; t = 'AZURE SERVICE' })) {
            [void]$b.Append(('<rect class="lanebox" x="{0}" y="{1}" width="{2}" height="{3}" rx="4" opacity="0.6"/>' -f $ln.x, $laneTop, $ln.w, ($laneBottom - $laneTop)))
            [void]$b.Append(('<text class="lane" x="{0}" y="{1}">{2}</text>' -f ($ln.x + 8), ($laneTop + 14), (NEnc (NTrunc $ln.t 42))))
        }

        $y = $rowTop
        if ($chains.Count -gt 0) {
            $ri = 0
            foreach ($c in $chains) {
                $rh = $rowH[$ri]; $ri++
                $cy = $y + [int]($rh / 2) + 4
                $by = $cy - 31
                $pe = $c.pe

                $srvName = 'no server bundle'
                $srvLines = @('not in export')
                if ($servers.Count -gt 0) {
                    $srvName = $servers[0].host
                    $srvLines = @('File Sync agent')
                    if ($servers.Count -gt 1) { $srvLines = @('File Sync agent', ('and ' + ($servers.Count - 1) + ' more')) }
                }
                [void]$b.Append((NBox $bx[0] $by $bw[0] 62 'ghost' $srvName $srvLines))
                [void]$b.Append((NBox $bx[1] $by $bw[1] 62 'ghost' 'on-prem DNS' @('conditional forwarder', 'never in an export')))
                [void]$b.Append((NConn ($bx[0] + $bw[0]) $cy $bx[1] 'na' 'not visible from ARM'))

                $rvName = 'no DNS resolver'; $rvCls = 'bad'; $rvLines = @('none in topology')
                if ($null -ne $c.resolver) {
                    $rvName = [string](NProp $c.resolver 'name' '')
                    $rvCls = 'ok'
                    $rvLines = @([string](NProp (NProp $c.resolver 'properties') 'dnsResolverState' ''), 'inbound IP not captured')
                }
                [void]$b.Append((NBox $bx[2] $by $bw[2] 62 $rvCls $rvName $rvLines))
                [void]$b.Append((NConn ($bx[1] + $bw[1]) $cy $bx[2] 'na' 'not visible from ARM'))

                $hit = $null
                if (@($c.zoneHits).Count -gt 0) { $hit = @($c.zoneHits)[0] }
                $zName = 'no zone group'; $zCls = 'bad'; $zLines = @('nothing manages a record'); $c3 = 'bad'; $c3l = 'no zone group'
                if ($null -ne $hit) {
                    $zName = $hit.zg.zoneName
                    if ($null -eq $hit.zone) { $zCls = 'bad'; $zLines = @('not in the export'); $c3 = 'bad'; $c3l = 'zone missing' }
                    elseif (-not $hit.linked) { $zCls = 'bad'; $zLines = @(('linked vnets: ' + @($hit.zone.links).Count), ('not ' + $pe.vnet)); $c3 = 'bad'; $c3l = 'vnet not linked' }
                    else { $zCls = 'ok'; $zLines = @(('linked vnets: ' + @($hit.zone.links).Count), 'this vnet is linked'); $c3 = ''; $c3l = '' }
                }
                [void]$b.Append((NBox $bx[3] $by $bw[3] 62 $zCls $zName $zLines))
                [void]$b.Append((NConn ($bx[2] + $bw[2]) $cy $bx[3] $c3 $c3l))

                $recs = @()
                foreach ($zg in $pe.zgs) { foreach ($r in $zg.recs) { $recs += $r } }
                $slots = $c.expected
                if (@($recs).Count -gt $slots) { $slots = @($recs).Count }
                if ($slots -lt 1) { $slots = 1 }
                $sh = 30; $sgap = 4
                $sy = $cy - [int]((($slots * ($sh + $sgap)) - $sgap) / 2)
                for ($ki = 0; $ki -lt $slots; $ki++) {
                    $byy = $sy + ($ki * ($sh + $sgap))
                    if ($ki -lt @($recs).Count) {
                        $r = @($recs)[$ki]
                        $ipTxt = 'no IP'
                        if (@($r.ips).Count -gt 0) { $ipTxt = (@($r.ips) -join ', ') }
                        $ttlTxt = '?'
                        if ($null -ne $r.ttl) { $ttlTxt = [string]$r.ttl }
                        [void]$b.Append((NBox $bx[4] $byy $bw[4] $sh 'ok' $r.name @(('ttl ' + $ttlTxt + '   ' + $ipTxt))))
                    } else {
                        [void]$b.Append((NBox $bx[4] $byy $bw[4] $sh 'bad' 'name not published' @()))
                    }
                }
                $c4 = ''; $c4l = ''
                if (@($recs).Count -eq 0) { $c4 = 'bad'; $c4l = 'no A record' }
                elseif (@($recs).Count -lt $c.expected) { $c4 = 'bad'; $c4l = ('' + @($recs).Count + ' of ' + $c.expected) }
                [void]$b.Append((NConn ($bx[3] + $bw[3]) $cy $bx[4] $c4 $c4l))

                $nicIp = 'IP not in export'
                $nicCls = 'bad'; $c5 = 'bad'; $c5l = 'no IP'
                if (@($pe.ips).Count -gt 0) {
                    $nicIp = [string]@($pe.ips)[0]
                    if (@($pe.ips).Count -gt 1) { $nicIp = $nicIp + ' +' + (@($pe.ips).Count - 1) + ' more' }
                    $nicCls = 'ok'; $c5 = ''; $c5l = ''
                }
                $snTxt = 'subnet not in export'
                if ($pe.subnet -ne '') { $snTxt = 'subnet ' + $pe.subnet }
                [void]$b.Append((NBox $bx[5] $by $bw[5] 62 $nicCls $pe.name @($nicIp, $snTxt)))
                [void]$b.Append((NConn ($bx[4] + $bw[4]) $cy $bx[5] $c5 $c5l))

                $tName = 'no connection'; $tLines = @('nothing to reach'); $c6 = 'bad'; $c6l = 'no connection'; $tCls = 'bad'
                if ($null -ne $c.conn) {
                    $tName = $c.conn.target
                    $gid = ''
                    if (@($c.conn.groupIds).Count -gt 0) { $gid = [string]@($c.conn.groupIds)[0] }
                    $tLines = @(('[' + $gid + '] ' + $c.conn.status), (NLeaf $c.conn.provider))
                    if ($c.conn.status -eq 'Approved') { $c6 = ''; $c6l = ''; $tCls = 'ok' } else { $c6l = ('status ' + $c.conn.status) }
                }
                [void]$b.Append((NBox $bx[6] $by $bw[6] 62 $tCls $tName $tLines))
                [void]$b.Append((NConn ($bx[5] + $bw[5]) $cy $bx[6] $c6 $c6l))

                $y += $rh
            }
        } else {
            # empty state: the private skeleton greyed, the live public route drawn beneath it
            $cy = $y + 54; $by = $cy - 31
            $ghost = @('registered server', 'on-prem DNS', 'DNS resolver', 'privatelink zone', 'A record', 'private endpoint', 'target')
            [void]$b.Append(('<text class="hd" x="8" y="{0}">the private path, as it would be - none of it exists in this export</text>' -f ($y + 14)))
            for ($ki = 0; $ki -lt 7; $ki++) {
                [void]$b.Append((NBox $bx[$ki] $by $bw[$ki] 62 'ghost' $ghost[$ki] @('not configured')))
                if ($ki -gt 0) { [void]$b.Append((NConn ($bx[$ki - 1] + $bw[$ki - 1]) $cy $bx[$ki] 'ghost' '')) }
            }
            $y += $rowH[0]
            [void]$b.Append(('<text class="hd" x="8" y="{0}">what is actually happening today</text>' -f ($y + 16)))
            $py = $y + 26
            foreach ($t in $pubTargets) {
                $pcy = $py + 24
                [void]$b.Append((NBox 8 $py 200 48 'ghost' 'registered servers' @(('' + $servers.Count + ' bundle(s) in the export'))))
                [void]$b.Append((NBox 300 $py 200 48 'ok' 'HTTPS 443' @('public DNS', 'Microsoft routing')))
                [void]$b.Append((NBox 592 $py 240 48 'ok' 'public endpoint' @('no private endpoint exists')))
                [void]$b.Append((NBox 924 $py 348 48 'ok' $t.n @($t.d1, $t.d2)))
                [void]$b.Append((NConn 208 $pcy 300 '' ''))
                [void]$b.Append((NConn 500 $pcy 592 '' ''))
                [void]$b.Append((NConn 832 $pcy 924 '' ''))
                $py += 56
            }
        }

        # the two legs that have no customer-network path at all - the question customers ask most
        [void]$b.Append(('<rect class="band" x="0" y="{0}" width="{1}" height="{2}" rx="6"/>' -f $bandY, $W, $bandH))
        [void]$b.Append(('<text class="lane" x="10" y="{0}">MICROSOFT INTERNAL - no customer-network path exists, and none is needed (NET-09)</text>' -f ($bandY + 17)))
        $l1y = $bandY + 27
        [void]$b.Append((NBox 10 $l1y 250 30 'ghost' 'Storage Sync Service' @()))
        [void]$b.Append((NBox 430 $l1y 250 30 'ghost' 'storage account / file share' @()))
        [void]$b.Append((NConn 260 ($l1y + 15) 430 '' 'server-side sync'))
        $l2y = $bandY + 67
        [void]$b.Append((NBox 10 $l2y 250 30 'ghost' 'Azure Backup vault' @()))
        [void]$b.Append((NBox 430 $l2y 250 30 'ghost' 'Azure file share snapshot' @()))
        [void]$b.Append((NConn 260 ($l2y + 15) 430 '' 'trusted services'))
        [void]$b.Append(('<text class="s" x="700" y="{0}">Neither leg can be forced through ExpressRoute or a private endpoint.</text>' -f ($l1y + 20)))
        [void]$b.Append(('<text class="s" x="700" y="{0}">A private endpoint on the vault does not apply to Azure Files.</text>' -f ($l2y + 20)))
        [void]$b.Append('</svg>')
        [void]$b.Append('<div class="nx-legend"><span><b>solid</b> the export holds evidence</span><span><b>dashed grey</b> not visible from ARM</span><span><b>broken red</b> the data shows this hop missing</span><span><b>stacked boxes</b> the four names an Afs endpoint must publish</span></div>')
        [void]$b.Append('</div>')

        # -------------------------------------------------------------- private endpoints
        [void]$b.Append('<h2>Private endpoints</h2>')
        if ($peRows.Count -eq 0) {
            [void]$b.Append('<div class="card"><p>The export holds no private endpoint targeting a storage account or a Storage Sync Service. The exporter lists only endpoints whose target is <code>Microsoft.Storage/storageAccounts</code> or <code>Microsoft.StorageSync/storageSyncServices</code>, so a blob, Key Vault or Azure Migrate cache endpoint would be absent here by design, not missing.</p></div>')
        } else {
            [void]$b.Append('<p class="nx-note">Private IP addresses come only from the DNS zone group record sets. <code>properties.ipConfigurations</code> and <code>properties.customDnsConfigs</code> are returned EMPTY by the ARM list call in every real export, and <code>networkInterfaces[]</code> yields only a NIC id that is never exported - so a blank IP column would be a tooling artefact, not a configuration gap. Feeds <span class="nx-rule">NET-03</span> <span class="nx-rule">NET-04</span>.</p>')
            [void]$b.Append('<table><thead><tr><th>Endpoint</th><th>RG / location</th><th>State</th><th>Target</th><th>Group ids</th><th>Connection</th><th>Subnet / vnet</th><th>Private IP</th></tr></thead><tbody>')
            foreach ($pr in $peRows) {
                $cList = @($pr.conns)
                if ($cList.Count -eq 0) {
                    [void]$b.Append(('<tr><td class="res">{0}</td><td>{1}<br><span class="ev">{2}</span></td><td>{3}</td><td colspan="4"><span class="nx-gap">the endpoint carries no privateLinkServiceConnection and no manual connection</span></td><td class="ev">{4}</td></tr>' -f `
                        (NEnc $pr.name), (NOr $pr.rg), (NOr $pr.loc), (NOr $pr.prov), (NOr (@($pr.ips) -join ', ') 'no IP')))
                }
                foreach ($c in $cList) {
                    # description reads 'Auto-Approved' when the platform approved it; blank means it did not
                    $appr = [string]$c.desc
                    if ($c.manual) { $appr = 'MANUAL connection request' }
                    elseif (([string]$c.desc) -eq '') { $appr = 'blank description - not Auto-Approved' }
                    $stTxt = (NOr $c.status 'no status')
                    if ($c.status -ne '' -and $c.status -ne 'Approved') { $stTxt = '<span class="nx-gap">' + (NEnc $c.status) + '</span>' }
                    [void]$b.Append(('<tr><td class="res">{0}</td><td>{1}<br><span class="ev">{2}</span></td><td>{3}</td><td class="res">{4}<br><span class="ev">{5}</span></td><td>{6}</td><td>{7}<br><span class="ev">{8}; actionsRequired={9}</span></td><td class="res">{10}<br><span class="ev">{11}</span></td><td class="ev">{12}</td></tr>' -f `
                        (NEnc $pr.name), (NOr $pr.rg), (NOr $pr.loc), (NOr $pr.prov),
                        (NOr $c.target 'no target'), (NOr $c.provider), (NOr (@($c.groupIds) -join ', ') 'none'),
                        $stTxt, (NEnc $appr), (NOr $c.actions 'not stated'),
                        (NOr $pr.subnet), (NOr $pr.vnet), (NOr (@($pr.ips) -join ', ') 'no IP in the export')))
                }
            }
            [void]$b.Append('</tbody></table>')

            [void]$b.Append('<h3>Chain evidence, hop by hop</h3>')
            $net02Noted = $false
            foreach ($c in $chains) {
                $pe = $c.pe
                [void]$b.Append('<div class="card">')
                [void]$b.Append(('<div><span class="id">{0}</span> <b>{1}</b> <span class="res">{2}</span></div>' -f `
                    (NEnc $pe.name), (NOr (@($pe.gids) -join ', ') 'no group id'), (NOr $pe.id)))
                $hops = @()
                $tgt = ''
                if ($null -ne $c.conn) { $tgt = $c.conn.target + '  (' + $c.conn.provider + ')' }
                $hops += @{ h = 'target resource';            v = $tgt;        ok = ($null -ne $c.conn) }
                $hops += @{ h = 'endpoint connection status'; v = $(if ($null -ne $c.conn) { $c.conn.status } else { '' }); ok = ($null -ne $c.conn -and $c.conn.status -eq 'Approved') }
                $hops += @{ h = 'subnet';                     v = $pe.subnet;  ok = ($pe.subnet -ne '') }
                $hops += @{ h = 'vnet the endpoint sits in';  v = $pe.vnet;    ok = ($pe.vnet -ne '') }
                $zgTxt = @()
                foreach ($zg in $pe.zgs) { $zgTxt += ($zg.group + ' / ' + $zg.cfgName) }
                $hops += @{ h = 'DNS zone group'; v = ($zgTxt -join ', '); ok = (@($pe.zgs).Count -gt 0) }
                foreach ($h in $c.zoneHits) {
                    $hops += @{ h = 'private DNS zone'; v = $h.zg.zoneName; ok = ($null -ne $h.zone) }
                    $lv = 'the zone is not in the export, so its links cannot be read'
                    if ($null -ne $h.zone) {
                        $ln = @()
                        foreach ($l in @($h.zone.links)) { $ln += (NLeaf (NProp (NProp (NProp $l 'properties') 'virtualNetwork') 'id' '')) }
                        $lv = '' + @($h.zone.links).Count + ' link(s): ' + ($ln -join ', ')
                    }
                    $hops += @{ h = "the zone's vnet links"; v = $lv; ok = $h.linked }
                }
                $rn = @()
                foreach ($zg in $pe.zgs) { foreach ($r in $zg.recs) { $rn += $r.name } }
                $hops += @{ h = 'A record(s)'; v = ('' + $pe.recCount + ' of ' + $c.expected + ' expected: ' + ($rn -join ', ')); ok = ($pe.recCount -ge $c.expected -and $pe.recCount -gt 0) }
                $hops += @{ h = 'private IP'; v = (@($pe.ips) -join ', '); ok = (@($pe.ips).Count -gt 0) }
                [void]$b.Append('<table><thead><tr><th>Hop</th><th>Value in the export</th><th>Evidence</th></tr></thead><tbody>')
                foreach ($h in $hops) {
                    $cls = 'nx-gap'; $word = 'missing or not proven'
                    if ($h.ok) { $cls = 'nx-ok'; $word = 'present' }
                    [void]$b.Append(('<tr><td>{0}</td><td class="ev">{1}</td><td><span class="{2}">{3}</span></td></tr>' -f (NEnc $h.h), (NOr $h.v 'not in export'), $cls, $word))
                }
                [void]$b.Append('</tbody></table>')
                if (@($c.issues).Count -gt 0) {
                    [void]$b.Append('<p><b>What this chain does not carry</b></p><ul>')
                    foreach ($iss in $c.issues) { [void]$b.Append('<li>' + (NEnc $iss) + '</li>') }
                    [void]$b.Append('</ul>')
                    if (-not $net02Noted) {
                        $net02Noted = $true
                        [void]$b.Append('<p class="nx-note">The NET-02 check is deliberately loose - it passes when ANY matching-prefix zone in the export has at least one link and at least one A record, without tying that zone to this endpoint&#39;s own vnet or matching the record to the target. The rows above are the exact per-endpoint evidence, so a pass that is not really a pass is visible here. The verdict still belongs to the rule.</p>')
                    }
                } else {
                    [void]$b.Append('<p><span class="nx-ok">Every hop this export can see is present.</span> The two hops it cannot see - the on-premises conditional forwarder, and what a server actually resolves - remain unproven; see <b>Server-side resolution evidence</b> below.</p>')
                }
                if (@($pe.zgs).Count -gt 0) {
                    [void]$b.Append('<h4>DNS zone group record sets</h4>')
                    [void]$b.Append('<table><thead><tr><th>Group / config</th><th>Zone</th><th>Type</th><th>Record set</th><th>FQDN</th><th>TTL</th><th>State</th><th>IP addresses</th></tr></thead><tbody>')
                    foreach ($zg in $pe.zgs) {
                        if (@($zg.recs).Count -eq 0) {
                            [void]$b.Append(('<tr><td>{0}</td><td class="res">{1}</td><td colspan="6"><span class="nx-gap">this zone config carries no record set</span></td></tr>' -f `
                                (NEnc ($zg.group + ' / ' + $zg.cfgName)), (NOr $zg.zoneName)))
                        }
                        foreach ($r in $zg.recs) {
                            [void]$b.Append(('<tr><td>{0}</td><td class="res">{1}</td><td>{2}</td><td class="res">{3}</td><td class="ev">{4}</td><td class="num">{5}</td><td>{6}</td><td class="ev">{7}</td></tr>' -f `
                                (NEnc ($zg.group + ' / ' + $zg.cfgName)), (NOr $zg.zoneName), (NOr $r.type), (NOr $r.name), (NOr $r.fqdn), (NOr $r.ttl '?'), (NOr $r.prov), (NOr (@($r.ips) -join ', ') 'none')))
                        }
                    }
                    [void]$b.Append('</tbody></table>')
                    $expTxt = 'a <code>file</code> endpoint publishes ONE name'
                    if ($pe.isAfs) { $expTxt = 'an <code>Afs</code> endpoint publishes FOUR names - &lt;service&gt;management, &lt;service&gt;syncp, &lt;service&gt;syncs and &lt;service&gt;monitoring, each suffixed with the region' }
                    [void]$b.Append(('<p class="nx-note">Expected shape: {0}. This endpoint publishes <b>{1}</b>. A short count is an incomplete private path even though every object reads Succeeded.</p>' -f $expTxt, $pe.recCount))
                }
                [void]$b.Append('</div>')
            }
        }

        # -------------------------------------------------------------- zones
        [void]$b.Append('<h2>Private DNS zones</h2>')
        if ($zoneRows.Count -eq 0) {
            [void]$b.Append('<div class="card"><p>No private DNS zone in the export. The exporter collects only zones matching <code>privatelink.file.*</code>, <code>privatelink.afs.*</code> or <code>*.privatelink.afs.*</code>, so a blob, vault or SQL privatelink zone is out of frame by design.</p></div>')
        } else {
            [void]$b.Append('<p class="nx-note"><code>numberOfRecordSets</code> counts the SOA record too - an afs zone declaring 5 record sets and returning 4 A records is correct, not a discrepancy. Feeds <span class="nx-rule">NET-02</span>.</p>')
            [void]$b.Append('<table><thead><tr><th>Zone</th><th>Resource group</th><th>Location</th><th>State</th><th>Record sets declared</th><th>A records returned</th><th>VNet links declared</th><th>Links returned</th><th>With registration</th></tr></thead><tbody>')
            foreach ($z in $zoneRows) {
                [void]$b.Append(('<tr><td class="res">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td class="num">{4}</td><td class="num">{5}</td><td class="num">{6}</td><td class="num">{7}</td><td class="num">{8}</td></tr>' -f `
                    (NOr $z.name), (NOr $z.rg), (NOr $z.loc), (NOr $z.prov), (NOr $z.nRs '?'), @($z.arecs).Count, (NOr $z.nVl '?'), @($z.links).Count, (NOr $z.nVlReg '?')))
            }
            [void]$b.Append('</tbody></table>')
            foreach ($z in $zoneRows) {
                [void]$b.Append('<div class="card">')
                [void]$b.Append(('<div><b>{0}</b> <span class="res">{1}</span></div>' -f (NOr $z.name), (NOr $z.id)))
                [void]$b.Append('<h4>VNet links - the list that decides who can resolve the name</h4>')
                if (@($z.links).Count -eq 0) {
                    [void]$b.Append('<p><span class="nx-gap">No virtual network link on this zone.</span> Nothing resolves it; every client falls back to the public IP.</p>')
                } else {
                    [void]$b.Append('<table><thead><tr><th>Link</th><th>Virtual network</th><th>Link state</th><th>Registration enabled</th><th>State</th></tr></thead><tbody>')
                    foreach ($l in $z.links) {
                        $lp = NProp $l 'properties'
                        [void]$b.Append(('<tr><td class="res">{0}</td><td class="res">{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f `
                            (NOr (NProp $l 'name' '')), (NOr (NLeaf (NProp (NProp $lp 'virtualNetwork') 'id' ''))),
                            (NOr (NProp $lp 'virtualNetworkLinkState')), (NYesNo (NProp $lp 'registrationEnabled')), (NOr (NProp $lp 'provisioningState'))))
                    }
                    [void]$b.Append('</tbody></table>')
                }
                [void]$b.Append('<h4>A records</h4>')
                if (@($z.arecs).Count -eq 0) {
                    [void]$b.Append('<p><span class="nx-gap">No A record in this zone.</span> The zone exists but publishes nothing.</p>')
                } else {
                    [void]$b.Append('<table><thead><tr><th>Name</th><th>FQDN</th><th>TTL</th><th>IPv4</th><th>Auto-registered</th><th>Creator - the endpoint that owns the record</th></tr></thead><tbody>')
                    foreach ($ar in $z.arecs) {
                        $ap = NProp $ar 'properties'
                        $ipl = @()
                        foreach ($e in @(NArr (NProp $ap 'aRecords'))) { $ipl += [string](NProp $e 'ipv4Address' '') }
                        $ttl = NProp $ap 'ttl'
                        $ttlNote = ''
                        if ($null -ne $ttl -and [int]$ttl -le 30) { $ttlNote = ' <span class="ev">(short - state it during a cutover)</span>' }
                        [void]$b.Append(('<tr><td class="res">{0}</td><td class="ev">{1}</td><td class="num">{2}{3}</td><td class="ev">{4}</td><td>{5}</td><td class="ev">{6}</td></tr>' -f `
                            (NOr (NProp $ar 'name' '')), (NOr (NProp $ap 'fqdn')), (NOr $ttl '?'), $ttlNote, (NOr ($ipl -join ', ')),
                            (NYesNo (NProp $ap 'isAutoRegistered')), (NOr (NProp (NProp $ap 'metadata') 'creator') 'no creator metadata - hand-made, or orphaned after an endpoint was deleted and recreated')))
                    }
                    [void]$b.Append('</tbody></table>')
                }
                [void]$b.Append('</div>')
            }
        }

        # -------------------------------------------------------------- coverage matrix
        [void]$b.Append('<h2>VNet coverage</h2>')
        [void]$b.Append('<p class="nx-note">A spoke with no link to the privatelink zone resolves the public IP and the storage firewall drops it. That defect is invisible in any per-endpoint view, which is why it is drawn as a matrix. Feeds <span class="nx-rule">NET-02</span>.</p>')
        if ($vnetIdx.Count -eq 0 -or $zoneRows.Count -eq 0) {
            [void]$b.Append('<div class="card"><p>')
            if ($vnetIdx.Count -eq 0) { [void]$b.Append('No virtual network is visible in the export. ') }
            else { [void]$b.Append(('' + $vnetIdx.Count + ' virtual network(s) are visible. ')) }
            if ($zoneRows.Count -eq 0) { [void]$b.Append('No private DNS zone was collected, so there is nothing to cross them with. ') }
            [void]$b.Append('The matrix returns as soon as both a zone and a vnet are in scope.</p></div>')
        } else {
            [void]$b.Append('<table class="mx"><thead><tr><th>Virtual network</th><th>Seen in</th>')
            foreach ($z in $zoneRows) { [void]$b.Append('<th>' + (NOr $z.name) + '</th>') }
            [void]$b.Append('</tr></thead><tbody>')
            foreach ($k in @($vnetIdx.Keys | Sort-Object)) {
                $v = $vnetIdx[$k]
                [void]$b.Append(('<tr><td class="res">{0}</td><td class="ev">{1}</td>' -f (NOr $v.name), (NEnc $v.src)))
                foreach ($z in $zoneRows) {
                    if (NIn $z.vnetIds $v.id) { [void]$b.Append('<td class="y">linked</td>') }
                    else { [void]$b.Append('<td class="n">not linked</td>') }
                }
                [void]$b.Append('</tr>')
            }
            [void]$b.Append('</tbody></table>')
        }

        # -------------------------------------------------------------- vnets
        [void]$b.Append('<h2>Virtual networks</h2>')
        if ($vnets.Count -eq 0) {
            [void]$b.Append('<div class="card"><p>The Resource Graph topology query returned no virtual network')
            if ($topo.Count -gt 0) { [void]$b.Append((' - it returned ' + $topo.Count + ' other row(s)')) }
            [void]$b.Append('. Without a vnet row the address plan, the subnets, the peerings and any custom DNS server cannot be shown, and none of them can be inferred from the endpoint or zone objects.</p></div>')
        } else {
            [void]$b.Append('<p class="nx-note">Custom DNS servers on a vnet override Azure-provided resolution and decide whether the privatelink zone is ever consulted.</p>')
            [void]$b.Append('<table><thead><tr><th>VNet</th><th>Location</th><th>Resource group</th><th>Subscription</th><th>Address space</th><th>DDoS</th><th>Encryption</th><th>DNS servers</th></tr></thead><tbody>')
            foreach ($v in $vnets) {
                $vp = NProp $v 'properties'
                $pref = @()
                foreach ($x in @(NArr (NProp (NProp $vp 'addressSpace') 'addressPrefixes'))) { $pref += [string]$x }
                $encr = NProp $vp 'encryption'
                $encTxt = 'property not present'
                if ($null -ne $encr) { $encTxt = 'enabled=' + [string](NProp $encr 'enabled' '?') + ' enforcement=' + [string](NProp $encr 'enforcement' '?') }
                $dnsSrv = @()
                foreach ($x in @(NArr (NProp (NProp $vp 'dhcpOptions') 'dnsServers'))) { $dnsSrv += [string]$x }
                $dnsTxt = 'Azure-provided (168.63.129.16) - no dhcpOptions.dnsServers on this vnet'
                if ($dnsSrv.Count -gt 0) { $dnsTxt = ($dnsSrv -join ', ') + ' - custom DNS; the privatelink zone is consulted only if these servers forward to Azure DNS' }
                [void]$b.Append(('<tr><td class="res">{0}</td><td>{1}</td><td>{2}</td><td class="ev">{3}</td><td class="ev">{4}</td><td>{5}</td><td class="ev">{6}</td><td class="ev">{7}</td></tr>' -f `
                    (NOr (NProp $v 'name' '')), (NOr (NProp $v 'location')), (NOr (NProp $v 'resourceGroup')), (NOr (NProp $v 'subscriptionId')),
                    (NOr ($pref -join ', ') 'no address space on the row'), (NYesNo (NProp $vp 'enableDdosProtection')), (NEnc $encTxt), (NEnc $dnsTxt)))
            }
            [void]$b.Append('</tbody></table>')
            foreach ($v in $vnets) {
                $vp = NProp $v 'properties'
                $subnets = @(NArr (NProp $vp 'subnets'))
                $peers = @(NArr (NProp $vp 'virtualNetworkPeerings'))
                [void]$b.Append('<div class="card">')
                [void]$b.Append(('<div><b>{0}</b> <span class="res">{1}</span></div>' -f (NOr (NProp $v 'name' '')), (NOr (NProp $v 'id'))))
                [void]$b.Append('<h4>Subnets</h4>')
                if ($subnets.Count -eq 0) {
                    [void]$b.Append('<p><span class="nx-na">This vnet row carries no subnets array.</span> Subnet policies, address headroom and the endpoints each subnet hosts cannot be shown from it.</p>')
                } else {
                    [void]$b.Append('<table><thead><tr><th>Subnet</th><th>Prefix</th><th>PE network policies</th><th>PLS network policies</th><th>Purpose</th><th>Delegation</th><th>ipConfigurations</th><th>Private endpoints hosted</th></tr></thead><tbody>')
                    foreach ($sn in $subnets) {
                        $sp = NProp $sn 'properties'
                        # both shapes occur in real exports: addressPrefix (string) and addressPrefixes (array)
                        $pfx = @()
                        if ($null -ne (NProp $sp 'addressPrefix')) { $pfx += [string](NProp $sp 'addressPrefix') }
                        foreach ($x in @(NArr (NProp $sp 'addressPrefixes'))) { $pfx += [string]$x }
                        $dels = @()
                        foreach ($d in @(NArr (NProp $sp 'delegations'))) { $dels += [string](NProp (NProp $d 'properties') 'serviceName' (NProp $d 'name' '')) }
                        $sPes = @()
                        foreach ($x in @(NArr (NProp $sp 'privateEndpoints'))) { $sPes += (NLeaf (NProp $x 'id' '')) }
                        [void]$b.Append(('<tr><td class="res">{0}</td><td class="ev">{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td class="ev">{5}</td><td class="num">{6}</td><td class="ev">{7}</td></tr>' -f `
                            (NOr (NProp $sn 'name' '')), (NOr ($pfx -join ', ')), (NOr (NProp $sp 'privateEndpointNetworkPolicies')), (NOr (NProp $sp 'privateLinkServiceNetworkPolicies')),
                            (NOr (NProp $sp 'purpose') 'none'), (NOr ($dels -join ', ') 'none'), @(NArr (NProp $sp 'ipConfigurations')).Count, (NOr ($sPes -join ', ') 'none')))
                    }
                    [void]$b.Append('</tbody></table>')
                    [void]$b.Append('<p class="nx-note">Read the ipConfigurations count against the prefix size for headroom. It can legitimately exceed the endpoints listed above, because the export filters private endpoints down to Storage and Storage Sync targets.</p>')
                }
                [void]$b.Append('<h4>Peerings</h4>')
                if ($peers.Count -eq 0) {
                    [void]$b.Append('<p><span class="nx-na">No peering on this vnet.</span> If the endpoints live here and the gateway lives elsewhere, nothing on-premises reaches them through this vnet.</p>')
                } else {
                    [void]$b.Append('<table><thead><tr><th>Peering</th><th>State</th><th>Remote vnet</th><th>allowGatewayTransit</th><th>useRemoteGateways</th></tr></thead><tbody>')
                    foreach ($pz in $peers) {
                        $pzp = NProp $pz 'properties'
                        [void]$b.Append(('<tr><td class="res">{0}</td><td>{1}</td><td class="res">{2}</td><td>{3}</td><td>{4}</td></tr>' -f `
                            (NOr (NProp $pz 'name' '')), (NOr (NProp $pzp 'peeringState')), (NOr (NLeaf (NProp (NProp $pzp 'remoteVirtualNetwork') 'id' ''))),
                            (NYesNo (NProp $pzp 'allowGatewayTransit')), (NYesNo (NProp $pzp 'useRemoteGateways'))))
                    }
                    [void]$b.Append('</tbody></table>')
                }
                [void]$b.Append('</div>')
            }
        }

        # -------------------------------------------------------------- hybrid path
        [void]$b.Append('<h2>Hybrid path</h2>')
        $topoFile = @($files | Where-Object { $_.name -eq 'network/topology.json' })
        $topoCaptured = $true
        if ($topoFile.Count -gt 0 -and -not $topoFile[0].exists) { $topoCaptured = $false }
        if (@($netErrs | Where-Object { (NLc (NProp $_ 'where' '')) -match 'resourcegraph' }).Count -gt 0) { $topoCaptured = $false }
        [void]$b.Append('<p class="nx-note">All nine resource types the topology query asks for. <b>None found</b> means the query ran and the type does not exist in the exported subscriptions; <b>not captured</b> means the query produced no result at all. Feeds <span class="nx-rule">NET-10</span> <span class="nx-rule">NET-11</span>.</p>')
        [void]$b.Append('<table><thead><tr><th>Type</th><th>Rows</th><th>Names</th></tr></thead><tbody>')
        foreach ($tt in $topoTypes) {
            $hitRows = @($topo | Where-Object { (NLc (NProp $_ 'type' '')) -eq $tt.k })
            $cell = '<span class="nx-na">none found</span>'
            if (-not $topoCaptured) { $cell = '<span class="nx-gap">not captured</span>' }
            if ($hitRows.Count -gt 0) {
                $names = @()
                foreach ($r in $hitRows) { $names += [string](NProp $r 'name' '') }
                $cell = (NEnc ($names -join ', '))
            }
            [void]$b.Append(('<tr><td>{0} <span class="ev">{1}</span></td><td class="num">{2}</td><td class="ev">{3}</td></tr>' -f (NEnc $tt.l), (NEnc $tt.k), $hitRows.Count, $cell))
        }
        [void]$b.Append('</tbody></table>')

        if ($resolvers.Count -gt 0) {
            [void]$b.Append('<h3>DNS Private Resolver</h3>')
            [void]$b.Append('<table><thead><tr><th>Resolver</th><th>Location</th><th>Virtual network</th><th>State</th><th>Inbound endpoint IP</th></tr></thead><tbody>')
            foreach ($r in $resolvers) {
                $rp = NProp $r 'properties'
                [void]$b.Append(('<tr><td class="res">{0}</td><td>{1}</td><td class="res">{2}</td><td>{3}</td><td><span class="nx-na">not captured - the inbound endpoint is a child resource and is not in this export</span></td></tr>' -f `
                    (NOr (NProp $r 'name' '')), (NOr (NProp $r 'location')), (NOr (NLeaf (NProp (NProp $rp 'virtualNetwork') 'id' ''))), (NOr (NProp $rp 'dnsResolverState'))))
            }
            [void]$b.Append('</tbody></table>')
            [void]$b.Append('<p class="nx-note">The inbound endpoint IP is the address the on-premises conditional forwarders must point at. Read it from the as-built or the portal - this export cannot produce it.</p>')
        }

        $erRows = @($topo | Where-Object { (NLc (NProp $_ 'type' '')) -match 'expressroutecircuits|virtualnetworkgateways|expressroutegateways|/connections$' })
        if ($erRows.Count -gt 0) {
            [void]$b.Append('<h3>Circuits, gateways and connections</h3>')
            [void]$b.Append('<table><thead><tr><th>Name</th><th>Type</th><th>Location</th><th>Provider / SKU</th><th>State</th><th>Detail</th></tr></thead><tbody>')
            foreach ($r in $erRows) {
                $rp = NProp $r 'properties'
                $spp = NProp $rp 'serviceProviderProperties'
                if ($null -ne $spp) {
                    $prov = [string](NProp $spp 'serviceProviderName' '') + ' / ' + [string](NProp $spp 'peeringLocation' '') + ' / ' + [string](NProp $spp 'bandwidthInMbps' '') + ' Mbps'
                } else {
                    $prov = ([string](NProp (NProp $r 'sku') 'name' '') + ' ' + [string](NProp $rp 'gatewayType' '')).Trim()
                }
                $state = ([string](NProp $rp 'circuitProvisioningState' '') + ' ' + [string](NProp $rp 'serviceProviderProvisioningState' '') + ' ' + [string](NProp $rp 'connectionStatus' '')).Trim()
                $det = @()
                foreach ($pg in @(NArr (NProp $rp 'peerings'))) { $det += [string](NProp $pg 'name' '') }
                if ($null -ne (NProp $rp 'connectionType')) { $det += ('connectionType=' + [string](NProp $rp 'connectionType' '')) }
                [void]$b.Append(('<tr><td class="res">{0}</td><td class="ev">{1}</td><td>{2}</td><td class="ev">{3}</td><td>{4}</td><td class="ev">{5}</td></tr>' -f `
                    (NOr (NProp $r 'name' '')), (NOr (NProp $r 'type')), (NOr (NProp $r 'location')), (NOr $prov 'not stated'), (NOr $state 'not stated'), (NOr ($det -join ', ') 'none')))
            }
            [void]$b.Append('</tbody></table>')
        }

        # -------------------------------------------------------------- reverse index
        [void]$b.Append('<h2>Endpoints referenced by a resource</h2>')
        if ($refs.Count -eq 0) {
            [void]$b.Append('<div class="card"><p>No storage account and no Storage Sync Service in this export declares a private endpoint connection, which is consistent with an estate that has none.</p></div>')
        } else {
            [void]$b.Append('<p class="nx-note">Every <code>privateEndpointConnections[].properties.privateEndpoint.id</code> on a storage account, and every id in a Storage Sync Service connection file, checked case-insensitively against the ids in network/privateendpoints.json. A reference with no matching endpoint means the endpoint lives outside the exported subscriptions or the Network list call did not return it - never that the connection itself is broken. Feeds <span class="nx-rule">NET-03</span> <span class="nx-rule">NET-05</span> <span class="nx-rule">NET-06</span>.</p>')
            [void]$b.Append('<table><thead><tr><th>Declared by</th><th>Connection</th><th>Private endpoint</th><th>Status</th><th>In network/privateendpoints.json</th></tr></thead><tbody>')
            foreach ($r in $refs) {
                $kn = '<span class="nx-ok">yes</span>'
                if (-not $r.known) { $kn = '<span class="nx-gap">no - out of scope or not captured</span>' }
                [void]$b.Append(('<tr><td>{0}</td><td class="res">{1}</td><td class="res">{2}</td><td>{3}</td><td>{4}</td></tr>' -f `
                    (NEnc $r.from), (NOr $r.conn), (NOr $r.peName 'no id on the connection'), (NOr $r.status 'not stated'), $kn))
            }
            [void]$b.Append('</tbody></table>')
        }

        # -------------------------------------------------------------- public path
        [void]$b.Append('<h2>Public path (evidence only)</h2>')
        [void]$b.Append('<p class="nx-note">These are the fields that turn "an endpoint exists" into "traffic actually goes private". The judgement lives on the Storage and File Sync tabs and in <span class="nx-rule">NET-07</span> <span class="nx-rule">NET-08</span> <span class="nx-rule">AFS-11</span> <span class="nx-rule">AFS-14</span> <span class="nx-rule">SEC-03</span> <span class="nx-rule">SEC-05</span>; it is not restated here.</p>')
        if ($syncs.Count -gt 0) {
            [void]$b.Append('<table><thead><tr><th>Storage Sync Service</th><th>incomingTrafficPolicy</th><th>Private endpoint connections</th><th>Connection statuses</th></tr></thead><tbody>')
            foreach ($s in $syncs) {
                $sp = NProp $s.svc 'properties'
                $stats = @()
                foreach ($c in @($s.pec)) { $stats += [string](NProp (NProp (NProp $c 'properties') 'privateLinkServiceConnectionState') 'status' '') }
                foreach ($c in @(NArr (NProp $sp 'privateEndpointConnections'))) { $stats += [string](NProp (NProp (NProp $c 'properties') 'privateLinkServiceConnectionState') 'status' '') }
                [void]$b.Append(('<tr><td class="res">{0}</td><td>{1}</td><td class="num">{2}</td><td class="ev">{3}</td></tr>' -f `
                    (NOr (NProp $s.svc 'name' $s.dir)), (NOr (NProp $sp 'incomingTrafficPolicy') 'not set'), @($s.pec).Count, (NOr ($stats -join ', ') 'none')))
            }
            [void]$b.Append('</tbody></table>')
        }
        if ($accounts.Count -gt 0) {
            [void]$b.Append('<table><thead><tr><th>Storage account</th><th>publicNetworkAccess</th><th>defaultAction</th><th>bypass</th><th>ipRules</th><th>vnetRules</th><th>ipv6Rules</th><th>resourceAccessRules</th></tr></thead><tbody>')
            foreach ($a in $accounts) {
                $ap = NProp $a 'properties'
                $acl = NProp $ap 'networkAcls'
                $pna = NProp $ap 'publicNetworkAccess'
                $pnaTxt = '<span class="nx-na">not set - behaves as Enabled, never as Disabled</span>'
                if ($null -ne $pna) { $pnaTxt = NEnc $pna }
                $rar = '<span class="nx-na">field absent</span>'
                if (NHas $acl 'resourceAccessRules') { $rar = [string]@(NArr (NProp $acl 'resourceAccessRules')).Count }
                $ipv6 = '<span class="nx-na">field absent</span>'
                if (NHas $acl 'ipv6Rules') { $ipv6 = [string]@(NArr (NProp $acl 'ipv6Rules')).Count }
                $ipList = @()
                foreach ($r in @(NArr (NProp $acl 'ipRules'))) { $ipList += ([string](NProp $r 'value' '') + ' ' + [string](NProp $r 'action' '')).Trim() }
                $ipTxt = [string]@(NArr (NProp $acl 'ipRules')).Count
                if ($ipList.Count -gt 0) { $ipTxt = $ipTxt + ' (' + ($ipList -join '; ') + ')' }
                [void]$b.Append(('<tr><td class="res">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td class="ev">{4}</td><td class="num">{5}</td><td class="num">{6}</td><td class="num">{7}</td></tr>' -f `
                    (NOr (NProp $a 'name' '')), $pnaTxt, (NOr (NProp $acl 'defaultAction') 'not set'), (NOr (NProp $acl 'bypass') 'none'),
                    (NEnc $ipTxt), @(NArr (NProp $acl 'virtualNetworkRules')).Count, $ipv6, $rar))
            }
            [void]$b.Append('</tbody></table>')
        }
        if ($syncs.Count -eq 0 -and $accounts.Count -eq 0) {
            [void]$b.Append('<div class="card"><p>The export holds no storage account and no Storage Sync Service, so the public path cannot be described either.</p></div>')
        }

        # -------------------------------------------------------------- server-side evidence
        [void]$b.Append('<h2>Server-side resolution evidence</h2>')
        [void]$b.Append('<p class="nx-note">The bundles show which DNS servers each registered server uses, but their own DNS tests probe only <code>management.azure.com</code> and <code>login.microsoftonline.com</code> - never the storage or <code>*.afs.azure.net</code> names. <b>This export therefore cannot prove that a server resolves the private IP.</b> The commands that would: <code>Debug-StorageSyncServer -TestNetworkConnectivity</code> on the server, or <code>Resolve-DnsName &lt;account&gt;.file.core.windows.net</code> and <code>Resolve-DnsName &lt;service&gt;syncp.&lt;region&gt;.afs.azure.net</code>, compared against the private IPs above.</p>')
        if ($servers.Count -eq 0) {
            [void]$b.Append('<div class="card"><p>No server bundle in this export, so server-side resolution cannot be evidenced at all. Collect one per registered server with <code>Get-AfsServerDiagnostics.ps1</code>.</p></div>')
        } else {
            [void]$b.Append('<table><thead><tr><th>Server</th><th>Bundle</th><th>Interface</th><th>IPv4</th><th>DNS servers in use</th><th>Gateway</th></tr></thead><tbody>')
            foreach ($s in $servers) {
                if (@($s.ipcfg).Count -eq 0) {
                    [void]$b.Append(('<tr><td class="res">{0}</td><td class="ev">{1}</td><td colspan="4"><span class="nx-na">network.json carried an empty ipConfiguration - Get-NetIPConfiguration returned nothing on that server</span></td></tr>' -f (NEnc $s.host), (NEnc $s.bundle)))
                }
                foreach ($ic in @($s.ipcfg)) {
                    $v4 = @(); foreach ($x in @(NArr (NProp $ic 'IPv4'))) { $v4 += [string]$x }
                    $dn = @(); foreach ($x in @(NArr (NProp $ic 'DNS'))) { $dn += [string]$x }
                    $gw = @(); foreach ($x in @(NArr (NProp $ic 'Gateway'))) { $gw += [string]$x }
                    [void]$b.Append(('<tr><td class="res">{0}</td><td class="ev">{1}</td><td>{2}</td><td class="ev">{3}</td><td class="ev">{4}</td><td class="ev">{5}</td></tr>' -f `
                        (NEnc $s.host), (NEnc $s.bundle), (NOr (NProp $ic 'InterfaceAlias')), (NOr ($v4 -join ', ')), (NOr ($dn -join ', ') 'none reported'), (NOr ($gw -join ', ') 'none')))
                }
            }
            [void]$b.Append('</tbody></table>')
            [void]$b.Append('<table><thead><tr><th>Server</th><th>DNS tests recorded in the bundle</th><th>Debug-StorageSyncServer -TestNetworkConnectivity</th></tr></thead><tbody>')
            foreach ($s in $servers) {
                $dt = @()
                foreach ($t in @($s.dns)) { $dt += ([string](NProp $t 'name' '') + ' -> ' + [string](NProp $t 'address' (NProp $t 'nameHost' '?'))) }
                $dbgTxt = 'not collected'
                if ($s.debug -ne '') { $dbgTxt = NTrunc $s.debug 800 }
                [void]$b.Append(('<tr><td class="res">{0}</td><td class="ev">{1}</td><td><span class="nx-pre">{2}</span></td></tr>' -f `
                    (NEnc $s.host), (NOr ($dt -join '; ') 'none - the bundle recorded no DNS test'), (NEnc $dbgTxt)))
            }
            [void]$b.Append('</tbody></table>')
        }

        # -------------------------------------------------------------- export integrity
        [void]$b.Append('<h2>Export integrity</h2>')
        if ($netErrs.Count -eq 0) {
            [void]$b.Append('<div class="card"><p>errors.json carries no row for <code>privateDnsZones:&lt;sub&gt;</code>, <code>vnetLinks:&lt;zone&gt;</code>, <code>aRecords:&lt;zone&gt;</code>, <code>privateEndpoints:&lt;sub&gt;</code>, <code>dnsZoneGroups:&lt;pe&gt;</code> or <code>resourceGraph:topology</code>. Everything absent above is absent because it does not exist in the exported subscriptions, not because a call failed.</p></div>')
        } else {
            [void]$b.Append('<p class="nx-note">An object absent because its collection failed must never be read as "not configured". These rows are the difference.</p>')
            [void]$b.Append('<table><thead><tr><th>Where</th><th>When (UTC)</th><th>Detail</th></tr></thead><tbody>')
            foreach ($e in $netErrs) {
                [void]$b.Append(('<tr><td class="res">{0}</td><td class="ev">{1}</td><td><span class="nx-pre">{2}</span></td></tr>' -f `
                    (NOr (NProp $e 'where' '')), (NOr (NProp $e 'at')), (NEnc (NTrunc (NProp $e 'detail' '') 1500))))
            }
            [void]$b.Append('</tbody></table>')
        }

        # -------------------------------------------------------------- scope
        [void]$b.Append('<h2>Scope of this tab</h2><div class="card"><div class="kv">')
        $subTxt = @()
        foreach ($s in $subs) { $subTxt += ([string](NProp $s 'name' '?') + ' (' + [string](NProp $s 'id' '?') + ')') }
        [void]$b.Append('<div class="k">Subscriptions exported</div><div class="ev">' + (NOr ($subTxt -join '; ') 'not stated in manifest.json') + '</div>')
        [void]$b.Append('<div class="k">Zone filter the exporter applies</div><div><code>privatelink.file.*</code>, <code>privatelink.afs.*</code> and <code>*.privatelink.afs.*</code> only. A blob, Key Vault or SQL privatelink zone is out of frame by design, not missing.</div>')
        [void]$b.Append('<div class="k">Endpoint filter the exporter applies</div><div>Only endpoints whose target is <code>Microsoft.Storage/storageAccounts</code> or <code>Microsoft.StorageSync/storageSyncServices</code>. An Azure Migrate cache endpoint, or a hub endpoint in a connectivity subscription, is out of frame by design.</div>')
        [void]$b.Append('<div class="k">Never captured at all</div><div>NSGs, route tables, NIC objects, DNS Private Resolver inbound-endpoint IPs, forwarding-ruleset rules (all child resources) and on-premises DNS forwarders. Their absence is a property of the export, not of the estate.</div>')
        [void]$b.Append('<div class="k">Rules this evidence feeds</div><div>')
        foreach ($rid in @('NET-01', 'NET-02', 'NET-03', 'NET-04', 'NET-05', 'NET-06', 'NET-07', 'NET-08', 'NET-09', 'NET-10', 'NET-11', 'AFS-11', 'AFS-14', 'SEC-03', 'SEC-05')) {
            [void]$b.Append('<span class="nx-rule">' + $rid + '</span> ')
        }
        [void]$b.Append('<br><span class="ev">Each verdict, its severity and its recommendation are on the Findings tab. This tab carries only the evidence they were made from.</span></div>')
        [void]$b.Append('</div></div>')
    } catch {
        $why = [System.Net.WebUtility]::HtmlEncode([string]$_.Exception.Message)
        [void]$b.Append('<div class="card"><p>The rest of this tab could not be built from the export: <code>' + $why + '</code></p>')
        [void]$b.Append('<p>Everything above this point is complete, and the rest of the report is unaffected. The raw files are <code>network/privateendpoints.json</code>, <code>network/privatednszones.json</code> and <code>network/topology.json</code> in the export.</p></div>')
    }

    [void]$Sb.Append('<section class="tab" id="tab-network">')
    [void]$Sb.Append($b.ToString())
    [void]$Sb.Append('</section>')
}
