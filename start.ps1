<#
.SYNOPSIS
  Guided start. Asks what you want to do, checks your prerequisites, asks the questions it
  needs, and runs the right scripts in the right order.

.DESCRIPTION
  This is the front door. You should not need to read anything else to get going.

  It never changes anything without telling you first and asking. Every destructive or
  outward-facing step is confirmed, and the build always runs a dry run before the real one.

.EXAMPLE
  .\start.ps1

.NOTES
  Run from PowerShell, not Git Bash. Git Bash rewrites arguments beginning with "/" into
  Windows paths, which corrupts Azure resource IDs.
#>
[CmdletBinding()]
param(
    # How much to record and how chatty the Azure CLI should be. Everything always goes to the
    # log file; this chooses what the console also shows. See deploy/AfsLog.ps1.
    [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')][string]$LogLevel = 'Verbose'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root      = $PSScriptRoot
$script:DeployDir = Join-Path $script:Root 'deploy'
$script:InputsFile = Join-Path $script:DeployDir 'inputs.json'
$script:ContextFile = Join-Path $script:DeployDir 'deployment-context.json'
$script:RepoUrl    = 'https://github.com/gusitde/azure-filesync-backup-assessment'

. (Join-Path $script:DeployDir 'AfsLog.ps1')
. (Join-Path $script:DeployDir 'AfsConfig.ps1')
$script:LogFile = Start-AfsLog -Level $LogLevel -Name 'wizard'

# ------------------------------------------------------------------ ui ------

function Write-Rule { Write-Host ('-' * 74) -ForegroundColor DarkGray }

function Write-Banner {
    if ($Host.UI.RawUI -and -not [Console]::IsOutputRedirected) { Clear-Host }
    Write-Host ''
    Write-Host '  Azure File Sync + Azure Backup' -ForegroundColor White
    Write-Host '  assessment and deployment kit' -ForegroundColor White
    Write-Host ''
    Write-Rule
}

function Write-Title {
    param([string]$Text)
    Write-AfsLog -Level STEP -Message $Text; Write-Host ''
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Rule
}

function Write-Explain {
    param([string]$Text)
    foreach ($line in ($Text -split "`n")) { Write-Host ("  " + $line) -ForegroundColor DarkGray }
}

function Write-Good { param([string]$T) Write-AfsLog -Level INFO -Message ("ok: " + $T); Write-Host ("  [ok]   " + $T) -ForegroundColor Green }
function Write-Bad  { param([string]$T) Write-AfsLog -Level ERROR -Message $T; Write-Host ("  [!]    " + $T) -ForegroundColor Red }
function Write-Note { param([string]$T) Write-AfsLog -Level WARN -Message $T; Write-Host ("  [i]    " + $T) -ForegroundColor Yellow }

function Read-Answer {
    <# Ask one question. Loops until the answer validates, so a typo never lands in a file. #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Why,
        [string]$Default,
        [string]$Pattern,
        [string]$PatternHelp,
        [switch]$AllowEmpty
    )
    $tries = 0
    while ($true) {
        if (++$tries -gt 5) { throw 'No usable answer after several attempts (is input redirected or empty?). Stopping rather than looping.' }
        Write-Host ''
        Write-Host ("  " + $Question) -ForegroundColor White
        if ($Why) { Write-Explain $Why }
        $prompt = if ($Default) { "  > [$Default] " } else { '  > ' }
        Write-Host $prompt -NoNewline -ForegroundColor White
        $answer = Read-Host
        if (-not $answer) { $answer = $Default }
        if (-not $answer) {
            if ($AllowEmpty) { return '' }
            Write-Bad 'an answer is needed here.'
            continue
        }
        if ($Pattern -and $answer -notmatch $Pattern) {
            if ($PatternHelp) { Write-Bad $PatternHelp } else { Write-Bad 'that does not look right.' }
            continue
        }
        Write-AfsLog -Level DEBUG -Message ("answer: " + $Question + " -> " + $answer)
        return $answer
    }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Question, [string]$Why, [bool]$DefaultYes = $true)
    $d = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    $tries = 0
    while ($true) {
        if (++$tries -gt 5) { throw 'No usable answer after several attempts. Stopping rather than looping.' }
        Write-Host ''
        Write-Host ("  " + $Question) -ForegroundColor White
        if ($Why) { Write-Explain $Why }
        Write-Host ("  > [$d] ") -NoNewline -ForegroundColor White
        $a = Read-Host
        if (-not $a) {
            # Enter on a real console means "take the default". With redirected input an empty
            # read is usually end-of-input, and assuming "yes" there once resumed a live build
            # from a scripted test - so a silent answer never confirms anything.
            if ([Console]::IsInputRedirected) { Write-Note 'no answer (input ended) - treating that as no.'; return $false }
            return $DefaultYes
        }
        if ($a -match '^[Yy]') { return $true }
        if ($a -match '^[Nn]') { return $false }
        Write-Bad 'answer y or n.'
    }
}

function Read-Choice {
    param([Parameter(Mandatory)][string]$Question, [Parameter(Mandatory)][string[]]$Options)
    $tries = 0
    while ($true) {
        if (++$tries -gt 5) { throw 'No usable choice after several attempts. Stopping rather than looping.' }
        Write-Host ''
        Write-Host ("  " + $Question) -ForegroundColor White
        Write-Host ''
        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host ("    {0}) {1}" -f ($i + 1), $Options[$i])
        }
        Write-Host ''
        Write-Host '  > ' -NoNewline -ForegroundColor White
        $a = Read-Host
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $Options.Count) {
            Write-AfsLog -Level DEBUG -Message ("choice: " + $Question + " -> " + $Options[[int]$a - 1])
            return ([int]$a - 1)
        }
        Write-Bad ("choose 1 to " + $Options.Count)
    }
}

