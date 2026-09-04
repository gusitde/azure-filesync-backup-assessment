function Add-AfsTabProvenance {
    <#
    .SYNOPSIS
      The Export tab: where this evidence came from, and where it is thin.

    .DESCRIPTION
      Everything on the other tabs is downstream of one folder produced by one account at one
      moment. This tab is that folder's chain of custody: who ran the export, when, against which
      subscriptions, with which lookback windows; which calls failed and exactly which checks that
      hollowed out; whether the files still match the hashes the exporter recorded; and which
      registered servers have no server-side bundle, so their SRV-* checks never ran at all.

      It states facts and gaps only. Severities and findings belong to the Findings tab; this tab
      is the evidence a reader needs to decide how much of that to believe.
    #>
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
        [string]$ExportRoot
    )

    # ---- local helpers ---------------------------------------------------------------------
    # Nested so this stays one top-level function. Every one of them is total: it returns a
    # value for missing files, empty files, 0-byte files and malformed JSON, and never throws.
    function E { param($v) if ($null -eq $v) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$v) }

    function Pv {
        param($o, [string]$n, $def = $null)
        if ($null -eq $o) { return $def }
        try {
            if ($o.PSObject.Properties.Name -contains $n) {
                $v = $o.$n
                if ($null -eq $v) { return $def }
                return $v
            }
        } catch { }
        return $def
    }

    function RdText {
        param([string]$p)
        if (-not $p) { return $null }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        $t = $null
        try { $t = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue } catch { return $null }
        if ($null -eq $t) { return $null }
        $t = [string]$t
        if ($t.Length -gt 0 -and [int][char]$t[0] -eq 65279) { $t = $t.Substring(1) }   # BOM
        return $t
    }

    function RdJson {
        param([string]$p)
        $t = RdText $p
        if ($null -eq $t) { return $null }
        if ($t.Trim().Length -eq 0) { return $null }     # a real export writes 0-byte files
        try { return ($t | ConvertFrom-Json) } catch { return $null }
    }

    function RdList {
        param([string]$p)
        $o = RdJson $p
        if ($null -eq $o) { return @() }
        return @($o)
    }

    function CountOf { param($v) if ($null -eq $v) { return 0 } return @($v).Count }

    function ToDt {
        param($v)
        if ($null -eq $v) { return $null }
        $s = ([string]$v).Trim()
        if ($s.Length -eq 0) { return $null }
        $d = [datetime]::MinValue
        $st = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if ([datetime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $st, [ref]$d)) { return $d }
        return $null
    }

    function Stamp { param($d) if ($null -eq $d) { return '' } return ($d.ToString('yyyy-MM-dd HH:mm') + 'Z') }

    function FmtBytes {
        param($n)
        $b = 0.0
        try { $b = [double]$n } catch { return '' }
        if ($b -lt 1024) { return ("{0} B" -f [int]$b) }
        if ($b -lt 1048576) { return ("{0:N1} KB" -f ($b / 1024)) }
        if ($b -lt 1073741824) { return ("{0:N1} MB" -f ($b / 1048576)) }
        return ("{0:N2} GB" -f ($b / 1073741824))
    }

    function SpanText {
        param($ts)
        if ($null -eq $ts) { return '' }
        $h = $ts.TotalHours
        $neg = ''
        if ($h -lt 0) { $neg = '-'; $h = [Math]::Abs($h) }
        if ($h -lt 48) { return ($neg + ("{0:N1} h" -f $h)) }
        return ($neg + ("{0:N1} d" -f ($h / 24)))
    }

    # ---- scoped style ----------------------------------------------------------------------
    [void]$Sb.Append('<section class="tab" id="tab-provenance">')
    [void]$Sb.Append(@'
<style>
#tab-provenance .prov-scroll{overflow-x:auto;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:8px 4px;margin:8px 0 14px}
#tab-provenance .prov-svg{display:block;min-width:900px;max-width:100%;height:auto}
#tab-provenance .prov-svg .box{fill:var(--surface);stroke:var(--line);stroke-width:1}
#tab-provenance .prov-svg .box2{fill:var(--surface-2);stroke:var(--line);stroke-width:1}
#tab-provenance .prov-svg .t{fill:var(--ink);font-family:"Segoe UI",system-ui,Arial,sans-serif;font-size:11.5px}
#tab-provenance .prov-svg .t.h{font-weight:600;font-size:12.5px}
#tab-provenance .prov-svg .t.m{fill:var(--muted);font-size:10.5px}
#tab-provenance .prov-svg .t.f{fill:var(--faint);font-size:10px}
#tab-provenance .prov-svg .t.r{fill:var(--crit);font-size:10.5px}
#tab-provenance .prov-svg .t.g{fill:var(--good);font-size:10.5px;font-weight:600}
#tab-provenance .prov-svg .flow{stroke:var(--accent);stroke-width:1.6;fill:none}
#tab-provenance .prov-svg .err{stroke:var(--crit);stroke-width:1.4;fill:none}
#tab-provenance .prov-svg .err.dot{stroke-dasharray:3 3}
#tab-provenance .prov-svg .bound{fill:none;stroke:var(--good);stroke-width:1.5;stroke-dasharray:6 4}
#tab-provenance .prov-svg .bound.off{stroke:var(--faint);stroke-width:1.2}
#tab-provenance .prov-svg .chip{fill:var(--surface-3);stroke:var(--line)}
#tab-provenance .prov-svg .band{fill:var(--info-soft);stroke:var(--line)}
#tab-provenance .prov-svg .axis{stroke:var(--muted);stroke-width:1}
#tab-provenance .prov-svg .sh-ok{fill:var(--good)}
#tab-provenance .prov-svg .sh-none{fill:var(--faint)}
#tab-provenance .prov-svg .sh-no{fill:var(--crit)}
#tab-provenance .prov-svg .mk-flow{fill:var(--accent)}
#tab-provenance .prov-svg .mk-err{fill:var(--crit)}
#tab-provenance .tile{cursor:default}
#tab-provenance .tile .n.sm{font-size:22px}
#tab-provenance .pill{display:inline-block;padding:1px 8px;border-radius:20px;font-size:11.5px;font-weight:600;white-space:nowrap}
#tab-provenance .pill.ok{background:var(--good-soft);color:var(--good)}
#tab-provenance .pill.no{background:var(--crit-soft);color:var(--crit)}
#tab-provenance .pill.warn{background:var(--warn-soft);color:var(--warn)}
#tab-provenance .pill.neutral{background:var(--surface-3);color:var(--muted)}
#tab-provenance .det{font-family:"IBM Plex Mono",Consolas,monospace;font-size:11.5px;color:var(--muted);white-space:pre-wrap;word-break:break-word;max-width:520px}
#tab-provenance details{margin:6px 0}
#tab-provenance details>summary{cursor:pointer;color:var(--accent);font-size:13px;padding:4px 0}
#tab-provenance .banner{background:var(--info-soft);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:var(--radius);padding:12px 14px;margin:8px 0 14px}
#tab-provenance .note{color:var(--muted);font-size:12.5px;margin:4px 0 10px}
#tab-provenance table.tight th,#tab-provenance table.tight td{padding:6px 9px}
#tab-provenance td.mono,#tab-provenance th.mono{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px}
@media(max-width:900px){#tab-provenance .prov-scroll{padding:4px 0}}
</style>
'@)

    # ---- resolve the root ------------------------------------------------------------------
    $now = (Get-Date).ToUniversalTime()
    $root = [string]$ExportRoot
    if ($ExportRoot) {
        $rp = $null
        try { $rp = Resolve-Path -LiteralPath $ExportRoot -ErrorAction SilentlyContinue } catch { }
        if ($rp) { $root = [string](@($rp)[0].ProviderPath) }
    }

    function RelP {
        param([string]$full)
        if (-not $full) { return '' }
        $r = [string]$full
        if ($root -and $r.Length -ge $root.Length -and $r.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $r = $r.Substring($root.Length)
        }
        return (($r.TrimStart('\', '/')) -replace '\\', '/')
    }

    $manifest = $null
    if ($root) { $manifest = RdJson (Join-Path $root 'manifest.json') }

    if ($null -eq $manifest) {
        # The assessor itself refuses a folder without a manifest ("Not an export folder"). Say so
        # plainly rather than rendering an empty audit trail that looks like a clean bill of health.
        [void]$Sb.Append('<h2>Export provenance</h2><div class="card">')
        [void]$Sb.Append("<p><b>No <code>manifest.json</code> was found at <span class=`"res`">$(E $root)</span>, so there is no provenance record to show.</b></p>")
        [void]$Sb.Append('<p>A folder without a manifest is not an export produced by <code>Export-AzFileSyncEnvironment.ps1</code> - it may be a partially copied folder, a still-zipped export, or a hand-assembled set of files. Nothing on this tab can be established, and the run identity, subscription scope, collection windows, failed calls and file hashes behind the rest of the report are unknown.</p>')
        [void]$Sb.Append('<p>Re-run the export, or expand the original archive so that <code>manifest.json</code> sits at the root of the folder passed to the assessor.</p>')
        [void]$Sb.Append('</div></section>')
        return
    }

    # ---- run identity ----------------------------------------------------------------------
    $tool       = [string](Pv $manifest 'tool' '')
    $toolVer    = [string](Pv $manifest 'toolVersion' '')
    $schema     = [string](Pv $manifest 'schema' '')
    $exportedBy = [string](Pv $manifest 'exportedBy' '')
    $tenantId   = [string](Pv $manifest 'tenantId' '')
    $cloud      = [string](Pv $manifest 'cloud' '')
    $expRaw     = [string](Pv $manifest 'exportedAtUtc' '')
    $exportedAt = ToDt $expRaw
    $jobLb      = Pv $manifest 'jobLookbackDays' $null
    $metLb      = Pv $manifest 'metricsLookbackDays' $null
    $metSkipRaw = Pv $manifest 'metricsSkipped' $null
    $metSkipped = $false
    if ($null -ne $metSkipRaw) { try { $metSkipped = [bool]$metSkipRaw } catch { $metSkipped = $false } }
    $subs       = @(Pv $manifest 'subscriptions' @())
    $countsObj  = Pv $manifest 'counts' $null
    $apiVers    = Pv $manifest 'apiVersions' $null
    $mFiles     = @(Pv $manifest 'files' @())
    $mErrCount  = Pv $manifest 'errorCount' $null

    $age = $null
    if ($exportedAt) { $age = $now - $exportedAt }
    $ageTxt = 'unknown'
    $ageTile = 'info'
    $ageVerdict = 'The manifest carries no usable <code>exportedAtUtc</code>. The assessor does not fail on this - it silently substitutes assessment time - so every age-based check (server heartbeat, last successful job, storage key age) has quietly re-based on when the report was run, not when the data was read.'
    if ($age) {
        $ageTxt = SpanText $age
        $h = $age.TotalHours
        if ($h -lt 0) {
            $ageTile = 'med'
            $ageVerdict = 'The export is stamped in the future relative to this machine. One of the two clocks is wrong; treat every "at export time" comparison with suspicion until that is resolved.'
        } elseif ($h -le 24) {
            $ageTile = 'low'
            $ageVerdict = 'Current. Heartbeat, job-freshness and key-age checks describe the estate as it stands.'
        } elseif ($h -le 72) {
            $ageTile = 'low'
            $ageVerdict = 'Still representative. Configuration findings hold; treat the freshness checks (heartbeat, last successful job) as of the export stamp, not today.'
        } elseif ($h -le 336) {
            $ageTile = 'med'
            $ageVerdict = 'Ageing. Re-run the export before quoting anything time-based - a server that has since come back, or an agent that has since expired, will not show here.'
        } else {
            $ageTile = 'high'
            $ageVerdict = 'Stale. Every time-based rule is reporting a truth this old while the report itself looks current. Re-export before presenting freshness conclusions.'
        }
    }

    # ---- collection errors (root) ----------------------------------------------------------
    $errPath = Join-Path $root 'errors.json'
    $errPresent = Test-Path -LiteralPath $errPath -PathType Leaf
    $errRaw = RdText $errPath
    $errRows = @()
    $errNote = ''
    if (-not $errPresent) {
        $errNote = 'The export does not contain an errors.json at all, so it is not possible to tell whether any call failed.'
    } elseif ($null -eq $errRaw -or $errRaw.Trim().Length -eq 0) {
        $errNote = ''    # 0-byte file: ConvertTo-Json @() writes nothing. This is the clean case.
    } else {
        $parsed = $null
        try { $parsed = $errRaw | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -eq $parsed) {
            if ($errRaw.Trim() -ne '[]' -and $errRaw.Trim() -ne 'null') {
                $errNote = 'errors.json is present but could not be parsed as JSON, so failed calls cannot be listed.'
            }
        } else {
            $errRows = @(@($parsed) | Where-Object { $null -ne $_ })
        }
    }

    # A metric failure is written twice - metrics:<t> and metrics-nofilter:<t> - because the
    # exporter retries without the dimension filter. Two rows, one gap.
    $normWheres = @()
    foreach ($er in $errRows) {
        $w = [string](Pv $er 'where' '')
        $normWheres += ($w -replace '^metrics-nofilter:', 'metrics:')
    }
    $gapKeys = @($normWheres | Where-Object { $_ -ne '' } | Sort-Object -Unique)

    # ---- what each failed call left hollow -------------------------------------------------
    function GapImpact {
        param([string]$op)
        $o = ([string]$op).ToLower()
        switch -Regex ($o) {
            '^metrics'          { return @('the named key inside that metrics.json is written as null; the rest of the file is intact', 'cloud-tiering and recall metric checks for that resource') }
            '^rbac'             { return @('roleassignments.json for that resource is null', 'role-assignment and least-privilege checks (SEC / identity) for that resource') }
            '^diagnostics'      { return @('the diagnostics*.json for that resource is null', 'diagnostic-settings / log-routing checks (MON) - cannot be proven either way') }
            '^locks'            { return @('locks.json for that scope is null', 'resource-lock checks - an unlocked vault and an unreadable one look identical') }
            '^vaults'           { return @('the vault list for that subscription is incomplete', 'every backup check (BKP) for the vaults that were not enumerated') }
            '^defender'         { return @('defender.json / the pricing file is null', 'Defender for Storage coverage checks') }
            '^shares'           { return @('shares.json for that account is null', 'file-share inventory and backup-coverage checks') }
            '^fileservice'      { return @('fileservice.json for that account is null', 'soft-delete and share-property checks') }
            '^account|^storage' { return @('account.json for that account is null', 'storage security, firewall and networking checks') }
            '^jobs'             { return @('jobs.json for that vault is null', 'backup-job freshness and failure checks') }
            '^policies'         { return @('policies.json for that vault is null', 'retention and schedule checks') }
            '^protecteditems'   { return @('protecteditems.json for that vault is null', 'protected-item coverage checks') }
            '^containers'       { return @('containers.json for that vault is null', 'container-to-item mapping used by the coverage checks') }
            '^privateendpoint'  { return @('the private-endpoint file is null', 'private-endpoint and private-routing checks (NET)') }
            '^privatedns'       { return @('network/privatednszones.json is null', 'private DNS zone and resolution checks (NET)') }
            '^topology|^network' { return @('network/topology.json is null', 'hub/spoke, resolver and routing checks (NET)') }
            '^metricalert'      { return @('monitor/metricalerts.json is null', 'alerting checks (MON)') }
            '^subscription'     { return @('the subscription was not enumerated', 'every check for every resource in that subscription') }
            '^registeredserver' { return @('registeredservers.json for that service is null', 'registered-server checks (AFS) and the server-bundle coverage denominator') }
            '^serverendpoint'   { return @('serverendpoints.json for that service is null', 'server-endpoint topology and cloud-tiering policy checks (AFS)') }
            '^cloudendpoint'    { return @('cloudendpoints.json for that service is null', 'cloud-endpoint to storage-account mapping used across the report') }
            '^syncgroup'        { return @('syncgroups.json for that service is null', 'sync-group topology checks (AFS)') }
            '^resourceguard'    { return @('resourceguardproxies.json is null', 'multi-user authorisation checks') }
            default             { return @('the file for that call was written as null or left absent', 'any check that reads that file') }
        }
    }

    # ---- subscriptions ---------------------------------------------------------------------
    $subRows = @()
    foreach ($s in $subs) {
        if ($null -eq $s) { continue }
        $subRows += [pscustomobject]@{
            id   = [string](Pv $s 'id' '')
            name = [string](Pv $s 'name' '')
        }
    }

    # ---- files on disk, hash verification, empty-file census -------------------------------
    $allFiles = @()
    try { $allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue) } catch { $allFiles = @() }
    $diskBytes = 0
    foreach ($f in $allFiles) { $diskBytes += $f.Length }

    $listedSet = @{}
    $manifestBytes = 0
    foreach ($fe in $mFiles) {
        if ($null -eq $fe) { continue }
        $p = [string](Pv $fe 'path' '')
        if ($p) { $listedSet[$p.ToLower()] = $true }
        $bz = Pv $fe 'bytes' 0
        try { $manifestBytes += [long]$bz } catch { }
    }

    $vMatched = 0; $vMismatch = 0; $vMissing = 0
    $vBad = @()
    if ($mFiles.Count -gt 0) {
        foreach ($fe in $mFiles) {
            if ($null -eq $fe) { continue }
            $p = [string](Pv $fe 'path' '')
            if (-not $p) { continue }
            $want = [string](Pv $fe 'sha256' '')
            $full = Join-Path $root ($p -replace '/', '\')
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $vMissing++
                $vBad += [pscustomobject]@{ path = $p; state = 'listed but not on disk'; want = $want; got = '' }
                continue
            }
            $got = ''
            try { $got = [string]((Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash) } catch { $got = '' }
            if ($want -and $got -and [string]::Equals($got, $want, [System.StringComparison]::OrdinalIgnoreCase)) {
                $vMatched++
            } elseif (-not $want) {
                $vMismatch++
                $vBad += [pscustomobject]@{ path = $p; state = 'no hash recorded for this entry'; want = ''; got = $got }
            } else {
                $vMismatch++
                $vBad += [pscustomobject]@{ path = $p; state = 'content does not match the recorded hash'; want = $want; got = $got }
            }
        }
    }

    # Present on disk but outside the hashed set. manifest.json cannot hash itself and server
    # bundles are dropped in by hand after the run, so both are expected to be outside.
    $outByDesign = 0
    $unlisted = @()
    foreach ($f in $allFiles) {
        $rel = RelP $f.FullName
        if (-not $rel) { continue }
        if ($rel -ieq 'manifest.json' -or $rel.ToLower().StartsWith('servers/')) { $outByDesign++; continue }
        if ($mFiles.Count -eq 0) { continue }
        if (-not $listedSet.ContainsKey($rel.ToLower())) { $unlisted += $rel }
    }

    $cZero = 0; $cArr = 0; $cNull = 0; $cObj = 0; $cPop = 0
    foreach ($f in $allFiles) {
        if ($f.Extension -ine '.json') { continue }
        if ($f.Length -eq 0) { $cZero++; continue }
        if ($f.Length -le 32) {
            $t = RdText $f.FullName
            if ($null -ne $t) {
                $tt = $t.Trim()
                if ($tt -eq '[]') { $cArr++; continue }
                if ($tt -eq 'null') { $cNull++; continue }
                if ($tt -eq '{}') { $cObj++; continue }
            }
        }
        $cPop++
    }
    $cEmptyTotal = $cZero + $cArr + $cNull + $cObj

    # ---- registered servers, bundles, coverage ---------------------------------------------
    $svcDirs = @()
    $ssRoot = Join-Path $root 'storagesync'
    if (Test-Path -LiteralPath $ssRoot) {
        try { $svcDirs = @(Get-ChildItem -LiteralPath $ssRoot -Directory -ErrorAction SilentlyContinue) } catch { $svcDirs = @() }
    }
    $regServers = @()
    foreach ($d in $svcDirs) {
        foreach ($rs in (RdList (Join-Path $d.FullName 'registeredservers.json'))) {
            if ($null -eq $rs) { continue }
            $pr = Pv $rs 'properties' $null
            $disp = [string](Pv $pr 'friendlyName' (Pv $pr 'serverName' (Pv $rs 'name' '')))
            $short = $disp
            if ($short -and $short.Contains('.')) { $short = $short.Split('.')[0] }
            $regServers += [pscustomobject]@{
                svc   = $d.Name
                disp  = $disp
                short = [string]$short
                agent = [string](Pv $pr 'agentVersion' '')
                hb    = [string](Pv $pr 'lastHeartBeat' '')
            }
        }
    }

    $bundleArtifacts = @(
        @{ f = 'system.json';              n = 'system.json';            w = 'the bundle has no identity at all - hostname, OS, agent version and the elevated flag all come from here' },
        @{ f = 'services.json';            n = 'services.json';          w = 'agent service state (FileSyncSvc, StorageSync monitor) cannot be checked' },
        @{ f = 'volumes.json';             n = 'volumes.json';           w = 'volume free space and the cloud-tiering headroom check go dark' },
        @{ f = 'programs.json';            n = 'programs.json';          w = 'installed backup and anti-virus products cannot be listed' },
        @{ f = 'sync-session-digest.json'; n = 'sync-session-digest.json'; w = 'per-item sync error counts go dark' },
        @{ f = 'events-telemetry.json';    n = 'events-telemetry.json';  w = 'SRV-06 (9102 telemetry events) cannot fire - a clean result would only mean nothing was read' },
        @{ f = 'events-operational.json';  n = 'events-operational.json'; w = 'operational event evidence is absent' },
        @{ f = 'selfservicerestore.json';  n = 'selfservicerestore.json'; w = 'SRV-07 (previous versions / self-service restore) cannot fire' },
        @{ f = 'fltmc.txt';                n = 'fltmc.txt';              w = 'SRV-01 (filter-driver altitude conflicts) cannot fire' },
        @{ f = 'debug-diagnose.txt';       n = 'debug-diagnose.txt';     w = 'SRV-08 (Debug-StorageSyncServer) cannot fire - only written when the agent DLL imports' },
        @{ f = 'debug-network.txt';        n = 'debug-network.txt';      w = 'the agent network connectivity test is absent' },
        @{ f = 'debug-filesyncerrors.txt'; n = 'debug-filesyncerrors.txt'; w = 'per-file sync error detail is absent' },
        @{ f = 'w32tm.txt';                n = 'w32tm.txt';              w = 'server time-skew evidence is absent' },
        @{ f = 'smbshares.json';           n = 'smbshares.json';         w = 'the SMB shares served from the endpoint cannot be listed' },
        @{ f = 'network.json';             n = 'network.json';           w = 'server network configuration is absent' },
        @{ f = 'registry-storagesync.json'; n = 'registry-storagesync.json'; w = 'agent registry settings are absent' },
        @{ f = 'winhttp-proxy.txt';        n = 'winhttp-proxy.txt';      w = 'the WinHTTP proxy in force for the agent is unknown' },
        @{ f = 'tiered-census.json';       n = 'tiered-census.json';     w = 'optional - only written when the collector ran with -SampleTieredFiles' },
        @{ f = 'errors.json';              n = 'errors.json';            w = 'the bundle records no collection failures of its own' }
    )

    $bundles = @()
    $srvRoot = Join-Path $root 'servers'
    $serversDirPresent = (Test-Path -LiteralPath $srvRoot)
    if ($serversDirPresent) {
        $hostDirs = @()
        try { $hostDirs = @(Get-ChildItem -LiteralPath $srvRoot -Directory -ErrorAction SilentlyContinue) } catch { $hostDirs = @() }
        foreach ($hd in $hostDirs) {
            $sysAll = @()
            try { $sysAll = @(Get-ChildItem -LiteralPath $hd.FullName -Filter 'system.json' -Recurse -File -ErrorAction SilentlyContinue) } catch { $sysAll = @() }
            $zips = @()
            try { $zips = @(Get-ChildItem -LiteralPath $hd.FullName -Filter '*.zip' -File -ErrorAction SilentlyContinue) } catch { $zips = @() }

            if ($sysAll.Count -eq 0) {
                # A zip that nobody expanded is not the same as a missing bundle. Say which it is.
                $st = 'folder present, no system.json found'
                if ($zips.Count -gt 0) { $st = 'still zipped - present but unread until it is expanded' }
                $bundles += [pscustomobject]@{
                    host = $hd.Name; dir = ''; rel = (RelP $hd.FullName); state = $st
                    collected = $null; collectedRaw = ''; toolVer = ''; elevated = $null
                    errors = @(); present = @{}; afsdiag = $false; badDebug = @()
                }
                continue
            }

            $sysFile = $sysAll[0]
            $bdir = Split-Path -Parent $sysFile.FullName
            $sys = RdJson $sysFile.FullName
            $hn = [string](Pv $sys 'hostname' $hd.Name)
            $cRaw = [string](Pv $sys 'collectedAtUtc' '')
            $elevRaw = Pv $sys 'elevated' $null
            $elev = $null
            if ($null -ne $elevRaw) { try { $elev = [bool]$elevRaw } catch { $elev = $null } }

            $present = @{}
            foreach ($a in $bundleArtifacts) {
                $present[$a.f] = (Test-Path -LiteralPath (Join-Path $bdir $a.f) -PathType Leaf)
            }
            $afsdiag = (Test-Path -LiteralPath (Join-Path $bdir 'afsdiag'))

            # Capture() writes "ERROR: <exception>" into the debug text AND appends to errors.json,
            # and SRV-08 then regex-matches fail|error on that same text. Flag it here so a
            # collection failure is not read as a server-side defect.
            $badDebug = @()
            foreach ($dn in @('debug-diagnose.txt', 'debug-network.txt', 'debug-filesyncerrors.txt')) {
                $dt = RdText (Join-Path $bdir $dn)
                if ($null -eq $dt) { continue }
                $fl = ''
                $lines = @($dt -split "`r?`n")
                if ($lines.Count -gt 0) { $fl = [string]$lines[0] }
                if ($fl -match '^\s*ERROR:') { $badDebug += ($dn + ' :: ' + $fl.Trim()) }
            }

            $bErrRaw = RdText (Join-Path $bdir 'errors.json')
            $bErr = @()
            if ($null -ne $bErrRaw -and $bErrRaw.Trim().Length -gt 0) {
                $bp = $null
                try { $bp = $bErrRaw | ConvertFrom-Json } catch { $bp = $null }
                if ($null -ne $bp) { $bErr = @(@($bp) | Where-Object { $null -ne $_ }) }
            }

            $bundles += [pscustomobject]@{
                host = $hn; dir = $bdir; rel = (RelP $bdir); state = 'read'
                collected = (ToDt $cRaw); collectedRaw = $cRaw
                toolVer = [string](Pv $sys 'toolVersion' ''); elevated = $elev
                errors = $bErr; present = $present; afsdiag = $afsdiag; badDebug = $badDebug
            }
        }
    }

    $bundleByHost = @{}
    foreach ($b in $bundles) {
        $k = ([string]$b.host).ToLower()
        if ($k -and (-not $bundleByHost.ContainsKey($k))) { $bundleByHost[$k] = $b }
    }
    $covered = 0
    $uncoveredNames = @()
    foreach ($rs in $regServers) {
        $k = ([string]$rs.short).ToLower()
        if ($k -and $bundleByHost.ContainsKey($k)) { $covered++ } else { $uncoveredNames += $rs.disp }
    }
    $readBundles = @($bundles | Where-Object { $_.state -eq 'read' })
    $bundleErrTotal = 0
    foreach ($b in $readBundles) { $bundleErrTotal += (CountOf $b.errors) }

    # ---- observed metric windows -----------------------------------------------------------
    $metricRows = @()
    $metricPaths = @()
    foreach ($d in $svcDirs) { $metricPaths += (Join-Path $d.FullName 'metrics.json') }
    $stDirs = @()
    $stRoot = Join-Path $root 'storage'
    if (Test-Path -LiteralPath $stRoot) {
        try { $stDirs = @(Get-ChildItem -LiteralPath $stRoot -Directory -ErrorAction SilentlyContinue) } catch { $stDirs = @() }
    }
    foreach ($d in $stDirs) { $metricPaths += (Join-Path $d.FullName 'metrics.json') }
    foreach ($mp in $metricPaths) {
        if (-not (Test-Path -LiteralPath $mp -PathType Leaf)) { continue }
        $rel = RelP $mp
        $mo = RdJson $mp
        if ($null -eq $mo) {
            $metricRows += [pscustomobject]@{ file = $rel; key = '(whole file)'; span = ''; iv = ''; got = $false }
            continue
        }
        $props = @()
        try { $props = @($mo.PSObject.Properties) } catch { $props = @() }
        foreach ($pr in $props) {
            $v = $pr.Value
            if ($null -eq $v) {
                $metricRows += [pscustomobject]@{ file = $rel; key = [string]$pr.Name; span = ''; iv = ''; got = $false }
                continue
            }
            $vals = Pv $v 'value' $null
            $metricRows += [pscustomobject]@{
                file = $rel; key = [string]$pr.Name
                span = [string](Pv $v 'timespan' ''); iv = [string](Pv $v 'interval' '')
                got  = ((CountOf $vals) -gt 0)
            }
        }
    }

    # ---- counts reconciliation --------------------------------------------------------------
    $obs = @{}
    $obs['storageSyncServices'] = $svcDirs.Count
    $obs['registeredServers'] = $regServers.Count
    $sg = 0; $ce = 0; $se = 0
    foreach ($d in $svcDirs) {
        $sg += (CountOf (RdList (Join-Path $d.FullName 'syncgroups.json')))
        $ce += (CountOf (RdList (Join-Path $d.FullName 'cloudendpoints.json')))
        $se += (CountOf (RdList (Join-Path $d.FullName 'serverendpoints.json')))
    }
    $obs['syncGroups'] = $sg; $obs['cloudEndpoints'] = $ce; $obs['serverEndpoints'] = $se
    $obs['storageAccounts'] = $stDirs.Count
    $sh = 0
    foreach ($d in $stDirs) { $sh += (CountOf (RdList (Join-Path $d.FullName 'shares.json'))) }
    $obs['fileShares'] = $sh
    $bkDirs = @()
    $bkRoot = Join-Path $root 'backup'
    if (Test-Path -LiteralPath $bkRoot) {
        try { $bkDirs = @(Get-ChildItem -LiteralPath $bkRoot -Directory -ErrorAction SilentlyContinue) } catch { $bkDirs = @() }
    }
    $obs['recoveryServicesVaults'] = $bkDirs.Count
    $bp = 0; $pi = 0; $bj = 0
    foreach ($d in $bkDirs) {
        $bp += (CountOf (RdList (Join-Path $d.FullName 'policies.json')))
        $pi += (CountOf (RdList (Join-Path $d.FullName 'protecteditems.json')))
        $bj += (CountOf (RdList (Join-Path $d.FullName 'jobs.json')))
    }
    $obs['backupPolicies'] = $bp; $obs['protectedItems'] = $pi; $obs['backupJobs'] = $bj
    $dpDirs = @()
    $dpRoot = Join-Path $root 'backup-dataprotection'
    if (Test-Path -LiteralPath $dpRoot) {
        try { $dpDirs = @(Get-ChildItem -LiteralPath $dpRoot -Directory -ErrorAction SilentlyContinue) } catch { $dpDirs = @() }
    }
    $obs['dataProtectionVaults'] = $dpDirs.Count
    $obs['privateDnsZones'] = (CountOf (RdList (Join-Path $root 'network/privatednszones.json')))
    $obs['privateEndpoints'] = (CountOf (RdList (Join-Path $root 'network/privateendpoints.json')))

    $inv = RdJson (Join-Path $root 'inventory.json')
    $invCounts = @{}
    if ($null -ne $inv) {
        $ips = @()
        try { $ips = @($inv.PSObject.Properties) } catch { $ips = @() }
        foreach ($pr in $ips) { $invCounts[[string]$pr.Name] = (CountOf $pr.Value) }
    }

    # =========================================================================================
    # RENDER
    # =========================================================================================
    [void]$Sb.Append('<h2>Export provenance</h2>')

    # ---- confidence banner ------------------------------------------------------------------
    $subNames = @($subRows | ForEach-Object { $_.name } | Where-Object { $_ })
    $subPhrase = "$($subRows.Count) subscription"
    if ($subRows.Count -ne 1) { $subPhrase = "$($subRows.Count) subscriptions" }
    if ($subNames.Count -gt 0 -and $subNames.Count -le 4) { $subPhrase += ' (' + ($subNames -join ', ') + ')' }
    $gapPhrase = "$($errRows.Count) failed collection call"
    if ($errRows.Count -ne 1) { $gapPhrase += 's' }
    if ($errRows.Count -ne $gapKeys.Count) {
        $gapPhrase += " ($($gapKeys.Count) distinct gap"
        if ($gapKeys.Count -eq 1) { $gapPhrase += ')' } else { $gapPhrase += 's)' }
    }
    $sentence = 'Assessed from an export taken ' + (Stamp $exportedAt)
    if (-not $exportedAt) { $sentence = 'Assessed from an export with no usable timestamp' }
    if ($age) { $sentence += " ($ageTxt old)" }
    $sentence += ' by ' + $(if ($exportedBy) { $exportedBy } else { 'an unrecorded account' })
    $sentence += ' across ' + $subPhrase + ', with ' + $gapPhrase + '.'
    if ($regServers.Count -eq 0) {
        $sentence += ' No File Sync servers are registered, so server-side collection does not apply.'
    } else {
        $sentence += " Server bundles cover $covered of $($regServers.Count) registered server"
        if ($regServers.Count -ne 1) { $sentence += 's' }
        $sentence += '.'
        if ($uncoveredNames.Count -gt 0 -and $uncoveredNames.Count -le 8) {
            $sentence += ' Server-side checks were not run for ' + ($uncoveredNames -join ', ') + '.'
        } elseif ($uncoveredNames.Count -gt 8) {
            $sentence += " Server-side checks were not run for $($uncoveredNames.Count) of them."
        }
    }
    if ($metSkipped) { $sentence += ' Metrics collection was skipped, so every metric-based check is unproven.' }
    [void]$Sb.Append('<div class="banner"><b>Confidence statement</b> - copy this into the cover note.<br>')
    [void]$Sb.Append("<span class=`"ev`">$(E $sentence)</span></div>")

    # ---- tiles -------------------------------------------------------------------------------
    $gapTile = 'info'; if ($gapKeys.Count -gt 0) { $gapTile = 'med' }
    $covTile = 'info'
    if ($regServers.Count -gt 0) {
        if ($covered -eq $regServers.Count) { $covTile = 'low' }
        elseif ($covered -eq 0) { $covTile = 'high' }
        else { $covTile = 'med' }
    }
    $covVal = "$covered / $($regServers.Count)"
    if ($regServers.Count -eq 0) { $covVal = 'n/a' }
    [void]$Sb.Append('<div class="tiles">')
    [void]$Sb.Append("<div class=`"tile $ageTile`"><div class=`"n sm`">$(E $ageTxt)</div><div class=`"l`">Export age</div></div>")
    [void]$Sb.Append("<div class=`"tile info`"><div class=`"n`">$($subRows.Count)</div><div class=`"l`">Subscriptions reached</div></div>")
    [void]$Sb.Append("<div class=`"tile $gapTile`"><div class=`"n`">$($gapKeys.Count)</div><div class=`"l`">Distinct collection gaps</div></div>")
    [void]$Sb.Append("<div class=`"tile $covTile`"><div class=`"n sm`">$(E $covVal)</div><div class=`"l`">Servers with a bundle</div></div>")
    [void]$Sb.Append('</div>')

    # ---- chain of custody diagram -------------------------------------------------------------
    $svgFiles = 'no per-file hashes recorded'
    $svgVerify = 'integrity not verifiable'
    $boundCls = 'bound off'
    $boundLbl = 't f'
    if ($mFiles.Count -gt 0) {
        $svgFiles = "$($mFiles.Count) files, $(FmtBytes $manifestBytes)"
        $svgVerify = "$vMatched match, $vMismatch differ, $vMissing missing"
        $boundCls = 'bound'
        $boundLbl = 't g'
        if ($vMismatch -gt 0 -or $vMissing -gt 0) { $boundCls = 'bound off'; $boundLbl = 't r' }
    }
    $svgBundleLine = 'no server bundle in this export'
    $svgCollected = 'collectedAtUtc - nothing collected'
    $svgElev = 'no bundle to check'
    $elevCls = 'sh-none'
    $elevTxt = 't m'
    if ($readBundles.Count -gt 0) {
        $b0 = $readBundles[0]
        $svgBundleLine = "$covered of $($regServers.Count) registered servers covered"
        $svgCollected = 'collectedAtUtc ' + $(if ($b0.collected) { Stamp $b0.collected } else { 'not recorded' })
        if ($readBundles.Count -gt 1) { $svgCollected += " (first of $($readBundles.Count))" }
        if ($b0.elevated -eq $true) { $svgElev = 'elevated: yes'; $elevCls = 'sh-ok' }
        elseif ($b0.elevated -eq $false) { $svgElev = 'elevated: NO'; $elevCls = 'sh-no'; $elevTxt = 't r' }
        else { $svgElev = 'elevated: not recorded' }
    }
    $svgExpTs = 'exportedAtUtc ' + $(if ($exportedAt) { Stamp $exportedAt } else { 'not recorded' })
    $svgFoot = 'schematic, not to scale'
    if ($readBundles.Count -gt 0 -and $readBundles[0].collected -and $exportedAt) {
        $svgFoot += ' - bundle collected ' + (SpanText ($readBundles[0].collected - $exportedAt)) + ' from the export stamp'
    } elseif ($readBundles.Count -gt 0) {
        $svgFoot += ' - bundle/export clock skew not computable'
    } else {
        $svgFoot += ' - no bundle clock to compare'
    }
    if ($age) { $svgFoot += '; report written ' + $ageTxt + ' after the export' }
    $svgErrLine = "errors.json - $($errRows.Count) row(s)"
    $svgBErrLine = "servers/*/errors.json - $bundleErrTotal row(s)"
    $svgAssessed = 'assessedAtUtc ' + (Stamp $now)
    $svgAge = ''
    if ($age) { $svgAge = 'assessed ' + $ageTxt + ' after the export' }
    $svgBand1 = ''
    if ($readBundles.Count -gt 0 -and $readBundles[0].collected) {
        $svgBand1 = '<rect x="150" y="418" width="280" height="12" class="band"/>' +
                    '<line x1="150" y1="414" x2="150" y2="434" class="axis"/>' +
                    '<text x="150" y="408" class="t f">SRV-10 compares agent versions across this gap</text>'
    }

    [void]$Sb.Append('<h2>Chain of custody</h2>')
    [void]$Sb.Append('<p class="note">Three collectors, three clocks, three error channels - and only one of the three is covered by hashes. The dashed boundary is exactly what the manifest can prove.</p>')
    [void]$Sb.Append('<div class="prov-scroll">')
    [void]$Sb.Append(@"
<svg class="prov-svg" viewBox="0 0 900 520" role="img" aria-label="Chain of custody for this export: an ARM collector and a per-server collector write into one export folder, which the assessor reads to produce the report. Only the ARM collector's output is covered by the manifest hashes; manifest.json and the server bundles sit outside that boundary. The root errors file reaches the assessor, the per-bundle errors file is never read, and subscriptions the account could not see are never recorded at all.">
<defs>
<marker id="pv-flow" markerWidth="9" markerHeight="7" refX="8" refY="3.5" orient="auto"><path d="M0,0 L9,3.5 L0,7 z" class="mk-flow"/></marker>
<marker id="pv-err" markerWidth="9" markerHeight="7" refX="8" refY="3.5" orient="auto"><path d="M0,0 L9,3.5 L0,7 z" class="mk-err"/></marker>
</defs>

<rect x="12" y="16" width="250" height="120" rx="8" class="box"/>
<text x="26" y="38" class="t h">1. ARM / Azure (read-only GETs)</text>
<text x="26" y="57" class="t m">$(E $tool) v$(E $toolVer)</text>
<circle cx="30" cy="73" r="4" class="chip"/>
<text x="42" y="77" class="t">$(E $svgExpTs)</text>
<text x="26" y="94" class="t f">stamped at the END of the run</text>
<text x="26" y="114" class="t m">$(E $svgFiles)</text>
<text x="26" y="130" class="t f">+ inventory.json + summary.md</text>

<rect x="12" y="152" width="250" height="112" rx="8" class="box"/>
<text x="26" y="174" class="t h">2. Windows servers (by hand)</text>
<text x="26" y="192" class="t m">Get-AfsServerDiagnostics.ps1, per host</text>
<circle cx="30" cy="207" r="4" class="chip"/>
<text x="42" y="211" class="t">$(E $svgCollected)</text>
<path d="M26 220 l7 -3 l7 3 v6 c0 5 -4 8 -7 9 c-3 -1 -7 -4 -7 -9 z" class="$elevCls"/>
<text x="46" y="234" class="$elevTxt">$(E $svgElev)</text>
<text x="26" y="254" class="t f">$(E $svgBundleLine)</text>

<rect x="300" y="16" width="296" height="248" rx="8" class="box2"/>
<text x="314" y="36" class="t h">export folder</text>
<rect x="312" y="46" width="272" height="118" rx="6" class="$boundCls"/>
<text x="324" y="66" class="$boundLbl">sha256 in manifest.files[]</text>
<text x="324" y="85" class="t m">$(E $svgFiles)</text>
<text x="324" y="103" class="t m">$(E $svgVerify)</text>
<text x="324" y="126" class="t f">everything the exporter wrote itself</text>
<text x="324" y="146" class="t f">is inside this boundary</text>
<text x="314" y="186" class="t">manifest.json</text>
<text x="314" y="201" class="t f">outside - it cannot hash itself</text>
<text x="314" y="221" class="t">servers/**</text>
<text x="314" y="236" class="t f">outside - dropped in by hand, unhashed</text>
<text x="314" y="256" class="t r">$(E $svgErrLine)</text>

<rect x="640" y="52" width="246" height="86" rx="8" class="box"/>
<text x="654" y="74" class="t h">3. Assess-AzFileSyncExport.ps1</text>
<circle cx="658" cy="90" r="4" class="chip"/>
<text x="670" y="94" class="t">$(E $svgAssessed)</text>
<text x="654" y="114" class="t f">$(E $svgAge)</text>
<text x="654" y="130" class="t f">re-bases every age check on the export stamp</text>

<rect x="640" y="164" width="246" height="52" rx="8" class="box"/>
<text x="654" y="186" class="t h">findings.json</text>
<text x="654" y="204" class="t m">assessment.html (this report)</text>

<path d="M262 76 L296 76" class="flow" marker-end="url(#pv-flow)"/>
<path d="M262 208 L296 208" class="flow" marker-end="url(#pv-flow)"/>
<path d="M596 120 C 616 120 620 100 636 96" class="flow" marker-end="url(#pv-flow)"/>
<path d="M763 138 L763 162" class="flow" marker-end="url(#pv-flow)"/>

<path d="M470 262 C 540 262 580 150 634 122" class="err" marker-end="url(#pv-err)"/>
<rect x="640" y="18" width="112" height="22" rx="11" class="chip"/>
<text x="650" y="33" class="t r">surfaced as OPS-02</text>
<path d="M700 52 L700 42" class="err" marker-end="url(#pv-err)"/>

<text x="314" y="290" class="t r">$(E $svgBErrLine)</text>
<path d="M470 286 L604 286" class="err"/>
<path d="M610 280 L624 294 M624 280 L610 294" class="err"/>
<text x="634" y="284" class="t r">never read by the assessor</text>
<text x="634" y="299" class="t f">this tab is its only surface</text>

<path d="M262 106 C 292 150 294 258 250 298" class="err dot" marker-end="url(#pv-err)"/>
<text x="12" y="326" class="t r">invisible subscriptions: not Enabled, other tenant, or no Reader</text>
<text x="12" y="341" class="t f">silently absent from subscriptions[] - no error row is ever written for them</text>

<line x1="60" y1="424" x2="850" y2="424" class="axis"/>
$svgBand1
<rect x="430" y="418" width="370" height="12" class="band"/>
<line x1="430" y1="414" x2="430" y2="434" class="axis"/>
<line x1="800" y1="414" x2="800" y2="434" class="axis"/>
<text x="430" y="408" class="t f">AFS-03 / AFS-04 / key age all re-base on this stamp</text>
<text x="150" y="448" class="t m" text-anchor="middle">server bundle</text>
<text x="150" y="462" class="t f" text-anchor="middle">$(E $(if ($readBundles.Count -gt 0 -and $readBundles[0].collected) { Stamp $readBundles[0].collected } else { 'no bundle' }))</text>
<text x="430" y="448" class="t m" text-anchor="middle">cloud export</text>
<text x="430" y="462" class="t f" text-anchor="middle">$(E $(if ($exportedAt) { Stamp $exportedAt } else { 'not recorded' }))</text>
<text x="800" y="448" class="t m" text-anchor="middle">assessed</text>
<text x="800" y="462" class="t f" text-anchor="middle">$(E (Stamp $now))</text>
<text x="60" y="486" class="t f">$(E $svgFoot)</text>
<text x="60" y="504" class="t f">Blue = data flow. Red = failure channel. Green dashed = what the manifest hashes can prove.</text>
</svg>
"@)
    [void]$Sb.Append('</div>')

    # ---- run identity ------------------------------------------------------------------------
    [void]$Sb.Append('<h2>Run identity</h2>')
    [void]$Sb.Append('<p class="note">When, by whom, and with what. This is the only answer the export gives to those three questions.</p>')
    [void]$Sb.Append('<div class="card kv">')
    [void]$Sb.Append("<div class=`"k`">Export folder</div><div class=`"res`">$(E $root)</div>")
    [void]$Sb.Append("<div class=`"k`">Tool</div><div><code>$(E $tool)</code> v$(E $toolVer)</div>")
    [void]$Sb.Append("<div class=`"k`">Schema</div><div><code>$(E $schema)</code></div>")
    if ($expRaw -and $exportedAt) {
        [void]$Sb.Append("<div class=`"k`">Exported (UTC)</div><div><code>$(E $expRaw)</code> - stamped when the run <i>finished</i>, so the earliest data in the export is older than this label</div>")
    } elseif ($expRaw) {
        [void]$Sb.Append("<div class=`"k`">Exported (UTC)</div><div><code>$(E $expRaw)</code> <span class=`"pill no`">not a date</span> the stamp cannot be parsed, so it establishes nothing</div>")
    } else {
        [void]$Sb.Append('<div class="k">Exported (UTC)</div><div><span class="pill no">not recorded</span> the assessor substitutes assessment time without warning</div>')
    }
    [void]$Sb.Append("<div class=`"k`">Export age</div><div><b>$(E $ageTxt)</b> - $ageVerdict</div>")
    if ($exportedBy) {
        [void]$Sb.Append("<div class=`"k`">Exported by</div><div><code>$(E $exportedBy)</code> - the account whose Reader access defines what could be seen</div>")
    } else {
        [void]$Sb.Append('<div class="k">Exported by</div><div><span class="pill warn">not recorded</span> nobody is named as accountable for this read</div>')
    }
    [void]$Sb.Append("<div class=`"k`">Tenant</div><div class=`"res`">$(E $tenantId)</div>")
    [void]$Sb.Append("<div class=`"k`">Cloud</div><div>$(E $cloud)</div>")
    [void]$Sb.Append('</div>')

    # ---- subscriptions -------------------------------------------------------------------------
    [void]$Sb.Append('<h2>Subscriptions in scope</h2>')
    if ($subRows.Count -eq 0) {
        [void]$Sb.Append('<div class="card"><p>The manifest lists no subscriptions. Either the export was run with an explicit scope that resolved to nothing, or subscription enumeration failed - check the failed calls below.</p></div>')
    } else {
        [void]$Sb.Append('<table class="tight"><thead><tr><th>Subscription</th><th class="mono">Id</th><th>Folder prefix used on disk</th></tr></thead><tbody>')
        foreach ($s in $subRows) {
            $folder = ([string]$s.name) -replace '[^\w.\-]', '_'
            [void]$Sb.Append("<tr><td>$(E $s.name)</td><td class=`"mono res`">$(E $s.id)</td><td class=`"mono`">$(E $folder)__&lt;resource&gt;</td></tr>")
        }
        [void]$Sb.Append('</tbody></table>')
    }
    [void]$Sb.Append('<p class="note"><b>This is what was reachable, not what exists.</b> With no explicit scope the exporter takes every subscription whose state is Enabled <i>and</i> whose tenant matches the signed-in tenant. A disabled subscription, a subscription in another tenant, or one where the account lacks Reader is simply absent - and no error row is written for it. If the customer believes there are more subscriptions than the table above, that belief is not contradicted by this export.</p>')

    # ---- collection windows ---------------------------------------------------------------------
    [void]$Sb.Append('<h2>Collection windows</h2>')
    [void]$Sb.Append('<div class="card kv">')
    [void]$Sb.Append("<div class=`"k`">Job lookback (requested)</div><div>$(E $(if ($null -ne $jobLb) { "$jobLb days" } else { 'not recorded' })) - backup jobs older than this are not in the export, so a report of no failed jobs means none <i>in this window</i></div>")
    [void]$Sb.Append("<div class=`"k`">Metrics lookback (requested)</div><div>$(E $(if ($null -ne $metLb) { "$metLb days" } else { 'not recorded' }))</div>")
    if ($metSkipped) {
        [void]$Sb.Append('<div class="k">Metrics collected</div><div><span class="pill no">skipped</span> every metric-based check - cloud-tiering recall volume, tiered data size, server heartbeat metrics, cache hit rate - has no input and did not run. Re-export without -SkipMetrics before drawing tiering conclusions.</div>')
    } else {
        [void]$Sb.Append('<div class="k">Metrics collected</div><div><span class="pill ok">yes</span> the observed windows below are the ground truth - trust them over the requested lookback</div>')
    }
    [void]$Sb.Append('</div>')
    if ($metricRows.Count -gt 0) {
        $shown = @($metricRows | Select-Object -First 24)
        [void]$Sb.Append('<table class="tight"><thead><tr><th>Metrics file</th><th>Metric</th><th>Observed timespan</th><th>Interval</th><th>Data</th></tr></thead><tbody>')
        foreach ($m in $shown) {
            $st = '<span class="pill no">null</span>'
            if ($m.got) { $st = '<span class="pill ok">present</span>' }
            elseif ($m.span) { $st = '<span class="pill neutral">no series</span>' }
            [void]$Sb.Append("<tr><td class=`"mono res`">$(E $m.file)</td><td class=`"mono`">$(E $m.key)</td><td class=`"mono`">$(E $m.span)</td><td class=`"mono`">$(E $m.iv)</td><td>$st</td></tr>")
        }
        [void]$Sb.Append('</tbody></table>')
        if ($metricRows.Count -gt $shown.Count) {
            [void]$Sb.Append("<p class=`"note`">$($metricRows.Count - $shown.Count) further metric row(s) not shown.</p>")
        }
        [void]$Sb.Append('<p class="note">A <code>null</code> row is a gap <i>inside</i> an otherwise healthy file: the rest of that metrics.json is intact, only that one key is missing. File-level coverage is not enough - this is where a missing metric actually hides.</p>')
    } else {
        [void]$Sb.Append('<p class="note">No metrics files were found in the export, so no observed collection window can be shown.</p>')
    }

    # ---- failed calls ------------------------------------------------------------------------
    [void]$Sb.Append('<h2>Failed collection calls</h2>')
    if ($errNote) { [void]$Sb.Append("<div class=`"card`"><p>$(E $errNote)</p></div>") }
    if ($errRows.Count -eq 0) {
        $totalCalls = ''
        if ($mFiles.Count -gt 0) { $totalCalls = " Every one of the $($mFiles.Count) files the exporter set out to write was written." }
        if (-not $errNote) {
            [void]$Sb.Append("<div class=`"card`"><p><span class=`"pill ok`">0 failed calls</span> No collection call failed.$(E $totalCalls)</p>")
            [void]$Sb.Append('<p>Zero errors is not the same as full coverage: a subscription the account could not see, and a server with no diagnostic bundle, both produce silence rather than an error. Read this together with the coverage tables below.</p></div>')
        }
    } else {
        if ($errRows.Count -ne $gapKeys.Count) {
            $gapWord = 'actual gaps'
            if ($gapKeys.Count -eq 1) { $gapWord = 'actual gap' }
            [void]$Sb.Append("<p class=`"note`"><b>$($errRows.Count) rows, $($gapKeys.Count) $gapWord.</b> A metric failure is recorded twice - once as <code>metrics:&lt;target&gt;</code> and again as <code>metrics-nofilter:&lt;target&gt;</code>, because the exporter retries the same call without its dimension filter. The raw count overstates the damage.</p>")
        }
        $showErr = @($errRows | Select-Object -First 40)
        [void]$Sb.Append('<table class="tight"><thead><tr><th>Operation</th><th>Target</th><th>When (UTC)</th><th>Detail returned by ARM</th></tr></thead><tbody>')
        foreach ($er in $showErr) {
            $w = [string](Pv $er 'where' '')
            $op = $w; $tg = ''
            $ci = $w.IndexOf(':')
            if ($ci -ge 0) { $op = $w.Substring(0, $ci); $tg = $w.Substring($ci + 1) }
            [void]$Sb.Append("<tr><td class=`"mono`">$(E $op)</td><td class=`"mono res`">$(E $tg)</td><td class=`"mono`">$(E (Pv $er 'at' ''))</td><td><div class=`"det`">$(E (Pv $er 'detail' ''))</div></td></tr>")
        }
        [void]$Sb.Append('</tbody></table>')
        if ($errRows.Count -gt $showErr.Count) {
            [void]$Sb.Append("<p class=`"note`">$($errRows.Count - $showErr.Count) further row(s) are in <code>errors.json</code>.</p>")
        }

        [void]$Sb.Append('<h3>What each gap left hollow</h3>')
        [void]$Sb.Append('<p class="note">An error list is a log. This is the same list expressed as coverage: which file is empty because of it, and which checks therefore had nothing to read.</p>')
        [void]$Sb.Append('<table class="tight"><thead><tr><th>Gap</th><th>Left hollow</th><th>Checks that could not run</th></tr></thead><tbody>')
        foreach ($g in $gapKeys) {
            $op = $g; $tg = ''
            $ci = $g.IndexOf(':')
            if ($ci -ge 0) { $op = $g.Substring(0, $ci); $tg = $g.Substring($ci + 1) }
            $imp = GapImpact $op
            [void]$Sb.Append("<tr><td class=`"mono`">$(E $op)<br><span class=`"res`">$(E $tg)</span></td><td>$(E $imp[0])</td><td>$(E $imp[1])</td></tr>")
        }
        [void]$Sb.Append('</tbody></table>')
        [void]$Sb.Append('<p class="note">An HTTP 403 usually means the exporting account lacks Reader on that resource; an HTTP 400 usually means the resource does not publish what was asked for, which is a tool-side gap rather than a customer-side one. The full ARM response is in the table above so the difference can be judged rather than guessed.</p>')
    }
    if ($null -ne $mErrCount) {
        [void]$Sb.Append("<p class=`"note`">The manifest records <code>errorCount</code> = $(E $mErrCount); <code>errors.json</code> carries $($errRows.Count) row(s).</p>")
    }

    # ---- integrity ---------------------------------------------------------------------------
    [void]$Sb.Append('<h2>File integrity</h2>')
    if ($mFiles.Count -eq 0) {
        [void]$Sb.Append('<div class="card"><p><span class="pill warn">no hashes</span> <b>This export does not carry per-file hashes, so file integrity cannot be verified.</b> The manifest has an empty <code>files[]</code> array - nothing here proves the files are the ones the exporter wrote.</p>')
        [void]$Sb.Append("<p>What can still be said: the folder holds <b>$($allFiles.Count)</b> file(s) totalling <b>$(E (FmtBytes $diskBytes))</b>. That is a weaker substitute - it detects a truncated copy, not an edit.</p></div>")
    } else {
        $verdictPill = '<span class="pill ok">all files match</span>'
        if ($vMismatch -gt 0 -or $vMissing -gt 0) { $verdictPill = '<span class="pill no">does not verify</span>' }
        [void]$Sb.Append('<div class="card kv">')
        [void]$Sb.Append("<div class=`"k`">Verification</div><div>$verdictPill recomputed SHA-256 over every listed file</div>")
        [void]$Sb.Append("<div class=`"k`">Listed and matching</div><div><b>$vMatched</b> of $($mFiles.Count)</div>")
        [void]$Sb.Append("<div class=`"k`">Listed, content differs</div><div><b>$vMismatch</b></div>")
        [void]$Sb.Append("<div class=`"k`">Listed, not on disk</div><div><b>$vMissing</b></div>")
        [void]$Sb.Append("<div class=`"k`">Recorded size</div><div>$(E (FmtBytes $manifestBytes)) across $($mFiles.Count) files</div>")
        [void]$Sb.Append("<div class=`"k`">On disk now</div><div>$($allFiles.Count) files, $(E (FmtBytes $diskBytes))</div>")
        [void]$Sb.Append("<div class=`"k`">Outside the hashed set</div><div>$outByDesign file(s) by design - <code>manifest.json</code> cannot hash itself, and <code>servers/**</code> is dropped in by hand after the run</div>")
        [void]$Sb.Append("<div class=`"k`">Present but unlisted</div><div><b>$($unlisted.Count)</b> file(s) that are neither hashed nor expected to be</div>")
        [void]$Sb.Append('</div>')
        if ($vBad.Count -gt 0) {
            [void]$Sb.Append('<table class="tight"><thead><tr><th>File</th><th>State</th><th class="mono">Recorded</th><th class="mono">Recomputed</th></tr></thead><tbody>')
            foreach ($bd in @($vBad | Select-Object -First 25)) {
                [void]$Sb.Append("<tr><td class=`"mono res`">$(E $bd.path)</td><td>$(E $bd.state)</td><td class=`"mono res`">$(E $bd.want)</td><td class=`"mono res`">$(E $bd.got)</td></tr>")
            }
            [void]$Sb.Append('</tbody></table>')
            if ($vBad.Count -gt 25) { [void]$Sb.Append("<p class=`"note`">$($vBad.Count - 25) further row(s) not shown.</p>") }
        }
        if ($unlisted.Count -gt 0) {
            [void]$Sb.Append('<details><summary>' + $unlisted.Count + ' file(s) present but not in the manifest</summary><div class="card"><div class="res">')
            foreach ($u in @($unlisted | Select-Object -First 60)) { [void]$Sb.Append("$(E $u)<br>") }
            if ($unlisted.Count -gt 60) { [void]$Sb.Append("... and $($unlisted.Count - 60) more") }
            [void]$Sb.Append('</div></div></details>')
        }
        [void]$Sb.Append('<details><summary>Show the recorded hash list (' + $mFiles.Count + ' files)</summary><table class="tight"><thead><tr><th>File</th><th class="num">Bytes</th><th class="mono">SHA-256</th></tr></thead><tbody>')
        foreach ($fe in $mFiles) {
            if ($null -eq $fe) { continue }
            [void]$Sb.Append("<tr><td class=`"mono res`">$(E (Pv $fe 'path' ''))</td><td class=`"num`">$(E (Pv $fe 'bytes' 0))</td><td class=`"mono res`">$(E (Pv $fe 'sha256' ''))</td></tr>")
        }
        [void]$Sb.Append('</tbody></table></details>')
    }
    [void]$Sb.Append('<p class="note"><b>What the hashes cover.</b> Only the files the exporter wrote itself. <code>manifest.json</code> is not in its own list - it cannot hash itself - and nothing under <code>servers/</code> is either, because server bundles are collected separately and copied in afterwards. A bundle can therefore be swapped or edited without any hash noticing; the cloud-side files cannot.</p>')

    # ---- empty-file legend --------------------------------------------------------------------
    [void]$Sb.Append('<h2>Reading an empty file</h2>')
    [void]$Sb.Append('<p class="note">The single biggest misreading risk in an export. Three different things look like "nothing", and in this export most of them are evidence, not gaps.</p>')
    [void]$Sb.Append('<table class="tight"><thead><tr><th>Looks like</th><th class="num">Files</th><th>What it actually means</th></tr></thead><tbody>')
    [void]$Sb.Append("<tr><td class=`"mono`">0 bytes</td><td class=`"num`">$cZero</td><td>The call succeeded and returned an empty collection. PowerShell's <code>ConvertTo-Json @()</code> writes an empty string, so the file has no content at all. This is the normal shape of &quot;there are none&quot;.</td></tr>")
    [void]$Sb.Append("<tr><td class=`"mono`">[]</td><td class=`"num`">$cArr</td><td>Same meaning, written explicitly: ARM answered, the answer was an empty list.</td></tr>")
    [void]$Sb.Append("<tr><td class=`"mono`">null</td><td class=`"num`">$cNull</td><td>The call returned nothing usable <i>or</i> failed. Cross-check against the failed-call table above: a null with a matching error row is a gap; a null with no error row is a genuine absence.</td></tr>")
    [void]$Sb.Append("<tr><td class=`"mono`">{}</td><td class=`"num`">$cObj</td><td>An empty object - the resource exists but has no properties of the kind requested.</td></tr>")
    [void]$Sb.Append("<tr><td>populated</td><td class=`"num`">$cPop</td><td>Content present. Note that a populated file can still contain a null <i>key</i> - see the metrics table above.</td></tr>")
    [void]$Sb.Append('</tbody></table>')
    [void]$Sb.Append("<p class=`"note`"><b>$cEmptyTotal of $($cEmptyTotal + $cPop) JSON files in this export are empty in one of those three ways, against $($errRows.Count) failed call(s).</b> Empty is the normal case: no locks, no diagnostic settings, no private endpoints. Several checks fire precisely <i>because</i> a file is empty - presenting emptiness as a collection gap would invert those findings.</p>")

    # ---- server bundle coverage -----------------------------------------------------------------
    [void]$Sb.Append('<h2>Server-side coverage</h2>')
    if ($regServers.Count -eq 0 -and $bundles.Count -eq 0) {
        [void]$Sb.Append('<div class="card"><p>No File Sync servers are registered in this export, so server-side collection does not apply. An empty coverage table here is correct, not a gap.</p></div>')
    } else {
        if ($regServers.Count -eq 0) {
            [void]$Sb.Append('<div class="card"><p>No File Sync servers are registered in this export, so there is no coverage denominator to measure against. The bundle(s) below were collected anyway and are listed for completeness - nothing on the cloud side claims them.</p></div>')
        } elseif (-not $serversDirPresent) {
            [void]$Sb.Append("<div class=`"card`"><p><b>This export has no <code>servers/</code> directory, which is the normal state of a raw ARM export.</b> All $($regServers.Count) registered server(s) below were assessed from the cloud side only: the 11 server-side checks (SRV-01 to SRV-11) - filter-driver conflicts, agent service state, volume headroom, backup and anti-virus products, telemetry events, previous versions, time skew - did not run for any of them.</p>")
            [void]$Sb.Append('<p><b>Remedy:</b> run <code>Get-AfsServerDiagnostics.ps1</code> elevated on each host and drop the resulting zip under <code>servers\&lt;hostname&gt;\</code>, then re-run the assessor.</p></div>')
        } elseif ($covered -lt $regServers.Count) {
            [void]$Sb.Append("<div class=`"card`"><p><b>Bundles cover $covered of $($regServers.Count) registered servers.</b> For the other $($regServers.Count - $covered), the 11 server-side checks (SRV-01 to SRV-11) did not run - they are neither passing nor failing, they are unexamined. Run <code>Get-AfsServerDiagnostics.ps1</code> elevated on each and drop the zip under <code>servers\&lt;hostname&gt;\</code>.</p></div>")
        }
        [void]$Sb.Append('<table class="tight"><thead><tr><th>Registered server</th><th>Storage Sync Service</th><th>Bundle</th><th>Collected (UTC)</th><th>Clock skew vs export</th><th>Collector</th><th>Elevated</th></tr></thead><tbody>')
        foreach ($rs in $regServers) {
            $k = ([string]$rs.short).ToLower()
            $b = $null
            if ($k -and $bundleByHost.ContainsKey($k)) { $b = $bundleByHost[$k] }
            if ($null -eq $b) {
                [void]$Sb.Append("<tr><td>$(E $rs.disp)</td><td class=`"res`">$(E $rs.svc)</td><td><span class=`"pill no`">no bundle</span></td><td colspan=`"4`" class=`"ev`">SRV-01 to SRV-11 did not run for this server</td></tr>")
                continue
            }
            $bp2 = '<span class="pill ok">present</span>'
            if ($b.state -ne 'read') { $bp2 = '<span class="pill warn">' + (E $b.state) + '</span>' }
            $skew = ''
            if ($b.collected -and $exportedAt) { $skew = SpanText ($b.collected - $exportedAt) }
            $ep = '<span class="pill neutral">not recorded</span>'
            if ($b.elevated -eq $true) { $ep = '<span class="pill ok">yes</span>' }
            elseif ($b.elevated -eq $false) { $ep = '<span class="pill no">NO</span>' }
            $tv = '-'
            if ($b.toolVer) { $tv = 'v' + [string]$b.toolVer }
            [void]$Sb.Append("<tr><td>$(E $rs.disp)</td><td class=`"res`">$(E $rs.svc)</td><td>$bp2</td><td class=`"mono`">$(E $b.collectedRaw)</td><td class=`"mono`">$(E $skew)</td><td class=`"mono`">$(E $tv)</td><td>$ep</td></tr>")
        }
        # Bundles present in servers/ that no registered server claims.
        $claimed = @{}
        foreach ($rs in $regServers) { $claimed[([string]$rs.short).ToLower()] = $true }
        foreach ($b in $bundles) {
            $hk = ([string]$b.host).ToLower()
            if ($hk -and $claimed.ContainsKey($hk)) { continue }
            $tv2 = '-'
            if ($b.toolVer) { $tv2 = 'v' + [string]$b.toolVer }
            $ep2 = '<span class="pill neutral">not recorded</span>'
            if ($b.elevated -eq $true) { $ep2 = '<span class="pill ok">yes</span>' }
            elseif ($b.elevated -eq $false) { $ep2 = '<span class="pill no">NO</span>' }
            [void]$Sb.Append("<tr><td>$(E $b.host) <span class=`"pill warn`">not registered</span></td><td class=`"res`">-</td><td><span class=`"pill ok`">present</span></td><td class=`"mono`">$(E $b.collectedRaw)</td><td class=`"mono`"></td><td class=`"mono`">$(E $tv2)</td><td>$ep2</td></tr>")
        }
        [void]$Sb.Append('</tbody></table>')
        $zipped = @($bundles | Where-Object { $_.state -ne 'read' })
        if ($zipped.Count -gt 0) {
            [void]$Sb.Append("<p class=`"note`"><b>$($zipped.Count) bundle(s) are present but were not read</b> - the zip has not been expanded, so nothing inside it reached the assessor. Expand each <code>servers\&lt;host&gt;\*.zip</code> in place and re-run; the data is there, it is simply unopened.</p>")
        }
    }
    if ($readBundles.Count -gt 0) {
        [void]$Sb.Append('<p class="note"><b>Elevation matters.</b> Without an elevated collector the event logs, <code>fltmc</code> and the agent cmdlets return partial or empty results, so a clean server-side result can mean only that the collector could not see. <b>Clock skew matters too:</b> SRV-10 compares the agent version read on the server against the version the cloud has registered, and telemetry events are correlated with cloud sync status - both assume the two snapshots describe the same moment. A negative skew means the bundle was collected before the cloud export.</p>')
        $notElev = @($readBundles | Where-Object { $_.elevated -eq $false })
        if ($notElev.Count -gt 0) {
            $names = @($notElev | ForEach-Object { [string]$_.host })
            [void]$Sb.Append("<div class=`"card`"><p><span class=`"pill no`">not elevated</span> <b>$(E ($names -join ', '))</b> - treat every clean SRV-* result for these hosts as unproven rather than passing.</p></div>")
        }
    }

    # ---- bundle collection errors ------------------------------------------------------------
    if ($readBundles.Count -gt 0) {
        [void]$Sb.Append('<h3>Collection failures inside the server bundles</h3>')
        [void]$Sb.Append('<p class="note">The assessor reads system, services, volumes, programs, the sync digest, telemetry, self-service restore and the debug text files from each bundle - but never opens the bundle''s own <code>errors.json</code>. These failures reach no finding anywhere else in the report. Note there is no timestamp: unlike the cloud error log, the per-host collector records only <code>where</code> and <code>detail</code>.</p>')
        if ($bundleErrTotal -eq 0) {
            [void]$Sb.Append("<div class=`"card`"><p><span class=`"pill ok`">clean</span> No collection failures were recorded inside the $($readBundles.Count) bundle(s) read.</p></div>")
        } else {
            [void]$Sb.Append('<table class="tight"><thead><tr><th>Host</th><th>Collector step</th><th>Detail</th></tr></thead><tbody>')
            foreach ($b in $readBundles) {
                foreach ($be in @($b.errors | Select-Object -First 30)) {
                    [void]$Sb.Append("<tr><td>$(E $b.host)</td><td class=`"mono`">$(E (Pv $be 'where' ''))</td><td><div class=`"det`">$(E (Pv $be 'detail' ''))</div></td></tr>")
                }
            }
            [void]$Sb.Append('</tbody></table>')
        }
        $anyBad = @($readBundles | Where-Object { (CountOf $_.badDebug) -gt 0 })
        if ($anyBad.Count -gt 0) {
            [void]$Sb.Append('<div class="card"><p><b>A collection failure can masquerade as a server failure.</b> The collector writes <code>ERROR: &lt;exception&gt;</code> into the debug text file when a cmdlet cannot run, and SRV-08 then matches on the words "fail" or "error" in that same text. The following files start with such a line, so cross-check them against the bundle errors above before presenting SRV-08 as a server-side defect:</p><div class="res">')
            foreach ($b in $anyBad) {
                foreach ($bd in $b.badDebug) { [void]$Sb.Append("$(E $b.host) / $(E $bd)<br>") }
            }
            [void]$Sb.Append('</div></div>')
        }

        # ---- bundle artifact matrix -------------------------------------------------------------
        [void]$Sb.Append('<h3>What each bundle actually contains</h3>')
        [void]$Sb.Append('<p class="note">An absent artifact silences a check without recording an error anywhere. This matrix is the only place that absence is visible.</p>')
        $cols = @($readBundles | Select-Object -First 8)
        [void]$Sb.Append('<table class="tight"><thead><tr><th>Artifact</th>')
        foreach ($c in $cols) { [void]$Sb.Append("<th>$(E $c.host)</th>") }
        [void]$Sb.Append('<th>If absent</th></tr></thead><tbody>')
        foreach ($a in $bundleArtifacts) {
            [void]$Sb.Append("<tr><td class=`"mono`">$(E $a.n)</td>")
            foreach ($c in $cols) {
                $has = $false
                try { if ($c.present.ContainsKey($a.f)) { $has = [bool]$c.present[$a.f] } } catch { $has = $false }
                if ($has) { [void]$Sb.Append('<td><span class="pill ok">yes</span></td>') }
                else { [void]$Sb.Append('<td><span class="pill neutral">-</span></td>') }
            }
            [void]$Sb.Append("<td>$(E $a.w)</td></tr>")
        }
        [void]$Sb.Append('<tr><td class="mono">afsdiag/</td>')
        foreach ($c in $cols) {
            if ($c.afsdiag) { [void]$Sb.Append('<td><span class="pill ok">yes</span></td>') }
            else { [void]$Sb.Append('<td><span class="pill neutral">-</span></td>') }
        }
        [void]$Sb.Append('<td>optional - only collected when the collector ran with -CollectAfsDiag</td></tr>')
        [void]$Sb.Append('</tbody></table>')
        if ($readBundles.Count -gt $cols.Count) {
            [void]$Sb.Append("<p class=`"note`">$($readBundles.Count - $cols.Count) further bundle(s) not shown.</p>")
        }
    }

    # ---- counts reconciliation -------------------------------------------------------------------
    [void]$Sb.Append('<h2>Counts against what is on disk</h2>')
    [void]$Sb.Append('<p class="note">The manifest says what the exporter counted; the middle column is what this report found by walking the folder. Where they differ, the folder wins - and a count of zero next to a present file is the difference between "nothing found" and "nothing collected".</p>')
    if ($null -eq $countsObj) {
        [void]$Sb.Append('<div class="card"><p>The manifest records no <code>counts</code> block, so there is nothing to reconcile against.</p></div>')
    } else {
        $cps = @()
        try { $cps = @($countsObj.PSObject.Properties) } catch { $cps = @() }
        [void]$Sb.Append('<table class="tight"><thead><tr><th>Resource</th><th class="num">manifest.counts</th><th class="num">on disk</th><th class="num">inventory.json</th><th></th></tr></thead><tbody>')
        foreach ($pr in $cps) {
            $nm = [string]$pr.Name
            $mv = $pr.Value
            $ov = '-'
            if ($obs.ContainsKey($nm)) { $ov = [string]$obs[$nm] }
            $iv = '-'
            if ($invCounts.ContainsKey($nm)) { $iv = [string]$invCounts[$nm] }
            $flag = ''
            if ($obs.ContainsKey($nm)) {
                $same = $false
                try { $same = ([int]$mv -eq [int]$obs[$nm]) } catch { $same = $false }
                if (-not $same) { $flag = '<span class="pill warn">differs</span>' }
            }
            $label = ($nm -creplace '([a-z])([A-Z])', '$1 $2').ToLower()
            [void]$Sb.Append("<tr><td>$(E $label)</td><td class=`"num`">$(E $mv)</td><td class=`"num`">$(E $ov)</td><td class=`"num`">$(E $iv)</td><td>$flag</td></tr>")
        }
        [void]$Sb.Append('</tbody></table>')
    }

    # ---- api versions ------------------------------------------------------------------------------
    [void]$Sb.Append('<h2>API versions used</h2>')
    $avProps = @()
    if ($null -ne $apiVers) { try { $avProps = @($apiVers.PSObject.Properties) } catch { $avProps = @() } }
    if ($avProps.Count -eq 0) {
        [void]$Sb.Append('<div class="card"><p><span class="pill warn">not recorded by this tool version</span> This export does not list the ARM API versions it queried. That absence is itself provenance: without it, a finding cannot be reproduced exactly two years from now, and a shape difference between two exports of the same estate cannot be attributed to a tooling change rather than a real change.</p></div>')
    } else {
        [void]$Sb.Append('<details><summary>' + $avProps.Count + ' provider API versions - what makes a finding reproducible later</summary><table class="tight"><thead><tr><th>Provider</th><th class="mono">API version</th></tr></thead><tbody>')
        foreach ($pr in $avProps) {
            [void]$Sb.Append("<tr><td>$(E $pr.Name)</td><td class=`"mono`">$(E $pr.Value)</td></tr>")
        }
        [void]$Sb.Append('</tbody></table></details>')
    }

    # ---- what the export cannot tell you --------------------------------------------------------
    [void]$Sb.Append('<h2>What this export cannot tell you</h2>')
    [void]$Sb.Append('<div class="card"><ul>')
    [void]$Sb.Append('<li><b>When the run started, or how long it took.</b> Only the end stamp is recorded. On a large estate the earliest data can be materially older than the label, which silently widens every "at export time" comparison. On a small estate the measured drift is about half a minute; nobody has measured it on a large one.</li>')
    [void]$Sb.Append('<li><b>Which subscriptions were never seen.</b> Not enabled, another tenant, or no Reader - all three are indistinguishable from "does not exist", and none of them writes an error row.</li>')
    [void]$Sb.Append('<li><b>The server bundle''s own parameters.</b> It records no event lookback (the default is 7 days, inferable only from the oldest event in the file), no file-sampling cap, and no manifest or hashes of its own. Its only provenance is <code>system.json</code> plus the timestamp in its folder name.</li>')
    [void]$Sb.Append('<li><b>Anything that changed after the export.</b> Every conclusion in this report is a statement about the moment above, not about now.</li>')
    [void]$Sb.Append('</ul></div>')

    # ---- scope of the read -----------------------------------------------------------------------
    [void]$Sb.Append('<h2>Scope of the read</h2>')
    [void]$Sb.Append('<div class="card"><p><b>Every call was an ARM GET.</b> Nothing was created, changed or deleted, and no file content was read - the export describes configuration, not data.</p>')
    [void]$Sb.Append('<p><b>No secrets were requested.</b> Storage account keys, SAS tokens, connection strings and certificates were never fetched. On top of that the exporter runs a redaction pass before writing, blanking well-known secret field names - <code>serverCertificate</code>, <code>primaryKey</code>, <code>secondaryKey</code>, <code>connectionString</code>, <code>sasToken</code>, <code>accessToken</code>, <code>password</code>, <code>clientSecret</code>, <code>sharedKey</code>, <code>primaryMasterKey</code>, <code>keys</code> - to <code>[REDACTED]</code>. This is why the export can be handed to a third party for assessment.</p>')
    [void]$Sb.Append('<p><b>The server bundles are read-only too</b> - service state, event logs, volume free space, installed programs and the agent''s own diagnostic cmdlets. They do not enumerate or read user files.</p></div>')

    [void]$Sb.Append('</section>')
}
