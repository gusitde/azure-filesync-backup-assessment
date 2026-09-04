<#
.SYNOPSIS
  Run the tenant policy and governance assessment (AzGovViz) with the parameters this
  deployment already knows, and land its output beside the other reports.

.DESCRIPTION
  The assessor in this repository answers "is this File Sync and Backup estate built well?".
  It says nothing about the tenant around it - policy assignments, RBAC, management group
  structure, locks, Defender coverage. That is a different question with a mature tool already
  answering it, so this does not reinvent one: it wraps AzGovViz, feeds it the subscription and
  tenant from your deployment context, and puts its report next to ours.

  What this adds over running AzGovViz by hand:

    - parameters come from deployment-context.json, so the governance report covers the
      subscription you actually built into rather than whatever your context happened to be
    - the prerequisites are checked first, with the exact fix for each - including the one that
      catches everyone, which is that AzGovViz needs PowerShell 7 while this kit runs on 5.1
    - the output lands in governance/ and is picked up by the wizard's reports option, so the
      two assessments are read together

  IT DOES NOT MODIFY ANYTHING. AzGovViz is read-only, and so is this.

.PARAMETER Context
  deployment-context.json from phase 1. Supplies the subscription and tenant. Optional - pass
  -SubscriptionId and -TenantId instead to assess somewhere this kit did not build.

.PARAMETER ManagementGroupId
  The management group to assess from. Defaults to the tenant root group, whose id is the
  tenant id. You need Reader on it - that is the whole point of the tool, and the most common
  reason a first run returns almost nothing.

.PARAMETER SourcePath
  Where AzGovViz is checked out. If it is not there, it is cloned from -SourceRepo.

.PARAMETER SourceRepo
  The repository to clone when -SourcePath is empty.

.PARAMETER OutputPath
  Where the report goes. Default: governance/ in this repository.

.PARAMETER InstallPowerShell7
  Install PowerShell 7 with winget if it is missing. Off by default: installing a shell is
  your decision, not this script's.

.EXAMPLE
  .\Invoke-AfsGovernanceAssessment.ps1 -Context .\deploy\deployment-context.json -WhatIf

.EXAMPLE
  .\Invoke-AfsGovernanceAssessment.ps1 -Context .\deploy\deployment-context.json

.NOTES
  AzGovViz is Microsoft's Azure Governance Visualizer. It needs PowerShell 7.0.3 or later and
  Reader at the management group scope. This wrapper runs on 5.1 and shells out to 7, because
  the rest of the kit must stay on 5.1 for AzFilesHybrid.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$Context,
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ManagementGroupId,
    [string]$SourcePath,
    [string]$SourceRepo = 'https://github.com/gusitde/azuregovassessment',
    [string]$OutputPath,
    [string]$PwshPath,
    [switch]$InstallPowerShell7,
    [switch]$SkipClone
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deploy\AfsConfig.ps1')
. (Join-Path $PSScriptRoot 'deploy\AfsLog.ps1')
if (-not $env:AFS_LOG_FILE) { Start-AfsLog -Level Verbose -Name 'governance' | Out-Null }
Write-Host ('  log: ' + $env:AFS_LOG_FILE) -ForegroundColor DarkGray

function Write-GovOk   { param([string]$T) Write-AfsLog -Level INFO -Message ("ok: " + $T); Write-Host ("      OK    " + $T) -ForegroundColor Green }
function Write-GovInfo { param([string]$T) Write-Host ("      ..    " + $T) -ForegroundColor DarkGray }
function Write-GovWarn { param([string]$T) Write-AfsLog -Level WARN -Message $T; Write-Host ("      WARN  " + $T) -ForegroundColor Yellow }
function Write-GovSay  { param([string]$T) foreach ($l in ($T -split "`n")) { Write-Host ("            " + $l) -ForegroundColor DarkGray } }

$script:StepNo = 0
$script:StepTotal = 6
function Write-GovStep {
    param([string]$T)
    Write-AfsStepTimer -Label $T
    $script:StepNo++
    Write-AfsLog -Level STEP -Message ('[' + $script:StepNo + '] ' + $T)
    Write-Host ''
    Write-AfsPhaseStrip -Done ($script:StepNo - 1) -Total $script:StepTotal
    Write-Host ("[{0}/{1}] {2}" -f $script:StepNo, $script:StepTotal, $T) -ForegroundColor Cyan
    Write-AfsProgress -Activity 'Governance assessment' -Status $T -Step $script:StepNo -Total $script:StepTotal
}

# ------------------------------------------------------------------ inputs ---