function Invoke-Cli {
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFailure)
    if ($AllowFailure) { return Invoke-AfsAz -Args $Args -AllowFailure }
    return Invoke-AfsAz -Args $Args
}

function ConvertTo-Array {
    <#  @(Invoke-Cli ...) does NOT flatten: a function returning an Object[] is emitted as a
        single item, so the array subexpression yields one element containing the array. That
        turned a six-subscription menu into one entry with every name concatenated. Normalise
        here instead. #>
    param($Value)
    if ($null -eq $Value) { return @() }
    # the unary comma matters: 'return $array' goes through the pipeline, which unwraps a
    # ONE-element array back to its scalar, and a PSCustomObject has no .Count - the as-built
    # reported the deployment identity's single role as 'not readable' because of exactly that
    if ($Value -is [System.Array]) { return ,$Value }
    return ,@($Value)
}

# -------------------------------------------------------- prerequisites -----

function Test-Prerequisites {
    param([switch]$ForDeploy)
    Write-Title 'Checking what you have'

    $ok = $true

    # PowerShell
    $psv = $PSVersionTable.PSVersion
    Write-Good ("PowerShell " + $psv)

    # Git Bash warning
    if ($env:MSYSTEM) {
        Write-Bad 'you appear to be running under Git Bash / MSYS.'
        Write-Explain "Git Bash rewrites arguments that start with / into Windows paths, which
corrupts Azure resource IDs. Please run this from PowerShell instead."
        return $false
    }

    # Azure CLI
    $v = Invoke-Cli @('version', '-o', 'json') -AllowFailure
    if (-not $v) {
        Write-Bad 'Azure CLI (az) was not found on PATH.'
        Write-Explain "Install it with:  winget install --exact --id Microsoft.AzureCLI
then close and reopen PowerShell so PATH picks it up."
        return $false
    }
    Write-Good ("Azure CLI " + $v.'azure-cli')

    if (-not $ForDeploy) { return $true }

    # dns-resolver extension
    $ext = Invoke-Cli @('extension', 'list', '--query', "[?name=='dns-resolver'].version", '-o', 'tsv') -AllowFailure
    if ($ext) {
        Write-Good ("dns-resolver extension " + $ext)
    } else {
        Write-Note 'the dns-resolver extension is missing.'
        Write-Explain "It is needed for the Azure DNS Private Resolver. Without it, every
az dns-resolver command fails as an unrecognised command group."
        if (Read-YesNo -Question 'Install it now?' -DefaultYes $true) {
            Invoke-Cli @('extension', 'add', '--name', 'dns-resolver', '--only-show-errors') -AllowFailure | Out-Null
            Write-Good 'installed'
        } else {
            Write-Note 'continuing without it - the DNS resolver step will be skipped or fail.'
        }
    }

    return $ok
}

function Get-SignedInAccount {
    return (Invoke-Cli @('account', 'show', '-o', 'json') -AllowFailure)
}

function Ensure-SignedIn {
    param([string]$TenantId)
    Write-Title 'Signing in'

    $acct = Get-SignedInAccount
    if ($acct) {
        Write-Good ("already signed in as " + $acct.user.name)
        if (-not (Read-YesNo -Question 'Use this account?' -DefaultYes $true)) {
            Invoke-Cli @('logout') -AllowFailure | Out-Null
            $acct = $null
        }
    }

    if (-not $acct) {
        Write-Explain "A browser window will open. Complete multi-factor authentication if you
are prompted - that is the whole reason this step exists. Most tenants
refuse every resource-creating call from a session that has not done it."
        Write-Host ''
        Read-Host '  Press Enter to open the browser' | Out-Null
        $args = @('login', '--only-show-errors', '-o', 'json')
        if ($TenantId) { $args += @('--tenant', $TenantId) }
        Invoke-Cli $args -AllowFailure | Out-Null
        $acct = Get-SignedInAccount
        if (-not $acct) { Write-Bad 'sign-in did not complete.'; return $null }
        Write-Good ("signed in as " + $acct.user.name)
    }
    return $acct
}

# ------------------------------------------------------------- questions ----

