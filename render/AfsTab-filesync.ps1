function Add-AfsTabFileSync {
    <#
      Evidence tab: the Azure File Sync estate exactly as the export recorded it.
      Storage Sync Services, sync groups, cloud endpoints, server endpoints, registered
      servers, cloud tiering policy and sync health - measured values only. The Findings
      tab owns the verdicts; this tab is what those verdicts were computed from.
      Every age in here is relative to manifest.exportedAtUtc, never to the reader's clock.
    #>
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
        [string]$ExportRoot
    )

    # ---------------------------------------------------------------- helpers --
    function E { param($v) if ($null -eq $v) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$v) }
    function Pv {
        param($Obj, [string]$Name, $Default = $null)
        if ($null -eq $Obj) { return $Default }
        try { $p = $Obj.PSObject.Properties[$Name]; if ($p -and $null -ne $p.Value) { return $p.Value } } catch { }
        return $Default
    }
    function HasP { param($Obj, [string]$Name) if ($null -eq $Obj) { return $false }; try { return (@($Obj.PSObject.Properties.Name) -contains $Name) } catch { return $false } }
    function LoadJ {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $t = $null
        try { $t = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue } catch { return $null }
        if ($null -eq $t) { return $null }
        $t = [string]$t
        if ($t.Length -gt 0 -and [int][char]$t[0] -eq 65279) { $t = $t.Substring(1) }
        if ([string]::IsNullOrWhiteSpace($t)) { return $null }
        if ($t.Trim() -eq 'null') { return $null }
        try { return ($t | ConvertFrom-Json) } catch { return $null }
    }
    function LoadA { param([string]$Path) $o = LoadJ $Path; if ($null -eq $o) { return ,@() } return ,@($o) }
    function AsA  { param($o) if ($null -eq $o) { return ,@() } return ,@($o) }
    function LoadT {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $t = $null
        try { $t = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue } catch { return '' }
        if ($null -eq $t) { return '' }
        return [string]$t
    }
    function ToDate {
        param($s)
        if ($null -eq $s) { return $null }
        if ([string]::IsNullOrWhiteSpace([string]$s)) { return $null }
        try { return [datetime]::Parse([string]$s, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { return $null }
    }
    function Num {
        param($v)
        if ($null -eq $v) { return $null }
        $d = 0.0
        if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Any, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
        return $null
    }
    function Nm { param($v, [int]$dp = 1) $d = Num $v; if ($null -eq $d) { return '' } return $d.ToString('F' + $dp, [cultureinfo]::InvariantCulture) }
    function Sz {
        param($v)
        $d = Num $v
        if ($null -eq $d) { return '-' }
        $u = 'B'; $x = $d; $dp = 0
        if     ([math]::Abs($d) -ge 1125899906842624.0) { $x = $d / 1125899906842624.0; $u = 'PiB'; $dp = 2 }
        elseif ([math]::Abs($d) -ge 1099511627776.0)    { $x = $d / 1099511627776.0;    $u = 'TiB'; $dp = 2 }
        elseif ([math]::Abs($d) -ge 1073741824.0)       { $x = $d / 1073741824.0;       $u = 'GiB'; $dp = 1 }
        elseif ([math]::Abs($d) -ge 1048576.0)          { $x = $d / 1048576.0;          $u = 'MiB'; $dp = 1 }
        elseif ([math]::Abs($d) -ge 1024.0)             { $x = $d / 1024.0;             $u = 'KiB'; $dp = 1 }
        return ($x.ToString('F' + $dp, [cultureinfo]::InvariantCulture) + ' ' + $u)
    }
    function Cnt { param($v) $d = Num $v; if ($null -eq $d) { return '-' } return $d.ToString('N0', [cultureinfo]::InvariantCulture) }
    function AgeTxt {
        param($stamp, $RefDate)
        $d = ToDate $stamp
        if ($null -eq $d -or $null -eq $RefDate) { return '' }
        $ref = [datetime]$RefDate
        $past = $true; $ts = $ref - $d
        if ($ts.Ticks -lt 0) { $past = $false; $ts = $d - $ref }
        $s = ''
        if ($ts.TotalDays -ge 1)      { $s = ([int][math]::Floor($ts.TotalDays)).ToString() + ' d ' + $ts.Hours.ToString() + ' h' }
        elseif ($ts.TotalHours -ge 1) { $s = ([int][math]::Floor($ts.TotalHours)).ToString() + ' h ' + $ts.Minutes.ToString() + ' m' }
        else                          { $s = ([int][math]::Floor($ts.TotalMinutes)).ToString() + ' min' }
        if ($past) { return ($s + ' before export') }
        return ('in ' + $s)
    }
    # Whole calendar days between the export date and a stamp - dates, not hours, so an
    # expiry on the 15th against an export on the 3rd reads as 12 days and not 11.
    function DaysFrom { param($stamp, $RefDate) $d = ToDate $stamp; if ($null -eq $d -or $null -eq $RefDate) { return $null } return [int][math]::Round(($d.Date - ([datetime]$RefDate).Date).TotalDays) }
    function Leaf { param([string]$id) if ([string]::IsNullOrWhiteSpace($id)) { return '' } return ($id.Split('/')[-1]) }
    function ShortHost { param([string]$n) if ([string]::IsNullOrWhiteSpace($n)) { return '' } return ($n.Split('.')[0].ToLower()) }
    function DriveOf { param([string]$p) if ([string]::IsNullOrWhiteSpace($p)) { return '' } if ($p -match '^([A-Za-z]):') { return ($Matches[1].ToUpper() + ':') } return '' }
    function IsUnder {
        param([string]$parent, [string]$child)
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($child)) { return $false }
        $p = $parent.TrimEnd('\'); $c = $child.TrimEnd('\')
        if ($p.ToLower() -eq $c.ToLower()) { return $false }
        return $c.ToLower().StartsWith($p.ToLower() + '\')
    }
    function Trunc { param([string]$s, [int]$n) if ([string]::IsNullOrEmpty($s)) { return '' } if ($s.Length -le $n) { return $s } return ($s.Substring(0, [math]::Max(1, $n - 1)) + '...') }
    function Truthy { param($v) $s = ([string]$v).Trim().ToLower(); return ($s -eq 'true' -or $s -eq '1' -or $s -eq 'yes' -or $s -eq 'on') }
    function Pill { param([string]$text, [string]$kind) $k = 'afs-pill'; if ($kind) { $k = 'afs-pill ' + $kind } return ('<span class="' + $k + '">' + (E $text) + '</span>') }
    function Bar {
        param($pct, [string]$label, [switch]$Hot)
        $d = Num $pct; if ($null -eq $d) { $d = 0.0 }
        if ($d -lt 0) { $d = 0.0 }
        if ($d -gt 100) { $d = 100.0 }
        $c = 'afs-bar'; if ($Hot) { $c = 'afs-bar hot' }
        return ('<span class="' + $c + '"><i style="width:' + $d.ToString('F1', [cultureinfo]::InvariantCulture) + '%"></i><b>' + (E $label) + '</b></span>')
    }
    # Signed 32-bit HResults are the export's native form; Microsoft's sync-error tables are
    # indexed by the unsigned hex, so always render decimal -> hex -> name.
    $hrNames = @{
        '0x00000000' = 'S_OK - the session completed'
        '0x80070005' = 'ERROR_ACCESS_DENIED'
        '0x80070020' = 'ERROR_SHARING_VIOLATION - file held open'
        '0x80070070' = 'ERROR_DISK_FULL'
        '0x80070079' = 'ERROR_SEM_TIMEOUT'
        '0x8007007B' = 'ERROR_INVALID_NAME - unsupported character or path'
        '0x800704C7' = 'ERROR_CANCELLED'
        '0x800705B4' = 'ERROR_TIMEOUT'
        '0x80072EE2' = 'WININET_E_TIMEOUT - network timeout'
        '0x80C80203' = 'ECS_E_SYNC_METADATA_KNOWLEDGE_SOFT_LIMIT_REACHED'
        '0x80C80207' = 'ECS_E_SYNC_CONSTRAINT_CONFLICT'
        '0x80C8305F' = 'ECS_E_AZURE_FILE_SHARE_SIZE_LIMIT_REACHED - share is full'
    }
    function HrHex {
        param($v)
        if ($null -eq $v) { return '' }
        if ([string]::IsNullOrWhiteSpace([string]$v)) { return '' }
        $l = [int64]0
        if (-not [int64]::TryParse([string]$v, [System.Globalization.NumberStyles]::Any, [cultureinfo]::InvariantCulture, [ref]$l)) { return '' }
        $u = $l -band 0xFFFFFFFFL
        return ('0x' + $u.ToString('X8'))
    }
    function HrHtml {
        param($v)
        $hex = HrHex $v
        if (-not $hex) { if ($null -eq $v) { return '<span class="afs-note">not reported</span>' } return (E $v) }
        $name = ''
        if ($hrNames.ContainsKey($hex)) { $name = $hrNames[$hex] }
        $out = '<span class="mono">' + (E ([string]$v)) + '</span> <span class="afs-note">-&gt;</span> <b class="mono">' + (E $hex) + '</b>'
        if ($name) { $out += '<br><span class="afs-note">' + (E $name) + '</span>' }
        elseif ($hex -ne '0x00000000') { $out += '<br><span class="afs-note">not in the decoder table - look this hex up in the File Sync error reference</span>' }
        return $out
    }
    function OsName {
        param([string]$v)
        if ([string]::IsNullOrWhiteSpace($v)) { return '' }
        if ($v -like '10.0.26100*') { return 'Windows Server 2025' }
        if ($v -like '10.0.25398*') { return 'Windows Server 23H2' }
        if ($v -like '10.0.20348*') { return 'Windows Server 2022' }
        if ($v -like '10.0.17763*') { return 'Windows Server 2019' }
        if ($v -like '10.0.14393*') { return 'Windows Server 2016' }
        if ($v -like '6.3.*')       { return 'Windows Server 2012 R2' }
        if ($v -like '6.2.*')       { return 'Windows Server 2012' }
        if ($v -like '6.1.*')       { return 'Windows Server 2008 R2' }
        return ''
    }
    function Marked {
        param([string]$text)
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }
        $enc = [System.Net.WebUtility]::HtmlEncode($text)
        return ([regex]::Replace($enc, '(?i)(error|failed|failure|fail|expires|expired|denied|timeout|timed out|skew|unable|warning|not\s+found)', '<b>$0</b>'))
    }

    # ------------------------------------------------------------ open section --
    [void]$Sb.Append('<section class="tab" id="tab-filesync">')
    [void]$Sb.Append(@'
<style>
#tab-filesync .afs-lede{color:var(--muted);max-width:88ch;margin:0 0 14px}
#tab-filesync .afs-pill{display:inline-block;padding:2px 9px;border-radius:20px;font-size:12px;font-weight:600;white-space:nowrap;background:var(--surface-3);color:var(--muted);margin:2px 4px 2px 0}
#tab-filesync .afs-pill.ok{background:var(--good-soft);color:var(--good)}
#tab-filesync .afs-pill.bad{background:var(--crit-soft);color:var(--crit)}
#tab-filesync .afs-pill.warn{background:var(--warn-soft);color:var(--warn)}
#tab-filesync .afs-pill.off{background:var(--surface-3);color:var(--faint)}
#tab-filesync .afs-note{color:var(--muted);font-size:12px}
#tab-filesync .afs-flag{color:var(--crit);font-size:12px;font-weight:600}
#tab-filesync .mono{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px}
#tab-filesync .afs-bar{position:relative;display:inline-block;height:15px;min-width:120px;width:100%;max-width:190px;background:var(--surface-3);border-radius:8px;overflow:hidden;vertical-align:middle}
#tab-filesync .afs-bar i{position:absolute;left:0;top:0;bottom:0;background:var(--accent);opacity:.5}
#tab-filesync .afs-bar.hot i{background:var(--crit);opacity:.55}
#tab-filesync .afs-bar b{position:absolute;left:0;right:0;top:0;bottom:0;text-align:center;line-height:15px;font-size:11px;font-family:"IBM Plex Mono",Consolas,monospace;color:var(--ink)}
#tab-filesync pre.afs-pre{background:var(--surface-3);border:1px solid var(--line);border-radius:6px;padding:10px 12px;margin:6px 0 12px;font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px;white-space:pre-wrap;word-break:break-word;color:var(--ink)}
#tab-filesync pre.afs-pre b{color:var(--crit)}
#tab-filesync .afs-scroll{overflow-x:auto;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:12px;margin:6px 0 16px}
#tab-filesync .afs-scroll svg{display:block;min-width:840px;width:100%;height:auto}
#tab-filesync tr.hollow td{color:var(--faint);font-style:italic}
#tab-filesync .afs-sub{color:var(--muted);font-size:12px;font-weight:400}
#tab-filesync .afs-two{display:grid;grid-template-columns:1fr 1fr;gap:12px}
#tab-filesync .sv-t{fill:var(--ink);font-family:"Segoe UI",system-ui,sans-serif;font-size:11px}
#tab-filesync .sv-tb{fill:var(--ink);font-family:"Segoe UI",system-ui,sans-serif;font-size:12px;font-weight:600}
#tab-filesync .sv-tm{fill:var(--muted);font-family:"IBM Plex Mono",Consolas,monospace;font-size:10px}
#tab-filesync .sv-th{fill:var(--faint);font-family:"Segoe UI",system-ui,sans-serif;font-size:10px;letter-spacing:.06em;text-transform:uppercase}
#tab-filesync .sv-svc{fill:var(--info-soft);stroke:var(--accent);stroke-width:1.5}
#tab-filesync .sv-lane{fill:var(--surface-2);stroke:var(--line);stroke-width:1}
#tab-filesync .sv-lane-warn{stroke:var(--warn);stroke-width:1.5}
#tab-filesync .sv-lane-none{fill:none;stroke:var(--faint);stroke-width:1.5;stroke-dasharray:7 5}
#tab-filesync .sv-card{fill:var(--surface);stroke:var(--line);stroke-width:1}
#tab-filesync .sv-card-err{fill:var(--crit-soft);stroke:var(--crit);stroke-width:2}
#tab-filesync .sv-card-child{fill:var(--surface-3);stroke:var(--warn);stroke-width:1.5;stroke-dasharray:5 3}
#tab-filesync .sv-cyl{fill:var(--surface);stroke:var(--accent);stroke-width:1.5}
#tab-filesync .sv-cylfill{fill:var(--accent);opacity:.22}
#tab-filesync .sv-cylfill.hot{fill:var(--crit);opacity:.3}
#tab-filesync .sv-edge{fill:none;stroke:var(--accent);opacity:.8}
#tab-filesync .sv-edge-stale{fill:none;stroke:var(--faint);stroke-dasharray:5 4}
#tab-filesync .sv-arr{fill:var(--accent)}
#tab-filesync .sv-arr-stale{fill:var(--faint)}
#tab-filesync .sv-badge{fill:var(--good-soft);stroke:var(--good);stroke-width:1}
#tab-filesync .sv-badge-off{fill:none;stroke:var(--faint);stroke-width:1;stroke-dasharray:4 3}
#tab-filesync .sv-ann{fill:none;stroke:var(--muted);stroke-width:1;stroke-dasharray:2 4;opacity:.6}
#tab-filesync .sv-pat-bg{fill:var(--warn-soft)}
#tab-filesync .sv-pat-fg{fill:var(--warn);opacity:.22}
#tab-filesync .sv-hat-bg{fill:var(--surface-3)}
#tab-filesync .sv-hat-fg{fill:var(--faint);opacity:.55}
#tab-filesync .sv-spark{fill:var(--accent);opacity:.55}
#tab-filesync .sv-spark.hot{fill:var(--crit);opacity:.6}
#tab-filesync .sv-axis{stroke:var(--line)}
@media(max-width:900px){#tab-filesync .afs-two{grid-template-columns:1fr}}
</style>
'@)

    try {
        $root = $ExportRoot
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
            [void]$Sb.Append('<h2>Azure File Sync</h2><div class="card"><p>No export folder was supplied to the renderer, so there is nothing to show here. Pass <code>-ExportRoot</code> pointing at the folder produced by <code>Export-AzFileSyncEnvironment.ps1</code>.</p></div>')
        } else {
            $manifest   = LoadJ (Join-Path $root 'manifest.json')
            $inventory  = LoadJ (Join-Path $root 'inventory.json')
            $expErrors  = LoadA (Join-Path $root 'errors.json')
            $coverage   = LoadA (Join-Path $root 'backup\share-coverage.json')
            $exportedAt = ToDate (Pv $manifest 'exportedAtUtc')
            $exportedTx = [string](Pv $manifest 'exportedAtUtc' 'not recorded in the manifest')
            $counts     = Pv $manifest 'counts'
            $subs       = AsA (Pv $manifest 'subscriptions')
            $metricsSkipped = Truthy (Pv $manifest 'metricsSkipped' $false)
            $invSvcs    = AsA (Pv $inventory 'storageSyncServices')

            # storage accounts, indexed by resource id and by name
            $accById = @{}; $accByName = @{}
            $stRoot = Join-Path $root 'storage'
            if (Test-Path -LiteralPath $stRoot) {
                foreach ($d in @(Get-ChildItem -LiteralPath $stRoot -Directory -ErrorAction SilentlyContinue)) {
                    $acct = LoadJ (Join-Path $d.FullName 'account.json')
                    if ($null -eq $acct) { continue }
                    $shf = LoadJ (Join-Path $d.FullName 'shares.json')
                    $rec = [pscustomobject]@{
                        dir         = $d.Name
                        account     = $acct
                        id          = [string](Pv $acct 'id' '')
                        name        = [string](Pv $acct 'name' $d.Name)
                        location    = [string](Pv $acct 'location' '')
                        props       = (Pv $acct 'properties')
                        shares      = (AsA (Pv $shf 'shares'))
                        softDeleted = (AsA (Pv $shf 'softDeleted'))
                        fileService = (LoadJ (Join-Path $d.FullName 'fileservice.json'))
                    }
                    if ($rec.id)   { $accById[$rec.id.ToLower()] = $rec }
                    if ($rec.name) { $accByName[$rec.name.ToLower()] = $rec }
                }
            }
            # backup coverage, keyed "<account>/<share>"
            $covIdx = @{}
            foreach ($c in $coverage) {
                $k = (([string](Pv $c 'storageAccount' '')) + '/' + ([string](Pv $c 'share' ''))).ToLower()
                if ($k -ne '/') { $covIdx[$k] = $c }
            }
            # server diagnostic bundles, keyed on the SHORT hostname (lowercased)
            $bundles = @{}
            $srvRoot = Join-Path $root 'servers'
            if (Test-Path -LiteralPath $srvRoot) {
                foreach ($d in @(Get-ChildItem -LiteralPath $srvRoot -Directory -ErrorAction SilentlyContinue)) {
                    $sysf = @(Get-ChildItem -LiteralPath $d.FullName -Filter 'system.json' -Recurse -ErrorAction SilentlyContinue) | Select-Object -First 1
                    if ($null -eq $sysf) { continue }
                    $bd  = Split-Path $sysf.FullName -Parent
                    $sys = LoadJ $sysf.FullName
                    $hn  = [string](Pv $sys 'hostname' $d.Name)
                    $key = ShortHost $hn
                    if (-not $key) { $key = $d.Name.ToLower() }
                    $bundles[$key] = [pscustomobject]@{
                        dir       = $bd
                        folder    = $d.Name
                        hostname  = $hn
                        system    = $sys
                        services  = (LoadJ (Join-Path $bd 'services.json'))
                        volumes   = (LoadJ (Join-Path $bd 'volumes.json'))
                        programs  = (LoadJ (Join-Path $bd 'programs.json'))
                        digest    = (LoadA (Join-Path $bd 'sync-session-digest.json'))
                        telemetry = (LoadA (Join-Path $bd 'events-telemetry.json'))
                        oplog     = (LoadA (Join-Path $bd 'events-operational.json'))
                        ssr       = (LoadA (Join-Path $bd 'selfservicerestore.json'))
                        smb       = (LoadA (Join-Path $bd 'smbshares.json'))
                        berrors   = (LoadA (Join-Path $bd 'errors.json'))
                        diagnose  = (LoadT (Join-Path $bd 'debug-diagnose.txt'))
                        netTxt    = (LoadT (Join-Path $bd 'debug-network.txt'))
                        errTxt    = (LoadT (Join-Path $bd 'debug-filesyncerrors.txt'))
                        w32tm     = (LoadT (Join-Path $bd 'w32tm.txt'))
                        proxy     = (LoadT (Join-Path $bd 'winhttp-proxy.txt'))
                        fltmc     = (LoadT (Join-Path $bd 'fltmc.txt'))
                    }
                }
            }
            $usedBundles = @{}

            # Storage Sync Service folders
            $svcDirs = @()
            $ssRoot = Join-Path $root 'storagesync'
            if (Test-Path -LiteralPath $ssRoot) { $svcDirs = @(Get-ChildItem -LiteralPath $ssRoot -Directory -ErrorAction SilentlyContinue) }

            [void]$Sb.Append('<h2>Azure File Sync</h2>')
            [void]$Sb.Append('<p class="afs-lede">What the estate actually contains, as recorded at <code>' + (E $exportedTx) + '</code>. <b>Every age, expiry and staleness figure on this tab is measured against that export timestamp, not against today</b> - a heartbeat that was two days old at export time stays two days old however long ago the export was taken. Values are shown as the export holds them; the Findings tab decides what they mean.</p>')

            if ($svcDirs.Count -eq 0 -and $invSvcs.Count -eq 0) {
                # ---- empty state 1: there is no File Sync in this estate ------------
                $subTxt = 'the exported subscription(s)'
                if ($subs.Count -gt 0) {
                    $names = @()
                    foreach ($s in $subs) { $n = [string](Pv $s 'name' (Pv $s 'id' '')); if ($n) { $names += $n } }
                    if ($names.Count -gt 0) { $subTxt = ($subs.Count.ToString() + ' subscription(s): ' + ($names -join ', ')) }
                }
                [void]$Sb.Append('<div class="card"><p><b>No Storage Sync Service was found.</b> The export covered ' + (E $subTxt) + ' at <code>' + (E $exportedTx) + '</code>, and it contains no <code>storagesync/</code> data and no <code>storageSyncServices</code> entries in <code>inventory.json</code>.</p>')
                [void]$Sb.Append('<p>This estate is not caching any Azure file share on a Windows server. There are no sync groups, no server endpoints, no cloud tiering and no registered servers to assess - so for any Azure file shares that do exist, the backup story is the whole protection story, and it is on the backup tabs of this report, not here.</p>')
                [void]$Sb.Append('<p class="afs-note">This is a stated negative, not a gap in the export. If File Sync is expected, confirm the export ran against the subscription that holds the Storage Sync Service and that the account had Reader on it.</p></div>')

                $nonSync = @($coverage | Where-Object { -not (Truthy (Pv $_ 'azureFileSync' $false)) })
                if ($nonSync.Count -gt 0) {
                    [void]$Sb.Append('<h3>Azure file shares in the export, none of them a File Sync hub <span class="afs-sub">(' + (E $nonSync.Count) + ' from backup/share-coverage.json)</span></h3>')
                    [void]$Sb.Append('<table><thead><tr><th>Subscription</th><th>Storage account</th><th>Share</th><th>File Sync</th><th>Backup</th><th>Vault / policy</th><th>Last backup</th></tr></thead><tbody>')
                    foreach ($c in $nonSync) {
                        $prot = Truthy (Pv $c 'protected' $false)
                        $pp = Pill 'not backed up' 'off'
                        if ($prot) { $pp = Pill ([string](Pv $c 'protectionState' 'Protected')) 'ok' }
                        $vt = [string](Pv $c 'vault' '')
                        $po = [string](Pv $c 'policy' '')
                        $vp = '<span class="afs-note">none</span>'
                        if ($vt -or $po) { $vp = (E $vt) + ' / ' + (E $po) }
                        [void]$Sb.Append('<tr><td>' + (E (Pv $c 'subscription' '')) + '</td><td class="mono">' + (E (Pv $c 'storageAccount' '')) + '</td><td class="mono">' + (E (Pv $c 'share' '')) + '</td><td>' + (Pill 'no' 'off') + '</td><td>' + $pp + '</td><td>' + $vp + '</td><td>' + (E (Pv $c 'lastBackupStatus' '-')) + '</td></tr>')
                    }
                    [void]$Sb.Append('</tbody></table>')
                    [void]$Sb.Append('<p class="afs-note">Listed here because "no File Sync" is a scoping fact: these shares are cloud-only, so nothing recalls them and nothing caches them, and their protection is decided entirely by Azure Backup for Azure Files.</p>')
                } elseif ($coverage.Count -eq 0) {
                    [void]$Sb.Append('<p class="afs-note">The export did not include <code>backup/share-coverage.json</code>, so the file shares that exist without File Sync cannot be listed here.</p>')
                }
            } else {
                # ---- scope strip ---------------------------------------------------
                $tileDefs = @(
                    @{ l = 'Sync services';    k = 'storageSyncServices' },
                    @{ l = 'Sync groups';      k = 'syncGroups' },
                    @{ l = 'Cloud endpoints';  k = 'cloudEndpoints' },
                    @{ l = 'Server endpoints'; k = 'serverEndpoints' },
                    @{ l = 'Registered srv';   k = 'registeredServers' },
                    @{ l = 'Server bundles';   k = '' }
                )
                [void]$Sb.Append('<div class="tiles" style="grid-template-columns:repeat(6,1fr)">')
                foreach ($t in $tileDefs) {
                    $v = ''
                    if ($t.k) { $v = [string](Pv $counts $t.k '-') } else { $v = [string]$bundles.Count }
                    [void]$Sb.Append('<div class="tile"><div class="n">' + (E $v) + '</div><div class="l">' + (E $t.l) + '</div></div>')
                }
                [void]$Sb.Append('</div>')

                if ($svcDirs.Count -eq 0) {
                    [void]$Sb.Append('<div class="card"><p><b>The inventory names a Storage Sync Service, but the export has no <code>storagesync/</code> folder for it.</b> Only the inventory row can be shown; sync groups, endpoints, registered servers, tiering policy and sync health were not collected.</p>')
                    [void]$Sb.Append('<table><thead><tr><th>Name</th><th>Location</th><th>Subscription</th><th>Resource ID</th></tr></thead><tbody>')
                    foreach ($s in $invSvcs) {
                        [void]$Sb.Append('<tr><td><b>' + (E (Pv $s 'name' '')) + '</b></td><td>' + (E (Pv $s 'location' '')) + '</td><td class="mono">' + (E (Pv $s 'subscription' '')) + '</td><td class="res">' + (E (Pv $s 'id' '')) + '</td></tr>')
                    }
                    [void]$Sb.Append('</tbody></table><p class="afs-note">Re-run the export with Reader on that resource group to fill this tab in.</p></div>')
                }

                $svcIx = 0
                $bundleWanted = 0
                $bundleFound  = 0
                foreach ($sd in $svcDirs) {
                    $svcIx++
                    $svc     = LoadJ (Join-Path $sd.FullName 'service.json')
                    $groups  = LoadA (Join-Path $sd.FullName 'syncgroups.json')
                    $ceps    = LoadA (Join-Path $sd.FullName 'cloudendpoints.json')
                    $seps    = LoadA (Join-Path $sd.FullName 'serverendpoints.json')
                    $regs    = LoadA (Join-Path $sd.FullName 'registeredservers.json')
                    $pecs    = LoadA (Join-Path $sd.FullName 'privateendpointconnections.json')
                    $locks   = LoadA (Join-Path $sd.FullName 'locks.json')
                    $diags   = LoadA (Join-Path $sd.FullName 'diagnostics.json')
                    $roles   = LoadA (Join-Path $sd.FullName 'roleassignments.json')
                    $metrics = LoadJ (Join-Path $sd.FullName 'metrics.json')

                    $svcName = [string](Pv $svc 'name' $sd.Name)
                    $svcId   = [string](Pv $svc 'id' '')
                    $svcLoc  = [string](Pv $svc 'location' '')
                    $sp      = Pv $svc 'properties'
                    $itp     = [string](Pv $sp 'incomingTrafficPolicy' '')
                    $useId   = Pv $sp 'useIdentity' $null
                    $sysData = Pv $svc 'systemData'

                    $pecApproved = @($pecs | Where-Object { ([string](Pv (Pv (Pv $_ 'properties') 'privateLinkServiceConnectionState') 'status' '')) -eq 'Approved' })
                    $lockNames = @()
                    foreach ($l in $locks) { $lockNames += (([string](Pv $l 'name' (Leaf (Pv $l 'id' '')))) + ' (' + ([string](Pv (Pv $l 'properties') 'level' '?')) + ')') }
                    $tagNames = @()
                    $tg = Pv $svc 'tags'
                    if ($tg) { try { foreach ($p in $tg.PSObject.Properties) { $tagNames += ($p.Name + '=' + [string]$p.Value) } } catch { } }
                    $scopedRoles = @()
                    if ($svcId) { $scopedRoles = @($roles | Where-Object { ([string](Pv (Pv $_ 'properties') 'scope' '')).ToLower() -eq $svcId.ToLower() }) }

                    [void]$Sb.Append('<h2>Storage Sync Service <span class="mono">' + (E $svcName) + '</span></h2>')
                    [void]$Sb.Append('<div class="card kv">')
                    [void]$Sb.Append('<div class="k">Resource ID</div><div class="res">' + (E $svcId) + '</div>')
                    [void]$Sb.Append('<div class="k">Location</div><div>' + (E $svcLoc) + '</div>')
                    [void]$Sb.Append('<div class="k">Export folder</div><div class="mono">storagesync/' + (E $sd.Name) + '</div>')
                    [void]$Sb.Append('<div class="k">Provisioning state</div><div>' + (E (Pv $sp 'provisioningState' 'not reported')) + '</div>')

                    $itpTxt = 'not reported'
                    if ($itp) {
                        if ($itp -eq 'AllowAllTraffic') { $itpTxt = (E $itp) + ' <span class="afs-note">- the service public endpoint accepts registrations and sync from any network</span>' }
                        elseif ($itp -eq 'AllowVirtualNetworksOnly') {
                            $itpTxt = (E $itp) + ' <span class="afs-note">- public endpoint disabled; reachable only through an approved private endpoint</span>'
                            if ($pecApproved.Count -eq 0) { $itpTxt += ' <span class="afs-flag">no approved private endpoint connection exists</span>' }
                        } else { $itpTxt = E $itp }
                    }
                    [void]$Sb.Append('<div class="k">incomingTrafficPolicy</div><div>' + $itpTxt + '</div>')

                    $idTxt = '<span class="afs-note">not reported</span>'
                    if ($null -ne $useId) {
                        if (Truthy $useId) { $idTxt = (Pill 'useIdentity = true' 'ok') + ' <span class="afs-note">the service authenticates to storage with a managed identity</span>' }
                        else { $idTxt = (Pill 'useIdentity = false' 'warn') + ' <span class="afs-note">the service authenticates to the storage account with the account key</span>' }
                    }
                    [void]$Sb.Append('<div class="k">Identity</div><div>' + $idTxt + '</div>')
                    [void]$Sb.Append('<div class="k">Private endpoint connections</div><div>' + (E $pecApproved.Count) + ' approved of ' + (E $pecs.Count) + '</div>')
                    if ($pecs.Count -gt 0) {
                        foreach ($p in $pecs) {
                            $st = [string](Pv (Pv (Pv $p 'properties') 'privateLinkServiceConnectionState') 'status' '?')
                            $pe = Leaf ([string](Pv (Pv (Pv $p 'properties') 'privateEndpoint') 'id' ''))
                            [void]$Sb.Append('<div class="k afs-note">- connection</div><div class="mono">' + (E (Leaf ([string](Pv $p 'name' '')))) + ' <span class="afs-note">status</span> ' + (E $st) + ' <span class="afs-note">endpoint</span> ' + (E $pe) + '</div>')
                        }
                    }
                    $lockTxt = '0 <span class="afs-note">- the export found no management lock on this service</span>'
                    if ($lockNames.Count -gt 0) { $lockTxt = (E $lockNames.Count) + ' - ' + (E ($lockNames -join ', ')) }
                    [void]$Sb.Append('<div class="k">Resource locks</div><div>' + $lockTxt + '</div>')
                    [void]$Sb.Append('<div class="k">Diagnostic settings</div><div>' + (E $diags.Count) + '</div>')
                    $roleTxt = (E $scopedRoles.Count) + ' at this scope'
                    if ($roles.Count -gt $scopedRoles.Count) { $roleTxt += ' <span class="afs-note">(' + (E $roles.Count) + ' returned including inherited subscription and resource-group assignments, filtered out here)</span>' }
                    [void]$Sb.Append('<div class="k">Role assignments</div><div>' + $roleTxt + '</div>')
                    $tagTxt = '<span class="afs-note">none</span>'
                    if ($tagNames.Count -gt 0) { $tagTxt = E ($tagNames -join ', ') }
                    [void]$Sb.Append('<div class="k">Tags</div><div>' + $tagTxt + '</div>')
                    [void]$Sb.Append('<div class="k">Contents</div><div>' + (E $groups.Count) + ' sync groups &middot; ' + (E $ceps.Count) + ' cloud endpoints &middot; ' + (E $seps.Count) + ' server endpoints &middot; ' + (E $regs.Count) + ' registered servers</div>')
                    if ($sysData) {
                        [void]$Sb.Append('<div class="k">Stood up</div><div>' + (E (Pv $sysData 'createdAt' 'not reported')) + ' <span class="afs-note">by</span> ' + (E (Pv $sysData 'createdBy' 'unknown')) + ' (' + (E (Pv $sysData 'createdByType' '?')) + ')</div>')
                        [void]$Sb.Append('<div class="k">Last modified</div><div>' + (E (Pv $sysData 'lastModifiedAt' 'not reported')) + ' <span class="afs-note">by</span> ' + (E (Pv $sysData 'lastModifiedBy' 'unknown')) + '</div>')
                    }
                    $lastOp = [string](Pv $sp 'lastOperationName' '')
                    if ($lastOp) { [void]$Sb.Append('<div class="k">Last ARM operation</div><div class="mono">' + (E $lastOp) + '</div>') }
                    $ssUid = [string](Pv $sp 'storageSyncServiceUid' '')
                    if ($ssUid) { [void]$Sb.Append('<div class="k">Service UID</div><div class="mono">' + (E $ssUid) + '</div>') }
                    [void]$Sb.Append('</div>')

                    if ($groups.Count -eq 0 -and $seps.Count -eq 0 -and $regs.Count -eq 0) {
                        [void]$Sb.Append('<div class="card"><p><b>The service exists and nothing is attached to it.</b> 0 sync groups, 0 cloud endpoints, 0 server endpoints, 0 registered servers - no server has been given a registration token yet.</p>')
                        if ($sysData) { [void]$Sb.Append('<p class="afs-note">Created ' + (E (Pv $sysData 'createdAt' '')) + '; compare that against the export timestamp above to see how long it has stood empty.</p>') }
                        [void]$Sb.Append('<p class="afs-note">There is no topology, no tiering telemetry and no sync health to show - not because the export missed them, but because they do not exist yet. This is a half-built deployment.</p></div>')
                    }

                    # ---- derived model: endpoints joined to groups, servers, shares ----
                    function GroupOf { param([string]$id) if ($id -match '/syncGroups/([^/]+)') { return $Matches[1] } return '' }

                    $epRecs = @()
                    foreach ($ep in $seps) {
                        $p = Pv $ep 'properties'
                        $ss = Pv $p 'syncStatus'
                        $up = Pv $ss 'uploadStatus'
                        $dn = Pv $ss 'downloadStatus'
                        $ct = Pv $p 'cloudTieringStatus'
                        $path = [string](Pv $p 'serverLocalPath' '')
                        $srvName = [string](Pv $p 'friendlyName' (Pv $p 'serverName' ''))
                        $rec = [pscustomobject]@{
                            name      = [string](Pv $ep 'name' (Leaf ([string](Pv $ep 'id' ''))))
                            id        = [string](Pv $ep 'id' '')
                            group     = (GroupOf ([string](Pv $ep 'id' '')))
                            props     = $p
                            path      = $path
                            drive     = (DriveOf $path)
                            srvShort  = (ShortHost $srvName)
                            srvName   = $srvName
                            srvFqdn   = [string](Pv $p 'serverName' '')
                            srvResId  = ([string](Pv $p 'serverResourceId' '')).ToLower()
                            tiering   = (([string](Pv $p 'cloudTiering' 'off')).ToLower() -eq 'on')
                            freeCfg   = (Pv $p 'volumeFreeSpacePercent')
                            tierDays  = (Pv $p 'tierFilesOlderThanDays')
                            sync      = $ss
                            up        = $up
                            dn        = $dn
                            tier      = $ct
                            health    = [string](Pv $ss 'combinedHealth' '')
                            upHealth  = [string](Pv $ss 'uploadHealth' '')
                            dnHealth  = [string](Pv $ss 'downloadHealth' '')
                            activity  = [string](Pv $ss 'syncActivity' '')
                            notSync   = (Pv $ss 'totalPersistentFilesNotSyncingCount')
                            upOk      = (Pv $up 'lastSyncSuccessTimestamp')
                            dnOk      = (Pv $dn 'lastSyncSuccessTimestamp')
                            onSystem  = ($path -match '^[Cc]:')
                            parent    = ''
                        }
                        $epRecs += $rec
                    }
                    # nesting: one serverLocalPath is a prefix of another on the same server
                    foreach ($a in $epRecs) {
                        $best = ''
                        $bestLen = -1
                        foreach ($b in $epRecs) {
                            if ($b.name -eq $a.name) { continue }
                            if ($b.srvResId -ne $a.srvResId -and $b.srvShort -ne $a.srvShort) { continue }
                            if (IsUnder $b.path $a.path) { if ($b.path.Length -gt $bestLen) { $best = $b.name; $bestLen = $b.path.Length } }
                        }
                        $a.parent = $best
                    }
                    $nested = @($epRecs | Where-Object { $_.parent -ne '' })

                    $isStale = {
                        param($stamp)
                        $d = ToDate $stamp
                        if ($null -eq $d -or $null -eq $exportedAt) { return $false }
                        return (($exportedAt - $d).TotalHours -gt 24)
                    }

                    $ceRecs = @()
                    foreach ($ce in $ceps) {
                        $p = Pv $ce 'properties'
                        $saId = [string](Pv $p 'storageAccountResourceId' '')
                        $shName = [string](Pv $p 'azureFileShareName' '')
                        $acct = $null
                        if ($saId -and $accById.ContainsKey($saId.ToLower())) { $acct = $accById[$saId.ToLower()] }
                        elseif ($saId) { $an = (Leaf $saId).ToLower(); if ($accByName.ContainsKey($an)) { $acct = $accByName[$an] } }
                        $share = $null
                        if ($null -ne $acct) {
                            foreach ($s in $acct.shares) { if (([string](Pv $s 'name' '')).ToLower() -eq $shName.ToLower()) { $share = $s; break } }
                        }
                        $cov = $null
                        if ($saId -and $shName) {
                            $ck = ((Leaf $saId) + '/' + $shName).ToLower()
                            if ($covIdx.ContainsKey($ck)) { $cov = $covIdx[$ck] }
                        }
                        $enum = Pv $p 'changeEnumerationStatus'
                        $last = Pv $enum 'lastCompletedEnumeration'
                        $ceRecs += [pscustomobject]@{
                            name = [string](Pv $ce 'name' (Leaf ([string](Pv $ce 'id' ''))))
                            group = (GroupOf ([string](Pv $ce 'id' '')))
                            props = $p
                            saId = $saId
                            saName = (Leaf $saId)
                            shareName = $shName
                            acct = $acct
                            share = $share
                            shareProps = (Pv $share 'properties')
                            cov = $cov
                            enum = $enum
                            lastEnum = $last
                            enumPresent = (HasP $p 'changeEnumerationStatus')
                        }
                    }

                    $grpRecs = @()
                    foreach ($g in $groups) {
                        $gn = [string](Pv $g 'name' (Leaf ([string](Pv $g 'id' ''))))
                        $ge = @($epRecs | Where-Object { $_.group -eq $gn })
                        $gc = @($ceRecs | Where-Object { $_.group -eq $gn }) | Select-Object -First 1
                        $bad = @($ge | Where-Object { $_.health -and $_.health -ne 'Healthy' })
                        $state = 'ok'
                        if ($ge.Count -eq 0) { $state = 'none' } elseif ($bad.Count -gt 0) { $state = 'warn' }
                        $grpRecs += [pscustomobject]@{
                            name = $gn
                            grp = $g
                            status = [string](Pv (Pv $g 'properties') 'syncGroupStatus' '')
                            uid = [string](Pv (Pv $g 'properties') 'uniqueId' '')
                            eps = $ge
                            ce = $gc
                            bad = $bad.Count
                            state = $state
                        }
                    }
                    # cloud endpoints whose sync group is not in syncgroups.json, and vice versa
                    foreach ($c in $ceRecs) {
                        $known = @($grpRecs | Where-Object { $_.name -eq $c.group })
                        if ($known.Count -eq 0) {
                            $ge = @($epRecs | Where-Object { $_.group -eq $c.group })
                            $bad = @($ge | Where-Object { $_.health -and $_.health -ne 'Healthy' })
                            $state = 'ok'
                            if ($ge.Count -eq 0) { $state = 'none' } elseif ($bad.Count -gt 0) { $state = 'warn' }
                            $grpRecs += [pscustomobject]@{ name = $c.group; grp = $null; status = ''; uid = ''; eps = $ge; ce = $c; bad = $bad.Count; state = $state }
                        }
                    }

                    $regRecs = @()
                    foreach ($r in $regs) {
                        $p = Pv $r 'properties'
                        $fn = [string](Pv $p 'friendlyName' (Pv $p 'serverName' (Pv $r 'name' '')))
                        $sh = ShortHost $fn
                        $rid = ([string](Pv $r 'id' '')).ToLower()
                        $mine = @($epRecs | Where-Object { ($_.srvResId -ne '' -and $_.srvResId -eq $rid) -or ($_.srvResId -eq '' -and $_.srvShort -eq $sh) })
                        $bun = $null
                        if ($sh -and $bundles.ContainsKey($sh)) { $bun = $bundles[$sh]; $usedBundles[$sh] = $true }
                        $regRecs += [pscustomobject]@{
                            name = [string](Pv $r 'name' '')
                            friendly = $fn
                            short = $sh
                            props = $p
                            id = $rid
                            eps = $mine
                            bundle = $bun
                        }
                        $bundleWanted++
                        if ($null -ne $bun) { $bundleFound++ }
                    }
                    $orphanSrv = @($regRecs | Where-Object { $_.eps.Count -eq 0 })

                    # ---- topology diagram ------------------------------------------
                    if ($grpRecs.Count -gt 0 -or $orphanSrv.Count -gt 0) {
                        $W = 840
                        $svcX = 14;  $svcW = 176; $svcH = 96
                        $laneX = 204; $laneW = 622
                        $cardX = 218; $cardW = 250; $cardH = 54
                        $chOff = 16;  $chH = 42
                        $cylX = 566;  $cylW = 244; $cylH = 98
                        $collapse = ($epRecs.Count -gt 40)

                        $lanes = @()
                        $y = 42
                        foreach ($gr in $grpRecs) {
                            $tops = @($gr.eps | Where-Object { $_.parent -eq '' })
                            $shown = $tops
                            $hidden = 0
                            if ($collapse) {
                                $shown = @($tops | Where-Object { $_.health -and $_.health -ne 'Healthy' })
                                $hidden = $tops.Count - $shown.Count
                            }
                            $units = @()
                            foreach ($t in $shown) {
                                $kids = @($gr.eps | Where-Object { $_.parent -eq $t.name })
                                $h = $cardH
                                if ($kids.Count -gt 0) { $h = $cardH + ($kids.Count * ($chH + 6)) + 6 }
                                $units += [pscustomobject]@{ ep = $t; kids = $kids; h = $h; y = 0 }
                            }
                            $cardsH = 0
                            foreach ($u in $units) { $cardsH += $u.h }
                            if ($units.Count -gt 1) { $cardsH += 10 * ($units.Count - 1) }
                            if ($hidden -gt 0) { if ($units.Count -gt 0) { $cardsH += 10 }; $cardsH += 40 }
                            $inner = [int][math]::Max($cardsH, $cylH + 8)
                            $laneH = 30 + $inner + 14
                            $cy = $y + 30
                            foreach ($u in $units) { $u.y = $cy; $cy += $u.h + 10 }
                            $lanes += [pscustomobject]@{ gr = $gr; y = $y; h = $laneH; units = $units; hidden = $hidden; hiddenY = $cy; cylY = ($y + 30 + [int][math]::Floor(($inner - $cylH) / 2)) }
                            $y += $laneH + 14
                        }
                        $lanesTop = 42
                        $lanesBot = $y - 14
                        if ($lanes.Count -eq 0) { $lanesBot = $lanesTop }
                        $orphY = $y
                        $orphH = 0
                        if ($orphanSrv.Count -gt 0) {
                            $rows = [int][math]::Ceiling($orphanSrv.Count / 3.0)
                            $orphH = 34 + ($rows * 50)
                            $y += $orphH + 12
                        }
                        $H = $y + 10
                        $svcY = $lanesTop + [int][math]::Max(0, [math]::Floor((($lanesBot - $lanesTop) - $svcH) / 2))

                        $g = New-Object System.Text.StringBuilder
                        [void]$g.Append('<div class="afs-scroll"><svg viewBox="0 0 ' + $W + ' ' + $H + '" role="img" aria-label="Azure File Sync topology for ' + (E $svcName) + ': the Storage Sync Service, one lane per sync group, its server endpoints on the left and its cloud endpoint on the right, with registered servers that carry no server endpoint shown separately underneath." preserveAspectRatio="xMidYMin meet">')
                        [void]$g.Append('<defs>')
                        [void]$g.Append('<pattern id="afsStripe' + $svcIx + '" width="10" height="10" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="10" height="10" class="sv-pat-bg"/><rect width="4" height="10" class="sv-pat-fg"/></pattern>')
                        [void]$g.Append('<pattern id="afsHatch' + $svcIx + '" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" class="sv-hat-bg"/><rect width="2" height="6" class="sv-hat-fg"/></pattern>')
                        [void]$g.Append('<marker id="afsUp' + $svcIx + '" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" class="sv-arr"/></marker>')
                        [void]$g.Append('<marker id="afsUpS' + $svcIx + '" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" class="sv-arr-stale"/></marker>')
                        [void]$g.Append('<marker id="afsDn' + $svcIx + '" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M10,0 L0,5 L10,10 z" class="sv-arr"/></marker>')
                        [void]$g.Append('<marker id="afsDnS' + $svcIx + '" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M10,0 L0,5 L10,10 z" class="sv-arr-stale"/></marker>')
                        [void]$g.Append('</defs>')
                        # column captions
                        [void]$g.Append('<text class="sv-th" x="' + $svcX + '" y="20">Storage Sync Service</text>')
                        [void]$g.Append('<text class="sv-th" x="' + $cardX + '" y="20">Server endpoints - cache, not a copy</text>')
                        [void]$g.Append('<text class="sv-th" x="' + $cylX + '" y="20">Cloud endpoints - the authoritative copy</text>')
                        if ($lanes.Count -gt 0) {
                            [void]$g.Append('<rect class="sv-ann" x="' + ($cardX - 8) + '" y="' + ($lanesTop - 12) + '" width="' + ($cardW + 16) + '" height="' + (($lanesBot - $lanesTop) + 16) + '" rx="8"/>')
                        }
                        # service node
                        [void]$g.Append('<rect class="sv-svc" x="' + $svcX + '" y="' + $svcY + '" width="' + $svcW + '" height="' + $svcH + '" rx="8"/>')
                        [void]$g.Append('<text class="sv-tb" x="' + ($svcX + 12) + '" y="' + ($svcY + 22) + '">' + (E (Trunc $svcName 22)) + '</text>')
                        [void]$g.Append('<text class="sv-tm" x="' + ($svcX + 12) + '" y="' + ($svcY + 40) + '">' + (E $svcLoc) + '</text>')
                        [void]$g.Append('<text class="sv-t" x="' + ($svcX + 12) + '" y="' + ($svcY + 58) + '">' + (E (Trunc $itp 24)) + '</text>')
                        $idLbl = 'account key (useIdentity false)'
                        if (Truthy $useId) { $idLbl = 'managed identity' }
                        [void]$g.Append('<text class="sv-t" x="' + ($svcX + 12) + '" y="' + ($svcY + 74) + '">' + (E $idLbl) + '</text>')
                        [void]$g.Append('<text class="sv-tm" x="' + ($svcX + 12) + '" y="' + ($svcY + 89) + '">' + (E ($grpRecs.Count.ToString() + ' groups / ' + $regs.Count.ToString() + ' servers')) + '</text>')

                        foreach ($ln in $lanes) {
                            $gr = $ln.gr
                            $laneCls = 'sv-lane'
                            $laneStyle = ''
                            if ($gr.state -eq 'warn') { $laneCls = 'sv-lane sv-lane-warn'; $laneStyle = ' style="fill:url(#afsStripe' + $svcIx + ')"' }
                            elseif ($gr.state -eq 'none') { $laneCls = 'sv-lane-none' }
                            [void]$g.Append('<rect class="' + $laneCls + '" x="' + $laneX + '" y="' + $ln.y + '" width="' + $laneW + '" height="' + $ln.h + '" rx="8"' + $laneStyle + '/>')
                            [void]$g.Append('<line class="sv-edge" x1="' + ($svcX + $svcW) + '" y1="' + ($svcY + [int]($svcH / 2)) + '" x2="' + $laneX + '" y2="' + ($ln.y + 18) + '" stroke-width="1"/>')
                            $gLbl = $gr.name
                            $gSuffix = ''
                            if ($gr.state -eq 'none') { $gSuffix = '  -  0 server endpoints: a cloud endpoint syncing to nothing' }
                            elseif ($gr.bad -gt 0) { $gSuffix = '  -  ' + $gr.bad.ToString() + ' endpoint(s) not Healthy' }
                            [void]$g.Append('<text class="sv-tb" x="' + ($laneX + 12) + '" y="' + ($ln.y + 19) + '">' + (E (Trunc ($gLbl + $gSuffix) 84)) + '</text>')

                            foreach ($u in $ln.units) {
                                $ep = $u.ep
                                $cc = 'sv-card'
                                if ($ep.health -and $ep.health -ne 'Healthy') { $cc = 'sv-card-err' }
                                [void]$g.Append('<rect class="' + $cc + '" x="' + $cardX + '" y="' + $u.y + '" width="' + $cardW + '" height="' + $u.h + '" rx="6"/>')
                                [void]$g.Append('<text class="sv-tb" x="' + ($cardX + 10) + '" y="' + ($u.y + 19) + '">' + (E (Trunc $ep.srvName 18)) + '</text>')
                                [void]$g.Append('<text class="sv-tm" x="' + ($cardX + 10) + '" y="' + ($u.y + 34) + '">' + (E (Trunc $ep.path 26)) + '</text>')
                                $bx = $cardX + 132
                                if ($ep.tiering) {
                                    [void]$g.Append('<rect class="sv-badge" x="' + $bx + '" y="' + ($u.y + 38) + '" width="108" height="14" rx="7"/>')
                                    [void]$g.Append('<text class="sv-tm" x="' + ($bx + 7) + '" y="' + ($u.y + 48) + '">tier ' + (E ([string]$ep.freeCfg)) + '% / ' + (E ([string]$ep.tierDays)) + 'd</text>')
                                } else {
                                    [void]$g.Append('<rect class="sv-badge-off" x="' + $bx + '" y="' + ($u.y + 38) + '" width="108" height="14" rx="7"/>')
                                    [void]$g.Append('<text class="sv-tm" x="' + ($bx + 7) + '" y="' + ($u.y + 48) + '">no tiering - full copy</text>')
                                }
                                $ns = Num $ep.notSync
                                if ($null -ne $ns -and $ns -gt 0) {
                                    [void]$g.Append('<circle class="sv-card-err" cx="' + ($cardX + $cardW - 16) + '" cy="' + ($u.y + 16) + '" r="11"/>')
                                    [void]$g.Append('<text class="sv-tm" x="' + ($cardX + $cardW - 16) + '" y="' + ($u.y + 20) + '" text-anchor="middle">' + (E (Nm $ns 0)) + '</text>')
                                }
                                $ky = $u.y + $cardH + 2
                                foreach ($kd in $u.kids) {
                                    [void]$g.Append('<rect class="sv-card-child" x="' + ($cardX + $chOff) + '" y="' + $ky + '" width="' + ($cardW - ($chOff * 2)) + '" height="' + $chH + '" rx="5"/>')
                                    [void]$g.Append('<text class="sv-t" x="' + ($cardX + $chOff + 8) + '" y="' + ($ky + 17) + '">' + (E (Trunc $kd.path 24)) + '</text>')
                                    [void]$g.Append('<text class="sv-tm" x="' + ($cardX + $chOff + 8) + '" y="' + ($ky + 32) + '">nested inside the endpoint above</text>')
                                    $ky += $chH + 6
                                }
                                # edge to the cloud endpoint: thickness = cached share of the cloud data set
                                $sw = 1.4
                                $ts = Pv $ep.tier 'spaceSavings'
                                $cb = Num (Pv $ts 'cachedSizeBytes')
                                $tb = Num (Pv $ts 'totalSizeCloudBytes')
                                if ($null -ne $cb -and $null -ne $tb -and $tb -gt 0) { $sw = 1.2 + (3.6 * [math]::Min(1.0, ($cb / $tb))) }
                                $ey = $u.y + [int]($cardH / 2)
                                $cyc = $ln.cylY + [int]($cylH / 2)
                                $mx = [int](($cardX + $cardW + $cylX) / 2)
                                $upStale = (& $isStale $ep.upOk)
                                $dnStale = (& $isStale $ep.dnOk)
                                $mu = 'afsUp' + $svcIx; if ($upStale) { $mu = 'afsUpS' + $svcIx }
                                $md = 'afsDn' + $svcIx; if ($dnStale) { $md = 'afsDnS' + $svcIx }
                                $ecls = 'sv-edge'
                                if ($upStale -and $dnStale) { $ecls = 'sv-edge-stale' }
                                [void]$g.Append('<path class="' + $ecls + '" d="M' + ($cardX + $cardW + 8) + ',' + $ey + ' C' + $mx + ',' + $ey + ' ' + $mx + ',' + $cyc + ' ' + ($cylX - 8) + ',' + $cyc + '" stroke-width="' + (Nm $sw 2) + '" marker-end="url(#' + $mu + ')" marker-start="url(#' + $md + ')"/>')
                            }
                            if ($ln.hidden -gt 0) {
                                [void]$g.Append('<rect class="sv-card" x="' + $cardX + '" y="' + $ln.hiddenY + '" width="' + $cardW + '" height="34" rx="6"/>')
                                [void]$g.Append('<text class="sv-t" x="' + ($cardX + 10) + '" y="' + ($ln.hiddenY + 21) + '">' + (E ($ln.hidden.ToString() + ' further Healthy server endpoints (collapsed)')) + '</text>')
                            }
                            if ($gr.eps.Count -eq 0) {
                                [void]$g.Append('<text class="sv-t" x="' + $cardX + '" y="' + ($ln.cylY + 50) + '">no server endpoint in this group</text>')
                            }
                            # cloud endpoint cylinder
                            $ce = $gr.ce
                            $cyY = $ln.cylY
                            $capCls = 'sv-cyl'
                            $capStyle = ''
                            $lbl1 = 'no cloud endpoint'
                            $lbl2 = ''
                            $lbl3 = ''
                            $lbl4 = ''
                            $fillPct = $null
                            $hot = $false
                            if ($null -ne $ce) {
                                $lbl1 = $ce.saName
                                $lbl2 = $ce.shareName
                                if ($null -ne $ce.lastEnum) { $lbl3 = 'namespace ' + (Sz (Pv $ce.lastEnum 'namespaceSizeBytes')) }
                                else { $lbl3 = 'no completed enumeration'; $capStyle = ' style="fill:url(#afsHatch' + $svcIx + ')"' }
                                $q = Num (Pv $ce.shareProps 'shareQuota')
                                $u2 = Num (Pv $ce.shareProps 'shareUsageBytes')
                                if ($null -ne $q -and $q -gt 0 -and $null -ne $u2) {
                                    $fillPct = ($u2 / ($q * 1073741824.0)) * 100.0
                                    if ($fillPct -gt 100) { $fillPct = 100.0 }
                                    if ($fillPct -ge 80) { $hot = $true }
                                    $lbl4 = (Nm $fillPct 0) + '% of quota  -  ' + [string](Pv $ce.shareProps 'accessTier' '')
                                } elseif ($null -ne $ce.share) { $lbl4 = [string](Pv $ce.shareProps 'accessTier' '') }
                                else { $lbl4 = 'share not in the export' }
                            }
                            [void]$g.Append('<path class="sv-cyl" d="M' + $cylX + ',' + ($cyY + 12) + ' L' + $cylX + ',' + ($cyY + $cylH - 12) + ' A' + [int]($cylW / 2) + ',12 0 0 0 ' + ($cylX + $cylW) + ',' + ($cyY + $cylH - 12) + ' L' + ($cylX + $cylW) + ',' + ($cyY + 12) + '"/>')
                            if ($null -ne $fillPct) {
                                $fh = [int](($cylH - 24) * ($fillPct / 100.0))
                                $fcls = 'sv-cylfill'
                                if ($hot) { $fcls = 'sv-cylfill hot' }
                                [void]$g.Append('<rect class="' + $fcls + '" x="' + ($cylX + 1) + '" y="' + ($cyY + $cylH - 12 - $fh) + '" width="' + ($cylW - 2) + '" height="' + $fh + '"/>')
                            }
                            [void]$g.Append('<ellipse class="' + $capCls + '" cx="' + ($cylX + [int]($cylW / 2)) + '" cy="' + ($cyY + 12) + '" rx="' + [int]($cylW / 2) + '" ry="12"' + $capStyle + '/>')
                            [void]$g.Append('<text class="sv-tb" x="' + ($cylX + 12) + '" y="' + ($cyY + 44) + '">' + (E (Trunc $lbl2 24)) + '</text>')
                            [void]$g.Append('<text class="sv-tm" x="' + ($cylX + 12) + '" y="' + ($cyY + 60) + '">' + (E (Trunc $lbl1 30)) + '</text>')
                            [void]$g.Append('<text class="sv-t" x="' + ($cylX + 12) + '" y="' + ($cyY + 76) + '">' + (E (Trunc $lbl3 30)) + '</text>')
                            [void]$g.Append('<text class="sv-tm" x="' + ($cylX + 12) + '" y="' + ($cyY + 90) + '">' + (E (Trunc $lbl4 32)) + '</text>')
                        }
                        if ($orphanSrv.Count -gt 0) {
                            [void]$g.Append('<rect class="sv-lane-none" x="' + $laneX + '" y="' + $orphY + '" width="' + $laneW + '" height="' + $orphH + '" rx="8"/>')
                            [void]$g.Append('<text class="sv-tb" x="' + ($laneX + 12) + '" y="' + ($orphY + 21) + '">Registered servers with no server endpoint - off the topology entirely</text>')
                            $oy = $orphY + 32; $oi = 0
                            foreach ($o in $orphanSrv) {
                                $col = $oi % 3
                                $cx2 = $laneX + 12 + ($col * 200)
                                $cy2 = $oy + ([int][math]::Floor($oi / 3) * 50)
                                [void]$g.Append('<rect class="sv-card" x="' + $cx2 + '" y="' + $cy2 + '" width="188" height="42" rx="6"/>')
                                [void]$g.Append('<text class="sv-tb" x="' + ($cx2 + 10) + '" y="' + ($cy2 + 18) + '">' + (E (Trunc $o.friendly 20)) + '</text>')
                                $rl = [string](Pv $o.props 'serverRole' '')
                                $cl = [string](Pv $o.props 'clusterName' '')
                                $sub = $rl
                                if ($cl) { $sub = $rl + ' of ' + $cl }
                                [void]$g.Append('<text class="sv-tm" x="' + ($cx2 + 10) + '" y="' + ($cy2 + 34) + '">' + (E (Trunc ($sub + '  0 endpoints') 26)) + '</text>')
                                $oi++
                            }
                        }
                        [void]$g.Append('</svg></div>')
                        [void]$Sb.Append('<h3>Topology</h3>')
                        [void]$Sb.Append($g.ToString())
                        [void]$Sb.Append('<p class="afs-note">Lane fill carries the sync-group rollup: plain where every server endpoint reports Healthy, hatched where at least one does not, hollow with a dashed outline where the group has no server endpoint at all. Edge thickness is the cached share of the cloud data set (cachedSizeBytes / totalSizeCloudBytes); an arrowhead is greyed when that direction has had no successful sync in the 24 h before the export. A card drawn inside another card is a nested server endpoint. The cylinder fill is shareUsageBytes against shareQuota, and a hatched cap means the cloud endpoint has no completed change enumeration.</p>')
                    }

                    # ---- sync group -> cloud endpoint -> server endpoints ------------
                    if ($grpRecs.Count -gt 0) {
                        [void]$Sb.Append('<h3>Sync groups <span class="afs-sub">' + (E $grpRecs.Count) + ' groups, ' + (E $ceRecs.Count) + ' cloud endpoints, ' + (E $epRecs.Count) + ' server endpoints</span></h3>')
                        [void]$Sb.Append('<table><thead><tr><th>Sync group</th><th>syncGroupStatus</th><th>Cloud endpoint</th><th>Storage account / share</th><th>Server endpoints</th><th>Not Healthy</th></tr></thead><tbody>')
                        foreach ($gr in $grpRecs) {
                            $cls = ''
                            if ($gr.eps.Count -eq 0) { $cls = ' class="hollow"' }
                            $ceTxt = '<span class="afs-note">none in the export</span>'
                            $tgt = '<span class="afs-note">-</span>'
                            if ($null -ne $gr.ce) {
                                $ceTxt = '<span class="mono">' + (E $gr.ce.name) + '</span>'
                                $tgt = '<span class="mono">' + (E $gr.ce.saName) + ' / ' + (E $gr.ce.shareName) + '</span>'
                                if ($null -eq $gr.ce.acct) { $tgt += ' <span class="afs-flag">storage account not in this export - the share behind this group was not assessed</span>' }
                            }
                            $epTxt = ''
                            if ($gr.eps.Count -eq 0) { $epTxt = '0 - the cloud endpoint has nothing syncing to it' }
                            else {
                                $bits = @()
                                foreach ($e in $gr.eps) { $bits += ($e.srvName + ' ' + $e.path) }
                                $epTxt = $gr.eps.Count.ToString() + ' - ' + ($bits -join '; ')
                            }
                            $badTxt = '0'
                            if ($gr.bad -gt 0) { $badTxt = '<b class="afs-flag">' + (E $gr.bad) + '</b>' }
                            [void]$Sb.Append('<tr' + $cls + '><td><b>' + (E $gr.name) + '</b></td><td class="mono">' + (E $gr.status) + '</td><td>' + $ceTxt + '</td><td>' + $tgt + '</td><td>' + (E $epTxt) + '</td><td class="num">' + $badTxt + '</td></tr>')
                        }
                        [void]$Sb.Append('</tbody></table>')
                        [void]$Sb.Append('<p class="afs-note">Rows in italic have no server endpoint. <code>syncGroupStatus</code> arrives from ARM as a string, and is reproduced verbatim.</p>')
                    }

                    # ---- server endpoints: placement and policy ----------------------
                    if ($epRecs.Count -gt 0) {
                        [void]$Sb.Append('<h3>Server endpoints - placement and policy</h3>')
                        [void]$Sb.Append('<table><thead><tr><th>Server endpoint</th><th>Server</th><th>Local path</th><th>Sync group</th><th>Cloud tiering</th><th>Free space policy<br><span class="afs-sub">configured / effective / current</span></th><th>Tier files older than</th><th>Initial download</th><th>Local cache mode</th><th>Initial upload</th></tr></thead><tbody>')
                        foreach ($e in $epRecs) {
                            $p = $e.props
                            $pathHtml = '<span class="mono">' + (E $e.path) + '</span>'
                            $flags = @()
                            if ($e.onSystem) { $flags += 'on the system volume' }
                            if ($e.parent) { $flags += 'nested inside ' + $e.parent }
                            $kids = @($epRecs | Where-Object { $_.parent -eq $e.name })
                            if ($kids.Count -gt 0) { $flags += 'contains ' + $kids.Count.ToString() + ' nested endpoint(s)' }
                            if ($flags.Count -gt 0) { $pathHtml += '<br><span class="afs-flag">' + (E ($flags -join '; ')) + '</span>' }
                            $tierTxt = Pill 'off' 'off'
                            if ($e.tiering) { $tierTxt = Pill 'on' 'ok' }
                            $vf = Pv $e.tier 'volumeFreeSpacePolicyStatus'
                            $eff = Pv $vf 'effectiveVolumeFreeSpacePolicy'
                            $cur = Pv $vf 'currentVolumeFreeSpacePercent'
                            $fsTxt = '<span class="mono">' + (E ([string]$e.freeCfg)) + '%</span>'
                            if ($null -ne $eff) {
                                $fsTxt += ' / <b class="mono">' + (E ([string]$eff)) + '%</b> / <span class="mono">' + (E ([string]$cur)) + '%</span>'
                                $ec = Num $eff; $cc2 = Num $e.freeCfg
                                if ($null -ne $ec -and $null -ne $cc2 -and $ec -ne $cc2) { $fsTxt += '<br><span class="afs-flag">the agent enforces ' + (E (Nm $ec 0)) + '%, not the ' + (E (Nm $cc2 0)) + '% configured here</span>' }
                            } elseif ($e.tiering) { $fsTxt += ' / <span class="afs-note">effective not reported</span>' }
                            else { $fsTxt += ' / <span class="afs-note">tiering off - not enforced</span>' }
                            [void]$Sb.Append('<tr><td class="mono">' + (E $e.name) + '</td><td>' + (E $e.srvName) + '</td><td>' + $pathHtml + '</td><td>' + (E $e.group) + '</td><td>' + $tierTxt + '</td><td>' + $fsTxt + '</td><td class="num">' + (E ([string]$e.tierDays)) + ' d</td><td>' + (E (Pv $p 'initialDownloadPolicy' '-')) + '</td><td>' + (E (Pv $p 'localCacheMode' '-')) + '</td><td>' + (E (Pv $p 'initialUploadPolicy' '-')) + '</td></tr>')
                        }
                        [void]$Sb.Append('</tbody></table>')
                        $fsNote = 'The configured <code>volumeFreeSpacePercent</code> is per endpoint; the effective policy is per volume, so endpoints sharing a volume all take the volume-wide value. Both are shown because they can differ, and the agent enforces the effective one.'
                        if ($nested.Count -gt 0) { $fsNote += ' ' + $nested.Count.ToString() + ' endpoint path(s) sit underneath another endpoint on the same server.' }
                        [void]$Sb.Append('<p class="afs-note">' + $fsNote + '</p>')

                        # ---- server endpoints: sync health --------------------------
                        [void]$Sb.Append('<h3>Server endpoints - sync health <span class="afs-sub">ages measured against the export at ' + (E $exportedTx) + '</span></h3>')
                        [void]$Sb.Append('<table><thead><tr><th>Server endpoint</th><th>Combined</th><th>Upload</th><th>Download</th><th>Activity</th><th>Files not syncing<br><span class="afs-sub">persistent / per-item</span></th><th>Last successful upload</th><th>Last successful download</th><th>lastSyncResult<br><span class="afs-sub">upload / download</span></th><th>Status updated</th></tr></thead><tbody>')
                        foreach ($e in $epRecs) {
                            $hc = 'ok'
                            if ($e.health -and $e.health -ne 'Healthy') { $hc = 'bad' }
                            $uc = 'ok'; if ($e.upHealth -and $e.upHealth -ne 'Healthy') { $uc = 'bad' }
                            $dc = 'ok'; if ($e.dnHealth -and $e.dnHealth -ne 'Healthy') { $dc = 'bad' }
                            $ns = Num $e.notSync
                            $nsTxt = (E ([string]$e.notSync))
                            if ($null -ne $ns -and $ns -gt 0) { $nsTxt = '<b class="afs-flag">' + (E (Nm $ns 0)) + '</b>' }
                            $pi = Pv $e.up 'lastSyncPerItemErrorCount'
                            $nsTxt += ' / ' + (E ([string]$pi))
                            $upAge = AgeTxt $e.upOk $exportedAt
                            $dnAge = AgeTxt $e.dnOk $exportedAt
                            $upTxt = '<span class="afs-note">never reported</span>'
                            if ($e.upOk) { $upTxt = '<span class="mono">' + (E $e.upOk) + '</span>'; if ($upAge) { $cl2 = 'afs-note'; if (& $isStale $e.upOk) { $cl2 = 'afs-flag' }; $upTxt += '<br><span class="' + $cl2 + '">' + (E $upAge) + '</span>' } }
                            $dnTxt = '<span class="afs-note">never reported</span>'
                            if ($e.dnOk) { $dnTxt = '<span class="mono">' + (E $e.dnOk) + '</span>'; if ($dnAge) { $cl3 = 'afs-note'; if (& $isStale $e.dnOk) { $cl3 = 'afs-flag' }; $dnTxt += '<br><span class="' + $cl3 + '">' + (E $dnAge) + '</span>' } }
                            $lsr = (HrHtml (Pv $e.up 'lastSyncResult')) + '<br>' + (HrHtml (Pv $e.dn 'lastSyncResult'))
                            [void]$Sb.Append('<tr><td class="mono">' + (E $e.name) + '</td><td>' + (Pill ([string]$e.health) $hc) + '</td><td>' + (Pill ([string]$e.upHealth) $uc) + '</td><td>' + (Pill ([string]$e.dnHealth) $dc) + '</td><td>' + (E $e.activity) + '</td><td class="num">' + $nsTxt + '</td><td>' + $upTxt + '</td><td>' + $dnTxt + '</td><td>' + $lsr + '</td><td class="mono">' + (E (Pv $e.sync 'lastUpdatedTimestamp' '-')) + '</td></tr>')
                        }
                        [void]$Sb.Append('</tbody></table>')
                        [void]$Sb.Append('<p class="afs-note">A <code>lastSyncResult</code> of 0 and a combined health of Error can and do coexist - the last individual session succeeded while the endpoint is still unhealthy - so health is read from <code>combinedHealth</code>, never derived from the result code. <code>filesNotSyncingErrors[]</code> and <code>recallErrors[]</code> carry the per-error-code breakdown in a real export; where they are empty arrays here, the file list has to come from <code>FileSyncErrorsReport</code> on the server.</p>')
                    }

                    # ---- HResult decoder --------------------------------------------
                    $hrSeen = @{}
                    function NoteHr { param($v, [string]$where) $hex = HrHex $v; if (-not $hex) { return }; if (-not $hrSeen.ContainsKey($hex)) { $hrSeen[$hex] = [pscustomobject]@{ raw = [string]$v; hex = $hex; where = @() } }; if (($hrSeen[$hex].where -notcontains $where)) { $hrSeen[$hex].where += $where } }
                    foreach ($e in $epRecs) {
                        NoteHr (Pv $e.tier 'lastCloudTieringResult') ($e.name + ' cloudTieringStatus.lastCloudTieringResult')
                        NoteHr (Pv $e.up 'lastSyncResult') ($e.name + ' uploadStatus.lastSyncResult')
                        NoteHr (Pv $e.dn 'lastSyncResult') ($e.name + ' downloadStatus.lastSyncResult')
                    }
                    foreach ($rr in $regRecs) {
                        if ($null -eq $rr.bundle) { continue }
                        foreach ($dg in $rr.bundle.digest) { NoteHr (Pv $dg 'hresult') ($rr.friendly + ' 9102 ' + [string](Pv $dg 'syncGroup' '') + ' ' + [string](Pv $dg 'direction' '')) }
                    }
                    if ($hrSeen.Count -gt 0) {
                        [void]$Sb.Append('<h3>HResults in this export <span class="afs-sub">signed decimal as ARM returns it, unsigned hex as the Microsoft error tables index it</span></h3>')
                        [void]$Sb.Append('<table><thead><tr><th>Decimal</th><th>Hex</th><th>Name</th><th>Seen on</th></tr></thead><tbody>')
                        foreach ($k in @($hrSeen.Keys | Sort-Object)) {
                            $h = $hrSeen[$k]
                            $nm = '<span class="afs-note">not in the decoder table</span>'
                            if ($hrNames.ContainsKey($h.hex)) { $nm = '<b>' + (E $hrNames[$h.hex]) + '</b>' }
                            $wh = (($h.where | Select-Object -First 6) -join '; ')
                            if ($h.where.Count -gt 6) { $wh += ' (+' + ($h.where.Count - 6).ToString() + ' more)' }
                            [void]$Sb.Append('<tr><td class="mono">' + (E $h.raw) + '</td><td class="mono"><b>' + (E $h.hex) + '</b></td><td>' + $nm + '</td><td class="afs-note">' + (E $wh) + '</td></tr>')
                        }
                        [void]$Sb.Append('</tbody></table>')
                        [void]$Sb.Append('<p class="afs-note">Every File Sync error reference - sync errors, tiering errors, recall errors - is indexed by the hex form, so this is the column to search with. <a href="https://learn.microsoft.com/troubleshoot/azure/azure-storage/files/file-sync/file-sync-troubleshoot-sync-errors" target="_blank" rel="noopener">File Sync sync-error reference</a>.</p>')
                    }

                    # ---- cloud tiering economics -------------------------------------
                    $tierOn  = @($epRecs | Where-Object { $_.tiering })
                    $tierOff = @($epRecs | Where-Object { -not $_.tiering })
                    if ($epRecs.Count -gt 0) {
                        [void]$Sb.Append('<h3>Cloud tiering</h3>')
                        if ($tierOn.Count -eq 0) {
                            [void]$Sb.Append('<div class="card"><p>Cloud tiering is off on every server endpoint in this service, so <code>cloudTieringStatus</code> is null throughout and no tiering telemetry exists to show - not zero savings, no measurement at all. Each server holds a full local copy of its sync group.</p></div>')
                        } else {
                            [void]$Sb.Append('<table><thead><tr><th>Server endpoint</th><th>Volume size</th><th>In cloud</th><th>Cached locally</th><th>Space savings</th><th>Cache hit<br><span class="afs-sub">bytes % / ratio</span></th><th>Low disk mode</th><th>Files not tiering</th><th>Last tiering result</th><th>Date policy</th></tr></thead><tbody>')
                            foreach ($e in $tierOn) {
                                $ct = $e.tier
                                if ($null -eq $ct) {
                                    [void]$Sb.Append('<tr><td class="mono">' + (E $e.name) + '</td><td colspan="9" class="afs-note">tiering is on but the export carries no cloudTieringStatus for this endpoint</td></tr>')
                                    continue
                                }
                                $sv = Pv $ct 'spaceSavings'
                                $cp = Pv $ct 'cachePerformance'
                                $fn = Pv $ct 'filesNotTiering'
                                $ld = Pv $ct 'lowDiskMode'
                                $dp = Pv $ct 'datePolicyStatus'
                                $savePct = Pv $sv 'spaceSavingsPercent'
                                $saveTxt = '-'
                                if ($null -ne $savePct) { $saveTxt = (Bar $savePct ((Nm $savePct 0) + '%')) + '<br><span class="afs-note">' + (E (Sz (Pv $sv 'spaceSavingsBytes'))) + ' saved</span>' }
                                $hb = Pv $cp 'cacheHitBytesPercent'
                                $hr2 = Pv $cp 'cacheHitRatio'
                                $hitTxt = '<span class="mono">' + (E ([string]$hb)) + '%</span> / <b class="mono">' + (E ([string]$hr2)) + '</b>'
                                $hbn = Num $hb; $hrn = Num $hr2
                                if ($null -ne $hbn -and $null -ne $hrn -and [math]::Abs(($hbn / 100.0) - $hrn) -gt 0.02) {
                                    $hitTxt += '<br><span class="afs-flag">these two disagree; the rule reads cacheHitRatio</span>'
                                }
                                $ldSt = [string](Pv $ld 'state' '')
                                $ldTxt = Pill $ldSt 'ok'
                                if ($ldSt -and $ldSt -ne 'Disabled') { $ldTxt = Pill $ldSt 'bad' }
                                if (-not $ldSt) { $ldTxt = '<span class="afs-note">not reported</span>' }
                                $fnC = Pv $fn 'totalFileCount'
                                $fnTxt = (E ([string]$fnC))
                                $fnN = Num $fnC
                                if ($null -ne $fnN -and $fnN -gt 0) { $fnTxt = '<b class="afs-flag">' + (E (Nm $fnN 0)) + '</b>' }
                                $tp = Pv $dp 'tieredFilesMostRecentAccessTimestamp'
                                $dpTxt = '<span class="afs-note">not reported</span>'
                                if ($tp) {
                                    $dpTxt = '<span class="mono">' + (E $tp) + '</span><br><span class="afs-note">most recently accessed tiered file; policy tiers after ' + (E ([string]$e.tierDays)) + ' d'
                                    $dd = DaysFrom $tp $exportedAt
                                    if ($null -ne $dd) { $dpTxt += ', that file was last touched ' + (E ([math]::Abs($dd))) + ' d before the export' }
                                    $dpTxt += '</span>'
                                }
                                [void]$Sb.Append('<tr><td class="mono">' + (E $e.name) + '</td><td class="num">' + (E (Sz (Pv $sv 'volumeSizeBytes'))) + '</td><td class="num">' + (E (Sz (Pv $sv 'totalSizeCloudBytes'))) + '</td><td class="num">' + (E (Sz (Pv $sv 'cachedSizeBytes'))) + '</td><td>' + $saveTxt + '</td><td>' + $hitTxt + '</td><td>' + $ldTxt + '</td><td class="num">' + $fnTxt + '</td><td>' + (HrHtml (Pv $ct 'lastCloudTieringResult')) + '<br><span class="afs-note">health ' + (E (Pv $ct 'health' '?')) + ', last success ' + (E (Pv $ct 'lastSuccessTimestamp' '-')) + '</span></td><td>' + $dpTxt + '</td></tr>')
                            }
                            [void]$Sb.Append('</tbody></table>')
                        }
                        if ($tierOff.Count -gt 0) {
                            $offNames = @()
                            foreach ($o in $tierOff) { $offNames += ($o.name + ' (' + $o.srvName + ' ' + $o.path + ')') }
                            [void]$Sb.Append('<p class="afs-note"><b>Tiering off, so no tiering telemetry exists</b> on ' + (E $tierOff.Count) + ' endpoint(s): ' + (E ($offNames -join ', ')) + '. <code>cloudTieringStatus</code> is literally null for these - the fields above are absent, not zero. These servers hold the full data set locally, which is also the only topology in which server-side backup of the endpoint is supported.</p>')
                        }
                    }

                    # ---- cloud endpoints, namespace and target shares -----------------
                    if ($ceRecs.Count -gt 0) {
                        [void]$Sb.Append('<h3>Cloud endpoints and their Azure file shares</h3>')
                        [void]$Sb.Append('<table><thead><tr><th>Cloud endpoint</th><th>Sync group</th><th>Storage account / share</th><th>backupEnabled<br><span class="afs-sub">as ARM returns it</span></th><th>Backup coverage<br><span class="afs-sub">share-coverage.json</span></th><th>Change enumeration</th><th>Enumerated namespace</th><th>Share usage vs quota</th><th>Tier / protocol</th></tr></thead><tbody>')
                        foreach ($c in $ceRecs) {
                            $tgt = '<span class="mono">' + (E $c.saName) + '</span><br><span class="mono">' + (E $c.shareName) + '</span>'
                            if ($null -eq $c.acct) { $tgt += '<br><span class="afs-flag">storage account not in this export - the assessment is blind on this share</span>' }
                            elseif ($c.acct.location -and $svcLoc -and $c.acct.location.ToLower() -ne $svcLoc.ToLower()) { $tgt += '<br><span class="afs-flag">account is in ' + (E $c.acct.location) + ', the service is in ' + (E $svcLoc) + '</span>' }
                            $be = Pv $c.props 'backupEnabled'
                            $beTxt = '<span class="mono">' + (E ([string]$be)) + '</span>'
                            if ($null -eq $be) { $beTxt = '<span class="afs-note">absent</span>' }
                            $covTxt = '<span class="afs-note">share not in share-coverage.json</span>'
                            if ($null -ne $c.cov) {
                                if (Truthy (Pv $c.cov 'protected' $false)) {
                                    $covTxt = (Pill ([string](Pv $c.cov 'protectionState' 'Protected')) 'ok') + '<br><span class="afs-note">' + (E (Pv $c.cov 'vault' '')) + ' / ' + (E (Pv $c.cov 'policy' '')) + ', last ' + (E (Pv $c.cov 'lastBackupStatus' '-')) + '</span>'
                                } else { $covTxt = Pill 'not backed up' 'bad' }
                            }
                            $enTxt = '<span class="afs-note">changeEnumerationStatus absent</span>'
                            if ($c.enumPresent) {
                                if ($null -eq $c.lastEnum) { $enTxt = '<span class="afs-flag">present but empty - no enumeration has completed</span>' }
                                else {
                                    $comp = Pv $c.lastEnum 'completedTimestamp'
                                    $enTxt = '<span class="mono">' + (E $comp) + '</span><br><span class="afs-note">' + (E (AgeTxt $comp $exportedAt)) + '; next ' + (E (Pv $c.lastEnum 'nextRunTimestamp' '-')) + '</span>'
                                }
                            }
                            $nsTxt = '<span class="afs-note">-</span>'
                            if ($null -ne $c.lastEnum) {
                                $nsTxt = '<b>' + (E (Sz (Pv $c.lastEnum 'namespaceSizeBytes'))) + '</b><br><span class="afs-note">' + (E (Cnt (Pv $c.lastEnum 'namespaceFilesCount'))) + ' files, ' + (E (Cnt (Pv $c.lastEnum 'namespaceDirectoriesCount'))) + ' dirs</span>'
                            }
                            $qTxt = '<span class="afs-note">share not in the export</span>'
                            $tierTxt2 = '<span class="afs-note">-</span>'
                            if ($null -ne $c.share) {
                                $q = Num (Pv $c.shareProps 'shareQuota')
                                $used = Num (Pv $c.shareProps 'shareUsageBytes')
                                if ($null -ne $q -and $q -gt 0 -and $null -ne $used) {
                                    $pct = ($used / ($q * 1073741824.0)) * 100.0
                                    $hot = ($pct -ge 80)
                                    if ($hot) { $qTxt = Bar $pct ((Nm $pct 0) + '%') -Hot } else { $qTxt = Bar $pct ((Nm $pct 0) + '%') }
                                    $qTxt += '<br><span class="afs-note">' + (E (Sz $used)) + ' used of ' + (E (Sz ($q * 1073741824.0))) + ' quota</span>'
                                    if ($null -ne $c.lastEnum) {
                                        $nsB = Num (Pv $c.lastEnum 'namespaceSizeBytes')
                                        if ($null -ne $nsB -and $used -gt 0 -and [math]::Abs($nsB - $used) / $used -gt 0.1) {
                                            $nsTxt += '<br><span class="afs-flag">the share reports ' + (E (Sz $used)) + ' used - the two numbers disagree</span>'
                                        }
                                    }
                                }
                                $tierTxt2 = (E (Pv $c.shareProps 'accessTier' '-')) + '<br><span class="afs-note">' + (E (Pv $c.shareProps 'enabledProtocols' '-')) + '</span>'
                                if ($null -ne $c.acct) {
                                    $lfs = [string](Pv $c.acct.props 'largeFileSharesState' '')
                                    if ($lfs) {
                                        $tierTxt2 += '<br><span class="afs-note">largeFileShares ' + (E $lfs) + '</span>'
                                        $qq = Num (Pv $c.shareProps 'shareQuota')
                                        if ($lfs -ne 'Enabled' -and $null -ne $qq -and $qq -gt 5120) { $tierTxt2 += '<br><span class="afs-flag">quota above 5 TiB on an account with large file shares ' + (E $lfs) + '</span>' }
                                    }
                                }
                            }
                            [void]$Sb.Append('<tr><td class="mono">' + (E $c.name) + '</td><td>' + (E $c.group) + '</td><td>' + $tgt + '</td><td>' + $beTxt + '</td><td>' + $covTxt + '</td><td>' + $enTxt + '</td><td>' + $nsTxt + '</td><td>' + $qTxt + '</td><td>' + $tierTxt2 + '</td></tr>')
                        }
                        [void]$Sb.Append('</tbody></table>')
                        [void]$Sb.Append('<p class="afs-note"><code>backupEnabled</code> arrives from ARM as a string and is not authoritative for backup coverage - the join in <code>backup/share-coverage.json</code> is, and it is the column beside it. The enumerated namespace and the share usage are shown next to each other deliberately: they are independent measurements and where they disagree, that disagreement is in the source data.</p>')

                        # shares on the same accounts that are NOT sync targets
                        $syncKeys = @{}
                        foreach ($c in $ceRecs) { if ($c.saName -and $c.shareName) { $syncKeys[($c.saName + '/' + $c.shareName).ToLower()] = $true } }
                        $otherShares = @()
                        foreach ($c in $ceRecs) {
                            if ($null -eq $c.acct) { continue }
                            foreach ($s in $c.acct.shares) {
                                $sn = [string](Pv $s 'name' '')
                                $k = ($c.acct.name + '/' + $sn).ToLower()
                                if ($syncKeys.ContainsKey($k)) { continue }
                                if (@($otherShares | Where-Object { $_.key -eq $k }).Count -gt 0) { continue }
                                $otherShares += [pscustomobject]@{ key = $k; acct = $c.acct.name; name = $sn; props = (Pv $s 'properties') }
                            }
                        }
                        if ($otherShares.Count -gt 0) {
                            [void]$Sb.Append('<h4>Shares on the same storage accounts that are NOT File Sync targets</h4>')
                            [void]$Sb.Append('<table><thead><tr><th>Storage account</th><th>Share</th><th>Used</th><th>Quota</th><th>Access tier</th></tr></thead><tbody>')
                            foreach ($o in $otherShares) {
                                [void]$Sb.Append('<tr><td class="mono">' + (E $o.acct) + '</td><td class="mono">' + (E $o.name) + '</td><td class="num">' + (E (Sz (Pv $o.props 'shareUsageBytes'))) + '</td><td class="num">' + (E (Sz ((Num (Pv $o.props 'shareQuota')) * 1073741824.0))) + '</td><td>' + (E (Pv $o.props 'accessTier' '-')) + '</td></tr>')
                            }
                            [void]$Sb.Append('</tbody></table><p class="afs-note">These sit beside the sync hubs and look like File Sync data. They are not: no cloud endpoint points at them, so nothing on any server caches or recalls them.</p>')
                        }
                    }

                    # ---- registered servers -------------------------------------------
                    if ($regRecs.Count -gt 0) {
                        [void]$Sb.Append('<h3>Registered servers <span class="afs-sub">' + (E $regRecs.Count) + ' registered, server-side evidence bundle present for ' + (E @($regRecs | Where-Object { $null -ne $_.bundle }).Count) + '</span></h3>')
                        [void]$Sb.Append('<table><thead><tr><th>Server</th><th>OS version</th><th>Agent</th><th>Agent expires</th><th>Last heartbeat</th><th>Role / cluster</th><th>Auth</th><th>Provisioning</th><th>Endpoints</th><th>Bundle</th></tr></thead><tbody>')
                        foreach ($r in $regRecs) {
                            $p = $r.props
                            $osv = [string](Pv $p 'serverOSVersion' '')
                            $osn = OsName $osv
                            $osTxt = '<span class="mono">' + (E $osv) + '</span>'
                            if ($osn) { $osTxt += '<br><span class="afs-note">' + (E $osn) + '</span>' }
                            if ($osv -and -not $osv.StartsWith('10.0.')) { $osTxt += '<br><span class="afs-flag">not on the 10.0.x kernel Azure File Sync supports</span>' }
                            $av = [string](Pv $p 'agentVersion' '')
                            $avs = [string](Pv $p 'agentVersionStatus' '')
                            $avc = 'ok'
                            if ($avs -and $avs -ne 'Ok') { $avc = 'bad' }
                            $agTxt = '<span class="mono">' + (E $av) + '</span> ' + (Pill $avs $avc)
                            $exp = Pv $p 'agentVersionExpirationDate'
                            $expTxt = '<span class="afs-note">not reported</span>'
                            if ($exp) {
                                $dd = DaysFrom $exp $exportedAt
                                $expTxt = '<span class="mono">' + (E $exp) + '</span>'
                                if ($null -ne $dd) {
                                    $cl4 = 'afs-note'
                                    if ($dd -lt 0) { $expTxt += '<br><span class="afs-flag">expired ' + (E ([math]::Abs($dd))) + ' d before the export</span>' }
                                    else {
                                        if ($dd -le 90) { $cl4 = 'afs-flag' }
                                        $expTxt += '<br><span class="' + $cl4 + '">' + (E $dd) + ' d after the export</span>'
                                    }
                                }
                            }
                            $hb = Pv $p 'lastHeartBeat'
                            $hbTxt = '<span class="afs-note">never</span>'
                            if ($hb) {
                                $hbd = ToDate $hb
                                $cl5 = 'afs-note'
                                if ($null -ne $hbd -and $null -ne $exportedAt -and ($exportedAt - $hbd).TotalHours -gt 1) { $cl5 = 'afs-flag' }
                                $hbTxt = '<span class="mono">' + (E $hb) + '</span><br><span class="' + $cl5 + '">' + (E (AgeTxt $hb $exportedAt)) + '</span>'
                            }
                            $role = [string](Pv $p 'serverRole' '')
                            $cn = [string](Pv $p 'clusterName' '')
                            $ci = [string](Pv $p 'clusterId' '')
                            $roleTxt2 = (E $role)
                            if ($cn) { $roleTxt2 += '<br><span class="afs-note">cluster ' + (E $cn); if (-not $ci) { $roleTxt2 += ', clusterId empty' }; $roleTxt2 += '</span>' }
                            $auth = [string](Pv $p 'activeAuthType' '')
                            $authTxt = Pill $auth 'off'
                            if ($auth -eq 'ManagedIdentity') { $authTxt = Pill $auth 'ok' }
                            if ((Truthy $useId) -and $auth -and $auth -ne 'ManagedIdentity') { $authTxt += '<br><span class="afs-flag">the service uses a managed identity, this server does not</span>' }
                            $epTxt2 = (E $r.eps.Count)
                            if ($r.eps.Count -eq 0) { $epTxt2 = '<b class="afs-flag">0</b><br><span class="afs-note">registered but carries no server endpoint</span>' }
                            $bTxt = '<span class="afs-flag">none</span>'
                            if ($null -ne $r.bundle) { $bTxt = (Pill 'present' 'ok') + '<br><span class="afs-note mono">servers/' + (E $r.bundle.folder) + '</span>' }
                            [void]$Sb.Append('<tr><td><b>' + (E $r.friendly) + '</b><br><span class="afs-note mono">' + (E (Pv $p 'serverName' '')) + '</span></td><td>' + $osTxt + '</td><td>' + $agTxt + '</td><td>' + $expTxt + '</td><td>' + $hbTxt + '</td><td>' + $roleTxt2 + '</td><td>' + $authTxt + '</td><td>' + (E (Pv $p 'provisioningState' '-')) + '</td><td class="num">' + $epTxt2 + '</td><td>' + $bTxt + '</td></tr>')
                        }
                        [void]$Sb.Append('</tbody></table>')
                        $noB = @($regRecs | Where-Object { $null -eq $_.bundle })
                        if ($noB.Count -gt 0) {
                            $nb = @()
                            foreach ($n in $noB) { $nb += $n.friendly }
                            [void]$Sb.Append('<p class="afs-note">Server-side evidence exists for ' + (E ($regRecs.Count - $noB.Count)) + ' of ' + (E $regRecs.Count) + ' registered servers. Missing for: <b>' + (E ($nb -join ', ')) + '</b>. Everything below - volumes, services, filter drivers, clock, sync sessions, dedup, SMB shares, backup and antivirus products - is unknown for those servers. Run <code>Get-AfsServerDiagnostics.ps1</code> on each (elevated) and drop the zip under <code>servers\&lt;hostname&gt;\</code>. The absence of server findings for them is not a clean bill of health.</p>')
                        }
                        [void]$Sb.Append('<p class="afs-note"><code>serverCertificate</code> is present in the export but redacted, so no certificate expiry can be computed from it. The only certificate evidence in the whole export is the free text of <code>debug-diagnose.txt</code> in a server bundle.</p>')
                    }

                    # ---- server-side evidence -----------------------------------------
                    foreach ($r in $regRecs) {
                        if ($null -eq $r.bundle) { continue }
                        $b = $r.bundle
                        $sys = $b.system
                        [void]$Sb.Append('<h3>Server evidence - ' + (E $r.friendly) + ' <span class="afs-sub">bundle collected ' + (E (Pv $sys 'collectedAtUtc' 'time not recorded')) + '</span></h3>')
                        [void]$Sb.Append('<div class="card kv">')
                        [void]$Sb.Append('<div class="k">Hostname / domain</div><div><span class="mono">' + (E (Pv $sys 'hostname' '')) + '</span> in <span class="mono">' + (E (Pv $sys 'domain' 'not domain joined')) + '</span>')
                        $regFqdn = [string](Pv $r.props 'serverName' '')
                        if ($regFqdn -and (Pv $sys 'domain' '')) {
                            $regDom = ''
                            if ($regFqdn -match '^[^.]+\.(.+)$') { $regDom = $Matches[1] }
                            if ($regDom -and $regDom.ToLower() -ne ([string](Pv $sys 'domain' '')).ToLower()) {
                                [void]$Sb.Append(' <span class="afs-flag">the registration says ' + (E $regFqdn) + '; the bundle and the registration are joined on the short hostname only</span>')
                            }
                        }
                        [void]$Sb.Append('</div>')
                        [void]$Sb.Append('<div class="k">Operating system</div><div>' + (E (Pv $sys 'osCaption' '')) + ' <span class="mono">' + (E (Pv $sys 'osVersion' '')) + '</span></div>')
                        $localAv = [string](Pv $sys 'agentFileVersion' '')
                        $regAv = [string](Pv $r.props 'agentVersion' '')
                        $avTxt2 = '<span class="mono">' + (E $localAv) + '</span> on the server / <span class="mono">' + (E $regAv) + '</span> registered'
                        if ($localAv -and $regAv -and $localAv -ne $regAv) { $avTxt2 += ' <span class="afs-flag">the two disagree</span>' }
                        elseif ($localAv -and $regAv) { $avTxt2 += ' ' + (Pill 'match' 'ok') }
                        [void]$Sb.Append('<div class="k">Agent version</div><div>' + $avTxt2 + '</div>')
                        [void]$Sb.Append('<div class="k">Agent auto-update</div><div>' + (E (Pv (Pv $sys 'agentAutoUpdate') 'AutoUpdatePolicy' 'not reported')) + '</div>')
                        [void]$Sb.Append('<div class="k">Collector elevated</div><div>' + (E (Pv $sys 'elevated' 'not reported')) + '</div>')
                        $svcs = AsA (Pv $b.services 'services')
                        $procs = AsA (Pv $b.services 'processes')
                        $fd = Pv $b.services 'filterDriversPresent'
                        $chips = ''
                        foreach ($s in $svcs) {
                            $sn = [string](Pv $s 'Name' '')
                            $st = [string](Pv $s 'Status' '')
                            $k = 'off'
                            if ($st -eq 'Running') { $k = 'ok' } elseif ($st) { $k = 'bad' }
                            $chips += Pill ($sn + ' ' + $st) $k
                        }
                        if ($svcs.Count -eq 0) { $chips = '<span class="afs-note">services.json was not in the bundle</span>' }
                        [void]$Sb.Append('<div class="k">Services</div><div>' + $chips + '</div>')
                        $pchips = ''
                        foreach ($pr in $procs) { $pchips += Pill ([string](Pv $pr 'Name' '')) 'ok' }
                        if ($procs.Count -eq 0) { $pchips = '<span class="afs-note">no processes recorded</span>' }
                        [void]$Sb.Append('<div class="k">Processes</div><div>' + $pchips + '</div>')
                        $dchips = ''
                        if ($null -ne $fd) {
                            foreach ($dn2 in @('StorageSync', 'StorageSyncGuard')) {
                                $pv2 = Pv $fd $dn2
                                $k2 = 'bad'
                                $lbl2 = $dn2 + ' missing'
                                if (Truthy $pv2) { $k2 = 'ok'; $lbl2 = $dn2 + ' loaded' }
                                $dchips += Pill $lbl2 $k2
                            }
                        } else { $dchips = '<span class="afs-note">filter driver state not recorded</span>' }
                        if ($b.fltmc) { $dchips += ' <span class="afs-note mono">fltmc: ' + (E (Trunc (($b.fltmc -replace '\s+', ' ').Trim()) 80)) + '</span>' }
                        [void]$Sb.Append('<div class="k">Filter drivers</div><div>' + $dchips + '</div>')
                        [void]$Sb.Append('</div>')

                        # volumes joined to endpoint policy
                        $vols = AsA (Pv $b.volumes 'volumes')
                        if ($vols.Count -gt 0) {
                            [void]$Sb.Append('<h4>Volume headroom against the endpoint policy</h4>')
                            [void]$Sb.Append('<table><thead><tr><th>Volume</th><th>Size</th><th>Free</th><th>Free %</th><th>Endpoint(s) on this volume</th><th>Free-space policy</th><th>Delta</th><th>Cluster size</th></tr></thead><tbody>')
                            foreach ($v in $vols) {
                                $dr = [string](Pv $v 'drive' '')
                                $mine2 = @($r.eps | Where-Object { $_.drive -eq $dr })
                                $fp = Num (Pv $v 'freePercent')
                                $polTxt = '<span class="afs-note">no endpoint here</span>'
                                $deltaTxt = '<span class="afs-note">-</span>'
                                $epTxt3 = '<span class="afs-note">none</span>'
                                if ($mine2.Count -gt 0) {
                                    $bits2 = @()
                                    foreach ($m in $mine2) { $bits2 += ($m.name + ' ' + $m.path) }
                                    $epTxt3 = '<span class="mono">' + (($bits2 | ForEach-Object { E $_ }) -join '<br>') + '</span>'
                                    $pol = $null
                                    foreach ($m in $mine2) {
                                        $eff2 = Num (Pv (Pv $m.tier 'volumeFreeSpacePolicyStatus') 'effectiveVolumeFreeSpacePolicy')
                                        if ($null -ne $eff2) { $pol = $eff2; break }
                                        $cfg2 = Num $m.freeCfg
                                        if ($null -ne $cfg2 -and $null -eq $pol) { $pol = $cfg2 }
                                    }
                                    if ($null -ne $pol) {
                                        $polTxt = '<span class="mono">' + (E (Nm $pol 0)) + '%</span>'
                                        if ($null -ne $fp) {
                                            $delta = $fp - $pol
                                            $dc2 = 'afs-note'
                                            if ($delta -le 5) { $dc2 = 'afs-flag' }
                                            $sign = ''
                                            if ($delta -gt 0) { $sign = '+' }
                                            $deltaTxt = '<span class="' + $dc2 + ' mono">' + $sign + (E (Nm $delta 1)) + ' pt</span>'
                                            if ($delta -lt 0) { $deltaTxt += '<br><span class="afs-flag">the policy cannot be met - the agent tiers continuously</span>' }
                                        }
                                    }
                                }
                                $bpc = Num (Pv $v 'bytesPerCluster')
                                $bpcTxt = (E (Cnt $bpc)) + ' B'
                                if ($null -ne $bpc -and $bpc -ge 65536 -and $mine2.Count -gt 0) { $bpcTxt += '<br><span class="afs-flag">each tiered file still occupies one cluster</span>' }
                                [void]$Sb.Append('<tr><td class="mono">' + (E $dr) + ' ' + (E (Pv $v 'label' '')) + '</td><td class="num">' + (E (Cnt (Pv $v 'sizeGiB'))) + ' GiB</td><td class="num">' + (E (Cnt (Pv $v 'freeGiB'))) + ' GiB</td><td class="num">' + (E (Nm $fp 1)) + '%</td><td>' + $epTxt3 + '</td><td class="num">' + $polTxt + '</td><td class="num">' + $deltaTxt + '</td><td class="num">' + $bpcTxt + '</td></tr>')
                            }
                            [void]$Sb.Append('</tbody></table>')
                        }

                        # posture chips
                        $ded = AsA (Pv $b.volumes 'dedup')
                        $fts = AsA (Pv $b.volumes 'features')
                        $wss = AsA (Pv $b.volumes 'windowsSearchScopes')
                        [void]$Sb.Append('<div class="card kv">')
                        $smbTxt = '<span class="afs-note">no SMB shares recorded</span>'
                        if ($b.smb.Count -gt 0) {
                            $sb2 = @()
                            foreach ($s in $b.smb) {
                                $pth = [string](Pv $s 'Path' '')
                                $onEp = @($r.eps | Where-Object { $_.path -and ($pth.ToLower() -eq $_.path.ToLower() -or (IsUnder $_.path $pth)) })
                                $t2 = [string](Pv $s 'Name' '') + ' -> ' + $pth
                                if ($onEp.Count -gt 0) { $t2 += ' (over a server endpoint)' }
                                $sb2 += $t2
                            }
                            $smbTxt = (($sb2 | ForEach-Object { E $_ }) -join '<br>')
                        }
                        [void]$Sb.Append('<div class="k">SMB shares</div><div class="mono">' + $smbTxt + '</div>')
                        $ssrTxt = '<span class="afs-note">not recorded</span>'
                        if ($b.ssr.Count -gt 0) {
                            $s3 = ''
                            foreach ($x in $b.ssr) {
                                $res = [string](Pv $x 'result' '')
                                $k3 = 'off'
                                if ($res -match 'True') { $k3 = 'ok' } elseif ($res -match 'False') { $k3 = 'bad' }
                                $s3 += Pill ([string](Pv $x 'drive' '') + ' ' + ($res -replace '^SelfServiceRestore\s*:\s*', '')) $k3
                            }
                            $ssrTxt = $s3
                        }
                        [void]$Sb.Append('<div class="k">Self-service restore</div><div>' + $ssrTxt + '</div>')
                        $dedTxt = '<span class="afs-note">no deduplicated volume</span>'
                        if ($ded.Count -gt 0) {
                            $d3 = @()
                            foreach ($x in $ded) {
                                $mfa = Pv $x 'MinimumFileAgeDays'
                                $t3 = [string](Pv $x 'Volume' '') + ' enabled=' + [string](Pv $x 'Enabled' '') + ', MinimumFileAgeDays=' + [string]$mfa + ', ' + (Sz (Pv $x 'SavedSpace')) + ' saved'
                                if ($null -ne $mfa) { $t3 += ' - this delays the tiering date policy by the same ' + [string]$mfa + ' days' }
                                $d3 += $t3
                            }
                            $dedTxt = (($d3 | ForEach-Object { E $_ }) -join '<br>')
                        }
                        [void]$Sb.Append('<div class="k">Data deduplication</div><div>' + $dedTxt + '</div>')
                        $ftTxt = '<span class="afs-note">not recorded</span>'
                        if ($fts.Count -gt 0) {
                            $f3 = ''
                            foreach ($x in $fts) {
                                $inst = Truthy (Pv $x 'Installed' $false)
                                $k4 = 'off'
                                $lbl3 = [string](Pv $x 'Name' '') + ' not installed'
                                if ($inst) { $k4 = 'warn'; $lbl3 = [string](Pv $x 'Name' '') + ' installed' }
                                $f3 += Pill $lbl3 $k4
                            }
                            $ftTxt = $f3
                        }
                        [void]$Sb.Append('<div class="k">File server roles</div><div>' + $ftTxt + '</div>')
                        $wsTxt = '<span class="afs-note">no Windows Search index scope recorded</span>'
                        if ($wss.Count -gt 0) {
                            $w3 = @()
                            foreach ($x in $wss) { $w3 += ([string](Pv $x 'URL' '') + ' include=' + [string](Pv $x 'Include' '')) }
                            $wsTxt = '<span class="mono">' + (($w3 | ForEach-Object { E $_ }) -join '<br>') + '</span>'
                        }
                        [void]$Sb.Append('<div class="k">Windows Search scopes</div><div>' + $wsTxt + '</div>')
                        $bav = AsA (Pv $b.programs 'backupOrAvProducts')
                        $bavTxt = '<span class="afs-note">none recorded</span>'
                        if ($bav.Count -gt 0) {
                            $b3 = @()
                            foreach ($x in $bav) { $b3 += ([string](Pv $x 'DisplayName' '') + ' ' + [string](Pv $x 'DisplayVersion' '') + ' (' + [string](Pv $x 'Publisher' '') + ')') }
                            $bavTxt = (($b3 | ForEach-Object { E $_ }) -join '<br>')
                        }
                        [void]$Sb.Append('<div class="k">Backup / AV products</div><div>' + $bavTxt + '</div>')
                        $def = Pv $b.programs 'defender'
                        $defTxt = '<span class="afs-note">not recorded</span>'
                        if ($null -ne $def) {
                            $ex = AsA (Pv $def 'exclusionPaths')
                            $defTxt = 'realTime=' + (E ([string](Pv $def 'realTime' '?'))) + ', amRunning=' + (E ([string](Pv $def 'amRunning' '?'))) + ', ' + (E $ex.Count) + ' exclusion path(s)'
                            if ($ex.Count -gt 0) { $defTxt += '<br><span class="mono">' + (($ex | ForEach-Object { E ([string]$_) }) -join '<br>') + '</span>' }
                        }
                        [void]$Sb.Append('<div class="k">Microsoft Defender</div><div>' + $defTxt + '</div>')
                        [void]$Sb.Append('</div>')

                        # sync session digest + telemetry
                        if ($b.digest.Count -gt 0) {
                            [void]$Sb.Append('<h4>Sync sessions on this server <span class="afs-sub">event 9102, rolled up</span></h4>')
                            [void]$Sb.Append('<table><thead><tr><th>Time</th><th>Sync group</th><th>Direction</th><th>HResult</th><th>Per-item errors</th></tr></thead><tbody>')
                            foreach ($dg in ($b.digest | Sort-Object -Property @{ Expression = { [string](Pv $_ 'time' '') }; Descending = $true })) {
                                $pe = Num (Pv $dg 'perItemErrorCount')
                                $peTxt = (E ([string](Pv $dg 'perItemErrorCount' '0')))
                                if ($null -ne $pe -and $pe -gt 0) { $peTxt = '<b class="afs-flag">' + (E (Nm $pe 0)) + '</b>' }
                                [void]$Sb.Append('<tr><td class="mono">' + (E (Pv $dg 'time' '')) + '</td><td>' + (E (Pv $dg 'syncGroup' '')) + '</td><td>' + (E (Pv $dg 'direction' '')) + '</td><td>' + (HrHtml (Pv $dg 'hresult')) + '</td><td class="num">' + $peTxt + '</td></tr>')
                            }
                            [void]$Sb.Append('</tbody></table>')
                        }
                        if ($b.telemetry.Count -gt 0) {
                            [void]$Sb.Append('<h4>Telemetry log</h4><table><thead><tr><th>Time</th><th>Event</th><th>Level</th><th>Message</th></tr></thead><tbody>')
                            foreach ($ev in $b.telemetry) {
                                [void]$Sb.Append('<tr><td class="mono">' + (E (Pv $ev 'time' '')) + '</td><td class="mono">' + (E (Pv $ev 'id' '')) + '</td><td>' + (E (Pv $ev 'level' '')) + '</td><td>' + (E (Pv $ev 'message' '')) + '</td></tr>')
                            }
                            [void]$Sb.Append('</tbody></table>')
                        }
                        if ($b.oplog.Count -gt 0) {
                            [void]$Sb.Append('<h4>Operational log</h4><table><thead><tr><th>Time</th><th>Event</th><th>Level</th><th>Message</th></tr></thead><tbody>')
                            foreach ($ev in $b.oplog) {
                                [void]$Sb.Append('<tr><td class="mono">' + (E (Pv $ev 'time' '')) + '</td><td class="mono">' + (E (Pv $ev 'id' '')) + '</td><td>' + (E (Pv $ev 'level' '')) + '</td><td>' + (E (Pv $ev 'message' '')) + '</td></tr>')
                            }
                            [void]$Sb.Append('</tbody></table>')
                        }

                        # free-text diagnostics, verbatim
                        $txts = @(
                            @{ t = 'Debug-StorageSyncServer -Diagnose'; f = 'debug-diagnose.txt'; v = $b.diagnose },
                            @{ t = 'Debug-StorageSyncServer -TestNetworkConnectivity'; f = 'debug-network.txt'; v = $b.netTxt },
                            @{ t = 'FileSyncErrorsReport'; f = 'debug-filesyncerrors.txt'; v = $b.errTxt },
                            @{ t = 'w32tm /query /status'; f = 'w32tm.txt'; v = $b.w32tm },
                            @{ t = 'netsh winhttp show proxy'; f = 'winhttp-proxy.txt'; v = $b.proxy }
                        )
                        $anyTxt = $false
                        foreach ($t in $txts) { if (-not [string]::IsNullOrWhiteSpace([string]$t.v)) { $anyTxt = $true } }
                        if ($anyTxt) {
                            [void]$Sb.Append('<h4>Server diagnostics, verbatim <span class="afs-sub">the only free-text evidence in the export; fail and error tokens are highlighted, nothing is paraphrased</span></h4>')
                            foreach ($t in $txts) {
                                if ([string]::IsNullOrWhiteSpace([string]$t.v)) { continue }
                                [void]$Sb.Append('<p class="afs-note"><b>' + (E $t.t) + '</b> <span class="mono">' + (E $t.f) + '</span></p>')
                                [void]$Sb.Append('<pre class="afs-pre">' + (Marked ([string]$t.v).TrimEnd()) + '</pre>')
                            }
                        }
                        if ($b.berrors.Count -gt 0) {
                            [void]$Sb.Append('<h4>Collector errors in this bundle</h4><table><thead><tr><th>Where</th><th>Detail</th></tr></thead><tbody>')
                            foreach ($er in $b.berrors) {
                                [void]$Sb.Append('<tr><td class="mono">' + (E (Pv $er 'where' '')) + '</td><td class="afs-note">' + (E (Trunc ([string](Pv $er 'detail' '')) 400)) + '</td></tr>')
                            }
                            [void]$Sb.Append('</tbody></table>')
                        }
                    }
                    $stray = @()
                    foreach ($k in @($bundles.Keys)) { if (-not $usedBundles.ContainsKey($k)) { $stray += $bundles[$k] } }
                    if ($stray.Count -gt 0 -and $regRecs.Count -gt 0) {
                        $sn2 = @()
                        foreach ($s in $stray) { $sn2 += ($s.hostname + ' (servers/' + $s.folder + ')') }
                        [void]$Sb.Append('<p class="afs-note">' + (E $stray.Count) + ' server bundle(s) in the export match no registered server of this service on the short hostname: <b>' + (E ($sn2 -join ', ')) + '</b>. Either the server is registered to a different Storage Sync Service, or the short hostnames collide across domains.</p>')
                    }

                    # ---- metrics -------------------------------------------------------
                    [void]$Sb.Append('<h3>Metrics <span class="afs-sub">' + (E ([string](Pv $manifest 'metricsLookbackDays' 'unrecorded'))) + '-day lookback ending at the export</span></h3>')
                    $metricErr = @($expErrors | Where-Object { ([string](Pv $_ 'where' '')) -like 'metric*' -and (($svcName -eq '') -or ([string](Pv $_ 'where' '')) -like ('*' + $svcName + '*')) })
                    if ($metricsSkipped) {
                        [void]$Sb.Append('<div class="card"><p>Metrics collection was skipped for this export (<code>manifest.metricsSkipped = true</code>), so there is no recall volume, no transferred bytes, no per-item error counts and no heartbeat series here. Re-run the export without <code>-SkipMetrics</code> to fill this panel.</p></div>')
                    } elseif ($null -eq $metrics) {
                        [void]$Sb.Append('<div class="card"><p>The export contains no <code>metrics.json</code> for this service, so no Azure Monitor series can be shown.</p></div>')
                    } else {
                        $order = @('StorageSyncRecallTotalSizeBytes', 'StorageSyncRecalledTotalNetworkBytes', 'StorageSyncRecallThroughputBytesPerSecond', 'StorageSyncTieredDataSizeBytes', 'StorageSyncTieringCacheSizeBytes', 'StorageSyncComputedCacheHitRate', 'StorageSyncBatchTransferredFileBytes', 'ServerSyncSessionResult', 'StorageSyncSyncSessionPerItemErrorsCount', 'StorageSyncSyncSessionAppliedFilesCount', 'StorageSyncLowDiskModeCount', 'StorageSyncServerHeartbeat', 'StorageSyncAgentVersionExpirationDays')
                        $keys = @()
                        try { $keys = @($metrics.PSObject.Properties.Name) } catch { $keys = @() }
                        $ordered = @()
                        foreach ($o in $order) { if ($keys -contains $o) { $ordered += $o } }
                        foreach ($k in $keys) { if ($ordered -notcontains $k) { $ordered += $k } }
                        if ($ordered.Count -eq 0) {
                            [void]$Sb.Append('<div class="card"><p><code>metrics.json</code> is present but holds no metric keys.</p></div>')
                        } else {
                            [void]$Sb.Append('<table><thead><tr><th>Metric</th><th>Unit / interval</th><th>Series</th><th>Peak in window</th><th>Shape</th></tr></thead><tbody>')
                            foreach ($k in $ordered) {
                                $mv = Pv $metrics $k
                                if ($null -eq $mv) {
                                    $why = ''
                                    foreach ($er in $metricErr) {
                                        $det = [string](Pv $er 'detail' '')
                                        if ($det -like ('*' + $k + '*')) { $why = [string](Pv $er 'where' '') + ' - ' + (Trunc $det 320); break }
                                    }
                                    $cell = '<span class="afs-note">the provider returned nothing for this metric</span>'
                                    if ($why) { $cell = '<span class="afs-flag">rejected by the provider</span><br><span class="afs-note mono">' + (E $why) + '</span>' }
                                    [void]$Sb.Append('<tr><td class="mono">' + (E $k) + '</td><td colspan="4">' + $cell + '</td></tr>')
                                    continue
                                }
                                $vals = AsA (Pv $mv 'value')
                                $unit = ''
                                $series = @()
                                foreach ($v in $vals) {
                                    if (-not $unit) { $unit = [string](Pv $v 'unit' '') }
                                    foreach ($ts in (AsA (Pv $v 'timeseries'))) {
                                        $dims = @()
                                        foreach ($md in (AsA (Pv $ts 'metadatavalues'))) { $dims += ([string](Pv (Pv $md 'name') 'value' '') + '=' + [string](Pv $md 'value' '')) }
                                        $pts = @()
                                        foreach ($d in (AsA (Pv $ts 'data'))) {
                                            $val = $null
                                            foreach ($agg in @('total', 'average', 'maximum', 'minimum', 'count')) {
                                                $cand = Num (Pv $d $agg)
                                                if ($null -ne $cand) { $val = $cand; break }
                                            }
                                            if ($null -ne $val) { $pts += [pscustomobject]@{ t = [string](Pv $d 'timeStamp' ''); v = $val } }
                                        }
                                        $series += [pscustomobject]@{ dim = ($dims -join ' '); pts = $pts }
                                    }
                                }
                                $withData = @($series | Where-Object { $_.pts.Count -gt 0 })
                                $intv = [string](Pv $mv 'interval' '')
                                $unitTxt = (E $unit) + '<br><span class="afs-note mono">' + (E $intv) + '</span>'
                                if ($withData.Count -eq 0) {
                                    $sTxt = '<span class="afs-note">' + (E $series.Count) + ' series, no data points in the window</span>'
                                    [void]$Sb.Append('<tr><td class="mono">' + (E $k) + '</td><td>' + $unitTxt + '</td><td colspan="3">' + $sTxt + '</td></tr>')
                                    continue
                                }
                                foreach ($s in $withData) {
                                    $mx = 0.0
                                    foreach ($p in $s.pts) { if ($p.v -gt $mx) { $mx = $p.v } }
                                    $peak = $null
                                    foreach ($p in $s.pts) { if ($p.v -eq $mx) { $peak = $p; break } }
                                    $peakTxt = '-'
                                    if ($null -ne $peak) {
                                        $pv3 = $peak.v
                                        if ($unit -eq 'Bytes' -or $unit -eq 'BytesPerSecond') { $peakTxt = (E (Sz $pv3)) } else { $peakTxt = (E (Nm $pv3 2)) }
                                        $peakTxt += '<br><span class="afs-note mono">' + (E $peak.t) + '</span>'
                                    }
                                    $spark = '<svg viewBox="0 0 220 46" role="img" aria-label="' + (E ($k + ' ' + $s.dim)) + '" style="width:220px;height:46px">'
                                    $n = $s.pts.Count
                                    $bw = 200.0 / [math]::Max(1, $n)
                                    $i = 0
                                    foreach ($p in $s.pts) {
                                        $h = 0.0
                                        if ($mx -gt 0) { $h = 34.0 * ($p.v / $mx) }
                                        if ($h -lt 1 -and $p.v -gt 0) { $h = 1.0 }
                                        $x = 8.0 + ($i * $bw)
                                        $cls2 = 'sv-spark'
                                        if ($mx -gt 0 -and $p.v -eq $mx -and $unit -eq 'Bytes' -and $mx -ge 536870912000.0) { $cls2 = 'sv-spark hot' }
                                        $spark += '<rect class="' + $cls2 + '" x="' + (Nm $x 1) + '" y="' + (Nm (38.0 - $h) 1) + '" width="' + (Nm ([math]::Max(2.0, $bw - 2.0)) 1) + '" height="' + (Nm $h 1) + '"/>'
                                        $i++
                                    }
                                    $spark += '<line class="sv-axis" x1="6" y1="38.5" x2="214" y2="38.5"/></svg>'
                                    $dimTxt = $s.dim
                                    if (-not $dimTxt) { $dimTxt = 'no dimension' }
                                    [void]$Sb.Append('<tr><td class="mono">' + (E $k) + '</td><td>' + $unitTxt + '</td><td class="mono">' + (E $dimTxt) + '<br><span class="afs-note">' + (E $s.pts.Count) + ' points</span></td><td class="num">' + $peakTxt + '</td><td>' + $spark + '</td></tr>')
                                }
                            }
                            [void]$Sb.Append('</tbody></table>')
                            $hasRecall = $false
                            foreach ($rk in @('StorageSyncRecallTotalSizeBytes', 'StorageSyncRecalledTotalNetworkBytes', 'StorageSyncRecallThroughputBytesPerSecond')) {
                                if (($keys -contains $rk) -and ($null -ne (Pv $metrics $rk))) { $hasRecall = $true }
                            }
                            if (-not $hasRecall) {
                                [void]$Sb.Append('<p class="afs-note"><b>No recall series is available.</b> <code>StorageSyncRecallTotalSizeBytes</code> does not exist on the live provider - it is rejected with HTTP 400 and the valid metric list is returned in <code>errors.json</code>. The recall evidence has to come from <code>StorageSyncRecalledTotalNetworkBytes</code>, <code>StorageSyncRecallThroughputBytesPerSecond</code> or <code>StorageSyncComputedCacheHitRate</code>, and where none of those were collected there is no recall measurement in this export at all.</p>')
                            } else {
                                [void]$Sb.Append('<p class="afs-note">A single-day recall spike of the same order as the local cache is the signature of something walking the whole volume - a backup agent, an antivirus full scan, or a search indexer. Compare the peak above against the cached size in the tiering table and against the backup, antivirus and Windows Search evidence on the server.</p>')
                            }
                        }
                    }
                    if ($metricErr.Count -gt 0) {
                        [void]$Sb.Append('<h4>Export gaps affecting this service</h4><table><thead><tr><th>Call</th><th>What Azure returned</th><th>At</th></tr></thead><tbody>')
                        foreach ($er in $metricErr) {
                            [void]$Sb.Append('<tr><td class="mono">' + (E (Pv $er 'where' '')) + '</td><td class="afs-note mono">' + (E (Trunc ([string](Pv $er 'detail' '')) 600)) + '</td><td class="mono">' + (E (Pv $er 'at' '')) + '</td></tr>')
                        }
                        [void]$Sb.Append('</tbody></table><p class="afs-note">These are quoted rather than shown as an empty chart: a panel that is blank because a call failed reads the same as a panel that is blank because the estate is quiet, and they are not the same thing.</p>')
                    }
                }

                if ($bundleWanted -gt 0) {
                    [void]$Sb.Append('<h3>Server-side coverage of this export</h3>')
                    $covPct = 0.0
                    if ($bundleWanted -gt 0) { $covPct = (100.0 * $bundleFound / $bundleWanted) }
                    $hotCov = ($covPct -lt 100)
                    $covBar = Bar $covPct (($bundleFound.ToString()) + ' of ' + $bundleWanted.ToString())
                    if ($hotCov) { $covBar = Bar $covPct (($bundleFound.ToString()) + ' of ' + $bundleWanted.ToString()) -Hot }
                    [void]$Sb.Append('<div class="card"><p>Server-side evidence exists for ' + $covBar + ' registered servers. The Azure side of every server is complete because it comes from ARM; the server side exists only where someone ran <code>Get-AfsServerDiagnostics.ps1</code> and dropped the zip under <code>servers\</code>. Read a missing bundle as "unknown", never as "fine".</p></div>')
                }

                # ---- evidence to rule legend ---------------------------------------
                [void]$Sb.Append('<h3>Which rules read which panel</h3>')
                [void]$Sb.Append('<p class="afs-lede">This tab measures; the Findings tab judges. The mapping below says which panel each rule was computed from, and what the rule looks at - so a number here can be traced to a verdict there, and a verdict there can be checked against the number here.</p>')
                [void]$Sb.Append('<table><thead><tr><th>Panel on this tab</th><th>Rules</th><th>What the rule checks</th></tr></thead><tbody>')
                $legend = @(
                    @{ p = 'Service header strip'; r = 'AFS-11, AFS-12, AFS-18, AFS-19, MON-01, OPS-01'; c = 'incomingTrafficPolicy AllowVirtualNetworksOnly with no Approved private endpoint; useIdentity not true; no CanNotDelete lock; server activeAuthType not ManagedIdentity while the service uses one; no metric alerts scoped to the service; tags lacking owner and environment' },
                    @{ p = 'Sync groups / topology'; r = 'AFS-13, AFS-16, AFS-17'; c = 'cloud endpoint storage account not among the exported accounts; service location differs from the cloud endpoint account location; a sync group with 0 server endpoints' },
                    @{ p = 'Server endpoints - placement and policy'; r = 'AFS-09, AFS-10, TIER-01, TIER-04'; c = 'serverLocalPath starts with C:\; one serverLocalPath is a prefix of another on the same server; cloudTiering off; volumeFreeSpacePercent below 10' },
                    @{ p = 'Server endpoints - sync health'; r = 'AFS-01, AFS-02, AFS-03'; c = 'combinedHealth not Healthy; totalPersistentFilesNotSyncingCount or per-item error count above 0; lastSyncSuccessTimestamp older than 24 h at export time' },
                    @{ p = 'Cloud tiering'; r = 'TIER-02, TIER-03, TIER-05, TIER-06'; c = 'cloudTieringStatus.health not Healthy or lastCloudTieringResult not 0; lowDiskMode Enabled; cachePerformance.cacheHitRatio below 0.8; recall above 500 GiB in a day' },
                    @{ p = 'Cloud endpoints and their shares'; r = 'AFS-08, AFS-14, DATA-01, DATA-02, DATA-03, DATA-06, SEC-03, SEC-05'; c = 'change enumeration older than 48 h or absent; storage firewall blocking the Storage Sync Service; LRS on a synced account; share soft delete off or under 14 days; share above 80 % of quota; large file shares not enabled; the account public endpoint open to all networks, or disabled outright' },
                    @{ p = 'Registered servers'; r = 'AFS-04, AFS-05, AFS-06, AFS-07, AFS-15'; c = 'lastHeartBeat older than 1 h at export time; agentVersionStatus Expired or Blocked or expiring within 90 days; agent below the latest major version; serverOSVersion off the 10.0.x kernel; clusterName present' },
                    @{ p = 'Server evidence'; r = 'SRV-01 to SRV-11, OPS-03'; c = 'FileSyncSvc, AzureStorageSyncMonitor and the StorageSync / StorageSyncGuard filter drivers; backup or antivirus product on a tiered endpoint; volume free space at or below the tiering policy; Windows Search or DFS-R on an endpoint path; clock offset above 5 minutes; 9102 sessions with a non-zero HResult; self-service restore off; Debug-StorageSyncServer reporting a failure; 64 KiB clusters on a tiered volume; the server agent version differing from the registered one; deduplication on a tiered volume; and no bundle at all for a registered server' },
                    @{ p = 'Metrics and export gaps'; r = 'TIER-06, MON-01, OPS-02'; c = 'recall volume per day; alert rules on the service; errors.json not empty' }
                )
                foreach ($l in $legend) {
                    [void]$Sb.Append('<tr><td>' + (E $l.p) + '</td><td class="id">' + (E $l.r) + '</td><td class="afs-note">' + (E $l.c) + '</td></tr>')
                }
                [void]$Sb.Append('</tbody></table>')
                [void]$Sb.Append('<p class="afs-note">Rule IDs are cross-references only. Severity, recommendation and the Microsoft reference for each one live on the Findings tab and in <code>docs/RULES.md</code>; nothing on this tab is a verdict.</p>')
            }
        }
    } catch {
        $why = [System.Net.WebUtility]::HtmlEncode([string]$_.Exception.Message)
        [void]$Sb.Append('<div class="card"><p>The File Sync evidence could not be rendered in full from this export: <code>' + $why + '</code></p>')
        [void]$Sb.Append('<p>Anything already shown above is accurate; the rest of the report is unaffected, and the raw data is in the export folder itself.</p></div>')
    }
    [void]$Sb.Append('</section>')
}