if ($Context) {
    if (-not (Test-Path $Context)) { throw "Deployment context not found: $Context" }
    $ctx = Read-AfsJsonc -Path $Context
    if (-not $SubscriptionId) { $SubscriptionId = [string]$ctx.config.subscriptionId }
    if (-not $TenantId) { $TenantId = [string](Get-AfsProp $ctx.identity 'tenantId' '') }
}
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'governance' }
if (-not $SourcePath) { $SourcePath = Join-Path $PSScriptRoot '.azgovviz' }

Write-Host ''
Write-Host '  Policy and governance assessment (AzGovViz)' -ForegroundColor White
Write-Host ('  subscription : ' + $(if ($SubscriptionId) { $SubscriptionId } else { '(the signed-in default)' }))
Write-Host ('  tenant       : ' + $(if ($TenantId) { $TenantId } else { '(the signed-in default)' }))
Write-Host ('  output       : ' + $OutputPath)

# --------------------------------------------------------------- preflight ---

Write-GovStep 'Preflight'

$acct = Invoke-AfsAz -Args @('account', 'show', '-o', 'json') -AllowFailure
if (-not $acct) { throw 'Not signed in. Run: az login' }
Write-GovOk ('signed in as ' + $acct.user.name)
if (-not $TenantId) { $TenantId = [string]$acct.tenantId }
if (-not $SubscriptionId) { $SubscriptionId = [string]$acct.id }

# The tenant root management group carries the tenant id. Assessing from there is what makes
# the report cover the estate rather than one subscription.
if (-not $ManagementGroupId) { $ManagementGroupId = $TenantId }
Write-GovOk ('assessing from management group ' + $ManagementGroupId)

# PowerShell 7. This is the one that stops people: the kit is 5.1 on purpose (AzFilesHybrid
# will not run anywhere else), and AzGovViz will not run on 5.1 at all.
# Three places, in order: what you passed, a portable copy sitting beside this repository,
# then PATH. The portable copy matters - Windows Server has no winget and an MSI needs
# administrator, but the PowerShell zip needs neither, so a governance run does not have to
# wait on someone with local admin.
$pwsh = $null
if ($PwshPath -and (Test-Path $PwshPath)) { $pwsh = Get-Item $PwshPath }
if (-not $pwsh) {
    $portable = Join-Path $PSScriptRoot '.pwsh7\pwsh.exe'
    if (Test-Path $portable) { $pwsh = Get-Item $portable; Write-GovInfo 'using the portable PowerShell 7 in .pwsh7' }
}
if (-not $pwsh) { $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue }
if (-not $pwsh) {
    Write-GovWarn 'PowerShell 7 is not installed, and AzGovViz needs 7.0.3 or later'
    Write-GovSay @"
This kit runs on Windows PowerShell 5.1 deliberately - AzFilesHybrid, which the
AD DS join uses, does not work on 7. So the two coexist: 5.1 for the kit, 7 for
this one assessment, which is why this script shells out rather than importing.

  winget install --exact --id Microsoft.PowerShell

No winget, or no local administrator? PowerShell 7 also ships as a plain zip that
needs neither - extract it and point at it with -PwshPath, or drop it in .pwsh7
beside this repository and it is found automatically:

  \$r = Invoke-RestMethod https://api.github.com/repos/PowerShell/PowerShell/releases/latest
  \$a = \$r.assets | Where-Object name -like 'PowerShell-*-win-x64.zip' | Select-Object -First 1
  Invoke-WebRequest \$a.browser_download_url -OutFile \$env:TEMP\ps7.zip -UseBasicParsing
  Expand-Archive \$env:TEMP\ps7.zip -DestinationPath .\.pwsh7
"@
    if (-not $InstallPowerShell7) { throw 'PowerShell 7 is required for the governance assessment.' }
    if ($PSCmdlet.ShouldProcess('this machine', 'install PowerShell 7 with winget')) {
        & winget install --exact --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if (-not $pwsh) { throw 'PowerShell 7 still not on PATH. Open a new shell and run this again.' }
    }
}
if ($pwsh) {
    $pwshExe = $(if ($pwsh.PSObject.Properties['Source'] -and $pwsh.Source) { $pwsh.Source } else { $pwsh.FullName })
    $ver = (& $pwshExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') 2>$null
    if ($ver -and [version]($ver -split '-')[0] -lt [version]'7.0.3') {
        throw ("AzGovViz needs PowerShell 7.0.3 or later; this machine has $ver.")
    }
    Write-GovOk ('PowerShell ' + $ver + ' at ' + $pwshExe)
}

# Reader at the management group scope. Without it the run completes and reports almost
# nothing, which reads like a broken tool rather than a missing role.
$mgOk = Invoke-AfsAz -Args @('account', 'management-group', 'show', '-n', $ManagementGroupId, '--query', 'name', '-o', 'tsv') -AllowFailure
if ($mgOk) {
    Write-GovOk ('management group ' + $ManagementGroupId + ' is readable')
} else {
    Write-GovWarn ('cannot read management group ' + $ManagementGroupId)
    Write-GovSay @"
AzGovViz walks the hierarchy from there, so without Reader on it the report comes
back nearly empty - which looks like a broken tool rather than a missing role.

  az role assignment create --assignee $($acct.user.name) --role Reader --scope /providers/Microsoft.Management/managementGroups/$ManagementGroupId

Granting Reader at the tenant root also needs your account to be elevated once
(Entra ID > Properties > Access management for Azure resources).
"@
}

# ------------------------------------------------------------------ source ---

Write-GovStep 'AzGovViz source'

$entry = Join-Path $SourcePath 'pwsh\AzGovVizParallel.ps1'
if (Test-Path $entry) {
    Write-GovOk ('found at ' + $SourcePath)
} elseif ($SkipClone) {
    throw "AzGovViz was not found at $SourcePath and -SkipClone was given."
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is needed to fetch AzGovViz, or pass -SourcePath to an existing checkout.' }
    if ($PSCmdlet.ShouldProcess($SourceRepo, ('clone into ' + $SourcePath))) {
        Write-GovInfo ('cloning ' + $SourceRepo)
        # git writes ordinary progress ("Cloning into ...") to stderr, and with
        # ErrorActionPreference Stop PowerShell turns any native stderr into a TERMINATING
        # error - so a perfectly good clone throws. Relax it around the call and judge the
        # result by the exit code, exactly as Invoke-AfsAz does for the Azure CLI.
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $gitOut = & git clone --depth 1 $SourceRepo $SourcePath 2>&1
            $gitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prevEap }
        foreach ($line in $gitOut) { if ("$line".Trim()) { Write-AfsLog -Level DEBUG -Message ('git  ' + $line) } }
        if ($gitCode -ne 0) { throw ("git clone failed (exit $gitCode): " + (($gitOut | Out-String).Trim())) }
        if (-not (Test-Path $entry)) { throw "Cloned, but $entry is not there. Check -SourceRepo." }
        Write-GovOk 'cloned'
    }
}
if (Test-Path $entry) {
    $product = (Select-String -Path $entry -Pattern "^\s*\`$ProductVersion\s*=\s*'([^']+)'" | Select-Object -First 1)
    if ($product) { Write-GovOk ('AzGovViz ' + $product.Matches[0].Groups[1].Value) }
}