function New-InputsFile {
    Write-Title 'Four questions'
    Write-Explain "Everything else is worked out from these. You will see the full list of
what will be created before anything happens."

    $acct = Get-SignedInAccount

    # ---- 1. the administrator ----
    Write-Host ''
    Write-Host '  1 of 4 - the administrator' -ForegroundColor Cyan
    $adminUpn = Read-Answer -Question 'Which Entra account will create the deployment identity?' `
        -Why "Used once, by the first phase, to create a service principal and give it
access to one resource group. It is not used again after that.
It needs Application Administrator in Entra ID, and Owner or User
Access Administrator on the subscription." `
        -Default $(if ($acct) { $acct.user.name } else { $null })

    $tenantId = if ($acct) { $acct.tenantId } else {
        Read-Answer -Question 'Tenant id?' -Pattern '^[0-9a-fA-F-]{36}$' -PatternHelp 'that should be a GUID.'
    }

    # ---- 2. where ----
    Write-Host ''
    Write-Host '  2 of 4 - where to build it' -ForegroundColor Cyan

    $subs = ConvertTo-Array (Invoke-Cli @('account', 'list', '--query', "[?state=='Enabled'].{name:name,id:id}", '-o', 'json') -AllowFailure)
    $subId = $null
    if ($subs -and $subs.Count -gt 0) {
        Write-Explain ("These are the subscriptions this account can see (" + $subs.Count + ").")
        $labels = @($subs | ForEach-Object { "$($_.name)   ($($_.id))" })
        $idx = Read-Choice -Question 'Which subscription should the work go into?' -Options $labels
        $subId = $subs[$idx].id

        # make it the active one, so everything after this points at the same place
        $env:AFS_SUBSCRIPTION_ID = $subId   # every az call is pinned to it (see Invoke-AfsAz)
        Invoke-Cli @('account', 'set', '--subscription', $subId) -AllowFailure | Out-Null
        Write-Good ("active subscription: " + $subs[$idx].name)

        # a read here is worth more than a promise later: if the account cannot see the
        # resource groups, it has no Azure role and phase 1 will fail at the first write.
        # 'length(@)' is NOT usable here: on Windows the ')' breaks the az.cmd wrapper and the
        # read fails, which made this probe accuse a perfectly good account of having no
        # access. A provider read needs a real Azure role (Reader or above) and always
        # returns a value when it succeeds, even in an empty subscription.
        $probe = Invoke-Cli @('provider', 'show', '-n', 'Microsoft.Resources', '--subscription', $subId, '--query', 'namespace', '-o', 'tsv') -AllowFailure
        if ($null -eq $probe) {
            Write-Host ''
            Write-Bad 'this account can sign in, but cannot read that subscription.'
            Write-Explain "Being a Global Administrator in Entra ID grants nothing over Azure
resources - directory roles and Azure roles are separate things.
Phase 1 would fail at the first write, so it is better to know now."
            Write-Host ''
            Write-Host '  Check what you hold:' -ForegroundColor White
            Write-Host '    az role assignment list --assignee <your-upn> --all -o table' -ForegroundColor Cyan
            Write-Host ''
            Write-Host '  If that is empty and you are a Global Administrator, elevate once:' -ForegroundColor White
            Write-Host '    az rest --method post --url "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"' -ForegroundColor Cyan
            Write-Host '    az login    # required - the elevation is not in your current token' -ForegroundColor Cyan
            Write-Host ('    az role assignment create --assignee <your-upn> --role Owner --scope /subscriptions/' + $subId) -ForegroundColor Cyan
            Write-Host ''
            if (-not (Read-YesNo -Question 'Carry on anyway and answer the rest?' -DefaultYes $false)) {
                throw 'Stopped before asking anything else. Grant the access above, then start again.'
            }
        } else {
            Write-Good ("access confirmed - " + $probe + " resource group(s) visible")
        }
    } else {
        Write-Note 'no subscriptions were returned for this account.'
        $subId = Read-Answer -Question 'Subscription id?' -Pattern '^[0-9a-fA-F-]{36}$' -PatternHelp 'that should be a GUID.'
    }

    $location = Read-Answer -Question 'Which Azure region?' `
        -Why "Where the storage, sync service and vault are created. Keep the vault in the
same region as the storage account - Azure Files backup requires it." `
        -Default 'eastus' -Pattern '^[a-z0-9]+$' -PatternHelp 'a region short name, like eastus or westeurope.'

    $prefix = Read-Answer -Question 'Short name prefix for everything this builds?' `
        -Why "The one naming decision you make. 2-8 lowercase letters or digits.
'contoso' gives rg-contoso-filesync, stcontosofs01, vnet-contoso-filesync,
rsv-contoso-eastus, and so on." `
        -Pattern '^[a-z0-9]{2,8}$' -PatternHelp '2-8 lowercase letters or digits, no spaces or dashes.'

    # ---- 3. AD admin ----
    Write-Host ''
    Write-Host '  3 of 4 - Active Directory' -ForegroundColor Cyan
    Write-Explain "Azure file shares can use your existing AD accounts and NTFS permissions.
That needs the storage account joined to your domain. You can skip this
now and do it later from a domain-joined machine."

    $doAd = Read-YesNo -Question 'Configure the AD DS domain join?' -DefaultYes $false `
        -Why "Say no for a first run. The storage side comes up on its own, and you can
turn this on afterwards once you are on a domain-joined machine with the
AzFilesHybrid module."

    $adAdmin = 'not-configured'; $domain = ''; $netbios = ''; $ou = ''
    if ($doAd) {
        $domain = Read-Answer -Question 'AD domain FQDN?' -Default 'corp.example.com' `
            -Pattern '^[A-Za-z0-9.-]+$' -PatternHelp 'something like corp.example.com'
        $netbios = Read-Answer -Question 'NetBIOS (short) domain name?' `
            -Default ($domain.Split('.')[0].ToUpper()) -Pattern '^[A-Za-z0-9-]+$'
        $ou = Read-Answer -Question 'Distinguished name of the OU for the storage account identity?' `
            -Why "A dedicated OU, not the default Computers container, so the object can be
found, audited and delegated. It must already exist." `
            -Default ("OU=AzureFiles,OU=Servers," + (($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','))
        $adAdmin = Read-Answer -Question 'Which AD account will perform the join?' `
            -Why "It needs permission to create an object in that OU. It does NOT need
Domain Admin, and asking for Domain Admin here is a common over-reach.
You will be prompted for the password when the join runs." `
            -Default ("administrator@" + $domain)
    }

    # ---- 4. retention ----
    Write-Host ''
    Write-Host '  4 of 4 - backup retention' -ForegroundColor Cyan
    $retention = Read-Answer -Question 'How many days should daily backups be kept?' `
        -Why "This comes from your records-retention obligation, not from a product default.
Single-file restore comes from the snapshot tier, which allows up to 200 days." `
        -Default '60' -Pattern '^\d{1,3}$' -PatternHelp 'a number of days, 1 to 200.'

    # ---- write it ----
    $inputs = [ordered]@{
        entraGlobalAdmin     = [ordered]@{ userPrincipalName = $adminUpn; tenantId = $tenantId }
        azure                = [ordered]@{ subscriptionId = $subId; location = $location; namePrefix = $prefix; uniqueSuffix = '01' }
        activeDirectoryAdmin = [ordered]@{ userPrincipalName = $adAdmin; passwordSource = 'prompt' }
        activeDirectory      = [ordered]@{
            domainFqdn = $domain; netBiosName = $netbios
            organizationalUnitDistinguishedName = $ou
            identityObjectType = 'ComputerAccount'; domainControllerOrSite = ''
        }
        overrides            = [ordered]@{ enableAdDsJoin = $doAd; backupDailyRetentionDays = [int]$retention }
    }

    if (Test-Path $script:InputsFile) {
        Write-Host ''
        Write-Note "$script:InputsFile already exists."
        if (-not (Read-YesNo -Question 'Overwrite it?' -DefaultYes $false)) {
            Write-Note 'keeping the existing file.'
            return
        }
    }
    $inputs | ConvertTo-Json -Depth 6 | Set-Content -Path $script:InputsFile -Encoding ascii
    Write-Host ''
    Write-Good ("saved " + $script:InputsFile)
}

