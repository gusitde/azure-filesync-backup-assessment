function Add-AfsTabStorage {
    <#
      The Storage tab: what storage accounts and Azure file shares actually exist, and how they
      are configured. It renders evidence only - every value is the raw export field, with the
      rule ID it feeds carried as data-rule and the field path in the tooltip. The Findings tab
      owns the verdict; this tab is what a reviewer checks the verdict against.

      It must never throw and never leave a blank panel: an absent file, a null, a zero-byte
      file and an empty array are four different facts, and each says which one it is.
    #>
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
        [string]$ExportRoot
    )

    # ---------------------------------------------------------------------------
    # helpers - defined first, because a nested function binds when its statement runs
    # ---------------------------------------------------------------------------
    function SEnc { param($v) if ($null -eq $v) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$v) }

    function SHas { param($o, [string]$n)
        if ($null -eq $o) { return $false }
        try { return (@($o.PSObject.Properties.Name) -contains $n) } catch { return $false }
    }

    function SGet { param($o, [string]$n, $d = $null)
        if ($null -eq $o) { return $d }
        try {
            $pr = $o.PSObject.Properties[$n]
            if ($null -eq $pr) { return $d }
            $v = $pr.Value
            if ($null -eq $v) { return $d }
            return $v
        } catch { return $d }
    }

    # Save-Json unrolls a one-element array, so a single lock arrives as a bare object.
    function SArr { param($x) if ($null -eq $x) { return @() } return @($x) }

    # Empty lists are written as ZERO-BYTE files, and metrics.json is sometimes the literal
    # null. ConvertFrom-Json throws on both, so all three collapse to $null here.
    function SJson { param([string]$Path)
        if (-not $Path) { return $null }
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $raw = $null
        try { $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue } catch { return $null }
        if ($null -eq $raw) { return $null }
        $raw = [string]$raw
        if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 65279) { $raw = $raw.Substring(1) }
        $raw = $raw.Trim()
        if ($raw -eq '' -or $raw -eq 'null') { return $null }
        try { return ($raw | ConvertFrom-Json) } catch { return $null }
    }

    function SNum { param($v, [int]$dp = 0)
        if ($null -eq $v) { return '' }
        try { return ([double]$v).ToString('N' + $dp, [System.Globalization.CultureInfo]::InvariantCulture) } catch { return [string]$v }
    }

    function SBool { param($v)
        if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
        return [string]$v
    }

    function STrunc { param([string]$s, [int]$n)
        if ($null -eq $s) { return '' }
        if ($s.Length -le $n) { return $s }
        return ($s.Substring(0, [Math]::Max(1, $n - 2)) + '..')
    }

    function SLeaf { param([string]$id)
        if (-not $id) { return '' }
        $parts = $id -split '/'
        return $parts[$parts.Length - 1]
    }

    # One evidence cell: the literal value, a state colour, the rule it feeds, the field path.
    function SVal { param([string]$Text, [string]$State = 'na', [string]$Rule = '', [string]$Tip = '')
        $out = '<span class="v ' + $State + '"'
        if ($Rule) { $out += ' data-rule="' + (SEnc $Rule) + '"' }
        if ($Tip) { $out += ' title="' + (SEnc $Tip) + '"' }
        return ($out + '>' + (SEnc $Text) + '</span>')
    }

    function SRow { param([string]$K, [string]$Vhtml, [string]$Note = '')
        $out = '<div class="k">' + (SEnc $K) + '</div><div>' + $Vhtml
        if ($Note) { $out += ' <span class="sub">' + (SEnc $Note) + '</span>' }
        return ($out + '</div>')
    }

    function SvgBox { param([int]$x, [int]$y, [int]$w, [int]$h, [string]$state, [string]$title, $lines, [string]$rule = '', [int]$rx = 8)
        $stroke = 'var(--line)'; $fill = 'var(--surface-3)'; $dash = ''
        switch ($state) {
            'good' { $stroke = 'var(--good)'; $fill = 'var(--good-soft)' }
            'warn' { $stroke = 'var(--warn)'; $fill = 'var(--warn-soft)' }
            'open' { $stroke = 'var(--crit)'; $fill = 'var(--crit-soft)' }
            'info' { $stroke = 'var(--info)'; $fill = 'var(--info-soft)' }
            default { $dash = ' stroke-dasharray="4 2"' }
        }
        $out = '<rect x="{0}" y="{1}" width="{2}" height="{3}" rx="{4}" fill="{5}" stroke="{6}" stroke-width="1.5"{7}/>' -f $x, $y, $w, $h, $rx, $fill, $stroke, $dash
        if ($title) {
            $out += '<text x="{0}" y="{1}" font-size="12" font-weight="600" fill="currentColor">{2}</text>' -f ($x + 10), ($y + 17), (SEnc $title)
        }
        if ($rule) {
            $out += '<text x="{0}" y="{1}" font-size="10" text-anchor="end" fill="var(--muted)" font-family="Consolas,monospace">{2}</text>' -f ($x + $w - 8), ($y + 17), (SEnc $rule)
        }
        $ly = $y + 32
        foreach ($l in (SArr $lines)) {
            $out += '<text x="{0}" y="{1}" font-size="11" fill="currentColor">{2}</text>' -f ($x + 10), $ly, (SEnc ([string]$l))
            $ly += 12
        }
        return $out
    }

    # metrics.json: {SetName:{value:[{name:{value},unit,timeseries:[{metadatavalues,data}]}]}}
    # Real data points can carry no value key at all - those buckets are skipped, never zeroed.
    function SSeries { param($set)
        $out = @()
        if ($null -eq $set) { return $out }
        foreach ($mv in (SArr (SGet $set 'value'))) {
            $mname = [string](SGet (SGet $mv 'name') 'value' '')
            $unit = [string](SGet $mv 'unit' '')
            foreach ($ts in (SArr (SGet $mv 'timeseries'))) {
                $dim = ''
                foreach ($md in (SArr (SGet $ts 'metadatavalues'))) {
                    if ($dim -ne '') { $dim += ', ' }
                    $dim += [string](SGet $md 'value' '')
                }
                $pts = 0; $withData = 0; $sum = 0.0; $hasTotal = $false
                $lastAvg = $null; $minMin = $null; $avgSum = 0.0; $avgN = 0
                foreach ($d in (SArr (SGet $ts 'data'))) {
                    $pts++; $any = $false
                    if (SHas $d 'total') {
                        $t = SGet $d 'total'
                        if ($null -ne $t) { $sum += [double]$t; $hasTotal = $true; $any = $true }
                    }
                    if (SHas $d 'average') {
                        $av = SGet $d 'average'
                        if ($null -ne $av) { $avgSum += [double]$av; $avgN++; $lastAvg = [double]$av; $any = $true }
                    }
                    if (SHas $d 'minimum') {
                        $mi = SGet $d 'minimum'
                        if ($null -ne $mi) { if ($null -eq $minMin -or [double]$mi -lt $minMin) { $minMin = [double]$mi }; $any = $true }
                    }
                    if ($any) { $withData++ }
                }
                $out += @{
                    Metric = $mname; Dim = $dim; Unit = $unit; Points = $pts; WithData = $withData
                    Total = $sum; HasTotal = $hasTotal; LastAvg = $lastAvg; MinMin = $minMin
                    Avg = $(if ($avgN -gt 0) { $avgSum / $avgN } else { $null })
                }
            }
        }
        return $out
    }

    # ---------------------------------------------------------------------------
    # open the section - every exit path below closes it
    # ---------------------------------------------------------------------------
    [void]$Sb.Append('<section class="tab" id="tab-storage">')
    [void]$Sb.Append(@'
<style>
#tab-storage .v{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px;padding:1px 6px;border-radius:3px;white-space:nowrap;display:inline-block}
#tab-storage .v.ok{background:var(--good-soft);color:var(--good)}
#tab-storage .v.warn{background:var(--warn-soft);color:var(--warn)}
#tab-storage .v.bad{background:var(--crit-soft);color:var(--crit)}
#tab-storage .v.inf{background:var(--info-soft);color:var(--info)}
#tab-storage .v.unset{background:transparent;color:var(--muted);border:1px dashed var(--line)}
#tab-storage .v.na{background:transparent;color:var(--faint);padding-left:0}
#tab-storage .chip{display:inline-block;font-family:"IBM Plex Mono",Consolas,monospace;font-size:11px;color:var(--muted);background:var(--surface-3);border-radius:10px;padding:1px 8px;margin-left:6px}
#tab-storage .chip.afs{background:var(--info-soft);color:var(--info)}
#tab-storage .sbar{height:8px;background:var(--surface-3);border-radius:4px;overflow:hidden;min-width:96px;margin-top:4px}
#tab-storage .sbar i{display:block;height:100%;background:var(--good)}
#tab-storage .sbar.w i{background:var(--warn)}
#tab-storage .sbar.c i{background:var(--crit)}
#tab-storage .sub{color:var(--muted);font-size:12px}
#tab-storage .note{color:var(--muted);font-size:12px;margin:2px 0 10px}
#tab-storage .scroll{overflow-x:auto}
#tab-storage .diag{overflow-x:auto;margin:12px 0 2px}
#tab-storage .diag svg{width:100%;height:auto;min-width:720px;display:block}
#tab-storage .acct{border-left:3px solid var(--accent);padding-left:12px;margin:26px 0 8px}
#tab-storage .acct h2{margin:0 0 2px}
#tab-storage .cols{display:grid;grid-template-columns:1fr 1fr;gap:0 18px}
#tab-storage h4{margin:14px 0 4px}
#tab-storage h5{font-size:12px;margin:12px 0 4px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
#tab-storage table.tight th,#tab-storage table.tight td{padding:6px 9px}
@media print{#tab-storage .diag svg{min-width:0}
 #tab-storage .v,#tab-storage .chip,#tab-storage .sbar i{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
@media(max-width:900px){#tab-storage .cols{grid-template-columns:1fr}}
</style>
'@)
    [void]$Sb.Append('<h2>Storage accounts and file shares</h2>')

    # ---- state 4: there is no export to read ----------------------------------
    if (-not $ExportRoot -or -not (Test-Path -LiteralPath $ExportRoot)) {
        [void]$Sb.Append('<div class="card"><p><b>No export directory was supplied.</b> This tab reads the raw export, not the findings file. Re-run the renderer with <code>-ExportRoot</code> pointing at the export folder.</p></div></section>')
        return
    }
    $manifest = SJson (Join-Path $ExportRoot 'manifest.json')
    if ($null -eq $manifest) {
        [void]$Sb.Append('<div class="card"><p><b>This is not an Azure File Sync export.</b> Expected <code>manifest.json</code> with schema <code>luca.afs-export/1</code> at the root of <code>' + (SEnc $ExportRoot) + '</code>.</p>')
        [void]$Sb.Append('<p>Produce one with <code>.\Export-AzFileSyncEnvironment.ps1 -OutputPath .\afs-export</code>.</p></div></section>')
        return
    }

    # ---------------------------------------------------------------------------
    # the cross-cutting files, read once
    # ---------------------------------------------------------------------------
    $inventory  = SJson (Join-Path $ExportRoot 'inventory.json')
    $allErrors  = @(SArr (SJson (Join-Path $ExportRoot 'errors.json')))
    $coverage   = @(SArr (SJson (Join-Path $ExportRoot (Join-Path 'backup' 'share-coverage.json'))))
    $alerts     = @(SArr (SJson (Join-Path $ExportRoot (Join-Path 'monitor' 'metricalerts.json'))))
    $peWrap     = @(SArr (SJson (Join-Path $ExportRoot (Join-Path 'network' 'privateendpoints.json'))))
    $dnsWrap    = @(SArr (SJson (Join-Path $ExportRoot (Join-Path 'network' 'privatednszones.json'))))
    $storageDir = Join-Path $ExportRoot 'storage'

    $mCounts        = SGet $manifest 'counts'
    $mAccounts      = SGet $mCounts 'storageAccounts'
    $mShares        = SGet $mCounts 'fileShares'
    $metricsSkipped = SGet $manifest 'metricsSkipped' $false
    $lookback       = SGet $manifest 'metricsLookbackDays'
    $exportedAt     = [string](SGet $manifest 'exportedAtUtc' '')
    $exportedBy     = [string](SGet $manifest 'exportedBy' '')
    $mFiles         = @(SArr (SGet $manifest 'files'))

    # subscription-level Defender pricing, keyed by subscription id
    $defPricing = @{}
    $defenderDir = Join-Path $ExportRoot 'defender'
    if (Test-Path -LiteralPath $defenderDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $defenderDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -notlike '*StorageAccounts*') { continue }
            $o = SJson $f.FullName
            if ($null -eq $o) { continue }
            $oid = [string](SGet $o 'id' '')
            if ($oid -match '/subscriptions/([^/]+)/') { $defPricing[$Matches[1].ToLower()] = $o }
        }
    }

    # subscription-level locks - their ids come back with lowercased path segments
    $subLocks = @()
    $locksDir = Join-Path $ExportRoot 'locks'
    if (Test-Path -LiteralPath $locksDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $locksDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $subLocks += @(SArr (SJson $f.FullName))
        }
    }

    # cloud endpoints: the canonical account+share -> sync group join
    $syncMap = @{}
    $syncDir = Join-Path $ExportRoot 'storagesync'
    if (Test-Path -LiteralPath $syncDir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $syncDir -Directory -ErrorAction SilentlyContinue)) {
            foreach ($c in (SArr (SJson (Join-Path $d.FullName 'cloudendpoints.json')))) {
                $cp = SGet $c 'properties'
                $said = [string](SGet $cp 'storageAccountResourceId' '')
                $cshn = [string](SGet $cp 'azureFileShareName' '')
                if (-not $said -or -not $cshn) { continue }
                $cid = [string](SGet $c 'id' '')
                $sg = ''; $svc = ''
                if ($cid -match '/syncGroups/([^/]+)/') { $sg = $Matches[1] }
                if ($cid -match '/storageSyncServices/([^/]+)/') { $svc = $Matches[1] }
                $syncMap[($said.ToLower() + '|' + $cshn.ToLower())] = @{ Service = $svc; SyncGroup = $sg; Endpoint = [string](SGet $c 'name' '') }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # pass 1 - read every account folder into a plain hashtable
    # ---------------------------------------------------------------------------
    $accounts = @()
    $unreadable = @()
    if (Test-Path -LiteralPath $storageDir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $storageDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $acct = SJson (Join-Path $d.FullName 'account.json')
            if ($null -eq $acct -or -not (SHas $acct 'id')) { $unreadable += $d.Name; continue }

            $p = SGet $acct 'properties'
            $id = [string](SGet $acct 'id' '')
            $name = [string](SGet $acct 'name' (SLeaf $id))
            $idl = $id.ToLower()
            $subId = ''
            if ($id -match '/subscriptions/([^/]+)/') { $subId = $Matches[1] }
            $rg = ''
            if ($id -match '/resource[Gg]roups/([^/]+)/') { $rg = $Matches[1] }

            # the inventory row carries the File Sync linkage flag
            $inv = $null
            foreach ($ia in (SArr (SGet $inventory 'storageAccounts'))) {
                $iaId = [string](SGet $ia 'id' '')
                if ($iaId -and $iaId.ToLower() -eq $idl) { $inv = $ia; break }
            }
            $syncEndpoints = @()
            foreach ($se in (SArr (SGet $inv 'syncEndpoints'))) { $syncEndpoints += [string]$se }

            $fs = SJson (Join-Path $d.FullName 'fileservice.json')
            $fsp = SGet $fs 'properties'
            $sdrp = SGet $fsp 'shareDeleteRetentionPolicy'
            $smb = SGet (SGet $fsp 'protocolSettings') 'smb'

            $shJson = SJson (Join-Path $d.FullName 'shares.json')
            $rawSh = @(SArr (SGet $shJson 'shares'))
            $rawSnap = @(SArr (SGet $shJson 'snapshots'))
            $rawSoft = @(SArr (SGet $shJson 'softDeleted'))

            # snapshot entries repeat the parent share's name AND id - count by name
            $snapCount = @{}
            foreach ($sn in $rawSnap) {
                $k = ([string](SGet $sn 'name' '')).ToLower()
                if (-not $k) { continue }
                if ($snapCount.ContainsKey($k)) { $snapCount[$k] = $snapCount[$k] + 1 } else { $snapCount[$k] = 1 }
            }

            $shares = @()
            foreach ($sh in $rawSh) {
                $sp = SGet $sh 'properties'
                $shn = [string](SGet $sh 'name' '')
                $q = SGet $sp 'shareQuota'
                $hasU = SHas $sp 'shareUsageBytes'
                $u = SGet $sp 'shareUsageBytes'
                $fill = $null
                if ($hasU -and $null -ne $u -and $null -ne $q -and [double]$q -gt 0) {
                    $fill = ([double]$u / ([double]$q * 1073741824)) * 100
                }
                $cov = $null
                foreach ($cvr in $coverage) {
                    if (([string](SGet $cvr 'storageAccount' '')).ToLower() -eq $name.ToLower() -and
                        ([string](SGet $cvr 'share' '')).ToLower() -eq $shn.ToLower()) { $cov = $cvr; break }
                }
                $sk = $idl + '|' + $shn.ToLower()
                $sync = $null
                if ($syncMap.ContainsKey($sk)) { $sync = $syncMap[$sk] }
                $meta = @()
                $mdo = SGet $sp 'metadata'
                if ($null -ne $mdo) {
                    foreach ($mp in @($mdo.PSObject.Properties)) { $meta += ($mp.Name + '=' + [string]$mp.Value) }
                }
                $shares += @{
                    Name = $shn; Quota = $q; HasUsage = $hasU; Usage = $u; Fill = $fill
                    Tier = [string](SGet $sp 'accessTier' ''); TierChanged = [string](SGet $sp 'accessTierChangeTime' '')
                    Protocols = [string](SGet $sp 'enabledProtocols' ''); ProtocolsSet = (SHas $sp 'enabledProtocols')
                    Lease = ([string](SGet $sp 'leaseStatus' '') + ' / ' + [string](SGet $sp 'leaseState' ''))
                    LastMod = [string](SGet $sp 'lastModifiedTime' '')
                    SignedIds = @(SArr (SGet $sp 'signedIdentifiers')).Count
                    Meta = $meta
                    Snapshots = $(if ($snapCount.ContainsKey($shn.ToLower())) { $snapCount[$shn.ToLower()] } else { 0 })
                    Cov = $cov
                    Sync = $sync
                }
            }

            # locks: the per-account file plus the subscription sweep, matched case-insensitively
            $locks = @()
            $seenLock = @{}
            foreach ($lk in (SArr (SJson (Join-Path $d.FullName 'locks.json')))) {
                $lid = ([string](SGet $lk 'id' '')).ToLower()
                if (-not $seenLock.ContainsKey($lid)) { $seenLock[$lid] = $true; $locks += $lk }
            }
            foreach ($lk in $subLocks) {
                $lid = ([string](SGet $lk 'id' '')).ToLower()
                if ($lid -like ($idl + '/providers/microsoft.authorization/locks/*') -and -not $seenLock.ContainsKey($lid)) {
                    $seenLock[$lid] = $true; $locks += $lk
                }
            }

            # RBAC: atScope() returns every parent scope too - only account-scope rows are ours
            $raPath = Join-Path $d.FullName 'roleassignments.json'
            $raAll = @(SArr (SJson $raPath))
            $raHere = @(); $raUp = 0
            foreach ($ra in $raAll) {
                if (([string](SGet $ra 'scope' '')).ToLower() -eq $idl) { $raHere += $ra } else { $raUp++ }
            }

            $mPath = Join-Path $d.FullName 'metrics.json'
            $accounts += @{
                Dir = $d.Name; Id = $id; IdLower = $idl; Name = $name; Sub = $subId; Rg = $rg
                Acct = $acct; P = $p
                Location = [string](SGet $acct 'location' ''); Kind = [string](SGet $acct 'kind' '')
                Sku = [string](SGet (SGet $acct 'sku') 'name' ''); SkuTier = [string](SGet (SGet $acct 'sku') 'tier' '')
                Tags = (SGet $acct 'tags')
                IsAfs = [bool](SGet $inv 'referencedByAzureFileSync' $false)
                InvFound = ($null -ne $inv); SyncEndpoints = $syncEndpoints
                FsFound = ($null -ne $fs); Sdrp = $sdrp; Smb = $smb
                SharesFound = ($null -ne $shJson); Shares = $shares; Snaps = $rawSnap; Soft = $rawSoft
                Locks = $locks
                RaHere = $raHere; RaUp = $raUp; RaFileExists = (Test-Path -LiteralPath $raPath)
                Defender = (SJson (Join-Path $d.FullName 'defender.json'))
                DiagAcct = @(SArr (SJson (Join-Path $d.FullName 'diagnostics-account.json')))
                DiagFile = @(SArr (SJson (Join-Path $d.FullName 'diagnostics-fileservice.json')))
                Metrics = (SJson $mPath); MetricsExists = (Test-Path -LiteralPath $mPath)
            }
        }
    }

    # ---- state 1: no storage accounts ------------------------------------------
    if ($accounts.Count -eq 0) {
        [void]$Sb.Append('<div class="card"><p><b>No storage accounts in this export.</b></p>')
        [void]$Sb.Append('<p>That is two opposite conclusions, and the export says which one it is:</p><ul>')
        [void]$Sb.Append('<li>the subscriptions in scope genuinely have no <code>Microsoft.Storage</code> accounts, or</li>')
        [void]$Sb.Append('<li>the export could not enumerate them - the reader had no rights, or the call failed.</li></ul>')
        $enumErr = @($allErrors | Where-Object { ([string](SGet $_ 'where' '')) -like 'storageAccounts:*' })
        $subNames = @()
        foreach ($sn in (SArr (SGet $manifest 'subscriptions'))) {
            $subNames += ([string](SGet $sn 'name' '') + ' (' + [string](SGet $sn 'id' '') + ')')
        }
        [void]$Sb.Append('<div class="kv">')
        [void]$Sb.Append((SRow 'manifest counts.storageAccounts' (SVal ([string]$mAccounts) 'na' '' 'manifest.json .counts.storageAccounts')))
        [void]$Sb.Append((SRow 'account folders read' (SVal '0' 'na' '' 'storage/<Subscription>__<account>/account.json')))
        [void]$Sb.Append((SRow 'exported by' (SVal $exportedBy 'na' '' 'manifest.json .exportedBy - whose Reader rights were used')))
        [void]$Sb.Append((SRow 'subscriptions in scope' (SVal ($subNames -join '; ') 'na' '' 'manifest.json .subscriptions[]')))
        [void]$Sb.Append((SRow 'enumeration errors' (SVal ([string]$enumErr.Count) $(if ($enumErr.Count -gt 0) { 'bad' } else { 'ok' }) '' 'errors.json .where = storageAccounts:<subscriptionId>')))
        [void]$Sb.Append('</div>')
        if ($enumErr.Count -gt 0) {
            [void]$Sb.Append('<p class="note">The enumeration failed, so this is not evidence of an empty estate:</p><table class="tight"><thead><tr><th>where</th><th>detail</th></tr></thead><tbody>')
            foreach ($e in $enumErr) {
                [void]$Sb.Append('<tr><td class="ev">' + (SEnc (SGet $e 'where' '')) + '</td><td class="ev">' + (SEnc (STrunc ([string](SGet $e 'detail' '')) 400)) + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table>')
        } elseif ($null -ne $mAccounts -and [int]$mAccounts -gt 0) {
            [void]$Sb.Append('<p class="note">The manifest counted ' + (SEnc ([string]$mAccounts)) + ' storage accounts, but no folder carries a readable <code>account.json</code>. The export is incomplete - re-run it before drawing any conclusion.</p>')
        }
        if ($unreadable.Count -gt 0) {
            [void]$Sb.Append('<p class="note">Folders present but unreadable: <code>' + (SEnc ($unreadable -join ', ')) + '</code></p>')
        }
        [void]$Sb.Append('</div></section>')
        return
    }

    # ---------------------------------------------------------------------------
    # estate roll-up
    # ---------------------------------------------------------------------------
    $totShares = 0; $totQuota = 0.0; $totUsed = 0.0
    $protShares = 0; $afsShares = 0
    foreach ($a in $accounts) {
        foreach ($s in $a.Shares) {
            $totShares++
            if ($null -ne $s.Quota) { $totQuota += [double]$s.Quota }
            if ($s.HasUsage -and $null -ne $s.Usage) { $totUsed += ([double]$s.Usage / 1073741824) }
            if ($null -ne $s.Cov -and [bool](SGet $s.Cov 'protected' $false)) { $protShares++ }
            if ($null -ne $s.Sync -or ($null -ne $s.Cov -and [bool](SGet $s.Cov 'azureFileSync' $false))) { $afsShares++ }
        }
    }
    $fillPct = 0.0
    if ($totQuota -gt 0) { $fillPct = ($totUsed / $totQuota) * 100 }

    [void]$Sb.Append('<p class="note">Every value below is the raw field from the export. The small code beside a value is the rule it is evidence for; hover a value to read its field path. Severities live on the Findings tab - this tab is the proof.</p>')

    [void]$Sb.Append('<div class="tiles">')
    [void]$Sb.Append('<div class="tile"><div class="n">' + $accounts.Count + '</div><div class="l">storage accounts</div></div>')
    [void]$Sb.Append('<div class="tile"><div class="n">' + $totShares + '</div><div class="l">azure file shares (' + $afsShares + ' synced)</div></div>')
    if ($totShares -gt 0 -and $totQuota -gt 0) {
        $ft = 'info'
        if ($fillPct -ge 90) { $ft = 'high' } elseif ($fillPct -ge 80) { $ft = 'med' }
        [void]$Sb.Append('<div class="tile ' + $ft + '"><div class="n">' + (SNum $fillPct 1) + '%</div><div class="l">of ' + (SNum $totQuota 0) + ' GiB provisioned is used</div></div>')
    } else {
        [void]$Sb.Append('<div class="tile"><div class="n">-</div><div class="l">no provisioned capacity</div></div>')
    }
    $pt = 'info'
    if ($totShares -gt 0 -and $protShares -eq 0) { $pt = 'high' } elseif ($protShares -lt $totShares) { $pt = 'med' }
    [void]$Sb.Append('<div class="tile ' + $pt + '"><div class="n">' + $protShares + ' / ' + $totShares + '</div><div class="l">shares in a backup vault</div></div>')
    [void]$Sb.Append('</div>')

    # ---- state 2: accounts, but no file shares anywhere ------------------------
    if ($totShares -eq 0) {
        [void]$Sb.Append('<div class="card"><p><b>No Azure file shares on any account in scope.</b> The account posture below is still real and still worth reading.</p>')
        [void]$Sb.Append('<p>The load-bearing caveat: the assessor skips an account with no file shares entirely (<code>if ($a.shares.Count -eq 0) { continue }</code>). An empty Findings tab for these accounts means <b>not assessed</b>, not <b>passed</b>. That is the whole reason this tab renders when there is nothing to assess.</p></div>')
    }

    # ---------------------------------------------------------------------------
    # estate posture matrix - one row per account
    # ---------------------------------------------------------------------------
    [void]$Sb.Append('<h3>Posture at a glance</h3><div class="scroll"><table class="tight"><thead><tr>')
    foreach ($h in @('Account', 'Region', 'Redundancy', 'File Sync', 'HTTPS only', 'Min TLS', 'Public net', 'Firewall', 'Shared key', 'Directory', 'Share soft delete', 'Defender', 'Lock', 'Shares')) {
        [void]$Sb.Append('<th>' + $h + '</th>')
    }
    [void]$Sb.Append('</tr></thead><tbody>')
    foreach ($a in $accounts) {
        $p = $a.P
        [void]$Sb.Append('<tr><td class="res">' + (SEnc $a.Name) + '</td><td>' + (SEnc $a.Location) + '</td>')
        [void]$Sb.Append('<td>' + (SVal $a.Sku $(if ($a.Sku -like '*_LRS') { 'warn' } else { 'ok' }) 'DATA-01' ('sku.name = ' + $a.Sku)) + '</td>')
        [void]$Sb.Append('<td>' + $(if ($a.IsAfs) { (SVal 'yes' 'inf' 'AFS-13' 'inventory.json .referencedByAzureFileSync = true') } else { (SVal 'no' 'na' '' 'inventory.json .referencedByAzureFileSync = false') }) + '</td>')

        $https = SGet $p 'supportsHttpsTrafficOnly'
        [void]$Sb.Append('<td>' + $(if ($https -eq $true) { (SVal 'true' 'ok' 'SEC-01' 'properties.supportsHttpsTrafficOnly = true') } elseif ($https -eq $false) { (SVal 'false' 'bad' 'SEC-01' 'properties.supportsHttpsTrafficOnly = false') } else { (SVal 'not set' 'unset' 'SEC-01' 'properties.supportsHttpsTrafficOnly absent') }) + '</td>')

        $tlsSet = SHas $p 'minimumTlsVersion'
        $tls = [string](SGet $p 'minimumTlsVersion' 'TLS1_0')
        if (-not $tlsSet) { [void]$Sb.Append('<td>' + (SVal 'not set (TLS1_0)' 'unset' 'SEC-02' 'properties.minimumTlsVersion absent - the platform default is TLS1_0') + '</td>') }
        elseif ($tls -eq 'TLS1_2' -or $tls -eq 'TLS1_3') { [void]$Sb.Append('<td>' + (SVal $tls 'ok' 'SEC-02' ('properties.minimumTlsVersion = ' + $tls)) + '</td>') }
        else { [void]$Sb.Append('<td>' + (SVal $tls 'bad' 'SEC-02' ('properties.minimumTlsVersion = ' + $tls)) + '</td>') }

        $pnaSet = SHas $p 'publicNetworkAccess'
        $pna = [string](SGet $p 'publicNetworkAccess' 'Enabled')
        if (-not $pnaSet) { [void]$Sb.Append('<td>' + (SVal 'not set (Enabled)' 'unset' 'SEC-03' 'properties.publicNetworkAccess absent - the platform default is Enabled') + '</td>') }
        elseif ($pna -eq 'Disabled') { [void]$Sb.Append('<td>' + (SVal $pna $(if ($a.IsAfs) { 'warn' } else { 'ok' }) 'SEC-05' 'properties.publicNetworkAccess = Disabled') + '</td>') }
        else { [void]$Sb.Append('<td>' + (SVal $pna 'warn' 'SEC-03' ('properties.publicNetworkAccess = ' + $pna)) + '</td>') }

        $na = SGet $p 'networkAcls'
        $da = [string](SGet $na 'defaultAction' 'Allow')
        $nIp = @(SArr (SGet $na 'ipRules')).Count
        $nVn = @(SArr (SGet $na 'virtualNetworkRules')).Count
        [void]$Sb.Append('<td>' + (SVal ($da + ' (' + $nIp + ' IP, ' + $nVn + ' VNet)') $(if ($da -eq 'Deny') { 'ok' } else { 'bad' }) 'SEC-03' ('properties.networkAcls.defaultAction = ' + $da)) + '</td>')

        $skaSet = SHas $p 'allowSharedKeyAccess'
        $ska = SGet $p 'allowSharedKeyAccess' $true
        if (-not $skaSet) { [void]$Sb.Append('<td>' + (SVal 'not set (true)' 'unset' 'SEC-04' 'properties.allowSharedKeyAccess absent - the platform default is true') + '</td>') }
        elseif ($ska -eq $false) { [void]$Sb.Append('<td>' + (SVal 'false' 'inf' 'BKP-18' 'properties.allowSharedKeyAccess = false') + '</td>') }
        else { [void]$Sb.Append('<td>' + (SVal 'true' 'warn' 'SEC-04' 'properties.allowSharedKeyAccess = true') + '</td>') }

        $ds = [string](SGet (SGet $p 'azureFilesIdentityBasedAuthentication') 'directoryServiceOptions' 'None')
        [void]$Sb.Append('<td>' + (SVal $ds $(if ($ds -eq 'None') { 'warn' } else { 'ok' }) 'SEC-07' ('properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions = ' + $ds)) + '</td>')

        if ($null -eq $a.Sdrp) { [void]$Sb.Append('<td>' + (SVal 'not read' 'unset' 'DATA-02' 'fileservice.json missing or unreadable') + '</td>') }
        elseif ([bool](SGet $a.Sdrp 'enabled' $false)) { [void]$Sb.Append('<td>' + (SVal ('on, ' + [string](SGet $a.Sdrp 'days' '?') + ' d') 'ok' 'DATA-02' ('properties.shareDeleteRetentionPolicy.enabled = true, days = ' + [string](SGet $a.Sdrp 'days' ''))) + '</td>') }
        else { [void]$Sb.Append('<td>' + (SVal 'OFF' 'bad' 'DATA-02' 'properties.shareDeleteRetentionPolicy.enabled = false') + '</td>') }

        $dEnabled = $null; $dSrc = ''
        if ($null -ne $a.Defender -and (SHas (SGet $a.Defender 'properties') 'isEnabled')) {
            $dEnabled = SGet (SGet $a.Defender 'properties') 'isEnabled'; $dSrc = 'per-account defender.json'
        } elseif ($a.Sub -and $defPricing.ContainsKey($a.Sub.ToLower())) {
            $tier = [string](SGet (SGet $defPricing[$a.Sub.ToLower()] 'properties') 'pricingTier' '')
            $dEnabled = ($tier -eq 'Standard'); $dSrc = 'subscription pricing tier ' + $tier
        }
        if ($null -eq $dEnabled) { [void]$Sb.Append('<td>' + (SVal 'not readable' 'unset' 'SEC-09' 'defender.json is null and no subscription pricing file was exported') + '</td>') }
        elseif ($dEnabled -eq $true) { [void]$Sb.Append('<td>' + (SVal 'on' 'ok' 'SEC-09' $dSrc) + '</td>') }
        else { [void]$Sb.Append('<td>' + (SVal 'off' 'warn' 'SEC-09' $dSrc) + '</td>') }

        if (@($a.Locks).Count -eq 0) { [void]$Sb.Append('<td>' + (SVal 'none' 'warn' 'SEC-10' 'locks.json is empty') + '</td>') }
        else {
            $lvl = [string](SGet (SGet @($a.Locks)[0] 'properties') 'level' '')
            [void]$Sb.Append('<td>' + (SVal $lvl 'ok' 'SEC-10' ('locks.json .properties.level = ' + $lvl)) + '</td>')
        }
        [void]$Sb.Append('<td class="num">' + @($a.Shares).Count + '</td></tr>')
    }
    [void]$Sb.Append('</tbody></table></div>')
    [void]$Sb.Append('<p class="note">A dashed cell is a field the export did not carry. It is not blank and it is not "safe": the platform default applies, and for <code>minimumTlsVersion</code> that default is TLS1_0.</p>')

    # ---------------------------------------------------------------------------
    # pass 2 - one block per account
    # ---------------------------------------------------------------------------
    foreach ($a in $accounts) {
        $p = $a.P
        $safeId = ($a.Name -replace '[^A-Za-z0-9]', '-')

        [void]$Sb.Append('<div class="acct"><h2>' + (SEnc $a.Name) + '</h2><div class="sub">' + (SEnc $a.Location) + ' - ' + (SEnc $a.Kind) + ' - ' + (SEnc $a.Sku) + ' - resource group ' + (SEnc $a.Rg))
        if ($a.IsAfs) { [void]$Sb.Append('<span class="chip afs">Azure File Sync target</span>') }
        [void]$Sb.Append('</div></div>')

        # ---- the exposure and durability path ---------------------------------
        $https = SGet $p 'supportsHttpsTrafficOnly'
        $tlsSet = SHas $p 'minimumTlsVersion'
        $tls = [string](SGet $p 'minimumTlsVersion' 'TLS1_0')
        $tState = 'good'
        if ($https -eq $false) { $tState = 'open' }
        elseif (-not $tlsSet) { $tState = 'unset' }
        elseif ($tls -ne 'TLS1_2' -and $tls -ne 'TLS1_3') { $tState = 'open' }

        $na = SGet $p 'networkAcls'
        $da = [string](SGet $na 'defaultAction' 'Allow')
        $byp = [string](SGet $na 'bypass' '')
        $nIp = @(SArr (SGet $na 'ipRules')).Count
        $nVn = @(SArr (SGet $na 'virtualNetworkRules')).Count
        $pnaSet = SHas $p 'publicNetworkAccess'
        $pna = [string](SGet $p 'publicNetworkAccess' 'Enabled')
        $peConns = @(SArr (SGet $p 'privateEndpointConnections'))
        $peApproved = 0
        foreach ($pc in $peConns) {
            if ([string](SGet (SGet (SGet $pc 'properties') 'privateLinkServiceConnectionState') 'status' '') -eq 'Approved') { $peApproved++ }
        }
        $nState = 'good'
        if ($pna -eq 'Disabled') { $nState = 'good' }
        elseif ($da -ne 'Deny') { $nState = 'open' }
        elseif ($byp -notmatch 'AzureServices') { $nState = 'warn' }

        $skaSet = SHas $p 'allowSharedKeyAccess'
        $ska = SGet $p 'allowSharedKeyAccess' $true
        $ds = [string](SGet (SGet $p 'azureFilesIdentityBasedAuthentication') 'directoryServiceOptions' 'None')
        $iState = 'warn'
        if (-not $skaSet) { $iState = 'unset' }
        elseif ($ska -eq $false) { $iState = 'good' }

        $shownShares = @($a.Shares)
        $moreShares = 0
        if ($shownShares.Count -gt 8) { $moreShares = $shownShares.Count - 8; $shownShares = @($shownShares[0..7]) }
        $rowN = [Math]::Max(1, $shownShares.Count)
        $svgH = 150 + ($rowN * 90)

        $desc = 'Account ' + $a.Name + '. HTTPS only ' + (SBool $https) + ', minimum TLS ' + $(if ($tlsSet) { $tls } else { 'not set, default TLS1_0' }) +
                '. Public network access ' + $(if ($pnaSet) { $pna } else { 'not set, default Enabled' }) + ', firewall default action ' + $da +
                ', bypass ' + $(if ($byp) { $byp } else { 'not set' }) + ', ' + $nIp + ' IP rules, ' + $nVn + ' VNet rules, ' +
                $peConns.Count + ' private endpoint connections of which ' + $peApproved + ' approved. Shared key access ' +
                $(if ($skaSet) { (SBool $ska) } else { 'not set, default true' }) + ', directory service ' + $ds + '. ' +
                @($a.Shares).Count + ' file shares, ' + $(if ($null -ne $a.Sdrp -and [bool](SGet $a.Sdrp 'enabled' $false)) { 'share soft delete on' } else { 'share soft delete off' }) + '.'

        [void]$Sb.Append('<div class="diag"><svg viewBox="0 0 960 ' + $svgH + '" role="img" aria-label="Exposure and durability path for ' + (SEnc $a.Name) + '" xmlns="http://www.w3.org/2000/svg">')
        [void]$Sb.Append('<title>Exposure and durability path for ' + (SEnc $a.Name) + '</title><desc>' + (SEnc $desc) + '</desc>')
        [void]$Sb.Append('<defs><marker id="arrow-' + $safeId + '" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" fill="var(--muted)"/></marker></defs>')
        $mk = ' marker-end="url(#arrow-' + $safeId + ')"'

        [void]$Sb.Append((SvgBox 8 24 150 62 'info' 'CALLER' @('internet or', 'registered servers')))
        [void]$Sb.Append((SvgBox 176 24 196 62 $tState 'TRANSPORT' @(
                    ('HTTPS only: ' + $(if ($null -eq $https) { 'not set' } else { (SBool $https) })),
                    ('min TLS: ' + $(if ($tlsSet) { $tls } else { 'not set (TLS1_0)' }))) 'SEC-01/02'))
        [void]$Sb.Append((SvgBox 390 24 236 62 $nState 'NETWORK' @(
                    ('public: ' + $(if ($pnaSet) { $pna } else { 'not set (Enabled)' })),
                    ('firewall: ' + $da + ', bypass ' + $(if ($byp) { $byp } else { 'not set' })),
                    ([string]$nIp + ' IP, ' + $nVn + ' VNet, ' + $peConns.Count + ' PE (' + $peApproved + ' approved)')) 'SEC-03/05'))
        [void]$Sb.Append((SvgBox 644 24 196 62 $iState 'IDENTITY' @(
                    ('shared key: ' + $(if ($skaSet) { (SBool $ska) } else { 'not set (true)' })),
                    ('directory: ' + $ds)) 'SEC-04/07'))
        foreach ($ax in @(158, 372, 626)) {
            [void]$Sb.Append('<path d="M ' + $ax + ' 55 L ' + ($ax + 15) + ' 55" stroke="var(--muted)" stroke-width="2" fill="none"' + $mk + '/>')
        }
        $lastTop = 116 + (($rowN - 1) * 90)
        [void]$Sb.Append('<path d="M 840 55 L 872 55 L 872 100 L 22 100 L 22 137" stroke="var(--muted)" stroke-width="2" fill="none"' + $mk + '/>')
        if ($rowN -gt 1) {
            [void]$Sb.Append('<path d="M 22 137 L 22 ' + ($lastTop + 22) + '" stroke="var(--muted)" stroke-width="2" fill="none"/>')
        }

        if ($shownShares.Count -eq 0) {
            [void]$Sb.Append((SvgBox 40 116 300 44 'unset' 'NO FILE SHARES' @('shares.json .shares[] is empty')))
            [void]$Sb.Append('<text x="356" y="142" font-size="11" fill="var(--muted)">the assessor skips this account entirely - not assessed, not passed</text>')
        }
        $ri = 0
        foreach ($s in $shownShares) {
            $y0 = 116 + ($ri * 90)
            [void]$Sb.Append('<path d="M 22 ' + ($y0 + 22) + ' L 40 ' + ($y0 + 22) + '" stroke="var(--muted)" stroke-width="2" fill="none"/>')

            $sState = 'unset'; $fillTxt = 'usage not returned'
            if ($null -ne $s.Fill) {
                $sState = 'good'
                if ([double]$s.Fill -ge 90) { $sState = 'open' } elseif ([double]$s.Fill -ge 80) { $sState = 'warn' }
                $fillTxt = (SNum ([double]$s.Usage / 1073741824) 0) + ' of ' + (SNum $s.Quota 0) + ' GiB (' + (SNum $s.Fill 1) + '%)'
            } elseif ($null -ne $s.Quota) {
                $fillTxt = 'quota ' + (SNum $s.Quota 0) + ' GiB, usage not returned'
            }
            [void]$Sb.Append((SvgBox 40 $y0 340 44 $sState ('SHARE  ' + (STrunc $s.Name 20)) @($fillTxt) 'DATA-03'))
            if ($null -ne $s.Fill) {
                $bw = [int]([Math]::Max(0, [Math]::Min(100, [double]$s.Fill)) * 1.2)
                $bc = 'var(--good)'
                if ([double]$s.Fill -ge 90) { $bc = 'var(--crit)' } elseif ([double]$s.Fill -ge 80) { $bc = 'var(--warn)' }
                [void]$Sb.Append('<rect x="250" y="' + ($y0 + 25) + '" width="120" height="8" rx="4" fill="var(--surface-3)"/>')
                [void]$Sb.Append('<rect x="250" y="' + ($y0 + 25) + '" width="' + $bw + '" height="8" rx="4" fill="' + $bc + '"/>')
            }

            # the File Sync leg - Microsoft-internal, and it cannot be made private
            if ($null -ne $s.Sync) {
                [void]$Sb.Append('<path d="M 380 ' + ($y0 + 22) + ' L 762 ' + ($y0 + 22) + '" stroke="var(--info)" stroke-width="1.5" stroke-dasharray="3 3" fill="none"/>')
                [void]$Sb.Append((SvgBox 770 ($y0 + 2) 182 34 'info' '' @(('sync group ' + (STrunc ([string]$s.Sync.SyncGroup) 20)))))
                [void]$Sb.Append('<text x="780" y="' + ($y0 + 15) + '" font-size="11" font-weight="600" fill="currentColor">STORAGE SYNC SERVICE</text>')
                [void]$Sb.Append('<text x="861" y="' + ($y0 + 50) + '" font-size="10" text-anchor="middle" fill="var(--muted)">Microsoft-internal leg -</text>')
                [void]$Sb.Append('<text x="861" y="' + ($y0 + 61) + '" font-size="10" text-anchor="middle" fill="var(--muted)">cannot be made private</text>')
            }

            # the three durability layers hanging below the share
            $dy = $y0 + 50
            [void]$Sb.Append('<path d="M 70 ' + ($y0 + 44) + ' L 70 ' + $dy + '" stroke="var(--line)" stroke-width="1.5" fill="none"/>')
            $sdState = 'open'; $sdTxt = 'soft delete: OFF'
            if ($null -eq $a.Sdrp) { $sdState = 'unset'; $sdTxt = 'soft delete: not read' }
            elseif ([bool](SGet $a.Sdrp 'enabled' $false)) {
                $sdd = [string](SGet $a.Sdrp 'days' '')
                $sdState = 'good'; $sdTxt = 'soft delete: on, ' + $(if ($sdd) { $sdd + ' d' } else { 'days not set' })
            }
            [void]$Sb.Append((SvgBox 40 $dy 204 26 $sdState '' @() '' 5))
            [void]$Sb.Append('<text x="50" y="' + ($dy + 17) + '" font-size="11" fill="currentColor">' + (SEnc $sdTxt) + '</text>')

            $snN = [int]$s.Snapshots
            $snState = 'unset'
            if ($snN -gt 150) { $snState = 'warn' } elseif ($snN -gt 0) { $snState = 'good' }
            [void]$Sb.Append((SvgBox 252 $dy 150 26 $snState '' @() '' 5))
            [void]$Sb.Append('<text x="262" y="' + ($dy + 17) + '" font-size="11" fill="currentColor">snapshots: ' + $snN + ' of 200</text>')

            $vTxt = 'vault: no coverage row'; $vState = 'unset'
            if ($null -ne $s.Cov) {
                if ([bool](SGet $s.Cov 'protected' $false)) {
                    $vSt = [string](SGet $s.Cov 'protectionState' '')
                    $vTxt = 'vault: ' + (STrunc ([string](SGet $s.Cov 'vault' '')) 18) + ' - ' + $(if ($vSt) { $vSt } else { 'state not returned' })
                    if ($vSt -eq 'Protected') { $vState = 'good' } elseif ($vSt -eq 'IRPending') { $vState = 'info' } else { $vState = 'warn' }
                } else {
                    $vTxt = 'vault: not protected'; $vState = 'open'
                }
            }
            [void]$Sb.Append((SvgBox 410 $dy 282 26 $vState '' @() '' 5))
            [void]$Sb.Append('<text x="420" y="' + ($dy + 17) + '" font-size="11" fill="currentColor">' + (SEnc (STrunc $vTxt 44)) + '</text>')
            $ri++
        }
        if ($moreShares -gt 0) {
            [void]$Sb.Append('<text x="40" y="' + (116 + ($rowN * 90) + 2) + '" font-size="11" fill="var(--muted)">+ ' + $moreShares + ' more shares - the table below carries every one</text>')
        }

        $ly = 116 + ($rowN * 90) + 14
        $legend = @()
        $legend += @{ S = 'var(--good)'; F = 'var(--good-soft)'; T = 'pass'; X = 40 }
        $legend += @{ S = 'var(--warn)'; F = 'var(--warn-soft)'; T = 'weak'; X = 120 }
        $legend += @{ S = 'var(--crit)'; F = 'var(--crit-soft)'; T = 'open'; X = 200 }
        $legend += @{ S = 'var(--line)'; F = 'var(--surface-3)'; T = 'not set - the platform default applies'; X = 290 }
        foreach ($lgd in $legend) {
            [void]$Sb.Append('<rect x="' + $lgd.X + '" y="' + $ly + '" width="10" height="10" rx="2" fill="' + $lgd.F + '" stroke="' + $lgd.S + '" stroke-width="1.5"/>')
            [void]$Sb.Append('<text x="' + ($lgd.X + 15) + '" y="' + ($ly + 9) + '" font-size="11" fill="var(--muted)">' + (SEnc $lgd.T) + '</text>')
        }
        [void]$Sb.Append('</svg></div>')

        # ---- account, transport and identity, network -------------------------
        [void]$Sb.Append('<div class="cols">')
        [void]$Sb.Append('<div><h4>Account</h4><div class="card kv">')
        [void]$Sb.Append((SRow 'resource id' ('<span class="res">' + (SEnc $a.Id) + '</span>')))
        [void]$Sb.Append((SRow 'location' (SVal $a.Location 'na' 'BKP-14' ('location = ' + $a.Location)) 'a backup vault must be co-regional with the share'))
        [void]$Sb.Append((SRow 'kind / sku' ((SVal $a.Kind 'na' '' ('kind = ' + $a.Kind)) + ' ' + (SVal $a.Sku $(if ($a.Sku -like '*_LRS') { 'warn' } else { 'ok' }) 'DATA-01/07' ('sku.name = ' + $a.Sku)))))
        [void]$Sb.Append((SRow 'access tier' (SVal ([string](SGet $p 'accessTier' 'not set')) 'na' '' ('properties.accessTier = ' + [string](SGet $p 'accessTier' '')))))
        if (SHas $p 'largeFileSharesState') {
            $lfs = [string](SGet $p 'largeFileSharesState' '')
            [void]$Sb.Append((SRow 'large file shares' (SVal $lfs $(if ($lfs -eq 'Enabled') { 'ok' } else { 'warn' }) 'DATA-06' ('properties.largeFileSharesState = ' + $lfs))))
        } else {
            [void]$Sb.Append((SRow 'large file shares' (SVal 'not set (Disabled)' 'unset' 'DATA-06' 'properties.largeFileSharesState absent - the platform default is Disabled')))
        }
        $tagPairs = @(); $hasOwner = $false; $hasEnv = $false
        if ($null -ne $a.Tags) {
            foreach ($tp in @($a.Tags.PSObject.Properties)) {
                $tagPairs += ($tp.Name + '=' + [string]$tp.Value)
                if ($tp.Name -match '(?i)^owner$') { $hasOwner = $true }
                if ($tp.Name -match '(?i)^environment$') { $hasEnv = $true }
            }
        }
        if ($tagPairs.Count -eq 0) {
            [void]$Sb.Append((SRow 'tags' (SVal 'none' 'warn' 'OPS-01' 'tags = {}')))
        } else {
            [void]$Sb.Append((SRow 'tags' (SVal ($tagPairs -join '   ') $(if ($hasOwner -and $hasEnv) { 'ok' } else { 'warn' }) 'OPS-01' ('tags: ' + ($tagPairs -join ', '))) $(if ($hasOwner -and $hasEnv) { '' } else { 'no owner and environment pair' })))
        }
        if ($a.InvFound) {
            [void]$Sb.Append((SRow 'azure file sync' (SVal (SBool $a.IsAfs) $(if ($a.IsAfs) { 'inf' } else { 'na' }) 'AFS-13' 'inventory.json .referencedByAzureFileSync') $(if (@($a.SyncEndpoints).Count -gt 0) { $a.SyncEndpoints -join '; ' } else { 'no sync endpoints listed' })))
        } else {
            [void]$Sb.Append((SRow 'azure file sync' (SVal 'no inventory row' 'unset' '' 'inventory.json .storageAccounts[] carries no row for this id')))
        }
        [void]$Sb.Append('</div></div>')

        [void]$Sb.Append('<div><h4>Transport and identity</h4><div class="card kv">')
        [void]$Sb.Append((SRow 'https only' $(if ($https -eq $true) { (SVal 'true' 'ok' 'SEC-01' 'properties.supportsHttpsTrafficOnly = true') } elseif ($https -eq $false) { (SVal 'false' 'bad' 'SEC-01' 'properties.supportsHttpsTrafficOnly = false') } else { (SVal 'not set' 'unset' 'SEC-01' 'properties.supportsHttpsTrafficOnly absent') })))
        [void]$Sb.Append((SRow 'minimum tls' $(if (-not $tlsSet) { (SVal 'not set (defaults to TLS1_0)' 'unset' 'SEC-02' 'properties.minimumTlsVersion absent') } elseif ($tls -eq 'TLS1_2' -or $tls -eq 'TLS1_3') { (SVal $tls 'ok' 'SEC-02' ('properties.minimumTlsVersion = ' + $tls)) } else { (SVal $tls 'bad' 'SEC-02' ('properties.minimumTlsVersion = ' + $tls)) })))
        [void]$Sb.Append((SRow 'shared key access' $(if (-not $skaSet) { (SVal 'not set (defaults to true)' 'unset' 'SEC-04' 'properties.allowSharedKeyAccess absent') } elseif ($ska -eq $false) { (SVal 'false' 'inf' 'BKP-18' 'properties.allowSharedKeyAccess = false') } else { (SVal 'true' 'warn' 'SEC-04' 'properties.allowSharedKeyAccess = true') }) 'Azure Backup for Files, and File Sync without managed identity, both require it today'))
        [void]$Sb.Append((SRow 'default to oauth' $(if (SHas $p 'defaultToOAuthAuthentication') { (SVal (SBool (SGet $p 'defaultToOAuthAuthentication')) 'na' '' 'properties.defaultToOAuthAuthentication') } else { (SVal 'not set' 'unset' '' 'properties.defaultToOAuthAuthentication absent') })))
        $adp = SGet (SGet $p 'azureFilesIdentityBasedAuthentication') 'activeDirectoryProperties'
        [void]$Sb.Append((SRow 'directory service' (SVal $ds $(if ($ds -eq 'None') { 'warn' } else { 'ok' }) 'SEC-07' ('properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions = ' + $ds)) $(if ($null -ne $adp) { 'domain ' + [string](SGet $adp 'domainName' '') } else { '' })))
        [void]$Sb.Append((SRow 'blob public access' $(if (SHas $p 'allowBlobPublicAccess') { (SVal (SBool (SGet $p 'allowBlobPublicAccess')) $(if ((SGet $p 'allowBlobPublicAccess') -eq $true) { 'bad' } else { 'ok' }) 'SEC-11' 'properties.allowBlobPublicAccess') } else { (SVal 'not set (false)' 'unset' 'SEC-11' 'properties.allowBlobPublicAccess absent') })))
        [void]$Sb.Append((SRow 'cross-tenant replication' $(if (SHas $p 'allowCrossTenantReplication') { (SVal (SBool (SGet $p 'allowCrossTenantReplication')) $(if ((SGet $p 'allowCrossTenantReplication') -eq $true) { 'warn' } else { 'ok' }) 'SEC-12' 'properties.allowCrossTenantReplication') } else { (SVal 'not set' 'unset' 'SEC-12' 'properties.allowCrossTenantReplication absent') })))
        $sftpCell = $(if (SHas $p 'isSftpEnabled') { (SVal ('sftp ' + (SBool (SGet $p 'isSftpEnabled'))) $(if ((SGet $p 'isSftpEnabled') -eq $true) { 'warn' } else { 'ok' }) 'SEC-15' 'properties.isSftpEnabled') } else { (SVal 'sftp not set' 'unset' 'SEC-15' 'properties.isSftpEnabled absent') })
        $luCell = $(if (SHas $p 'isLocalUserEnabled') { (SVal ('local users ' + (SBool (SGet $p 'isLocalUserEnabled'))) $(if ((SGet $p 'isLocalUserEnabled') -eq $true) { 'warn' } else { 'ok' }) 'SEC-15' 'properties.isLocalUserEnabled') } else { (SVal 'local users not set' 'unset' 'SEC-15' 'properties.isLocalUserEnabled absent') })
        [void]$Sb.Append((SRow 'sftp / local users' ($sftpCell + ' ' + $luCell)))
        [void]$Sb.Append('</div></div>')

        [void]$Sb.Append('<div><h4>Network exposure</h4><div class="card kv">')
        [void]$Sb.Append((SRow 'public network access' $(if (-not $pnaSet) { (SVal 'not set (defaults to Enabled)' 'unset' 'SEC-03' 'properties.publicNetworkAccess absent') } elseif ($pna -eq 'Disabled') { (SVal $pna $(if ($a.IsAfs) { 'warn' } else { 'ok' }) 'SEC-05' 'properties.publicNetworkAccess = Disabled') } else { (SVal $pna 'warn' 'SEC-03' ('properties.publicNetworkAccess = ' + $pna)) }) $(if ($pna -eq 'Disabled' -and $a.IsAfs) { 'File Sync guidance is Deny plus trusted services, not fully disabled' } else { '' })))
        [void]$Sb.Append((SRow 'firewall default action' (SVal $da $(if ($da -eq 'Deny') { 'ok' } else { 'bad' }) 'SEC-03' ('properties.networkAcls.defaultAction = ' + $da)) $(if ($da -ne 'Deny') { 'open to all networks' } else { '' })))
        $bypNote = ''
        if ($byp -eq 'None' -and $da -ne 'Deny') { $bypNote = 'invisible today, but switching the firewall to Deny would break File Sync and Backup' }
        elseif ($byp -eq 'None') { $bypNote = 'trusted Azure services are blocked' }
        [void]$Sb.Append((SRow 'bypass' $(if (SHas $na 'bypass') { (SVal $byp $(if ($byp -match 'AzureServices') { 'ok' } else { 'warn' }) 'AFS-14' ('properties.networkAcls.bypass = ' + $byp)) } else { (SVal 'not set' 'unset' 'AFS-14' 'properties.networkAcls.bypass absent') }) $bypNote))
        $ipTxt = @()
        foreach ($r in (SArr (SGet $na 'ipRules'))) { $ipTxt += ([string](SGet $r 'value' '') + ' ' + [string](SGet $r 'action' '')) }
        [void]$Sb.Append((SRow 'ip rules' $(if ($ipTxt.Count -eq 0) { (SVal 'none' 'na' '' 'properties.networkAcls.ipRules = []') } else { (SVal ($ipTxt -join '; ') 'na' '' 'properties.networkAcls.ipRules[]') })))
        $vnTxt = @()
        foreach ($r in (SArr (SGet $na 'virtualNetworkRules'))) { $vnTxt += (SLeaf ([string](SGet $r 'id' ''))) }
        [void]$Sb.Append((SRow 'vnet rules' $(if ($vnTxt.Count -eq 0) { (SVal 'none' 'na' '' 'properties.networkAcls.virtualNetworkRules = []') } else { (SVal ($vnTxt -join '; ') 'na' '' 'properties.networkAcls.virtualNetworkRules[]') })))
        [void]$Sb.Append((SRow 'resource access rules' $(if (SHas $na 'resourceAccessRules') { (SVal ([string]@(SArr (SGet $na 'resourceAccessRules')).Count) 'na' '' 'properties.networkAcls.resourceAccessRules[]') } else { (SVal 'not set' 'unset' '' 'properties.networkAcls.resourceAccessRules absent') })))
        [void]$Sb.Append('</div></div></div>')

        # ---- private endpoints, resolved against network/ ---------------------
        [void]$Sb.Append('<h4>Private endpoints</h4>')
        if ($peConns.Count -eq 0) {
            [void]$Sb.Append('<p class="note">No private endpoint connection on this account (<code>properties.privateEndpointConnections = []</code>). The file service is reached over its public endpoint. <span class="chip">NET-08</span></p>')
        } else {
            [void]$Sb.Append('<div class="scroll"><table class="tight"><thead><tr><th>Connection</th><th>Status</th><th>Private endpoint</th><th>Group ids</th><th>Subnet</th><th>DNS zone group</th></tr></thead><tbody>')
            foreach ($pc in $peConns) {
                $pcp = SGet $pc 'properties'
                $peId = [string](SGet (SGet $pcp 'privateEndpoint') 'id' '')
                $st = [string](SGet (SGet $pcp 'privateLinkServiceConnectionState') 'status' '')
                $found = $null
                foreach ($w in $peWrap) {
                    if (([string](SGet (SGet $w 'privateEndpoint') 'id' '')).ToLower() -eq $peId.ToLower()) { $found = $w; break }
                }
                $gids = @(); $subnet = ''; $zones = @()
                if ($null -ne $found) {
                    $pep = SGet (SGet $found 'privateEndpoint') 'properties'
                    foreach ($cn in (SArr (SGet $pep 'privateLinkServiceConnections'))) {
                        foreach ($g in (SArr (SGet (SGet $cn 'properties') 'groupIds'))) { $gids += [string]$g }
                    }
                    $subnet = SLeaf ([string](SGet (SGet $pep 'subnet') 'id' ''))
                    foreach ($zg in (SArr (SGet $found 'privateDnsZoneGroups'))) {
                        foreach ($zc in (SArr (SGet (SGet $zg 'properties') 'privateDnsZoneConfigs'))) {
                            $zones += (SLeaf ([string](SGet (SGet $zc 'properties') 'privateDnsZoneId' '')))
                        }
                    }
                }
                [void]$Sb.Append('<tr><td class="res">' + (SEnc (SGet $pc 'name' '')) + '</td>')
                [void]$Sb.Append('<td>' + (SVal $st $(if ($st -eq 'Approved') { 'ok' } else { 'warn' }) 'NET-02' ('privateLinkServiceConnectionState.status = ' + $st)) + '</td>')
                [void]$Sb.Append('<td class="res">' + (SEnc (SLeaf $peId)) + '</td>')
                [void]$Sb.Append('<td>' + (SVal $(if ($gids.Count -gt 0) { $gids -join ', ' } else { 'not resolved' }) $(if ($gids -contains 'file') { 'ok' } elseif ($gids.Count -gt 0) { 'warn' } else { 'unset' }) 'NET-03' 'privateEndpoint.properties.privateLinkServiceConnections[].properties.groupIds - must be file') + '</td>')
                [void]$Sb.Append('<td class="res">' + $(if ($subnet) { (SEnc $subnet) } else { (SVal 'not in network/privateendpoints.json' 'unset' '' 'the private endpoint resource itself was not exported') }) + '</td>')
                [void]$Sb.Append('<td class="res">' + $(if ($zones.Count -gt 0) { (SEnc ($zones -join ', ')) } else { (SVal 'none' 'unset' 'NET-04' 'no privateDnsZoneGroups on the endpoint') }) + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table></div>')
            $fileZone = $null
            foreach ($z in $dnsWrap) {
                if ([string](SGet (SGet $z 'zone') 'name' '') -eq 'privatelink.file.core.windows.net') { $fileZone = $z; break }
            }
            if ($null -eq $fileZone) {
                [void]$Sb.Append('<p class="note">No <code>privatelink.file.core.windows.net</code> zone is present in <code>network/privatednszones.json</code>, so name resolution for this endpoint is not evidenced by the export. <span class="chip">NET-04 / NET-06</span></p>')
            } else {
                [void]$Sb.Append('<p class="note">Zone <code>privatelink.file.core.windows.net</code>: ' + @(SArr (SGet $fileZone 'virtualNetworkLinks')).Count + ' virtual network link(s), ' + @(SArr (SGet $fileZone 'aRecords')).Count + ' A record(s). <span class="chip">NET-04 / NET-06</span></p>')
            }
        }

        # ---- encryption and account keys --------------------------------------
        $encr = SGet $p 'encryption'
        [void]$Sb.Append('<div class="cols"><div><h4>Encryption</h4><div class="card kv">')
        $ksrc = [string](SGet $encr 'keySource' '')
        [void]$Sb.Append((SRow 'key source' (SVal $(if ($ksrc) { $ksrc } else { 'not set' }) $(if ($ksrc -eq 'Microsoft.Keyvault') { 'ok' } else { 'na' }) 'SEC-14' ('properties.encryption.keySource = ' + $ksrc)) $(if ($ksrc -eq 'Microsoft.Storage') { 'platform-managed keys' } else { '' })))
        $kvp = SGet $encr 'keyvaultproperties'
        if ($null -ne $kvp) {
            [void]$Sb.Append((SRow 'customer managed key' (SVal ([string](SGet $kvp 'keyname' '') + ' @ ' + [string](SGet $kvp 'keyvaulturi' '')) 'ok' 'SEC-14' 'properties.encryption.keyvaultproperties')))
        }
        [void]$Sb.Append((SRow 'infrastructure encryption' $(if (SHas $encr 'requireInfrastructureEncryption') { (SVal (SBool (SGet $encr 'requireInfrastructureEncryption')) 'na' '' 'properties.encryption.requireInfrastructureEncryption') } else { (SVal 'not set' 'unset' '' 'properties.encryption.requireInfrastructureEncryption absent') })))
        $svcTxt = @()
        $svcs = SGet $encr 'services'
        if ($null -ne $svcs) {
            foreach ($svp in @($svcs.PSObject.Properties)) {
                $svcTxt += ($svp.Name + ': ' + (SBool (SGet $svp.Value 'enabled')) + ', ' + [string](SGet $svp.Value 'keyType' ''))
            }
        }
        [void]$Sb.Append((SRow 'services' $(if ($svcTxt.Count -gt 0) { (SVal ($svcTxt -join '   ') 'na' '' 'properties.encryption.services') } else { (SVal 'not returned' 'unset' '' 'properties.encryption.services absent') })))
        [void]$Sb.Append('</div></div>')

        [void]$Sb.Append('<div><h4>Account keys</h4><div class="card kv">')
        $kct = SGet $p 'keyCreationTime'
        foreach ($kn in @('key1', 'key2')) {
            $kv = [string](SGet $kct $kn '')
            $ageTxt = 'not returned'; $kState = 'unset'
            if ($kv) {
                $dt = $null
                try { $dt = [datetime]::Parse($kv, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $dt = $null }
                if ($null -ne $dt) {
                    $age = [int]([datetime]::UtcNow - $dt).TotalDays
                    $ageTxt = $kv + '   (' + $age + ' days old)'
                    $kState = $(if ($age -gt 365) { 'bad' } else { 'ok' })
                } else { $ageTxt = $kv; $kState = 'na' }
            }
            [void]$Sb.Append((SRow ($kn + ' created') (SVal $ageTxt $kState 'SEC-06' ('properties.keyCreationTime.' + $kn + ' = ' + $kv))))
        }
        $kpol = SGet $p 'keyPolicy'
        if ($null -eq $kpol) {
            [void]$Sb.Append((SRow 'key expiration policy' (SVal 'none' 'bad' 'SEC-06' 'properties.keyPolicy absent') 'a separate remediation from key age - the policy is what keeps them rotating'))
        } else {
            $kd = [string](SGet $kpol 'keyExpirationPeriodInDays' '')
            [void]$Sb.Append((SRow 'key expiration policy' (SVal ($kd + ' days') 'ok' 'SEC-06' ('properties.keyPolicy.keyExpirationPeriodInDays = ' + $kd))))
        }
        [void]$Sb.Append('</div></div></div>')

        # ---- file service and locks -------------------------------------------
        [void]$Sb.Append('<div class="cols"><div><h4>File service</h4><div class="card kv">')
        if (-not $a.FsFound) {
            [void]$Sb.Append((SRow 'fileservice.json' (SVal 'not read' 'unset' 'DATA-02' 'storage/<account>/fileservice.json is missing, zero bytes or unparseable') ('check errors.json for fileService:' + $a.Name)))
        } else {
            if ($null -eq $a.Sdrp) {
                [void]$Sb.Append((SRow 'share soft delete' (SVal 'not returned' 'unset' 'DATA-02' 'properties.shareDeleteRetentionPolicy absent')))
            } elseif ([bool](SGet $a.Sdrp 'enabled' $false)) {
                $sdd2 = [string](SGet $a.Sdrp 'days' '')
                [void]$Sb.Append((SRow 'share soft delete' (SVal ('enabled, ' + $(if ($sdd2) { $sdd2 + ' days' } else { 'days not returned' })) 'ok' 'DATA-02' ('properties.shareDeleteRetentionPolicy.enabled = true; days = ' + $sdd2))))
            } else {
                [void]$Sb.Append((SRow 'share soft delete' (SVal 'OFF' 'bad' 'DATA-02' 'properties.shareDeleteRetentionPolicy.enabled = false') 'the only defence against a deleted share; there is no days key when it is off'))
            }
            $smbProps = @()
            if ($null -ne $a.Smb) { foreach ($smp in @($a.Smb.PSObject.Properties)) { $smbProps += ($smp.Name + ' = ' + [string]$smp.Value) } }
            if ($smbProps.Count -eq 0) {
                [void]$Sb.Append((SRow 'smb settings' (SVal '{} - platform defaults' 'warn' 'SEC-08' 'properties.protocolSettings.smb = {}') 'defaults allow SMB2.1/3.0/3.1.1, NTLMv2 and Kerberos, AES-128-CCM'))
            } else {
                [void]$Sb.Append((SRow 'smb settings' (SVal ($smbProps -join '   ') 'ok' 'SEC-08' ('properties.protocolSettings.smb: ' + ($smbProps -join '; ')))))
            }
        }
        [void]$Sb.Append('</div></div>')

        [void]$Sb.Append('<div><h4>Resource locks</h4><div class="card">')
        if (@($a.Locks).Count -eq 0) {
            [void]$Sb.Append('<p class="note">No resource lock on this account. Deleting it deletes every share on it. <span class="chip">SEC-10</span></p>')
        } else {
            [void]$Sb.Append('<table class="tight"><thead><tr><th>Name</th><th>Level</th><th>Origin</th></tr></thead><tbody>')
            foreach ($lk in $a.Locks) {
                $lp = SGet $lk 'properties'
                $notes = [string](SGet $lp 'notes' '')
                [void]$Sb.Append('<tr><td class="res">' + (SEnc (SGet $lk 'name' '')) + '</td><td>' + (SVal ([string](SGet $lp 'level' '')) 'ok' 'SEC-10' ('properties.level = ' + [string](SGet $lp 'level' ''))) + '</td>')
                [void]$Sb.Append('<td>' + $(if ($notes -match '(?i)auto-created by azure backup') { (SVal 'machine-made (Azure Backup)' 'inf' '' $notes) } else { (SVal 'customer' 'ok' '' $(if ($notes) { $notes } else { 'properties.notes is empty' })) }) + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table><p class="note">A lock created by Azure Backup is a side effect of registering the account with a vault, not evidence of governance.</p>')
        }
        [void]$Sb.Append('</div></div></div>')

        # ---- shares and backup coverage ---------------------------------------
        [void]$Sb.Append('<h4>File shares and backup coverage</h4>')
        if (-not $a.SharesFound) {
            [void]$Sb.Append('<p class="note">shares.json was not read for this account (missing, zero bytes or unparseable). Check <code>errors.json</code> for <code>shares+snapshots:' + (SEnc $a.Name) + '</code>.</p>')
        } elseif (@($a.Shares).Count -eq 0) {
            [void]$Sb.Append('<p class="note">No Azure file shares on this account (<code>shares.json .shares[] = []</code>). The assessor skips accounts with no shares, so this account produces no findings at all - that is <b>not assessed</b>, not <b>passed</b>.</p>')
        } else {
            [void]$Sb.Append('<div class="scroll"><table class="tight"><thead><tr><th>Share</th><th>Quota GiB</th><th>Used GiB</th><th>Fill</th><th>Tier</th><th>Protocol</th><th>Snapshots</th><th>Backup</th><th>Vault / policy</th><th>Access policies</th><th>Last modified</th></tr></thead><tbody>')
            foreach ($s in $a.Shares) {
                [void]$Sb.Append('<tr><td class="res">' + (SEnc $s.Name))
                if ($null -ne $s.Sync) { [void]$Sb.Append('<span class="chip afs">' + (SEnc ([string]$s.Sync.SyncGroup)) + '</span>') }
                foreach ($m in $s.Meta) { [void]$Sb.Append('<span class="chip">' + (SEnc $m) + '</span>') }
                [void]$Sb.Append('</td><td class="num">' + (SEnc (SNum $s.Quota 0)) + '</td>')
                if ($s.HasUsage -and $null -ne $s.Usage) {
                    [void]$Sb.Append('<td class="num">' + (SEnc (SNum ([double]$s.Usage / 1073741824) 0)) + '</td>')
                } else {
                    [void]$Sb.Append('<td>' + (SVal 'stats call failed' 'unset' 'DATA-03' ('shareUsageBytes is absent - the expand=stats GET failed; see errors.json share-stats:' + $a.Name + '/' + $s.Name)) + '</td>')
                }
                if ($null -ne $s.Fill) {
                    $bcls = ''; $fState = 'ok'
                    if ([double]$s.Fill -ge 90) { $bcls = ' c'; $fState = 'bad' } elseif ([double]$s.Fill -ge 80) { $bcls = ' w'; $fState = 'warn' }
                    $bwidth = [Math]::Round([Math]::Max(0, [Math]::Min(100, [double]$s.Fill)), 1)
                    [void]$Sb.Append('<td>' + (SVal ((SNum $s.Fill 1) + '%') $fState 'DATA-03' ('shareUsageBytes / (shareQuota * 1024^3) = ' + (SNum $s.Fill 1) + '%')) + '<div class="sbar' + $bcls + '"><i style="width:' + $bwidth + '%"></i></div></td>')
                } else {
                    [void]$Sb.Append('<td>' + (SVal 'unknown' 'unset' 'DATA-03' 'fill cannot be computed without shareUsageBytes') + '</td>')
                }
                [void]$Sb.Append('<td>' + (SEnc $s.Tier) + '</td>')
                [void]$Sb.Append('<td>' + $(if ($s.ProtocolsSet) { (SEnc $s.Protocols) } else { (SVal 'not set (SMB)' 'unset' '' 'properties.enabledProtocols absent - the default is SMB') }) + '</td>')
                [void]$Sb.Append('<td>' + (SVal ([string]$s.Snapshots + ' of 200') $(if ([int]$s.Snapshots -gt 150) { 'warn' } elseif ([int]$s.Snapshots -gt 0) { 'ok' } else { 'na' }) 'DATA-04' 'shares.json .snapshots[] counted by share name') + '</td>')
                if ($null -eq $s.Cov) {
                    [void]$Sb.Append('<td>' + (SVal 'no coverage row' 'unset' 'BKP-01' 'backup/share-coverage.json carries no row for this account and share') + '</td><td></td>')
                } elseif (-not [bool](SGet $s.Cov 'protected' $false)) {
                    [void]$Sb.Append('<td>' + (SVal $(if ($null -ne $s.Sync) { 'not protected (File Sync cloud endpoint)' } else { 'not protected' }) 'bad' 'BKP-01' 'share-coverage.json .protected = false') + '</td><td></td>')
                } else {
                    $pst = [string](SGet $s.Cov 'protectionState' '')
                    $lbs = [string](SGet $s.Cov 'lastBackupStatus' '')
                    $cState = 'ok'
                    if ($pst -eq 'IRPending' -or $lbs -eq 'IRPending') { $cState = 'inf' }
                    elseif ($pst -ne 'Protected' -or ($lbs -and $lbs -ne 'Healthy')) { $cState = 'bad' }
                    $ctxt = $pst
                    if ($lbs) { $ctxt += ' / ' + $lbs }
                    if ($cState -eq 'inf') { $ctxt += ' (initial replication in flight)' }
                    [void]$Sb.Append('<td>' + (SVal $ctxt $cState 'BKP-02' ('share-coverage.json .protectionState = ' + $pst + '; .lastBackupStatus = ' + $lbs)) + '</td>')
                    $pol = [string](SGet $s.Cov 'policy' '')
                    [void]$Sb.Append('<td class="res">' + (SEnc ([string](SGet $s.Cov 'vault' ''))) + $(if ($pol) { ' / ' + (SEnc $pol) } else { ' ' + (SVal 'policy not returned' 'unset' '' 'share-coverage.json .policy is an empty string') }) + '</td>')
                }
                [void]$Sb.Append('<td>' + (SVal ([string]$s.SignedIds) $(if ([int]$s.SignedIds -gt 0) { 'warn' } else { 'na' }) '' 'properties.signedIdentifiers[] - stored access policies are long-lived SAS grants') + '</td>')
                [void]$Sb.Append('<td class="ev">' + (SEnc $s.LastMod) + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table></div>')
            [void]$Sb.Append('<p class="note">Fill is <code>shareUsageBytes / (shareQuota * 1024^3)</code> - the quota is GiB and the usage is bytes. Amber from 80%, red from 90%. <span class="chip">DATA-03</span></p>')
        }

        # ---- snapshots and soft-deleted shares --------------------------------
        [void]$Sb.Append('<div class="cols"><div><h4>Share snapshots</h4><div class="card">')
        if (@($a.Snaps).Count -eq 0) {
            [void]$Sb.Append('<p class="note">None. <code>shares.json .snapshots[]</code> is empty.</p>')
        } else {
            [void]$Sb.Append('<table class="tight"><thead><tr><th>Share</th><th>Snapshot time</th></tr></thead><tbody>')
            foreach ($sn in $a.Snaps) {
                [void]$Sb.Append('<tr><td class="res">' + (SEnc (SGet $sn 'name' '')) + '</td><td class="ev">' + (SEnc (SGet (SGet $sn 'properties') 'snapshotTime' '')) + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table><p class="note">Snapshot entries repeat the parent share name and id; only <code>properties.snapshotTime</code> distinguishes them. The limit is 200 per share. <span class="chip">DATA-04</span></p>')
        }
        [void]$Sb.Append('</div></div>')

        [void]$Sb.Append('<div><h4>Soft-deleted shares</h4><div class="card">')
        if (@($a.Soft).Count -eq 0) {
            [void]$Sb.Append('<p class="note">None. <code>shares.json .softDeleted[]</code> is empty.</p>')
        } else {
            [void]$Sb.Append('<table class="tight"><thead><tr><th>Share</th><th>Deleted</th><th>Days left to recover</th><th>Quota GiB</th><th>Version</th></tr></thead><tbody>')
            foreach ($sd in $a.Soft) {
                $sdp = SGet $sd 'properties'
                $rem = SGet $sdp 'remainingRetentionDays'
                $rState = 'ok'
                if ($null -ne $rem) { if ([int]$rem -le 7) { $rState = 'bad' } elseif ([int]$rem -le 14) { $rState = 'warn' } }
                [void]$Sb.Append('<tr><td class="res">' + (SEnc (SGet $sd 'name' '')) + '</td><td class="ev">' + (SEnc (SGet $sdp 'deletedTime' '')) + '</td>')
                [void]$Sb.Append('<td>' + (SVal $(if ($null -ne $rem) { [string]$rem + ' days' } else { 'not returned' }) $rState 'DATA-05' ('properties.remainingRetentionDays = ' + [string]$rem)) + '</td>')
                [void]$Sb.Append('<td class="num">' + (SEnc (SNum (SGet $sdp 'shareQuota') 0)) + '</td><td class="ev">' + (SEnc (SGet $sdp 'version' '')) + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table><p class="note">A countdown, not a list: when the days run out the share is gone for good. <span class="chip">DATA-05</span></p>')
        }
        [void]$Sb.Append('</div></div></div>')

        # ---- rbac at account scope --------------------------------------------
        [void]$Sb.Append('<h4>Role assignments at account scope</h4>')
        if (-not $a.RaFileExists) {
            [void]$Sb.Append('<p class="note">roleassignments.json was not written for this account. Check <code>errors.json</code> for <code>rbac:' + (SEnc $a.Name) + '</code>.</p>')
        } elseif (@($a.RaHere).Count -eq 0) {
            [void]$Sb.Append('<p class="note">No role assignments at account scope; ' + $a.RaUp + ' reach it by inheritance from the subscription, management groups or root. <span class="chip">SEC-13</span></p>')
        } else {
            [void]$Sb.Append('<div class="scroll"><table class="tight"><thead><tr><th>Role</th><th>Principal type</th><th>Principal id</th><th>Condition</th><th>Created</th></tr></thead><tbody>')
            foreach ($ra in $a.RaHere) {
                $rn = [string](SGet $ra 'roleName' '')
                $ptp = [string](SGet $ra 'principalType' '')
                $priv = ((@('Owner', 'Contributor', 'Storage Account Contributor') -contains $rn) -and ($ptp -eq 'User'))
                [void]$Sb.Append('<tr><td>' + $(if ($priv) { (SVal $rn 'bad' 'SEC-13' ('roleName = ' + $rn + ' held directly by a User')) } else { (SEnc $rn) }) + '</td>')
                [void]$Sb.Append('<td>' + (SEnc $ptp) + '</td><td class="res">' + (SEnc (SGet $ra 'principalId' '')) + '</td>')
                [void]$Sb.Append('<td class="ev">' + $(if ($null -ne (SGet $ra 'condition')) { (SEnc (SGet $ra 'condition')) } else { 'none' }) + '</td>')
                [void]$Sb.Append('<td class="ev">' + (SEnc (SGet $ra 'createdOn' '')) + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table></div>')
            [void]$Sb.Append('<p class="note">A further ' + $a.RaUp + ' assignments reach this account by inheritance. The export queries with <code>atScope()</code>, which returns every parent scope; only the account-scope rows are shown here.</p>')
        }

        # ---- defender and diagnostics -----------------------------------------
        [void]$Sb.Append('<div class="cols"><div><h4>Defender for Storage</h4><div class="card kv">')
        $dprops = SGet $a.Defender 'properties'
        if ($null -eq $dprops) {
            $subTier = 'not exported'
            if ($a.Sub -and $defPricing.ContainsKey($a.Sub.ToLower())) { $subTier = [string](SGet (SGet $defPricing[$a.Sub.ToLower()] 'properties') 'pricingTier' 'not exported') }
            [void]$Sb.Append((SRow 'per-account setting' (SVal 'not readable (403/404 or null)' 'unset' 'SEC-09' 'storage/<account>/defender.json is null or absent') ('the subscription pricing tier ' + $subTier + ' applies')))
        } else {
            $dEn = SGet $dprops 'isEnabled'
            [void]$Sb.Append((SRow 'enabled' (SVal (SBool $dEn) $(if ($dEn -eq $true) { 'ok' } else { 'warn' }) 'SEC-09' ('properties.isEnabled = ' + (SBool $dEn)))))
            $mw = SGet (SGet $dprops 'malwareScanning') 'onUpload'
            if ($null -ne $mw) {
                [void]$Sb.Append((SRow 'malware scanning on upload' (SVal ((SBool (SGet $mw 'isEnabled')) + ', cap ' + [string](SGet $mw 'capGBPerMonth' 'n/a') + ' GB per month') $(if ((SGet $mw 'isEnabled') -eq $true) { 'ok' } else { 'na' }) 'SEC-09' 'properties.malwareScanning.onUpload')))
            }
            $sdd3 = SGet $dprops 'sensitiveDataDiscovery'
            if ($null -ne $sdd3) {
                [void]$Sb.Append((SRow 'sensitive data discovery' (SVal (SBool (SGet $sdd3 'isEnabled')) 'na' 'SEC-09' 'properties.sensitiveDataDiscovery.isEnabled')))
            }
            if (SHas $dprops 'overrideSubscriptionLevelSettings') {
                [void]$Sb.Append((SRow 'overrides the subscription' (SVal (SBool (SGet $dprops 'overrideSubscriptionLevelSettings')) 'na' '' 'properties.overrideSubscriptionLevelSettings')))
            }
        }
        if ($a.Sub -and $defPricing.ContainsKey($a.Sub.ToLower())) {
            $dpr = SGet $defPricing[$a.Sub.ToLower()] 'properties'
            $tier2 = [string](SGet $dpr 'pricingTier' '')
            [void]$Sb.Append((SRow 'subscription pricing tier' (SVal $tier2 $(if ($tier2 -eq 'Standard') { 'ok' } else { 'warn' }) 'SEC-09' ('defender/<Subscription>-pricing-StorageAccounts.json .properties.pricingTier = ' + $tier2))))
            if (SHas $dpr 'resourcesCoverageStatus') {
                [void]$Sb.Append((SRow 'coverage status' (SVal ([string](SGet $dpr 'resourcesCoverageStatus' '')) 'na' 'SEC-09' 'properties.resourcesCoverageStatus')))
            }
            if (SHas $dpr 'freeTrialRemainingTime') {
                [void]$Sb.Append((SRow 'free trial remaining' (SVal ([string](SGet $dpr 'freeTrialRemainingTime' '')) 'na' '' 'properties.freeTrialRemainingTime')))
            }
        } else {
            [void]$Sb.Append((SRow 'subscription pricing tier' (SVal 'not in this export' 'unset' 'SEC-09' 'defender/<Subscription>-pricing-StorageAccounts.json is missing')))
        }
        [void]$Sb.Append('</div></div>')

        [void]$Sb.Append('<div><h4>Diagnostic settings</h4><div class="card">')
        if ((@($a.DiagAcct).Count + @($a.DiagFile).Count) -eq 0) {
            [void]$Sb.Append('<p class="note">No diagnostic setting on the account or on the file service. Share reads, writes and deletes are recorded nowhere. <span class="chip">MON-03</span></p>')
        } else {
            [void]$Sb.Append('<table class="tight"><thead><tr><th>Scope</th><th>Name</th><th>Destination</th><th>Categories enabled</th></tr></thead><tbody>')
            $diagSets = @()
            $diagSets += @{ Scope = 'account'; Items = @($a.DiagAcct) }
            $diagSets += @{ Scope = 'file service'; Items = @($a.DiagFile) }
            foreach ($dset in $diagSets) {
                foreach ($dg in $dset.Items) {
                    $dgp = SGet $dg 'properties'
                    $dest = @()
                    foreach ($dk in @('workspaceId', 'storageAccountId', 'eventHubAuthorizationRuleId')) {
                        if (SHas $dgp $dk) { $dest += ($dk + ' = ' + (SLeaf ([string](SGet $dgp $dk '')))) }
                    }
                    $cats = @()
                    foreach ($lgc in (SArr (SGet $dgp 'logs'))) {
                        if ([bool](SGet $lgc 'enabled' $false)) { $cats += [string](SGet $lgc 'category' (SGet $lgc 'categoryGroup' '')) }
                    }
                    $mets = @()
                    foreach ($mtc in (SArr (SGet $dgp 'metrics'))) {
                        if ([bool](SGet $mtc 'enabled' $false)) { $mets += [string](SGet $mtc 'category' '') }
                    }
                    $catTxt = $(if ($cats.Count -gt 0) { $cats -join ', ' } else { 'no log category enabled' })
                    if ($mets.Count -gt 0) { $catTxt += '   [metrics: ' + ($mets -join ', ') + ']' }
                    [void]$Sb.Append('<tr><td>' + (SEnc $dset.Scope) + '</td><td class="res">' + (SEnc (SGet $dg 'name' '')) + '</td>')
                    [void]$Sb.Append('<td class="ev">' + $(if ($dest.Count -gt 0) { (SEnc ($dest -join '; ')) } else { 'not returned' }) + '</td>')
                    [void]$Sb.Append('<td>' + (SVal $catTxt $(if ($cats.Count -gt 0) { 'ok' } else { 'warn' }) 'MON-03' 'properties.logs[] where enabled = true') + '</td></tr>')
                }
            }
            [void]$Sb.Append('</tbody></table>')
            if (@($a.DiagFile).Count -eq 0) {
                [void]$Sb.Append('<p class="note">Nothing is set on the <b>file service</b>. Only the file-service setting records share reads, writes and deletes; the account-level one does not. <span class="chip">MON-03</span></p>')
            }
        }
        [void]$Sb.Append('</div></div></div>')

        # ---- metric alerts ----------------------------------------------------
        $myAlerts = @()
        foreach ($al in $alerts) {
            foreach ($sc in (SArr (SGet (SGet $al 'properties') 'scopes'))) {
                if (([string]$sc).ToLower() -eq $a.IdLower) { $myAlerts += $al; break }
            }
        }
        [void]$Sb.Append('<h4>Metric alerts</h4>')
        if ($myAlerts.Count -eq 0) {
            [void]$Sb.Append('<p class="note">No metric alert in <code>monitor/metricalerts.json</code> is scoped to this account. Nobody is told when the file service degrades. <span class="chip">MON-02</span></p>')
        } else {
            [void]$Sb.Append('<div class="scroll"><table class="tight"><thead><tr><th>Alert</th><th>Enabled</th><th>Criteria</th><th>Frequency / window</th><th>Actions</th></tr></thead><tbody>')
            foreach ($al in $myAlerts) {
                $ap = SGet $al 'properties'
                $crit = @()
                foreach ($cr in (SArr (SGet (SGet $ap 'criteria') 'allOf'))) {
                    $crit += ([string](SGet $cr 'metricName' '') + ' ' + [string](SGet $cr 'operator' '') + ' ' + [string](SGet $cr 'threshold' '') + ' (' + [string](SGet $cr 'timeAggregation' '') + ')')
                }
                $en = SGet $ap 'enabled'
                $nAct = @(SArr (SGet $ap 'actions')).Count
                [void]$Sb.Append('<tr><td class="res">' + (SEnc (SGet $al 'name' '')) + '</td>')
                [void]$Sb.Append('<td>' + (SVal (SBool $en) $(if ($en -eq $true) { 'ok' } else { 'warn' }) 'MON-02' 'properties.enabled') + '</td>')
                [void]$Sb.Append('<td>' + (SVal ($crit -join '; ') 'na' 'MON-02' 'properties.criteria.allOf[]') + '</td>')
                [void]$Sb.Append('<td class="ev">' + (SEnc ([string](SGet $ap 'evaluationFrequency' '') + ' / ' + [string](SGet $ap 'windowSize' ''))) + '</td>')
                [void]$Sb.Append('<td>' + (SVal ([string]$nAct + ' action group(s)') $(if ($nAct -gt 0) { 'ok' } else { 'warn' }) 'MON-02' 'properties.actions[] - an alert with no action group notifies nobody') + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table></div>')
        }

        # ---- metrics -----------------------------------------------------------
        [void]$Sb.Append('<h4>Metrics</h4>')
        if (-not $a.MetricsExists -or $null -eq $a.Metrics) {
            $why = 'the export did not write metrics.json for this account'
            if ($metricsSkipped -eq $true) { $why = 'the export ran with <code>-SkipMetrics</code> (<code>manifest.json .metricsSkipped = true</code>)' }
            elseif (@($a.Shares).Count -eq 0) { $why = 'the account has no live file shares, so there is no file-service metric to read' }
            else {
                $mErr = @($allErrors | Where-Object { ([string](SGet $_ 'where' '')) -like ('metrics:' + $a.Name + '/*') })
                if ($mErr.Count -gt 0) { $why = 'the metric calls failed - ' + $mErr.Count + ' entry(ies) in errors.json under <code>metrics:' + (SEnc $a.Name) + '/...</code>' }
                elseif ($a.MetricsExists) { $why = 'metrics.json was written as <code>null</code> - the metric query returned nothing' }
            }
            [void]$Sb.Append('<p class="note"><b>Metrics not collected:</b> ' + $why + '. Without them there is no evidence of which authentication method the shares actually use, so shared-key removal cannot be judged safe from this export alone. <span class="chip">MON-02</span></p>')
        } else {
            $lbTxt = $(if ($null -ne $lookback) { 'last ' + [string]$lookback + ' days' } else { 'export lookback window' })
            $auth = @(SSeries (SGet $a.Metrics 'TransactionsByAuth'))
            [void]$Sb.Append('<div class="cols"><div><h5>Transactions by authentication (' + (SEnc $lbTxt) + ')</h5>')
            if ($auth.Count -eq 0) {
                [void]$Sb.Append('<p class="note">The TransactionsByAuth series is not in this metrics.json.</p>')
            } else {
                $grand = 0.0
                foreach ($r in $auth) { $grand += [double]$r.Total }
                [void]$Sb.Append('<table class="tight"><thead><tr><th>Authentication</th><th>Transactions</th><th>Share</th></tr></thead><tbody>')
                foreach ($r in ($auth | Sort-Object -Property @{ Expression = { [double]$_.Total } } -Descending)) {
                    $pctv = 0.0
                    if ($grand -gt 0) { $pctv = ([double]$r.Total / $grand) * 100 }
                    $aState = 'na'
                    if ([string]$r.Dim -eq 'AccountKey' -and [double]$r.Total -gt 0) { $aState = 'warn' }
                    elseif ([string]$r.Dim -eq 'Anonymous' -and [double]$r.Total -gt 0) { $aState = 'bad' }
                    elseif ([string]$r.Dim -eq 'OAuth' -and [double]$r.Total -gt 0) { $aState = 'ok' }
                    [void]$Sb.Append('<tr><td>' + (SVal ([string]$r.Dim) $aState 'SEC-04' 'metrics.json .TransactionsByAuth, dimension Authentication') + '</td>')
                    [void]$Sb.Append('<td class="num">' + (SEnc (SNum $r.Total 0)) + '</td><td class="num">' + (SEnc (SNum $pctv 1)) + '%</td></tr>')
                }
                [void]$Sb.Append('</tbody></table>')
                [void]$Sb.Append('<p class="note">Traffic on <code>AccountKey</code> is what turning shared key off would break; <code>OAuth</code> traffic is what already survives it. <span class="chip">SEC-04 / AFS-12</span></p>')
            }
            [void]$Sb.Append('</div>')

            [void]$Sb.Append('<div><h5>Availability and response mix</h5>')
            $avail = @(SSeries (SGet $a.Metrics 'Availability'))
            if ($avail.Count -eq 0) {
                [void]$Sb.Append('<p class="note">The Availability series is not in this metrics.json.</p>')
            } else {
                [void]$Sb.Append('<div class="card kv">')
                foreach ($r in $avail) {
                    $avTxt = $(if ($null -ne $r.Avg) { (SNum $r.Avg 2) + '% average' } else { 'no bucket carried a value' })
                    if ($null -ne $r.MinMin) { $avTxt += ', ' + (SNum $r.MinMin 2) + '% worst day' }
                    $vState = 'unset'
                    if ($null -ne $r.Avg) { $vState = $(if ([double]$r.Avg -ge 99.9) { 'ok' } elseif ([double]$r.Avg -ge 99) { 'warn' } else { 'bad' }) }
                    [void]$Sb.Append((SRow 'availability' (SVal $avTxt $vState 'MON-02' 'metrics.json .Availability average and minimum, P1D') ([string]$r.WithData + ' of ' + [string]$r.Points + ' buckets carried a value')))
                }
                [void]$Sb.Append('</div>')
            }
            $resp = @(SSeries (SGet $a.Metrics 'TransactionsByResponse'))
            if ($resp.Count -gt 0) {
                [void]$Sb.Append('<table class="tight"><thead><tr><th>Response type</th><th>Transactions</th></tr></thead><tbody>')
                $shown = 0
                foreach ($r in ($resp | Sort-Object -Property @{ Expression = { [double]$_.Total } } -Descending)) {
                    if ([double]$r.Total -le 0) { continue }
                    $shown++
                    [void]$Sb.Append('<tr><td>' + (SVal ([string]$r.Dim) $(if ([string]$r.Dim -eq 'Success') { 'ok' } else { 'warn' }) '' 'metrics.json .TransactionsByResponse, dimension ResponseType') + '</td><td class="num">' + (SEnc (SNum $r.Total 0)) + '</td></tr>')
                }
                if ($shown -eq 0) { [void]$Sb.Append('<tr><td colspan="2" class="ev">no response type carried any traffic in the window</td></tr>') }
                [void]$Sb.Append('</tbody></table><p class="note">Throttling and authorization errors here are the usual explanation for a failing backup or a stalled sync.</p>')
            }
            [void]$Sb.Append('</div></div>')

            $cap = @(SSeries (SGet $a.Metrics 'FileCapacity'))
            if ($cap.Count -gt 0) {
                [void]$Sb.Append('<h5>Capacity series</h5><div class="scroll"><table class="tight"><thead><tr><th>Metric</th><th>Dimension</th><th>Latest value</th><th>Unit</th><th>Buckets with data</th></tr></thead><tbody>')
                $allDim = $true
                foreach ($r in $cap) {
                    if ([string]$r.Dim -ne '<All>') { $allDim = $false }
                    $lv = $(if ($null -ne $r.LastAvg) { (SNum $r.LastAvg 0) } elseif ($r.HasTotal -and [double]$r.Total -gt 0) { (SNum $r.Total 0) } else { 'no value' })
                    [void]$Sb.Append('<tr><td>' + (SEnc ([string]$r.Metric)) + '</td><td class="res">' + (SEnc $(if ($r.Dim) { [string]$r.Dim } else { 'account total' })) + '</td>')
                    [void]$Sb.Append('<td class="num">' + (SEnc $lv) + '</td><td>' + (SEnc ([string]$r.Unit)) + '</td>')
                    [void]$Sb.Append('<td>' + (SVal ([string]$r.WithData + ' of ' + [string]$r.Points) $(if ([int]$r.WithData -eq 0) { 'unset' } else { 'na' }) '' 'an empty bucket carries a timeStamp and no value - it is skipped, never read as zero') + '</td></tr>')
                }
                [void]$Sb.Append('</tbody></table></div>')
                if ($allDim) {
                    [void]$Sb.Append('<p class="note">The <code>fileshare</code> dimension collapsed to <code>&lt;All&gt;</code>, so these are account totals rather than per-share figures. <code>FileShareSnapshotSize</code> is the number the share table cannot show: snapshot storage is billed and invisible in <code>shareUsageBytes</code>.</p>')
                } else {
                    [void]$Sb.Append('<p class="note"><code>FileShareSnapshotSize</code> is the number the share table cannot show: snapshot storage is billed and invisible in <code>shareUsageBytes</code>.</p>')
                }
            }
        }

        # ---- what the export could not read for this account -------------------
        $myErr = @($allErrors | Where-Object {
                $w = [string](SGet $_ 'where' '')
                ($w -like ('*:' + $a.Name)) -or ($w -like ('*:' + $a.Name + '/*'))
            })
        if ($myErr.Count -gt 0) {
            [void]$Sb.Append('<h4>Export gaps for this account</h4><table class="tight"><thead><tr><th>where</th><th>at</th><th>detail</th></tr></thead><tbody>')
            foreach ($e in $myErr) {
                [void]$Sb.Append('<tr><td class="res">' + (SEnc (SGet $e 'where' '')) + '</td><td class="ev">' + (SEnc (SGet $e 'at' '')) + '</td><td class="ev">' + (SEnc (STrunc ([string](SGet $e 'detail' '')) 300)) + '</td></tr>')
            }
            [void]$Sb.Append('</tbody></table><p class="note">A panel above that reads "not configured" for one of these subjects is really "not readable". They are different conclusions.</p>')
        }
    }

    # ---------------------------------------------------------------------------
    # provenance for the whole tab
    # ---------------------------------------------------------------------------
    [void]$Sb.Append('<h3>Where this came from</h3><div class="card kv">')
    [void]$Sb.Append((SRow 'exported (UTC)' ('<code>' + (SEnc $exportedAt) + '</code>')))
    [void]$Sb.Append((SRow 'exported by' (SEnc $exportedBy)))
    $apiV = [string](SGet (SGet $manifest 'apiVersions') 'Storage' '')
    [void]$Sb.Append((SRow 'Microsoft.Storage api version' $(if ($apiV) { '<code>' + (SEnc $apiV) + '</code>' } else { (SVal 'not recorded' 'unset' '' 'manifest.json .apiVersions is absent in older exports') })))
    [void]$Sb.Append((SRow 'accounts: manifest vs folders' (SVal ([string]$mAccounts + ' counted, ' + $accounts.Count + ' read') $(if ($null -ne $mAccounts -and [int]$mAccounts -ne $accounts.Count) { 'warn' } else { 'ok' }) '' 'manifest.json .counts.storageAccounts vs storage/*/account.json')))
    [void]$Sb.Append((SRow 'shares: manifest vs folders' (SVal ([string]$mShares + ' counted, ' + $totShares + ' read') $(if ($null -ne $mShares -and [int]$mShares -ne $totShares) { 'warn' } else { 'ok' }) '' 'manifest.json .counts.fileShares vs shares.json .shares[]')))
    [void]$Sb.Append((SRow 'metrics lookback' $(if ($metricsSkipped -eq $true) { (SVal 'skipped (-SkipMetrics)' 'unset' '' 'manifest.json .metricsSkipped = true') } else { (SVal ([string]$lookback + ' days') 'na' '' 'manifest.json .metricsLookbackDays') })))
    [void]$Sb.Append((SRow 'file integrity records' $(if ($mFiles.Count -gt 0) { (SVal ([string]$mFiles.Count + ' files with sha256') 'ok' '' 'manifest.json .files[] path, bytes, sha256') } else { (SVal 'none recorded' 'unset' '' 'manifest.json .files[] is empty - this export carries no integrity evidence') })))
    if ($unreadable.Count -gt 0) {
        [void]$Sb.Append((SRow 'unreadable account folders' (SVal ($unreadable -join ', ') 'warn' '' 'storage/<folder>/account.json missing or unparseable')))
    }
    [void]$Sb.Append('</div>')
    [void]$Sb.Append('<p class="note">Folder names are sanitised (<code>storage/&lt;Subscription&gt;__&lt;account&gt;</code>, every character outside the word class becomes an underscore), so a folder name is not a reliable key. Every join above keys on the account resource id from <code>account.json</code>.</p>')

    [void]$Sb.Append('</section>')
}
