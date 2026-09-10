function Add-AfsTabServers {
    <#
      The Servers tab: the on-premises half of the assessment.

      Findings say what is wrong; this tab says what was measured. It renders the cloud
      registration roster (registeredservers.json) joined to whatever server-side bundles
      Get-AfsServerDiagnostics.ps1 produced, then, per bundle, every file the collector
      writes - including the ones no rule reads (debug-filesyncerrors.txt, winhttp-proxy.txt,
      smbshares.json, registry-storagesync.json, defender, Windows Search scopes,
      events-operational.json, the bundle's own errors.json, the tiered census).

      Three things this tab exists to make visible and nothing else does:
        - a server registered in Azure with no bundle has NO server-side evidence at all,
        - a bundle with no registration raises no rule anywhere,
        - a bundle collected without elevation is silently empty, which reads as health.
    #>
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
          [string]$ExportRoot)

    # ---------------------------------------------------------------------------------
    # Nested helpers: scoped to this function, so a sibling subject tab can define its
    # own without either shadowing the other. Every one of them is total - it returns a
    # value for null, a missing file, a zero-byte file and malformed JSON alike.
    # ---------------------------------------------------------------------------------
    function SrvEnc { param($v) if ($null -eq $v) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$v) }

    function SrvProp {
        param($Obj, [string]$Name, $Default = $null)
        if ($null -eq $Obj) { return $Default }
        $p = $null
        try { $p = $Obj.PSObject.Properties[$Name] } catch { return $Default }
        if ($p -and $null -ne $p.Value) { return $p.Value }
        return $Default
    }
    function SrvText {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $t = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        if ($null -eq $t) { return '' }
        return ([string]$t).TrimStart([char]0xFEFF)
    }
    # Mirrors the assessor's Load-Json: an empty, whitespace-only or literal-"null" file is
    # "no rows", not corruption. The real Landing_Zone export ships 20+ zero-byte JSON files,
    # registeredservers.json among them, and a naive JSON.parse throws on exactly those.
    function SrvJson {
        param([string]$Path)
        $t = SrvText $Path
        if ([string]::IsNullOrWhiteSpace($t)) { return $null }
        if ($t.Trim() -eq 'null') { return $null }
        try { return ($t | ConvertFrom-Json) } catch { return $null }
    }
    function SrvList { param([string]$Path) $o = SrvJson $Path; if ($null -eq $o) { return ,@() } return ,@($o) }

    # Invariant-culture number formatting. An SVG coordinate written with a comma decimal
    # separator (de-DE, fr-FR) silently destroys the diagram, so nothing formats implicitly.
    function SrvNum {
        param($v, [string]$Fmt = '0.##')
        $d = 0.0
        try { $d = [double]$v } catch { return '0' }
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return '0' }
        return ([string]::Format([cultureinfo]::InvariantCulture, ('{0:' + $Fmt + '}'), $d))
    }
    function SrvLabel { param($n) $s = [string]$n; if (-not $s) { return '' } return ($s -split '\.')[0] }
    function SrvSlug { param($n) $s = [string]$n; if (-not $s) { return 'x' } return ($s -replace '[^A-Za-z0-9]', '') }
    function SrvDate {
        param($s)
        if (-not $s) { return $null }
        try { return [datetime]::Parse([string]$s, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { return $null }
    }
    function SrvSpan {
        param($Minutes)
        $m = 0.0
        try { $m = [math]::Abs([double]$Minutes) } catch { return '?' }
        if ($m -lt 90) { return ('{0} min' -f [int][math]::Round($m)) }
        if ($m -lt 2880) { return ('{0} h {1} min' -f [int][math]::Floor($m / 60), [int][math]::Round($m % 60)) }
        return ('{0} d {1} h' -f [int][math]::Floor($m / 1440), [int][math]::Floor(($m % 1440) / 60))
    }
    # HRESULTs in sync-session-digest.json are STRINGS and are decimal-negative or 0x form
    # depending on the agent's message format. Both are rendered, with the Win32 code.
    function SrvHresult {
        param($H, $Win32)
        $s = ([string]$H).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return 'not parsed' }
        $v = $null
        try {
            if ($s -match '^0[xX][0-9a-fA-F]{1,8}$') { $v = [int64][Convert]::ToInt64($s.Substring(2), 16) }
            elseif ($s -match '^-?\d+$') { $v = [int64]$s }
        } catch { $v = $null }
        if ($null -eq $v) { return ($s + ' (unrecognised form)') }
        # Decimal masks on purpose: PowerShell reads 0xFFFF0000 as a NEGATIVE Int32, which
        # silently breaks every -band here and swallows the Win32 name.
        $u = $v
        if ($u -lt 0) { $u = $u + 4294967296 }
        $u = $u -band 4294967295
        $signed = $u
        if ($signed -gt 2147483647) { $signed = $signed - 4294967296 }
        $out = ('{0} = 0x{1:X8}' -f $signed, [uint32]$u)
        if (($u -band 4294901760) -eq 2147942400) {
            $w = [int]($u -band 65535)
            $n = $null
            if ($Win32 -and $Win32.ContainsKey($w)) { $n = $Win32[$w] }
            if ($n) { $out = ('{0} = {1} ({2})' -f $out, $n, $w) } else { $out = ('{0} = Win32 {1}' -f $out, $w) }
        }
        return $out
    }
    # Verbatim command output, line by line, with the SRV-08 trigger highlighted where it
    # actually matched - a reader must see WHICH line tripped /\b(fail|error)\b/i.
    function SrvPre {
        param([string]$Body, [switch]$Highlight)
        if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
        $g = New-Object System.Text.StringBuilder
        [void]$g.Append('<pre class="raw">')
        foreach ($ln in (($Body.TrimEnd()) -split "`r?`n")) {
            $e = SrvEnc $ln
            if ($Highlight -and ($ln -match '(?i)\b(fail|error)\b')) { [void]$g.Append('<mark>' + $e + '</mark>') } else { [void]$g.Append($e) }
            [void]$g.Append("`n")
        }
        [void]$g.Append('</pre>')
        return $g.ToString()
    }
    # Endpoints whose cloud serverName/friendlyName has the same first DNS label as a host.
    function SrvEndpointsFor {
        param([string]$Label, $All)
        $out = @()
        if (-not $Label) { return ,@() }
        foreach ($e in @($All)) {
            $p = SrvProp $e.obj 'properties'
            $n = [string](SrvProp $p 'serverName' '')
            if (-not $n) { $n = [string](SrvProp $p 'friendlyName' '') }
            if ((SrvLabel $n) -ieq $Label) { $out += $e }
        }
        return ,@($out)
    }

    $win32 = @{ 2 = 'ERROR_FILE_NOT_FOUND'; 3 = 'ERROR_PATH_NOT_FOUND'; 5 = 'ERROR_ACCESS_DENIED'; 8 = 'ERROR_NOT_ENOUGH_MEMORY';
        32 = 'ERROR_SHARING_VIOLATION'; 33 = 'ERROR_LOCK_VIOLATION'; 53 = 'ERROR_BAD_NETPATH'; 59 = 'ERROR_UNEXP_NET_ERR';
        67 = 'ERROR_BAD_NET_NAME'; 87 = 'ERROR_INVALID_PARAMETER'; 112 = 'ERROR_DISK_FULL'; 121 = 'ERROR_SEM_TIMEOUT';
        234 = 'ERROR_MORE_DATA'; 1223 = 'ERROR_CANCELLED'; 1450 = 'ERROR_NO_SYSTEM_RESOURCES'; 1460 = 'ERROR_TIMEOUT' }
    $evtMeaning = @{ '9003' = 'cloud tiering'; '9005' = 'recall'; '9006' = 'recall'; '9009' = 'recall'; '9016' = 'cloud tiering';
        '9029' = 'cloud tiering'; '9059' = 'recall'; '9071' = 'recall'; '9102' = 'sync session'; '9121' = 'per-item errors';
        '9301' = 'heartbeat'; '9302' = 'sync progress' }
    $svcStatusName = @{ '1' = 'Stopped'; '2' = 'StartPending'; '3' = 'StopPending'; '4' = 'Running'; '5' = 'ContinuePending'; '6' = 'PausePending'; '7' = 'Paused' }
    $svcStartName = @{ '0' = 'Boot'; '1' = 'System'; '2' = 'Automatic'; '3' = 'Manual'; '4' = 'Disabled' }
    $skipped = 'SRV-01 service and filter drivers, SRV-02 backup/AV on a tiered endpoint, SRV-03 volume headroom against the tiering policy, SRV-04 Windows Search / DFS-R, SRV-05 clock skew, SRV-06 failing sync sessions, SRV-07 self-service restore, SRV-08 Debug-StorageSyncServer, SRV-09 NTFS cluster size, SRV-10 agent version drift, SRV-11 dedup on a tiered volume'

    $x = New-Object System.Text.StringBuilder
    [void]$x.Append('<section class="tab" id="tab-servers">')
    [void]$x.Append(@'
<style>
#tab-servers .tiles{grid-template-columns:repeat(3,1fr)}
#tab-servers pre.raw{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px;line-height:1.45;background:var(--surface-3);border:1px solid var(--line);border-radius:6px;padding:8px 10px;margin:6px 0 10px;white-space:pre-wrap;word-break:break-word;overflow-x:auto}
#tab-servers pre.raw mark{background:var(--crit-soft);color:var(--crit);font-weight:600;padding:0 2px;border-radius:2px}
#tab-servers .svgwrap{overflow-x:auto;background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin:6px 0}
#tab-servers .lg{display:flex;flex-wrap:wrap;gap:16px;font-size:12px;color:var(--muted);margin:8px 2px 2px}
#tab-servers .lg i{display:inline-block;width:20px;height:9px;border-radius:2px;vertical-align:middle;margin-right:6px;border:1px solid var(--line)}
#tab-servers .chip{display:inline-block;font-size:11px;padding:1px 8px;border-radius:20px;border:1px solid var(--line);background:var(--surface-3);color:var(--muted);margin:0 4px 3px 0;white-space:nowrap}
#tab-servers .chip.rule{font-family:"IBM Plex Mono",Consolas,monospace;color:var(--accent);background:var(--info-soft);border-color:#d3e0ec}
#tab-servers .chip.warn{background:var(--warn-soft);color:var(--warn);border-color:#eedcae}
#tab-servers .chip.ok{background:var(--good-soft);color:var(--good);border-color:#c4e3d1}
#tab-servers .note{color:var(--muted);font-size:12.5px;margin:4px 0 10px}
#tab-servers .srvhead{border-bottom:1px solid var(--line);padding-bottom:9px;margin:0 0 12px}
#tab-servers .srvhead h3{margin:0 0 4px;font-size:15px}
#tab-servers tr.ghost td,#tab-servers .ghost{color:var(--faint)}
#tab-servers table.tight th,#tab-servers table.tight td{padding:6px 9px;font-size:12.5px}
#tab-servers .mono{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px}
#tab-servers h4{color:var(--muted);text-transform:uppercase;letter-spacing:.05em;font-size:11px;margin:18px 0 4px;font-weight:700}
#tab-servers .grid2{display:grid;grid-template-columns:1fr 1fr;gap:0 22px;align-items:start}
@media(max-width:900px){#tab-servers .tiles{grid-template-columns:1fr}#tab-servers .grid2{grid-template-columns:1fr}}
</style>
'@)
    [void]$x.Append('<h2>Servers</h2>')
    [void]$x.Append('<p class="note">The on-premises file servers: what they are, what the volumes hold, and what the Storage Sync agent reported. This tab is the <b>evidence</b> - the measurements the SRV findings were computed from, plus everything the collector gathered that no rule reads. The verdicts are on the Findings tab.</p>')

    try {
        if (-not ($ExportRoot -and (Test-Path -LiteralPath $ExportRoot))) {
            [void]$x.Append('<div class="card"><p>No export folder was supplied to the renderer, so nothing on-premises can be shown here. Re-run the assessor pointing at the export directory to populate this tab.</p></div></section>')
            [void]$Sb.Append($x.ToString())
            return
        }

        # ---- manifest: the clock every server-vs-cloud comparison is skewed against ------
        $manifest = SrvJson (Join-Path $ExportRoot 'manifest.json')
        $exportedRaw = [string](SrvProp $manifest 'exportedAtUtc' '')
        $exportedAt = SrvDate $exportedRaw

        # ---- cloud half: registered servers + server endpoints --------------------------
        $cloudServers = @(); $cloudEndpoints = @(); $svcNames = @()
        $regFilesSeen = 0; $regFilesEmpty = 0
        $ssRoot = Join-Path $ExportRoot 'storagesync'
        $ssRootPresent = (Test-Path -LiteralPath $ssRoot)
        if ($ssRootPresent) {
            foreach ($d in @(Get-ChildItem -LiteralPath $ssRoot -Directory -ErrorAction SilentlyContinue)) {
                $svcName = $d.Name
                if ($svcName -match '__') { $svcName = ($svcName -split '__', 2)[1] }
                $svcNames += $svcName
                $rp = Join-Path $d.FullName 'registeredservers.json'
                if (Test-Path -LiteralPath $rp) {
                    $regFilesSeen++
                    $rt = SrvText $rp
                    if ([string]::IsNullOrWhiteSpace($rt) -or $rt.Trim() -eq 'null') { $regFilesEmpty++ }
                }
                foreach ($r in (SrvList $rp)) { $cloudServers += [pscustomobject]@{ svc = $svcName; obj = $r } }
                foreach ($e in (SrvList (Join-Path $d.FullName 'serverendpoints.json'))) { $cloudEndpoints += [pscustomobject]@{ svc = $svcName; obj = $e } }
            }
        }
        # inventory.json still names the sync services when their folders came back empty.
        $inventory = SrvJson (Join-Path $ExportRoot 'inventory.json')
        foreach ($s in @(SrvProp $inventory 'storageSyncServices' @())) {
            $n = [string](SrvProp $s 'name' '')
            if ($n -and ($svcNames -notcontains $n)) { $svcNames += $n }
        }

        # ---- server half: bundles -------------------------------------------------------
        # Layout is three-way and all three must work: servers/<HOST>/<HOST>-afs-server-<stamp>/*.json,
        # servers/<HOST>/system.json directly, or servers/<HOST>/<name>.zip expanded in place.
        $bundles = @(); $emptyHostDirs = @(); $pendingZips = @()
        $serversRoot = Join-Path $ExportRoot 'servers'
        $serversDirPresent = (Test-Path -LiteralPath $serversRoot)
        if ($serversDirPresent) {
            foreach ($hd in @(Get-ChildItem -LiteralPath $serversRoot -Directory -ErrorAction SilentlyContinue)) {
                $zips = @()
                try { $zips = @(Get-ChildItem -LiteralPath $hd.FullName -Filter '*.zip' -ErrorAction SilentlyContinue) } catch { $zips = @() }
                $sysFiles = @()
                try { $sysFiles = @(Get-ChildItem -LiteralPath $hd.FullName -Filter 'system.json' -Recurse -ErrorAction SilentlyContinue) } catch { $sysFiles = @() }
                foreach ($z in $zips) {
                    $expanded = Join-Path $hd.FullName ([System.IO.Path]::GetFileNameWithoutExtension($z.Name))
                    if (-not (Test-Path -LiteralPath $expanded)) { $pendingZips += [pscustomobject]@{ hostDir = $hd.Name; zip = $z.Name } }
                }
                $cand = @()
                foreach ($sf in $sysFiles) {
                    $sysObj = SrvJson $sf.FullName
                    if ($null -eq $sysObj) { continue }
                    $bd0 = Split-Path -Parent $sf.FullName
                    $raw = [string](SrvProp $sysObj 'collectedAtUtc' '')
                    $cand += [pscustomobject]@{
                        dir = $bd0; name = (Split-Path -Leaf $bd0); system = $sysObj
                        hostname = [string](SrvProp $sysObj 'hostname' $hd.Name)
                        collectedRaw = $raw; collected = (SrvDate $raw)
                    }
                }
                if ($cand.Count -eq 0) { $emptyHostDirs += [pscustomobject]@{ hostDir = $hd.Name; zips = $zips.Count }; continue }
                # The assessor takes the FIRST system.json a recursive search returns - a coin
                # flip when a host carries several timestamped bundles. Render the newest by
                # collectedAtUtc and disclose the rest rather than inheriting that.
                $ordered = @($cand | Sort-Object -Property @{ Expression = { if ($_.collected) { $_.collected } else { [datetime]::MinValue } } } -Descending)
                $pri = $ordered[0]
                $others = @()
                if ($ordered.Count -gt 1) { $others = @($ordered[1..($ordered.Count - 1)]) }
                $bd = $pri.dir
                $bundles += [pscustomobject]@{
                    hostDir = $hd.Name; dir = $bd; bundleName = $pri.name; hostname = $pri.hostname
                    collectedRaw = $pri.collectedRaw; collected = $pri.collected; system = $pri.system
                    services    = (SrvJson (Join-Path $bd 'services.json'))
                    volumes     = (SrvJson (Join-Path $bd 'volumes.json'))
                    programs    = (SrvJson (Join-Path $bd 'programs.json'))
                    network     = (SrvJson (Join-Path $bd 'network.json'))
                    shares      = (SrvList (Join-Path $bd 'smbshares.json'))
                    ssr         = (SrvList (Join-Path $bd 'selfservicerestore.json'))
                    digest      = (SrvList (Join-Path $bd 'sync-session-digest.json'))
                    telemetry   = (SrvList (Join-Path $bd 'events-telemetry.json'))
                    operational = (SrvList (Join-Path $bd 'events-operational.json'))
                    registry    = (SrvList (Join-Path $bd 'registry-storagesync.json'))
                    errors      = (SrvList (Join-Path $bd 'errors.json'))
                    census      = (SrvList (Join-Path $bd 'tiered-census.json'))
                    fltmc       = (SrvText (Join-Path $bd 'fltmc.txt'))
                    w32tm       = (SrvText (Join-Path $bd 'w32tm.txt'))
                    proxy       = (SrvText (Join-Path $bd 'winhttp-proxy.txt'))
                    diagnose    = (SrvText (Join-Path $bd 'debug-diagnose.txt'))
                    netdbg      = (SrvText (Join-Path $bd 'debug-network.txt'))
                    syncerr     = (SrvText (Join-Path $bd 'debug-filesyncerrors.txt'))
                    afsdiag     = (SrvText (Join-Path $bd 'afsdiag-run.txt'))
                    censusFile  = (Test-Path -LiteralPath (Join-Path $bd 'tiered-census.json'))
                    afsdiagDir  = (Test-Path -LiteralPath (Join-Path $bd 'afsdiag'))
                    others = $others; zips = $zips.Count
                }
            }
        }

        # ---- the join: first DNS label, case-insensitive. NEVER the FQDN ----------------
        # The fixture proves why: the cloud records FS01.contoso.local while the bundle's own
        # domain is corp.contoso.com. Both directions can miss; only one of them raises a rule.
        $bundleByHost = @{}
        foreach ($b in $bundles) {
            $k = ([string]$b.hostname).ToLower()
            if ($k -and -not $bundleByHost.ContainsKey($k)) { $bundleByHost[$k] = $b }
        }
        $roster = @()
        foreach ($cs in $cloudServers) {
            $p = SrvProp $cs.obj 'properties'
            $fn = [string](SrvProp $p 'friendlyName' '')
            $sn = [string](SrvProp $p 'serverName' '')
            $src = $fn
            if (-not $src) { $src = $sn }
            $lab = SrvLabel $src
            if (-not $lab) { $lab = [string](SrvProp $cs.obj 'name' '') }
            $key = $lab.ToLower()
            $bm = $null
            if ($key -and $bundleByHost.ContainsKey($key)) { $bm = $bundleByHost[$key] }
            $roster += [pscustomobject]@{ svc = $cs.svc; label = $lab; key = $key; props = $p; bundle = $bm }
        }
        $matchedKeys = @{}
        foreach ($r in $roster) { if ($r.bundle) { $matchedKeys[$r.key] = $true } }
        $orphanBundles = @($bundles | Where-Object { -not $matchedKeys.ContainsKey(([string]$_.hostname).ToLower()) })
        $cMatched = @($roster | Where-Object { $_.bundle }).Count
        $cNoBundle = @($roster | Where-Object { -not $_.bundle }).Count
        $cOrphan = $orphanBundles.Count

        # ---- empty state 2: nothing registered anywhere and nothing collected -----------
        # This is "no Azure File Sync servers in scope", not "evidence missing". Say so and
        # suppress the coverage counters, the join map and the remedy entirely - otherwise
        # the report nags about a gap that cannot exist.
        if (($roster.Count -eq 0) -and ($bundles.Count -eq 0) -and ($pendingZips.Count -eq 0) -and ($emptyHostDirs.Count -eq 0)) {
            [void]$x.Append('<div class="card"><p><b>No Azure File Sync servers are in scope, so there is no on-premises evidence to show.</b></p>')
            if (-not $ssRootPresent) {
                [void]$x.Append('<p>The export has no <code>storagesync/</code> folder: no Storage Sync Service, and therefore no registered server, was found in the subscriptions that were exported.</p>')
            } elseif ($regFilesSeen -gt 0 -and $regFilesEmpty -eq $regFilesSeen) {
                [void]$x.Append('<p>All ' + $regFilesEmpty + ' <code>registeredservers.json</code> file(s) in this export are empty or zero bytes across ' + $svcNames.Count + ' Storage Sync Service(s), which is exactly what the exporter writes for an empty list. The services exist; no server has been registered to them.</p>')
            } else {
                [void]$x.Append('<p>The ' + $svcNames.Count + ' Storage Sync Service(s) in this export returned no registered server.</p>')
            }
            [void]$x.Append('<p>Nothing is missing and nothing needs collecting: with no registered server there is no agent, no cache volume and no server endpoint to measure. The eleven SRV checks and the OPS-03 coverage check have nothing to evaluate.</p></div>')
            [void]$x.Append('</section>')
            [void]$Sb.Append($x.ToString())
            return
        }

        # ---------------------------------------------------------------------------------
        # SECONDARY DIAGRAM - the join map. Why some servers carry no server-side evidence.
        # ---------------------------------------------------------------------------------
        $rows = @()
        foreach ($r in $roster) {
            $bn = ''
            if ($r.bundle) { $bn = [string]$r.bundle.hostname }
            $kind = 'nobundle'
            if ($r.bundle) { $kind = 'match' }
            $rows += [pscustomobject]@{ left = $r.label; right = $bn; kind = $kind }
        }
        foreach ($b in $orphanBundles) { $rows += [pscustomobject]@{ left = ''; right = [string]$b.hostname; kind = 'orphan' } }
        $shown = @($rows | Select-Object -First 14)
        $jRowH = 30
        $jTop = 44
        $jh = $jTop + ([math]::Max(1, $shown.Count) * $jRowH) + 26
        [void]$x.Append('<div class="svgwrap"><svg viewBox="0 0 760 ' + $jh + '" width="100%" height="' + $jh + '" role="img" aria-label="Join map between the servers registered in Azure and the diagnostic bundles collected on-premises">')
        [void]$x.Append('<title>Cloud registration joined to collected bundle, by first DNS label</title>')
        [void]$x.Append('<text x="12" y="18" font-size="11" font-weight="700" fill="currentColor" opacity=".65">REGISTERED IN AZURE</text>')
        [void]$x.Append('<text x="360" y="18" font-size="11" font-weight="700" fill="currentColor" opacity=".65">COLLECTED BUNDLE</text>')
        [void]$x.Append('<text x="12" y="32" font-size="10" fill="currentColor" opacity=".5">storagesync/&lt;svc&gt;/registeredservers.json</text>')
        [void]$x.Append('<text x="360" y="32" font-size="10" fill="currentColor" opacity=".5">servers/&lt;HOST&gt;/&hellip;/system.json</text>')
        if ($shown.Count -eq 0) {
            [void]$x.Append('<text x="12" y="' + ($jTop + 16) + '" font-size="12" fill="currentColor" opacity=".55">Nothing registered in Azure and nothing collected on-premises - there is no join to draw.</text>')
        }
        $jy = $jTop
        foreach ($rw in $shown) {
            $cy = $jy + 13
            if ($rw.kind -eq 'orphan') {
                [void]$x.Append('<rect x="12" y="' + $jy + '" width="200" height="26" rx="5" fill="none" stroke="var(--faint)" stroke-width="1" stroke-dasharray="4 3"/>')
                [void]$x.Append('<text x="24" y="' + ($cy + 4) + '" font-size="11.5" fill="var(--faint)">not registered</text>')
            } else {
                [void]$x.Append('<rect x="12" y="' + $jy + '" width="200" height="26" rx="5" fill="var(--info-soft)" stroke="var(--line)"/>')
                [void]$x.Append('<text x="24" y="' + ($cy + 4) + '" font-size="12" font-weight="600" fill="var(--ink)">' + (SrvEnc $rw.left) + '</text>')
            }
            if ($rw.kind -eq 'nobundle') {
                [void]$x.Append('<line x1="214" y1="' + $cy + '" x2="356" y2="' + $cy + '" stroke="var(--faint)" stroke-width="1.5" stroke-dasharray="5 4"/>')
                [void]$x.Append('<rect x="358" y="' + $jy + '" width="180" height="26" rx="5" fill="none" stroke="var(--faint)" stroke-dasharray="4 3"/>')
                [void]$x.Append('<text x="370" y="' + ($cy + 4) + '" font-size="11.5" fill="var(--faint)">no bundle</text>')
                [void]$x.Append('<text x="548" y="' + ($cy + 4) + '" font-size="10.5" fill="var(--faint)">OPS-03 - SRV-01..SRV-11 skipped</text>')
            } else {
                [void]$x.Append('<line x1="214" y1="' + $cy + '" x2="356" y2="' + $cy + '" stroke="var(--accent)" stroke-width="2"/>')
                [void]$x.Append('<rect x="358" y="' + $jy + '" width="180" height="26" rx="5" fill="var(--good-soft)" stroke="var(--line)"/>')
                [void]$x.Append('<text x="370" y="' + ($cy + 4) + '" font-size="12" font-weight="600" fill="var(--ink)">' + (SrvEnc $rw.right) + '</text>')
                if ($rw.kind -eq 'orphan') { [void]$x.Append('<text x="548" y="' + ($cy + 4) + '" font-size="10.5" fill="var(--faint)">no rule fires in either direction</text>') }
                else { [void]$x.Append('<text x="548" y="' + ($cy + 4) + '" font-size="10.5" fill="var(--good)">measured on the server</text>') }
            }
            $jy = $jy + $jRowH
        }
        [void]$x.Append('<text x="12" y="' + ($jy + 16) + '" font-size="10.5" fill="currentColor" opacity=".55">join rule: friendlyName (fallback serverName) split on &quot;.&quot; element 0, compared case-insensitively to system.json hostname</text>')
        [void]$x.Append('</svg></div>')
        if ($rows.Count -gt $shown.Count) { [void]$x.Append('<p class="note">' + ($rows.Count - $shown.Count) + ' further row(s) omitted from the diagram; every one of them is in the roster table below.</p>') }

        # ---------------------------------------------------------------------------------
        # COVERAGE HEADER
        # ---------------------------------------------------------------------------------
        [void]$x.Append('<div class="tiles">')
        [void]$x.Append('<div class="tile"><div class="n">' + $cMatched + '</div><div class="l">Registered + bundle</div></div>')
        [void]$x.Append('<div class="tile info"><div class="n">' + $cNoBundle + '</div><div class="l">Registered, no bundle</div></div>')
        [void]$x.Append('<div class="tile info"><div class="n">' + $cOrphan + '</div><div class="l">Bundle, no registration</div></div>')
        [void]$x.Append('</div>')
        [void]$x.Append('<p class="note">A registered server with no bundle is reported once as <span class="chip rule">OPS-03</span> and the eleven SRV checks are simply not evaluated for it. A bundle with no matching registration raises <b>nothing anywhere</b> - an orphaned or decommissioned server surfaces only on this tab.</p>')
        if ($exportedRaw) { [void]$x.Append('<p class="note">The cloud side was exported <span class="mono">' + (SrvEnc $exportedRaw) + '</span>. Bundles are collected separately, by hand, and are frequently days older; each server card states its own skew against that clock.</p>') }

        # ---------------------------------------------------------------------------------
        # ROSTER - substantive from cloud data alone, which is the normal case
        # ---------------------------------------------------------------------------------
        [void]$x.Append('<h3>Registered servers</h3>')
        if ($roster.Count -eq 0) {
            if (-not $ssRootPresent) {
                [void]$x.Append('<div class="card"><p><b>No Azure File Sync servers are in scope.</b> The export has no <code>storagesync/</code> folder, so no Storage Sync Service - and therefore no registered server - was found. There is nothing to collect on-premises and nothing to remediate here.</p></div>')
            } elseif ($regFilesSeen -gt 0 -and $regFilesEmpty -eq $regFilesSeen) {
                [void]$x.Append('<div class="card"><p><b>No Azure File Sync servers are in scope.</b> All ' + $regFilesEmpty + ' <code>registeredservers.json</code> file(s) in the export are empty or zero bytes, which is what the exporter writes for an empty list. That is an empty estate, not missing evidence - so no server bundle is expected and none is asked for.</p></div>')
            } else {
                [void]$x.Append('<div class="card"><p>No registered servers were returned for the ' + $svcNames.Count + ' Storage Sync Service(s) named in this export.</p></div>')
            }
        } else {
            [void]$x.Append('<table class="tight"><thead><tr><th>Server</th><th>Service</th><th>Server name (cloud)</th><th>Agent</th><th>Version status</th><th>Expires</th><th>Server OS</th><th>Last heartbeat</th><th>Role / cluster</th><th>Auth</th><th>Server-side evidence</th></tr></thead><tbody>')
            foreach ($r in ($roster | Sort-Object label)) {
                $p = $r.props
                $cls = ''
                $ev = 'no server-side evidence'
                if ($r.bundle) {
                    $ev = 'bundle <span class="mono">' + (SrvEnc $r.bundle.bundleName) + '</span>'
                    if ($r.bundle.collectedRaw) { $ev = $ev + '<br><span class="mono">' + (SrvEnc $r.bundle.collectedRaw) + '</span>' }
                } else { $cls = ' class="ghost"' }
                [void]$x.Append('<tr' + $cls + '>')
                [void]$x.Append('<td><b>' + (SrvEnc $r.label) + '</b></td>')
                [void]$x.Append('<td>' + (SrvEnc $r.svc) + '</td>')
                [void]$x.Append('<td class="mono">' + (SrvEnc (SrvProp $p 'serverName' '-')) + '</td>')
                [void]$x.Append('<td class="mono">' + (SrvEnc (SrvProp $p 'agentVersion' '-')) + '</td>')
                [void]$x.Append('<td>' + (SrvEnc (SrvProp $p 'agentVersionStatus' '-')) + '</td>')
                [void]$x.Append('<td class="mono">' + (SrvEnc (SrvProp $p 'agentVersionExpirationDate' '-')) + '</td>')
                [void]$x.Append('<td class="mono">' + (SrvEnc (SrvProp $p 'serverOSVersion' '-')) + '</td>')
                [void]$x.Append('<td class="mono">' + (SrvEnc (SrvProp $p 'lastHeartBeat' '-')) + '</td>')
                $role = [string](SrvProp $p 'serverRole' '-')
                $cn = [string](SrvProp $p 'clusterName' '')
                if ($cn) { $role = $role + ' / ' + $cn }
                [void]$x.Append('<td>' + (SrvEnc $role) + '</td>')
                [void]$x.Append('<td>' + (SrvEnc (SrvProp $p 'activeAuthType' '-')) + '</td>')
                [void]$x.Append('<td>' + $ev + '</td>')
                [void]$x.Append('</tr>')
            }
            [void]$x.Append('</tbody></table>')
            [void]$x.Append('<p class="note">The exporter redacts <code>serverCertificate</code> and this report never renders it. The only certificate signal available on this tab is the Debug-StorageSyncServer diagnose text of a collected bundle.</p>')
        }

        # ---- the remedy, stated once, and only where a gap can actually exist ------------
        if ($cNoBundle -gt 0) {
            $why = 'Some hosts were collected and some were not.'
            if (-not $serversDirPresent) { $why = 'The export has no <code>servers/</code> folder at all, which is the normal case - <code>Export-AzFileSyncEnvironment.ps1</code> never writes one. Server collection is a separate, manual, per-server step.' }
            [void]$x.Append('<div class="card"><p><b>' + $cNoBundle + ' registered server(s) have no diagnostic bundle in this export.</b> ' + $why + ' These checks were therefore not evaluated for them: ' + (SrvEnc $skipped) + '.</p>')
            [void]$x.Append('<p>To close the gap, on each server, from an elevated PowerShell:</p>')
            [void]$x.Append((SrvPre @'
.\Get-AfsServerDiagnostics.ps1 -OutputPath C:\temp
# then copy  <host>-afs-server-<stamp>.zip  into the export as
#   servers\<hostname>\<host>-afs-server-<stamp>.zip
# and re-run the assessor against the export folder.
'@))
            [void]$x.Append('<p class="note">The collection is read-only. It reads service, volume and share state, the File Sync event logs, installed programs and the agent registry keys; it reads no file content, no keys, no SAS tokens and no certificates.</p></div>')
        }

        if ($pendingZips.Count -gt 0) {
            [void]$x.Append('<div class="card"><p><b>Unexpanded bundle archive(s).</b> These zips sit under <code>servers/</code> with no expanded folder beside them, so their contents are not rendered anywhere in this report:</p><ul>')
            foreach ($z in $pendingZips) { [void]$x.Append('<li class="mono">servers\' + (SrvEnc $z.hostDir) + '\' + (SrvEnc $z.zip) + '</li>') }
            [void]$x.Append('</ul><p class="note">Expand each one in place - the assessor does this automatically on its next run - and re-render.</p></div>')
        }
        if ($emptyHostDirs.Count -gt 0) {
            $names = @()
            foreach ($h in $emptyHostDirs) { $names += (SrvEnc $h.hostDir) }
            [void]$x.Append('<div class="card"><p><b>Host folder(s) under <code>servers/</code> with no readable <code>system.json</code>:</b> ' + ($names -join ', ') + '. Either a collection that failed before its first step, or an archive that was never expanded.</p></div>')
        }

        # ---------------------------------------------------------------------------------
        # PER-BUNDLE EVIDENCE
        # ---------------------------------------------------------------------------------
        [void]$x.Append('<h2>Collected server bundles (' + $bundles.Count + ')</h2>')
        if ($bundles.Count -eq 0 -and $roster.Count -gt 0) {
            [void]$x.Append('<p class="note">None. Everything above this line comes from the Azure control plane; nothing below it could be measured on a server.</p>')
        }

        $bi = 0
        foreach ($b in $bundles) {
            $bi++
            $hostn = [string]$b.hostname
            $slug = (SrvSlug $hostn) + $bi
            $sys = $b.system
            $myEps = SrvEndpointsFor $hostn $cloudEndpoints
            $tieredEps = @($myEps | Where-Object { ([string](SrvProp (SrvProp $_.obj 'properties') 'cloudTiering' 'off')) -ieq 'on' })
            $reg = $null
            foreach ($r in $roster) { if ($r.bundle -and (([string]$r.bundle.hostname) -ieq $hostn)) { $reg = $r; break } }
            $rp = $null
            if ($reg) { $rp = $reg.props }

            [void]$x.Append('<div class="card">')
            [void]$x.Append('<div class="srvhead"><h3>' + (SrvEnc $hostn) + '</h3>')
            [void]$x.Append('<div class="note" style="margin:0">bundle <span class="mono">' + (SrvEnc $b.bundleName) + '</span> under <span class="mono">servers\' + (SrvEnc $b.hostDir) + '</span>')
            if ($reg) { [void]$x.Append(' &ndash; joined to registered server <b>' + (SrvEnc $reg.label) + '</b> in ' + (SrvEnc $reg.svc)) }
            else { [void]$x.Append(' &ndash; <b>no matching registration</b> in any Storage Sync Service in this export, and no rule reports that') }
            [void]$x.Append('</div></div>')

            # ---- evidence confidence: absence of evidence must not read as health --------
            $elev = SrvProp $sys 'elevated' $null
            $bErrs = @($b.errors)
            [void]$x.Append('<h4>Evidence confidence</h4><div>')
            if ($elev -eq $true) { [void]$x.Append('<span class="chip ok">elevated collection</span>') }
            elseif ($elev -eq $false) { [void]$x.Append('<span class="chip warn">NOT elevated</span>') }
            else { [void]$x.Append('<span class="chip">elevation not reported</span>') }
            [void]$x.Append('<span class="chip">collector v' + (SrvEnc (SrvProp $sys 'toolVersion' '?')) + '</span>')
            if ($bErrs.Count -eq 0) { [void]$x.Append('<span class="chip ok">errors.json empty</span>') }
            else { [void]$x.Append('<span class="chip warn">' + $bErrs.Count + ' collection error(s)</span>') }
            if ($b.censusFile) { [void]$x.Append('<span class="chip">tiered census present</span>') } else { [void]$x.Append('<span class="chip">no -SampleTieredFiles</span>') }
            if ($b.afsdiagDir -or $b.afsdiag) { [void]$x.Append('<span class="chip">AFSDiag present</span>') } else { [void]$x.Append('<span class="chip">no -CollectAfsDiag</span>') }
            [void]$x.Append('</div>')
            if ($elev -eq $false) {
                [void]$x.Append('<p class="note"><b>Read every clean result below as unproven.</b> A non-elevated collection silently returns nothing for <code>fltmc</code>, for both event logs and for all three <code>debug-*.txt</code> files. The sync-session digest is then empty, so SRV-06 cannot fire and SRV-08 cannot fire. This server can look green because it was never measured.</p>')
            }
            $missingWhy = @()
            if ((-not $b.diagnose) -and (-not $b.netdbg) -and (@($b.ssr).Count -eq 0)) { $missingWhy += 'no <code>debug-*.txt</code> and no <code>selfservicerestore.json</code> usually means the agent DLL was not at <code>C:\Program Files\Azure\StorageSyncAgent</code> - the bundle''s errors.json records that as <span class="mono">where=servercmdlets</span>' }
            if (-not $b.fltmc) { $missingWhy += '<code>fltmc.txt</code> is empty, which typically means the collection was not elevated' }
            if ($missingWhy.Count -gt 0) { [void]$x.Append('<p class="note">' + ($missingWhy -join '; ') + '.</p>') }
            if ($bErrs.Count -gt 0) {
                [void]$x.Append('<table class="tight"><thead><tr><th>Where</th><th>Detail</th></tr></thead><tbody>')
                foreach ($er in $bErrs) { [void]$x.Append('<tr><td class="mono">' + (SrvEnc (SrvProp $er 'where' '-')) + '</td><td>' + (SrvEnc (SrvProp $er 'detail' '-')) + '</td></tr>') }
                [void]$x.Append('</tbody></table>')
            }
            if (@($b.others).Count -gt 0) {
                $onames = @()
                foreach ($o in @($b.others)) { $onames += ((SrvEnc $o.name) + ' (' + (SrvEnc $o.collectedRaw) + ')') }
                [void]$x.Append('<p class="note"><b>' + @($b.others).Count + ' older bundle(s) also present under this host</b> and not rendered: ' + ($onames -join ', ') + '. The assessor reads whichever <code>system.json</code> a recursive search returns first, which is effectively arbitrary; this report reads the newest by <code>collectedAtUtc</code>.</p>')
            }

            # ---- time skew ---------------------------------------------------------------
            [void]$x.Append('<h4>The clock this evidence was taken on</h4><div class="card kv" style="margin-top:0">')
            [void]$x.Append('<div class="k">Bundle collected (UTC)</div><div class="mono">' + (SrvEnc (SrvProp $sys 'collectedAtUtc' 'not reported')) + '</div>')
            $expShow = 'not reported'
            if ($exportedRaw) { $expShow = $exportedRaw }
            [void]$x.Append('<div class="k">Cloud export (UTC)</div><div class="mono">' + (SrvEnc $expShow) + '</div>')
            if ($exportedAt -and $b.collected) {
                $mins = ($exportedAt - $b.collected).TotalMinutes
                $dir = 'older than'
                if ($mins -lt 0) { $dir = 'newer than' }
                [void]$x.Append('<div class="k">Skew</div><div>' + (SrvEnc (SrvSpan $mins)) + ' - the bundle is ' + $dir + ' the cloud export. Every server-versus-cloud number below (agent version, measured free space against <code>cloudTieringStatus</code>) is only meaningful with that gap in view.</div>')
            } else {
                [void]$x.Append('<div class="k">Skew</div><div class="ghost">Not computable - one of the two timestamps is missing.</div>')
            }
            [void]$x.Append('</div>')

            # ---- identity ------------------------------------------------------------------
            [void]$x.Append('<h4>Identity and platform</h4><div class="grid2"><div class="card kv" style="margin-top:0">')
            [void]$x.Append('<div class="k">Hostname (server)</div><div class="mono">' + (SrvEnc (SrvProp $sys 'hostname' '-')) + '</div>')
            $domTxt = 'not reported'
            if ((SrvProp $sys 'domain' '')) { $domTxt = (SrvEnc (SrvProp $sys 'domain' '')) + ' &middot; partOfDomain=' + (SrvEnc (SrvProp $sys 'partOfDomain' 'not reported')) }
            [void]$x.Append('<div class="k">Domain (server)</div><div class="mono">' + $domTxt + '</div>')
            [void]$x.Append('<div class="k">Operating system</div><div>' + (SrvEnc (SrvProp $sys 'osCaption' '-')) + '</div>')
            [void]$x.Append('<div class="k">Version / build</div><div class="mono">' + (SrvEnc (SrvProp $sys 'osVersion' '-')) + ' / ' + (SrvEnc (SrvProp $sys 'osBuild' '-')) + '</div>')
            $clu = SrvProp $sys 'cluster'
            $cluTxt = 'standalone - no cluster reported'
            if ($clu) { $cluTxt = [string](SrvProp $clu 'Name' '?') + ' in ' + [string](SrvProp $clu 'Domain' '?') }
            [void]$x.Append('<div class="k">Cluster</div><div>' + (SrvEnc $cluTxt) + '</div>')
            # These fields are always written by the collector but absent from the sample
            # fixture, so the degraded path is the one that gets exercised locally.
            $hwBits = @()
            $mk = ([string](SrvProp $sys 'manufacturer' '') + ' ' + [string](SrvProp $sys 'model' '')).Trim()
            if ($mk) { $hwBits += $mk }
            if ($null -ne (SrvProp $sys 'totalMemoryGiB' $null)) { $hwBits += ((SrvEnc (SrvProp $sys 'totalMemoryGiB' '')) + ' GiB RAM') }
            if ($null -ne (SrvProp $sys 'logicalProcessors' $null)) { $hwBits += ((SrvEnc (SrvProp $sys 'logicalProcessors' '')) + ' logical CPUs') }
            $hwTxt = 'not in this bundle'
            if ($hwBits.Count -gt 0) { $hwTxt = ($hwBits -join ' &middot; ') }
            [void]$x.Append('<div class="k">Hardware</div><div>' + $hwTxt + '</div>')
            $upBits = @()
            if ((SrvProp $sys 'lastBoot' '')) { $upBits += ('booted ' + (SrvEnc (SrvProp $sys 'lastBoot' ''))) }
            if ((SrvProp $sys 'installDate' '')) { $upBits += ('installed ' + (SrvEnc (SrvProp $sys 'installDate' ''))) }
            $upTxt = 'not in this bundle'
            if ($upBits.Count -gt 0) { $upTxt = ($upBits -join ' &middot; ') }
            [void]$x.Append('<div class="k">Boot / install date</div><div class="mono">' + $upTxt + '</div>')
            $dnr = [string](SrvProp $sys 'dotNetRelease' '')
            $dnrTxt = '-'
            if ($dnr) { $dnrTxt = $dnr; if ($dnr -eq '528372') { $dnrTxt = $dnr + ' (.NET Framework 4.8)' } }
            [void]$x.Append('<div class="k">.NET release</div><div class="mono">' + (SrvEnc $dnrTxt) + '</div>')
            [void]$x.Append('</div><div class="card kv" style="margin-top:0">')
            if ($rp) {
                [void]$x.Append('<div class="k">Server name (cloud)</div><div class="mono">' + (SrvEnc (SrvProp $rp 'serverName' '-')) + '</div>')
                [void]$x.Append('<div class="k">Friendly name (cloud)</div><div class="mono">' + (SrvEnc (SrvProp $rp 'friendlyName' '-')) + '</div>')
                [void]$x.Append('<div class="k">Server OS (cloud)</div><div class="mono">' + (SrvEnc (SrvProp $rp 'serverOSVersion' '-')) + '</div>')
                $ccn = [string](SrvProp $rp 'clusterName' '')
                if (-not $ccn) { $ccn = 'no cluster' }
                [void]$x.Append('<div class="k">Role / cluster (cloud)</div><div>' + (SrvEnc (SrvProp $rp 'serverRole' '-')) + ' / ' + (SrvEnc $ccn) + '</div>')
                [void]$x.Append('<div class="k">Last heartbeat</div><div class="mono">' + (SrvEnc (SrvProp $rp 'lastHeartBeat' '-')) + '</div>')
                [void]$x.Append('<div class="k">Active auth type</div><div>' + (SrvEnc (SrvProp $rp 'activeAuthType' '-')) + '</div>')
                [void]$x.Append('<div class="k">Management error code</div><div class="mono">' + (SrvEnc (SrvProp $rp 'serverManagementErrorCode' '-')) + '</div>')
                $sd = [string](SrvProp $sys 'domain' '')
                $cnm = [string](SrvProp $rp 'serverName' '')
                if ($sd -and $cnm -and ($cnm -notmatch [regex]::Escape($sd))) {
                    [void]$x.Append('<div class="k">Domain agreement</div><div>The cloud records <span class="mono">' + (SrvEnc $cnm) + '</span> while the server reports domain <span class="mono">' + (SrvEnc $sd) + '</span>. That disagreement is exactly why the join is on the first DNS label and never on the FQDN.</div>')
                }
            } else {
                [void]$x.Append('<div class="k">Cloud registration</div><div class="ghost">None found. Nothing in the Azure control plane in this export claims this hostname, so the cloud column is blank for every comparison below.</div>')
            }
            [void]$x.Append('</div></div>')

            # ---- agent ---------------------------------------------------------------------
            $ap = SrvProp $sys 'agentProduct'
            $localVer = [string](SrvProp $sys 'agentFileVersion' '')
            if (-not $localVer) { $localVer = [string](SrvProp $ap 'DisplayVersion' '') }
            $cloudVer = ''
            if ($rp) { $cloudVer = [string](SrvProp $rp 'agentVersion' '') }
            [void]$x.Append('<h4>Storage Sync agent</h4><div class="card kv" style="margin-top:0">')
            $prodTxt = 'not found in the uninstall registry'
            if ($ap) { $prodTxt = (SrvEnc (SrvProp $ap 'DisplayName' 'unnamed product')) + ' <span class="mono">' + (SrvEnc (SrvProp $ap 'DisplayVersion' '-')) + '</span>' }
            [void]$x.Append('<div class="k">Installed product</div><div>' + $prodTxt + '</div>')
            $lvShow = 'not read'
            if ($localVer) { $lvShow = $localVer }
            [void]$x.Append('<div class="k">FileSyncSvc.exe version</div><div class="mono">' + (SrvEnc $lvShow) + '</div>')
            $cvShow = 'no registration to compare against'
            if ($cloudVer) { $cvShow = $cloudVer }
            [void]$x.Append('<div class="k">Registered version (cloud)</div><div class="mono">' + (SrvEnc $cvShow) + '</div>')
            if ($localVer -and $cloudVer) {
                if ($localVer -eq $cloudVer) {
                    [void]$x.Append('<div class="k">Agreement</div><div>Server and registration agree, so <span class="chip rule">SRV-10</span> stays silent.</div>')
                } else {
                    [void]$x.Append('<div class="k">Agreement</div><div><b>They differ</b>: server <span class="mono">' + (SrvEnc $localVer) + '</span> against registered <span class="mono">' + (SrvEnc $cloudVer) + '</span>. That pair is the whole of <span class="chip rule">SRV-10</span>''s evidence.</div>')
                }
            }
            if ($rp) {
                [void]$x.Append('<div class="k">Version status (cloud)</div><div>' + (SrvEnc (SrvProp $rp 'agentVersionStatus' '-')) + ', expires <span class="mono">' + (SrvEnc (SrvProp $rp 'agentVersionExpirationDate' '-')) + '</span></div>')
            }
            [void]$x.Append('<div class="k">Auto-update policy</div><div class="mono">' + (SrvEnc (SrvProp (SrvProp $sys 'agentAutoUpdate') 'AutoUpdatePolicy' 'not reported')) + '</div>')
            [void]$x.Append('</div>')

            # ---------------------------------------------------------------------------
            # PRIMARY DIAGRAM - volume headroom against the policy each endpoint enforces
            # ---------------------------------------------------------------------------
            $vols = @(SrvProp $b.volumes 'volumes' @())
            $descs = @()
            [void]$x.Append('<h4>Volume headroom against the cloud tiering policy</h4>')
            if ($vols.Count -eq 0) {
                [void]$x.Append('<p class="note">The bundle carries no volume list in <code>volumes.json</code>, so there is nothing to plot. Headroom, cluster size and deduplication are all unmeasured on this server.</p>')
            } else {
                $barX = 128.0; $barW = 690.0; $svgW = 980.0
                $yy = 44.0
                foreach ($v in $vols) {
                    $drv = [string](SrvProp $v 'drive' '')
                    $dkey = $drv.ToUpper()
                    $eps = @()
                    foreach ($e in $myEps) {
                        $ep = SrvProp $e.obj 'properties'
                        $lp = [string](SrvProp $ep 'serverLocalPath' '')
                        if ($lp.Length -ge 2 -and $dkey -and $lp.Substring(0, 2).ToUpper() -eq $dkey) { $eps += $e }
                    }
                    $sz = [double](SrvProp $v 'sizeGiB' 0)
                    $fg = [double](SrvProp $v 'freeGiB' 0)
                    $fp = SrvProp $v 'freePercent' $null
                    if (($null -eq $fp) -and $sz -gt 0) { $fp = 100.0 * $fg / $sz }
                    $chips = @()
                    $cl = SrvProp $v 'bytesPerCluster' $null
                    if ($cl -and ([int]$cl) -ge 65536) { $chips += ([string][int](([int]$cl) / 1024) + ' KiB clusters') }
                    foreach ($dv in @(SrvProp $b.volumes 'dedup' @())) {
                        if ((([string](SrvProp $dv 'Volume' '')).ToUpper() -eq $dkey) -and ((SrvProp $dv 'Enabled' $false) -eq $true)) {
                            $chips += ('dedup, MinFileAge ' + [string](SrvProp $dv 'MinimumFileAgeDays' '?') + ' d')
                        }
                    }
                    if ($eps.Count -eq 0) { $chips += 'no server endpoint on this volume' }
                    $head = [math]::Max(1, $eps.Count)
                    $barTop = $yy + 6 + ($head * 13)
                    $h = 6 + ($head * 13) + 22 + 20
                    $descs += [pscustomobject]@{ v = $v; drive = $drv; eps = $eps; size = $sz; freeGiB = $fg; freePct = $fp; chips = $chips; barTop = $barTop; top = $yy }
                    $yy = $yy + $h
                }
                $svgH = $yy + 10
                [void]$x.Append('<div class="svgwrap"><svg viewBox="0 0 ' + (SrvNum $svgW) + ' ' + (SrvNum $svgH) + '" width="100%" height="' + (SrvNum $svgH) + '" role="img" aria-label="Per-volume capacity, measured free space and the cloud tiering free-space policy of each server endpoint on ' + (SrvEnc $hostn) + '">')
                [void]$x.Append('<title>' + (SrvEnc $hostn) + ' - volume headroom against the tiering free-space policy of each server endpoint</title>')
                [void]$x.Append('<defs><pattern id="afsHatch' + $slug + '" width="7" height="7" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="7" stroke="var(--crit)" stroke-width="2.4" opacity=".26"/></pattern></defs>')
                [void]$x.Append('<text x="8" y="18" font-size="10.5" font-weight="700" fill="currentColor" opacity=".6">FREE %, MEASURED FROM THE RIGHT EDGE</text>')
                foreach ($pc in @(0, 10, 20, 30, 40, 50)) {
                    $ax = $barX + $barW * (1.0 - ($pc / 100.0))
                    [void]$x.Append('<line x1="' + (SrvNum $ax) + '" y1="26" x2="' + (SrvNum $ax) + '" y2="32" stroke="currentColor" opacity=".3"/>')
                    [void]$x.Append('<text x="' + (SrvNum $ax) + '" y="22" font-size="9.5" text-anchor="middle" fill="currentColor" opacity=".5">' + $pc + '%</text>')
                }
                foreach ($d in $descs) {
                    $bt = $d.barTop
                    if ($d.eps.Count -eq 0) {
                        [void]$x.Append('<text x="' + (SrvNum $barX) + '" y="' + (SrvNum ($d.top + 14)) + '" font-size="10" fill="currentColor" opacity=".45">no server endpoint on this volume, so no tiering policy applies to it</text>')
                    }
                    $maxBand = 0.0
                    $li = 0
                    foreach ($e in $d.eps) {
                        $ep = SrvProp $e.obj 'properties'
                        $nm = [string](SrvProp $e.obj 'name' '?')
                        $lp = [string](SrvProp $ep 'serverLocalPath' '')
                        $pol = [double](SrvProp $ep 'volumeFreeSpacePercent' 20)
                        $tier = [string](SrvProp $ep 'cloudTiering' 'off')
                        $days = [string](SrvProp $ep 'tierFilesOlderThanDays' '-')
                        $cts = SrvProp $ep 'cloudTieringStatus'
                        $vfsp = SrvProp $cts 'volumeFreeSpacePolicyStatus'
                        $cloudFree = SrvProp $vfsp 'currentVolumeFreeSpacePercent' $null
                        $effPol = SrvProp $vfsp 'effectiveVolumeFreeSpacePolicy' $null
                        $txt = $nm + '   ' + $lp + '   tiering ' + $tier + '   policy ' + (SrvNum $pol) + '%'
                        if (($null -ne $effPol) -and ((SrvNum $effPol) -ne (SrvNum $pol))) { $txt = $txt + ' (effective ' + (SrvNum $effPol) + '%)' }
                        $txt = $txt + '   date policy ' + $days + ' d'
                        if ($null -ne $cloudFree) { $txt = $txt + '   cloud reports ' + (SrvNum $cloudFree) + '% free' }
                        [void]$x.Append('<text x="' + (SrvNum $barX) + '" y="' + (SrvNum ($d.top + 14 + ($li * 13))) + '" font-size="10" fill="currentColor" opacity=".72">' + (SrvEnc $txt) + '</text>')
                        if ($tier -ieq 'on') { $maxBand = [math]::Max($maxBand, ($pol + 5.0)) }
                        $li++
                    }
                    [void]$x.Append('<rect x="' + (SrvNum $barX) + '" y="' + (SrvNum $bt) + '" width="' + (SrvNum $barW) + '" height="20" rx="3" fill="var(--surface-3)" stroke="var(--line)"/>')
                    if ($maxBand -gt 0) {
                        $bw = $barW * ([math]::Min(100.0, $maxBand) / 100.0)
                        [void]$x.Append('<rect x="' + (SrvNum ($barX + $barW - $bw)) + '" y="' + (SrvNum $bt) + '" width="' + (SrvNum $bw) + '" height="20" fill="url(#afsHatch' + $slug + ')"/>')
                    }
                    if (($null -ne $d.freePct) -and ($d.size -gt 0)) {
                        $usedFrac = (100.0 - [double]$d.freePct) / 100.0
                        if ($usedFrac -lt 0) { $usedFrac = 0.0 }
                        if ($usedFrac -gt 1) { $usedFrac = 1.0 }
                        $uw = $barW * $usedFrac
                        $op = '.55'
                        if ($d.eps.Count -eq 0) { $op = '.22' }
                        [void]$x.Append('<rect x="' + (SrvNum $barX) + '" y="' + (SrvNum $bt) + '" width="' + (SrvNum $uw) + '" height="20" rx="3" fill="var(--accent)" opacity="' + $op + '"/>')
                        [void]$x.Append('<line x1="' + (SrvNum ($barX + $uw)) + '" y1="' + (SrvNum ($bt - 3)) + '" x2="' + (SrvNum ($barX + $uw)) + '" y2="' + (SrvNum ($bt + 23)) + '" stroke="var(--ink)" stroke-width="1.4"/>')
                    }
                    foreach ($e in $d.eps) {
                        $ep = SrvProp $e.obj 'properties'
                        $pol = [double](SrvProp $ep 'volumeFreeSpacePercent' 20)
                        $tx = $barX + $barW * (1.0 - ([math]::Min(100.0, $pol) / 100.0))
                        [void]$x.Append('<line x1="' + (SrvNum $tx) + '" y1="' + (SrvNum ($bt - 5)) + '" x2="' + (SrvNum $tx) + '" y2="' + (SrvNum ($bt + 25)) + '" stroke="var(--crit)" stroke-width="1.6"/>')
                        [void]$x.Append('<text x="' + (SrvNum $tx) + '" y="' + (SrvNum ($bt + 35)) + '" font-size="9" text-anchor="middle" fill="var(--crit)">policy ' + (SrvNum $pol) + '%</text>')
                        $cts = SrvProp $ep 'cloudTieringStatus'
                        $cf = SrvProp (SrvProp $cts 'volumeFreeSpacePolicyStatus') 'currentVolumeFreeSpacePercent' $null
                        if ($null -ne $cf) {
                            $cx = $barX + $barW * (1.0 - ([math]::Min(100.0, [double]$cf) / 100.0))
                            [void]$x.Append('<line x1="' + (SrvNum $cx) + '" y1="' + (SrvNum ($bt - 2)) + '" x2="' + (SrvNum $cx) + '" y2="' + (SrvNum ($bt + 22)) + '" stroke="var(--info)" stroke-width="1.6" stroke-dasharray="3 2"/>')
                        }
                    }
                    [void]$x.Append('<text x="8" y="' + (SrvNum ($bt + 10)) + '" font-size="13" font-weight="700" fill="var(--ink)">' + (SrvEnc $d.drive) + '</text>')
                    [void]$x.Append('<text x="36" y="' + (SrvNum ($bt + 10)) + '" font-size="11" fill="currentColor" opacity=".7">' + (SrvEnc (SrvProp $d.v 'label' '')) + '</text>')
                    [void]$x.Append('<text x="8" y="' + (SrvNum ($bt + 22)) + '" font-size="9.5" fill="currentColor" opacity=".55">' + (SrvNum $d.size) + ' GiB</text>')
                    if ($null -ne $d.freePct) {
                        [void]$x.Append('<text x="' + (SrvNum ($barX + $barW + 8)) + '" y="' + (SrvNum ($bt + 9)) + '" font-size="12" font-weight="700" fill="var(--ink)">' + (SrvNum $d.freePct '0.#') + '%</text>')
                        [void]$x.Append('<text x="' + (SrvNum ($barX + $barW + 8)) + '" y="' + (SrvNum ($bt + 20)) + '" font-size="9" fill="currentColor" opacity=".55">' + (SrvNum $d.freeGiB) + ' GiB free</text>')
                    } else {
                        [void]$x.Append('<text x="' + (SrvNum ($barX + $barW + 8)) + '" y="' + (SrvNum ($bt + 12)) + '" font-size="10" fill="currentColor" opacity=".5">free % not reported</text>')
                    }
                    $cx2 = $barX
                    foreach ($c in $d.chips) {
                        $cw = (5.9 * $c.Length) + 14.0
                        [void]$x.Append('<rect x="' + (SrvNum $cx2) + '" y="' + (SrvNum ($bt + 26)) + '" width="' + (SrvNum $cw) + '" height="14" rx="7" fill="var(--surface-3)" stroke="var(--line)"/>')
                        [void]$x.Append('<text x="' + (SrvNum ($cx2 + 7)) + '" y="' + (SrvNum ($bt + 36)) + '" font-size="9.5" fill="currentColor" opacity=".72">' + (SrvEnc $c) + '</text>')
                        $cx2 = $cx2 + $cw + 6
                    }
                }
                [void]$x.Append('</svg></div>')
                [void]$x.Append('<div class="lg"><span><i style="background:var(--accent);opacity:.55"></i>used</span><span><i style="background:var(--surface-3)"></i>free</span><span><i style="background:var(--crit);opacity:.26"></i>trip zone: free at or below policy + 5 points <span class="chip rule">SRV-03</span></span><span><i style="background:var(--crit)"></i>endpoint free-space policy</span><span><i style="background:var(--info)"></i>free % the cloud reports for that endpoint</span></div>')
                [void]$x.Append('<p class="note">The two free-space measurements disagree by design and are never reconciled into one number here: the server measured its own volume at collection time, the cloud reports <code>cloudTieringStatus.volumeFreeSpacePolicyStatus.currentVolumeFreeSpacePercent</code> as of its own <code>lastUpdatedTimestamp</code>.</p>')

                [void]$x.Append('<table class="tight"><thead><tr><th>Drive</th><th>Label</th><th>FS</th><th>Size GiB</th><th>Free GiB</th><th>Free %</th><th>Bytes/cluster</th><th>Endpoints on this volume</th></tr></thead><tbody>')
                foreach ($d in $descs) {
                    $eplist = @()
                    foreach ($e in $d.eps) {
                        $ep = SrvProp $e.obj 'properties'
                        $eplist += ((SrvEnc (SrvProp $e.obj 'name' '?')) + ' <span class="mono">' + (SrvEnc (SrvProp $ep 'serverLocalPath' '')) + '</span> tiering ' + (SrvEnc (SrvProp $ep 'cloudTiering' 'off')))
                    }
                    $epTxt = '<span class="ghost">none</span>'
                    if ($eplist.Count -gt 0) { $epTxt = ($eplist -join '<br>') }
                    $clv = SrvProp $d.v 'bytesPerCluster' $null
                    $clTxt = '-'
                    if ($null -ne $clv) {
                        $clTxt = (SrvEnc $clv)
                        if ((([int]$clv) -ge 65536) -and ($d.eps.Count -gt 0)) { $clTxt = $clTxt + ' <span class="chip rule">SRV-09</span>' }
                    }
                    $fpTxt = '-'
                    if ($null -ne $d.freePct) { $fpTxt = (SrvNum $d.freePct '0.#') }
                    [void]$x.Append('<tr><td class="mono"><b>' + (SrvEnc $d.drive) + '</b></td><td>' + (SrvEnc (SrvProp $d.v 'label' '-')) + '</td><td>' + (SrvEnc (SrvProp $d.v 'fileSystem' '-')) + '</td>')
                    [void]$x.Append('<td class="num">' + (SrvNum $d.size) + '</td><td class="num">' + (SrvNum $d.freeGiB) + '</td><td class="num">' + $fpTxt + '</td>')
                    [void]$x.Append('<td class="num">' + $clTxt + '</td><td>' + $epTxt + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
            }

            # ---- endpoints that matched no volume -------------------------------------------
            $unmatchedEps = @()
            foreach ($e in $myEps) {
                $lp = [string](SrvProp (SrvProp $e.obj 'properties') 'serverLocalPath' '')
                $hit = $false
                foreach ($v in $vols) {
                    $dk = ([string](SrvProp $v 'drive' '')).ToUpper()
                    if ($lp.Length -ge 2 -and $dk -and ($lp.Substring(0, 2).ToUpper() -eq $dk)) { $hit = $true }
                }
                if (-not $hit) { $unmatchedEps += $e }
            }
            if ($unmatchedEps.Count -gt 0) {
                $u = @()
                foreach ($e in $unmatchedEps) { $u += ((SrvEnc (SrvProp $e.obj 'name' '?')) + ' <span class="mono">' + (SrvEnc (SrvProp (SrvProp $e.obj 'properties') 'serverLocalPath' '')) + '</span>') }
                [void]$x.Append('<p class="note"><b>' + $unmatchedEps.Count + ' endpoint path(s) matched no volume on this server</b> and therefore drop out of the headroom, self-service-restore and cluster-size checks without leaving a trace: ' + ($u -join ', ') + '. Drive matching is the first two characters of the path uppercased, so a UNC path, a mount point or a cluster shared volume matches nothing.</p>')
            }

            # ---- server endpoints on this server (cloud side) --------------------------------
            [void]$x.Append('<h4>Server endpoints on this server (cloud)</h4>')
            if ($myEps.Count -eq 0) {
                [void]$x.Append('<p class="note">No server endpoint in this export names this host, so none of the local numbers above has a policy to be measured against.</p>')
            } else {
                [void]$x.Append('<table class="tight"><thead><tr><th>Endpoint</th><th>Local path</th><th>Tiering</th><th>Policy %</th><th>Effective %</th><th>Cloud free %</th><th>Date policy</th><th>Low disk mode</th><th>Sync health</th><th>Last tiering result</th><th>Cloud updated</th></tr></thead><tbody>')
                foreach ($e in $myEps) {
                    $ep = SrvProp $e.obj 'properties'
                    $cts = SrvProp $ep 'cloudTieringStatus'
                    $vfsp = SrvProp $cts 'volumeFreeSpacePolicyStatus'
                    $ss = SrvProp $ep 'syncStatus'
                    $ltr = SrvProp $cts 'lastCloudTieringResult' $null
                    $ltrTxt = '-'
                    if ($null -ne $ltr) {
                        if ([string]$ltr -eq '0') { $ltrTxt = '0 (success)' } else { $ltrTxt = SrvHresult $ltr $win32 }
                    }
                    [void]$x.Append('<tr><td><b>' + (SrvEnc (SrvProp $e.obj 'name' '?')) + '</b></td>')
                    [void]$x.Append('<td class="mono">' + (SrvEnc (SrvProp $ep 'serverLocalPath' '-')) + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp $ep 'cloudTiering' 'off')) + '</td>')
                    [void]$x.Append('<td class="num">' + (SrvEnc (SrvProp $ep 'volumeFreeSpacePercent' '-')) + '</td>')
                    [void]$x.Append('<td class="num">' + (SrvEnc (SrvProp $vfsp 'effectiveVolumeFreeSpacePolicy' '-')) + '</td>')
                    [void]$x.Append('<td class="num">' + (SrvEnc (SrvProp $vfsp 'currentVolumeFreeSpacePercent' '-')) + '</td>')
                    $tfod = SrvProp $ep 'tierFilesOlderThanDays' $null
                    $tfodTxt = '-'
                    if ($null -ne $tfod) { $tfodTxt = (SrvEnc $tfod) + ' d' }
                    [void]$x.Append('<td class="num">' + $tfodTxt + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp (SrvProp $cts 'lowDiskMode') 'state' '-')) + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp $ss 'combinedHealth' '-')) + ', not syncing ' + (SrvEnc (SrvProp $ss 'totalPersistentFilesNotSyncingCount' '-')) + '</td>')
                    [void]$x.Append('<td class="mono">' + (SrvEnc $ltrTxt) + '</td>')
                    [void]$x.Append('<td class="mono">' + (SrvEnc (SrvProp $cts 'lastUpdatedTimestamp' '-')) + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
            }

            # ---- services, processes, filter drivers -----------------------------------------
            $svcs = @(SrvProp $b.services 'services' @())
            [void]$x.Append('<h4>Services, processes and filter drivers</h4>')
            if ($null -eq $b.services) {
                [void]$x.Append('<p class="note">The bundle has no <code>services.json</code>, so <span class="chip rule">SRV-01</span> had no evidence at all to read on this server.</p>')
            } else {
                [void]$x.Append('<div class="grid2"><div>')
                [void]$x.Append('<table class="tight"><thead><tr><th>Service</th><th>Display name</th><th>Status</th><th>Start type</th></tr></thead><tbody>')
                if ($svcs.Count -eq 0) { [void]$x.Append('<tr class="ghost"><td colspan="4">No services returned.</td></tr>') }
                foreach ($s in $svcs) {
                    $st = [string](SrvProp $s 'Status' '')
                    $stTxt = 'not reported'
                    if ($st) { $stTxt = $st; if ($svcStatusName.ContainsKey($st)) { $stTxt = $st + ' (' + $svcStatusName[$st] + ')' } }
                    $sty = [string](SrvProp $s 'StartType' '')
                    $styTxt = 'not reported'
                    if ($sty) { $styTxt = $sty; if ($svcStartName.ContainsKey($sty)) { $styTxt = $sty + ' (' + $svcStartName[$sty] + ')' } }
                    [void]$x.Append('<tr><td class="mono"><b>' + (SrvEnc (SrvProp $s 'Name' '?')) + '</b></td><td>' + (SrvEnc (SrvProp $s 'DisplayName' '-')) + '</td><td>' + (SrvEnc $stTxt) + '</td><td>' + (SrvEnc $styTxt) + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
                [void]$x.Append('<p class="note">Get-Service drops absent properties and serialises Status and StartType as a string or an integer depending on the PowerShell version; both forms are shown exactly as collected. A missing start type means "not reported", never Disabled.</p>')
                [void]$x.Append('</div><div>')
                $procs = @(SrvProp $b.services 'processes' @())
                [void]$x.Append('<table class="tight"><thead><tr><th>Process</th><th>PID</th></tr></thead><tbody>')
                if ($procs.Count -eq 0) { [void]$x.Append('<tr class="ghost"><td colspan="2">Neither AzureStorageSyncMonitor nor FileSyncSvc was running at collection time.</td></tr>') }
                foreach ($pr in $procs) { [void]$x.Append('<tr><td class="mono">' + (SrvEnc (SrvProp $pr 'Name' '?')) + '</td><td class="num">' + (SrvEnc (SrvProp $pr 'Id' '-')) + '</td></tr>') }
                [void]$x.Append('</tbody></table>')
                $fdp = SrvProp $b.services 'filterDriversPresent'
                [void]$x.Append('<table class="tight"><thead><tr><th>Filter driver</th><th>Detected</th></tr></thead><tbody>')
                foreach ($fn in @('StorageSync', 'StorageSyncGuard')) {
                    $val = SrvProp $fdp $fn $null
                    $vt = 'not reported'
                    if ($val -eq $true) { $vt = 'yes' } elseif ($val -eq $false) { $vt = 'no' }
                    [void]$x.Append('<tr><td class="mono">' + $fn + '</td><td>' + $vt + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
                [void]$x.Append('<p class="note">Those two booleans are a collection-time regex over <code>fltmc filters</code>, so here is the text that produced them.</p>')
                if ($b.fltmc) { [void]$x.Append((SrvPre $b.fltmc)) } else { [void]$x.Append('<p class="note ghost">fltmc.txt is empty - the collector was not elevated, or fltmc returned nothing.</p>') }
                [void]$x.Append('</div></div>')
                [void]$x.Append('<p class="note">FileSyncSvc state, the monitor process and those two filters are the entirety of <span class="chip rule">SRV-01</span>; the WSearch row plus "this server has any endpoint" is half of <span class="chip rule">SRV-04</span>.</p>')
            }

            # ---- sync session digest ----------------------------------------------------------
            [void]$x.Append('<h4>Sync session digest (parsed from Telemetry event 9102)</h4>')
            $dg = @($b.digest)
            if ($dg.Count -eq 0) {
                [void]$x.Append('<p class="note">Empty. Either no sync session was logged in the collector''s event window, or the event log could not be read - an unelevated collection returns nothing here, and <span class="chip rule">SRV-06</span> then cannot fire whatever the server is actually doing.</p>')
            } else {
                $badCount = 0
                [void]$x.Append('<table class="tight"><thead><tr><th>Time (UTC)</th><th>Sync group</th><th>Direction</th><th>HResult</th><th>Per-item errors</th></tr></thead><tbody>')
                foreach ($s in ($dg | Sort-Object -Property @{ Expression = { [string](SrvProp $_ 'time' '') } } -Descending)) {
                    $tm = SrvProp $s 'time' $null
                    $hr = SrvProp $s 'hresult' $null
                    $hrs = ([string]$hr).Trim()
                    $isBad = ($hrs -and ($hrs -ne '0') -and ($hrs -ne '0x0'))
                    if ($isBad) { $badCount++ }
                    $hrTxt = 'not parsed'
                    if ($null -ne $hr) {
                        if ($isBad) { $hrTxt = SrvHresult $hr $win32 } else { $hrTxt = '0 (success)' }
                    }
                    $pie = SrvProp $s 'perItemErrorCount' $null
                    $tmTxt = 'not parsed'
                    if ($tm) { $tmTxt = [string]$tm }
                    $pieTxt = 'not parsed'
                    if ($null -ne $pie) { $pieTxt = [string]$pie }
                    [void]$x.Append('<tr><td class="mono">' + (SrvEnc $tmTxt) + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp $s 'syncGroup' 'not parsed')) + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp $s 'direction' 'not parsed')) + '</td>')
                    [void]$x.Append('<td class="mono">' + (SrvEnc $hrTxt) + '</td>')
                    [void]$x.Append('<td class="num">' + (SrvEnc $pieTxt) + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
                [void]$x.Append('<p class="note">' + $badCount + ' of ' + $dg.Count + ' session(s) carry a non-zero HResult; <span class="chip rule">SRV-06</span> counts exactly that, with a threshold of 3, alongside the 9121 event count below. Every field here comes from a regex over free-text event messages, so any of them can read "not parsed" on a different agent version even when the session row itself exists.</p>')
            }

            # ---- telemetry events --------------------------------------------------------------
            [void]$x.Append('<h4>Telemetry event log</h4>')
            $tel = @($b.telemetry)
            if ($tel.Count -eq 0) {
                [void]$x.Append('<p class="note">No telemetry events in the collector''s window, or the log was not readable without elevation.</p>')
            } else {
                $byId = @{}
                foreach ($ev in $tel) {
                    $id = [string](SrvProp $ev 'id' '')
                    if (-not $id) { $id = '(no id)' }
                    if (-not $byId.ContainsKey($id)) { $byId[$id] = @() }
                    $byId[$id] += $ev
                }
                [void]$x.Append('<table class="tight"><thead><tr><th>Event ID</th><th>Meaning</th><th>Count</th><th>Levels</th><th>Most recent</th><th>Sample message</th></tr></thead><tbody>')
                foreach ($id in ($byId.Keys | Sort-Object)) {
                    $grp = @($byId[$id])
                    $mean = 'not in the collector''s map'
                    if ($evtMeaning.ContainsKey($id)) { $mean = $evtMeaning[$id] }
                    $levels = @(); $times = @()
                    foreach ($ev in $grp) {
                        $lv = [string](SrvProp $ev 'level' '')
                        if ($lv -and ($levels -notcontains $lv)) { $levels += $lv }
                        $tv = [string](SrvProp $ev 'time' '')
                        if ($tv) { $times += $tv }
                    }
                    $latest = '-'
                    if ($times.Count -gt 0) { $latest = @($times | Sort-Object -Descending)[0] }
                    $msg = [string](SrvProp $grp[0] 'message' '')
                    if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '...' }
                    $idCell = (SrvEnc $id)
                    if ($id -eq '9121' -or $id -eq '9102') { $idCell = $idCell + ' <span class="chip rule">SRV-06</span>' }
                    [void]$x.Append('<tr><td class="mono">' + $idCell + '</td><td>' + (SrvEnc $mean) + '</td><td class="num">' + $grp.Count + '</td><td>' + (SrvEnc ($levels -join ', ')) + '</td><td class="mono">' + (SrvEnc $latest) + '</td><td class="mono">' + (SrvEnc $msg) + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
                [void]$x.Append('<p class="note">Collector event map: 9102 sync session, 9121 per-item errors, 9302 sync progress, 9301 heartbeat, 9003 / 9016 / 9029 cloud tiering, 9005 / 9006 / 9009 / 9059 / 9071 recall.</p>')
            }

            # ---- operational events -------------------------------------------------------------
            [void]$x.Append('<h4>Operational event log (Warning, Error and Critical only)</h4>')
            $ops = @($b.operational)
            if ($ops.Count -eq 0) {
                [void]$x.Append('<p class="note">No Warning, Error or Critical event in the collector''s lookback window - <code>-EventLookbackDays</code>, default 7 days, capped at 2000 events. That reads as a clean week, not as an absent collection; the exception is a bundle collected without elevation, where this log comes back empty either way. No rule reads this file, so this tab is its only surface.</p>')
            } else {
                [void]$x.Append('<table class="tight"><thead><tr><th>Time (UTC)</th><th>ID</th><th>Level</th><th>Message</th></tr></thead><tbody>')
                foreach ($ev in (@($ops) | Select-Object -First 200)) {
                    $msg = [string](SrvProp $ev 'message' '')
                    if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + '...' }
                    [void]$x.Append('<tr><td class="mono">' + (SrvEnc (SrvProp $ev 'time' '-')) + '</td><td class="mono">' + (SrvEnc (SrvProp $ev 'id' '-')) + '</td><td>' + (SrvEnc (SrvProp $ev 'level' '-')) + '</td><td>' + (SrvEnc $msg) + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
                if ($ops.Count -gt 200) { [void]$x.Append('<p class="note">' + ($ops.Count - 200) + ' further event(s) not listed here; the full list is in <code>events-operational.json</code>.</p>') }
            }

            # ---- debug cmdlet output ---------------------------------------------------------
            [void]$x.Append('<h4>Debug-StorageSyncServer output, verbatim</h4>')
            if ((-not $b.diagnose) -and (-not $b.netdbg)) {
                [void]$x.Append('<p class="note">Neither <code>debug-diagnose.txt</code> nor <code>debug-network.txt</code> is in the bundle, so <span class="chip rule">SRV-08</span> could not fire for this server whatever its actual state. The usual cause is the agent DLL not being present at <code>C:\Program Files\Azure\StorageSyncAgent</code>.</p>')
            } else {
                $dHit = ($b.diagnose -match '(?i)\b(fail|error)\b')
                $nHit = ($b.netdbg -match '(?i)\b(fail|error)\b')
                $where = 'neither file'
                if ($dHit -and $nHit) { $where = 'both files' }
                elseif ($dHit) { $where = 'debug-diagnose.txt only' }
                elseif ($nHit) { $where = 'debug-network.txt only' }
                [void]$x.Append('<p class="note"><span class="chip rule">SRV-08</span> triggers on <code>\b(fail|error)\b</code> over the whole concatenated text, so it names both files even when only one of them matched. Here the match is in <b>' + $where + '</b>, and the matched lines are highlighted below. Real Debug-StorageSyncServer output containing "Errors: 0" trips the same regex.</p>')
                [void]$x.Append('<p class="mono" style="margin:8px 0 0">debug-diagnose.txt</p>')
                if ($b.diagnose) { [void]$x.Append((SrvPre $b.diagnose -Highlight)) } else { [void]$x.Append('<p class="note ghost">not collected</p>') }
                [void]$x.Append('<p class="mono" style="margin:8px 0 0">debug-network.txt</p>')
                if ($b.netdbg) { [void]$x.Append((SrvPre $b.netdbg -Highlight)) } else { [void]$x.Append('<p class="note ghost">not collected</p>') }
            }
            [void]$x.Append('<p class="mono" style="margin:8px 0 0">debug-filesyncerrors.txt</p>')
            if ($b.syncerr) {
                [void]$x.Append((SrvPre $b.syncerr))
                [void]$x.Append('<p class="note">Collected but read by no rule. It is the per-item detail behind the per-item error counts above.</p>')
            } else {
                [void]$x.Append('<p class="note ghost">not collected.</p>')
            }
            if ($b.afsdiag) {
                [void]$x.Append('<p class="mono" style="margin:8px 0 0">afsdiag-run.txt</p>')
                $ad = $b.afsdiag
                if ($ad.Length -gt 4000) { $ad = $ad.Substring(0, 4000) + "`n... truncated in this report; the full output is in the bundle." }
                [void]$x.Append((SrvPre $ad))
            }

            # ---- self-service restore ----------------------------------------------------------
            [void]$x.Append('<h4>Self-service restore (Previous Versions)</h4>')
            $ssr = @($b.ssr)
            if ($ssr.Count -eq 0) {
                [void]$x.Append('<p class="note">Not collected - <code>selfservicerestore.json</code> is absent or empty, which travels with the missing debug output above, since both need the agent cmdlets.</p>')
            } else {
                [void]$x.Append('<table class="tight"><thead><tr><th>Drive</th><th>Raw cmdlet output</th><th>Reads as</th><th>Endpoints on that drive</th></tr></thead><tbody>')
                foreach ($r in $ssr) {
                    $dl = [string](SrvProp $r 'drive' '')
                    $raw = [string](SrvProp $r 'result' '')
                    $isOff = ($raw -match 'False|Disabled|not enabled')
                    $eplist = @()
                    foreach ($e in $myEps) {
                        $ep = SrvProp $e.obj 'properties'
                        $lp = [string](SrvProp $ep 'serverLocalPath' '')
                        if ($dl -and $lp -and $lp.ToUpper().StartsWith($dl.ToUpper())) {
                            $eplist += ((SrvEnc (SrvProp $e.obj 'name' '?')) + ' (tiering ' + (SrvEnc (SrvProp $ep 'cloudTiering' 'off')) + ')')
                        }
                    }
                    $epTxt = '<span class="ghost">none</span>'
                    if ($eplist.Count -gt 0) { $epTxt = ($eplist -join ', ') }
                    $reads = 'enabled'
                    if ($isOff) {
                        $reads = 'disabled'
                        if ($eplist.Count -gt 0) { $reads = 'disabled <span class="chip rule">SRV-07</span>' }
                    }
                    [void]$x.Append('<tr><td class="mono">' + (SrvEnc $dl) + '</td><td class="mono">' + (SrvEnc $raw) + '</td><td>' + $reads + '</td><td>' + $epTxt + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
                [void]$x.Append('<p class="note">The result is the raw <code>Out-String</code> of the cmdlet, never a boolean, so it is parsed by regex for False / Disabled / not enabled. It is only material where the drive actually carries an endpoint.</p>')
            }

            # ---- dedup, features, search scopes --------------------------------------------------
            [void]$x.Append('<h4>Deduplication, roles and Windows Search scopes</h4><div class="grid2"><div>')
            $ded = @(SrvProp $b.volumes 'dedup' @())
            [void]$x.Append('<table class="tight"><thead><tr><th>Volume</th><th>Dedup</th><th>Min file age</th><th>Saved</th><th>Optimized files</th><th>Usage</th><th>Endpoint on it?</th></tr></thead><tbody>')
            if ($ded.Count -eq 0) { [void]$x.Append('<tr class="ghost"><td colspan="7">No deduplicated volume reported.</td></tr>') }
            foreach ($dv in $ded) {
                $vn = ([string](SrvProp $dv 'Volume' '')).ToUpper()
                $has = $false
                foreach ($e in $myEps) {
                    $lp = [string](SrvProp (SrvProp $e.obj 'properties') 'serverLocalPath' '')
                    if ($lp.Length -ge 2 -and $vn -and ($lp.Substring(0, 2).ToUpper() -eq $vn)) { $has = $true }
                }
                $sv = SrvProp $dv 'SavedSpace' $null
                $svTxt = '-'
                if ($null -ne $sv) { $svTxt = (SrvNum ([double]$sv / 1073741824.0) '0.##') + ' GiB' }
                $hasTxt = '<span class="ghost">no endpoint on this volume</span>'
                if ($has) { $hasTxt = 'yes <span class="chip rule">SRV-11</span>' }
                [void]$x.Append('<tr><td class="mono">' + (SrvEnc (SrvProp $dv 'Volume' '?')) + '</td><td>' + (SrvEnc (SrvProp $dv 'Enabled' '-')) + '</td>')
                $mfa = SrvProp $dv 'MinimumFileAgeDays' $null
                $mfaTxt = '-'
                if ($null -ne $mfa) { $mfaTxt = (SrvEnc $mfa) + ' d' }
                [void]$x.Append('<td class="num">' + $mfaTxt + '</td><td class="num">' + $svTxt + '</td>')
                [void]$x.Append('<td class="num">' + (SrvEnc (SrvProp $dv 'OptimizedFilesCount' '-')) + '</td><td>' + (SrvEnc (SrvProp $dv 'UsageType' '-')) + '</td>')
                [void]$x.Append('<td>' + $hasTxt + '</td></tr>')
            }
            [void]$x.Append('</tbody></table>')
            [void]$x.Append('<p class="note">SRV-11 fires for every dedup-enabled volume, whether or not it carries an endpoint - the last column is what the rule text implies but does not check. MinimumFileAgeDays also delays the tiering date policy by the same number of days.</p>')
            [void]$x.Append('</div><div>')
            $feats = @(SrvProp $b.volumes 'features' @())
            [void]$x.Append('<table class="tight"><thead><tr><th>Role / feature</th><th>Installed</th></tr></thead><tbody>')
            if ($feats.Count -eq 0) { [void]$x.Append('<tr class="ghost"><td colspan="2">No feature list collected.</td></tr>') }
            foreach ($f in $feats) {
                $nm = [string](SrvProp $f 'Name' '?')
                $ins = SrvProp $f 'Installed' $null
                $cell = (SrvEnc $nm)
                if ($nm -eq 'FS-DFS-Replication' -and $ins -eq $true) { $cell = $cell + ' <span class="chip rule">SRV-04</span>' }
                $insTxt = '-'
                if ($null -ne $ins) { $insTxt = [string]$ins }
                [void]$x.Append('<tr><td class="mono">' + $cell + '</td><td>' + (SrvEnc $insTxt) + '</td></tr>')
            }
            [void]$x.Append('</tbody></table>')
            $wss = @(SrvProp $b.volumes 'windowsSearchScopes' @())
            [void]$x.Append('<table class="tight"><thead><tr><th>Windows Search scope</th><th>Include</th><th>Covers an endpoint?</th></tr></thead><tbody>')
            if ($wss.Count -eq 0) { [void]$x.Append('<tr class="ghost"><td colspan="3">No Windows Search index scope collected.</td></tr>') }
            foreach ($w in $wss) {
                $u = [string](SrvProp $w 'URL' '')
                $norm = (($u -replace '^file:///', '') -replace '/', '\')
                $normT = $norm.TrimEnd('\')
                $cov = @()
                foreach ($e in $myEps) {
                    $lp = [string](SrvProp (SrvProp $e.obj 'properties') 'serverLocalPath' '')
                    if ($lp -and $normT -and ($normT.ToUpper().StartsWith($lp.ToUpper()) -or $lp.ToUpper().StartsWith($normT.ToUpper()))) {
                        $cov += (SrvEnc (SrvProp $e.obj 'name' '?'))
                    }
                }
                $covTxt = '<span class="ghost">no</span>'
                if ($cov.Count -gt 0) { $covTxt = ($cov -join ', ') + ' - indexing this scope recalls tiered files' }
                [void]$x.Append('<tr><td class="mono">' + (SrvEnc $u) + '</td><td class="num">' + (SrvEnc (SrvProp $w 'Include' '-')) + '</td><td>' + $covTxt + '</td></tr>')
            }
            [void]$x.Append('</tbody></table>')
            [void]$x.Append('<p class="note">SRV-04 fires on "WSearch running and this server has any endpoint" and never looks at these URLs. The last column is the specificity the finding lacks.</p>')
            [void]$x.Append('</div></div>')

            # ---- SMB shares -----------------------------------------------------------------------
            [void]$x.Append('<h4>SMB shares</h4>')
            $shs = @($b.shares)
            if ($shs.Count -eq 0) {
                [void]$x.Append('<p class="note">No SMB share collected - <code>smbshares.json</code> is absent or empty. Read by no rule; this tab is its only surface.</p>')
            } else {
                [void]$x.Append('<table class="tight"><thead><tr><th>Share</th><th>Path</th><th>Scope</th><th>Encrypt data</th><th>Enumeration</th><th>Continuously available</th><th>Sits on which endpoint</th></tr></thead><tbody>')
                foreach ($sh in $shs) {
                    $pth = [string](SrvProp $sh 'Path' '')
                    $on = @()
                    foreach ($e in $myEps) {
                        $ep = SrvProp $e.obj 'properties'
                        $lp = [string](SrvProp $ep 'serverLocalPath' '')
                        if ($lp -and $pth -and ($pth.ToUpper().StartsWith($lp.ToUpper()) -or $lp.ToUpper().StartsWith($pth.ToUpper()))) {
                            $on += ((SrvEnc (SrvProp $e.obj 'name' '?')) + ' (tiering ' + (SrvEnc (SrvProp $ep 'cloudTiering' 'off')) + ')')
                        }
                    }
                    $onTxt = '<span class="ghost">not on a File Sync endpoint</span>'
                    if ($on.Count -gt 0) { $onTxt = ($on -join ', ') }
                    [void]$x.Append('<tr><td><b>' + (SrvEnc (SrvProp $sh 'Name' '?')) + '</b></td><td class="mono">' + (SrvEnc $pth) + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp $sh 'ScopeName' '-')) + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp $sh 'EncryptData' 'not collected')) + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp $sh 'FolderEnumerationMode' 'not collected')) + '</td>')
                    [void]$x.Append('<td>' + (SrvEnc (SrvProp $sh 'ContinuouslyAvailable' 'not collected')) + '</td>')
                    [void]$x.Append('<td>' + $onTxt + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
                [void]$x.Append('<p class="note">This is how a reader learns which user-facing share sits on a tiered cache. EncryptData, FolderEnumerationMode and ContinuouslyAvailable come from real bundles; where they read "not collected" the bundle did not carry them.</p>')
            }

            # ---- backup / AV / Defender -------------------------------------------------------------
            [void]$x.Append('<h4>Backup and antivirus products, Microsoft Defender</h4><div class="grid2"><div>')
            $prods = @(SrvProp $b.programs 'backupOrAvProducts' @())
            [void]$x.Append('<table class="tight"><thead><tr><th>Product</th><th>Version</th><th>Publisher</th></tr></thead><tbody>')
            if ($prods.Count -eq 0) { [void]$x.Append('<tr class="ghost"><td colspan="3">No backup or antivirus product matched in the installed-programs list.</td></tr>') }
            foreach ($pd in $prods) {
                [void]$x.Append('<tr><td>' + (SrvEnc (SrvProp $pd 'DisplayName' '?')) + '</td><td class="mono">' + (SrvEnc (SrvProp $pd 'DisplayVersion' '-')) + '</td><td>' + (SrvEnc (SrvProp $pd 'Publisher' '-')) + '</td></tr>')
            }
            [void]$x.Append('</tbody></table>')
            if ($prods.Count -gt 0 -and $tieredEps.Count -gt 0) {
                $tn = @()
                foreach ($e in $tieredEps) { $tn += ((SrvEnc (SrvProp $e.obj 'name' '?')) + ' <span class="mono">' + (SrvEnc (SrvProp (SrvProp $e.obj 'properties') 'serverLocalPath' '')) + '</span>') }
                [void]$x.Append('<p class="note">Those products sit on a server carrying ' + $tieredEps.Count + ' tiered endpoint(s): ' + ($tn -join ', ') + '. That pairing is the entirety of <span class="chip rule">SRV-02</span>''s evidence.</p>')
            }
            $allp = @(SrvProp $b.programs 'allPrograms' @())
            $plural = 'entries'
            if ($allp.Count -eq 1) { $plural = 'entry' }
            [void]$x.Append('<p class="note">Installed-programs inventory: ' + $allp.Count + ' ' + $plural + ' collected. Read by no rule.</p>')
            [void]$x.Append('</div><div>')
            $def = SrvProp $b.programs 'defender'
            if ($null -eq $def) {
                [void]$x.Append('<p class="note">No Defender status collected.</p>')
            } else {
                $exc = @(SrvProp $def 'exclusionPaths' @())
                $excTxt = 'none'
                if ($exc.Count -gt 0) { $excTxt = (SrvEnc ((@($exc | ForEach-Object { [string]$_ })) -join ', ')) }
                [void]$x.Append('<div class="card kv" style="margin-top:0">')
                [void]$x.Append('<div class="k">Real-time protection</div><div>' + (SrvEnc (SrvProp $def 'realTime' 'not reported')) + '</div>')
                [void]$x.Append('<div class="k">Service running</div><div>' + (SrvEnc (SrvProp $def 'amRunning' 'not reported')) + '</div>')
                [void]$x.Append('<div class="k">Engine</div><div class="mono">' + (SrvEnc (SrvProp $def 'engine' 'not collected')) + '</div>')
                [void]$x.Append('<div class="k">Signature age</div><div>' + (SrvEnc (SrvProp $def 'signatureAge' 'not collected')) + '</div>')
                [void]$x.Append('<div class="k">Path exclusions</div><div class="mono">' + $excTxt + '</div>')
                [void]$x.Append('<div class="k">Process exclusions</div><div class="mono">' + (SrvEnc (SrvProp $def 'exclusionProcesses' 'not collected')) + '</div>')
                [void]$x.Append('<div class="k">Extension exclusions</div><div class="mono">' + (SrvEnc (SrvProp $def 'exclusionExtensions' 'not collected')) + '</div>')
                [void]$x.Append('</div>')
                if ($exc.Count -eq 0 -and $tieredEps.Count -gt 0) {
                    [void]$x.Append('<p class="note">No path exclusion on a server carrying ' + $tieredEps.Count + ' tiered endpoint(s). Defender honours the recall-on-data-access attribute, so that is expected for Defender itself; it is the third-party scanner listed to the left that has to be confirmed. No rule reads any of this.</p>')
                }
            }
            [void]$x.Append('</div></div>')

            # ---- time sync + proxy ---------------------------------------------------------------
            [void]$x.Append('<h4>Time synchronisation and WinHTTP proxy</h4><div class="grid2"><div>')
            if (-not $b.w32tm) {
                [void]$x.Append('<p class="note">No <code>w32tm.txt</code> in the bundle, so <span class="chip rule">SRV-05</span> had nothing to read and an unsynchronised clock would go unreported.</p>')
            } else {
                $li2 = '-'; $strat = '-'; $offs = $null; $src = '-'
                if ($b.w32tm -match 'Leap Indicator:\s*(.+)') { $li2 = $Matches[1].Trim() }
                if ($b.w32tm -match 'Stratum:\s*(.+)') { $strat = $Matches[1].Trim() }
                if ($b.w32tm -match 'Phase Offset:\s*(-?[\d.]+)s') { $offs = [math]::Abs([double]$Matches[1]) }
                if ($b.w32tm -match 'Source:\s*(.+)') { $src = $Matches[1].Trim() }
                $offTxt = 'not parsed'
                if ($null -ne $offs) { $offTxt = (SrvNum $offs '0.######') + ' s' }
                $srcCell = (SrvEnc $src)
                if ($src -match 'Local CMOS Clock') { $srcCell = $srcCell + ' <span class="chip warn">free-running clock</span>' }
                [void]$x.Append('<div class="card kv" style="margin-top:0">')
                [void]$x.Append('<div class="k">Leap indicator</div><div class="mono">' + (SrvEnc $li2) + '</div>')
                [void]$x.Append('<div class="k">Stratum</div><div class="mono">' + (SrvEnc $strat) + '</div>')
                [void]$x.Append('<div class="k">Phase offset</div><div class="mono">' + (SrvEnc $offTxt) + ' <span class="ghost">(rule threshold 300 s)</span></div>')
                [void]$x.Append('<div class="k">Source</div><div class="mono">' + $srcCell + '</div>')
                [void]$x.Append('</div>')
                [void]$x.Append((SrvPre $b.w32tm))
            }
            [void]$x.Append('</div><div>')
            if (-not $b.proxy) {
                [void]$x.Append('<p class="note">No <code>winhttp-proxy.txt</code> collected.</p>')
            } else {
                [void]$x.Append((SrvPre $b.proxy))
                [void]$x.Append('<p class="note">Read by no rule, but a WinHTTP proxy the agent was never configured for is one of the named causes behind a Debug-StorageSyncServer failure.</p>')
            }
            [void]$x.Append('</div></div>')

            # ---- network -------------------------------------------------------------------------
            [void]$x.Append('<h4>Network configuration and DNS resolution</h4>')
            $ipc = @(SrvProp $b.network 'ipConfiguration' @())
            $dnsT = @(SrvProp $b.network 'dnsTests' @())
            if ($ipc.Count -eq 0 -and $dnsT.Count -eq 0) {
                [void]$x.Append('<p class="note"><code>network.json</code> carries no interface and no DNS test, so this server contributes no on-box network evidence. When populated, the addresses it resolves for <code>management.azure.com</code> and <code>login.microsoftonline.com</code> - and for <code>privatelink.afs.azure.net</code> / <code>privatelink.file.core.windows.net</code> - are the only server-side proof of private-endpoint DNS; the networking rules otherwise infer it from the Azure side alone.</p>')
            } else {
                if ($ipc.Count -gt 0) {
                    [void]$x.Append('<table class="tight"><thead><tr><th>Interface</th><th>IPv4</th><th>DNS servers</th><th>Gateway</th></tr></thead><tbody>')
                    foreach ($i in $ipc) {
                        $dv2 = SrvProp $i 'DNS' ''
                        if ($dv2 -is [System.Array]) { $dv2 = ($dv2 -join ', ') }
                        [void]$x.Append('<tr><td>' + (SrvEnc (SrvProp $i 'InterfaceAlias' '-')) + '</td><td class="mono">' + (SrvEnc (SrvProp $i 'IPv4' '-')) + '</td><td class="mono">' + (SrvEnc $dv2) + '</td><td class="mono">' + (SrvEnc (SrvProp $i 'Gateway' '-')) + '</td></tr>')
                    }
                    [void]$x.Append('</tbody></table>')
                }
                if ($dnsT.Count -gt 0) {
                    [void]$x.Append('<table class="tight"><thead><tr><th>Name</th><th>Record type</th><th>Address</th><th>Resolves to</th></tr></thead><tbody>')
                    foreach ($t in $dnsT) {
                        [void]$x.Append('<tr><td class="mono">' + (SrvEnc (SrvProp $t 'name' '-')) + '</td><td>' + (SrvEnc (SrvProp $t 'type' '-')) + '</td><td class="mono">' + (SrvEnc (SrvProp $t 'address' '-')) + '</td><td class="mono">' + (SrvEnc (SrvProp $t 'nameHost' '-')) + '</td></tr>')
                    }
                    [void]$x.Append('</tbody></table>')
                }
            }

            # ---- agent registry + tiered census ----------------------------------------------------
            [void]$x.Append('<h4>Agent registry and tiered-file census</h4>')
            $regRows = @($b.registry)
            if ($regRows.Count -eq 0) {
                [void]$x.Append('<p class="note"><code>registry-storagesync.json</code> is empty. A populated bundle carries the <code>HKLM:\SOFTWARE\Microsoft\Azure\StorageSync</code> subkeys holding ServerLocalPath / LocalPath per endpoint - the server''s own view of its endpoints, which is what to diff against the cloud <code>serverendpoints.json</code> when the two disagree.</p>')
            } else {
                [void]$x.Append('<table class="tight"><thead><tr><th>Key</th><th>Values</th></tr></thead><tbody>')
                foreach ($rk in (@($regRows) | Select-Object -First 60)) {
                    $kn = ''
                    foreach ($cnd in @('PSPath', 'PSChildName', 'Key', 'Name')) { if (-not $kn) { $kn = [string](SrvProp $rk $cnd '') } }
                    $pairs = @()
                    try {
                        foreach ($pp in @($rk.PSObject.Properties)) {
                            if ($pp.Name -like 'PS*') { continue }
                            $pv = $pp.Value
                            if ($pv -is [System.Array]) { $pv = ($pv -join ', ') }
                            $pairs += ((SrvEnc $pp.Name) + '=' + (SrvEnc $pv))
                        }
                    } catch { }
                    [void]$x.Append('<tr><td class="mono">' + (SrvEnc $kn) + '</td><td class="mono">' + ($pairs -join '; ') + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
            }
            $cen = @($b.census)
            if ($cen.Count -eq 0) {
                [void]$x.Append('<p class="note">No tiered-file census: the collector ran without <code>-SampleTieredFiles</code>. The cache-to-tier split on this server is therefore known only from the cloud''s <code>spaceSavings</code> figures, never measured on the volume itself.</p>')
            } else {
                [void]$x.Append('<table class="tight"><thead><tr><th>Path</th><th>Files inspected</th><th>Truncated</th><th>Tiered files</th><th>Local GiB</th><th>Tiered logical GiB</th></tr></thead><tbody>')
                foreach ($c in $cen) {
                    $tr = SrvProp $c 'truncated' $false
                    $trTxt = 'no'
                    if ($tr -eq $true) { $trTxt = '<b>yes - every number in this row is a floor, not a total</b>' }
                    [void]$x.Append('<tr><td class="mono">' + (SrvEnc (SrvProp $c 'path' '-')) + '</td><td class="num">' + (SrvEnc (SrvProp $c 'filesInspected' '-')) + '</td><td>' + $trTxt + '</td>')
                    [void]$x.Append('<td class="num">' + (SrvEnc (SrvProp $c 'tieredFiles' '-')) + '</td><td class="num">' + (SrvEnc (SrvProp $c 'localBytesGiB' '-')) + '</td><td class="num">' + (SrvEnc (SrvProp $c 'tieredLogicalGiB' '-')) + '</td></tr>')
                }
                [void]$x.Append('</tbody></table>')
                [void]$x.Append('<p class="note">Bounded by <code>-MaxFiles</code>, default 200000. This is the only ground-truth measurement of the cache-to-tier split anywhere in the assessment.</p>')
            }

            [void]$x.Append('</div>')
        }

        [void]$x.Append('<p class="note">The rule chips above - <span class="chip rule">SRV-03</span> and its siblings - point at the check a measurement feeds. The verdict, its severity and its recommendation live on the Findings tab, and the check text on the Rules tab; nothing on this tab is a finding.</p>')

    } catch {
        $why2 = [System.Net.WebUtility]::HtmlEncode([string]$_.Exception.Message)
        [void]$x.Append('<div class="card"><p>The server evidence could not be assembled from this export: <code>' + $why2 + '</code></p><p>The rest of the report is unaffected, and the raw bundles remain in <code>servers/</code> in the export itself.</p></div>')
    }

    [void]$x.Append('</section>')
    [void]$Sb.Append($x.ToString())
}