# ------------------------------------------------------------ modules in 7 ---

Write-GovStep 'Modules inside PowerShell 7'
Write-GovSay @"
PowerShell 7 keeps its own module path, so a portable copy starts with nothing -
and AzGovViz PROMPTS when AzAPICall is missing. With no console to answer, that
prompt loops forever and the run never starts, silently.
"@

$modScript = @'
$ErrorActionPreference = 'Stop'
$want = @( @{ Name = 'AzAPICall'; Version = $env:AFS_AZAPICALL_VERSION }, @{ Name = 'Az.Accounts'; Version = $null } )
foreach ($m in $want) {
    $have = Get-Module -ListAvailable -Name $m.Name
    if ($m.Version) { $have = $have | Where-Object { $_.Version.ToString() -eq $m.Version } }
    if ($have) { "present  $($m.Name) $(($have | Select-Object -First 1).Version)"; continue }
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    if ($m.Version) { Install-Module -Name $m.Name -RequiredVersion $m.Version -Scope CurrentUser -Force -AllowClobber }
    else { Install-Module -Name $m.Name -Scope CurrentUser -Force -AllowClobber }
    "installed $($m.Name)"
}
'@

# the version AzGovViz asks for, read from the script rather than guessed
$azApiVer = '1.4.1'
$m = Select-String -Path $entry -Pattern "\`$AzAPICallVersion\s*=\s*'([^']+)'" | Select-Object -First 1
if ($m) { $azApiVer = $m.Matches[0].Groups[1].Value }
Write-GovInfo ('AzGovViz wants AzAPICall ' + $azApiVer)