# ----------------------------------------------------------------- flows ----

function Invoke-Phase2WithRetry {
    <# Run phase 2 from the context; on failure explain it and offer to run again. The build is
       idempotent - everything already created is found and skipped - so a retry continues from
       the failed step rather than starting over. #>
    param([int]$MaxAttempts = 5)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Push-Location $script:DeployDir
        $failed = $false
        try {
            & (Join-Path $script:DeployDir 'Deploy-AfsEnvironment.ps1') -Context $script:ContextFile
        } catch {
            $failed = $true
            Write-AfsLogException -ErrorRecord $_ -Context ("phase 2 attempt " + $attempt + " failed")
            Show-AzureFailure -Message $_.Exception.Message -Context ("Phase 2 stopped (attempt " + $attempt + " of " + $MaxAttempts + ").")
        } finally { Pop-Location }
        if (-not $failed) { return $true }
        if ($attempt -ge $MaxAttempts) { Write-Bad 'giving up after repeated failures. Fix the cause above, then choose Resume from the menu.'; return $false }
        Write-Explain "The build is idempotent: everything already created is found and skipped, so a
retry continues from the step that failed. If the fix above needs you to do
something first (sign in again, register a provider), do it now, then answer yes."
        if (-not (Read-YesNo -Question 'Retry phase 2 now?' -DefaultYes $true)) {
            Write-Note 'stopped. Choose Resume the last build from the menu when you are ready.'
            return $false
        }
        Write-Title ("Phase 2 - retry " + ($attempt + 1))
    }
    return $false
}

function Invoke-ResumeFlow {
    <# Menu entry: pick up a build that crashed or was interrupted, from its saved context. #>
    if (-not (Test-Prerequisites -ForDeploy)) { return }
    if (-not (Test-Path $script:ContextFile)) {
        Write-Bad 'no deployment context found - there is nothing to resume. Run a build first.'
        return
    }
    $ctx = Read-AfsJsonc -Path $script:ContextFile
    Write-Title 'Resume the last build'
    Write-Host ("  context   : " + $script:ContextFile)
    Write-Host ("  target    : " + $ctx.config.resourceGroup + " in " + $ctx.config.subscriptionId)
    Write-Host ("  identity  : " + $ctx.identity.displayName + " (" + $ctx.identity.appId + ")")
    Write-Host ("  created   : " + $ctx.createdUtc + " by " + $ctx.createdBy)
    Write-Explain "Phase 2 will run again from that context. Everything that already exists is
found and skipped; only what is missing is created."
    $acct = Ensure-SignedIn -TenantId $ctx.identity.tenantId
    if (-not $acct) { return }
    if (Read-YesNo -Question 'Dry run first?' -DefaultYes $true) {
        Push-Location $script:DeployDir
        try { & (Join-Path $script:DeployDir 'Deploy-AfsEnvironment.ps1') -Context $script:ContextFile -WhatIf }
        catch { Show-AzureFailure -Message $_.Exception.Message -Context 'The dry run did not complete.' }
        finally { Pop-Location }
    }
    if (-not (Read-YesNo -Question 'Resume the build now?' -DefaultYes $true)) { return }
    [void](Invoke-Phase2WithRetry)
}

