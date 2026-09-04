#Requires -Version 5.1
<#
  tests/run-tests.ps1 - proves the assessor against the synthetic fixture.
  Every deliberate defect in fixtures/make-fixture.py maps to a rule id; this script asserts
  the expected ids fire, the not-expected ids stay silent, and the private-routing switch
  adds exactly the NET-05.. checks. Exit code 0 = all green.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$assess = Join-Path $repo 'Assess-AzFileSyncExport.ps1'
$fixture = Join-Path $repo 'fixtures\sample-export'
if (-not (Test-Path (Join-Path $fixture 'manifest.json'))) { throw "fixture missing - run: python fixtures/make-fixture.py" }
$tmp = Join-Path $env:TEMP ("afs-tests-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$fail = 0
$total = 0
function Check([bool]$ok, [string]$what) { $script:total++; if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:fail++ } }

# -- 1. catalog --------------------------------------------------------------------------
Write-Host '1. rule catalog'
$cat = & $assess -ListRules
$ids = @([regex]::Matches(($cat -join "`n"), '(?m)^\| ((?:AFS|TIER|SEC|DATA|BKP|NET|MON|OPS|SRV)-\d\d) \|') | ForEach-Object { $_.Groups[1].Value })
Check ($ids.Count -ge 80) "catalog lists $($ids.Count) rules (>= 80)"
Check (($ids | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'rule ids are unique'

# -- 2. default mode ----------------------------------------------------------------------
Write-Host '2. default assessment on the fixture'
$out1 = Join-Path $tmp 'default'
& $assess -ExportPath $fixture -OutputPath $out1 -CustomerName 'Fixture Contoso' | Out-Null
$f1 = (Get-Content (Join-Path $out1 'findings.json') -Raw | ConvertFrom-Json)
$got = @($f1.findings | ForEach-Object { $_.id } | Select-Object -Unique)
$expected = @('AFS-01', 'AFS-02', 'AFS-03', 'AFS-04', 'AFS-05', 'AFS-06', 'AFS-07', 'AFS-08', 'AFS-09', 'AFS-10', 'AFS-12', 'AFS-15', 'AFS-17', 'AFS-18',
  'TIER-01', 'TIER-02', 'TIER-03', 'TIER-04', 'TIER-05', 'TIER-06',
  'SEC-02', 'SEC-03', 'SEC-04', 'SEC-06', 'SEC-07', 'SEC-08', 'SEC-09', 'SEC-10', 'SEC-11', 'SEC-13', 'SEC-14',
  'DATA-01', 'DATA-02', 'DATA-03', 'DATA-05', 'DATA-06',
  'BKP-01', 'BKP-02', 'BKP-03', 'BKP-04', 'BKP-05', 'BKP-06', 'BKP-07', 'BKP-08', 'BKP-09', 'BKP-11', 'BKP-12', 'BKP-13', 'BKP-16', 'BKP-17', 'BKP-19',
  'NET-01', 'MON-01', 'MON-02', 'MON-03', 'OPS-01', 'OPS-03',
  'SRV-02', 'SRV-03', 'SRV-04', 'SRV-06', 'SRV-07', 'SRV-08', 'SRV-09', 'SRV-11')
$notExpected = @('AFS-11', 'AFS-13', 'AFS-14', 'AFS-16', 'AFS-19', 'SEC-01', 'SEC-05', 'SEC-12', 'SEC-15', 'DATA-04', 'DATA-07', 'BKP-10', 'BKP-14', 'BKP-15', 'BKP-18',
  'NET-02', 'NET-03', 'NET-04', 'NET-05', 'NET-06', 'NET-07', 'NET-08', 'NET-09', 'NET-10', 'NET-11', 'OPS-02', 'SRV-01', 'SRV-05', 'SRV-10')
foreach ($id in $expected) { Check ($got -contains $id) "fires $id" }
foreach ($id in $notExpected) { Check (-not ($got -contains $id)) "silent $id" }
$net01 = @($f1.findings | Where-Object { $_.id -eq 'NET-01' })[0]
Check ($net01.severity -eq 'Info') 'NET-01 is Info without -PrivateTrafficRequired'
$bkp01 = @($f1.findings | Where-Object { $_.id -eq 'BKP-01' })
Check ($bkp01.Count -eq 3) "BKP-01 fires for the 3 unprotected shares (got $($bkp01.Count))"
Check (@($bkp01 | Where-Object { $_.resource -eq 'stcontosofiles01/home-drives' -and $_.evidence -like '*Azure File Sync cloud endpoint*' }).Count -eq 1) 'BKP-01 flags the File Sync cloud endpoint share explicitly'
$d3 = @($f1.findings | Where-Object { $_.id -eq 'DATA-03' -and $_.resource -eq 'stcontosofiles01/home-drives' })[0]
Check ($d3.severity -eq 'High') 'DATA-03 is High at 96 % usage'
$a5 = @($f1.findings | Where-Object { $_.id -eq 'AFS-05' })
Check ((@($a5 | Where-Object { $_.resource -like '*FS02*' -and $_.severity -eq 'High' }).Count -eq 1) -and (@($a5 | Where-Object { $_.resource -like '*FS01*' -and $_.severity -eq 'Medium' }).Count -eq 1)) 'AFS-05: FS02 expired = High, FS01 expiring = Medium'
Check ((@($f1.findings | Where-Object { $_.id -eq 'OPS-03' }).Count -eq 2)) 'OPS-03 for the two servers without a bundle (FS02, FS03)'
Check ((Test-Path (Join-Path $out1 'assessment.md')) -and ((Get-Content (Join-Path $out1 'assessment.md') -Raw) -match '## High findings')) 'assessment.md written with a High section'

# -- 3. private routing mode -----------------------------------------------------------------
Write-Host '3. assessment with -PrivateTrafficRequired'
$out2 = Join-Path $tmp 'private'
& $assess -ExportPath $fixture -OutputPath $out2 -CustomerName 'Fixture Contoso' -PrivateTrafficRequired | Out-Null
$f2 = (Get-Content (Join-Path $out2 'findings.json') -Raw | ConvertFrom-Json)
$got2 = @($f2.findings | ForEach-Object { $_.id } | Select-Object -Unique)
foreach ($id in @('NET-05', 'NET-06', 'NET-09', 'NET-10', 'NET-11')) { Check ($got2 -contains $id) "private mode fires $id" }
foreach ($id in @('NET-07', 'NET-08')) { Check (-not ($got2 -contains $id)) "private mode silent $id (no private endpoint yet)" }
$net01b = @($f2.findings | Where-Object { $_.id -eq 'NET-01' })[0]
Check ($net01b.severity -eq 'High') 'NET-01 escalates to High with -PrivateTrafficRequired'

# -- 4. zip input --------------------------------------------------------------------------
Write-Host '4. zip input'
$zip = Join-Path $tmp 'fixture.zip'
Compress-Archive -Path (Join-Path $fixture '*') -DestinationPath $zip -Force
$out3 = Join-Path $tmp 'zip'
& $assess -ExportPath $zip -OutputPath $out3 | Out-Null
$f3 = (Get-Content (Join-Path $out3 'findings.json') -Raw | ConvertFrom-Json)
Check ($f3.counts.High -eq $f1.counts.High -and $f3.counts.Medium -eq $f1.counts.Medium) 'zip and folder inputs give identical counts'


# -- 5. the how-to guide ---------------------------------------------------------------------
# A guide that has drifted from the tool teaches the wrong thing confidently, which is worse
# than no guide. These checks are cheap and they are the ones that catch drift.
Write-Host '5. how-to guide'
$guide = Join-Path $repo 'docs\HOW-TO-USE.html'
Check (Test-Path $guide) 'docs/HOW-TO-USE.html ships with the kit'
if (Test-Path $guide) {
    $h = Get-Content $guide -Raw
    $wiz = Get-Content (Join-Path $repo 'start.ps1') -Raw

    # the wizard can actually open it
    Check ($wiz -like '*How to use it - the full guide*') 'the wizard menu offers it'
    Check ($wiz -like '*function Invoke-HowToUseFlow*')   'the flow behind the menu entry exists'

    # every tab button has a section, and the wizard names only sections that exist
    $tabs = @([regex]::Matches($h, 'data-tab="([a-z]+)"')     | ForEach-Object { $_.Groups[1].Value })
    $secs = @([regex]::Matches($h, 'id="tab-([a-z]+)"')       | ForEach-Object { $_.Groups[1].Value })
    Check ($tabs.Count -eq 10) "the guide has 10 tabs (got $($tabs.Count))"
    Check (@($tabs | Where-Object { $secs -notcontains $_ }).Count -eq 0) 'every tab button has a section behind it'
    $flow = $wiz.Substring($wiz.IndexOf('function Invoke-HowToUseFlow'))
    $flow = $flow.Substring(0, $flow.IndexOf('function Invoke-DocsFlow'))
    $wizIds = @([regex]::Matches($flow, "id = '([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })
    Check ($wizIds.Count -eq $secs.Count) "the wizard lists every section ($($wizIds.Count) of $($secs.Count))"
    Check (@($wizIds | Where-Object { $secs -notcontains $_ }).Count -eq 0) 'every section the wizard offers exists in the page'

    # it has to render on a machine with no network - that is the point of a handover document
    $ext = @([regex]::Matches($h, '(?:src|href)="(?!#)([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    Check ($ext.Count -eq 0) "no external asset is fetched (found: $($ext -join ', '))"

    # the diagrams are the first thing an edit breaks
    Check (([regex]::Matches($h, '<svg')).Count -eq ([regex]::Matches($h, '</svg>')).Count) 'every <svg> is closed'
    Check (([regex]::Matches($h, '<svg')).Count -eq 4) 'all four diagrams are present'
    Check (([regex]::Matches($h, '<marker id="')).Count -eq (@([regex]::Matches($h, '<marker id="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique).Count)) 'arrowhead marker ids are unique across diagrams'
}

# -- 5b. splatting ---------------------------------------------------------------------------
# Splatting an ARRAY binds positionally, so @('-Context', $p) puts the literal '-Context' into
# the first parameter. Two wizard flows shipped with that defect and nothing caught it, because
# neither was exercised end to end. This is the cheap static check that would have.
Write-Host '5b. splatting'
$wizSrc = Get-Content (Join-Path $repo 'start.ps1') -Raw
$perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($wizSrc, [ref]$null, [ref]$perr)
# every variable that is splatted somewhere in the file
$splatted = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Splatted }, $true) |
              ForEach-Object { $_.VariablePath.UserPath } | Select-Object -Unique)
$bad = @()
foreach ($name in $splatted) {
    # find its assignments; flag any that assign an ARRAY containing a '-Switch' looking string
    $assigns = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $name }, $true))
    foreach ($a in $assigns) {
        $t = $a.Right.Extent.Text
        if ($t -match '^\s*@\(' -and $t -match "'-[A-Za-z]") { $bad += ($name + ' = ' + $t) }
    }
}
Check ($bad.Count -eq 0) "no splatted variable is built as an array of switch names$(if ($bad.Count) { ' -> ' + ($bad -join '; ') })"
Check ($splatted -notcontains 'args') 'nothing splats $args (an automatic variable)'

# -- 6. the wizard still parses ----------------------------------------------------------------
Write-Host '6. wizard'
$perr = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'start.ps1'), [ref]$null, [ref]$perr)
Check (-not ($perr -and $perr.Count)) "start.ps1 parses clean$(if ($perr -and $perr.Count) { ' - line ' + $perr[0].Extent.StartLineNumber + ': ' + $perr[0].Message })"

Write-Host ''
if ($fail -eq 0) { Write-Host "ALL GREEN ($total checks)" -ForegroundColor Green } else { Write-Host "$fail check(s) FAILED" -ForegroundColor Red }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit $fail
