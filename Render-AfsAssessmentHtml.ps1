<#
.SYNOPSIS
  Render findings.json into a self-contained, tabbed HTML report.

.DESCRIPTION
  One file, assessment.html, no external assets - it opens from a file share, an email
  attachment or a USB stick, and prints every tab in order. Same visual language as the
  governance dashboard, so the two reports read as one family.

  Tabs (one per page):
    Overview     scorecard by severity, area matrix, the High findings up front
    Findings     every finding, filterable by severity and area, with evidence,
                 recommendation and the Microsoft reference
    Roadmap      do now / this engagement / backlog, derived from severity
    Scope        what was in the export and when it was assessed
    Rules        the rule catalog, when the assessor was run with -IncludeCatalog
    About        how to read the report, and what it is not

  This file is a function library - dot-source it, then call the renderer:

      . .\Render-AfsAssessmentHtml.ps1
      ConvertTo-AfsAssessmentHtml -FindingsPath .\assessment-latest\findings.json

  It deliberately has NO param block: a dot-sourced script binds its parameters in the
  CALLER's scope, and an earlier version silently blanked the assessor's $OutputPath that way
  (assessment.html was then "not produced: parameter 'Path' is an empty string").

  ConvertTo-AfsAssessmentHtml parameters:
    -FindingsPath   the findings.json written by Assess-AzFileSyncExport.ps1
    -OutputPath     where to write the HTML (default: assessment.html next to the findings)
    -SummaryPath    optional summary.md from the export, shown on the Scope tab
    -RulesPath      optional rule catalog (markdown) shown on the Rules tab

.NOTES
  ASCII-only source. Every value from findings is HTML-encoded before it is written.
#>
Set-StrictMode -Version 2.0

function ConvertTo-AfsHtmlFromMarkdown {
    <# A deliberately small markdown renderer: headings, tables, bullets, code spans, bold,
       links. Enough for summary.md and the rule catalog without a dependency. #>
    param([string]$Markdown)
    $enc = [System.Net.WebUtility]
    $out = New-Object System.Text.StringBuilder
    $inTable = $false; $inList = $false
    foreach ($raw in ($Markdown -split "`r?`n")) {
        $line = $raw
        if ($inTable -and $line -notmatch '^\s*\|') { [void]$out.Append('</tbody></table>'); $inTable = $false }
        if ($inList -and $line -notmatch '^\s*[-*] ') { [void]$out.Append('</ul>'); $inList = $false }
        if ($line -match '^\s*$') { continue }
        $esc = $enc::HtmlEncode($line)
        # inline: code, bold, links
        $esc = [regex]::Replace($esc, '`([^`]+)`', '<code>$1</code>')
        $esc = [regex]::Replace($esc, '\*\*([^*]+)\*\*', '<b>$1</b>')
        $esc = [regex]::Replace($esc, '\[([^\]]+)\]\((https?://[^)]+)\)', '<a href="$2" target="_blank" rel="noopener">$1</a>')
        if ($line -match '^(#{1,4})\s+(.*)$') {
            $lvl = [Math]::Min(4, $Matches[1].Length + 1)
            $text = [regex]::Replace($esc, '^#{1,4}\s+', '')
            [void]$out.Append("<h$lvl>$text</h$lvl>"); continue
        }
        if ($line -match '^\s*\|') {
            if ($line -match '^\s*\|\s*-{2,}') { continue }   # separator row
            $cells = ($esc.Trim() -replace '^\|', '' -replace '\|$', '') -split '\|'
            if (-not $inTable) {
                [void]$out.Append('<table><thead><tr>')
                foreach ($c in $cells) { [void]$out.Append("<th>$($c.Trim())</th>") }
                [void]$out.Append('</tr></thead><tbody>'); $inTable = $true
            } else {
                [void]$out.Append('<tr>')
                foreach ($c in $cells) { [void]$out.Append("<td>$($c.Trim())</td>") }
                [void]$out.Append('</tr>')
            }
            continue
        }
        if ($line -match '^\s*[-*] (.*)$') {
            if (-not $inList) { [void]$out.Append('<ul>'); $inList = $true }
            [void]$out.Append("<li>$([regex]::Replace($esc, '^\s*[-*] ', ''))</li>"); continue
        }
        [void]$out.Append("<p>$esc</p>")
    }
    if ($inTable) { [void]$out.Append('</tbody></table>') }
    if ($inList) { [void]$out.Append('</ul>') }
    return $out.ToString()
}

