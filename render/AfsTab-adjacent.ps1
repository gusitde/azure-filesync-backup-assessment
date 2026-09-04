function Add-AfsTabGuardrails {
    <#
      Guardrails - the adjacent controls that decide whether a mistake is survivable:
      Microsoft Defender for Storage (subscription pricing and the per-account override),
      resource locks (per resource AND the subscription-wide inventory nothing else reads),
      Azure Monitor metric alerts (and whether they notify anybody), and Data Protection
      (Backup) vault security settings.

      Evidence only. The Findings tab owns severity; this tab shows what was captured, from
      which file, and - where the export cannot tell "off" from "not readable" - says so.
    #>
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
        [string]$ExportRoot
    )

    $g = New-Object System.Text.StringBuilder
    try {

    # ---- helpers ---------------------------------------------------------------------
    function W { param([string]$s) [void]$g.Append($s) }
    function GrdEnc { param($v) if ($null -eq $v) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$v) }

    function GrdRead {
        # Four different "empty" arrive from the exporter: absent file, zero bytes, the literal
        # text 'null', and a real empty array. They mean different things, so they are kept apart.
        param([string]$Path)
        $r = @{ state = 'missing'; obj = $null }
        if ([string]::IsNullOrWhiteSpace($Path)) { return $r }
        if (-not (Test-Path -LiteralPath $Path)) { return $r }
        $t = $null
        try { $t = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue } catch { $t = $null }
        if ($null -eq $t) { $r.state = 'empty'; return $r }
        $t = [string]$t
        if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
        if ([string]::IsNullOrWhiteSpace($t)) { $r.state = 'empty'; return $r }
        if ($t.Trim() -eq 'null') { $r.state = 'null'; return $r }
        try { $r.obj = ($t | ConvertFrom-Json); $r.state = 'ok' } catch { $r.state = 'unparsable' }
        return $r
    }
    function GrdList {
        # ARM collapses a single-item list to a bare object. ,@() normalises both, exactly as
        # the assessor's LoadList does; anything that iterates the raw value breaks on real data.
        param($Read)
        if ($null -eq $Read) { return ,@() }
        if ($Read.state -ne 'ok') { return ,@() }
        if ($null -eq $Read.obj) { return ,@() }
        return ,@($Read.obj)
    }
    function GrdProp {
        param($Obj, [string]$Name, $Default = $null)
        if ($null -eq $Obj) { return $Default }
        try {
            if ($Obj -is [System.Collections.IDictionary]) {
                if ($Obj.Contains($Name)) { $v = $Obj[$Name]; if ($null -eq $v) { return $Default } ; return $v }
                return $Default
            }
            $p = $Obj.PSObject.Properties[$Name]
            if ($null -eq $p) { return $Default }
            $v = $p.Value
            if ($null -eq $v) { return $Default }
            return $v
        } catch { return $Default }
    }
    function GrdPath {
        param($Obj, [string]$Dotted, $Default = $null)
        $cur = $Obj
        foreach ($seg in ($Dotted -split '\.')) {
            if ($null -eq $cur) { return $Default }
            $cur = GrdProp $cur $seg $null
        }
        if ($null -eq $cur) { return $Default }
        return $cur
    }
    function GrdChip {
        param([string]$Kind, [string]$Text, [string]$Tip = '')
        $t = ''
        if ($Tip) { $t = " title=`"$(GrdEnc $Tip)`"" }
        return "<span class=`"gr-chip gr-$Kind`"$t>$(GrdEnc $Text)</span>"
    }
    function GrdOnOff {
        param($V, [string]$Unknown = 'not captured', [string]$Tip = '')
        if ($null -eq $V) { return (GrdChip 'unknown' $Unknown $Tip) }
        if ($V -is [bool]) { if ($V) { return (GrdChip 'on' 'true' $Tip) } ; return (GrdChip 'off' 'false' $Tip) }
        $s = [string]$V
        if ([string]::IsNullOrWhiteSpace($s)) { return (GrdChip 'unknown' $Unknown $Tip) }
        if ($s -match '^(true|on|alwayson|enabled)$') { return (GrdChip 'on' $s $Tip) }
        if ($s -match '^(false|off|disabled|notcovered)$') { return (GrdChip 'off' $s $Tip) }
        return (GrdChip 'neutral' $s $Tip)
    }
    function GrdRule {
        param([string]$Ids)
        $o = ''
        foreach ($i in ($Ids -split ',')) {
            $t = $i.Trim(); if (-not $t) { continue }
            $o += "<span class=`"gr-rule`" title=`"rule $t - see the Findings tab`">$(GrdEnc $t)</span>"
        }
        return $o
    }
    function GrdSubId {
        param([string]$Id)
        if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
        $p = @($Id -split '/')
        if ($p.Count -ge 3) { return [string]$p[2] }
        return ''
    }
    function GrdLeaf {
        param([string]$Id)
        if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
        $p = @($Id -split '/')
        return [string]$p[$p.Count - 1]
    }
    function GrdDur {
        param($D)
        $s = [string]$D
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s -eq 'PT0S') { return 'none left' }
        if ($s -match '^P(\d+)D$')  { return "$($Matches[1]) day(s)" }
        if ($s -match '^P(\d+)W$')  { return "$($Matches[1]) week(s)" }
        if ($s -match '^P(\d+)M$')  { return "$($Matches[1]) month(s)" }
        if ($s -match '^P(\d+)Y$')  { return "$($Matches[1]) year(s)" }
        if ($s -match '^PT(\d+)H$') { return "$($Matches[1]) hour(s)" }
        if ($s -match '^PT(\d+)M$') { return "$($Matches[1]) minute(s)" }
        return ''
    }
    # GrdDirs / GrdFiles / GrdList return ,@(...) so that a single item stays a collection.
    # Assign the result or iterate it directly - never wrap the call in @(), which would nest
    # the whole collection inside a one-element array and silently process only the first item.
    function GrdDirs {
        param([string]$Rel)
        if ([string]::IsNullOrWhiteSpace($ExportRoot)) { return ,@() }
        $p = Join-Path $ExportRoot $Rel
        if (-not (Test-Path -LiteralPath $p)) { return ,@() }
        try { return ,@(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue | Sort-Object Name) } catch { return ,@() }
    }
    function GrdFiles {
        param([string]$Rel, [string]$Filter)
        if ([string]::IsNullOrWhiteSpace($ExportRoot)) { return ,@() }
        $p = Join-Path $ExportRoot $Rel
        if (-not (Test-Path -LiteralPath $p)) { return ,@() }
        try { return ,@(Get-ChildItem -LiteralPath $p -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object Name) } catch { return ,@() }
    }
    function GrdSvgBox {
        param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Kind, [string]$Line1, [string]$Line2)
        $fill = 'var(--surface)'; $stroke = 'var(--line)'; $ink = 'var(--muted)'
        if ($Kind -eq 'on')          { $fill = 'var(--good-soft)'; $stroke = 'var(--good)'; $ink = 'var(--good)' }
        elseif ($Kind -eq 'part')    { $fill = 'var(--warn-soft)'; $stroke = 'var(--warn)'; $ink = 'var(--warn)' }
        elseif ($Kind -eq 'off')     { $fill = 'var(--crit-soft)'; $stroke = 'var(--crit)'; $ink = 'var(--crit)' }
        elseif ($Kind -eq 'unknown') { $fill = 'url(#grd-hatch)';  $stroke = 'var(--faint)'; $ink = 'var(--muted)' }
        $cx = $X + [int]($W / 2)
        $s  = "<rect x=`"$X`" y=`"$Y`" width=`"$W`" height=`"$H`" rx=`"6`" fill=`"$fill`" stroke=`"$stroke`" stroke-width=`"1.5`"/>"
        $s += "<text x=`"$cx`" y=`"$($Y + 19)`" text-anchor=`"middle`" font-size=`"11`" font-weight=`"600`" fill=`"var(--ink)`">$(GrdEnc $Line1)</text>"
        if ($Line2) { $s += "<text x=`"$cx`" y=`"$($Y + 34)`" text-anchor=`"middle`" font-size=`"9.5`" fill=`"$ink`">$(GrdEnc $Line2)</text>" }
        return $s
    }
    function GrdSvgCap {
        param([int]$X, [int]$Y, [string[]]$Lines)
        $s = ''; $y = $Y
        foreach ($l in $Lines) {
            $s += "<text x=`"$X`" y=`"$y`" text-anchor=`"middle`" font-family=`"IBM Plex Mono, Consolas, monospace`" font-size=`"8`" fill=`"var(--faint)`">$(GrdEnc $l)</text>"
            $y += 10
        }
        return $s
    }

    # ---- 0. open the section, and decide whether there is anything to read at all -----
    W "<section class=`"tab`" id=`"tab-adjacent`">"
    W @'