function Get-AfsReports {
    <# Every assessment.html and as-built html in the repository, newest first. #>
    $found = @()
    foreach ($pattern in @('assessment.html', 'AS-BUILT-*.html')) {
        $found += @(Get-ChildItem -Path $script:Root -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(logs|\.git|node_modules)\\' })
    }
    return @($found | Sort-Object LastWriteTime -Descending)
}

function Invoke-ReportsFlow {
    <# Menu entry: open the findings and as-built reports that have been produced. #>
    while ($true) {
        Write-Title 'Reports'
        $reports = Get-AfsReports
        if ($reports.Count -eq 0) {
            Write-Note 'no reports yet. Run an assessment (option 2) or a build (option 1) first.'
            return
        }
        $labels = @()
        foreach ($r in $reports) {
            $kind = if ($r.Name -like 'AS-BUILT-*') { 'as-built  ' } else { 'assessment' }
            $labels += ("{0}  {1}  {2}" -f $kind, $r.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $r.FullName.Substring($script:Root.Length + 1))
        }
        $labels += 'Generate the as-built for the last build now'
        $labels += 'Back'
        $c = Read-Choice -Question 'Which report?' -Options $labels
        if ($c -eq $reports.Count) {
            if (-not (Test-Path $script:ContextFile)) { Write-Bad 'no deployment context - build first.'; continue }
            $acct = Ensure-SignedIn
            if (-not $acct) { continue }
            Push-Location $script:DeployDir
            try { & (Join-Path $script:DeployDir 'Export-AfsAsBuilt.ps1') -Context $script:ContextFile | Out-Null }
            catch { Show-AzureFailure -Message $_.Exception.Message -Context 'The as-built was not generated.' }
            finally { Pop-Location }
            continue
        }
        if ($c -eq ($reports.Count + 1)) { return }
        Start-Process $reports[$c].FullName
        Write-Good ('opened ' + $reports[$c].FullName)
    }
}

$script:StageTotal = 7
function Set-WizardStage {
    # overall progress across the whole build, above the per-script bars (Id 1 stacks over Id 0)
    param([int]$Stage, [string]$Text)
    Write-AfsLog -Level STEP -Message ('stage ' + $Stage + '/' + $script:StageTotal + ': ' + $Text)
    Write-Host ''
    Write-AfsPhaseStrip -Done $Stage -Total $script:StageTotal -Label 'stages'
    Write-AfsProgress -Activity 'Azure File Sync wizard' -Status $Text -Step $Stage -Total $script:StageTotal -Id 1
}

function Invoke-BuildFlow {
    if (-not (Test-Prerequisites -ForDeploy)) { return }
    Set-WizardStage 1 'prerequisites checked'

    # Sign in FIRST. Until we are authenticated we cannot list the subscriptions you can
    # actually see, and asking you to type a GUID from memory is a poor substitute.
    $acct = Ensure-SignedIn
    if (-not $acct) { return }
    Set-WizardStage 2 'signed in'

    if (Test-Path $script:InputsFile) {
        Write-Title 'Your answers'
        Write-Good ("found " + $script:InputsFile)
        if (Read-YesNo -Question 'Answer the questions again?' -DefaultYes $false) { New-InputsFile }
    } else {
        New-InputsFile
    }
    if (-not (Test-Path $script:InputsFile)) { Write-Bad 'no inputs file; cannot continue.'; return }

    # show what will be built
    Set-WizardStage 3 'answers ready'
    Write-Title 'What this will create'
    Push-Location $script:DeployDir
    try {
        & (Join-Path $script:DeployDir 'Deploy-AfsEnvironment.ps1') -InputFile $script:InputsFile -ShowResolved
    } finally { Pop-Location }

    if (-not (Read-YesNo -Question 'Does that look right?' -DefaultYes $true)) {
        Write-Note 'nothing has been changed. Re-run and answer the questions again.'
        return
    }

    # phase 1
    Set-WizardStage 4 'design reviewed'
    Write-Title 'Phase 1 - the deployment identity'
    Write-Explain "Creates a service principal and gives it Contributor on the one resource
group. After this, every deployment runs without a human."
    if (-not (Read-YesNo -Question 'Run phase 1 now?' -DefaultYes $true)) { return }

    Push-Location $script:DeployDir
    try {
        & (Join-Path $script:DeployDir 'Phase1-New-DeploymentIdentity.ps1') -InputFile $script:InputsFile -SkipLogin
    } catch {
        Write-Bad $_.Exception.Message
        Write-Host ''
        Write-Explain "If that said RequestDisallowedByAzure, the sign-in did not complete MFA.
Run 'az logout' then start again.
If it said AuthorizationFailed, the account is not Owner or User Access
Administrator on this subscription."
        Pop-Location
        return
    }
    Pop-Location

    if (-not (Test-Path $script:ContextFile)) {
        Write-Bad 'phase 1 did not produce a deployment context. Stopping here.'
        return
    }
    Write-Good 'phase 1 complete'

    # phase 2 dry run
    Set-WizardStage 5 'phase 1 done - identity ready'
    Write-Title 'Phase 2 - dry run first'
    Write-Explain "Nothing is changed. This checks your access and shows every step."
    Push-Location $script:DeployDir
    try {
        & (Join-Path $script:DeployDir 'Deploy-AfsEnvironment.ps1') -Context $script:ContextFile -WhatIf
    } finally { Pop-Location }

    Write-Host ''
    if (-not (Read-YesNo -Question 'Build it for real now?' -DefaultYes $true)) {
        Write-Note 'nothing was changed. Run this again when you are ready.'
        return
    }

    Set-WizardStage 6 'dry run reviewed - building'
    Write-Title 'Phase 2 - building'
    if (-not (Invoke-Phase2WithRetry)) { return }

    Set-WizardStage 7 'built'
    Complete-AfsProgress -Activity 'Azure File Sync wizard' -Id 1
    Write-Title 'Done'
    Write-Explain "Three things still need a human, on a specific machine:
  1. install the Azure File Sync agent on the file server and register it
  2. point your on-premises DNS at the resolver IP shown above, for the
     privatelink zones only
  3. domain-join the storage account, from a domain-joined machine

docs/AS-BUILT-TEMPLATE.md tells you what to capture as evidence."
}

function Test-AzPowerShellSession {
    <# True only if an Az PowerShell context exists AND can actually call Azure. A context that
       exists but is expired, or was made from a raw token, passes Get-AzContext and then fails
       on the first real call - which is exactly the crash this guards against. #>
    try {
        Import-Module Az.Accounts -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $ctx) { return $false }
        $r = Invoke-AzRestMethod -Method GET -Uri 'https://management.azure.com/subscriptions?api-version=2022-12-01' -ErrorAction Stop
        return ($r -and $r.StatusCode -eq 200)
    } catch { return $false }
}