# The subject tabs. Each renderer lives in its own file under render\ and emits exactly one
# <section class="tab">. They are additive: a report produced without an export root simply
# omits them, and adding a subject means dropping in a file and adding a row here.
# One file each because these are large - the estate has a lot to say - and because a failure
# in one is then trivially isolated from the rest.
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'render') -Filter 'AfsTab-*.ps1' -File -ErrorAction SilentlyContinue)) {
    try { . $f.FullName } catch { Write-Warning ('subject tab not loaded: ' + $f.Name + ' - ' + $_.Exception.Message) }
}

# Order is the order a reviewer reads an estate in: what is stored, how it syncs, how it is
# protected, how it is reached, what runs it, what guards it, and where the evidence came from.
$script:AfsDataTabs = @(
    @{ id = 'storage';    t = 'Storage';    fn = 'Add-AfsTabStorage' },
    @{ id = 'filesync';   t = 'File Sync';  fn = 'Add-AfsTabFileSync' },
    @{ id = 'backup';     t = 'Backup';     fn = 'Add-AfsTabBackup' },
    @{ id = 'network';    t = 'Network';    fn = 'Add-AfsTabNetwork' },
    @{ id = 'servers';    t = 'Servers';    fn = 'Add-AfsTabServers' },
    @{ id = 'adjacent';   t = 'Guardrails'; fn = 'Add-AfsTabGuardrails' },
    @{ id = 'provenance'; t = 'Export';     fn = 'Add-AfsTabProvenance' }
)