if ($PSCmdlet.ShouldProcess('PowerShell 7', ('ensure AzAPICall ' + $azApiVer + ' and Az.Accounts'))) {
    $env:AFS_AZAPICALL_VERSION = $azApiVer
    $modFile = Join-Path ([IO.Path]::GetTempPath()) 'afs-gov-modules.ps1'
    [System.IO.File]::WriteAllText($modFile, $modScript, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $out = & $pwshExe -NoProfile -File $modFile 2>&1
        foreach ($line in $out) { if ("$line".Trim()) { Write-GovOk ("$line".Trim()) } }
    } finally { Remove-Item $modFile -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------------- run ---

Write-GovStep 'Run the assessment'
Write-GovSay 'Read-only. It walks the management group hierarchy, so it takes a while on a large tenant.'

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# Mark the moment, so the collect step can tell what THIS run produced from what was
# already sitting in the folder. Without it a what-if reports yesterday's files as its
# own output - and, more seriously, so does a real run whose assessment produced nothing.
$runStartedAt = Get-Date

$govArgs = @(
    '-NoProfile', '-File', $entry,
    '-ManagementGroupId', $ManagementGroupId,
    '-OutputPath', $OutputPath,
    '-SubscriptionId4AzContext', $SubscriptionId,
    '-TenantId4AzContext', $TenantId
)
Write-GovInfo ('pwsh ' + (($govArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '))

if ($PSCmdlet.ShouldProcess($ManagementGroupId, 'run the governance assessment')) {
    if (-not $pwshExe) { throw 'PowerShell 7 is not available.' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $pwshExe @govArgs
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-AfsLog -Level INFO -Message ('AzGovViz exit ' + $code + ' in ' + [int]$sw.Elapsed.TotalSeconds + ' s')
    if ($code -ne 0) { throw ("AzGovViz exited with code $code. The log is $env:AFS_LOG_FILE.") }
    Write-GovOk ('finished in ' + [int]$sw.Elapsed.TotalSeconds + ' seconds')
}

# ---------------------------------------------------------------- collect ----

Write-GovStep 'Collect the output'

$all = @()
if (Test-Path $OutputPath) {
    $all = @(Get-ChildItem $OutputPath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.html', '.md', '.csv', '.json') } | Sort-Object LastWriteTime -Descending)
}
# Only files written since this run began are this run's output. Everything else is a
# leftover, and calling it "OK" would report a previous assessment as though it were current.
$produced = @($all | Where-Object { $_.LastWriteTime -ge $runStartedAt })
$leftover = @($all | Where-Object { $_.LastWriteTime -lt $runStartedAt })

if ($produced.Count) {
    foreach ($f in ($produced | Select-Object -First 8)) {
        Write-GovOk ($f.Name + '  (' + [math]::Round($f.Length / 1KB) + ' KB)')
    }
    if ($produced.Count -gt 8) { Write-GovInfo ('and ' + ($produced.Count - 8) + ' more') }
} elseif ($WhatIfPreference) {
    Write-GovInfo 'nothing was written - this was a what-if.'
    if ($leftover.Count) {
        Write-GovInfo ('the folder already holds ' + $leftover.Count + ' file(s) from a previous run, newest ' +
                       $leftover[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ' - they are NOT from this run')
    }
} else {
    Write-GovWarn 'this run produced no output files - check the log before trusting anything in that folder.'
    if ($leftover.Count) {
        Write-GovWarn ('what is there is older: ' + $leftover.Count + ' file(s), newest ' +
                       $leftover[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm') + '. Do not read it as current.')
    }
}

# ----------------------------------------------------------------- report ----

Write-GovStep 'Where it fits'

Complete-AfsProgress -Activity 'Governance assessment'
Write-AfsRunSummary -Outcome $(if ($WhatIfPreference) { 'what-if' } else { 'assessed' })
Write-Host ''
Write-AfsPhaseStrip -Done $script:StepTotal -Total $script:StepTotal
Write-Host '======================================' -ForegroundColor White
Write-Host $(if ($WhatIfPreference) { 'WHAT-IF complete. Nothing was run.' } else { 'Governance assessment complete.' }) -ForegroundColor Green
Write-Host ''
Write-Host 'Two reports, two questions:' -ForegroundColor White
Write-Host '  assessment.html   is this File Sync and Backup estate built well?'
Write-Host '  AzGovViz output   is the tenant around it governed well - policy, RBAC, locks,'
Write-Host '                    management group structure, Defender coverage?'
Write-Host ''
Write-Host 'The wizard lists both under its reports option.'
Write-Host ''
Write-Host ('Output: ' + $OutputPath)

Stop-AfsLog -Outcome 'governance assessment ended'