function Ensure-AzPowerShellSession {
    <# The export script uses the Az PowerShell module, which keeps its own sign-in, separate
       from the Azure CLI session the wizard already has. Establish one, and prove it works. #>
    param([string]$TenantId, [string]$SubscriptionId)
    Write-Title 'Az PowerShell session'
    Write-Explain "The export script uses the Az PowerShell module, which keeps its own sign-in -
separate from the Azure CLI. Your az login does not cover it."

    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Note 'the Az.Accounts module is not installed.'
        if (-not (Read-YesNo -Question 'Install it now, for the current user only?' -DefaultYes $true)) { return $false }
        try {
            Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
            Write-Good 'installed'
        } catch { Write-Bad ('install failed: ' + $_.Exception.Message); return $false }
    }

    if (Test-AzPowerShellSession) {
        Write-Good ('Az PowerShell already signed in as ' + (Get-AzContext).Account.Id)
        return $true
    }

    Write-Note 'no working Az PowerShell session - missing, expired, or a token-only context.'
    Write-Explain "A browser window will open. Complete MFA if prompted."
    Write-Host ''
    Read-Host '  Press Enter to sign in to Az PowerShell' | Out-Null
    try {
        # pass what we already know, so Connect-AzAccount does not stop to ask for a tenant
        # or a subscription - the only interaction left is MFA, if the broker needs it
        $conn = @{ ErrorAction = 'Stop' }
        if ($TenantId)       { $conn['Tenant'] = $TenantId }
        if ($SubscriptionId) { $conn['Subscription'] = $SubscriptionId }
        Connect-AzAccount @conn | Out-Null
    } catch {
        Write-AfsLogException -ErrorRecord $_ -Context 'Connect-AzAccount failed'
        Write-Bad ('Connect-AzAccount failed: ' + $_.Exception.Message)
        return $false
    }
    if (-not (Test-AzPowerShellSession)) {
        Write-Bad 'signed in, but the session still cannot list subscriptions.'
        return $false
    }
    Write-Good ('Az PowerShell signed in as ' + (Get-AzContext).Account.Id)
    return $true
}