function ConvertTo-AfsAssessmentHtml {
    param(
        [Parameter(Mandatory)][string]$FindingsPath,
        [string]$OutputPath,
        [string]$SummaryPath,
        [string]$RulesPath,
        [string]$ExportRoot
    )
    if (-not (Test-Path $FindingsPath)) { throw "findings file not found: $FindingsPath" }
    $dir = Split-Path -Parent (Resolve-Path $FindingsPath)
    if (-not $OutputPath) { $OutputPath = Join-Path $dir 'assessment.html' }

    $doc = Get-Content -Path $FindingsPath -Raw | ConvertFrom-Json
    $findings = @($doc.findings)
    $enc = [System.Net.WebUtility]
    function HtmlEnc { param($v) if ($null -eq $v) { return '' } return $enc::HtmlEncode([string]$v) }

    $sevOrder = @('High', 'Medium', 'Low', 'Info')
    $sevClass = @{ High = 'high'; Medium = 'med'; Low = 'low'; Info = 'info' }
    $bySev = @{}
    foreach ($s in $sevOrder) { $bySev[$s] = @($findings | Where-Object { $_.severity -eq $s }).Count }
    $areas = @($findings | ForEach-Object { $_.area } | Sort-Object -Unique)

    $customer = HtmlEnc $doc.customer
    $assessed = HtmlEnc $doc.assessedAtUtc
    $export   = HtmlEnc $doc.export
    $toolv    = HtmlEnc $doc.toolVersion
    $scopeBits = @()
    if ($doc.PSObject.Properties['counts'] -and $doc.counts) {
        foreach ($p in $doc.counts.PSObject.Properties) {
            $scopeBits += [pscustomobject]@{ k = ($p.Name -replace '([a-z])([A-Z])', '$1 $2').ToLower(); v = $p.Value }
        }
    }

    $sb = New-Object System.Text.StringBuilder

    # ---- head and style (single-quoted here-string: nothing is interpolated) ------
    [void]$sb.Append(@'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Azure File Sync + Azure Backup assessment</title>
<style>
:root{--ink:#1b2430;--muted:#5b6673;--faint:#8a95a1;--surface:#ffffff;--surface-2:#f4f6f8;--surface-3:#e9edf1;
--line:#d8dde3;--accent:#0b5cab;--accent-strong:#083f78;--good:#1a7f4b;--good-soft:#e3f3ea;--warn:#b8860b;
--warn-soft:#fff4dc;--crit:#b3261e;--crit-soft:#fbe9e7;--info:#4a6b8a;--info-soft:#e8eff6;--radius:8px}
*{box-sizing:border-box}
body{margin:0;background:var(--surface-2);color:var(--ink);font:14px/1.5 "Segoe UI",system-ui,-apple-system,Arial,sans-serif}
header{background:var(--accent-strong);color:#fff;padding:20px 32px 0}
header h1{margin:0 0 4px;font-size:22px;font-weight:600}
header .meta{color:#cfe0f3;font-size:13px;margin-bottom:14px}
header .meta code{font-family:"IBM Plex Mono",Consolas,monospace;color:#fff}
nav.tabs{display:flex;gap:2px;flex-wrap:wrap}
nav.tabs button{background:rgba(255,255,255,.08);color:#dbe7f3;border:0;border-radius:6px 6px 0 0;padding:9px 16px;cursor:pointer;font-size:13px}
nav.tabs button.active{background:var(--surface-2);color:var(--ink);font-weight:600}
nav.tabs button .n{font-family:"IBM Plex Mono",Consolas,monospace;font-size:11px;opacity:.75;margin-left:6px}
main{max-width:1280px;margin:0 auto;padding:22px 32px}
section.tab{display:none}section.tab.active{display:block}
h2{font-size:16px;margin:22px 0 10px}h2:first-child{margin-top:0}
h3{font-size:14px;margin:18px 0 8px}h4{font-size:13px;margin:14px 0 6px;color:var(--muted)}
p{margin:6px 0}code{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px;background:var(--surface-3);padding:1px 4px;border-radius:3px}
.tiles{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
.tile{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:14px 16px;cursor:pointer}
.tile .n{font-size:30px;font-weight:700;font-family:"IBM Plex Mono",Consolas,monospace;line-height:1}
.tile .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em;margin-top:6px}
.tile.high .n{color:var(--crit)}.tile.med .n{color:var(--warn)}.tile.low .n{color:var(--info)}.tile.info .n{color:var(--muted)}
table{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);overflow:hidden;margin:6px 0 14px}
th,td{padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top;text-align:left}
th{background:var(--surface-3);font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
tr:last-child td{border-bottom:0}
td.num{font-family:"IBM Plex Mono",Consolas,monospace;text-align:right}
.sev{display:inline-block;padding:2px 9px;border-radius:20px;font-size:12px;font-weight:600;white-space:nowrap}
.sev.high{background:var(--crit-soft);color:var(--crit)}.sev.med{background:var(--warn-soft);color:var(--warn)}
.sev.low{background:var(--info-soft);color:var(--info)}.sev.info{background:var(--surface-3);color:var(--muted)}
.id{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px;color:var(--accent);white-space:nowrap}
.res{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px;color:var(--muted);word-break:break-all}
.ev{font-family:"IBM Plex Mono",Consolas,monospace;font-size:12px;color:var(--muted)}
.filters{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:6px 0 12px}
.sevf{border:1px solid var(--line);background:var(--surface);border-radius:20px;padding:4px 12px;cursor:pointer;font-size:13px;color:var(--muted)}
.sevf.active{background:var(--accent);color:#fff;border-color:var(--accent)}
select{border:1px solid var(--line);border-radius:6px;padding:4px 8px;background:var(--surface);color:var(--ink)}
.count{color:var(--faint);font-size:12px;margin-left:auto}
a{color:var(--accent)}
.road{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
.road .col{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:12px 14px}
.road h3{margin:0 0 8px;font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
.road ul{margin:0;padding-left:18px}.road li{margin:4px 0}
.card{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:14px 16px;margin:8px 0}
.kv{display:grid;grid-template-columns:220px 1fr;gap:6px 14px}.kv .k{color:var(--muted)}
footer{color:var(--faint);font-size:12px;padding:24px 32px;text-align:center}
@media print{nav.tabs,.filters{display:none}section.tab{display:block!important;page-break-before:always}section.tab:first-of-type{page-break-before:auto}
 header{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
@media(max-width:900px){.tiles,.road{grid-template-columns:1fr 1fr}.kv{grid-template-columns:1fr}}
</style>
</head>
<body>
'@)

    # ---- header + tab bar ------------------------------------------------------
    [void]$sb.Append("<header><h1>Azure File Sync + Azure Backup assessment - $customer</h1>")
    [void]$sb.Append("<div class=`"meta`">Assessed <code>$assessed</code> - export <code>$export</code> - tool v$toolv</div>")
# A subject tab is offered only when its renderer exists AND there is an export to read.
    # Findings say what is wrong; these say what is actually there, which is the evidence.
    $dataTabs = @()
    if ($ExportRoot -and (Test-Path $ExportRoot)) {
        foreach ($d in $script:AfsDataTabs) {
            if (Get-Command $d.fn -ErrorAction SilentlyContinue) { $dataTabs += $d }
        }
    }
    $tabs = @(
        @{ id = 'overview'; t = 'Overview'; n = '' },
        @{ id = 'findings'; t = 'Findings'; n = $findings.Count }
    )
    foreach ($d in $dataTabs) { $tabs += @{ id = $d.id; t = $d.t; n = '' } }
    $tabs += @(
        @{ id = 'roadmap';  t = 'Roadmap';  n = '' },
        @{ id = 'scope';    t = 'Scope';    n = '' },
        @{ id = 'rules';    t = 'Rules';    n = '' },
        @{ id = 'about';    t = 'About';    n = '' }
    )
    [void]$sb.Append("<nav class=`"tabs`">")
    $first = $true
    foreach ($tb in $tabs) {
        $cls = if ($first) { ' class="active"' } else { '' }; $first = $false
        $badge = if ($tb.n -ne '') { "<span class=`"n`">$($tb.n)</span>" } else { '' }
        [void]$sb.Append("<button$cls data-tab=`"$($tb.id)`">$($tb.t)$badge</button>")
    }
    [void]$sb.Append("</nav></header><main>")

    # ---- OVERVIEW --------------------------------------------------------------
    [void]$sb.Append("<section class=`"tab active`" id=`"tab-overview`"><h2>Scorecard</h2><div class=`"tiles`">")
    foreach ($s in $sevOrder) {
        [void]$sb.Append(("<div class=`"tile {0}`" data-goto=`"{2}`"><div class=`"n`">{1}</div><div class=`"l`">{2}</div></div>" -f $sevClass[$s], $bySev[$s], $s))
    }
    [void]$sb.Append("</div><h2>By area</h2><table><thead><tr><th>Area</th>")
    foreach ($s in $sevOrder) { [void]$sb.Append("<th>$s</th>") }
    [void]$sb.Append("<th>Total</th></tr></thead><tbody>")
    foreach ($a in $areas) {
        $row = @($findings | Where-Object { $_.area -eq $a })
        [void]$sb.Append("<tr><td>$(HtmlEnc $a)</td>")
        foreach ($s in $sevOrder) { [void]$sb.Append("<td class=`"num`">$(@($row | Where-Object { $_.severity -eq $s }).Count)</td>") }
        [void]$sb.Append("<td class=`"num`">$($row.Count)</td></tr>")
    }
    [void]$sb.Append("</tbody></table>")
    $highs = @($findings | Where-Object { $_.severity -eq 'High' })
    [void]$sb.Append("<h2>High findings ($($highs.Count))</h2>")
    if ($highs.Count -eq 0) { [void]$sb.Append("<p class=`"card`">No High findings.</p>") }
    foreach ($f in $highs) {
        [void]$sb.Append("<div class=`"card`"><div><span class=`"id`">$(HtmlEnc $f.id)</span> <b>$(HtmlEnc $f.title)</b> <span class=`"res`">$(HtmlEnc $f.resource)</span></div>")
        [void]$sb.Append("<div class=`"ev`">$(HtmlEnc $f.evidence)</div><p>$(HtmlEnc $f.recommendation)")
        if ($f.reference) { [void]$sb.Append(" <a href=`"$(HtmlEnc $f.reference)`" target=`"_blank`" rel=`"noopener`">reference</a>") }
        [void]$sb.Append("</p></div>")
    }
    [void]$sb.Append("</section>")

    # ---- FINDINGS --------------------------------------------------------------
    [void]$sb.Append("<section class=`"tab`" id=`"tab-findings`"><h2>All findings</h2><div class=`"filters`">")
    [void]$sb.Append("<button class=`"sevf active`" data-sev=`"`">All</button>")
    foreach ($s in $sevOrder) { [void]$sb.Append("<button class=`"sevf`" data-sev=`"$s`">$s ($($bySev[$s]))</button>") }
    [void]$sb.Append("<select id=`"area`"><option value=`"`">All areas</option>")
    foreach ($a in $areas) { [void]$sb.Append("<option value=`"$(HtmlEnc $a)`">$(HtmlEnc $a)</option>") }
    [void]$sb.Append("</select><span class=`"count`" id=`"count`"></span></div>")
    [void]$sb.Append("<table id=`"ft`"><thead><tr><th>ID</th><th>Area</th><th>Severity</th><th>Resource</th><th>Finding</th><th>Evidence</th><th>Recommendation</th><th>Ref</th></tr></thead><tbody>")
    foreach ($f in $findings) {
        $sc = $sevClass[[string]$f.severity]; if (-not $sc) { $sc = 'info' }
        $ref = ''
        if ($f.reference) { $ref = "<a href=`"$(HtmlEnc $f.reference)`" target=`"_blank`" rel=`"noopener`">learn</a>" }
        [void]$sb.Append(("<tr data-sev=`"{0}`" data-area=`"{1}`"><td class=`"id`">{2}</td><td>{1}</td><td><span class=`"sev {3}`">{0}</span></td><td class=`"res`">{4}</td><td>{5}</td><td class=`"ev`">{6}</td><td>{7}</td><td>{8}</td></tr>" -f `
            (HtmlEnc $f.severity), (HtmlEnc $f.area), (HtmlEnc $f.id), $sc, (HtmlEnc $f.resource), (HtmlEnc $f.title), (HtmlEnc $f.evidence), (HtmlEnc $f.recommendation), $ref))
    }
    [void]$sb.Append("</tbody></table></section>")

    # ---- SUBJECT TABS ----------------------------------------------------------
    # Each renderer owns one section and must not throw: a subject whose renderer fails still
    # leaves a readable report, with the failure stated in place rather than a blank tab.
    foreach ($d in $dataTabs) {
        try {
            & $d.fn -Sb $sb -ExportRoot $ExportRoot
        } catch {
            $why = [System.Net.WebUtility]::HtmlEncode([string]$_.Exception.Message)
            [void]$sb.Append("<section class=`"tab`" id=`"tab-$($d.id)`"><h2>$($d.t)</h2>")
            [void]$sb.Append("<div class=`"card`"><p>This section could not be rendered from the export: <code>$why</code></p>")
            [void]$sb.Append("<p>The rest of the report is unaffected. The raw data is in the export itself.</p></div></section>")
        }
    }

    # ---- ROADMAP ---------------------------------------------------------------
    [void]$sb.Append("<section class=`"tab`" id=`"tab-roadmap`"><h2>Roadmap</h2><p>Derived from severity: High is a gap that exposes data or blocks recovery today; Medium is a control that should be in place before the engagement closes; Low and Info are hygiene and follow-ups.</p><div class=`"road`">")
    $lanes = @(
        @{ t = 'Do now';          sev = @('High') },
        @{ t = 'This engagement'; sev = @('Medium') },
        @{ t = 'Backlog';         sev = @('Low', 'Info') }
    )
    foreach ($lane in $lanes) {
        [void]$sb.Append("<div class=`"col`"><h3>$($lane.t)</h3><ul>")
        $items = @($findings | Where-Object { $lane.sev -contains $_.severity })
        if ($items.Count -eq 0) { [void]$sb.Append("<li>none</li>") }
        foreach ($f in $items) { [void]$sb.Append("<li><span class=`"id`">$(HtmlEnc $f.id)</span> $(HtmlEnc $f.title) <span class=`"res`">$(HtmlEnc $f.resource)</span></li>") }
        [void]$sb.Append("</ul></div>")
    }
    [void]$sb.Append("</div></section>")

    # ---- SCOPE -----------------------------------------------------------------
    [void]$sb.Append("<section class=`"tab`" id=`"tab-scope`"><h2>Scope</h2><div class=`"card kv`">")
    [void]$sb.Append("<div class=`"k`">Customer</div><div>$customer</div>")
    [void]$sb.Append("<div class=`"k`">Assessed (UTC)</div><div><code>$assessed</code></div>")
    [void]$sb.Append("<div class=`"k`">Export</div><div><code>$export</code></div>")
    foreach ($b in $scopeBits) { [void]$sb.Append("<div class=`"k`">$(HtmlEnc $b.k)</div><div>$(HtmlEnc $b.v)</div>") }
    [void]$sb.Append("</div>")
    if ($SummaryPath -and (Test-Path $SummaryPath)) {
        [void]$sb.Append("<h2>Export summary</h2><div class=`"card`">")
        [void]$sb.Append((ConvertTo-AfsHtmlFromMarkdown -Markdown (Get-Content -Path $SummaryPath -Raw)))
        [void]$sb.Append("</div>")
    } else {
        [void]$sb.Append("<p>The export's summary.md was not supplied, so only the counts are shown here. Pass -SummaryPath to include it.</p>")
    }
    [void]$sb.Append("</section>")

    # ---- RULES -----------------------------------------------------------------
    [void]$sb.Append("<section class=`"tab`" id=`"tab-rules`"><h2>Rule catalog</h2>")
    if ($RulesPath -and (Test-Path $RulesPath)) {
        [void]$sb.Append("<div class=`"card`">" + (ConvertTo-AfsHtmlFromMarkdown -Markdown (Get-Content -Path $RulesPath -Raw)) + "</div>")
    } else {
        [void]$sb.Append("<p>Every finding above names its rule ID. The full catalog - every rule, its check, recommendation and Microsoft reference - is in <code>docs/RULES.md</code>, or run the assessor with <code>-IncludeCatalog</code> to embed it here.</p>")
    }
    [void]$sb.Append("</section>")

    # ---- ABOUT -----------------------------------------------------------------
    [void]$sb.Append(@'
<section class="tab" id="tab-about"><h2>About this report</h2>
<div class="card">
<p><b>What it is.</b> A read-only assessment of an Azure File Sync and Azure Backup estate, produced from an ARM export. Every finding carries the evidence it was made from, a recommendation, and the Microsoft documentation it derives from - so any item can be verified independently.</p>
<p><b>What it is not.</b> It does not change anything, and it does not read data, keys, SAS tokens or certificates. The export made only GET calls.</p>
<p><b>Severity.</b> High: data is exposed or recovery is blocked today. Medium: a control that should be in place before the engagement closes. Low: hygiene. Info: worth knowing, no action required.</p>
<p><b>Three protection surfaces.</b> A migrated VM is protected by Azure Backup for VMs; an Azure file share by Azure Backup for Azure Files; a File Sync server endpoint is a cache and is deliberately not backed up - a file-level agent walking a tiered volume recalls the entire dataset.</p>
<p><b>Traffic that cannot be made private.</b> The Storage Sync Service to storage account leg stays inside Microsoft, and Azure Backup traffic for Azure Files is Azure-internal. The SMB and File Sync paths can be private; those two cannot, and do not need to be.</p>
</div></section>
'@)

    # ---- footer + script -------------------------------------------------------
    [void]$sb.Append("</main><footer>Generated by Assess-AzFileSyncExport v$toolv - read-only assessment; every recommendation carries its Microsoft reference.</footer>")
    [void]$sb.Append(@'
<script>
(function(){
  function show(id){
    document.querySelectorAll('nav.tabs button').forEach(function(b){b.classList.toggle('active',b.dataset.tab===id);});
    document.querySelectorAll('section.tab').forEach(function(s){s.classList.toggle('active',s.id==='tab-'+id);});
    try{history.replaceState(null,'','#'+id);}catch(e){}
  }
  document.querySelectorAll('nav.tabs button').forEach(function(b){b.addEventListener('click',function(){show(b.dataset.tab);});});
  var sev='', area='';
  var rows=document.querySelectorAll('#ft tbody tr');
  var count=document.getElementById('count');
  function apply(){
    var n=0;
    rows.forEach(function(r){var ok=(!sev||r.dataset.sev===sev)&&(!area||r.dataset.area===area);r.style.display=ok?'':'none';if(ok){n++;}});
    if(count){count.textContent=n+' of '+rows.length+' findings';}
    document.querySelectorAll('.sevf').forEach(function(x){x.classList.toggle('active',x.dataset.sev===sev);});
  }
  document.querySelectorAll('.sevf').forEach(function(b){b.addEventListener('click',function(){sev=b.dataset.sev;apply();});});
  var areaSel=document.getElementById('area'); if(areaSel){areaSel.addEventListener('change',function(e){area=e.target.value;apply();});}
  document.querySelectorAll('.tile[data-goto]').forEach(function(t){t.addEventListener('click',function(){sev=t.dataset.goto;show('findings');apply();});});
  var h=(location.hash||'').replace('#',''); if(h&&document.getElementById('tab-'+h)){show(h);}
  apply();
})();
</script>
</body>
</html>
'@)

    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $OutputPath
}