function Add-AfsTabBackup {
    <#
      The Backup tab: what Azure Backup actually holds for this estate.

      It answers one question first - which file shares are protected, and which are not -
      and then lays out the evidence behind every backup rule: vault identity, redundancy and
      cross-region restore, the four vault guards (soft delete, immutability, multi-user
      authorization, delete lock), policies and their two retention tiers, protected items
      and their independent state fields, the jobs in the export's lookback window, monitoring,
      and who holds rights that can delete the backups.

      It never invents a finding. Where a value is a risk it is stated plainly beside the value;
      the Findings tab owns severity. Where the export did not report a field it says so -
      "not reported by this export" is a different fact from "Disabled", and both differ from
      "the call failed", which is read out of errors.json.

      Sources: backup/<Subscription>__<vault>/*.json, backup/share-coverage.json,
      backup-dataprotection/*, storage/*, locks/*, monitor/metricalerts.json,
      manifest.json, errors.json.
    #>
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
          [string]$ExportRoot)

    # ------------------------------------------------------------------ helpers
    function BkEnc { param($v) if ($null -eq $v) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$v) }
    function BkStr { param($v) if ($null -eq $v) { return '' } return ([string]$v) }
    function BkHas {
        param($o, [string]$n)
        if ($null -eq $o) { return $false }
        try { foreach ($p in $o.PSObject.Properties) { if ($p.Name -eq $n) { return $true } } } catch { return $false }
        return $false
    }
    function BkGet {
        param($o, [string]$n, $def)
        if (BkHas $o $n) {
            $v = $null
            try { $v = $o.$n } catch { return $def }
            if ($null -eq $v) { return $def }
            return $v
        }
        return $def
    }
    function BkPath {
        param($o, [string]$path, $def)
        $cur = $o
        foreach ($seg in ($path -split '\.')) {
            if ($null -eq $cur) { return $def }
            if (-not (BkHas $cur $seg)) { return $def }
            try { $cur = $cur.$seg } catch { return $def }
        }
        if ($null -eq $cur) { return $def }
        return $cur
    }
    function BkBool {
        param($v)
        if ($null -eq $v) { return $false }
        if ($v -is [bool]) { return $v }
        return (([string]$v).ToLower() -eq 'true')
    }
    function BkJson {
        # A missing, zero-byte or literal-null file is simply no data, never an error.
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        try {
            $t = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            if ($null -eq $t) { return $null }
            $t = [string]$t
            if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
            if ([string]::IsNullOrWhiteSpace($t)) { return $null }
            if ($t.Trim() -eq 'null') { return $null }
            return ($t | ConvertFrom-Json)
        } catch { return $null }
    }
    function BkList {
        # Every backup JSON can arrive as an array, as one bare object (ConvertTo-Json collapses
        # a single item), as a zero-byte file, or as the literal null. Normalise all four.
        param([string]$p)
        $o = BkJson $p
        if ($null -eq $o) { return ,@() }
        return ,@($o)
    }
    function BkFileState {
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return 'missing' }
        if (-not (Test-Path -LiteralPath $p)) { return 'missing' }
        $len = 0
        try { $fi = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue; if ($null -ne $fi) { $len = $fi.Length } } catch { $len = 0 }
        if ($len -le 0) { return 'empty' }
        return 'present'
    }
    function BkBytes {
        param($n)
        if ($null -eq $n) { return '' }
        $v = 0.0
        try { $v = [double]$n } catch { return '' }
        if ($v -lt 0) { return '' }
        if ($v -lt 1024) { return ([string][int]$v + ' B') }
        $units = @('KiB', 'MiB', 'GiB', 'TiB', 'PiB'); $i = -1
        while ($v -ge 1024 -and $i -lt 4) { $v = $v / 1024; $i++ }
        return ('{0:N1} {1}' -f $v, $units[$i])
    }
    function BkDur {
        # ISO-8601 job duration: PT1M, PT21.5130349S
        param([string]$s)
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $m = [regex]::Match($s, '^P(?:(?<d>\d+)D)?(?:T(?:(?<h>\d+)H)?(?:(?<mi>\d+)M)?(?:(?<sec>[0-9.]+)S)?)?$')
        if (-not $m.Success) { return $s }
        $parts = @()
        if ($m.Groups['d'].Success) { $parts += ($m.Groups['d'].Value + 'd') }
        if ($m.Groups['h'].Success) { $parts += ($m.Groups['h'].Value + 'h') }
        if ($m.Groups['mi'].Success) { $parts += ($m.Groups['mi'].Value + 'm') }
        if ($m.Groups['sec'].Success) {
            $sv = 0.0
            try { $sv = [double]$m.Groups['sec'].Value } catch { $sv = 0.0 }
            $parts += ('{0:N1}s' -f $sv)
        }
        if (@($parts).Count -eq 0) { return $s }
        return ($parts -join ' ')
    }
    function BkSpan {
        # .NET TimeSpan string: 13.19:57:44.4638633
        param([string]$s)
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        try {
            $ts = [TimeSpan]::Parse($s, [cultureinfo]::InvariantCulture)
            return ([string]$ts.Days + 'd ' + [string]$ts.Hours + 'h ' + [string]$ts.Minutes + 'm')
        } catch { return $s }
    }
    function BkDate {
        param($s)
        if ($null -eq $s) { return $null }
        $t = [string]$s
        if ([string]::IsNullOrWhiteSpace($t)) { return $null }
        try { return [datetime]::Parse($t, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { return $null }
    }
    function BkShortDate {
        param($s)
        $d = BkDate $s
        if ($null -eq $d) { return (BkStr $s) }
        return $d.ToString('yyyy-MM-dd HH:mm')
    }
    function BkLeaf {
        param([string]$id)
        if ([string]::IsNullOrWhiteSpace($id)) { return '' }
        $p = $id.TrimEnd('/').Split('/')
        return $p[$p.Length - 1]
    }
    function BkRg {
        param([string]$id)
        if ([string]::IsNullOrWhiteSpace($id)) { return '' }
        $m = [regex]::Match($id, '/resourceGroups/([^/]+)', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }
    function BkTrunc {
        param([string]$s, [int]$n)
        if ($null -eq $s) { return '' }
        if ($s.Length -le $n) { return $s }
        if ($n -lt 2) { return $s.Substring(0, $n) }
        return ($s.Substring(0, $n - 1) + '.')
    }
    function BkBadge {
        # on / off / warn / not reported. Each state also carries an ASCII glyph, so it
        # survives greyscale printing and reads without colour.
        param([string]$state, [string]$text)
        $g = '[?]'
        if ($state -eq 'ok') { $g = '[+]' } elseif ($state -eq 'bad') { $g = '[-]' } elseif ($state -eq 'warn') { $g = '[!]' } elseif ($state -eq 'info') { $g = '[i]' }
        return ('<span class="bkb ' + $state + '"><span class="g">' + $g + '</span>' + (BkEnc $text) + '</span>')
    }
    function BkNR {
        param([string]$t)
        $s = $t
        if ([string]::IsNullOrWhiteSpace($s)) { $s = 'not reported by this export' }
        return ('<span class="bknr">' + (BkEnc $s) + '</span>')
    }
    function BkVal {
        param($v, [string]$missing)
        if ($null -eq $v -or (BkStr $v) -eq '') { return (BkNR $missing) }
        return (BkEnc $v)
    }
    function BkErrFor {
        # errors.json rows are labelled "<call>:<vault>" by the exporter, so a 403 on
        # backupPolicies is distinguishable from a vault that genuinely has none.
        param($errors, [string]$label)
        $hits = @()
        if ([string]::IsNullOrWhiteSpace($label)) { return ,$hits }
        foreach ($e in @($errors)) {
            $w = BkStr (BkGet $e 'where' '')
            if ($w -ne '' -and $w.ToLower().Contains($label.ToLower())) { $hits += $e }
        }
        return ,$hits
    }
    function BkErrLine {
        param($hits, [string]$label)
        $t = ''
        foreach ($e in @($hits)) { $t = BkStr (BkGet $e 'detail' ''); break }
        if ($t.Length -gt 240) { $t = $t.Substring(0, 240) + ' ...' }
        return ('<p class="bknote">' + (BkBadge 'unk' 'not captured') + ' the ' + (BkEnc $label) +
                ' call failed during export, so an empty result here means nothing: <span class="ev">' + (BkEnc $t) + '</span></p>')
    }
    function BkEmpty {
        # One honest line per empty section. "No jobs in the window" is not "backup never ran".
        param([string]$state, [string]$file, [string]$meaning, $hits, [string]$label)
        if (@($hits).Count -gt 0) { return (BkErrLine $hits $label) }
        if ($state -eq 'missing') {
            return ('<p class="bknote">' + (BkBadge 'unk' 'not in export') + ' <code>' + (BkEnc $file) + '</code> was not written by this export.</p>')
        }
        return ('<p class="bknote">' + (BkBadge 'info' 'none') + ' ' + (BkEnc $meaning) + '</p>')
    }
    function BkScopeKind {
        param([string]$scope, [string]$vaultId)
        if ([string]::IsNullOrWhiteSpace($scope)) { return 'unknown' }
        $s = $scope.ToLower()
        $v = ''
        if ($vaultId) { $v = $vaultId.ToLower() }
        if ($v -ne '' -and $s -eq $v) { return 'this vault' }
        if ($s -eq '/') { return 'tenant root' }
        if ($s.StartsWith('/providers/microsoft.management/managementgroups/')) { return 'management group' }
        if ($s -match '^/subscriptions/[^/]+$') { return 'subscription' }
        if ($s -match '^/subscriptions/[^/]+/resourcegroups/[^/]+$') { return 'resource group' }
        return 'other'
    }

    $b = New-Object System.Text.StringBuilder
    try {
        $root = ''
        if ($ExportRoot) { $root = [string]$ExportRoot }

        # ------------------------------------------------------------- manifest
        $manifest   = BkJson (Join-Path $root 'manifest.json')
        $counts     = BkPath $manifest 'counts' $null
        $exportedAt = BkDate (BkPath $manifest 'exportedAtUtc' '')
        $lookback   = 30
        try { $lookback = [int](BkPath $manifest 'jobLookbackDays' 30) } catch { $lookback = 30 }
        if ($lookback -lt 1 -or $lookback -gt 400) { $lookback = 30 }
        $errs = BkList (Join-Path $root 'errors.json')

        # ------------------------------------------- storage accounts and shares
        $accounts = @{}
        $accOrderAll = @()
        $storeDir = Join-Path $root 'storage'
        if (Test-Path -LiteralPath $storeDir) {
            foreach ($d in @(Get-ChildItem -LiteralPath $storeDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
                $acc = BkJson (Join-Path $d.FullName 'account.json')
                $dn = $d.Name
                $sub = ''
                $nm = BkStr (BkGet $acc 'name' '')
                $ix = $dn.LastIndexOf('__')
                if ($ix -ge 0) { $sub = $dn.Substring(0, $ix); if ($nm -eq '') { $nm = $dn.Substring($ix + 2) } }
                if ($nm -eq '') { $nm = $dn }
                $sharesDoc = BkJson (Join-Path $d.FullName 'shares.json')
                $shareList = @(); $snapList = @(); $softList = @()
                if ($null -ne $sharesDoc) {
                    if (BkHas $sharesDoc 'shares') { $shareList = @(BkGet $sharesDoc 'shares' @()) } else { $shareList = @($sharesDoc) }
                    if (BkHas $sharesDoc 'snapshots') { $snapList = @(BkGet $sharesDoc 'snapshots' @()) }
                    if (BkHas $sharesDoc 'softDeleted') { $softList = @(BkGet $sharesDoc 'softDeleted' @()) }
                }
                $accounts[$nm.ToLower()] = @{
                    name = $nm; sub = $sub; dir = $d.FullName; acct = $acc
                    location    = BkStr (BkGet $acc 'location' '')
                    shares      = $shareList
                    snaps       = $snapList
                    softDeleted = $softList
                    fsvc        = BkJson (Join-Path $d.FullName 'fileservice.json')
                }
                $accOrderAll += $nm
            }
        }

        # ------------------------------------------- Recovery Services vaults
        $bkDir = Join-Path $root 'backup'
        $vaults = @()
        if (Test-Path -LiteralPath $bkDir) {
            foreach ($d in @(Get-ChildItem -LiteralPath $bkDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
                $dn = $d.Name
                $sub = ''; $vn = $dn
                $ix = $dn.LastIndexOf('__')
                if ($ix -ge 0) { $sub = $dn.Substring(0, $ix); $vn = $dn.Substring($ix + 2) }
                $v = BkJson (Join-Path $d.FullName 'vault.json')
                $nm = BkStr (BkGet $v 'name' '')
                if ($nm -eq '') { $nm = $vn }
                $vid = BkStr (BkGet $v 'id' '')
                $vaults += @{
                    dir = $d.FullName; dirName = $dn; sub = $sub; name = $nm; id = $vid
                    location   = BkStr (BkGet $v 'location' '')
                    rg         = BkRg $vid
                    vault      = $v
                    cfg        = BkJson (Join-Path $d.FullName 'vaultconfig.json')
                    scfg       = BkJson (Join-Path $d.FullName 'storageconfig.json')
                    policies   = BkList (Join-Path $d.FullName 'policies.json')
                    items      = BkList (Join-Path $d.FullName 'protecteditems.json')
                    containers = BkList (Join-Path $d.FullName 'containers.json')
                    jobs       = BkList (Join-Path $d.FullName 'jobs.json')
                    guards     = BkList (Join-Path $d.FullName 'resourceguardproxies.json')
                    diags      = BkList (Join-Path $d.FullName 'diagnostics.json')
                    locks      = BkList (Join-Path $d.FullName 'locks.json')
                    roles      = BkList (Join-Path $d.FullName 'roleassignments.json')
                    stPolicies = BkFileState (Join-Path $d.FullName 'policies.json')
                    stItems    = BkFileState (Join-Path $d.FullName 'protecteditems.json')
                    stCont     = BkFileState (Join-Path $d.FullName 'containers.json')
                    stJobs     = BkFileState (Join-Path $d.FullName 'jobs.json')
                    stGuards   = BkFileState (Join-Path $d.FullName 'resourceguardproxies.json')
                    stDiags    = BkFileState (Join-Path $d.FullName 'diagnostics.json')
                    stLocks    = BkFileState (Join-Path $d.FullName 'locks.json')
                    stRoles    = BkFileState (Join-Path $d.FullName 'roleassignments.json')
                }
            }
        }
        $vaultByName = @{}
        $vaultRegions = @{}
        foreach ($v in $vaults) {
            $vaultByName[([string]$v.name).ToLower()] = $v
            $loc = ([string]$v.location).ToLower()
            if ($loc -ne '') { $vaultRegions[$loc] = $true }
        }

        # --------------------------------------------- Data Protection vaults
        $dpDir = Join-Path $root 'backup-dataprotection'
        $dpVaults = @()
        if (Test-Path -LiteralPath $dpDir) {
            foreach ($d in @(Get-ChildItem -LiteralPath $dpDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
                $dn = $d.Name; $sub = ''; $vn = $dn
                $ix = $dn.LastIndexOf('__')
                if ($ix -ge 0) { $sub = $dn.Substring(0, $ix); $vn = $dn.Substring($ix + 2) }
                $dv = BkJson (Join-Path $d.FullName 'vault.json')
                $nm = BkStr (BkGet $dv 'name' '')
                if ($nm -eq '') { $nm = $vn }
                $dpVaults += @{
                    name = $nm; sub = $sub; vault = $dv
                    location  = BkStr (BkGet $dv 'location' '')
                    rg        = BkRg (BkStr (BkGet $dv 'id' ''))
                    policies  = BkList (Join-Path $d.FullName 'policies.json')
                    instances = BkList (Join-Path $d.FullName 'instances.json')
                }
            }
        }

        # ------------------------------------------------- subscription locks
        $subLocks = @()
        $lockDir = Join-Path $root 'locks'
        if (Test-Path -LiteralPath $lockDir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $lockDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                foreach ($lk in @(BkList $f.FullName)) { $subLocks += $lk }
            }
        }
        $alerts = BkList (Join-Path (Join-Path $root 'monitor') 'metricalerts.json')

        # --------------------------------------------------- coverage matrix
        $covPath  = Join-Path $bkDir 'share-coverage.json'
        $covState = BkFileState $covPath
        $coverage = BkList $covPath
        $covRows = @()
        foreach ($c in @($coverage)) {
            $acct = BkStr (BkGet $c 'storageAccount' '')
            $shr  = BkStr (BkGet $c 'share' '')
            $prot = BkBool (BkGet $c 'protected' $false)
            $afs  = BkBool (BkGet $c 'azureFileSync' $false)
            $vn   = BkStr (BkGet $c 'vault' '')
            $usage = $null; $quota = $null; $accLoc = ''; $snapN = 0
            $ai = $null
            if ($acct -ne '') { $ai = $accounts[$acct.ToLower()] }
            if ($null -ne $ai) {
                $accLoc = [string]$ai.location
                foreach ($s in @($ai.shares)) {
                    if ((BkStr (BkGet $s 'name' '')).ToLower() -eq $shr.ToLower()) {
                        $usage = BkPath $s 'properties.shareUsageBytes' $null
                        $quota = BkPath $s 'properties.shareQuota' $null
                        break
                    }
                }
                foreach ($sn in @($ai.snaps)) {
                    if ((BkStr (BkGet $sn 'name' '')).ToLower() -eq $shr.ToLower()) { $snapN++ }
                }
            }
            $vloc = ''
            if ($vn -ne '') {
                $vv = $vaultByName[$vn.ToLower()]
                if ($null -ne $vv) { $vloc = [string]$vv.location }
            }
            $covRows += @{
                sub = BkStr (BkGet $c 'subscription' ''); acct = $acct; share = $shr
                afs = $afs; protected = $prot; vault = $vn; vaultLoc = $vloc
                policy = BkStr (BkGet $c 'policy' ''); state = BkStr (BkGet $c 'protectionState' '')
                last = BkStr (BkGet $c 'lastBackupStatus' ''); usage = $usage; quota = $quota
                accLoc = $accLoc; snaps = $snapN; y = 0
            }
        }
        # Unprotected-and-File-Sync first: those shares are the only copy of that data, because
        # server-side backup of a tiered endpoint is unsupported.
        $sorted = @($covRows | Sort-Object `
            @{ Expression = { if (-not $_.protected -and $_.afs) { 0 } elseif (-not $_.protected) { 1 } else { 2 } } }, `
            @{ Expression = { $_.acct } }, @{ Expression = { $_.share } })

        $nShares = @($sorted).Count
        $nProt = @($sorted | Where-Object { $_.protected }).Count
        $nUnprot = $nShares - $nProt
        $unprotBytes = 0.0
        $protBytes = 0.0
        foreach ($r in $sorted) {
            $u = 0.0
            if ($null -ne $r.usage) { try { $u = [double]$r.usage } catch { $u = 0.0 } }
            if ($r.protected) { $protBytes += $u } else { $unprotBytes += $u }
        }

        # ------------------------------------------------------- job totals
        $failedJobs = 0; $totalJobs = 0; $deleteJobs = 0
        foreach ($v in $vaults) {
            foreach ($j in @($v.jobs)) {
                $totalJobs++
                $st = BkStr (BkPath $j 'properties.status' '')
                $op = BkStr (BkPath $j 'properties.operation' '')
                if ($st -eq 'Failed') { $failedJobs++ }
                if ($op -eq 'DeleteBackupData') { $deleteJobs++ }
            }
        }
        # soft-deleted (deferred delete) items, across all vaults - the countdown to purge
        $deferred = @()
        foreach ($v in $vaults) {
            foreach ($it in @($v.items)) {
                if (BkBool (BkPath $it 'properties.isScheduledForDeferredDelete' $false)) {
                    $deferred += @{ v = $v; it = $it }
                }
            }
        }

        # ======================================================== section start
        [void]$b.Append('<section class="tab" id="tab-backup">')
        [void]$b.Append('<style>')
        [void]$b.Append('#tab-backup .bkb{display:inline-block;padding:1px 8px;border-radius:20px;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid transparent}')
        [void]$b.Append('#tab-backup .bkb .g{font-family:"IBM Plex Mono",Consolas,monospace;margin-right:5px;opacity:.9}')
        [void]$b.Append('#tab-backup .bkb.ok{background:var(--good-soft);color:var(--good);border-color:var(--good)}')
        [void]$b.Append('#tab-backup .bkb.bad{background:var(--crit-soft);color:var(--crit);border-color:var(--crit)}')
        [void]$b.Append('#tab-backup .bkb.warn{background:var(--warn-soft);color:var(--warn);border-color:var(--warn)}')
        [void]$b.Append('#tab-backup .bkb.info{background:var(--info-soft);color:var(--info);border-color:var(--info)}')
        [void]$b.Append('#tab-backup .bkb.unk{background:var(--surface-3);color:var(--muted);border-color:var(--line);border-style:dashed}')
        [void]$b.Append('#tab-backup .bknr{color:var(--faint);font-style:italic}')
        [void]$b.Append('#tab-backup .bknote{color:var(--muted);font-size:12px;margin:4px 0 10px}')
        [void]$b.Append('#tab-backup .bkgrid{display:grid;grid-template-columns:1fr 1fr;gap:12px}')
        [void]$b.Append('#tab-backup .bkwrap{overflow-x:auto;margin:6px 0 4px}')
        [void]$b.Append('#tab-backup svg{display:block;max-width:100%;height:auto}')
        [void]$b.Append('#tab-backup td.w,#tab-backup th.w{white-space:nowrap}')
        [void]$b.Append('#tab-backup table.tight th,#tab-backup table.tight td{padding:6px 8px;font-size:12px}')
        [void]$b.Append('#tab-backup tr.unprot>td:first-child{box-shadow:inset 3px 0 0 var(--crit)}')
        [void]$b.Append('#tab-backup .bkban{border-left:4px solid var(--crit);background:var(--crit-soft)}')
        [void]$b.Append('#tab-backup .bkvault{border-left:4px solid var(--accent)}')
        [void]$b.Append('#tab-backup h3 .bkb{margin-left:8px;vertical-align:middle}')
        [void]$b.Append('@media(max-width:900px){#tab-backup .bkgrid{grid-template-columns:1fr}}')
        [void]$b.Append('@media print{#tab-backup .bkwrap{overflow:visible}#tab-backup .bkb,#tab-backup tr.unprot>td:first-child{-webkit-print-color-adjust:exact;print-color-adjust:exact}#tab-backup table{page-break-inside:auto}#tab-backup tr{page-break-inside:avoid}}')
        [void]$b.Append('</style>')

        [void]$b.Append('<h2>Azure Backup</h2>')
        [void]$b.Append('<p>What the export found in <code>backup/</code> and <code>backup-dataprotection/</code>, joined to the file shares in <code>storage/</code>. ')
        [void]$b.Append('Values only - the Findings tab decides what is a finding. A field the API did not return is shown as <span class="bknr">not reported by this export</span>, which is not the same as disabled.</p>')

        # ------------------------------------------------------------- tiles
        $tileUnprot = 'info'
        if ($nUnprot -gt 0) { $tileUnprot = 'high' }
        $tileJobs = 'info'
        if ($failedJobs -gt 0) { $tileJobs = 'high' }
        [void]$b.Append('<div class="tiles">')
        [void]$b.Append('<div class="tile"><div class="n">' + @($vaults).Count + '</div><div class="l">Recovery Services vaults</div></div>')
        [void]$b.Append('<div class="tile low"><div class="n">' + $nProt + '</div><div class="l">File shares protected</div></div>')
        [void]$b.Append('<div class="tile ' + $tileUnprot + '"><div class="n">' + $nUnprot + '</div><div class="l">File shares not protected</div></div>')
        [void]$b.Append('<div class="tile ' + $tileJobs + '"><div class="n">' + $failedJobs + '</div><div class="l">Failed jobs / ' + $lookback + ' days</div></div>')
        [void]$b.Append('</div>')
        [void]$b.Append('<p class="bknote">Unprotected file-share data: <b>' + (BkEnc (BkBytes $unprotBytes)) + '</b> across ' + $nUnprot + ' share(s). Protected: ' +
                        (BkEnc (BkBytes $protBytes)) + ' across ' + $nProt + ' share(s). ' +
                        'Jobs in the window: ' + $totalJobs + ' (' + $deleteJobs + ' DeleteBackupData). ' +
                        'Backup items counting down to purge: ' + @($deferred).Count + '.</p>')

        # ---- empty state 1: no vault at all. This is the loudest possible reading of the
        #      export, so it is stated up front and the coverage matrix is still drawn below.
        $vaultCallErrs = BkErrFor $errs 'vaults:'
        if (@($vaults).Count -eq 0) {
            [void]$b.Append('<div class="card bkban"><h3 style="margin-top:0">No Recovery Services vault in scope</h3>')
            if (@($vaultCallErrs).Count -gt 0) {
                [void]$b.Append((BkErrLine $vaultCallErrs 'Recovery Services vault list'))
                [void]$b.Append('<p>Because that call failed, "no vault" here means "not captured" - do not read it as a clean bill of health.</p>')
            } elseif (-not (Test-Path -LiteralPath $bkDir)) {
                [void]$b.Append('<p>' + (BkBadge 'unk' 'not captured') + ' This export has no <code>backup/</code> directory at all, so no vault was enumerated. Read that as <b>not captured</b>, not as "no vault" - nothing here is evidence of coverage either way.</p>')
            } else {
                [void]$b.Append('<p>The export enumerated <code>Microsoft.RecoveryServices/vaults</code> and found none in the subscriptions in scope. ')
                if ($nShares -eq 0) {
                    [void]$b.Append('No Azure file share was enumerated either, so there is nothing to protect and nothing to reconcile in this export.</p>')
                } else {
                    [void]$b.Append('That means <b>' + [string]$nShares + ' file share(s), ' + (BkEnc (BkBytes ($unprotBytes + $protBytes))) + ', none protected by Azure Backup.</b></p>')
                }
                $regs = @{}
                foreach ($r in $sorted) { $rl = ([string]$r.accLoc).ToLower(); if ($rl -ne '') { $regs[$rl] = $true } }
                $regList = @($regs.Keys | Sort-Object)
                if (@($regList).Count -gt 0) {
                    [void]$b.Append('<p>Those shares live in: <code>' + (BkEnc ($regList -join ', ')) + '</code>. There is no vault in any of them.</p>')
                }
                if ($nShares -gt 0) {
                    [void]$b.Append('<p>Azure Files backup requires a vault in the <b>same region</b> as the storage account, so the first step is a vault per region, not a policy.</p>')
                }
            }
            if (@($dpVaults).Count -gt 0) {
                [void]$b.Append('<p>The estate does have Data Protection (Backup) vault(s) - ' + @($dpVaults).Count + ' of them, listed further down - just none for Azure Files.</p>')
            }
            [void]$b.Append('</div>')
        }

        # ============================================== THE PROTECTION CHAIN (SVG)
        # One row per file share, left to right: share -> container -> protected item ->
        # policy, forking into the snapshot tier (inside the storage-account box, same blast
        # radius as the data) and the vault tier (crossing out of it). Unprotected shares stop
        # dead against a red end-cap and never reach a vault. Every state carries a glyph and
        # a text badge as well as a colour, and every node has a <title> for screen readers.
        [void]$b.Append('<h2>The protection chain</h2>')
        [void]$b.Append('<div class="bkwrap">')

        $svgW = 1180
        $rowH = 74
        $bandH = 34
        $topY = $bandH + 16

        # group rows by storage account, keeping the sort order above
        $accOrder = @()
        $seenAcc = @{}
        foreach ($r in $sorted) {
            $k = ([string]$r.acct).ToLower()
            if (-not $seenAcc.ContainsKey($k)) { $seenAcc[$k] = $true; $accOrder += [string]$r.acct }
        }
        $groups = @()
        $vaultHits = @{}
        $y = $topY
        foreach ($a in $accOrder) {
            $rows = @($sorted | Where-Object { [string]$_.acct -eq $a })
            $gy0 = $y
            $y += 24
            foreach ($r in $rows) { $r.y = $y; $y += $rowH }
            $y += 8
            $groups += @{ acct = $a; y0 = $gy0; y1 = $y; rows = $rows }
            $y += 16
        }
        $rowsBottom = $y

        # vault boxes on the right, each anchored near the first row that points at it
        $vBoxH = 138
        $vy = $topY
        $vboxes = @()
        foreach ($v in $vaults) {
            $anchor = $vy
            foreach ($r in $sorted) {
                if ($r.protected -and ([string]$r.vault).ToLower() -eq ([string]$v.name).ToLower()) {
                    $cand = [int]$r.y - 24
                    if ($cand -gt $anchor) { $anchor = $cand }
                    break
                }
            }
            $vboxes += @{ v = $v; y = $anchor; h = $vBoxH }
            $vy = $anchor + $vBoxH + 16
        }
        $svgH = $rowsBottom
        if ($vy -gt $svgH) { $svgH = $vy }
        $svgH = $svgH + 42
        if ($svgH -lt 220) { $svgH = 220 }

        $aria = 'Protection chain: ' + $nProt + ' of ' + $nShares + ' file shares reach a Recovery Services vault; ' + $nUnprot + ' stop unprotected.'
        [void]$b.Append('<svg viewBox="0 0 ' + $svgW + ' ' + $svgH + '" width="' + $svgW + '" height="' + $svgH + '" role="img" aria-label="' + (BkEnc $aria) + '" xmlns="http://www.w3.org/2000/svg" style="font-family:Segoe UI,system-ui,Arial,sans-serif">')
        [void]$b.Append('<defs>')
        [void]$b.Append('<marker id="bkArr" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="var(--accent)"/></marker>')
        [void]$b.Append('<marker id="bkArrG" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="var(--faint)"/></marker>')
        [void]$b.Append('<pattern id="bkHatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" fill="var(--surface)"/><line x1="0" y1="0" x2="0" y2="6" stroke="var(--line)" stroke-width="3"/></pattern>')
        [void]$b.Append('</defs>')

        # the band that stops anyone redrawing Azure-internal paths as network work
        [void]$b.Append('<g><title>Azure-internal paths</title>')
        [void]$b.Append('<rect x="8" y="6" width="' + ($svgW - 16) + '" height="' + $bandH + '" rx="6" fill="var(--info-soft)" stroke="var(--info)" stroke-width="1"/>')
        [void]$b.Append('<text x="20" y="' + ($bandH / 2 + 11) + '" font-size="11.5" fill="var(--info)">Azure-internal, cannot be made private and does not need to be: Backup service to storage account (trusted services), and snapshot transfer into the vault. Only the management plane is client-side.</text>')
        [void]$b.Append('</g>')

        if ($nShares -eq 0 -and @($vaults).Count -eq 0) {
            [void]$b.Append('<g><title>No data</title><text x="20" y="' + ($topY + 30) + '" font-size="13" fill="var(--muted)">No file shares and no Recovery Services vault were enumerated in this export - there is no chain to draw.</text></g>')
        } elseif ($nShares -eq 0) {
            [void]$b.Append('<g><title>No file shares</title><text x="20" y="' + ($topY + 30) + '" font-size="13" fill="var(--muted)">No Azure file shares were enumerated, so the left of the chain is empty. The vault(s) found are drawn on the right.</text></g>')
        }

        # ---- account groups and their share rows
        foreach ($g in $groups) {
            $gh = [int]$g.y1 - [int]$g.y0
            [void]$b.Append('<g><title>Storage account ' + (BkEnc $g.acct) + ' - everything inside this box shares one blast radius</title>')
            [void]$b.Append('<rect x="8" y="' + $g.y0 + '" width="784" height="' + $gh + '" rx="8" fill="none" stroke="var(--line)" stroke-width="1.5" stroke-dasharray="2 3"/>')
            $accLocTxt = ''
            foreach ($rr in @($g.rows)) { if ([string]$rr.accLoc -ne '') { $accLocTxt = ' (' + [string]$rr.accLoc + ')' ; break } }
            [void]$b.Append('<text x="20" y="' + ([int]$g.y0 + 16) + '" font-size="11" font-weight="600" fill="var(--muted)">storage account ' + (BkEnc ($g.acct + $accLocTxt)) + ' - snapshots live in here</text>')
            [void]$b.Append('</g>')

            foreach ($r in @($g.rows)) {
                $ry = [int]$r.y
                $szTxt = ''
                if ($null -ne $r.usage) { $szTxt = BkBytes $r.usage }
                if ($null -ne $r.quota -and [string]$r.quota -ne '') { $szTxt = $szTxt + ' of ' + [string]$r.quota + ' GiB' }
                if ($szTxt -eq '') { $szTxt = 'size not captured' }
                $afsTxt = ''
                if ($r.afs) { $afsTxt = '[AFS]' }

                # --- share node
                $shStroke = 'var(--line)'
                if (-not $r.protected) { $shStroke = 'var(--crit)' }
                [void]$b.Append('<g><title>' + (BkEnc ([string]$r.share + ' on ' + [string]$r.acct + ' - ' + $szTxt + (& { if ($r.afs) { '; an Azure File Sync cloud endpoint' } else { '' } }) + (& { if ($r.protected) { '; protected' } else { '; NOT protected by Azure Backup' } }))) + '</title>')
                [void]$b.Append('<rect x="20" y="' + $ry + '" width="142" height="44" rx="5" fill="var(--surface)" stroke="' + $shStroke + '" stroke-width="1.5"/>')
                [void]$b.Append('<text x="28" y="' + ($ry + 17) + '" font-size="11.5" font-weight="600" fill="currentColor">' + (BkEnc (BkTrunc ([string]$r.share) 18)) + '</text>')
                [void]$b.Append('<text x="28" y="' + ($ry + 31) + '" font-size="9.5" fill="var(--muted)">' + (BkEnc $szTxt) + '</text>')
                if ($afsTxt -ne '') { [void]$b.Append('<text x="28" y="' + ($ry + 41) + '" font-size="9" font-weight="700" fill="var(--accent)">' + $afsTxt + ' File Sync cloud endpoint</text>') }
                [void]$b.Append('</g>')

                if (-not $r.protected) {
                    # the stub that stops dead - this single mark is the coverage gap
                    [void]$b.Append('<g><title>' + (BkEnc ([string]$r.share + ' is not protected by Azure Backup in any vault in this export')) + '</title>')
                    [void]$b.Append('<line x1="162" y1="' + ($ry + 22) + '" x2="196" y2="' + ($ry + 22) + '" stroke="var(--crit)" stroke-width="2"/>')
                    [void]$b.Append('<line x1="197" y1="' + ($ry + 10) + '" x2="197" y2="' + ($ry + 34) + '" stroke="var(--crit)" stroke-width="4"/>')
                    $noVaultHere = 'no backup'
                    if ([string]$r.accLoc -ne '' -and -not $vaultRegions.ContainsKey(([string]$r.accLoc).ToLower())) { $noVaultHere = 'no backup - and no vault in ' + [string]$r.accLoc }
                    [void]$b.Append('<text x="208" y="' + ($ry + 19) + '" font-size="11" font-weight="700" fill="var(--crit)">[-] NOT PROTECTED</text>')
                    [void]$b.Append('<text x="208" y="' + ($ry + 33) + '" font-size="9.5" fill="var(--muted)">' + (BkEnc $noVaultHere) + '</text>')
                    if ($r.afs) {
                        [void]$b.Append('<text x="208" y="' + ($ry + 45) + '" font-size="9.5" fill="var(--crit)">File Sync cache is not a backup - the share is the only copy</text>')
                    }
                    [void]$b.Append('</g>')
                    continue
                }

                # --- container node
                $cont = $null
                foreach ($vv in $vaults) {
                    foreach ($cn in @($vv.containers)) {
                        $src = BkStr (BkPath $cn 'properties.sourceResourceId' '')
                        if ($src -ne '' -and (BkLeaf $src).ToLower() -eq ([string]$r.acct).ToLower()) { $cont = $cn; break }
                    }
                    if ($null -ne $cont) { break }
                }
                $regTxt = 'container not captured'
                $healthTxt = ''
                $cStroke = 'var(--line)'
                if ($null -ne $cont) {
                    $regTxt = BkStr (BkPath $cont 'properties.registrationStatus' 'registration not reported')
                    $healthTxt = BkStr (BkPath $cont 'properties.healthStatus' '')
                    if ($healthTxt -eq 'Deleted') { $cStroke = 'var(--warn)' }
                }
                [void]$b.Append('<g><title>' + (BkEnc ('Protection container for ' + [string]$r.acct + ' - ' + $regTxt + (& { if ($healthTxt -ne '') { ' / health ' + $healthTxt } else { '' } }))) + '</title>')
                [void]$b.Append('<rect x="180" y="' + $ry + '" width="136" height="44" rx="5" fill="var(--surface)" stroke="' + $cStroke + '" stroke-width="1.5"/>')
                [void]$b.Append('<text x="188" y="' + ($ry + 17) + '" font-size="10.5" font-weight="600" fill="currentColor">container</text>')
                [void]$b.Append('<text x="188" y="' + ($ry + 30) + '" font-size="9.5" fill="var(--muted)">' + (BkEnc (BkTrunc $regTxt 20)) + '</text>')
                if ($healthTxt -ne '') {
                    $hcol = 'var(--muted)'
                    if ($healthTxt -eq 'Deleted') { $hcol = 'var(--warn)' }
                    [void]$b.Append('<text x="188" y="' + ($ry + 41) + '" font-size="9.5" font-weight="600" fill="' + $hcol + '">health ' + (BkEnc $healthTxt) + '</text>')
                }
                [void]$b.Append('</g>')
                [void]$b.Append('<line x1="162" y1="' + ($ry + 22) + '" x2="176" y2="' + ($ry + 22) + '" stroke="var(--accent)" stroke-width="1.5" marker-end="url(#bkArr)"/>')

                # --- protected item node: two independent dots, because real data pairs
                #     ProtectionStopped with lastBackupStatus Completed.
                $st = [string]$r.state
                $lb = [string]$r.last
                $stCol = 'var(--faint)'
                if ($st -eq 'Protected') { $stCol = 'var(--good)' } elseif ($st -eq 'IRPending') { $stCol = 'var(--warn)' } elseif ($st -ne '') { $stCol = 'var(--crit)' }
                $lbCol = 'var(--faint)'
                if ($lb -eq 'Healthy' -or $lb -eq 'Completed') { $lbCol = 'var(--good)' } elseif ($lb -eq 'IRPending') { $lbCol = 'var(--warn)' } elseif ($lb -ne '') { $lbCol = 'var(--crit)' }
                $stTxt = $st; if ($stTxt -eq '') { $stTxt = 'state not reported' }
                $lbTxt = $lb; if ($lbTxt -eq '') { $lbTxt = 'last backup not reported' }
                [void]$b.Append('<g><title>' + (BkEnc ('Protected item ' + [string]$r.share + ' - protectionState ' + $stTxt + ', lastBackupStatus ' + $lbTxt + ' (independent fields)')) + '</title>')
                [void]$b.Append('<rect x="332" y="' + $ry + '" width="152" height="44" rx="5" fill="var(--surface)" stroke="var(--line)" stroke-width="1.5"/>')
                [void]$b.Append('<text x="340" y="' + ($ry + 16) + '" font-size="10.5" font-weight="600" fill="currentColor">' + (BkEnc (BkTrunc ([string]$r.share) 20)) + '</text>')
                [void]$b.Append('<circle cx="345" cy="' + ($ry + 27) + '" r="4" fill="' + $stCol + '"/>')
                [void]$b.Append('<text x="354" y="' + ($ry + 30) + '" font-size="9.5" fill="var(--muted)">' + (BkEnc (BkTrunc $stTxt 22)) + '</text>')
                [void]$b.Append('<circle cx="345" cy="' + ($ry + 38) + '" r="4" fill="' + $lbCol + '"/>')
                [void]$b.Append('<text x="354" y="' + ($ry + 41) + '" font-size="9.5" fill="var(--muted)">' + (BkEnc (BkTrunc $lbTxt 22)) + '</text>')
                [void]$b.Append('</g>')
                [void]$b.Append('<line x1="316" y1="' + ($ry + 22) + '" x2="328" y2="' + ($ry + 22) + '" stroke="var(--accent)" stroke-width="1.5" marker-end="url(#bkArr)"/>')

                # --- policy node
                $polName = [string]$r.policy
                $pol = $null
                if ($polName -ne '' -and [string]$r.vault -ne '') {
                    $vv = $vaultByName[([string]$r.vault).ToLower()]
                    if ($null -ne $vv) {
                        foreach ($p in @($vv.policies)) {
                            if ((BkStr (BkGet $p 'name' '')).ToLower() -eq $polName.ToLower()) { $pol = $p; break }
                        }
                    }
                }
                $schedTxt = 'schedule not captured'
                $retTxt = ''
                $hasVaultTier = $false
                if ($null -ne $pol) {
                    $freq = BkStr (BkPath $pol 'properties.schedulePolicy.scheduleRunFrequency' '')
                    if ($freq -eq 'Hourly') {
                        $iv = BkStr (BkPath $pol 'properties.schedulePolicy.hourlySchedule.interval' '')
                        $schedTxt = 'every ' + $iv + 'h'
                    } elseif ($freq -ne '') { $schedTxt = $freq }
                    $dr = BkPath $pol 'properties.retentionPolicy.dailySchedule.retentionDuration.count' $null
                    if ($null -ne $dr) { $retTxt = 'keep ' + [string]$dr + 'd' }
                    if ($null -ne (BkPath $pol 'properties.vaultRetentionPolicy' $null)) { $hasVaultTier = $true }
                }
                $polLabel = $polName
                if ($polLabel -eq '') { $polLabel = 'policy name not reported' }
                [void]$b.Append('<g><title>' + (BkEnc ('Backup policy ' + $polLabel + ' - ' + $schedTxt + ' ' + $retTxt)) + '</title>')
                [void]$b.Append('<rect x="502" y="' + $ry + '" width="156" height="44" rx="5" fill="var(--surface)" stroke="var(--line)" stroke-width="1.5"/>')
                [void]$b.Append('<text x="510" y="' + ($ry + 16) + '" font-size="10.5" font-weight="600" fill="currentColor">' + (BkEnc (BkTrunc $polLabel 22)) + '</text>')
                [void]$b.Append('<text x="510" y="' + ($ry + 29) + '" font-size="9.5" fill="var(--muted)">' + (BkEnc $schedTxt) + '</text>')
                [void]$b.Append('<text x="510" y="' + ($ry + 40) + '" font-size="9.5" fill="var(--muted)">' + (BkEnc $retTxt) + '</text>')
                [void]$b.Append('</g>')
                [void]$b.Append('<line x1="484" y1="' + ($ry + 22) + '" x2="498" y2="' + ($ry + 22) + '" stroke="var(--accent)" stroke-width="1.5" marker-end="url(#bkArr)"/>')

                # --- fork 1: the snapshot tier, drawn INSIDE the account box
                [void]$b.Append('<g><title>Snapshot tier: recovery points are share snapshots held in this same storage account, so they share its blast radius</title>')
                [void]$b.Append('<line x1="658" y1="' + ($ry + 14) + '" x2="670" y2="' + ($ry + 14) + '" stroke="var(--accent)" stroke-width="1.5" marker-end="url(#bkArr)"/>')
                [void]$b.Append('<rect x="672" y="' + ($ry + 2) + '" width="112" height="24" rx="12" fill="var(--surface-3)" stroke="var(--line)"/>')
                [void]$b.Append('<text x="681" y="' + ($ry + 18) + '" font-size="10" font-weight="600" fill="currentColor">[+] snapshot tier</text>')
                [void]$b.Append('</g>')

                # --- fork 2: the vault tier, crossing out of the account box
                $vb = $null
                foreach ($x in $vboxes) { if (([string]$x.v.name).ToLower() -eq ([string]$r.vault).ToLower()) { $vb = $x; break } }
                # fan the connectors out a little so several shares into one vault stay countable
                $hk = ([string]$r.vault).ToLower()
                $hn = 0
                if ($vaultHits.ContainsKey($hk)) { $hn = [int]$vaultHits[$hk] }
                $vaultHits[$hk] = $hn + 1
                $bx = 800 + (($hn % 4) * 8)
                $vcy = $ry + 34
                if ($null -ne $vb) {
                    $vcy = [int]$vb.y + [int]($vb.h / 2) + ((($hn % 3) - 1) * 14)
                    if ($vcy -lt ([int]$vb.y + 10)) { $vcy = [int]$vb.y + 10 }
                    if ($vcy -gt ([int]$vb.y + [int]$vb.h - 10)) { $vcy = [int]$vb.y + [int]$vb.h - 10 }
                }
                $lineCol = 'var(--accent)'
                $dash = ''
                $mk = 'url(#bkArr)'
                $tierTxt = 'vault-standard tier'
                if (-not $hasVaultTier) { $lineCol = 'var(--faint)'; $dash = ' stroke-dasharray="5 4"'; $mk = 'url(#bkArrG)'; $tierTxt = 'vault tier NOT configured' }
                [void]$b.Append('<g><title>' + (BkEnc ('Vault tier: ' + $tierTxt + ' (policy vaultRetentionPolicy ' + (& { if ($hasVaultTier) { 'present' } else { 'absent - the offsite copy is missing' } }) + ')')) + '</title>')
                [void]$b.Append('<path d="M 658 ' + ($ry + 36) + ' L ' + $bx + ' ' + ($ry + 36) + ' L ' + $bx + ' ' + $vcy + ' L 842 ' + $vcy + '" fill="none" stroke="' + $lineCol + '" stroke-width="1.5"' + $dash + ' marker-end="' + $mk + '"/>')
                [void]$b.Append('<text x="664" y="' + ($ry + 33) + '" font-size="9" fill="' + $lineCol + '">' + (BkEnc $tierTxt) + '</text>')
                [void]$b.Append('</g>')
            }
        }

        # ---- the four vault guards, each with its fallback source and a third "not reported"
        #      state. On real vaults properties.securitySettings is absent entirely, so soft
        #      delete comes only from vaultconfig.json and immutability / MUA have no source
        #      at all - which is a different fact from "Disabled" and is shown as such.
        function BkGuards {
            param($v, $subLocks)
            $vp   = BkPath $v.vault 'properties' $null
            $sec  = BkGet $vp 'securitySettings' $null
            $cfgp = BkPath $v.cfg 'properties' $null
            $sd   = BkGet $sec 'softDeleteSettings' $null

            # soft delete
            $sdVal = ''; $sdSrc = ''
            if (BkHas $sd 'softDeleteState') { $sdVal = BkStr (BkGet $sd 'softDeleteState' ''); $sdSrc = 'vault.json properties.securitySettings.softDeleteSettings.softDeleteState' }
            elseif (BkHas $cfgp 'softDeleteFeatureState') { $sdVal = BkStr (BkGet $cfgp 'softDeleteFeatureState' ''); $sdSrc = 'vaultconfig.json properties.softDeleteFeatureState' }
            $sdState = 'unk'
            if ($sdVal -eq 'AlwaysON') { $sdState = 'ok' } elseif ($sdVal -eq 'Enabled') { $sdState = 'warn' } elseif ($sdVal -ne '') { $sdState = 'bad' }
            $sdDays = BkGet $sd 'softDeleteRetentionPeriodInDays' (BkGet $cfgp 'softDeleteRetentionPeriodInDays' $null)
            $enh    = BkGet $sd 'enhancedSecurityState' (BkGet $cfgp 'enhancedSecurityState' $null)
            $edit   = BkGet $cfgp 'isSoftDeleteFeatureStateEditable' $null

            # immutability
            $imVal = ''; $imSrc = ''
            $im = BkGet $sec 'immutabilitySettings' $null
            if (BkHas $im 'state') { $imVal = BkStr (BkGet $im 'state' ''); $imSrc = 'vault.json properties.securitySettings.immutabilitySettings.state' }
            $imState = 'unk'
            if ($imVal -eq 'Locked') { $imState = 'ok' } elseif ($imVal -eq 'Unlocked') { $imState = 'warn' } elseif ($imVal -ne '') { $imState = 'bad' }

            # multi-user authorization: a string on some vaults, an object with .state on others
            $muVal = ''; $muSrc = ''
            if (BkHas $sec 'multiUserAuthorization') {
                $mu = BkGet $sec 'multiUserAuthorization' $null
                if ($mu -is [string]) { $muVal = [string]$mu } else { $muVal = BkStr (BkGet $mu 'state' '') }
                $muSrc = 'vault.json properties.securitySettings.multiUserAuthorization'
            }
            $nGuards = @($v.guards).Count
            $muState = 'unk'
            if ($muVal -eq 'Enabled') { $muState = 'ok' } elseif ($muVal -ne '') { $muState = 'bad' }
            if ($muState -ne 'ok' -and $nGuards -gt 0) { $muState = 'ok' }
            if ($muState -eq 'unk' -and [string]$v.stGuards -eq 'empty') { $muState = 'bad' }

            # delete lock: at the vault, plus any inherited subscription / RG / tenant lock
            $lockNames = @()
            foreach ($lk in @($v.locks)) {
                $lvl = BkStr (BkPath $lk 'properties.level' '')
                if ($lvl -eq 'CanNotDelete' -or $lvl -eq 'ReadOnly') { $lockNames += ((BkStr (BkGet $lk 'name' (BkLeaf (BkStr (BkGet $lk 'id' ''))))) + ' (' + $lvl + ', at the vault)') }
            }
            $vidL = ([string]$v.id).ToLower()
            foreach ($lk in @($subLocks)) {
                $lvl = BkStr (BkPath $lk 'properties.level' '')
                if ($lvl -ne 'CanNotDelete' -and $lvl -ne 'ReadOnly') { continue }
                $lid = ([string](BkGet $lk 'id' '')).ToLower()
                $cut = $lid.IndexOf('/providers/microsoft.authorization/locks/')
                if ($cut -lt 0) { continue }
                $scope = $lid.Substring(0, $cut)
                if ($scope -eq '' -or $vidL -eq '') { continue }
                if ($vidL.StartsWith($scope)) {
                    $lockNames += ((BkStr (BkGet $lk 'name' (BkLeaf (BkStr (BkGet $lk 'id' ''))))) + ' (' + $lvl + ', inherited)')
                }
            }
            $lkState = 'bad'
            if (@($lockNames).Count -gt 0) { $lkState = 'ok' }
            if ([string]$v.stLocks -eq 'missing' -and @($lockNames).Count -eq 0) { $lkState = 'unk' }

            return @{
                sdVal = $sdVal; sdState = $sdState; sdSrc = $sdSrc; sdDays = $sdDays; enh = $enh; editable = $edit
                imVal = $imVal; imState = $imState; imSrc = $imSrc
                muVal = $muVal; muState = $muState; muSrc = $muSrc; guardCount = $nGuards
                lockNames = $lockNames; lkState = $lkState
                secPresent = ($null -ne $sec)
            }
        }

        # ---- redundancy and cross-region restore, saying which source answered
        function BkRedundancy {
            param($v)
            $red = BkPath $v.vault 'properties.redundancySettings' $null
            $sp  = BkPath $v.scfg 'properties' $null
            $mode = ''; $modeSrc = ''
            if (BkHas $red 'standardTierStorageRedundancy') { $mode = BkStr (BkGet $red 'standardTierStorageRedundancy' ''); $modeSrc = 'vault.json properties.redundancySettings.standardTierStorageRedundancy' }
            elseif (BkHas $sp 'storageModelType') { $mode = BkStr (BkGet $sp 'storageModelType' ''); $modeSrc = 'storageconfig.json properties.storageModelType' }
            $crr = ''; $crrSrc = ''
            if (BkHas $red 'crossRegionRestore') { $crr = BkStr (BkGet $red 'crossRegionRestore' ''); $crrSrc = 'vault.json properties.redundancySettings.crossRegionRestore' }
            elseif (BkHas $sp 'crossRegionRestoreFlag') { $crr = (& { if (BkBool (BkGet $sp 'crossRegionRestoreFlag' $false)) { 'Enabled' } else { 'Disabled' } }); $crrSrc = 'storageconfig.json properties.crossRegionRestoreFlag' }
            return @{
                mode = $mode; modeSrc = $modeSrc; crr = $crr; crrSrc = $crrSrc
                storageType = BkStr (BkGet $sp 'storageType' '')
                typeState   = BkStr (BkGet $sp 'storageTypeState' '')
                dedup       = BkStr (BkGet $sp 'dedupState' '')
                xcool       = BkStr (BkGet $sp 'xcoolState' '')
            }
        }

        # ---- vault boxes on the right of the diagram
        foreach ($x in $vboxes) {
            $v = $x.v
            $vy0 = [int]$x.y
            $gs = BkGuards $v $subLocks
            $rd = BkRedundancy $v
            $vTitle = 'Recovery Services vault ' + [string]$v.name + ' in ' + [string]$v.location
            [void]$b.Append('<g><title>' + (BkEnc $vTitle) + '</title>')
            [void]$b.Append('<rect x="842" y="' + $vy0 + '" width="324" height="' + $x.h + '" rx="8" fill="var(--surface)" stroke="var(--accent)" stroke-width="2"/>')
            [void]$b.Append('<text x="854" y="' + ($vy0 + 19) + '" font-size="12" font-weight="700" fill="currentColor">' + (BkEnc (BkTrunc ([string]$v.name) 30)) + '</text>')
            $skuTxt = BkStr (BkPath $v.vault 'sku.name' '')
            $tierTxt = BkStr (BkPath $v.vault 'sku.tier' '')
            if ($tierTxt -ne '') { $skuTxt = $skuTxt + '/' + $tierTxt }
            [void]$b.Append('<text x="854" y="' + ($vy0 + 32) + '" font-size="9.5" fill="var(--muted)">' + (BkEnc (([string]$v.location) + '  sku ' + $skuTxt + '  ' + [string]$v.sub)) + '</text>')
            [void]$b.Append('</g>')

            # redundancy, and whether it can still be changed
            $modeShort = $rd.mode
            if ($modeShort -eq 'LocallyRedundant') { $modeShort = 'LRS' } elseif ($modeShort -eq 'GeoRedundant') { $modeShort = 'GRS' } elseif ($modeShort -eq 'ZoneRedundant') { $modeShort = 'ZRS' } elseif ($modeShort -eq '') { $modeShort = '?' }
            $modeCol = 'var(--muted)'
            if ($modeShort -eq 'GRS') { $modeCol = 'var(--good)' } elseif ($modeShort -eq 'LRS') { $modeCol = 'var(--crit)' }
            [void]$b.Append('<g><title>' + (BkEnc ('Vault storage redundancy ' + (& { if ($rd.mode -eq '') { 'not reported' } else { $rd.mode } }) + '; storageTypeState ' + (& { if ($rd.typeState -eq '') { 'not reported' } else { $rd.typeState } }) + '. Redundancy is immutable once the first item is protected.')) + '</title>')
            [void]$b.Append('<rect x="854" y="' + ($vy0 + 40) + '" width="112" height="34" rx="5" fill="var(--surface-2)" stroke="var(--line)"/>')
            [void]$b.Append('<text x="862" y="' + ($vy0 + 56) + '" font-size="12" font-weight="700" fill="' + $modeCol + '">' + (BkEnc $modeShort) + '</text>')
            $tsTxt = $rd.typeState
            if ($tsTxt -eq '') { $tsTxt = 'state ?' }
            [void]$b.Append('<text x="862" y="' + ($vy0 + 69) + '" font-size="9" fill="var(--muted)">' + (BkEnc $tsTxt) + '</text>')
            [void]$b.Append('</g>')

            # paired region: solid when cross-region restore is on, ghost when off
            $crrOn = ($rd.crr -eq 'Enabled')
            $prCol = 'var(--faint)'; $prDash = ' stroke-dasharray="5 4"'; $prMk = 'url(#bkArrG)'; $prTxt = 'paired region: no CRR'
            if ($crrOn) { $prCol = 'var(--good)'; $prDash = ''; $prMk = 'url(#bkArr)'; $prTxt = 'paired region: CRR on' }
            [void]$b.Append('<g><title>' + (BkEnc ('Cross Region Restore ' + (& { if ($rd.crr -eq '') { 'not reported' } else { $rd.crr } }) + ' (' + $rd.crrSrc + ')')) + '</title>')
            [void]$b.Append('<line x1="968" y1="' + ($vy0 + 57) + '" x2="988" y2="' + ($vy0 + 57) + '" stroke="' + $prCol + '" stroke-width="1.5"' + $prDash + ' marker-end="' + $prMk + '"/>')
            [void]$b.Append('<rect x="990" y="' + ($vy0 + 43) + '" width="164" height="28" rx="5" fill="var(--surface-2)" stroke="' + $prCol + '"' + $prDash + '/>')
            [void]$b.Append('<text x="998" y="' + ($vy0 + 61) + '" font-size="10" fill="' + $prCol + '">' + (BkEnc $prTxt) + '</text>')
            [void]$b.Append('</g>')

            # the four guards: solid when on, dashed when off, hatched with ? when not reported
            $gdefs = @(
                @{ k = 'SD';   s = $gs.sdState; t = 'soft delete' },
                @{ k = 'IMM';  s = $gs.imState; t = 'immutability' },
                @{ k = 'MUA';  s = $gs.muState; t = 'multi-user auth / Resource Guard' },
                @{ k = 'LOCK'; s = $gs.lkState; t = 'delete lock' }
            )
            $gx = 854
            foreach ($gd in $gdefs) {
                $fill = 'var(--surface-2)'; $strk = 'var(--line)'; $dsh = ''; $gly = '[?]'; $col = 'var(--muted)'
                if ($gd.s -eq 'ok')   { $fill = 'var(--good-soft)'; $strk = 'var(--good)'; $gly = '[+]'; $col = 'var(--good)' }
                elseif ($gd.s -eq 'warn') { $fill = 'var(--warn-soft)'; $strk = 'var(--warn)'; $gly = '[!]'; $col = 'var(--warn)' }
                elseif ($gd.s -eq 'bad')  { $fill = 'var(--surface)';  $strk = 'var(--crit)'; $dsh = ' stroke-dasharray="4 3"'; $gly = '[-]'; $col = 'var(--crit)' }
                else { $fill = 'url(#bkHatch)'; $dsh = ' stroke-dasharray="4 3"' }
                [void]$b.Append('<g><title>' + (BkEnc ($gd.t + ': ' + (& { if ($gd.s -eq 'ok') { 'on' } elseif ($gd.s -eq 'warn') { 'partial' } elseif ($gd.s -eq 'bad') { 'off' } else { 'not reported by this export' } }))) + '</title>')
                [void]$b.Append('<rect x="' + $gx + '" y="' + ($vy0 + 82) + '" width="74" height="26" rx="4" fill="' + $fill + '" stroke="' + $strk + '" stroke-width="1.5"' + $dsh + '/>')
                [void]$b.Append('<text x="' + ($gx + 7) + '" y="' + ($vy0 + 99) + '" font-size="10" font-weight="700" fill="' + $col + '">' + $gly + ' ' + $gd.k + '</text>')
                [void]$b.Append('</g>')
                $gx += 78
            }
            [void]$b.Append('<text x="854" y="' + ($vy0 + 125) + '" font-size="9" fill="var(--muted)">[+] on   [-] off   [!] partial   [?] not reported by this export</text>')
        }

        [void]$b.Append('</svg></div>')
        [void]$b.Append('<p class="bknote">Read it left to right. A share that never reaches a vault is the coverage gap; a dashed grey line to the vault is a policy with no vault-standard tier, so the only recovery points are snapshots inside the same storage account. The four segments on each vault are its guards - a hatched segment means the export did not report the setting, which is not the same as off.</p>')

        # ============================================================ COVERAGE MATRIX
        [void]$b.Append('<h2>Coverage matrix - every file share, protected or not</h2>')
        $covErr = BkErrFor $errs 'shares:'
        if ($nShares -eq 0) {
            [void]$b.Append((BkEmpty $covState 'backup/share-coverage.json' 'No file shares were enumerated, so there is nothing to reconcile. Coverage cannot be asserted either way.' $covErr 'file share list'))
        } else {
            $declared = BkPath $counts 'fileShares' $null
            $recon = ''
            if ($null -ne $declared) {
                if ([string]$declared -eq [string]$nShares) {
                    $recon = 'Reconciles with <code>manifest.counts.fileShares = ' + (BkEnc $declared) + '</code>.'
                } else {
                    $recon = 'Does <b>not</b> reconcile with <code>manifest.counts.fileShares = ' + (BkEnc $declared) + '</code> - coverage lists only shares in storage accounts the export enumerated, so completeness cannot be claimed.'
                }
            }
            [void]$b.Append('<p class="bknote">' + $nShares + ' share(s) listed, sorted so that unprotected File Sync cloud endpoints come first - for those the Azure file share is the only backup, because server-side backup of a tiered server endpoint is unsupported. ' + $recon + '</p>')
            [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr>')
            [void]$b.Append('<th>Share</th><th>Storage account</th><th class="w">Region</th><th class="w">File Sync</th><th class="w">Used</th><th class="w">Quota</th>')
            [void]$b.Append('<th class="w">Protected</th><th>Vault</th><th>Policy</th><th class="w">Protection state</th><th class="w">Last backup</th><th>Region check</th>')
            [void]$b.Append('</tr></thead><tbody>')
            foreach ($r in $sorted) {
                $cls = ''
                if (-not $r.protected) { $cls = ' class="unprot"' }
                [void]$b.Append('<tr' + $cls + '>')
                [void]$b.Append('<td class="w"><b>' + (BkEnc $r.share) + '</b></td>')
                [void]$b.Append('<td class="w">' + (BkEnc $r.acct) + '</td>')
                [void]$b.Append('<td class="w">' + (BkVal $r.accLoc 'account not in export') + '</td>')
                if ($r.afs) { [void]$b.Append('<td class="w">' + (BkBadge 'info' 'cloud endpoint') + '</td>') } else { [void]$b.Append('<td class="w">no</td>') }
                [void]$b.Append('<td class="num">' + (BkVal (BkBytes $r.usage) 'not captured') + '</td>')
                $q = ''
                if ($null -ne $r.quota -and [string]$r.quota -ne '') { $q = [string]$r.quota + ' GiB' }
                [void]$b.Append('<td class="num">' + (BkVal $q 'not captured') + '</td>')
                if ($r.protected) { [void]$b.Append('<td class="w">' + (BkBadge 'ok' 'yes') + '</td>') } else { [void]$b.Append('<td class="w">' + (BkBadge 'bad' 'no') + '</td>') }
                [void]$b.Append('<td class="w">' + (BkVal $r.vault '-') + '</td>')
                $pol = [string]$r.policy
                if ($r.protected -and $pol -eq '') { [void]$b.Append('<td>' + (BkNR 'policy name not reported') + '</td>') } else { [void]$b.Append('<td class="w">' + (BkVal $pol '-') + '</td>') }
                # protectionState and lastBackupStatus are independent - never derive one
                $stS = 'info'
                if ([string]$r.state -eq 'Protected') { $stS = 'ok' } elseif ([string]$r.state -eq 'IRPending') { $stS = 'warn' } elseif ([string]$r.state -ne '') { $stS = 'bad' }
                $lbS = 'info'
                if ([string]$r.last -eq 'Healthy' -or [string]$r.last -eq 'Completed') { $lbS = 'ok' } elseif ([string]$r.last -eq 'IRPending') { $lbS = 'warn' } elseif ([string]$r.last -ne '') { $lbS = 'bad' }
                if ([string]$r.state -eq '') { [void]$b.Append('<td class="w">-</td>') } else { [void]$b.Append('<td class="w">' + (BkBadge $stS ([string]$r.state)) + '</td>') }
                if ([string]$r.last -eq '') { [void]$b.Append('<td class="w">-</td>') } else { [void]$b.Append('<td class="w">' + (BkBadge $lbS ([string]$r.last)) + '</td>') }
                # Azure Files backup requires the vault in the account's region
                $chk = ''
                $al = ([string]$r.accLoc).ToLower()
                if ($r.protected) {
                    $vl = ([string]$r.vaultLoc).ToLower()
                    if ($al -eq '' -or $vl -eq '') { $chk = (BkNR 'region not reported') }
                    elseif ($al -eq $vl) { $chk = (BkBadge 'ok' 'same region') }
                    else { $chk = (BkBadge 'bad' ('account ' + $al + ' vs vault ' + $vl)) }
                } else {
                    if ($al -eq '') { $chk = (BkNR 'region not reported') }
                    elseif ($vaultRegions.ContainsKey($al)) { $chk = (BkBadge 'warn' ('vault exists in ' + $al)) }
                    else { $chk = (BkBadge 'bad' ('no vault in ' + $al)) }
                }
                [void]$b.Append('<td class="w">' + $chk + '</td>')
                [void]$b.Append('</tr>')
            }
            [void]$b.Append('</tbody></table></div>')
            [void]$b.Append('<p class="bknote">"Region check" on an unprotected row answers the question that comes before any policy: is there a vault in that region at all. On a protected row it confirms the account and its vault are co-located, which Azure Files backup requires.</p>')
        }

        # ================================================== PER-VAULT DETAIL
        foreach ($v in $vaults) {
            $vp = BkPath $v.vault 'properties' $null
            $gs = BkGuards $v $subLocks
            $rd = BkRedundancy $v
            $vlabel = [string]$v.name

            [void]$b.Append('<h2>Recovery Services vault <code>' + (BkEnc $vlabel) + '</code></h2>')

            # ---------------------------------------------------- identity card
            [void]$b.Append('<div class="card bkvault"><div class="kv">')
            [void]$b.Append('<div class="k">Subscription</div><div>' + (BkVal ([string]$v.sub) 'directory prefix missing') + ' <span class="bknote">(from the directory name <code>' + (BkEnc ([string]$v.dirName)) + '</code>; inventory.json omits it)</span></div>')
            [void]$b.Append('<div class="k">Resource group</div><div>' + (BkVal ([string]$v.rg) 'not derivable from vault.json id') + '</div>')
            [void]$b.Append('<div class="k">Location</div><div>' + (BkVal ([string]$v.location) '') + '</div>')
            $skuN = BkStr (BkPath $v.vault 'sku.name' '')
            $skuT = BkStr (BkPath $v.vault 'sku.tier' '')
            $skuTxt = $skuN
            if ($skuT -ne '') { $skuTxt = $skuN + ' / ' + $skuT } elseif ($skuN -ne '') { $skuTxt = $skuN + ' (no tier reported)' }
            [void]$b.Append('<div class="k">SKU</div><div>' + (BkVal $skuTxt '') + '</div>')
            [void]$b.Append('<div class="k">Provisioning state</div><div>' + (BkVal (BkGet $vp 'provisioningState' '') '') + '</div>')
            [void]$b.Append('<div class="k">Public network access</div><div>' + (BkVal (BkGet $vp 'publicNetworkAccess' '') '') + '</div>')
            [void]$b.Append('<div class="k">Private endpoint (backup)</div><div>' + (BkVal (BkGet $vp 'privateEndpointStateForBackup' '') '') + ' <span class="bknote">a private endpoint on the vault does not apply to Azure Files backup, which is Azure-internal</span></div>')
            [void]$b.Append('<div class="k">Private endpoint (Site Recovery)</div><div>' + (BkVal (BkGet $vp 'privateEndpointStateForSiteRecovery' '') '') + '</div>')
            $bcdr = BkStr (BkGet $vp 'bcdrSecurityLevel' '')
            $bcdrHtml = BkNR ''
            if ($bcdr -ne '') {
                $bs = 'info'
                if ($bcdr -eq 'Poor') { $bs = 'bad' } elseif ($bcdr -eq 'Excellent' -or $bcdr -eq 'Good') { $bs = 'ok' } elseif ($bcdr -eq 'Fair') { $bs = 'warn' }
                $bcdrHtml = (BkBadge $bs $bcdr) + ' <span class="bknote">Microsoft''s own security grade for the vault</span>'
            }
            [void]$b.Append('<div class="k">BCDR security level</div><div>' + $bcdrHtml + '</div>')
            [void]$b.Append('<div class="k">Secure score</div><div>' + (BkVal (BkGet $vp 'secureScore' '') '') + '</div>')
            [void]$b.Append('<div class="k">Cross-subscription restore</div><div>' + (BkVal (BkPath $vp 'restoreSettings.crossSubscriptionRestoreSettings.crossSubscriptionRestoreState' '') '') + '</div>')
            $tags = BkGet $v.vault 'tags' $null
            $tagTxt = ''
            if ($null -ne $tags) {
                $tp = @()
                try { foreach ($p in $tags.PSObject.Properties) { $tp += ($p.Name + '=' + [string]$p.Value) } } catch { $tp = @() }
                $tagTxt = ($tp -join ', ')
            }
            [void]$b.Append('<div class="k">Tags</div><div>' + (BkVal $tagTxt 'no tags on the vault') + ' <span class="bknote">tag names are matched case-insensitively</span></div>')
            [void]$b.Append('<div class="k">Resource id</div><div class="res">' + (BkVal ([string]$v.id) '') + '</div>')
            [void]$b.Append('<div class="k">ETag</div><div class="ev">' + (BkVal (BkGet $v.vault 'etag' '') '') + '</div>')
            [void]$b.Append('</div></div>')

            # ------------------------------------- redundancy + cross-region restore
            [void]$b.Append('<h3>Storage redundancy and cross-region restore</h3>')
            [void]$b.Append('<div class="card"><div class="kv">')
            $modeS = 'unk'
            if ($rd.mode -eq 'GeoRedundant' -or $rd.mode -eq 'ZoneRedundant') { $modeS = 'ok' } elseif ($rd.mode -eq 'LocallyRedundant') { $modeS = 'bad' } elseif ($rd.mode -ne '') { $modeS = 'info' }
            $modeHtml = BkNR ''
            if ($rd.mode -ne '') { $modeHtml = (BkBadge $modeS $rd.mode) + ' <span class="bknote">source: <code>' + (BkEnc $rd.modeSrc) + '</code></span>' }
            [void]$b.Append('<div class="k">Vault storage redundancy</div><div>' + $modeHtml + '</div>')
            $tsHtml = BkNR ''
            if ($rd.typeState -ne '') {
                $tsS = 'info'
                if ($rd.typeState -eq 'Locked') { $tsS = 'warn' }
                $tsNote = ''
                if ($rd.typeState -eq 'Locked') { $tsNote = ' <span class="bknote">locked: redundancy is fixed once the first item is protected, so changing it means a new vault</span>' }
                if ($rd.typeState -eq 'Unlocked') { $tsNote = ' <span class="bknote">still changeable - no item has been protected yet</span>' }
                $tsHtml = (BkBadge $tsS $rd.typeState) + $tsNote
            }
            [void]$b.Append('<div class="k">storageTypeState</div><div>' + $tsHtml + '</div>')
            $crrHtml = BkNR ''
            if ($rd.crr -ne '') {
                $crrS = 'bad'
                if ($rd.crr -eq 'Enabled') { $crrS = 'ok' }
                $crrHtml = (BkBadge $crrS $rd.crr) + ' <span class="bknote">source: <code>' + (BkEnc $rd.crrSrc) + '</code></span>'
            }
            [void]$b.Append('<div class="k">Cross Region Restore</div><div>' + $crrHtml + '</div>')
            [void]$b.Append('<div class="k">storageType</div><div>' + (BkVal $rd.storageType '') + '</div>')
            [void]$b.Append('<div class="k">dedupState / xcoolState</div><div>' + (BkVal $rd.dedup '') + ' / ' + (BkVal $rd.xcool '') + '</div>')
            [void]$b.Append('</div></div>')

            # ------------------------------------------------- four vault guards
            [void]$b.Append('<h3>Vault guards</h3>')
            if (-not $gs.secPresent) {
                [void]$b.Append('<p class="bknote">' + (BkBadge 'unk' 'partial') + ' <code>vault.json properties.securitySettings</code> is absent on this vault, so soft delete is read from <code>vaultconfig.json</code> and immutability / multi-user authorization have <b>no source in this export at all</b>. They are shown below as not reported, not as disabled.</p>')
            }
            [void]$b.Append('<div class="card"><div class="kv">')
            $sdHtml = BkNR ''
            if ($gs.sdVal -ne '') {
                $sdExtra = ''
                if ($null -ne $gs.sdDays) { $sdExtra += ' retention ' + (BkEnc $gs.sdDays) + ' days.' }
                if ($gs.sdVal -eq 'Enabled') { $sdExtra += ' Enabled but not always-on: it can be turned off again.' }
                $sdHtml = (BkBadge $gs.sdState $gs.sdVal) + ' <span class="bknote">' + $sdExtra + ' source: <code>' + (BkEnc $gs.sdSrc) + '</code></span>'
            }
            [void]$b.Append('<div class="k">Soft delete</div><div>' + $sdHtml + '</div>')
            [void]$b.Append('<div class="k">Soft delete retention (days)</div><div>' + (BkVal $gs.sdDays '') + '</div>')
            [void]$b.Append('<div class="k">Enhanced security state</div><div>' + (BkVal $gs.enh '') + '</div>')
            $edHtml = BkNR ''
            if ($null -ne $gs.editable) {
                if (BkBool $gs.editable) { $edHtml = (BkBadge 'warn' 'true') + ' <span class="bknote">an attacker holding vault rights can still turn soft delete off</span>' }
                else { $edHtml = (BkBadge 'ok' 'false') + ' <span class="bknote">soft delete cannot be turned off</span>' }
            }
            [void]$b.Append('<div class="k">isSoftDeleteFeatureStateEditable</div><div>' + $edHtml + '</div>')
            $imHtml = BkNR 'no source in this export (securitySettings absent)'
            if ($gs.imVal -ne '') { $imHtml = (BkBadge $gs.imState $gs.imVal) + ' <span class="bknote">source: <code>' + (BkEnc $gs.imSrc) + '</code></span>' }
            [void]$b.Append('<div class="k">Immutability</div><div>' + $imHtml + '</div>')
            $muTxt = $gs.muVal
            if ($muTxt -eq '') {
                if ($gs.guardCount -gt 0) { $muTxt = 'Resource Guard attached' }
                elseif ([string]$v.stGuards -eq 'missing') { $muTxt = 'not reported' }
                else { $muTxt = 'no Resource Guard (vault setting not reported)' }
            }
            $muHtml = (BkBadge $gs.muState $muTxt) + ' <span class="bknote">' + @($v.guards).Count + ' Resource Guard proxy(ies) in <code>resourceguardproxies.json</code>'
            if ($gs.muSrc -ne '') { $muHtml += '; setting source <code>' + (BkEnc $gs.muSrc) + '</code>' }
            $muHtml += '</span>'
            [void]$b.Append('<div class="k">Multi-user authorization</div><div>' + $muHtml + '</div>')
            if (@($v.guards).Count -gt 0) {
                $gn = @()
                foreach ($g in @($v.guards)) { $gn += (BkStr (BkGet $g 'name' (BkLeaf (BkStr (BkGet $g 'id' ''))))) }
                [void]$b.Append('<div class="k">Resource Guard proxies</div><div class="ev">' + (BkEnc ($gn -join ', ')) + '</div>')
            }
            $lkHtml = BkBadge 'bad' 'no delete lock'
            if (@($gs.lockNames).Count -gt 0) { $lkHtml = (BkBadge 'ok' (([string]@($gs.lockNames).Count) + ' lock(s)')) + ' <span class="ev">' + (BkEnc ((@($gs.lockNames)) -join '; ')) + '</span>' }
            elseif ($gs.lkState -eq 'unk') { $lkHtml = BkNR 'locks.json was not written for this vault' }
            [void]$b.Append('<div class="k">Delete lock</div><div>' + $lkHtml + '</div>')
            [void]$b.Append('</div></div>')

            # --------------------------------------------------------- monitoring
            [void]$b.Append('<h3>Monitoring</h3>')
            $mon = BkGet $vp 'monitoringSettings' $null
            [void]$b.Append('<div class="card"><div class="kv">')
            if ($null -eq $mon) {
                [void]$b.Append('<div class="k">monitoringSettings</div><div>' + (BkNR 'the whole monitoringSettings block is absent from this vault.json - unknown, not Disabled') + '</div>')
            } else {
                $am = BkGet $mon 'azureMonitorAlertSettings' $null
                $cl = BkGet $mon 'classicAlertSettings' $null
                $jf = BkStr (BkGet $am 'alertsForAllJobFailures' '')
                $jfHtml = BkNR ''
                if ($jf -ne '') { $s = 'bad'; if ($jf -eq 'Enabled') { $s = 'ok' }; $jfHtml = BkBadge $s $jf }
                [void]$b.Append('<div class="k">Alerts for all job failures</div><div>' + $jfHtml + '</div>')
                [void]$b.Append('<div class="k">Alerts for replication issues</div><div>' + (BkVal (BkGet $am 'alertsForAllReplicationIssues' '') '') + '</div>')
                [void]$b.Append('<div class="k">Alerts for failover issues</div><div>' + (BkVal (BkGet $am 'alertsForAllFailoverIssues' '') '') + '</div>')
                [void]$b.Append('<div class="k">Classic: critical operations</div><div>' + (BkVal (BkGet $cl 'alertsForCriticalOperations' '') '') + '</div>')
                [void]$b.Append('<div class="k">Classic: Site Recovery e-mail</div><div>' + (BkVal (BkGet $cl 'emailNotificationsForSiteRecovery' '') '') + '</div>')
            }
            [void]$b.Append('</div></div>')

            $diagErr = BkErrFor $errs ('diagnostics:' + $vlabel)
            [void]$b.Append('<h4>Diagnostic settings</h4>')
            if (@($v.diags).Count -eq 0) {
                [void]$b.Append((BkEmpty ([string]$v.stDiags) 'diagnostics.json' 'No diagnostic setting on this vault - AzureBackupReport / CoreAzureBackup / AddonAzureBackupJobs logs are not being shipped anywhere.' $diagErr 'diagnostic settings'))
            } else {
                [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th>Setting</th><th>Workspace</th><th>Log categories</th><th>Metrics</th><th class="w">Destination type</th></tr></thead><tbody>')
                foreach ($ds in @($v.diags)) {
                    $logs = @()
                    foreach ($lg in @(BkPath $ds 'properties.logs' @())) {
                        $cn = BkStr (BkGet $lg 'category' (BkGet $lg 'categoryGroup' ''))
                        $en = BkBool (BkGet $lg 'enabled' $false)
                        if ($cn -ne '') { $logs += ($cn + (& { if ($en) { ' [+]' } else { ' [-]' } })) }
                    }
                    $mets = @()
                    foreach ($mt in @(BkPath $ds 'properties.metrics' @())) {
                        $cn = BkStr (BkGet $mt 'category' '')
                        $en = BkBool (BkGet $mt 'enabled' $false)
                        if ($cn -ne '') { $mets += ($cn + (& { if ($en) { ' [+]' } else { ' [-]' } })) }
                    }
                    [void]$b.Append('<tr><td class="w">' + (BkVal (BkGet $ds 'name' '') '') + '</td>')
                    [void]$b.Append('<td class="res">' + (BkVal (BkLeaf (BkStr (BkPath $ds 'properties.workspaceId' ''))) 'no workspace') + '</td>')
                    [void]$b.Append('<td class="ev">' + (BkVal ($logs -join ', ') 'none') + '</td>')
                    [void]$b.Append('<td class="ev">' + (BkVal ($mets -join ', ') 'none') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkPath $ds 'properties.logAnalyticsDestinationType' '') '') + '</td></tr>')
                }
                [void]$b.Append('</tbody></table></div>')
            }

            $vAlerts = @()
            foreach ($al in @($alerts)) {
                foreach ($sc in @(BkPath $al 'properties.scopes' @())) {
                    if (([string]$sc).ToLower() -eq ([string]$v.id).ToLower()) { $vAlerts += $al; break }
                }
            }
            if (@($vAlerts).Count -gt 0) {
                [void]$b.Append('<h4>Metric alert rules scoped to this vault</h4><div class="bkwrap"><table class="tight"><thead><tr><th>Rule</th><th class="w">Enabled</th><th class="w">Severity</th><th class="w">Evaluation</th></tr></thead><tbody>')
                foreach ($al in $vAlerts) {
                    [void]$b.Append('<tr><td>' + (BkVal (BkGet $al 'name' '') '') + '</td><td class="w">' + (BkVal (BkPath $al 'properties.enabled' '') '') +
                                    '</td><td class="w num">' + (BkVal (BkPath $al 'properties.severity' '') '') + '</td><td class="w">' + (BkVal (BkPath $al 'properties.evaluationFrequency' '') '') + '</td></tr>')
                }
                [void]$b.Append('</tbody></table></div>')
            }

            # ---------------------------------------------------- protected items
            $itemErr = BkErrFor $errs ('protectedItems:' + $vlabel)
            $fileItems = @(); $otherItems = @()
            foreach ($it in @($v.items)) {
                if ((BkStr (BkPath $it 'properties.workloadType' '')) -eq 'AzureFileShare') { $fileItems += $it } else { $otherItems += $it }
            }
            [void]$b.Append('<h3>Protected items - Azure Files (' + @($fileItems).Count + ')</h3>')
            if (@($v.items).Count -eq 0) {
                [void]$b.Append((BkEmpty ([string]$v.stItems) 'protecteditems.json' 'The vault exists and nothing is protected in it.' $itemErr 'protected item list'))
            } elseif (@($fileItems).Count -eq 0) {
                [void]$b.Append('<p class="bknote">' + (BkBadge 'info' 'none') + ' No Azure file share is protected in this vault, although it holds ' + @($otherItems).Count + ' item(s) of other workload types (below).</p>')
            } else {
                [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr>')
                [void]$b.Append('<th>Friendly name</th><th class="w">Storage account</th><th class="w">Protection state</th><th class="w">Protection status</th><th class="w">Last backup</th><th class="w">Last backup time</th><th>Policy</th><th class="w">Recovery points</th><th class="w">Oldest point</th><th>Soft-delete countdown</th></tr></thead><tbody>')
                foreach ($it in $fileItems) {
                    $ip = BkPath $it 'properties' $null
                    $fn = BkStr (BkGet $ip 'friendlyName' '')
                    # never parse the item name for the share name - it is a 64-hex hash in real data
                    if ($fn -eq '') { $fn = '(friendlyName not reported)' }
                    $src = BkStr (BkGet $ip 'sourceResourceId' '')
                    $san = BkLeaf $src
                    if ($san -eq '') {
                        $cn = BkStr (BkGet $ip 'containerName' '')
                        if ($cn -ne '') { $pp = $cn.Split(';'); $san = $pp[$pp.Length - 1] }
                    }
                    $st = BkStr (BkGet $ip 'protectionState' '')
                    $ps = BkStr (BkGet $ip 'protectionStatus' '')
                    $lb = BkStr (BkGet $ip 'lastBackupStatus' '')
                    $stS = 'info'
                    if ($st -eq 'Protected') { $stS = 'ok' } elseif ($st -eq 'IRPending') { $stS = 'warn' } elseif ($st -ne '') { $stS = 'bad' }
                    $psS = 'info'
                    if ($ps -eq 'Healthy') { $psS = 'ok' } elseif ($ps -ne '') { $psS = 'bad' }
                    $lbS = 'info'
                    if ($lb -eq 'Healthy' -or $lb -eq 'Completed') { $lbS = 'ok' } elseif ($lb -eq 'IRPending') { $lbS = 'warn' } elseif ($lb -ne '') { $lbS = 'bad' }
                    [void]$b.Append('<tr><td class="w"><b>' + (BkEnc $fn) + '</b>')
                    $proto = BkStr (BkGet $ip 'fileShareProtocol' '')
                    if ($proto -ne '') { [void]$b.Append(' <span class="bknote">' + (BkEnc $proto) + '</span>') }
                    [void]$b.Append('</td><td class="w">' + (BkVal $san '') + '</td>')
                    if ($st -eq '') { [void]$b.Append('<td class="w">' + (BkNR '') + '</td>') } else { [void]$b.Append('<td class="w">' + (BkBadge $stS $st) + '</td>') }
                    if ($ps -eq '') { [void]$b.Append('<td class="w">' + (BkNR '') + '</td>') } else { [void]$b.Append('<td class="w">' + (BkBadge $psS $ps) + '</td>') }
                    if ($lb -eq '') { [void]$b.Append('<td class="w">' + (BkNR '') + '</td>') } else { [void]$b.Append('<td class="w">' + (BkBadge $lbS $lb) + '</td>') }
                    [void]$b.Append('<td class="w">' + (BkVal (BkShortDate (BkGet $ip 'lastBackupTime' '')) '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $ip 'policyName' '') 'policyName not returned by the list API') + '</td>')
                    # extendedInfo needs $expand, which the exporter does not send - so a real
                    # export has no recovery-point count at all. "0" would be a false alarm.
                    $xi = BkGet $ip 'extendedInfo' $null
                    if ($null -eq $xi) {
                        [void]$b.Append('<td class="w">' + (BkNR 'not captured (needs $expand)') + '</td><td class="w">' + (BkNR 'not captured') + '</td>')
                    } else {
                        [void]$b.Append('<td class="num">' + (BkVal (BkGet $xi 'recoveryPointCount' '') 'not captured') + '</td>')
                        [void]$b.Append('<td class="w">' + (BkVal (BkShortDate (BkGet $xi 'oldestRecoveryPoint' '')) 'not captured') + '</td>')
                    }
                    if (BkBool (BkGet $ip 'isScheduledForDeferredDelete' $false)) {
                        $rem = BkStr (BkGet $ip 'deferredDeleteTimeRemaining' '')
                        $when = BkShortDate (BkGet $ip 'deferredDeleteTimeInUTC' '')
                        $ret = BkStr (BkGet $ip 'softDeleteRetentionPeriod' '')
                        $txt = 'purges in ' + (BkSpan $rem)
                        if ($rem -eq '') { $txt = 'soft-deleted' }
                        [void]$b.Append('<td>' + (BkBadge 'bad' $txt) + ' <span class="bknote">deleted ' + (BkEnc $when))
                        if ($ret -ne '') { [void]$b.Append('; retention ' + (BkEnc $ret) + ' days') }
                        [void]$b.Append('</span></td>')
                    } else {
                        [void]$b.Append('<td class="w">-</td>')
                    }
                    [void]$b.Append('</tr>')
                }
                [void]$b.Append('</tbody></table></div>')
                [void]$b.Append('<p class="bknote">protectionState and lastBackupStatus are independent fields and routinely disagree - a real item can be <code>ProtectionStopped</code> with <code>lastBackupStatus Completed</code>. <code>IRPending</code> means initial replication has not finished: not yet protected, not a failure. <code>Completed</code> and <code>Healthy</code> both mean good.</p>')
            }

            if (@($otherItems).Count -gt 0) {
                [void]$b.Append('<h4>Protected items - other workloads (' + @($otherItems).Count + ', inventory only)</h4>')
                [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th>Friendly name</th><th class="w">Workload</th><th>Item type</th><th class="w">Management type</th><th>Policy</th><th class="w">Protection state</th><th class="w">Last backup</th></tr></thead><tbody>')
                foreach ($it in $otherItems) {
                    $ip = BkPath $it 'properties' $null
                    [void]$b.Append('<tr><td class="w">' + (BkVal (BkGet $ip 'friendlyName' (BkGet $it 'name' '')) '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $ip 'workloadType' '') '') + '</td>')
                    [void]$b.Append('<td class="ev">' + (BkVal (BkGet $ip 'protectedItemType' '') '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $ip 'backupManagementType' '') '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $ip 'policyName' '') 'not reported') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $ip 'protectionState' '') '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $ip 'lastBackupStatus' '') '') + '</td></tr>')
                }
                [void]$b.Append('</tbody></table></div>')
            }

            # -------------------------------------------------------- policies
            $polErr = BkErrFor $errs ('backupPolicies:' + $vlabel)
            [void]$b.Append('<h3>Backup policies (' + @($v.policies).Count + ')</h3>')
            if (@($v.policies).Count -eq 0) {
                [void]$b.Append((BkEmpty ([string]$v.stPolicies) 'policies.json' 'No backup policy in this vault.' $polErr 'backup policy list'))
            } else {
                $storagePols = @(); $otherPols = @()
                foreach ($p in @($v.policies)) {
                    if ((BkStr (BkPath $p 'properties.backupManagementType' '')) -eq 'AzureStorage') { $storagePols += $p } else { $otherPols += $p }
                }
                $polGroups = @(
                    @{ t = 'Azure Files (AzureStorage)'; list = $storagePols; note = 'These are the policies that protect Azure file shares. The vault tier column is the binary that matters: snapshot-only keeps every recovery point inside the same storage account as the data.' },
                    @{ t = 'Other workloads'; list = $otherPols; note = 'VM, SQL and other policies in the same vault - shown so the non-file protected items above have a policy to point at.' }
                )
                foreach ($pg in $polGroups) {
                    if (@($pg.list).Count -eq 0) { continue }
                    [void]$b.Append('<h4>' + (BkEnc $pg.t) + ' (' + @($pg.list).Count + ')</h4>')
                    [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th>Policy</th><th class="w">Type</th><th class="w">Items</th><th>Schedule</th><th>Snapshot retention</th><th>Vault tier</th><th class="w">Instant RP</th></tr></thead><tbody>')
                    foreach ($p in @($pg.list)) {
                        $pp = BkPath $p 'properties' $null
                        $bmt = BkStr (BkGet $pp 'backupManagementType' '')
                        $wl = BkStr (BkGet $pp 'workLoadType' '')
                        $pt = BkStr (BkGet $pp 'policyType' '')
                        $typeTxt = $bmt
                        if ($wl -ne '' -and $wl -ne 'None') { $typeTxt += ' / ' + $wl }
                        if ($pt -ne '' -and $pt -ne 'None') { $typeTxt += ' ' + $pt }

                        # schedule: SimpleSchedulePolicy, SimpleSchedulePolicyV2 (hourly),
                        # or none at top level (AzureWorkload keeps it in subProtectionPolicy)
                        $schedParts = @()
                        $sp = BkGet $pp 'schedulePolicy' $null
                        if ($null -ne $sp) {
                            $freq = BkStr (BkGet $sp 'scheduleRunFrequency' '')
                            $hs = BkGet $sp 'hourlySchedule' $null
                            if ($null -ne $hs) {
                                $schedParts += ('every ' + (BkStr (BkGet $hs 'interval' '?')) + 'h from ' + (BkShortDate (BkGet $hs 'scheduleWindowStartTime' '')) + ' for ' + (BkStr (BkGet $hs 'scheduleWindowDuration' '?')) + 'h')
                            } else {
                                $times = @()
                                foreach ($t in @(BkGet $sp 'scheduleRunTimes' @())) { $times += (BkShortDate $t) }
                                $schedParts += ($freq + (& { if (@($times).Count -gt 0) { ' at ' + ($times -join ', ') } else { '' } }))
                            }
                            $spt = BkStr (BkGet $sp 'schedulePolicyType' '')
                            if ($spt -ne '') { $schedParts += ('(' + $spt + ')') }
                        }
                        foreach ($sub in @(BkGet $pp 'subProtectionPolicy' @())) {
                            $sptype = BkStr (BkGet $sub 'policyType' '')
                            $ssp = BkGet $sub 'schedulePolicy' $null
                            $mins = BkStr (BkGet $ssp 'scheduleFrequencyInMins' '')
                            if ($mins -ne '') { $schedParts += ($sptype + ': every ' + $mins + ' min') }
                            else { $schedParts += ($sptype + ': ' + (BkStr (BkGet $ssp 'scheduleRunFrequency' 'schedule not reported'))) }
                        }
                        $schedTxt = ($schedParts -join ' ')

                        # snapshot retention, all four schedules
                        $rp = BkGet $pp 'retentionPolicy' $null
                        $retParts = @()
                        foreach ($rk in @(@{ n = 'daily'; p = 'dailySchedule' }, @{ n = 'weekly'; p = 'weeklySchedule' }, @{ n = 'monthly'; p = 'monthlySchedule' }, @{ n = 'yearly'; p = 'yearlySchedule' })) {
                            $cnt = BkPath $rp ($rk.p + '.retentionDuration.count') $null
                            $dt = BkPath $rp ($rk.p + '.retentionDuration.durationType') ''
                            if ($null -ne $cnt) { $retParts += ($rk.n + ' ' + [string]$cnt + ' ' + [string]$dt) }
                        }
                        if (@($retParts).Count -eq 0) {
                            foreach ($sub in @(BkGet $pp 'subProtectionPolicy' @())) {
                                $c2 = BkPath $sub 'retentionPolicy.dailySchedule.retentionDuration.count' (BkPath $sub 'retentionPolicy.retentionDuration.count' $null)
                                if ($null -ne $c2) { $retParts += ((BkStr (BkGet $sub 'policyType' '')) + ' ' + [string]$c2 + ' days') }
                            }
                        }
                        $retTxt = ($retParts -join ', ')

                        # vault tier: presence of vaultRetentionPolicy is the whole question
                        $vr = BkGet $pp 'vaultRetentionPolicy' $null
                        $vrHtml = ''
                        if ($null -eq $vr) {
                            if ($bmt -eq 'AzureStorage') { $vrHtml = (BkBadge 'bad' 'snapshot-only') + ' <span class="bknote">recovery points stay in the same storage account as the data</span>' }
                            else { $vrHtml = '<span class="bknote">n/a</span>' }
                        } else {
                            $vparts = @()
                            $snapDays = BkGet $vr 'snapshotRetentionInDays' $null
                            if ($null -ne $snapDays) { $vparts += ('snapshots ' + [string]$snapDays + 'd') }
                            foreach ($rk in @(@{ n = 'daily'; p = 'dailySchedule' }, @{ n = 'weekly'; p = 'weeklySchedule' }, @{ n = 'monthly'; p = 'monthlySchedule' }, @{ n = 'yearly'; p = 'yearlySchedule' })) {
                                $c3 = BkPath $vr ('vaultRetention.' + $rk.p + '.retentionDuration.count') $null
                                if ($null -ne $c3) { $vparts += ('vault ' + $rk.n + ' ' + [string]$c3) }
                            }
                            $vrHtml = (BkBadge 'ok' 'snapshot + vault-standard') + ' <span class="bknote">' + (BkEnc ($vparts -join ', ')) + '</span>'
                        }
                        [void]$b.Append('<tr><td class="w"><b>' + (BkVal (BkGet $p 'name' '') '') + '</b></td>')
                        [void]$b.Append('<td class="w">' + (BkVal $typeTxt '') + '</td>')
                        [void]$b.Append('<td class="num">' + (BkVal (BkGet $pp 'protectedItemsCount' '0') '') + '</td>')
                        [void]$b.Append('<td>' + (BkVal $schedTxt 'no schedulePolicy on this policy') + ' <span class="bknote">' + (BkEnc (BkStr (BkGet $pp 'timeZone' ''))) + '</span></td>')
                        [void]$b.Append('<td>' + (BkVal $retTxt 'not reported') + '</td>')
                        [void]$b.Append('<td>' + $vrHtml + '</td>')
                        [void]$b.Append('<td class="num">' + (BkVal (BkGet $pp 'instantRpRetentionRangeInDays' '') '-') + '</td></tr>')
                    }
                    [void]$b.Append('</tbody></table></div>')
                    [void]$b.Append('<p class="bknote">' + (BkEnc $pg.note) + '</p>')
                }
                [void]$b.Append('<p class="bknote"><code>protectedItemsCount</code> is frequently 0 on real policies even where items exist - read the protected-items table above for what is actually protected.</p>')
            }

            # ------------------------------------------------------ containers
            $contErr = BkErrFor $errs ('containers:' + $vlabel)
            [void]$b.Append('<h3>Protection containers (' + @($v.containers).Count + ')</h3>')
            if (@($v.containers).Count -eq 0) {
                [void]$b.Append((BkEmpty ([string]$v.stCont) 'containers.json' 'No AzureStorage protection container is registered in this vault.' $contErr 'protection container list'))
            } else {
                [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th>Container</th><th class="w">Storage account</th><th class="w">Items</th><th class="w">Registration</th><th class="w">Health</th><th class="w">Account lock</th><th class="w">Type</th></tr></thead><tbody>')
                foreach ($cn in @($v.containers)) {
                    $cp = BkPath $cn 'properties' $null
                    $hs = BkStr (BkGet $cp 'healthStatus' '')
                    $hsHtml = BkNR ''
                    if ($hs -ne '') {
                        $hss = 'ok'
                        if ($hs -eq 'Deleted') { $hss = 'warn' } elseif ($hs -ne 'Healthy') { $hss = 'bad' }
                        $hsHtml = BkBadge $hss $hs
                        if ($hs -eq 'Deleted') { $hsHtml += ' <span class="bknote">the source was removed while its backup items are still listed - those items are counting down</span>' }
                    }
                    $rs = BkStr (BkGet $cp 'registrationStatus' '')
                    $rsHtml = BkNR ''
                    if ($rs -ne '') { $rss = 'ok'; if ($rs -ne 'Registered') { $rss = 'bad' }; $rsHtml = BkBadge $rss $rs }
                    [void]$b.Append('<tr><td>' + (BkVal (BkGet $cp 'friendlyName' (BkGet $cn 'name' '')) '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkLeaf (BkStr (BkGet $cp 'sourceResourceId' ''))) '') + '</td>')
                    [void]$b.Append('<td class="num">' + (BkVal (BkGet $cp 'protectedItemCount' '') '') + '</td>')
                    [void]$b.Append('<td class="w">' + $rsHtml + '</td><td>' + $hsHtml + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $cp 'acquireStorageAccountLock' '') '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $cp 'containerType' (BkGet $cp 'protectableObjectType' '')) '') + '</td></tr>')
                }
                [void]$b.Append('</tbody></table></div>')
            }

            # ------------------------------------------------------------ jobs
            $jobErr = BkErrFor $errs ('jobs:' + $vlabel)
            $winTxt = 'the last ' + $lookback + ' days'
            if ($null -ne $exportedAt) { $winTxt = $exportedAt.AddDays(-1 * $lookback).ToString('yyyy-MM-dd') + ' to ' + $exportedAt.ToString('yyyy-MM-dd') + ' (' + $lookback + ' days)' }
            [void]$b.Append('<h3>Jobs - ' + (BkEnc $winTxt) + '</h3>')
            if (@($v.jobs).Count -eq 0) {
                [void]$b.Append((BkEmpty ([string]$v.stJobs) 'jobs.json' ('No backup job in ' + $winTxt + '. The window is an ARM filter, so this means nothing ran in the window - it does not mean backup never ran.') $jobErr 'backup job list'))
            } else {
                # ---- 30-day strip: one square per day, worst status wins. An RPO gap (a run
                #      of days with no Backup job at all) is visible here long before the table.
                $endD = $exportedAt
                if ($null -eq $endD) { $endD = (Get-Date).ToUniversalTime() }
                $buckets = @{}
                foreach ($j in @($v.jobs)) {
                    $sd = BkDate (BkPath $j 'properties.startTime' '')
                    if ($null -eq $sd) { continue }
                    $off = [int]([math]::Floor(($endD.Date - $sd.Date).TotalDays))
                    if ($off -lt 0 -or $off -ge $lookback) { continue }
                    $idx = $lookback - 1 - $off
                    if (-not $buckets.ContainsKey($idx)) { $buckets[$idx] = @{ total = 0; failed = 0; warn = 0; backup = 0; del = 0 } }
                    $bk = $buckets[$idx]
                    $bk.total++
                    $stj = BkStr (BkPath $j 'properties.status' '')
                    $opj = BkStr (BkPath $j 'properties.operation' '')
                    if ($stj -eq 'Failed') { $bk.failed++ } elseif ($stj -eq 'InProgress' -or $stj -eq 'CompletedWithWarnings') { $bk.warn++ }
                    if ($opj -eq 'Backup') { $bk.backup++ }
                    if ($opj -eq 'DeleteBackupData') { $bk.del++ }
                }
                $cw = 15
                $stripW = $lookback * $cw + 16
                [void]$b.Append('<div class="bkwrap"><svg viewBox="0 0 ' + $stripW + ' 56" width="' + $stripW + '" height="56" role="img" aria-label="' +
                                (BkEnc ('Daily backup job status for ' + $vlabel + ' over ' + $lookback + ' days')) + '" xmlns="http://www.w3.org/2000/svg" style="font-family:Segoe UI,system-ui,Arial,sans-serif">')
                for ($i = 0; $i -lt $lookback; $i++) {
                    $x = 8 + $i * $cw
                    $dayD = $endD.Date.AddDays(-1 * ($lookback - 1 - $i))
                    $fill = 'var(--surface-3)'; $strk = 'var(--line)'; $lbl = 'no job'
                    if ($buckets.ContainsKey($i)) {
                        $bk = $buckets[$i]
                        $lbl = [string]$bk.total + ' job(s), ' + [string]$bk.backup + ' Backup, ' + [string]$bk.del + ' DeleteBackupData'
                        if ($bk.failed -gt 0) { $fill = 'var(--crit)'; $strk = 'var(--crit)'; $lbl += ', ' + [string]$bk.failed + ' FAILED' }
                        elseif ($bk.warn -gt 0) { $fill = 'var(--warn)'; $strk = 'var(--warn)' }
                        else { $fill = 'var(--good)'; $strk = 'var(--good)' }
                    }
                    [void]$b.Append('<g><title>' + (BkEnc ($dayD.ToString('yyyy-MM-dd') + ': ' + $lbl)) + '</title>')
                    [void]$b.Append('<rect x="' + $x + '" y="10" width="12" height="12" rx="2" fill="' + $fill + '" stroke="' + $strk + '"/></g>')
                    if (($i % 7) -eq 0) {
                        [void]$b.Append('<text x="' + $x + '" y="38" font-size="9" fill="var(--muted)">' + (BkEnc $dayD.ToString('MM-dd')) + '</text>')
                    }
                }
                [void]$b.Append('<text x="8" y="52" font-size="9" fill="var(--muted)">one square per day, oldest left. Empty square = no job that day.</text>')
                [void]$b.Append('</svg></div>')

                # ---- operation x status summary
                $ops = @{}
                foreach ($j in @($v.jobs)) {
                    $opj = BkStr (BkPath $j 'properties.operation' 'unknown')
                    $stj = BkStr (BkPath $j 'properties.status' 'unknown')
                    if (-not $ops.ContainsKey($opj)) { $ops[$opj] = @{} }
                    if (-not $ops[$opj].ContainsKey($stj)) { $ops[$opj][$stj] = 0 }
                    $ops[$opj][$stj] = $ops[$opj][$stj] + 1
                }
                $statCols = @()
                foreach ($k in @($ops.Keys)) { foreach ($s in @($ops[$k].Keys)) { if ($statCols -notcontains $s) { $statCols += $s } } }
                $statCols = @($statCols | Sort-Object)
                [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th>Operation</th>')
                foreach ($s in $statCols) { [void]$b.Append('<th class="w">' + (BkEnc $s) + '</th>') }
                [void]$b.Append('<th class="w">Total</th></tr></thead><tbody>')
                foreach ($k in @($ops.Keys | Sort-Object)) {
                    [void]$b.Append('<tr><td class="w"><b>' + (BkEnc $k) + '</b>')
                    if ($k -eq 'DeleteBackupData') { [void]$b.Append(' <span class="bknote">backup data leaving the vault</span>') }
                    [void]$b.Append('</td>')
                    $tot = 0
                    foreach ($s in $statCols) {
                        $n = 0
                        if ($ops[$k].ContainsKey($s)) { $n = [int]$ops[$k][$s] }
                        $tot += $n
                        $cell = [string]$n
                        if ($n -eq 0) { $cell = '<span class="bknr">0</span>' }
                        [void]$b.Append('<td class="num">' + $cell + '</td>')
                    }
                    [void]$b.Append('<td class="num">' + $tot + '</td></tr>')
                }
                [void]$b.Append('</tbody></table></div>')

                # ---- failures first, with Microsoft's own recommendation text verbatim
                $fails = @($v.jobs | Where-Object { (BkStr (BkPath $_ 'properties.status' '')) -eq 'Failed' })
                if (@($fails).Count -gt 0) {
                    [void]$b.Append('<h4>Failed jobs (' + @($fails).Count + ') with the error the service returned</h4>')
                    foreach ($j in $fails) {
                        $jp = BkPath $j 'properties' $null
                        [void]$b.Append('<div class="card"><div><span class="sev high">Failed</span> <b>' + (BkVal (BkGet $jp 'operation' '') '') + '</b> ')
                        [void]$b.Append((BkVal (BkGet $jp 'entityFriendlyName' '') '') + ' <span class="ev">' + (BkEnc (BkShortDate (BkGet $jp 'startTime' ''))))
                        $du = BkDur (BkStr (BkGet $jp 'duration' ''))
                        if ($du -ne '') { [void]$b.Append(' for ' + (BkEnc $du)) }
                        [void]$b.Append('</span></div>')
                        foreach ($ed in @(BkGet $jp 'errorDetails' @())) {
                            [void]$b.Append('<div class="ev">errorCode ' + (BkVal (BkGet $ed 'errorCode' '') '') + '</div>')
                            [void]$b.Append('<p>' + (BkVal (BkGet $ed 'errorString' '') 'no error text returned') + '</p>')
                            $recs = @(BkGet $ed 'recommendations' @())
                            if (@($recs).Count -gt 0) {
                                [void]$b.Append('<p class="bknote">Service recommendation, verbatim:</p><ul>')
                                foreach ($rc in $recs) { [void]$b.Append('<li>' + (BkEnc $rc) + '</li>') }
                                [void]$b.Append('</ul>')
                            }
                        }
                        if (@(BkGet $jp 'errorDetails' @()).Count -eq 0) {
                            [void]$b.Append('<p class="bknote">The job is Failed but carries no errorDetails in this export.</p>')
                        }
                        [void]$b.Append('</div>')
                    }
                }

                # ---- the job table, newest first, capped so a busy vault stays readable
                $jsorted = @($v.jobs | Sort-Object @{ Expression = { $d = BkDate (BkPath $_ 'properties.startTime' ''); if ($null -eq $d) { [datetime]'1900-01-01' } else { $d } }; Descending = $true })
                $cap = 60
                $shown = @($jsorted)
                if (@($jsorted).Count -gt $cap) { $shown = @($jsorted[0..($cap - 1)]) }
                [void]$b.Append('<h4>Job detail (' + @($shown).Count + ' of ' + @($jsorted).Count + ', newest first)</h4>')
                [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th class="w">Start</th><th class="w">End</th><th class="w">Duration</th><th class="w">Operation</th><th class="w">Status</th><th>Entity</th><th class="w">Storage account</th><th class="w">Job type</th><th class="w">User triggered</th><th>Activity id</th></tr></thead><tbody>')
                foreach ($j in $shown) {
                    $jp = BkPath $j 'properties' $null
                    $stj = BkStr (BkGet $jp 'status' '')
                    $sjs = 'info'
                    if ($stj -eq 'Completed') { $sjs = 'ok' } elseif ($stj -eq 'Failed') { $sjs = 'bad' } elseif ($stj -ne '') { $sjs = 'warn' }
                    [void]$b.Append('<tr><td class="w">' + (BkVal (BkShortDate (BkGet $jp 'startTime' '')) '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkShortDate (BkGet $jp 'endTime' '')) 'still running') + '</td>')
                    [void]$b.Append('<td class="w num">' + (BkVal (BkDur (BkStr (BkGet $jp 'duration' ''))) '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $jp 'operation' '') '') + '</td>')
                    if ($stj -eq '') { [void]$b.Append('<td class="w">' + (BkNR '') + '</td>') } else { [void]$b.Append('<td class="w">' + (BkBadge $sjs $stj) + '</td>') }
                    [void]$b.Append('<td>' + (BkVal (BkGet $jp 'entityFriendlyName' '') '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $jp 'storageAccountName' '') '-') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $jp 'jobType' (BkGet $jp 'backupManagementType' '')) '') + '</td>')
                    [void]$b.Append('<td class="w">' + (BkVal (BkGet $jp 'isUserTriggered' '') '-') + '</td>')
                    [void]$b.Append('<td class="ev">' + (BkVal (BkGet $jp 'activityId' '') '') + '</td></tr>')
                }
                [void]$b.Append('</tbody></table></div>')
                if (@($jsorted).Count -gt $cap) {
                    [void]$b.Append('<p class="bknote">' + (@($jsorted).Count - $cap) + ' older job(s) in the window are not listed here; every failure in the window is listed above regardless.</p>')
                }
            }

            # -------------------------------------------- who can delete the backups
            $rbacErr = BkErrFor $errs ('rbac:' + $vlabel)
            [void]$b.Append('<h3>Who can delete these backups</h3>')
            if (@($v.roles).Count -eq 0) {
                [void]$b.Append((BkEmpty ([string]$v.stRoles) 'roleassignments.json' 'No role assignment was returned at or above this vault.' $rbacErr 'role assignment list'))
            } else {
                $byScope = @{}
                $byRole = @{}
                $byType = @{}
                $atVault = 0
                foreach ($ra in @($v.roles)) {
                    $sc = BkStr (BkGet $ra 'scope' '')
                    $kind = BkScopeKind $sc ([string]$v.id)
                    if ($kind -eq 'this vault') { $atVault++ }
                    if (-not $byScope.ContainsKey($kind)) { $byScope[$kind] = 0 }
                    $byScope[$kind] = $byScope[$kind] + 1
                    $rn = BkStr (BkGet $ra 'roleName' 'unnamed role')
                    if (-not $byRole.ContainsKey($rn)) { $byRole[$rn] = 0 }
                    $byRole[$rn] = $byRole[$rn] + 1
                    $ptp = BkStr (BkGet $ra 'principalType' 'unknown')
                    if (-not $byType.ContainsKey($ptp)) { $byType[$ptp] = 0 }
                    $byType[$ptp] = $byType[$ptp] + 1
                }
                $hiRoles = @('Owner', 'Contributor', 'User Access Administrator', 'Backup Contributor', 'Backup Operator', 'Backup Trusted Operator', 'Role Based Access Control Administrator')
                $hiCount = 0
                foreach ($rn in @($byRole.Keys)) { if ($hiRoles -contains $rn) { $hiCount += [int]$byRole[$rn] } }
                [void]$b.Append('<p class="bknote">' + @($v.roles).Count + ' assignment(s) returned by ARM''s <code>atScope()</code> filter, which returns the vault scope <b>and every parent</b> - the tenant root, management groups, the subscription and the resource group. ' +
                                $atVault + ' are on the vault itself. The exporter flattens them without a Graph lookup, so principals are object ids and always will be.</p>')
                [void]$b.Append('<div class="bkgrid">')
                [void]$b.Append('<div class="card"><h4 style="margin-top:0">By scope</h4><table class="tight"><tbody>')
                foreach ($k in @($byScope.Keys | Sort-Object)) {
                    $lab = $k
                    if ($k -ne 'this vault') { $lab = $k + ' (inherited)' }
                    [void]$b.Append('<tr><td>' + (BkEnc $lab) + '</td><td class="num">' + $byScope[$k] + '</td></tr>')
                }
                [void]$b.Append('</tbody></table></div>')
                [void]$b.Append('<div class="card"><h4 style="margin-top:0">By principal type</h4><table class="tight"><tbody>')
                foreach ($k in @($byType.Keys | Sort-Object)) { [void]$b.Append('<tr><td>' + (BkEnc $k) + '</td><td class="num">' + $byType[$k] + '</td></tr>') }
                [void]$b.Append('</tbody></table></div>')
                [void]$b.Append('</div>')

                [void]$b.Append('<h4>By role (privileged roles first)</h4><div class="bkwrap"><table class="tight"><thead><tr><th>Role</th><th class="w">Assignments</th><th>Can it delete backup data?</th></tr></thead><tbody>')
                $ordered = @()
                foreach ($rn in $hiRoles) { if ($byRole.ContainsKey($rn)) { $ordered += $rn } }
                foreach ($rn in @($byRole.Keys | Sort-Object)) { if ($ordered -notcontains $rn) { $ordered += $rn } }
                foreach ($rn in $ordered) {
                    $note = ''
                    if ($rn -eq 'Owner' -or $rn -eq 'Contributor') { $note = 'yes - full control of the vault' }
                    elseif ($rn -eq 'Backup Contributor') { $note = 'yes - can stop protection and delete backup data' }
                    elseif ($rn -eq 'Backup Operator') { $note = 'partly - can trigger operations, not delete the vault' }
                    elseif ($rn -eq 'User Access Administrator' -or $rn -eq 'Role Based Access Control Administrator') { $note = 'indirectly - can grant itself any of the above' }
                    else { $note = 'not a backup-privileged role' }
                    [void]$b.Append('<tr><td>' + (BkEnc $rn) + '</td><td class="num">' + $byRole[$rn] + '</td><td class="bknote">' + (BkEnc $note) + '</td></tr>')
                }
                [void]$b.Append('</tbody></table></div>')
                [void]$b.Append('<p class="bknote"><b>' + $hiCount + '</b> assignment(s) hold a role that can delete or stop these backups, at the vault or above it. That number is the argument a Resource Guard answers; whether it is a finding is the Findings tab''s call.</p>')

                $hiRows = @($v.roles | Where-Object { $hiRoles -contains (BkStr (BkGet $_ 'roleName' '')) })
                if (@($hiRows).Count -gt 0) {
                    $rcap = 25
                    $rshown = @($hiRows)
                    if (@($hiRows).Count -gt $rcap) { $rshown = @($hiRows[0..($rcap - 1)]) }
                    [void]$b.Append('<h4>Privileged assignments (' + @($rshown).Count + ' of ' + @($hiRows).Count + ')</h4><div class="bkwrap"><table class="tight"><thead><tr><th>Role</th><th class="w">Principal type</th><th>Principal id</th><th>Scope</th><th class="w">Created</th><th class="w">Condition</th></tr></thead><tbody>')
                    foreach ($ra in $rshown) {
                        $sc = BkStr (BkGet $ra 'scope' '')
                        [void]$b.Append('<tr><td class="w">' + (BkVal (BkGet $ra 'roleName' '') '') + '</td>')
                        [void]$b.Append('<td class="w">' + (BkVal (BkGet $ra 'principalType' '') '') + '</td>')
                        [void]$b.Append('<td class="ev">' + (BkVal (BkGet $ra 'principalId' '') '') + '</td>')
                        [void]$b.Append('<td class="res">' + (BkEnc (BkScopeKind $sc ([string]$v.id))) + ': ' + (BkEnc (BkTrunc $sc 64)) + '</td>')
                        [void]$b.Append('<td class="w">' + (BkVal (BkShortDate (BkGet $ra 'createdOn' '')) '') + '</td>')
                        [void]$b.Append('<td class="w">' + (BkVal (BkGet $ra 'condition' '') 'none') + '</td></tr>')
                    }
                    [void]$b.Append('</tbody></table></div>')
                    if (@($hiRows).Count -gt $rcap) {
                        [void]$b.Append('<p class="bknote">' + (@($hiRows).Count - $rcap) + ' further privileged assignment(s) are counted above but not listed - the raw rows are in <code>' + (BkEnc ([string]$v.dirName)) + '/roleassignments.json</code>.</p>')
                    }
                }
            }
        }

        # ============================================== DATA PROTECTION VAULTS
        [void]$b.Append('<h2>Data Protection (Backup) vaults</h2>')
        $dpErr = BkErrFor $errs 'dataProtectionVaults:'
        if (@($dpVaults).Count -eq 0) {
            if (@($dpErr).Count -gt 0) {
                [void]$b.Append((BkErrLine $dpErr 'Data Protection vault list'))
            } elseif (-not (Test-Path -LiteralPath $dpDir)) {
                [void]$b.Append('<p class="bknote">' + (BkBadge 'unk' 'not in export') + ' No <code>backup-dataprotection/</code> directory - this export did not write one. <code>inventory.json</code> is not an index here either; the directories are the source of truth.</p>')
            } else {
                [void]$b.Append('<p class="bknote">' + (BkBadge 'info' 'none') + ' No <code>Microsoft.DataProtection/backupVaults</code> in the subscriptions in scope.</p>')
            }
        } else {
            [void]$b.Append('<p class="bknote">Inventory only. These vaults hold blob, disk and AKS backups - outside the Azure Files scope, but they are what "backup for everything in Azure" has to reconcile against.</p>')
            [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th>Vault</th><th class="w">Subscription</th><th class="w">Region</th><th class="w">Resource group</th><th>Datastores</th><th class="w">Soft delete</th><th class="w">Immutability</th><th class="w">Policies</th><th class="w">Backup instances</th></tr></thead><tbody>')
            foreach ($dv in $dpVaults) {
                $props = BkPath $dv.vault 'properties' $null
                $ds = @()
                foreach ($s in @(BkGet $props 'storageSettings' @())) {
                    $ds += ((BkStr (BkGet $s 'datastoreType' '?')) + ' / ' + (BkStr (BkGet $s 'type' '?')))
                }
                $dsd = BkStr (BkPath $props 'securitySettings.softDeleteSettings.state' '')
                $dRet = BkPath $props 'securitySettings.softDeleteSettings.retentionDurationInDays' $null
                $dim = BkStr (BkPath $props 'securitySettings.immutabilitySettings.state' '')
                $pnames = @()
                foreach ($p in @($dv.policies)) { $pnames += (BkStr (BkGet $p 'name' '')) }
                [void]$b.Append('<tr><td class="w"><b>' + (BkEnc ([string]$dv.name)) + '</b></td>')
                [void]$b.Append('<td class="w">' + (BkVal ([string]$dv.sub) '') + '</td>')
                [void]$b.Append('<td class="w">' + (BkVal ([string]$dv.location) '') + '</td>')
                [void]$b.Append('<td class="w">' + (BkVal ([string]$dv.rg) '') + '</td>')
                [void]$b.Append('<td>' + (BkVal ($ds -join '; ') '') + '</td>')
                $dsdTxt = $dsd
                if ($dsd -ne '' -and $null -ne $dRet) { $dsdTxt = $dsd + ' / ' + [string]$dRet + 'd' }
                [void]$b.Append('<td class="w">' + (BkVal $dsdTxt '') + '</td>')
                [void]$b.Append('<td class="w">' + (BkVal $dim '') + '</td>')
                [void]$b.Append('<td class="num">' + @($dv.policies).Count + '</td>')
                [void]$b.Append('<td class="num">' + @($dv.instances).Count + '</td></tr>')
                if (@($pnames).Count -gt 0) {
                    [void]$b.Append('<tr><td colspan="9" class="ev">policies: ' + (BkEnc ($pnames -join ', ')) + '</td></tr>')
                }
            }
            [void]$b.Append('</tbody></table></div>')
        }

        # ================================== PRECONDITIONS THE BACKUP PATH DEPENDS ON
        # These live in the storage tab's files but decide whether a backup job can run at all.
        [void]$b.Append('<h2>Storage-side preconditions for Azure Files backup</h2>')
        if (@($accounts.Keys).Count -eq 0) {
            [void]$b.Append('<p class="bknote">' + (BkBadge 'unk' 'not in export') + ' No <code>storage/</code> directory, so the preconditions below could not be read.</p>')
        } else {
            [void]$b.Append('<p class="bknote">A backup job fails on any of these before it ever reaches the vault. Read together with the failed jobs above.</p>')
            [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th>Storage account</th><th class="w">Region</th><th class="w">Vault in region</th><th>Shared key access</th><th>Network default action</th><th class="w">Bypass</th><th>Share soft delete</th><th class="w">Protected shares</th></tr></thead><tbody>')
            foreach ($an in @($accounts.Keys | Sort-Object)) {
                $ai = $accounts[$an]
                $ap = BkPath $ai.acct 'properties' $null
                $loc = ([string]$ai.location)
                $nProtHere = @($sorted | Where-Object { ([string]$_.acct).ToLower() -eq $an -and $_.protected }).Count
                # absent means allowed - saying "true" would be mis-citable
                $ska = ''
                if (BkHas $ap 'allowSharedKeyAccess') {
                    if (BkBool (BkGet $ap 'allowSharedKeyAccess' $false)) { $ska = (BkBadge 'ok' 'true') + ' <span class="bknote">required by Azure Files backup today</span>' }
                    else { $ska = (BkBadge 'bad' 'false') + ' <span class="bknote">Azure Files backup and restore fail outright while this is false</span>' }
                } else {
                    $ska = (BkBadge 'info' 'not set') + ' <span class="bknote">absent means allowed - the default</span>'
                }
                $da = BkStr (BkPath $ap 'networkAcls.defaultAction' '')
                $byp = BkStr (BkPath $ap 'networkAcls.bypass' '')
                $daHtml = BkNR ''
                if ($da -ne '') {
                    if ($da -eq 'Deny') {
                        if ($byp -match 'AzureServices') { $daHtml = (BkBadge 'warn' 'Deny') + ' <span class="bknote">firewalled, but trusted services are bypassed</span>' }
                        else { $daHtml = (BkBadge 'bad' 'Deny') + ' <span class="bknote">no AzureServices bypass - every backup job fails the way a firewall-blocked job does</span>' }
                    } else { $daHtml = BkBadge 'info' $da }
                }
                $sdrEnabled = BkPath $ai.fsvc 'properties.shareDeleteRetentionPolicy.enabled' $null
                $sdrDays = BkPath $ai.fsvc 'properties.shareDeleteRetentionPolicy.days' $null
                $sdrHtml = BkNR ''
                if ($null -ne $sdrEnabled) {
                    if (BkBool $sdrEnabled) {
                        $dd = 0
                        if ($null -ne $sdrDays) { try { $dd = [int]$sdrDays } catch { $dd = 0 } }
                        $ss = 'ok'
                        if ($dd -gt 0 -and $dd -lt 14) { $ss = 'warn' }
                        $sdrHtml = (BkBadge $ss ('enabled, ' + [string]$dd + ' days')) + ' <span class="bknote">a restore lands in the share; this is what survives the share being deleted</span>'
                    } else {
                        $sdrHtml = (BkBadge 'bad' 'disabled')
                    }
                }
                $vinr = BkNR ''
                if ($loc -ne '') {
                    if ($vaultRegions.ContainsKey($loc.ToLower())) { $vinr = BkBadge 'ok' 'yes' } else { $vinr = BkBadge 'bad' 'no' }
                }
                [void]$b.Append('<tr><td class="w"><b>' + (BkEnc ([string]$ai.name)) + '</b></td>')
                [void]$b.Append('<td class="w">' + (BkVal $loc '') + '</td>')
                [void]$b.Append('<td class="w">' + $vinr + '</td>')
                [void]$b.Append('<td>' + $ska + '</td>')
                [void]$b.Append('<td>' + $daHtml + '</td>')
                [void]$b.Append('<td class="w">' + (BkVal $byp '') + '</td>')
                [void]$b.Append('<td>' + $sdrHtml + '</td>')
                [void]$b.Append('<td class="num">' + $nProtHere + '</td></tr>')
            }
            [void]$b.Append('</tbody></table></div>')
        }

        # ================================================ EVIDENCE FOR THE RULES
        # For each backup rule: the exact field the assessor reads, and the value in THIS
        # export. No finding text and no recommendation - a reviewer can confirm or dispute
        # any finding from this table without opening the JSON.
        [void]$b.Append('<h2>Evidence behind the backup rules</h2>')
        [void]$b.Append('<p class="bknote">Values only. The Findings tab decides which of these is a finding and how severe it is.</p>')

        # aggregate what the rules read
        $allStoragePols = @()
        foreach ($v in $vaults) {
            foreach ($p in @($v.policies)) {
                if ((BkStr (BkPath $p 'properties.backupManagementType' '')) -eq 'AzureStorage') { $allStoragePols += @{ v = $v; p = $p } }
            }
        }
        $unhealthy = @()
        foreach ($v in $vaults) {
            foreach ($it in @($v.items)) {
                if ((BkStr (BkPath $it 'properties.workloadType' '')) -ne 'AzureFileShare') { continue }
                $st = BkStr (BkPath $it 'properties.protectionState' '')
                $lb = BkStr (BkPath $it 'properties.lastBackupStatus' '')
                if ($st -ne 'Protected' -or ($lb -ne 'Healthy' -and $lb -ne 'Completed')) {
                    $unhealthy += ((BkStr (BkPath $it 'properties.friendlyName' (BkGet $it 'name' ''))) + ' = ' + $st + ' / ' + $lb)
                }
            }
        }
        $nonFileItems = 0
        foreach ($v in $vaults) { foreach ($it in @($v.items)) { if ((BkStr (BkPath $it 'properties.workloadType' '')) -ne 'AzureFileShare') { $nonFileItems++ } } }
        $unprotRegions = @{}
        foreach ($r in $sorted) {
            if ($r.protected) { continue }
            $rl = ([string]$r.accLoc).ToLower()
            if ($rl -ne '') { $unprotRegions[$rl] = $true }
        }

        function BkJoinVaults {
            param($vaults, $fn)
            $out = @()
            foreach ($v in $vaults) { $out += ((BkEnc ([string]$v.name)) + ' = ' + (& $fn $v)) }
            if (@($out).Count -eq 0) { return (BkNR 'no vault in this export') }
            return ($out -join '<br>')
        }

        $ev = @()
        $ev += @{ id = 'BKP-01'; path = 'backup/share-coverage.json protected'; val = ([string]$nProt + ' of ' + [string]$nShares + ' share(s) protected; ' + [string]$nUnprot + ' not protected (' + (BkEnc (BkBytes $unprotBytes)) + ')') }
        $nFileItems = 0
        foreach ($v in $vaults) { foreach ($it in @($v.items)) { if ((BkStr (BkPath $it 'properties.workloadType' '')) -eq 'AzureFileShare') { $nFileItems++ } } }
        $ev += @{ id = 'BKP-02'; path = 'protecteditems.json properties.protectionState, .lastBackupStatus'; val = (& {
            if ($nFileItems -eq 0) { return (BkNR 'no Azure Files protected item in this export - nothing to be healthy or unhealthy') }
            if (@($unhealthy).Count -eq 0) { return ([string]$nFileItems + ' Azure Files item(s), all Protected with a good last backup') }
            return (BkEnc ($unhealthy -join '; '))
        }) }
        $ev += @{ id = 'BKP-03'; path = 'jobs.json properties.status = Failed'; val = ([string]$failedJobs + ' failed of ' + [string]$totalJobs + ' job(s) in the ' + [string]$lookback + '-day window') }
        $ev += @{ id = 'BKP-04'; path = 'policies.json properties.vaultRetentionPolicy (AzureStorage)'; val = (& {
            if (@($allStoragePols).Count -eq 0) { return (BkNR 'no AzureStorage policy in this export') }
            $o = @()
            foreach ($x in $allStoragePols) {
                $has = ($null -ne (BkPath $x.p 'properties.vaultRetentionPolicy' $null))
                $o += ((BkEnc (BkStr (BkGet $x.p 'name' ''))) + ' = ' + (& { if ($has) { 'present (snapshot + vault-standard)' } else { 'absent (snapshot-only)' } }))
            }
            return ($o -join '<br>')
        }) }
        $ev += @{ id = 'BKP-05'; path = 'policies.json properties.retentionPolicy.dailySchedule/weeklySchedule/monthlySchedule/yearlySchedule'; val = (& {
            if (@($allStoragePols).Count -eq 0) { return (BkNR 'no AzureStorage policy in this export') }
            $o = @()
            foreach ($x in $allStoragePols) {
                $dc = BkPath $x.p 'properties.retentionPolicy.dailySchedule.retentionDuration.count' $null
                $wk = ($null -ne (BkPath $x.p 'properties.retentionPolicy.weeklySchedule' $null))
                $mo = ($null -ne (BkPath $x.p 'properties.retentionPolicy.monthlySchedule' $null))
                $yr = ($null -ne (BkPath $x.p 'properties.retentionPolicy.yearlySchedule' $null))
                $o += ((BkEnc (BkStr (BkGet $x.p 'name' ''))) + ' = daily ' + (& { if ($null -eq $dc) { 'not set' } else { [string]$dc } }) +
                       ', weekly ' + (& { if ($wk) { 'yes' } else { 'no' } }) + ', monthly ' + (& { if ($mo) { 'yes' } else { 'no' } }) + ', yearly ' + (& { if ($yr) { 'yes' } else { 'no' } }))
            }
            return ($o -join '<br>')
        }) }
        $ev += @{ id = 'BKP-06'; path = 'securitySettings.softDeleteSettings.softDeleteState | vaultconfig.properties.softDeleteFeatureState'; val = (BkJoinVaults $vaults {
            param($v)
            $g = BkGuards $v $subLocks
            if ($g.sdVal -eq '') { return (BkNR 'not reported') }
            $x = (BkEnc $g.sdVal)
            if ($null -ne $g.sdDays) { $x += ', ' + (BkEnc $g.sdDays) + 'd' }
            if ($null -ne $g.editable) { $x += ', editable ' + (BkEnc $g.editable) }
            return $x }) }
        $ev += @{ id = 'BKP-07'; path = 'securitySettings.immutabilitySettings.state'; val = (BkJoinVaults $vaults {
            param($v)
            $g = BkGuards $v $subLocks
            if ($g.imVal -eq '') { return (BkNR 'not reported by this export (securitySettings absent)') }
            return (BkEnc $g.imVal) }) }
        $ev += @{ id = 'BKP-08'; path = 'securitySettings.multiUserAuthorization + resourceguardproxies.json + roleassignments.json'; val = (BkJoinVaults $vaults {
            param($v)
            $g = BkGuards $v $subLocks
            $hiRoles2 = @('Owner', 'Contributor', 'User Access Administrator', 'Backup Contributor', 'Backup Operator', 'Backup Trusted Operator', 'Role Based Access Control Administrator')
            $n = @($v.roles | Where-Object { $hiRoles2 -contains (BkStr (BkGet $_ 'roleName' '')) }).Count
            $mu = $g.muVal
            if ($mu -eq '') { $mu = 'setting not reported' }
            return ((BkEnc $mu) + ', ' + $g.guardCount + ' Resource Guard proxy(ies), ' + $n + ' privileged assignment(s) at or above the vault') }) }
        $ev += @{ id = 'BKP-09'; path = 'redundancySettings.standardTierStorageRedundancy | storageconfig.storageModelType, .storageTypeState'; val = (BkJoinVaults $vaults {
            param($v)
            $r = BkRedundancy $v
            if ($r.mode -eq '') { return (BkNR 'not reported') }
            return ((BkEnc $r.mode) + ', storageTypeState ' + (& { if ($r.typeState -eq '') { 'not reported' } else { (BkEnc $r.typeState) } })) }) }
        $ev += @{ id = 'BKP-10'; path = 'redundancySettings.crossRegionRestore | storageconfig.crossRegionRestoreFlag'; val = (BkJoinVaults $vaults {
            param($v)
            $r = BkRedundancy $v
            if ($r.crr -eq '') { return (BkNR 'not reported') }
            return ((BkEnc $r.crr) + ' (source ' + (BkEnc $r.crrSrc) + ')') }) }
        $ev += @{ id = 'BKP-11'; path = 'monitoringSettings.azureMonitorAlertSettings.alertsForAllJobFailures'; val = (BkJoinVaults $vaults {
            param($v)
            $m = BkPath $v.vault 'properties.monitoringSettings' $null
            if ($null -eq $m) { return (BkNR 'monitoringSettings block absent - unknown, not Disabled') }
            $x = BkStr (BkPath $m 'azureMonitorAlertSettings.alertsForAllJobFailures' '')
            if ($x -eq '') { return (BkNR 'not reported') }
            return (BkEnc $x) }) }
        $ev += @{ id = 'BKP-12'; path = 'diagnostics.json (Microsoft.Insights/diagnosticSettings on the vault)'; val = (BkJoinVaults $vaults {
            param($v)
            if (@($v.diags).Count -gt 0) { return (@($v.diags).Count.ToString() + ' setting(s)') }
            if ([string]$v.stDiags -eq 'missing') { return (BkNR 'diagnostics.json not written') }
            return '0 diagnostic settings' }) }
        $ev += @{ id = 'BKP-13'; path = 'policies.json properties.schedulePolicy.scheduleRunFrequency (AzureStorage)'; val = (& {
            if (@($allStoragePols).Count -eq 0) { return (BkNR 'no AzureStorage policy in this export') }
            $o = @()
            foreach ($x in $allStoragePols) {
                $f = BkStr (BkPath $x.p 'properties.schedulePolicy.scheduleRunFrequency' '')
                $iv = BkStr (BkPath $x.p 'properties.schedulePolicy.hourlySchedule.interval' '')
                $t = $f
                if ($iv -ne '') { $t = $f + ' every ' + $iv + 'h' }
                if ($t -eq '') { $t = 'not reported' }
                $o += ((BkEnc (BkStr (BkGet $x.p 'name' ''))) + ' = ' + (BkEnc $t))
            }
            return ($o -join '<br>')
        }) }
        $ev += @{ id = 'BKP-14'; path = 'account.json location of unprotected shares vs vault.json location'; val = (& {
            $ur = @($unprotRegions.Keys | Sort-Object)
            $vr = @($vaultRegions.Keys | Sort-Object)
            $t = 'unprotected shares in: ' + (& { if (@($ur).Count -eq 0) { 'none' } else { (BkEnc ($ur -join ', ')) } })
            $t += '<br>vault regions: ' + (& { if (@($vr).Count -eq 0) { 'none' } else { (BkEnc ($vr -join ', ')) } })
            $gaps = @()
            foreach ($r in $ur) { if (-not $vaultRegions.ContainsKey($r)) { $gaps += $r } }
            $t += '<br>regions with unprotected shares and no vault: ' + (& { if (@($gaps).Count -eq 0) { 'none' } else { (BkEnc ($gaps -join ', ')) } })
            return $t
        }) }
        $ev += @{ id = 'BKP-15'; path = 'protecteditems.json properties.isScheduledForDeferredDelete, .deferredDeleteTimeRemaining'; val = (& {
            if (@($deferred).Count -eq 0) { return 'no item is in the soft-deleted state' }
            $o = @()
            foreach ($x in $deferred) {
                $o += ((BkEnc (BkStr (BkPath $x.it 'properties.friendlyName' (BkGet $x.it 'name' '')))) + ' in ' + (BkEnc ([string]$x.v.name)) +
                       ' = purges in ' + (BkEnc (BkSpan (BkStr (BkPath $x.it 'properties.deferredDeleteTimeRemaining' '')))))
            }
            return ($o -join '<br>')
        }) }
        $ev += @{ id = 'BKP-16'; path = 'locks.json properties.level (CanNotDelete | ReadOnly) + inherited locks/<Subscription>.json'; val = (BkJoinVaults $vaults {
            param($v)
            $g = BkGuards $v $subLocks
            if (@($g.lockNames).Count -eq 0) {
                if ([string]$v.stLocks -eq 'missing') { return (BkNR 'locks.json not written') }
                return 'no lock'
            }
            return (BkEnc ((@($g.lockNames)) -join '; ')) }) }
        $ev += @{ id = 'BKP-17'; path = 'backup-dataprotection/<dir>/vault.json'; val = (& {
            if (@($dpVaults).Count -eq 0) { return 'no Data Protection vault directory in this export' }
            $o = @()
            foreach ($dv in $dpVaults) { $o += ((BkEnc ([string]$dv.name)) + ' (' + (BkEnc ([string]$dv.location)) + ')') }
            return ($o -join ', ')
        }) }
        $ev += @{ id = 'BKP-18'; path = 'storage/<account>/account.json properties.allowSharedKeyAccess (accounts with protected shares)'; val = (& {
            $o = @()
            foreach ($an in @($accounts.Keys | Sort-Object)) {
                $n = @($sorted | Where-Object { ([string]$_.acct).ToLower() -eq $an -and $_.protected }).Count
                if ($n -eq 0) { continue }
                $ap = BkPath $accounts[$an].acct 'properties' $null
                $t = 'not set (defaults to allowed)'
                if (BkHas $ap 'allowSharedKeyAccess') { $t = BkStr (BkGet $ap 'allowSharedKeyAccess' '') }
                $o += ((BkEnc ([string]$accounts[$an].name)) + ' = ' + (BkEnc $t))
            }
            if (@($o).Count -eq 0) { return 'no storage account in this export has a protected share' }
            return ($o -join '<br>')
        }) }
        $ev += @{ id = 'BKP-19'; path = 'protecteditems.json properties.workloadType not AzureFileShare'; val = ([string]$nonFileItems + ' non-file protected item(s) across ' + [string]@($vaults).Count + ' vault(s)') }
        $ev += @{ id = 'NET-09'; path = 'vault.json properties.privateEndpointStateForBackup'; val = (BkJoinVaults $vaults {
            param($v)
            return ((BkVal (BkPath $v.vault 'properties.privateEndpointStateForBackup' '') '') + ' - a vault private endpoint does not apply to Azure Files backup, which is Azure-internal') }) }
        $ev += @{ id = 'SEC-04'; path = 'storage/<account>/account.json properties.allowSharedKeyAccess (all accounts)'; val = (& {
            $o = @()
            foreach ($an in @($accounts.Keys | Sort-Object)) {
                $ap = BkPath $accounts[$an].acct 'properties' $null
                $t = 'not set (defaults to allowed)'
                if (BkHas $ap 'allowSharedKeyAccess') { $t = BkStr (BkGet $ap 'allowSharedKeyAccess' '') }
                $o += ((BkEnc ([string]$accounts[$an].name)) + ' = ' + (BkEnc $t))
            }
            if (@($o).Count -eq 0) { return (BkNR 'no storage account in this export') }
            return ($o -join '<br>')
        }) }
        $ev += @{ id = 'DATA-02'; path = 'storage/<account>/fileservice.json properties.shareDeleteRetentionPolicy.enabled / .days'; val = (& {
            $o = @()
            foreach ($an in @($accounts.Keys | Sort-Object)) {
                $en = BkPath $accounts[$an].fsvc 'properties.shareDeleteRetentionPolicy.enabled' $null
                $dy = BkPath $accounts[$an].fsvc 'properties.shareDeleteRetentionPolicy.days' $null
                $t = 'not reported'
                if ($null -ne $en) {
                    if (BkBool $en) { $t = 'enabled, ' + (& { if ($null -eq $dy) { 'days not reported' } else { [string]$dy + ' days' } }) } else { $t = 'disabled' }
                }
                $o += ((BkEnc ([string]$accounts[$an].name)) + ' = ' + (BkEnc $t))
            }
            if (@($o).Count -eq 0) { return (BkNR 'no storage account in this export') }
            return ($o -join '<br>')
        }) }
        $ev += @{ id = 'DATA-04'; path = 'storage/<account>/shares.json snapshots[] per share (200-per-share limit)'; val = (& {
            $mx = 0; $who = ''
            foreach ($r in $sorted) { if ([int]$r.snaps -gt $mx) { $mx = [int]$r.snaps; $who = [string]$r.acct + '/' + [string]$r.share } }
            if ($mx -eq 0) { return 'no share snapshot was enumerated in this export' }
            return ('highest snapshot count: ' + $mx + ' on ' + (BkEnc $who) + ' (limit 200, shared with Azure Backup)')
        }) }
        $ev += @{ id = 'SRV-02'; path = 'servers/<server>/programs.json + serverendpoints (read on the server tab, not here)'; val = (& {
            $sdir = Join-Path $root 'servers'
            if (-not (Test-Path -LiteralPath $sdir)) { return (BkNR 'no servers/ directory in this export') }
            $n = @(Get-ChildItem -LiteralPath $sdir -Directory -ErrorAction SilentlyContinue).Count
            return ($n.ToString() + ' server export(s) present; the installed-programs evidence for backup or AV agents on tiered endpoints lives there')
        }) }

        [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th class="w">Rule</th><th>Field the assessor reads</th><th>Value in this export</th></tr></thead><tbody>')
        foreach ($e in $ev) {
            [void]$b.Append('<tr><td class="id w">' + (BkEnc $e.id) + '</td><td class="ev">' + (BkEnc $e.path) + '</td><td>' + $e.val + '</td></tr>')
        }
        [void]$b.Append('</tbody></table></div>')

        # ---- what the export could not answer at all
        if (@($errs).Count -gt 0) {
            [void]$b.Append('<h3>Calls that failed during the export</h3>')
            [void]$b.Append('<p class="bknote">Any "none" above that sits behind one of these is "not captured", not a clean result.</p>')
            [void]$b.Append('<div class="bkwrap"><table class="tight"><thead><tr><th class="w">Call</th><th class="w">When</th><th>Detail</th></tr></thead><tbody>')
            foreach ($e in @($errs)) {
                $dt = BkStr (BkGet $e 'detail' '')
                if ($dt.Length -gt 300) { $dt = $dt.Substring(0, 300) + ' ...' }
                [void]$b.Append('<tr><td class="ev">' + (BkVal (BkGet $e 'where' '') '') + '</td><td class="w">' + (BkVal (BkShortDate (BkGet $e 'at' '')) '') + '</td><td class="ev">' + (BkEnc $dt) + '</td></tr>')
            }
            [void]$b.Append('</tbody></table></div>')
        }

        [void]$b.Append('</section>')
    } catch {
        # A subject tab must never cost the reader the report. State what happened, in place.
        $why = ''
        try { $why = [System.Net.WebUtility]::HtmlEncode([string]$_.Exception.Message) } catch { $why = 'unknown error' }
        $b = New-Object System.Text.StringBuilder
        [void]$b.Append('<section class="tab" id="tab-backup"><h2>Azure Backup</h2>')
        [void]$b.Append('<div class="card"><p>This section could not be rendered from the export: <code>' + $why + '</code></p>')
        [void]$b.Append('<p>The rest of the report is unaffected, and the raw data is in <code>backup/</code> in the export itself.</p></div></section>')
    }

    [void]$Sb.Append($b.ToString())
}