function Invoke-AssessFlow {
    if (-not (Test-Prerequisites)) { return }
    Write-Title 'Assess an existing estate'
    Write-Explain "Three steps: export the configuration (read-only), optionally collect
per-server detail, then produce the findings report."

    $choice = Read-Choice -Question 'Which step?' -Options @(
        'Export the configuration from Azure (needs Reader)',
        'Assess an export I already have (no Azure access needed)',
        'Back'
    )
    if ($choice -eq 2) { return }

    if ($choice -eq 0) {
        $acct = Ensure-SignedIn
        if (-not $acct) { return }

        # which subscriptions to export - from the list this account can actually see
        $subIds = @()
        $subs = ConvertTo-Array (Invoke-Cli @('account', 'list', '--query', "[?state=='Enabled'].{name:name,id:id}", '-o', 'json') -AllowFailure)
        if ($subs.Count -gt 0) {
            Write-Explain ("These are the subscriptions this account can see (" + $subs.Count + ").")
            $labels = @($subs | ForEach-Object { "$($_.name)   ($($_.id))" }) + @('All of them')
            $i = Read-Choice -Question 'Which subscription should be exported?' -Options $labels
            if ($i -lt $subs.Count) { $subIds = @($subs[$i].id) }
            else { $subIds = @($subs | ForEach-Object { $_.id }) }
        }

        # the export script needs its own session - establish and prove it before handing off
        $firstSub = if ($subIds.Count -eq 1) { $subIds[0] } else { $null }
        if (-not (Ensure-AzPowerShellSession -TenantId $acct.tenantId -SubscriptionId $firstSub)) {
            Write-Explain 'The export was not started.'
            return
        }

        Write-Note 'the export makes only read calls - no keys, no SAS, no data.'
        if (-not (Read-YesNo -Question 'Run the export now?' -DefaultYes $true)) { return }
        Push-Location $script:Root
        try {
            $exporter = Join-Path $script:Root 'Export-AzFileSyncEnvironment.ps1'
            if ($subIds.Count) { & $exporter -SubscriptionId $subIds } else { & $exporter }
        } catch {
            Write-AfsLogException -ErrorRecord $_ -Context 'export failed'
            Show-AzureFailure -Message $_.Exception.Message -Context 'The export did not complete.'
        } finally { Pop-Location }
        return
    }

    $path = Read-Answer -Question 'Path to the export zip or folder?'
    if (-not (Test-Path $path)) { Write-Bad 'that path does not exist.'; return }
    $customer = Read-Answer -Question 'Name to put on the report?' -Default 'Customer'
    $private = Read-YesNo -Question 'Must sync and backup traffic stay on a private path?' -DefaultYes $false `
        -Why "Turns on the ExpressRoute target-state rules and escalates findings about
anything still reachable over the public endpoint."

    Push-Location $script:Root
    try {
        $a = @('-ExportPath', $path, '-CustomerName', $customer)
        if ($private) { $a += '-PrivateTrafficRequired' }
        & (Join-Path $script:Root 'Assess-AzFileSyncExport.ps1') @a
        $html = Get-AfsReports | Where-Object { $_.Name -eq 'assessment.html' } | Select-Object -First 1
        if ($html -and (Read-YesNo -Question 'Open the HTML report now?' -DefaultYes $true)) {
            Start-Process $html.FullName
            Write-Good ('opened ' + $html.FullName)
        }
    } catch { Show-AzureFailure -Message $_.Exception.Message -Context 'The assessment did not complete.' }
    finally { Pop-Location }
}

function Invoke-RemoveFlow {
    if (-not (Test-Prerequisites)) { return }
    Write-Title 'Remove a deployment'
    if (-not (Test-Path $script:ContextFile)) {
        Write-Bad 'no deployment context found - nothing to remove from here.'
        return
    }
    Write-Note 'this deletes the resource group and everything in it.'
    Write-Explain "It inventories the group first and refuses if it finds anything your
configuration does not name."
    Write-Host ''
    if (-not (Read-YesNo -Question 'Show a dry run first?' -DefaultYes $true)) { return }

    Push-Location $script:DeployDir
    try { & (Join-Path $script:DeployDir 'Remove-AfsEnvironment.ps1') -Context $script:ContextFile -WhatIf }
    finally { Pop-Location }

    Write-Host ''
    $typed = Read-Answer -Question 'Type DELETE to confirm, anything else to cancel' -AllowEmpty
    if ($typed -cne 'DELETE') { Write-Note 'cancelled. Nothing was removed.'; return }

    Push-Location $script:DeployDir
    try { & (Join-Path $script:DeployDir 'Remove-AfsEnvironment.ps1') -Context $script:ContextFile -Confirm:$false }
    catch { Write-Bad $_.Exception.Message }
    finally { Pop-Location }
}


function Open-Target {
    <# Open a document either on GitHub or from disk, whichever the reader prefers. #>
    param([Parameter(Mandatory)][string]$RelativePath, [string]$Title)

    $label = $RelativePath
    if ($Title) { $label = $Title }
    $local = Join-Path $script:Root $RelativePath
    $url   = ($script:RepoUrl + '/blob/main/' + ($RelativePath -replace '\\', '/'))

    $c = Read-Choice -Question ("Open " + $label + " how?") -Options @(
        'On GitHub, in the browser',
        'From disk, in the default editor',
        'Show the first page here',
        'Back'
    )
    switch ($c) {
        0 {
            Write-Note 'if the repository is still private, GitHub will ask you to sign in.'
            Start-Process $url
            Write-Good $url
        }
        1 {
            if (Test-Path $local) { Start-Process $local; Write-Good $local }
            else { Write-Bad ("not found on disk: " + $local) }
        }
        2 {
            if (Test-Path $local) {
                Write-Host ''
                Get-Content $local -TotalCount 40 | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Gray }
                Write-Host ''
                Write-Note ("showing the first 40 lines of " + $RelativePath)
            } else { Write-Bad ("not found on disk: " + $local) }
        }
    }
}

function Invoke-DocsFlow {
    Write-Title 'Documentation'
    Write-Explain "What each document is for, so you can go straight to the one you need."

    $docs = @(
        @{ f = 'docs/GETTING-STARTED.md';         n = 'Getting started';         d = 'Dependencies, sign-in, and a walk-through of every script. Start here.' },
        @{ f = 'deploy/README.md';                n = 'Two-phase deployment';    d = 'How the four inputs, phase 1 and phase 2 fit together.' },
        @{ f = 'docs/RULES.md';                   n = 'Assessor rules';          d = 'Every rule the assessment applies, with its recommendation and source.' },
        @{ f = 'docs/ARCHITECTURE-REFERENCES.md'; n = 'Architecture references'; d = '73 verified Microsoft sources, each with a specific take-away.' },
        @{ f = 'docs/VALIDATION.md';              n = 'Validation record';       d = 'What has been executed, what has not, and what execution found.' },
        @{ f = 'docs/PROOF-OF-WORK.md';           n = 'Proof of work';           d = 'What was built and what verification caught. For sharing.' },
        @{ f = 'docs/AS-BUILT-TEMPLATE.md';       n = 'As-built template';       d = 'Fill in after a deployment. Names the evidence and screenshots to capture.' },
        @{ f = 'docs/PLAYBOOK-azure-file-sync-assessment.md';   n = 'Playbook: assessment'; d = 'Scope, export, assess and recommend on an existing estate.' },
        @{ f = 'docs/PLAYBOOK-azure-backup-for-azure-files.md'; n = 'Playbook: backup';     d = 'Design and set up Azure Backup for the synced shares.' },
        @{ f = 'advise/SESSION-GUIDE.md';         n = 'Customer session guide';  d = 'A two-hour working session when there is nothing to assess yet.' },
        @{ f = 'advise/REFERENCE-DESIGN.md';      n = 'Reference design';        d = '18 decisions, each with a default, a reason and a reversal cost.' },
        @{ f = 'CONTRIBUTING.md';                 n = 'Contributing';            d = 'How to report a correction or a gap. No write access needed.' }
    )

    while ($true) {
        Write-Host ''
        $labels = @()
        foreach ($d in $docs) {
            $mark = ' '
            if (-not (Test-Path (Join-Path $script:Root $d.f))) { $mark = '?' }
            $labels += ("{0} {1}" -f $mark, $d.n) + "`n         " + $d.d
        }
        $labels += 'Open the whole docs folder on GitHub'
        $labels += 'Back'

        $c = Read-Choice -Question 'Which document?' -Options $labels
        if ($c -eq $docs.Count) {
            Write-Note 'if the repository is still private, GitHub will ask you to sign in.'
            Start-Process ($script:RepoUrl + '/tree/main/docs')
            Write-Good ($script:RepoUrl + '/tree/main/docs')
            continue
        }
        if ($c -eq ($docs.Count + 1)) { return }
        Open-Target -RelativePath $docs[$c].f -Title $docs[$c].n
    }
}