<style>
#tab-adjacent .gr-chip{display:inline-block;padding:1px 8px;border-radius:20px;font-size:11px;font-weight:600;white-space:nowrap;border:1px solid transparent}
#tab-adjacent .gr-on{background:var(--good-soft);color:var(--good);border-color:var(--good)}
#tab-adjacent .gr-off{background:var(--crit-soft);color:var(--crit);border-color:var(--crit)}
#tab-adjacent .gr-part{background:var(--warn-soft);color:var(--warn);border-color:var(--warn)}
#tab-adjacent .gr-neutral{background:var(--surface-3);color:var(--muted);border-color:var(--line)}
#tab-adjacent .gr-unknown{background:repeating-linear-gradient(45deg,var(--surface-3),var(--surface-3) 3px,var(--surface) 3px,var(--surface) 7px);color:var(--muted);border-color:var(--faint)}
#tab-adjacent .gr-rule{display:inline-block;font-family:"IBM Plex Mono",Consolas,monospace;font-size:11px;color:var(--accent);background:var(--info-soft);border-radius:3px;padding:0 5px;margin-right:3px}
#tab-adjacent .gr-path{font-family:"IBM Plex Mono",Consolas,monospace;font-size:11px;color:var(--faint);word-break:break-all}
#tab-adjacent .gr-note{color:var(--muted);font-size:12px;margin:4px 0 10px}
#tab-adjacent .gr-none td{color:var(--muted);font-style:italic}
#tab-adjacent svg.grd{width:100%;height:auto;max-width:1180px;display:block;margin:8px 0 6px;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius)}
#tab-adjacent .tile{cursor:default}
#tab-adjacent .tile .n{font-size:26px}
#tab-adjacent table{font-size:13px}
#tab-adjacent td .gr-sub{display:block;color:var(--faint);font-size:11px;font-weight:400}
</style>
'@
    W "<h2>Guardrails</h2>"

    if ([string]::IsNullOrWhiteSpace($ExportRoot) -or -not (Test-Path -LiteralPath $ExportRoot)) {
        W "<div class=`"card`"><p>No export root was supplied to the renderer, so none of the guardrail evidence could be read. Re-run the renderer with <code>-ExportRoot</code> pointing at the export folder.</p></div></section>"
        [void]$Sb.Append($g.ToString())
        return
    }

    $pDefender = Join-Path $ExportRoot 'defender'
    $pLocks    = Join-Path $ExportRoot 'locks'
    $pAlerts   = Join-Path $ExportRoot 'monitor/metricalerts.json'
    $pDp       = Join-Path $ExportRoot 'backup-dataprotection'
    $hasDefender = Test-Path -LiteralPath $pDefender
    $hasLocks    = Test-Path -LiteralPath $pLocks
    $hasAlerts   = Test-Path -LiteralPath $pAlerts
    $hasDp       = Test-Path -LiteralPath $pDp

    $manifest = GrdRead (Join-Path $ExportRoot 'manifest.json')
    $mSchema  = [string](GrdProp $manifest.obj 'schema' '')
    $mWhen    = [string](GrdProp $manifest.obj 'exportedAtUtc' '')
    $subs     = @(GrdProp $manifest.obj 'subscriptions' @())
    $subName  = @{}
    foreach ($s in $subs) {
        $sid = [string](GrdProp $s 'id' '')
        if ($sid) { $subName[$sid.ToLower()] = [string](GrdProp $s 'name' $sid) }
    }
    function GrdSubLabel {
        param([string]$Sid)
        if ([string]::IsNullOrWhiteSpace($Sid)) { return '(unknown subscription)' }
        if ($subName.ContainsKey($Sid.ToLower())) { return $subName[$Sid.ToLower()] }
        return $Sid
    }

    if (-not ($hasDefender -or $hasLocks -or $hasAlerts -or $hasDp)) {
        # Subject absent from the export entirely: one card, no tables, and no all-grey diagram.
        W "<div class=`"card`">"
        W "<div class=`"kv`"><div class=`"k`">Export schema</div><div><code>$(GrdEnc $(if ($mSchema) { $mSchema } else { 'not stated' }))</code></div>"
        W "<div class=`"k`">Exported (UTC)</div><div><code>$(GrdEnc $(if ($mWhen) { $mWhen } else { 'not stated' }))</code></div></div>"
        W "<p>This export did not capture the adjacent controls; their posture is <b>unknown, not clear</b>. Expected but absent:</p>"
        W "<p class=`"gr-path`">defender/&lt;subscription&gt;-pricing-StorageAccounts.json<br>storage/&lt;sub&gt;__&lt;account&gt;/defender.json<br>locks/&lt;subscription&gt;.json<br>monitor/metricalerts.json<br>backup-dataprotection/&lt;sub&gt;__&lt;vault&gt;/vault.json</p>"
        W "<p>Re-run <code>Export-AzFileSyncEnvironment.ps1</code> with <b>Security Reader</b> on each subscription in addition to Reader - the Defender reads need it, and a Reader-only export gets 403, which is saved as <code>null</code> and looks identical to &quot;disabled&quot;.</p>"
        W "</div></section>"
        [void]$Sb.Append($g.ToString())
        return
    }

    # ---- 1. shared indexes -----------------------------------------------------------
    $inv = GrdRead (Join-Path $ExportRoot 'inventory.json')
    $invIdx = @{}   # lowercased ARM id -> @{ name; kind; id }
    $invKinds = @(
        @{ prop = 'storageSyncServices';    kind = 'Storage Sync Service' },
        @{ prop = 'storageAccounts';        kind = 'Storage account' },
        @{ prop = 'recoveryServicesVaults'; kind = 'Recovery Services vault' },
        @{ prop = 'dataProtectionVaults';   kind = 'Backup vault' }
    )
    foreach ($k in $invKinds) {
        foreach ($x in @(GrdProp $inv.obj $k.prop @())) {
            $xid = [string](GrdProp $x 'id' '')
            if (-not $xid) { continue }
            $invIdx[$xid.ToLower()] = @{ name = [string](GrdProp $x 'name' (GrdLeaf $xid)); kind = $k.kind; id = $xid }
        }
    }

    # backup/share-coverage.json: which accounts actually hold File Sync or protected shares
    $cov = GrdList (GrdRead (Join-Path $ExportRoot 'backup/share-coverage.json'))
    $covIdx = @{}
    foreach ($c in $cov) {
        $acct = [string](GrdProp $c 'storageAccount' '')
        if (-not $acct) { continue }
        $ck = $acct.ToLower()
        if (-not $covIdx.ContainsKey($ck)) { $covIdx[$ck] = @{ total = 0; afs = 0; protected = 0 } }
        $covIdx[$ck].total++
        if ((GrdProp $c 'azureFileSync' $false) -eq $true) { $covIdx[$ck].afs++ }
        if ((GrdProp $c 'protected' $false) -eq $true) { $covIdx[$ck].protected++ }
    }

    # errors.json: the only way to tell "off" from "not readable"
    $errRead = GrdRead (Join-Path $ExportRoot 'errors.json')
    $errAll  = GrdList $errRead
    $errIdx  = @{}
    foreach ($e in $errAll) {
        $w = [string](GrdProp $e 'where' '')
        if ($w -and -not $errIdx.ContainsKey($w.ToLower())) { $errIdx[$w.ToLower()] = $e }
    }
    function GrdErrTip {
        param([string]$Label)
        $e = $null
        if ($Label -and $errIdx.ContainsKey($Label.ToLower())) { $e = $errIdx[$Label.ToLower()] }
        if ($null -eq $e) { return 'no setting returned by ARM, and errors.json records no failure for this read' }
        $d = [string](GrdProp $e 'detail' '')
        if ($d.Length -gt 220) { $d = $d.Substring(0, 220) + ' ...' }
        return "capture failed - errors.json [$Label]: $d"
    }

    # ---- 2. Defender for Storage: subscription plans ---------------------------------
    $defSubs  = @()
    $defBySub = @{}
    $defFiles = GrdFiles 'defender' '*-pricing-StorageAccounts.json'
    foreach ($f in $defFiles) {
        $r = GrdRead $f.FullName
        $o = $r.obj
        $rec = @{
            sid      = (GrdSubId ([string](GrdProp $o 'id' '')))
            file     = "defender/$($f.Name)"
            state    = $r.state
            tier     = [string](GrdPath $o 'properties.pricingTier' '')
            coverage = [string](GrdPath $o 'properties.resourcesCoverageStatus' '')
            trial    = [string](GrdPath $o 'properties.freeTrialRemainingTime' '')
            subPlan  = [string](GrdPath $o 'properties.subPlan' '')
            ext      = @(GrdPath $o 'properties.extensions' @())
        }
        if ($rec.sid) { $defBySub[$rec.sid.ToLower()] = $rec }
        $defSubs += $rec
    }
    # every manifest subscription gets a row, even when its pricing file never arrived
    $defRows = @()
    foreach ($s in $subs) {
        $sid = [string](GrdProp $s 'id' '')
        if ($sid -and $defBySub.ContainsKey($sid.ToLower())) { $defRows += $defBySub[$sid.ToLower()] }
        else { $defRows += @{ sid = $sid; file = ''; state = 'missing'; tier = ''; coverage = ''; trial = ''; subPlan = ''; ext = @() } }
    }
    foreach ($d in $defSubs) {
        $known = $false
        foreach ($r in $defRows) { if ($r.sid -eq $d.sid) { $known = $true } }
        if (-not $known) { $defRows += $d }
    }
    $subsStandard = @($defRows | Where-Object { $_.tier -eq 'Standard' }).Count

    # ---- 3. per-resource inventory and its locks -------------------------------------
    $families = @(
        @{ rel = 'storagesync'; kind = 'Storage Sync Service';    primary = 'service.json'; rule = 'AFS-18' },
        @{ rel = 'storage';     kind = 'Storage account';         primary = 'account.json'; rule = 'SEC-10' },
        @{ rel = 'backup';      kind = 'Recovery Services vault'; primary = 'vault.json';   rule = 'BKP-16' }
    )
    $resRows = @()
    foreach ($fam in $families) {
        $famDirs = GrdDirs $fam.rel
        foreach ($d in $famDirs) {
            $prim = GrdRead (Join-Path $d.FullName $fam.primary)
            $name = [string](GrdProp $prim.obj 'name' '')
            if (-not $name) {
                $name = $d.Name
                if ($name -match '__') { $name = ($name -split '__', 2)[1] }
            }
            $rid = [string](GrdProp $prim.obj 'id' '')
            $lr  = GrdRead (Join-Path $d.FullName 'locks.json')
            $resRows += @{
                kind = $fam.kind; rule = $fam.rule; name = $name; id = $rid
                dir  = "$($fam.rel)/$($d.Name)"; lockState = $lr.state; locks = (GrdList $lr)
                sid  = (GrdSubId $rid)
            }
        }
    }

    # ---- 4. subscription-wide lock inventory (read by nothing else in the tool) -------
    $subLockRows  = @()
    $subLockFiles = GrdFiles 'locks' '*.json'
    $subLockEmpty = @()
    foreach ($f in $subLockFiles) {
        $r = GrdRead $f.FullName
        $items = GrdList $r
        # every file is accounted for by name and state, so one that could not be read is never
        # silently absent from a table that otherwise has rows in it
        $subLockEmpty += @{ file = "locks/$($f.Name)"; state = $r.state; count = @($items).Count }
        if (@($items).Count -eq 0) { continue }
        foreach ($l in $items) {
            $lid = [string](GrdProp $l 'id' '')
            $target = ''
            $ix = $lid.ToLower().IndexOf('/providers/microsoft.authorization/locks/')
            if ($ix -gt 0) { $target = $lid.Substring(0, $ix) }
            $segs = @()
            if ($target) { $segs = @(($target.Trim('/')) -split '/') }
            $scope = 'resource'
            if ($segs.Count -le 2) { $scope = 'subscription' } elseif ($segs.Count -le 4) { $scope = 'resourceGroup' }
            # inherited coverage: every assessed resource that sits under this lock's scope
            $covers = @()
            if ($target) {
                $tl = $target.ToLower()
                foreach ($rr in $resRows) {
                    if (-not $rr.id) { continue }
                    $ril = ([string]$rr.id).ToLower()
                    if ($ril -eq $tl -or $ril.StartsWith($tl + '/')) { $covers += $rr.name }
                }
            }
            $kn = ''
            if ($target -and $invIdx.ContainsKey($target.ToLower())) { $kn = $invIdx[$target.ToLower()].kind }
            $subLockRows += @{
                file  = "locks/$($f.Name)"; id = $lid; target = $target; scope = $scope
                name  = [string](GrdProp $l 'name' (GrdLeaf $lid))
                level = [string](GrdPath $l 'properties.level' '')
                notes = [string](GrdPath $l 'properties.notes' '')
                sid   = (GrdSubId $lid); covers = $covers; known = $kn
            }
        }
    }

    # ---- 5. metric alert rules -------------------------------------------------------
    $alertRead = GrdRead $pAlerts
    $alertRows = @()
    $alertList = GrdList $alertRead
    foreach ($a in $alertList) {
        $ap = GrdProp $a 'properties'
        $targets = @()
        foreach ($sc in @(GrdProp $ap 'scopes' @())) {
            $k = ([string]$sc).ToLower()
            if ($invIdx.ContainsKey($k)) { $targets += "$($invIdx[$k].name) ($($invIdx[$k].kind))" }
            else { $targets += (GrdLeaf ([string]$sc)) }
        }
        $crit = GrdProp $ap 'criteria'
        $sig = @()
        foreach ($c in @(GrdProp $crit 'allOf' @())) {
            $sig += (("$(GrdProp $c 'metricName' '') $(GrdProp $c 'operator' '') $(GrdProp $c 'threshold' '') ($(GrdProp $c 'timeAggregation' ''))").Trim())
        }
        $ag = @()
        foreach ($ac in @(GrdProp $ap 'actions' @())) { $ag += (GrdLeaf ([string](GrdProp $ac 'actionGroupId' ''))) }
        $tags = @()
        $tg = GrdProp $a 'tags'
        if ($null -ne $tg) {
            foreach ($tp in $tg.PSObject.Properties) {
                if ($null -ne $tp.Value -and [string]$tp.Value -ne '') { $tags += "$($tp.Name)=$($tp.Value)" }
            }
        }
        $aid = [string](GrdProp $a 'id' '')
        $alertRows += @{
            name = [string](GrdProp $a 'name' ''); id = $aid; sid = (GrdSubId $aid)
            enabled = (GrdProp $ap 'enabled' $null); severity = (GrdProp $ap 'severity' $null)
            freq = [string](GrdProp $ap 'evaluationFrequency' ''); window = [string](GrdProp $ap 'windowSize' '')
            auto = (GrdProp $ap 'autoMitigate' $null); odata = [string](GrdProp $crit 'odata.type' '')
            targets = $targets; sig = $sig; ag = $ag; tags = $tags
            desc = [string](GrdProp $ap 'description' '')
        }
    }
    $sevNames = @{ '0' = 'Critical'; '1' = 'Error'; '2' = 'Warning'; '3' = 'Informational'; '4' = 'Verbose' }
    $alertsWithAg = @($alertRows | Where-Object { @($_.ag).Count -gt 0 }).Count

    # ---- 6. Data Protection (Backup) vaults ------------------------------------------
    $dpRows = @()
    $dpDirs = GrdDirs 'backup-dataprotection'
    foreach ($d in $dpDirs) {
        $vr = GrdRead (Join-Path $d.FullName 'vault.json')
        $pr = GrdRead (Join-Path $d.FullName 'policies.json')
        $ir = GrdRead (Join-Path $d.FullName 'instances.json')
        $v  = $vr.obj
        $vname = [string](GrdProp $v 'name' '')
        if (-not $vname) {
            $vname = $d.Name
            if ($vname -match '__') { $vname = ($vname -split '__', 2)[1] }
        }
        $pols = @()
        $polList = GrdList $pr
        foreach ($p in $polList) {
            $sched = @(); $ret = @(); $stores = @(); $btype = ''
            foreach ($ru in @(GrdPath $p 'properties.policyRules' @())) {
                $ot = [string](GrdProp $ru 'objectType' '')
                if ($ot -eq 'AzureBackupRule') {
                    $btype = [string](GrdPath $ru 'backupParameters.backupType' '')
                    foreach ($ri in @(GrdPath $ru 'trigger.schedule.repeatingTimeIntervals' @())) {
                        $parts = @(([string]$ri) -split '/')
                        if ($parts.Count -ge 3) {
                            $gl = GrdDur $parts[2]
                            if (-not $gl) { $gl = $parts[2] }
                            $sched += "every $gl from $($parts[1])"
                        } else { $sched += [string]$ri }
                    }
                    $ds = [string](GrdPath $ru 'dataStore.dataStoreType' '')
                    if ($ds) { $stores += $ds }
                } elseif ($ot -eq 'AzureRetentionRule') {
                    foreach ($lc in @(GrdProp $ru 'lifecycles' @())) {
                        $dur = [string](GrdPath $lc 'deleteAfter.duration' '')
                        $src = [string](GrdPath $lc 'sourceDataStore.dataStoreType' '')
                        $gl  = GrdDur $dur
                        $txt = $dur
                        if ($gl) { $txt = "$dur ($gl)" }
                        if ($src) { $txt = "$txt in $src"; $stores += $src }
                        $ret += $txt.Trim()
                    }
                }
            }
            $pols += @{
                name  = [string](GrdProp $p 'name' ''); types = @(GrdPath $p 'properties.datasourceTypes' @())
                sched = $sched; ret = $ret; btype = $btype; stores = @($stores | Sort-Object -Unique)
            }
        }
        $vid = [string](GrdProp $v 'id' '')
        $instList = GrdList $ir
        $dpRows += @{
            dir = "backup-dataprotection/$($d.Name)"; name = $vname; vaultState = $vr.state
            location = [string](GrdProp $v 'location' ''); id = $vid; sid = (GrdSubId $vid)
            secureScore = [string](GrdPath $v 'properties.secureScore' '')
            bcdr        = [string](GrdPath $v 'properties.bcdrSecurityLevel' '')
            sdState     = [string](GrdPath $v 'properties.securitySettings.softDeleteSettings.state' '')
            sdDays      = (GrdPath $v 'properties.securitySettings.softDeleteSettings.retentionDurationInDays' $null)
            immut       = [string](GrdPath $v 'properties.securitySettings.immutabilitySettings.state' '')
            guard       = (GrdPath $v 'properties.isVaultProtectedByResourceGuard' $null)
            csr         = [string](GrdPath $v 'properties.featureSettings.crossSubscriptionRestoreSettings.state' '')
            prov        = [string](GrdPath $v 'properties.provisioningState' '')
            identity    = [string](GrdPath $v 'identity.type' '')
            storage     = @(GrdPath $v 'properties.storageSettings' @())
            policies    = $pols; policyState = $pr.state
            instances   = @($instList).Count; instanceState = $ir.state
        }
    }
    $mDpCount = GrdPath $manifest.obj 'counts.dataProtectionVaults' $null

    # ---- 7. per-account Defender settings, and the brake states for the diagram -------
    $acctDef = @()
    $anyDefOn = $false
    $defSeen  = $false
    foreach ($r in $defRows) {
        if ($r.state -eq 'ok') { $defSeen = $true }
        if ($r.tier -eq 'Standard') { $anyDefOn = $true }
    }
    $sdTotal = 0; $sdOn = 0; $sdSeen = $false
    $stDirs = GrdDirs 'storage'
    foreach ($d in $stDirs) {
        $ar = GrdRead (Join-Path $d.FullName 'account.json')
        $dr = GrdRead (Join-Path $d.FullName 'defender.json')
        $an = [string](GrdProp $ar.obj 'name' '')
        if (-not $an) {
            $an = $d.Name
            if ($an -match '__') { $an = ($an -split '__', 2)[1] }
        }
        $aid = [string](GrdProp $ar.obj 'id' '')
        $rec = @{
            name = $an; id = $aid; sid = (GrdSubId $aid); dir = "storage/$($d.Name)"; state = $dr.state
            isEnabled = (GrdPath $dr.obj 'properties.isEnabled' $null)
            malware   = (GrdPath $dr.obj 'properties.malwareScanning.onUpload.isEnabled' $null)
            cap       = (GrdPath $dr.obj 'properties.malwareScanning.onUpload.capGBPerMonth' $null)
            sdd       = (GrdPath $dr.obj 'properties.sensitiveDataDiscovery.isEnabled' $null)
            over      = (GrdPath $dr.obj 'properties.overrideSubscriptionLevelSettings' $null)
        }
        if ($rec.state -eq 'ok') { $defSeen = $true }
        if ($rec.isEnabled -eq $true) { $anyDefOn = $true }
        $acctDef += $rec
        # share soft delete rides along here - it is brake 2 for every synced share
        $fsr = GrdRead (Join-Path $d.FullName 'fileservice.json')
        if ($fsr.state -eq 'ok') {
            $sdSeen = $true; $sdTotal++
            if ((GrdPath $fsr.obj 'properties.shareDeleteRetentionPolicy.enabled' $false) -eq $true) { $sdOn++ }
        }
    }

    # brake 1 - a resource is braked by its own CanNotDelete lock OR by an inherited one
    $lockCaptured = @($resRows | Where-Object { $_.lockState -ne 'missing' }).Count
    $lockTotal = @($resRows).Count
    $braked = 0
    foreach ($rr in $resRows) {
        $has = $false
        foreach ($l in @($rr.locks)) { if ([string](GrdPath $l 'properties.level' '') -eq 'CanNotDelete') { $has = $true } }
        if (-not $has -and $rr.id) {
            $ril = ([string]$rr.id).ToLower()
            foreach ($sl in $subLockRows) {
                if ($sl.level -ne 'CanNotDelete' -or -not $sl.target) { continue }
                $tl = ([string]$sl.target).ToLower()
                if ($ril -eq $tl -or $ril.StartsWith($tl + '/')) { $has = $true }
            }
        }
        if ($has) { $braked++ }
    }
    $b1 = 'unknown'; $b1txt = 'not captured'
    if ($lockTotal -gt 0 -and $lockCaptured -gt 0) {
        $b1txt = "$braked of $lockTotal resources"
        if ($braked -eq 0) { $b1 = 'off' } elseif ($braked -lt $lockTotal) { $b1 = 'part' } else { $b1 = 'on' }
    } elseif ($lockTotal -gt 0) { $b1txt = "0 of $lockTotal captured" }

    # brake 2 - share soft delete plus Data Protection vault soft delete
    foreach ($dp in $dpRows) {
        if ($dp.vaultState -ne 'ok') { continue }
        $sdSeen = $true; $sdTotal++
        if ($dp.sdState -eq 'On' -or $dp.sdState -eq 'AlwaysOn') { $sdOn++ }
    }
    $b2 = 'unknown'; $b2txt = 'not captured'
    if ($sdSeen -and $sdTotal -gt 0) {
        $b2txt = "$sdOn of $sdTotal subjects"
        if ($sdOn -eq 0) { $b2 = 'off' } elseif ($sdOn -lt $sdTotal) { $b2 = 'part' } else { $b2 = 'on' }
    }

    # brake 3 - immutability and Resource Guard on the Data Protection vaults
    $dpOk    = @($dpRows | Where-Object { $_.vaultState -eq 'ok' }).Count
    $immOn   = @($dpRows | Where-Object { $_.vaultState -eq 'ok' -and $_.immut -ne '' -and $_.immut -ne 'Disabled' }).Count
    $guardOn = @($dpRows | Where-Object { $_.vaultState -eq 'ok' -and $_.guard -eq $true }).Count
    $b3 = 'unknown'; $b3txt = 'no Backup vault captured'
    if ($dpOk -gt 0) {
        $on3 = $immOn + $guardOn
        $b3txt = "$immOn immutable, $guardOn guarded / $dpOk"
        if ($on3 -eq 0) { $b3 = 'off' } elseif ($on3 -lt ($dpOk * 2)) { $b3 = 'part' } else { $b3 = 'on' }
    }

    # observers - detect and notify
    $b4 = 'unknown'; $b4txt = 'not captured'
    if ($defSeen) {
        if ($anyDefOn) { $b4 = 'on'; $b4txt = 'enabled somewhere' } else { $b4 = 'off'; $b4txt = 'off everywhere captured' }
    }
    $b5 = 'unknown'; $b5txt = 'metricalerts.json absent'
    if ($alertRead.state -ne 'missing') {
        $an5 = @($alertRows).Count
        if ($an5 -eq 0) { $b5 = 'off'; $b5txt = '0 in-scope rules' }
        elseif ($alertsWithAg -eq 0) { $b5 = 'off'; $b5txt = "$an5 rule(s), 0 action groups" }
        elseif ($alertsWithAg -lt $an5) { $b5 = 'part'; $b5txt = "$alertsWithAg of $an5 notify" }
        else { $b5 = 'on'; $b5txt = "$alertsWithAg of $an5 notify" }
    }

    # ---- 8. header line and tiles ----------------------------------------------------
    $subLine = 'no subscription list in manifest.json'
    if (@($subs).Count -gt 0) {
        $names = @()
        foreach ($s in $subs) { $names += [string](GrdProp $s 'name' (GrdProp $s 'id' '?')) }
        $subLine = "$(@($subs).Count) subscription(s): " + ($names -join ', ')
    }
    W "<p class=`"gr-note`">$(GrdEnc $subLine)"
    if ($mSchema -or $mWhen) { W " &middot; schema <code>$(GrdEnc $mSchema)</code> &middot; exported <code>$(GrdEnc $mWhen)</code>" }
    W "</p>"
    W "<p>Locks, Defender for Storage, metric alerts and Backup-vault security settings never appear in an inventory of what is deployed, but they decide whether a mistake is survivable. This tab is the <b>evidence</b>: what the export actually returned, and from which file. Severity belongs to the Findings tab; the hatched chips here mark values the export could not read, which is neither on nor off.</p>"

    W "<div class=`"tiles`">"
    W "<div class=`"tile`"><div class=`"n`">$braked/$lockTotal</div><div class=`"l`">resources with a delete lock</div></div>"
    W "<div class=`"tile`"><div class=`"n`">$subsStandard/$(@($defRows).Count)</div><div class=`"l`">subscriptions on Defender Standard</div></div>"
    W "<div class=`"tile`"><div class=`"n`">$alertsWithAg/$(@($alertRows).Count)</div><div class=`"l`">alert rules that notify someone</div></div>"
    W "<div class=`"tile`"><div class=`"n`">$(@($dpRows).Count)</div><div class=`"l`">Data Protection vaults</div></div>"
    W "</div>"

    # ---- 9. the diagram --------------------------------------------------------------
    $svgLabel = "Two panels. Left: the four brakes between a delete and unrecoverable data - resource lock ($b1txt), soft delete ($b2txt), immutability and Resource Guard ($b3txt) - with Defender for Storage ($b4txt) and metric alerts ($b5txt) drawn above the line as observers that notify but never block. Right: lock scope nesting, showing that the per-resource locks.json cannot see a lock inherited from the resource group or the subscription."
    W "<svg class=`"grd`" viewBox=`"0 0 1180 330`" role=`"img`" aria-label=`"$(GrdEnc $svgLabel)`" preserveAspectRatio=`"xMidYMid meet`">"
    W "<title>Guardrails: what stops a delete, and where a lock hides</title><desc>$(GrdEnc $svgLabel)</desc>"
    W "<defs>"
    W "<pattern id=`"grd-hatch`" width=`"7`" height=`"7`" patternUnits=`"userSpaceOnUse`" patternTransform=`"rotate(45)`"><rect width=`"7`" height=`"7`" fill=`"var(--surface-3)`"/><line x1=`"0`" y1=`"0`" x2=`"0`" y2=`"7`" stroke=`"var(--faint)`" stroke-width=`"1.6`"/></pattern>"
    W "<marker id=`"grd-arrow`" viewBox=`"0 0 10 10`" refX=`"9`" refY=`"5`" markerWidth=`"7`" markerHeight=`"7`" orient=`"auto`"><path d=`"M 0 0 L 10 5 L 0 10 z`" fill=`"var(--muted)`"/></marker>"
    W "<marker id=`"grd-arrow-crit`" viewBox=`"0 0 10 10`" refX=`"9`" refY=`"5`" markerWidth=`"7`" markerHeight=`"7`" orient=`"auto`"><path d=`"M 0 0 L 10 5 L 0 10 z`" fill=`"var(--crit)`"/></marker>"
    W "<marker id=`"grd-arrow-info`" viewBox=`"0 0 10 10`" refX=`"9`" refY=`"5`" markerWidth=`"7`" markerHeight=`"7`" orient=`"auto`"><path d=`"M 0 0 L 10 5 L 0 10 z`" fill=`"var(--info)`"/></marker>"
    W "</defs>"
    W "<rect x=`"0`" y=`"0`" width=`"1180`" height=`"330`" fill=`"var(--surface)`"/>"
    W "<line x1=`"731`" y1=`"12`" x2=`"731`" y2=`"318`" stroke=`"var(--line)`" stroke-width=`"1`"/>"

    # -- Panel A: the brakes
    W "<text x=`"12`" y=`"22`" font-size=`"12`" font-weight=`"700`" fill=`"var(--ink)`">Four brakes on one delete - and the file that proves each</text>"
    W "<text x=`"12`" y=`"37`" font-size=`"10`" fill=`"var(--muted)`">Detectors sit above the line. They notify; they never block.</text>"
    W (GrdSvgBox 12 48 196 40 $b4 'Defender for Storage - detect' $b4txt)
    W (GrdSvgBox 228 48 216 40 $b5 'Metric alert - notify' $b5txt)
    W (GrdSvgCap 110 100 @('defender/<sub>-pricing-StorageAccounts.json', 'storage/<acct>/defender.json isEnabled'))
    W (GrdSvgCap 336 100 @('monitor/metricalerts.json', 'properties.actions[]'))
    W "<circle cx=`"560`" cy=`"56`" r=`"8`" fill=`"none`" stroke=`"var(--muted)`" stroke-width=`"1.5`"/>"
    W "<path d=`"M 546 82 a 14 14 0 0 1 28 0`" fill=`"none`" stroke=`"var(--muted)`" stroke-width=`"1.5`"/>"
    W "<text x=`"560`" y=`"98`" text-anchor=`"middle`" font-size=`"9`" fill=`"var(--muted)`">a human, later</text>"
    W "<line x1=`"210`" y1=`"62`" x2=`"538`" y2=`"62`" stroke=`"var(--muted)`" stroke-width=`"1.3`" stroke-dasharray=`"4 3`" marker-end=`"url(#grd-arrow)`"/>"
    if (@($alertRows).Count -gt 0 -and $alertsWithAg -eq 0) {
        # the payoff: an enabled, correctly scoped rule whose actions[] is empty reaches nobody
        W "<line x1=`"446`" y1=`"76`" x2=`"506`" y2=`"76`" stroke=`"var(--crit)`" stroke-width=`"1.3`" stroke-dasharray=`"4 3`"/>"
        W "<path d=`"M 510 71 l 10 10 M 520 71 l -10 10`" stroke=`"var(--crit)`" stroke-width=`"1.6`" fill=`"none`"/>"
        W "<text x=`"446`" y=`"96`" font-size=`"9`" font-weight=`"600`" fill=`"var(--crit)`">actions[] empty - reaches nobody</text>"
    } else {
        W "<line x1=`"446`" y1=`"76`" x2=`"538`" y2=`"76`" stroke=`"var(--muted)`" stroke-width=`"1.3`" stroke-dasharray=`"4 3`" marker-end=`"url(#grd-arrow)`"/>"
    }
    W "<line x1=`"12`" y1=`"120`" x2=`"718`" y2=`"120`" stroke=`"var(--line)`" stroke-width=`"1`" stroke-dasharray=`"2 4`"/>"
    W (GrdSvgBox 12 150 96 46 'off' 'DELETE' 'issued')
    W "<line x1=`"110`" y1=`"173`" x2=`"126`" y2=`"173`" stroke=`"var(--muted)`" stroke-width=`"1.5`" marker-end=`"url(#grd-arrow)`"/>"
    W (GrdSvgBox 130 144 140 58 $b1 '1. Resource lock' $b1txt)
    W "<line x1=`"272`" y1=`"173`" x2=`"288`" y2=`"173`" stroke=`"var(--muted)`" stroke-width=`"1.5`" marker-end=`"url(#grd-arrow)`"/>"
    W (GrdSvgBox 292 144 140 58 $b2 '2. Soft delete' $b2txt)
    W "<line x1=`"434`" y1=`"173`" x2=`"450`" y2=`"173`" stroke=`"var(--muted)`" stroke-width=`"1.5`" marker-end=`"url(#grd-arrow)`"/>"
    W (GrdSvgBox 454 144 156 58 $b3 '3. Immutable / Guard' $b3txt)
    W "<line x1=`"612`" y1=`"173`" x2=`"626`" y2=`"173`" stroke=`"var(--crit)`" stroke-width=`"1.5`" marker-end=`"url(#grd-arrow-crit)`"/>"
    W (GrdSvgBox 630 150 88 46 'off' 'Data' 'unrecoverable')
    W (GrdSvgCap 200 220 @('locks/<sub>.json', '<resource>/locks.json', 'properties.level'))
    W (GrdSvgCap 362 220 @('fileservice.json', 'shareDeleteRetentionPolicy', 'vault.json softDeleteSettings'))
    W (GrdSvgCap 532 220 @('securitySettings.immutabilitySettings', '.state', 'isVaultProtectedByResourceGuard'))
    W "<text x=`"12`" y=`"272`" font-size=`"10`" fill=`"var(--muted)`">A ReadOnly lock closes brake 1 for the rule catalog, but it blocks listKeys - a POST - so File Sync</text>"
    W "<text x=`"12`" y=`"286`" font-size=`"10`" fill=`"var(--muted)`">and Azure Backup for Azure Files stop working. The level is in the lock table below.</text>"

    # -- Panel B: where a lock hides
    $subScopeN = @($subLockRows | Where-Object { $_.scope -eq 'subscription' }).Count
    $rgScopeN  = @($subLockRows | Where-Object { $_.scope -eq 'resourceGroup' }).Count
    $resScopeN = @($subLockRows | Where-Object { $_.scope -eq 'resource' }).Count
    $inheritN  = @($subLockRows | Where-Object { $_.scope -ne 'resource' -and @($_.covers).Count -gt 0 }).Count
    W "<text x=`"744`" y=`"22`" font-size=`"12`" font-weight=`"700`" fill=`"var(--ink)`">Where a lock hides</text>"
    W "<rect x=`"748`" y=`"36`" width=`"250`" height=`"180`" rx=`"8`" fill=`"var(--surface-2)`" stroke=`"var(--line)`"/>"
    W "<text x=`"758`" y=`"52`" font-size=`"10`" font-weight=`"600`" fill=`"var(--muted)`">subscription</text>"
    W "<text x=`"988`" y=`"52`" text-anchor=`"end`" font-family=`"IBM Plex Mono, Consolas, monospace`" font-size=`"10`" fill=`"var(--ink)`">$subScopeN lock(s)</text>"
    W "<rect x=`"766`" y=`"62`" width=`"214`" height=`"144`" rx=`"8`" fill=`"var(--surface-3)`" stroke=`"var(--line)`"/>"
    W "<text x=`"776`" y=`"78`" font-size=`"10`" font-weight=`"600`" fill=`"var(--muted)`">resourceGroup</text>"
    W "<text x=`"970`" y=`"78`" text-anchor=`"end`" font-family=`"IBM Plex Mono, Consolas, monospace`" font-size=`"10`" fill=`"var(--ink)`">$rgScopeN lock(s)</text>"
    W "<rect x=`"784`" y=`"90`" width=`"178`" height=`"106`" rx=`"8`" fill=`"var(--surface)`" stroke=`"var(--line)`"/>"
    W "<text x=`"794`" y=`"106`" font-size=`"10`" font-weight=`"600`" fill=`"var(--muted)`">resource</text>"
    W "<text x=`"952`" y=`"106`" text-anchor=`"end`" font-family=`"IBM Plex Mono, Consolas, monospace`" font-size=`"10`" fill=`"var(--ink)`">$resScopeN lock(s)</text>"
    W "<text x=`"794`" y=`"124`" font-size=`"9`" fill=`"var(--muted)`">storage account / sync service / vault</text>"
    W "<rect x=`"1022`" y=`"42`" width=`"148`" height=`"30`" rx=`"5`" fill=`"var(--info-soft)`" stroke=`"var(--info)`"/>"
    W "<text x=`"1096`" y=`"61`" text-anchor=`"middle`" font-family=`"IBM Plex Mono, Consolas, monospace`" font-size=`"9`" fill=`"var(--info)`">locks/&lt;sub&gt;.json</text>"
    W "<rect x=`"1022`" y=`"146`" width=`"148`" height=`"30`" rx=`"5`" fill=`"var(--crit-soft)`" stroke=`"var(--crit)`"/>"
    W "<text x=`"1096`" y=`"165`" text-anchor=`"middle`" font-family=`"IBM Plex Mono, Consolas, monospace`" font-size=`"9`" fill=`"var(--crit)`">&lt;resource&gt;/locks.json</text>"
    W "<line x1=`"998`" y1=`"46`" x2=`"1018`" y2=`"53`" stroke=`"var(--info)`" stroke-width=`"1.3`" marker-end=`"url(#grd-arrow-info)`"/>"
    W "<line x1=`"980`" y1=`"72`" x2=`"1018`" y2=`"58`" stroke=`"var(--info)`" stroke-width=`"1.3`" marker-end=`"url(#grd-arrow-info)`"/>"
    W "<line x1=`"962`" y1=`"100`" x2=`"1018`" y2=`"64`" stroke=`"var(--info)`" stroke-width=`"1.3`" marker-end=`"url(#grd-arrow-info)`"/>"
    W "<line x1=`"962`" y1=`"146`" x2=`"1018`" y2=`"158`" stroke=`"var(--crit)`" stroke-width=`"1.3`" marker-end=`"url(#grd-arrow-crit)`"/>"
    W "<text x=`"1096`" y=`"192`" text-anchor=`"middle`" font-size=`"9`" font-weight=`"600`" fill=`"var(--crit)`">this level and below only</text>"
    W "<text x=`"744`" y=`"240`" font-size=`"10`" fill=`"var(--muted)`">The rule catalog reads only the per-resource file, so a CanNotDelete inherited</text>"
    W "<text x=`"744`" y=`"254`" font-size=`"10`" fill=`"var(--muted)`">from the resource group is invisible to it. locks/&lt;sub&gt;.json is the only file that</text>"
    W "<text x=`"744`" y=`"268`" font-size=`"10`" fill=`"var(--muted)`">can clear such a finding - and this tab is its first consumer.</text>"
    W "<text x=`"744`" y=`"288`" font-size=`"10`" font-weight=`"600`" fill=`"var(--ink)`">Inherited coverage found in this export: $inheritN lock(s)</text>"
    W "</svg>"

    # ---- 10. Defender: subscription plans --------------------------------------------
    W "<h3>Defender for Storage - subscription plan</h3>"
    W "<p class=`"gr-note`">One file per subscription, named from the display name (<span class=`"gr-path`">defender/&lt;name&gt;-pricing-StorageAccounts.json</span>); the subscription id is read from the object, never from the filename. Cost lever: the V2 plan bills per storage account per month, and malware scanning bills per GB scanned against <code>CapGBPerMonth</code> - the export carries the cap, not the price.</p>"
    W "<table><thead><tr><th>Subscription</th><th>Pricing tier</th><th>Coverage</th><th>Free trial left</th><th>Sub-plan</th><th>Extensions</th><th>Source</th><th>Rule</th></tr></thead><tbody>"
    if (@($defRows).Count -eq 0) {
        W "<tr class=`"gr-none`"><td colspan=`"8`">The export contains no <span class=`"gr-path`">defender/</span> pricing file, so the subscription plan is unknown - not Free.</td></tr>"
    }
    foreach ($r in $defRows) {
        $lbl = "defender-pricing:$($r.sid)"
        W "<tr><td>$(GrdEnc (GrdSubLabel $r.sid))<span class=`"gr-sub`">$(GrdEnc $r.sid)</span></td>"
        if ($r.state -ne 'ok') {
            W "<td colspan=`"5`">$(GrdChip 'unknown' "not captured ($($r.state))" (GrdErrTip $lbl))</td>"
        } else {
            if ($r.tier -eq 'Standard') { W "<td>$(GrdChip 'on' $r.tier)</td>" }
            elseif ($r.tier) { W "<td>$(GrdChip 'off' $r.tier)<span class=`"gr-sub`">no Defender plan on this subscription</span></td>" }
            else { W "<td>$(GrdChip 'unknown' 'not returned' (GrdErrTip $lbl))</td>" }
            if ($r.coverage) { W "<td>$(GrdOnOff $r.coverage)</td>" }
            else { W "<td>$(GrdChip 'unknown' 'not returned' 'this API version did not return resourcesCoverageStatus')</td>" }
            if ($r.trial) { W "<td>$(GrdEnc "$($r.trial) - $(GrdDur $r.trial)")</td>" } else { W "<td>not returned</td>" }
            if ($r.subPlan) { W "<td>$(GrdEnc $r.subPlan)</td>" } else { W "<td>-<span class=`"gr-sub`">only returned on a Standard-tier subscription</span></td>" }
            $ex = @()
            foreach ($e in @($r.ext)) {
                $en = [string](GrdProp $e 'name' '')
                $eb = GrdProp $e 'isEnabled' $null
                $es = '?'
                if ($eb -eq $true) { $es = 'on' } elseif ($eb -eq $false) { $es = 'off' }
                $t = "$en=$es"
                $ec = GrdPath $e 'additionalExtensionProperties.CapGBPerMonth' $null
                if ($null -ne $ec) { $t += " (cap $ec GB/mo)" }
                $ex += $t
            }
            if (@($ex).Count -gt 0) { W "<td>$(GrdEnc ($ex -join '; '))</td>" } else { W "<td>none returned</td>" }
        }
        $src = 'file absent'
        if ($r.file) { $src = $r.file }
        W "<td class=`"gr-path`">$(GrdEnc $src)</td><td>$(GrdRule 'SEC-09')</td></tr>"
    }
    W "</tbody></table>"

    # ---- 11. Defender: per-account override and the precedence ------------------------
    W "<h3>Defender for Storage - per-account setting, and which side wins</h3>"
    W "<p class=`"gr-note`">The account setting governs only when <code>overrideSubscriptionLevelSettings</code> is true; otherwise the subscription tier does, whatever the account row says. Both sides are shown because the rule catalog ORs them and so cannot show which one is in force.</p>"
    W "<table><thead><tr><th>Storage account</th><th>Subscription tier</th><th>Account isEnabled</th><th>Overrides subscription</th><th>Effective</th><th>Malware scan on upload</th><th>Sensitive data discovery</th><th>Source</th><th>Rule</th></tr></thead><tbody>"
    if (@($acctDef).Count -eq 0) {
        W "<tr class=`"gr-none`"><td colspan=`"9`">The export contains no <span class=`"gr-path`">storage/</span> directory, so there is no per-account Defender setting to show.</td></tr>"
    }
    foreach ($a in $acctDef) {
        $tier = ''
        if ($a.sid -and $defBySub.ContainsKey($a.sid.ToLower())) { $tier = $defBySub[$a.sid.ToLower()].tier }
        $lbl = "defender:$($a.name)"
        if ($a.over -eq $true) {
            if ($a.isEnabled -eq $true) { $eff = GrdChip 'on' 'on (account override)' } else { $eff = GrdChip 'off' 'off (account override)' }
        } elseif ($a.state -ne 'ok') {
            # the account object never arrived, so the override flag is unknown and so is the winner
            $eff = GrdChip 'unknown' 'unknown' 'the per-account setting was not captured, so it is not known whether it overrides the subscription plan'
        } elseif ($tier -eq 'Standard') { $eff = GrdChip 'on' 'on (subscription plan)' }
        elseif ($tier) { $eff = GrdChip 'off' "off (subscription $tier)" }
        else { $eff = GrdChip 'unknown' 'unknown' 'neither the subscription plan nor the account setting was captured' }
        W "<tr><td>$(GrdEnc $a.name)"
        if ($covIdx.ContainsKey($a.name.ToLower())) {
            $c = $covIdx[$a.name.ToLower()]
            W "<span class=`"gr-sub`">$($c.total) share(s): $($c.afs) File Sync, $($c.protected) backed up</span>"
        }
        W "</td>"
        if ($tier) { W "<td>$(GrdEnc $tier)</td>" } else { W "<td>$(GrdChip 'unknown' 'not captured')</td>" }
        if ($a.state -eq 'ok') { W "<td>$(GrdOnOff $a.isEnabled)</td>" }
        elseif ($a.state -eq 'null') { W "<td>$(GrdChip 'unknown' 'null' (GrdErrTip $lbl))<span class=`"gr-sub`">no setting, or the read was refused</span></td>" }
        else { W "<td>$(GrdChip 'unknown' $a.state (GrdErrTip $lbl))</td>" }
        W "<td>$(GrdOnOff $a.over 'not returned')</td><td>$eff</td>"
        $mw = GrdOnOff $a.malware 'not returned'
        if ($null -ne $a.cap) {
            $capNote = "cap $($a.cap) GB/mo"
            if ([string]$a.cap -eq '-1') { $capNote = 'capGBPerMonth -1: no cap set' }
            $mw += "<span class=`"gr-sub`">$(GrdEnc $capNote)</span>"
        }
        W "<td>$mw</td><td>$(GrdOnOff $a.sdd 'not returned')</td>"
        W "<td class=`"gr-path`">$(GrdEnc "$($a.dir)/defender.json")</td><td>$(GrdRule 'SEC-09')</td></tr>"
    }
    W "</tbody></table>"

    # ---- 12. locks per assessed resource ---------------------------------------------
    W "<h3>Resource locks - per assessed resource</h3>"
    W "<p class=`"gr-note`">Not every lock is the customer's: <code>AzureBackupProtectionLock</code> is auto-created when a storage account is registered to a Recovery Services vault, and <code>ASR-Lock</code> by Site Recovery - both are identified by <code>properties.notes</code>. So an account Azure Backup protects usually already carries a lock, and the accounts a lock rule really flags are the ones Backup never registered.</p>"
    W "<table><thead><tr><th>Resource</th><th>Type</th><th>Lock at this resource</th><th>Level</th><th>Created by</th><th>Inherited lock</th><th>Source</th><th>Rule</th></tr></thead><tbody>"
    if (@($resRows).Count -eq 0) {
        W "<tr class=`"gr-none`"><td colspan=`"8`">No storage account, Storage Sync Service or Recovery Services vault directory is present in this export.</td></tr>"
    }
    foreach ($r in $resRows) {
        $inh = @()
        if ($r.id) {
            $ril = ([string]$r.id).ToLower()
            foreach ($sl in $subLockRows) {
                if (-not $sl.target -or $sl.scope -eq 'resource') { continue }
                $tl = ([string]$sl.target).ToLower()
                if ($ril.StartsWith($tl + '/')) { $inh += "$($sl.name) ($($sl.level), $($sl.scope) scope)" }
            }
        }
        if (@($inh).Count -gt 0) { $inhCell = GrdChip 'part' (@($inh) -join '; ') 'inherited from a parent scope - visible only in locks/<subscription>.json, which the per-resource rules do not read' }
        else { $inhCell = '-' }
        $lockList = @($r.locks)
        if (@($lockList).Count -eq 0) {
            if ($r.lockState -eq 'missing') { $cell = GrdChip 'unknown' 'locks.json absent' (GrdErrTip "locks:$($r.name)") }
            elseif ($r.lockState -eq 'null') { $cell = GrdChip 'unknown' 'null' (GrdErrTip "locks:$($r.name)") }
            else { $cell = GrdChip 'off' 'none' 'the lock list was returned and it was empty' }
            W "<tr><td>$(GrdEnc $r.name)</td><td>$(GrdEnc $r.kind)</td><td>$cell</td><td>-</td><td>-</td><td>$inhCell</td>"
            W "<td class=`"gr-path`">$(GrdEnc "$($r.dir)/locks.json")</td><td>$(GrdRule $r.rule)</td></tr>"
            continue
        }
        foreach ($l in $lockList) {
            $lvl = [string](GrdPath $l 'properties.level' '')
            $notes = [string](GrdPath $l 'properties.notes' '')
            $author = 'not stated'
            if ($notes -match 'Azure Backup') { $author = 'Azure Backup (auto-created)' }
            elseif ($notes -match 'Site Recovery') { $author = 'Azure Site Recovery (auto-created)' }
            elseif ($notes) { $author = $notes }
            if ($lvl -eq 'CanNotDelete') { $lvlCell = GrdChip 'on' $lvl }
            elseif ($lvl -eq 'ReadOnly') { $lvlCell = GrdChip 'part' 'ReadOnly' 'ReadOnly satisfies the lock rules but blocks listKeys, a POST - which breaks File Sync and Azure Backup for Azure Files' }
            elseif ($lvl) { $lvlCell = GrdChip 'neutral' $lvl }
            else { $lvlCell = GrdChip 'unknown' 'not returned' }
            W "<tr><td>$(GrdEnc $r.name)</td><td>$(GrdEnc $r.kind)</td><td><code>$(GrdEnc ([string](GrdProp $l 'name' '')))</code></td><td>$lvlCell"
            if ($lvl -eq 'ReadOnly') { W "<span class=`"gr-sub`">blocks listKeys - breaks File Sync and Backup</span>" }
            W "</td><td>$(GrdEnc $author)</td><td>$inhCell</td>"
            W "<td class=`"gr-path`">$(GrdEnc "$($r.dir)/locks.json")</td><td>$(GrdRule $r.rule)</td></tr>"
        }
    }
    W "</tbody></table>"

    # ---- 13. subscription-wide lock inventory ----------------------------------------
    W "<h3>Every lock in the subscription - including the scopes the rules cannot see</h3>"
    W "<p class=`"gr-note`">From <span class=`"gr-path`">locks/&lt;subscription&gt;.json</span>, the one file in the export that lists locks at resource-group and subscription scope, and locks on resources outside the assessed set. ARM returns ids with mixed casing inside a single document (<code>resourcegroups</code> / <code>resourceGroups</code>, <code>microsoft.storage</code> / <code>Microsoft.Storage</code>), so every join here lowercases both sides, and the scope is derived from the id, never from the filename.</p>"
    W "<table><thead><tr><th>Lock</th><th>Scope</th><th>Level</th><th>Target</th><th>Created by</th><th>Covers assessed resources</th><th>Subscription</th></tr></thead><tbody>"
    if (@($subLockRows).Count -eq 0) {
        if (@($subLockFiles).Count -eq 0) {
            W "<tr class=`"gr-none`"><td colspan=`"7`">The export has no <span class=`"gr-path`">locks/</span> directory, so subscription-wide and resource-group locks were never captured - their absence here is not evidence that none exist.</td></tr>"
        } else {
            $readable = @($subLockEmpty | Where-Object { $_.state -eq 'ok' -or $_.state -eq 'empty' }).Count
            if ($readable -gt 0) {
                W "<tr class=`"gr-none`"><td colspan=`"7`">The subscription lock list was returned and it was empty - no lock exists at any scope in $readable subscription(s).</td></tr>"
            } else {
                W "<tr class=`"gr-none`"><td colspan=`"7`">No <span class=`"gr-path`">locks/</span> file could be read, so locks at every scope are unknown, not absent.</td></tr>"
            }
        }
    }
    foreach ($sl in $subLockRows) {
        $author = 'not stated'
        if ($sl.notes -match 'Azure Backup') { $author = 'Azure Backup (auto-created)' }
        elseif ($sl.notes -match 'Site Recovery') { $author = 'Azure Site Recovery (auto-created)' }
        elseif ($sl.notes) { $author = $sl.notes }
        $sk = 'neutral'
        if ($sl.scope -eq 'subscription') { $sk = 'on' } elseif ($sl.scope -eq 'resourceGroup') { $sk = 'part' }
        if ($sl.level -eq 'CanNotDelete') { $lvlCell = GrdChip 'on' $sl.level }
        elseif ($sl.level -eq 'ReadOnly') { $lvlCell = GrdChip 'part' 'ReadOnly' 'blocks listKeys, a POST - breaks File Sync and Azure Backup for Azure Files' }
        elseif ($sl.level) { $lvlCell = GrdChip 'neutral' $sl.level }
        else { $lvlCell = GrdChip 'unknown' 'not returned' }
        $kn = 'outside the assessed set'
        if ($sl.known) { $kn = $sl.known }
        W "<tr><td><code>$(GrdEnc $sl.name)</code></td><td>$(GrdChip $sk $sl.scope)</td><td>$lvlCell</td>"
        W "<td>$(GrdEnc (GrdLeaf $sl.target))<span class=`"gr-sub`">$(GrdEnc $kn)</span></td><td>$(GrdEnc $author)</td>"
        if (@($sl.covers).Count -gt 0) { W "<td>$(GrdEnc (@($sl.covers) -join ', '))</td>" } else { W "<td>-</td>" }
        W "<td>$(GrdEnc (GrdSubLabel $sl.sid))</td></tr>"
    }
    W "</tbody></table>"
    if (@($subLockEmpty).Count -gt 0) {
        $fl = @()
        foreach ($x in $subLockEmpty) {
            $what = "$($x.count) lock(s)"
            if ($x.state -eq 'empty') { $what = 'returned empty' }
            elseif ($x.state -ne 'ok') { $what = "NOT READ ($($x.state))" }
            $fl += (GrdEnc "$($x.file): $what")
        }
        W "<p class=`"gr-note`">Read from $($fl -join ' &middot; ')</p>"
    }

    # ---- 14. metric alert rules ------------------------------------------------------
    W "<h3>Azure Monitor metric alert rules</h3>"
    W "<p class=`"gr-note`">This file is filtered at capture time: the exporter keeps only rules whose <code>scopes[]</code> hit a Storage Sync Service, storage account or Recovery Services vault in scope - so an empty file means <i>no rule targets an in-scope resource</i>, not that the subscription has no alerts, and a rule on a Data Protection vault is dropped because Backup vaults are not in that filter. Only metric alerts are exported: no log (scheduled query) alerts, no activity-log alerts, no action-group objects, and a vault's own built-in job-failure alerting is a different setting again. &quot;No metric alert&quot; therefore does not mean &quot;nobody is notified&quot;.</p>"
    W "<table><thead><tr><th>Rule</th><th>Target</th><th>Signal</th><th>Enabled</th><th>Severity</th><th>Frequency / window</th><th>Auto-mitigate</th><th>Provenance</th><th>Action group</th><th>Rule</th></tr></thead><tbody>"
    if (@($alertRows).Count -eq 0) {
        if ($alertRead.state -eq 'missing') {
            W "<tr class=`"gr-none`"><td colspan=`"10`"><span class=`"gr-path`">monitor/metricalerts.json</span> is absent from this export - alerting was never captured, so its posture is unknown, not clear.</td></tr>"
        } else {
            W "<tr class=`"gr-none`"><td colspan=`"10`">No metric alert rule in this subscription targets a Storage Sync Service, storage account or Recovery Services vault. Other alert types were not exported, so this is not evidence that nobody is notified.</td></tr>"
        }
    }
    foreach ($a in $alertRows) {
        $sv = '-'
        if ($null -ne $a.severity) {
            $sk = [string]$a.severity
            $sv = $sk
            if ($sevNames.ContainsKey($sk)) { $sv = "$sk ($($sevNames[$sk]))" }
        }
        W "<tr><td><code>$(GrdEnc $a.name)</code>"
        if ($a.desc) { W "<span class=`"gr-sub`">$(GrdEnc $a.desc)</span>" }
        W "</td><td>$(GrdEnc (@($a.targets) -join ', '))</td>"
        W "<td>$(GrdEnc (@($a.sig) -join '; '))<span class=`"gr-sub`">$(GrdEnc $a.odata)</span></td>"
        W "<td>$(GrdOnOff $a.enabled 'not returned')</td><td>$(GrdEnc $sv)</td>"
        W "<td>$(GrdEnc "$($a.freq) / $($a.window)")</td><td>$(GrdOnOff $a.auto 'not returned')</td>"
        $prov = '-'
        if (@($a.tags) -contains '_deployed_by_amba=true') { $prov = 'Azure Monitor Baseline Alerts' }
        elseif (@($a.tags).Count -gt 0) { $prov = (@($a.tags) -join ', ') }
        W "<td>$(GrdEnc $prov)</td>"
        if (@($a.ag).Count -gt 0) {
            W "<td>$(GrdChip 'on' (@($a.ag) -join ', '))</td>"
        } else {
            W "<td>$(GrdChip 'off' 'no action group')<span class=`"gr-sub`">properties.actions[] is empty - the rule evaluates and fires, and reaches nobody</span></td>"
        }
        W "<td>$(GrdRule 'MON-01, MON-02')</td></tr>"
    }
    W "</tbody></table>"

    # ---- 15. Data Protection (Backup) vaults -----------------------------------------
    W "<h3>Data Protection (Backup) vaults</h3>"
    if (@($dpRows).Count -eq 0) {
        if (-not $hasDp) {
            W "<div class=`"card`"><p>This export has no <span class=`"gr-path`">backup-dataprotection/</span> directory. Either no Microsoft.DataProtection Backup vault exists in scope, or the list call did not return - the capture table below shows whether a <code>dataProtectionVaults:</code> read failed.</p></div>"
        } else {
            W "<div class=`"card`"><p>The <span class=`"gr-path`">backup-dataprotection/</span> directory exists but holds no vault directory.</p></div>"
        }
    }
    if ($null -ne $mDpCount -and [string]$mDpCount -ne [string]@($dpRows).Count) {
        W "<p class=`"gr-note`">manifest.json counts <b>$(GrdEnc $mDpCount)</b> Data Protection vault(s) against $(@($dpRows).Count) directory/directories present - the difference is a vault whose files did not save. The classification below comes from the parsed <code>vault.json</code> and <code>datasourceTypes</code>, not from a directory count.</p>"
    }
    foreach ($v in $dpRows) {
        W "<div class=`"card`"><h4 style=`"margin-top:0`">$(GrdEnc $v.name)"
        if ($v.location) { W " <span class=`"res`">$(GrdEnc $v.location)</span>" }
        if ($v.secureScore) { W " $(GrdChip 'neutral' "secureScore: $($v.secureScore)" 'Azure''s own published posture grade for this vault - no rule in the catalog reads it')" }
        if ($v.bcdr) {
            $bk = 'neutral'
            if ($v.bcdr -match '^(Poor|Fair)$') { $bk = 'off' } elseif ($v.bcdr -match '^(Good|Excellent)$') { $bk = 'on' }
            W " $(GrdChip $bk "bcdrSecurityLevel: $($v.bcdr)" 'Azure''s own published posture grade for this vault - no rule in the catalog reads it')"
        }
        W "</h4>"
        if ($v.vaultState -ne 'ok') {
            W "<p>$(GrdChip 'unknown' "vault.json $($v.vaultState)" (GrdErrTip "dataProtectionVaults:$($v.sid)")) - this directory exists but its vault object was not captured, so every security setting below is unknown rather than off.</p>"
        } else {
            $store = @()
            foreach ($st in @($v.storage)) { $store += "$(GrdProp $st 'datastoreType' '')/$(GrdProp $st 'type' '')" }
            W "<div class=`"kv`">"
            W "<div class=`"k`">Subscription</div><div>$(GrdEnc (GrdSubLabel $v.sid))</div>"
            $sdExtra = ''
            if ($null -ne $v.sdDays) { $sdExtra = " retention $($v.sdDays) days" }
            W "<div class=`"k`">Soft delete</div><div>$(GrdOnOff $v.sdState 'not returned' 'Data Protection vocabulary is On / Off / AlwaysOn - not the Recovery Services vault Enabled / AlwaysON / Disabled, and the retention is a float')$(GrdEnc $sdExtra)</div>"
            W "<div class=`"k`">Immutability</div><div>$(GrdOnOff $v.immut 'not returned')</div>"
            W "<div class=`"k`">Protected by Resource Guard</div><div>$(GrdOnOff $v.guard 'not returned' 'the Data Protection equivalent of the Recovery Services vault resourceGuardProxies list - a boolean, not a list')</div>"
            W "<div class=`"k`">Cross-subscription restore</div><div>$(GrdOnOff $v.csr 'not returned')</div>"
            $stTxt = 'not returned'
            if (@($store).Count -gt 0) { $stTxt = ($store -join ', ') }
            W "<div class=`"k`">Redundancy</div><div>$(GrdEnc $stTxt)</div>"
            $idTxt = 'none'
            if ($v.identity) { $idTxt = $v.identity }
            W "<div class=`"k`">Managed identity</div><div>$(GrdEnc $idTxt)</div>"
            $pvTxt = 'not returned'
            if ($v.prov) { $pvTxt = $v.prov }
            W "<div class=`"k`">Provisioning state</div><div>$(GrdEnc $pvTxt)</div>"
            W "<div class=`"k`">Locks</div><div>$(GrdChip 'unknown' 'not captured for this resource type')<span class=`"gr-sub`">the exporter writes no locks.json, roleassignments.json or diagnostics.json for a Backup vault; a lock on one appears only in locks/&lt;subscription&gt;.json above</span></div>"
            W "</div>"
        }
        W "<table><thead><tr><th>Policy</th><th>Protects (datasourceTypes)</th><th>Backup</th><th>Schedule</th><th>Retention</th><th>Datastores</th></tr></thead><tbody>"
        if (@($v.policies).Count -eq 0) {
            if ($v.policyState -eq 'missing') { W "<tr class=`"gr-none`"><td colspan=`"6`">policies.json is absent - the policy set was not captured.</td></tr>" }
            else { W "<tr class=`"gr-none`"><td colspan=`"6`">The policy list was returned and it was empty - this vault carries no backup policy.</td></tr>" }
        }
        foreach ($p in @($v.policies)) {
            $blobPol = $false
            foreach ($t in @($p.types)) { if (([string]$t) -match 'blobServices') { $blobPol = $true } }
            $cls = 'not a blob policy - classified from datasourceTypes, not from the vault name'
            if ($blobPol) { $cls = 'blob backup' }
            $bt = '-'
            if ($p.btype) { $bt = $p.btype }
            $schTxt = '-'
            if (@($p.sched).Count -gt 0) { $schTxt = (@($p.sched) -join '; ') }
            $retTxt = '-'
            if (@($p.ret).Count -gt 0) { $retTxt = (@($p.ret) -join '; ') }
            W "<tr><td><code>$(GrdEnc $p.name)</code></td>"
            W "<td>$(GrdEnc (@($p.types) -join ', '))<span class=`"gr-sub`">$(GrdEnc $cls)</span></td>"
            W "<td>$(GrdEnc $bt)</td><td>$(GrdEnc $schTxt)</td><td>$(GrdEnc $retTxt)</td>"
            $onlyOp = (@($p.stores).Count -gt 0)
            foreach ($s in @($p.stores)) { if (([string]$s) -ne 'OperationalStore') { $onlyOp = $false } }
            W "<td>$(GrdEnc (@($p.stores) -join ', '))"
            if ($onlyOp) { W "<span class=`"gr-sub`">OperationalStore only - snapshot-tier retention, no vaulted copy</span>" }
            W "</td></tr>"
        }
        W "</tbody></table>"
        if ($v.instanceState -eq 'missing') {
            W "<p class=`"gr-note`">$(GrdChip 'unknown' 'instances.json absent' (GrdErrTip "dp-instances:$($v.name)")) &middot; <span class=`"gr-path`">$(GrdEnc $v.dir)</span> &middot; $(GrdRule 'BKP-17')</p>"
        } elseif ($v.instances -eq 0 -and @($v.policies).Count -gt 0) {
            W "<p class=`"gr-note`">$(GrdChip 'part' 'configured but unused') $(GrdEnc "$(@($v.policies).Count) policy/policies and 0 protected instances") - the instance list was returned and it was empty. &middot; <span class=`"gr-path`">$(GrdEnc $v.dir)</span> &middot; $(GrdRule 'BKP-17')</p>"
        } else {
            W "<p class=`"gr-note`">$(GrdEnc "$($v.instances) protected instance(s)") &middot; <span class=`"gr-path`">$(GrdEnc $v.dir)</span> &middot; $(GrdRule 'BKP-17')</p>"
        }
        W "</div>"
    }

    # ---- 16. capture confidence ------------------------------------------------------
    W "<h3>Capture confidence</h3>"
    W "<p class=`"gr-note`">Every guardrail read carries a label. <code>Invoke-ArmGet</code> returns <code>null</code> on any 4xx and the exporter saves the literal text <code>null</code>, so a null file cannot be told from &quot;not configured&quot; without this join - which is why every cell above has three states, not two. The Defender reads need <b>Security Reader</b>: a Reader-only export gets 403, which lands as <code>null</code> and reads as disabled.</p>"
    W "<p class=`"gr-note`">Reading the raw files by hand: <code>Save-Json</code> writes the literal <code>null</code> only for a failed or absent read, and a zero-byte file for a list that came back empty - so zero bytes is genuine evidence of &quot;none&quot;, while <code>null</code> is not. A single-item list arrives as a bare object rather than an array; every count on this tab normalises both.</p>"
    W "<table><thead><tr><th>Subject</th><th>State</th><th>Read from</th></tr></thead><tbody>"
    $capture = @(
        @{ n = 'Defender subscription plans';    ok = $hasDefender;                    p = 'defender/<subscription>-pricing-StorageAccounts.json' },
        @{ n = 'Defender per-account settings';  ok = (@($acctDef).Count -gt 0);       p = 'storage/<sub>__<account>/defender.json' },
        @{ n = 'Locks per resource';             ok = ($lockCaptured -gt 0);           p = 'storage | storagesync | backup/<resource>/locks.json' },
        @{ n = 'Locks, subscription-wide';       ok = $hasLocks;                       p = 'locks/<subscription>.json' },
        @{ n = 'Metric alert rules';             ok = $hasAlerts;                      p = 'monitor/metricalerts.json' },
        @{ n = 'Data Protection vaults';         ok = $hasDp;                          p = 'backup-dataprotection/<sub>__<vault>/vault.json' }
    )
    foreach ($c in $capture) {
        if ($c.ok) { $st = GrdChip 'on' 'captured' }
        else { $st = GrdChip 'unknown' 'never captured' 'the subject is absent from the export - its posture is unknown, not clear' }
        W "<tr><td>$(GrdEnc $c.n)</td><td>$st</td><td class=`"gr-path`">$(GrdEnc $c.p)</td></tr>"
    }
    W "</tbody></table>"
    $guardLabels = @('defender-pricing:', 'defender:', 'locks:', 'metricalerts:', 'dataprotectionvaults:', 'dp-policies:', 'dp-instances:')
    $relevant = @()
    foreach ($e in $errAll) {
        $w = ([string](GrdProp $e 'where' '')).ToLower()
        foreach ($gl in $guardLabels) { if ($w.StartsWith($gl)) { $relevant += $e; break } }
    }
    W "<table><thead><tr><th>Failed guardrail read (errors.json)</th><th>When</th><th>Detail</th></tr></thead><tbody>"
    if (@($relevant).Count -eq 0) {
        W "<tr class=`"gr-none`"><td colspan=`"3`">No guardrail read failed."
        if (@($errAll).Count -gt 0) {
            W " errors.json holds $(@($errAll).Count) entry/entries, none of them a Defender, lock, alert or Data Protection read - in a real export these are usually benign metric 400s, and the raw count is reported by the Findings tab, not restated here."
        }
        W "</td></tr>"
    }
    foreach ($e in $relevant) {
        $d = [string](GrdProp $e 'detail' '')
        if ($d.Length -gt 300) { $d = $d.Substring(0, 300) + ' ...' }
        W "<tr><td class=`"gr-path`">$(GrdEnc ([string](GrdProp $e 'where' '')))</td><td class=`"ev`">$(GrdEnc ([string](GrdProp $e 'at' '')))</td><td class=`"ev`">$(GrdEnc $d)</td></tr>"
    }
    W "</tbody></table>"

    W "</section>"
    [void]$Sb.Append($g.ToString())

    } catch {
        # Never a blank tab and never an exception out of a renderer: say what happened, in place.
        $why = [System.Net.WebUtility]::HtmlEncode([string]$_.Exception.Message)
        [void]$Sb.Append("<section class=`"tab`" id=`"tab-adjacent`"><h2>Guardrails</h2><div class=`"card`">")
        [void]$Sb.Append("<p>The guardrail evidence could not be assembled from this export: <code>$why</code></p>")
        [void]$Sb.Append("<p>Nothing else in the report is affected. The raw files are <code>defender/</code>, <code>locks/</code>, <code>monitor/metricalerts.json</code> and <code>backup-dataprotection/</code> in the export folder.</p>")
        [void]$Sb.Append("</div></section>")
    }
}