function Invoke-CodexFlow {
    Write-Title 'Blueprints, playbooks and runbooks'
    Write-Explain "Three kinds of document, separated on purpose:
  blueprint - what the target state looks like and why, including the
              decisions that cannot be reversed
  playbook  - the ordered steps to build it, each carrying a verify as
              well as a run
  runbook   - symptom, cause, recovery, for when it breaks later"

    $codexDir = Join-Path $script:Root 'codex'
    if (-not (Test-Path $codexDir)) { Write-Bad 'no codex folder found.'; return }

    # read the title out of each entry rather than hard-coding a list that would drift
    $entries = @()
    $files = Get-ChildItem -Path $codexDir -Filter '*.md' | Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name
    foreach ($file in $files) {
        $head  = Get-Content $file.FullName -TotalCount 12
        $title = ($head | Where-Object { $_ -match '^title:' } | Select-Object -First 1) -replace '^title:\s*', ''
        $type  = ($head | Where-Object { $_ -match '^doc_type:' } | Select-Object -First 1) -replace '^doc_type:\s*', ''
        if (-not $title) { $title = $file.BaseName }
        if (-not $type)  { $type = 'entry' }
        $entries += @{ file = ('codex/' + $file.Name); type = $type; title = $title }
    }

    while ($true) {
        $order  = @('blueprint', 'playbook', 'runbook')
        $sorted = @()
        foreach ($t in $order) { $sorted += @($entries | Where-Object { $_.type -eq $t }) }
        $sorted += @($entries | Where-Object { $order -notcontains $_.type })

        $nb = (@($entries | Where-Object { $_.type -eq 'blueprint' })).Count
        $np = (@($entries | Where-Object { $_.type -eq 'playbook' })).Count
        $nr = (@($entries | Where-Object { $_.type -eq 'runbook' })).Count

        Write-Host ''
        Write-Explain ("{0} entries: {1} blueprints, {2} playbooks, {3} runbooks, plus the diagram library." -f $entries.Count, $nb, $np, $nr)

        $labels = @()
        foreach ($e in $sorted) { $labels += ("[{0,-9}] {1}" -f $e.type, $e.title) }
        $labels += 'Open the codex folder on GitHub'
        $labels += 'Open the diagram library on GitHub'
        $labels += 'Back'

        $c = Read-Choice -Question 'Which one?' -Options $labels
        if ($c -eq $sorted.Count) {
            Start-Process ($script:RepoUrl + '/tree/main/codex'); Write-Good ($script:RepoUrl + '/tree/main/codex'); continue
        }
        if ($c -eq ($sorted.Count + 1)) {
            Start-Process ($script:RepoUrl + '/tree/main/codex/diagrams'); Write-Good ($script:RepoUrl + '/tree/main/codex/diagrams'); continue
        }
        if ($c -eq ($sorted.Count + 2)) { return }
        Open-Target -RelativePath $sorted[$c].file -Title $sorted[$c].title
    }
}

# ------------------------------------------------------------------ main ----

Write-Banner
Write-Host ''
Write-Explain "This walks you through whichever job you are here for. Nothing is changed
without showing you first and asking."
Write-Host ''
Write-Host ("  Logging to " + $script:LogFile) -ForegroundColor DarkGray
Write-Host ("  Level " + $LogLevel + " - re-run with -LogLevel Debug for full Azure CLI traces") -ForegroundColor DarkGray

try {
while ($true) {
    try {
        $c = Read-Choice -Question 'What would you like to do?' -Options @(
            'Build a new Azure File Sync environment',
            'Assess an existing environment',
            'Remove an environment I built',
            'Just check my prerequisites',
            'Read the documentation',
            'Browse the blueprints, playbooks and runbooks',
            'Resume the last build (retry after a crash)',
            'Open the findings and as-built reports',
            'Quit'
        )
    } catch {
        Write-Host ''
        Write-Bad $_.Exception.Message
        return
    }
    try {
        switch ($c) {
            0 { Invoke-BuildFlow }
            1 { Invoke-AssessFlow }
            2 { Invoke-RemoveFlow }
            3 { [void](Test-Prerequisites -ForDeploy) }
            4 { Invoke-DocsFlow }
            5 { Invoke-CodexFlow }
            6 { Invoke-ResumeFlow }
            7 { Invoke-ReportsFlow }
            8 { Write-Host ''; Write-Host '  Bye.' -ForegroundColor White; Write-Host ''; Stop-AfsLog -Outcome 'ended by user'; return }
        }
    } catch {
        Write-AfsLogException -ErrorRecord $_ -Context 'flow failed'
        Show-AzureFailure -Message $_.Exception.Message -Context 'That step did not complete.'
        Write-Host ("  Full detail is in " + $script:LogFile) -ForegroundColor DarkGray
        Write-Explain 'Nothing further was changed. You can choose again, or quit.'
    }
    Write-Host ''
    Write-Rule
}
} catch {
    # anything that escaped the flows - this is the line to read after a crash
    Write-AfsLogException -ErrorRecord $_ -Context 'wizard crashed'
    Write-Host ''
    Write-Host ('  [!]    The wizard stopped unexpectedly: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('         Details: ' + $script:LogFile) -ForegroundColor DarkGray
    Stop-AfsLog -Outcome 'crashed'
    throw
} finally {
    Stop-AfsLog -Outcome 'closed'
}
