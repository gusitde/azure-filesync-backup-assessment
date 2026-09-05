<#
.SYNOPSIS
  Luca AZ Consulting Helper - the guided front door. Asks what you want to do, checks your
  prerequisites, asks the questions it needs, and runs the right scripts in the right order.

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
. (Join-Path $script:DeployDir 'AfsSettings.ps1')
. (Join-Path $script:DeployDir 'AfsRequirements.ps1')
$script:LogFile = Start-AfsLog -Level $LogLevel -Name 'wizard'

# ------------------------------------------------------------------ ui ------

function Write-Rule { Write-Host ('-' * 74) -ForegroundColor DarkGray }

function Get-AfsInk {
    <#  The brand is indigo (#6366f1), which the 16-colour console cannot express. Where the
        console does truecolour, use the real thing; everywhere else fall back to the Cyan the
        sibling Server-Ops wizard already ships, so the family still looks like one company
        built it. Never emit escapes into a redirected stream - that is what ends up in a log. #>
    param([int]$R, [int]$G, [int]$B)
    if ([Console]::IsOutputRedirected -or -not $Host.UI.SupportsVirtualTerminal) { return '' }
    return ([string][char]27 + '[38;2;' + $R + ';' + $G + ';' + $B + 'm')
}
function Get-AfsInkOff { if ([Console]::IsOutputRedirected -or -not $Host.UI.SupportsVirtualTerminal) { return '' } return ([string][char]27 + '[0m') }

function Write-Banner {
    if ($Host.UI.RawUI -and -not [Console]::IsOutputRedirected) { Clear-Host }
    # Block glyphs by [char] code so this file stays strictly ASCII on disk.
    $b1 = [string][char]0x2591; $b2 = [string][char]0x2592; $b3 = [string][char]0x2593; $b4 = [string][char]0x2588
    $dash = [string][char]0x2500
    $off  = Get-AfsInkOff
    # lucaexpress.com indigo, deep to light and back - #4338ca #4f46e5 #6366f1 #818cf8
    $ramp  = @((Get-AfsInk 67 56 202), (Get-AfsInk 79 70 229), (Get-AfsInk 99 102 241), (Get-AfsInk 129 140 248))
    $glyph = @($b1, $b2, $b3, $b4)
    $p = Get-AfsProductInfo

    Write-Host ''
    if ($ramp[0]) {
        # truecolour: a real gradient either side of the wordmark
        $left = ''; $right = ''
        for ($i = 0; $i -lt 4; $i++) {
            $left  += $ramp[$i] + ($glyph[$i] * 3)
            $right += $ramp[3 - $i] + ($glyph[3 - $i] * 3)
        }
        Write-Host ('  ' + $left + $off) -NoNewline
        Write-Host ('  ' + $p.Name + '  ') -NoNewline -ForegroundColor White
        Write-Host ($right + $off)
        Write-Host ('  ' + (Get-AfsInk 129 140 248) + 'Azure File Sync and Azure Backup' + $off) -NoNewline
        Write-Host ('   ' + $p.Version + '  -  ' + $p.Author) -ForegroundColor DarkGray
        Write-Host ('  ' + (Get-AfsInk 110 118 129) + 'assess ' + $dash + ' build ' + $dash + ' connect ' + $dash + ' protect ' + $dash + ' govern ' + $dash + ' remove' + $off)
        Write-Host ('  ' + (Get-AfsInk 79 70 229) + ($dash * 70) + $off)
    } else {
        # 16-colour fallback - the same shape the Server-Ops wizard uses
        $grad  = ($b1 * 3) + ($b2 * 3) + ($b3 * 3) + ($b4 * 3)
        $gradR = ($b4 * 3) + ($b3 * 3) + ($b2 * 3) + ($b1 * 3)
        Write-Host ('  ' + $grad) -NoNewline -ForegroundColor Cyan
        Write-Host ('  ' + $p.Name + '  ') -NoNewline -ForegroundColor White
        Write-Host $gradR -ForegroundColor Cyan
        Write-Host '  Azure File Sync and Azure Backup' -NoNewline -ForegroundColor Cyan
        Write-Host ('   ' + $p.Version + '  -  ' + $p.Author) -ForegroundColor DarkGray
        Write-Host '  assess - build - connect - protect - govern - remove' -ForegroundColor DarkGray
        Write-Host ('  ' + ($dash * 70)) -ForegroundColor DarkCyan
    }
    Write-Host ''
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
        [string]$Example,
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
        # A remembered answer is offered and Enter takes it. An example is only ever shown -
        # pressing Enter must never commit to a server or a folder that was invented here to
        # illustrate a format.
        if ($Example -and -not $Default) { Write-Host ("         e.g. " + $Example) -ForegroundColor DarkGray }
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

function Clear-AfsPendingInput {
    <#  A step can run for twenty minutes. Anything typed while it ran is sitting in the console
        buffer and would be swallowed instantly by the next prompt - answering a question that
        had not been asked yet. On a menu whose entries include "Remove an environment" that is
        not a cosmetic problem. Only meaningful on a real console, so failure here is fine. #>
    try { if (-not [Console]::IsInputRedirected) { $Host.UI.RawUI.FlushInputBuffer() } } catch { }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Question, [string]$Why, [bool]$DefaultYes = $true)
    Clear-AfsPendingInput
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
    Clear-AfsPendingInput
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
    # ,@() and not @(): an empty array returned bare goes through the pipeline as NOTHING,
    # so the caller gets $null and .Count throws under Set-StrictMode
    if ($null -eq $Value) { return ,@() }
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

    # What the on-premises steps need. None of this is required to build the Azure side, so a
    # gap is reported rather than fatal - but it is reported HERE, where it costs nothing to
    # fix, instead of halfway through a change to a domain controller.
    Write-Host ''
    Write-Host '  For the on-premises steps (option 7):' -ForegroundColor DarkGray

    foreach ($m in @('Az.Accounts', 'Az.Storage', 'Az.StorageSync')) {
        if (Get-Module -ListAvailable -Name $m) {
            Write-Good ($m + ' ' + ((Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1).Version))
        } else {
            Write-Note ($m + ' is not installed - needed to register a file server and create the endpoints.')
            Write-Explain ("  Install-Module " + $m + " -Scope CurrentUser")
        }
    }

    if (Get-Module -ListAvailable -Name ActiveDirectory) {
        Write-Good 'Active Directory module (RSAT) - the AD DS join can run'
    } else {
        Write-Note 'the Active Directory module (RSAT) is not installed - the AD DS join cannot run.'
        Write-Explain @"
AzFilesHybrid needs it, and it tries to install it for you from a block that runs
even under -WhatIf - an install that needs elevation, and whose error message
("requires an elevated PowerShell session") points at the wrong problem.

Install it once, from an ELEVATED PowerShell:
  Install-WindowsFeature RSAT-AD-PowerShell                                   # Windows Server
  Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0   # Windows client

After that the join runs without elevation.
"@
    }

    if (Get-Module -ListAvailable -Name DnsServer) {
        Write-Good 'DnsServer module - conditional forwarders can be set from here'
    } else {
        Write-Note 'the DnsServer module is not installed - the forwarder step will probably fail.'
        Write-Explain "Without it Get-DnsServerZone does not exist here, so the script falls back to
running the cmdlets inside a remoting session ON each DNS server. That needs
WinRM there AND rights there - and a domain controller usually refuses an
account that is not in DnsAdmins or Domain Admins. In practice that fallback
fails more often than it works, so treat this as a prerequisite, not a nicety.

Install it once, from an ELEVATED PowerShell:
  Install-WindowsFeature RSAT-DNS-Server                              # Windows Server
  Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0       # Windows client

The wizard also offers to collect a credential for the DNS servers, which is
the other half of this - the module gets you the cmdlet, the credential gets
you the rights."
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
        # Not splatted, so this one was never broken - but $args is an automatic variable and
        # naming a local after it is how the governance defect stayed invisible for so long.
        $loginArgs = @('login', '--only-show-errors', '-o', 'json')
        if ($TenantId) { $loginArgs += @('--tenant', $TenantId) }
        Invoke-Cli $loginArgs -AllowFailure | Out-Null
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

function Invoke-SettingsFileFlow {
    <# For the people who would rather edit JSON than answer questions. Both routes write the
       same file, so neither is second-class - but the file is the one you can diff, comment
       and keep in a ticket, which is why it is worth pointing at plainly. #>
    $sample = Join-Path $script:DeployDir 'inputs.sample.jsonc'
    while ($true) {
        Write-Host ''
        Write-Host '  The settings file' -ForegroundColor White
        Write-Host ('    ' + $script:InputsFile) -ForegroundColor DarkGray
        if (Test-Path $script:InputsFile) {
            $fi = Get-Item $script:InputsFile
            Write-Host ('    ' + [math]::Round($fi.Length / 1KB, 1) + ' KB, last changed ' + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray
        } else {
            Write-Note 'it does not exist yet - the sample is the place to start.'
        }
        Write-Explain "Edit it in any editor and come back; this screen re-reads the file every
time it is shown, so your change appears as soon as you return. Comments
(// and /* */) are allowed - it is read as JSONC, not strict JSON.

The sample beside it carries a commented explanation of every field and,
just as usefully, the shape each value is expected to take."

        $labels = @(
            'Open it in the default editor',
            'Open the folder it is in',
            'Open the annotated sample (inputs.sample.jsonc)',
            'Check that it still parses',
            'Back'
        )
        switch (Read-Choice -Question 'What would you like to do?' -Options $labels) {
            0 {
                if (-not (Test-Path $script:InputsFile)) { Write-Bad 'there is no file to open yet.'; break }
                try { Start-Process $script:InputsFile; Write-Good ('opened ' + $script:InputsFile) }
                catch { Write-Bad ('could not open it: ' + $_.Exception.Message); Write-Explain ('Open it by hand: ' + $script:InputsFile) }
            }
            1 {
                try { Start-Process $script:DeployDir; Write-Good $script:DeployDir }
                catch { Write-Bad ('could not open the folder: ' + $_.Exception.Message) }
            }
            2 {
                if (-not (Test-Path $sample)) { Write-Bad ('the sample is missing: ' + $sample); break }
                try { Start-Process $sample; Write-Good ('opened ' + $sample) }
                catch { Write-Bad ('could not open it: ' + $_.Exception.Message); Write-Explain ('Open it by hand: ' + $sample) }
            }
            3 {
                # A hand-edited file that does not parse fails at the least convenient moment -
                # usually halfway through a build. Two seconds here beats that.
                if (-not (Test-Path $script:InputsFile)) { Write-Bad 'there is no file to check yet.'; break }
                try {
                    $probe = Read-AfsJsonc -Path $script:InputsFile
                    Write-Good 'it parses.'
                    try {
                        $r = Resolve-AfsConfig -Inputs $probe
                        Write-Good ('and it resolves - resource group ' + $r.resourceGroup + ' in ' + $r.location)
                    } catch {
                        Write-Note ('it parses, but does not resolve yet: ' + $_.Exception.Message)
                        Write-Explain 'That is fine while it is half-filled; the build needs it to resolve.'
                    }
                } catch {
                    Write-Bad ('it does not parse: ' + $_.Exception.Message)
                    Write-Explain 'A trailing comma and an unescaped backslash are the two usual causes.
In a Windows path write \\ - "D:\\Shares\\dept" - or use a forward slash.'
                }
            }
            4 { return }
        }
    }
}

function Invoke-SettingsFlow {
    <# Everything the build derives is editable, but nothing says so unless you read the
       resolver. This lists each setting with the value actually in force - yours, or the one
       derived from the name prefix - and lets you change any of it. #>
    if (-not (Test-Path $script:InputsFile)) {
        Write-Title 'Deployment settings'
        Write-Note 'there is no inputs file yet.'
        Write-Explain "Settings live in deploy\inputs.json. The build writes one for you, or it
can be copied from the sample."
        if (-not (Read-YesNo -Question 'Create one from the sample now?' -DefaultYes $true)) { return }
        Copy-Item (Join-Path $script:DeployDir 'inputs.sample.jsonc') $script:InputsFile -Force
        Write-Good ('created ' + $script:InputsFile)
    }

    while ($true) {
        $inputs = Read-AfsJsonc -Path $script:InputsFile
        $resolved = $null
        try { $resolved = Resolve-AfsConfig -Inputs $inputs } catch { }
        $catalog = Get-AfsSettingCatalog
        $groups = @($catalog | ForEach-Object { $_.Group } | Select-Object -Unique)

        Write-Title 'Deployment settings'
        Write-Explain "Anything marked (derived) follows from the name prefix. Change the prefix and
they move together; set one explicitly and it stops following."
        # Some people would rather edit the file. Say where it is, every time, rather than
        # making that a thing you have to already know.
        Write-Host ''
        Write-Host ('  settings file   ' + $script:InputsFile) -ForegroundColor DarkGray
        # These settings are read when phase 1 writes the deployment context. A build or
        # a resume that runs FROM an existing context uses what was captured then, so an
        # edit here would otherwise appear to do nothing at all.
        if (Test-Path $script:ContextFile) {
            $existing = $null
            try { $existing = Read-AfsJsonc -Path $script:ContextFile } catch { }
            if ($existing -and $resolved -and $existing.config.resourceGroup -ne $resolved.resourceGroup) {
                Write-Host ''
                Write-Note ('the saved deployment still points at ' + $existing.config.resourceGroup + ', not ' + $resolved.resourceGroup + '.')
                Write-Explain "Phase 1 captured those names when it ran. Build re-runs phase 1 and picks
these up; Resume deliberately does not, because it exists to continue the
deployment that was already started."
            }
        }
        Write-Host ''
        foreach ($g in $groups) {
            Write-Host ('  ' + $g) -ForegroundColor White
            foreach ($item in ($catalog | Where-Object { $_.Group -eq $g })) {
                $e = Get-AfsEffectiveValue -Inputs $inputs -Resolved $resolved -Setting $item
                $shown = if ($null -eq $e.Value) { '(not set)' } else { [string]$e.Value }
                $tag = if ($e.Source -eq 'derived') { ' (derived)' } else { '' }
                Write-Host ("    {0,-32} {1}{2}" -f $item.Label, $shown, $tag) -ForegroundColor DarkGray
            }
        }

        $opts = @($groups | ForEach-Object { 'Change something under ' + $_ }) +
                @('Show what it all resolves to',
                  'Edit the JSON file directly (deploy\inputs.json)',
                  'Back')
        $choice = Read-Choice -Question 'What now?' -Options $opts
        if ($choice -eq $groups.Count) {
            if ($resolved) { Show-AfsConfig -Config $resolved }
            else { Write-Bad 'the settings do not resolve yet - fill in the ones shown as (not set).' }
            continue
        }
        if ($choice -eq ($groups.Count + 1)) { Invoke-SettingsFileFlow; continue }
        if ($choice -eq ($groups.Count + 2)) { return }

        $group = $groups[$choice]
        $items = @($catalog | Where-Object { $_.Group -eq $group })
        $labels = @()
        foreach ($item in $items) {
            $e = Get-AfsEffectiveValue -Inputs $inputs -Resolved $resolved -Setting $item
            $labels += ("{0}  =  {1}" -f $item.Label, $(if ($null -eq $e.Value) { '(not set)' } else { [string]$e.Value }))
        }
        $labels += 'Back'
        $pick = Read-Choice -Question ($group + ' - which setting?') -Options $labels
        if ($pick -eq $items.Count) { continue }

        $item = $items[$pick]
        $e = Get-AfsEffectiveValue -Inputs $inputs -Resolved $resolved -Setting $item
        Write-Host ''
        Write-Host ('  ' + $item.Label) -ForegroundColor White
        if ($item.ContainsKey('Why')) { Write-Explain $item.Why }
        if ($e.Source -eq 'derived') { Write-Explain ('Derived as ' + $e.Value + ' today. Setting it here stops it following the prefix.') }

        if ($item.ContainsKey('Bool')) {
            $new = Read-YesNo -Question 'Turn this on?' -DefaultYes ([bool]$e.Value)
            Set-AfsInputValue -Inputs $inputs -Path $item.Path -Value $new
        } else {
            $default = ''
            if ($null -ne $e.Value) { $default = [string]$e.Value }
            $pattern = $null
            if ($item.ContainsKey('Pattern')) { $pattern = $item.Pattern }
            $help = $null
            if ($item.ContainsKey('Help')) { $help = 'Expected: ' + $item.Help }
            $ans = Read-Answer -Question 'New value' -Default $default -Pattern $pattern -PatternHelp $help -AllowEmpty
            if ($ans -eq '') {
                Set-AfsInputValue -Inputs $inputs -Path $item.Path -Value $null
                Write-Note 'cleared - it goes back to being derived.'
            } elseif ($item.ContainsKey('Int')) {
                Set-AfsInputValue -Inputs $inputs -Path $item.Path -Value ([int]$ans)
            } else {
                Set-AfsInputValue -Inputs $inputs -Path $item.Path -Value $ans
            }
        }

        # prove it still resolves BEFORE writing, so a typo cannot leave an unbuildable file
        try {
            $check = Resolve-AfsConfig -Inputs $inputs
            Save-AfsInputs -Inputs $inputs -Path $script:InputsFile
            Write-Good ('saved to ' + $script:InputsFile)
            if ($item.Path -eq 'azure.namePrefix') {
                Write-Explain ('Everything derived moved with it: ' + $check.resourceGroup + ', ' + $check.storageAccountName + ', ' + $check.storageSyncServiceName + ', ' + $check.vaultName)
            }
        } catch {
            Write-Bad ('that value does not resolve: ' + $_.Exception.Message)
            Write-Explain 'Nothing was saved. Pick it again and enter something else.'
        }
    }
}

function Invoke-GovernanceFlow {
    <# The other assessment: not "is this estate built well" but "is the tenant around it
       governed well". A separate tool answers that, so this runs it rather than reinventing
       it, and feeds it the subscription and tenant from the deployment. #>
    Write-Title 'Policy and governance across the tenant'
    Write-Explain "The assessment in option 2 looks at File Sync and Backup. This one looks at
everything around them - policy assignments, RBAC, management group structure,
locks, Defender coverage - using the Azure Governance Visualizer.

It is read-only, it needs Reader at the management group, and it needs
PowerShell 7, which this kit does not run on. The script sorts that out."
    $acct = Ensure-SignedIn
    if (-not $acct) { return }
    # A HASHTABLE, not an array. Splatting an array binds POSITIONALLY, so @('-Context', $path)
    # put the literal string '-Context' into $Context and the path into the next positional
    # parameter - which is what "Deployment context not found: -Context" was reporting.
    # ($args is also an automatic variable; assigning it inside a function is asking for trouble.)
    $govArgs = @{}
    if (Test-Path $script:ContextFile) { $govArgs.Context = $script:ContextFile }
    else { Write-Note 'no deployment context - assessing the subscription you are signed in to.' }
    if (Read-YesNo -Question 'Dry run first?' -DefaultYes $true) {
        try { & (Join-Path $script:Root 'Invoke-AfsGovernanceAssessment.ps1') @govArgs -WhatIf }
        catch { Show-AzureFailure -Message $_.Exception.Message -Context 'The dry run did not complete.' }
    }
    if (-not (Read-YesNo -Question 'Run it now? It can take a while on a large tenant.' -DefaultYes $true)) { return }
    try {
        & (Join-Path $script:Root 'Invoke-AfsGovernanceAssessment.ps1') @govArgs -Confirm:$false
    } catch {
        Write-AfsLogException -ErrorRecord $_ -Context 'governance assessment failed'
        Show-AzureFailure -Message $_.Exception.Message -Context 'The governance assessment did not complete.'
    }
}

function Invoke-OnPremisesFlow {
    <# The three steps the Azure build deliberately does not do, because each one changes a
       machine you own rather than a subscription. Each has its own script under onprem/, and
       each one is offered as a dry run first. #>
    $script:OnPremDir = Join-Path $script:Root 'onprem'
    while ($true) {
        Write-Title 'Connect your on-premises servers'
        Write-Explain "The build stops at the edge of Azure. These three finish the job, and each
one changes a machine of yours - a file server, a DNS server, Active
Directory - so each asks before it does anything."
        if (-not (Test-Path $script:ContextFile)) {
            Write-Bad 'no deployment context found - build the Azure side first (option 1).'
            return
        }
        $c = Read-Choice -Question 'Which one?' -Options @(
            'Install the File Sync agent and sync a folder to a share',
            'Point on-premises DNS at the Azure resolver',
            'Domain-join the storage account to Active Directory',
            'Back'
        )
        if ($c -eq 3) { return }
        $acct = Ensure-SignedIn
        if (-not $acct) { return }

        Push-Location $script:OnPremDir
        try {
            switch ($c) {
                0 {
                    $ctx = Read-AfsJsonc -Path $script:ContextFile
                    $onprem = Get-AfsProp $ctx.config 'onPremises'
                    $defServer = [string](Get-AfsProp $onprem 'fileServer' '')
                    # No saved answer? Show the shape of one, built from the AD domain so the
                    # example fits this environment - but as an example, never as a default.
                    $dom = [string](Get-AfsProp $ctx.config 'adDomainFqdn' '')
                    $exServer = if ($dom) { 'fs01.' + $dom } else { 'fs01.corp.example.com' }
                    $server = Read-Answer -Question 'Which file server?' -Why 'A name this machine can reach over PowerShell remoting.' -Default $defServer -Example $exServer -Pattern '^[A-Za-z0-9._-]+$' -PatternHelp 'a computer name, for example fs01 or fs01.corp.example.com'
                    $shares = @(ConvertTo-Array $ctx.config.shares | ForEach-Object { $_.name })
                    $paths = Get-AfsProp $onprem 'serverPaths'
                    $maps = @()
                    $answered = @{}
                    foreach ($sh in $shares) {
                        # Offer what was used last time; failing that a well-formed example, so
                        # the answer's shape is never something to guess at.
                        $def = [string](Get-AfsProp $paths $sh '')
                        if (-not $def) { $def = 'D:\Shares\' + $sh }
                        $ans = Read-Answer -Question ("Which folder on $server syncs to the share '" + $sh + "'?") -Why 'A local NTFS path on that server - not a mapped drive or a UNC path. Leave empty to skip this share.' -Default $def -AllowEmpty
                        if ($ans) { $maps += ($sh + '=' + $ans); $answered[$sh] = $ans }
                    }
                    Save-AfsOnPremisesAnswers -FileServer $server -ServerPaths $answered
                    if ($maps.Count -eq 0) { Write-Note 'no folders given - nothing to do.'; break }
                    Write-Explain 'A dry run first, as always.'
                    & (Join-Path $script:OnPremDir 'Install-AfsServerEndpoint.ps1') -Context $script:ContextFile -FileServer $server -SharePath $maps -WhatIf
                    if (Read-YesNo -Question 'Do it for real?' -DefaultYes $false) {
                        & (Join-Path $script:OnPremDir 'Install-AfsServerEndpoint.ps1') -Context $script:ContextFile -FileServer $server -SharePath $maps -Confirm:$false
                    }
                }
                1 {
                    Write-Explain "This one has the widest blast radius of the three: it changes how EVERY
client on your network resolves Azure storage names. The script proves the
resolver answers with a private address before it writes anything, and
refuses if it does not."
                    $ctxD = Read-AfsJsonc -Path $script:ContextFile
                    $defDns = [string](Get-AfsProp (Get-AfsProp $ctxD.config 'onPremises') 'dnsServers' '')
                    $domD = [string](Get-AfsProp $ctxD.config 'adDomainFqdn' '')
                    $exDns = if ($domD) { 'dc01.' + $domD + ', dc02.' + $domD } else { 'dc01.corp.example.com, dc02.corp.example.com' }
                    $servers = Read-Answer -Question 'Which DNS servers?' -Example $exDns -Why 'Comma-separated. Name every resolver your clients use, not only the domain controllers - Active Directory replicates a forwarder to domain controllers running DNS and nowhere else.' -Default $defDns -Pattern '^[A-Za-z0-9._,\s-]+$' -PatternHelp 'one or more computer names separated by commas'
                    Save-AfsOnPremisesAnswers -DnsServers $servers
                    # Reading zones on a domain controller usually needs an account in DnsAdmins
                    # or Domain Admins, and the signed-in one often is not. Offering it here beats
                    # failing on the read and making someone work out which switch to pass.
                    $dnsCred = $null
                    if (Read-YesNo -Question 'Use a different account to reach the DNS servers?' -Why 'Reading and writing zones needs DnsAdmins or Domain Admins. Answer no to use the account you are signed in with.' -DefaultYes $false) {
                        $dnsCred = Get-Credential -Message 'Account with DnsAdmins or Domain Admins rights'
                    }
                    $dnsArgs = @{ Context = $script:ContextFile; DnsServer = $servers }
                    if ($dnsCred) { $dnsArgs.Credential = $dnsCred }
                    & (Join-Path $script:OnPremDir 'Set-AfsDnsForwarders.ps1') @dnsArgs -WhatIf
                    if (Read-YesNo -Question 'Do it for real?' -DefaultYes $false) {
                        & (Join-Path $script:OnPremDir 'Set-AfsDnsForwarders.ps1') @dnsArgs -Confirm:$false
                    }
                }
                2 {
                    $ctx = Read-AfsJsonc -Path $script:ContextFile
                    $ou = Read-Answer -Question 'Which organizational unit should the storage account live in?' -Why 'A distinguished name. Give one: without it the object lands wherever this machine sits.' -Default ([string](Get-AfsProp $ctx.config 'adOuDn' ''))
                    & (Join-Path $script:OnPremDir 'Join-AfsStorageAccountToAdDs.ps1') -Context $script:ContextFile -OrganizationalUnit $ou -WhatIf
                    if (Read-YesNo -Question 'Do it for real?' -DefaultYes $false) {
                        & (Join-Path $script:OnPremDir 'Join-AfsStorageAccountToAdDs.ps1') -Context $script:ContextFile -OrganizationalUnit $ou -Confirm:$false
                    }
                }
            }
        } catch {
            Write-AfsLogException -ErrorRecord $_ -Context 'on-premises step failed'
            Show-AzureFailure -Message $_.Exception.Message -Context 'That step did not complete.'
        } finally { Pop-Location }
    }
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
    <# The reports this kit produced, ours first. Deliberately NOT everything that matches:
       the governance tool ships its own documentation and writes one page per subscription,
       so listing every match buries the two reports someone actually came for. #>
    $found = @()
    foreach ($pattern in @('assessment.html', 'AS-BUILT-*.html')) {
        $found += @(Get-ChildItem -Path $script:Root -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $skip = $false; foreach ($seg in @('logs', '.git', 'node_modules', '.azgovviz', '.pwsh7')) { if ($_.FullName.Split([IO.Path]::DirectorySeparatorChar) -contains $seg) { $skip = $true } }; -not $skip })
    }
    $ours = @($found | Sort-Object LastWriteTime -Descending)

    # the governance summary only: the top level of governance\, not the per-subscription
    # pages beneath it, and never the tool's own bundled documentation
    $gov = @()
    $govDir = Join-Path $script:Root 'governance'
    if (Test-Path $govDir) {
        $gov = @(Get-ChildItem -Path $govDir -Filter 'AzGovViz*.html' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    }
    return ,@($ours + $gov)
}


function Get-AfsAssessmentReports {
    <# Every assessment.html we can find, newest first, with whatever the file can tell us
       about itself. Reports are generated output and may sit anywhere the operator chose. #>
    $found = @()
    foreach ($dir in @($script:Root, (Join-Path $script:Root 'assessment-latest'))) {
        if (-not (Test-Path $dir)) { continue }
        $found += @(Get-ChildItem -Path $dir -Filter 'assessment.html' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)
    }
    $out = @()
    foreach ($f in ($found | Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending)) {
        # The customer name is in the <h1>; reading it beats making the operator guess from a path.
        $customer = ''
        try {
            $head = Get-Content $f.FullName -TotalCount 60 -ErrorAction SilentlyContinue
            $m = [regex]::Match(($head -join "`n"), '<h1>[^<]*assessment - ([^<]+)</h1>')
            if ($m.Success) { $customer = $m.Groups[1].Value.Trim() }
        } catch { }
        $out += [pscustomobject]@{ File = $f; Customer = $customer }
    }
    return ,$out
}

function Get-AfsReportTabs {
    <# Read the tabs out of the report itself rather than hard-coding a list here. A report
       generated before a tab existed still opens correctly, and adding a tab to the renderer
       needs no change in the wizard. #>
    param([Parameter(Mandatory)][string]$Path)
    $tabs = @()
    try {
        $html = Get-Content $Path -Raw -ErrorAction Stop
        $nav = [regex]::Match($html, '<nav class="tabs">(.*?)</nav>', 'Singleline')
        if (-not $nav.Success) { return ,$tabs }
        foreach ($m in [regex]::Matches($nav.Groups[1].Value, '<button[^>]*data-tab="([a-z0-9-]+)"[^>]*>(.*?)</button>', 'Singleline')) {
            $id = $m.Groups[1].Value
            # strip the count badge and any markup to get the visible label
            $label = [regex]::Replace($m.Groups[2].Value, '<[^>]+>', ' ')
            $label = ([regex]::Replace($label, '\s+', ' ')).Trim()
            $tabs += [pscustomobject]@{ Id = $id; Label = $label }
        }
    } catch { }
    return ,$tabs
}

function Invoke-AssessmentResultsFlow {
    <# Menu entry: go straight to the assessment results, and to the part of them you want. #>
    Write-Title 'Assessment results'

    $reports = Get-AfsAssessmentReports
    if ($reports.Count -eq 0) {
        Write-Note 'no assessment has been run yet.'
        Write-Explain "Run 'Assess an existing environment' first. It exports the configuration
read-only, assesses it, and writes assessment.html beside the export."
        return
    }

    $report = $reports[0]
    if ($reports.Count -gt 1) {
        $labels = @()
        foreach ($r in $reports) {
            $who = if ($r.Customer) { $r.Customer } else { '(no customer name)' }
            $labels += ("{0}  {1}`n         {2}" -f $r.File.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $who,
                        $r.File.FullName.Substring($script:Root.Length + 1))
        }
        $labels += 'Back'
        $c = Read-Choice -Question 'Which assessment?' -Options $labels
        if ($c -eq $reports.Count) { return }
        $report = $reports[$c]
    }

    $path = $report.File.FullName
    $dir  = Split-Path -Parent $path
    Write-Good ($path.Substring($script:Root.Length + 1) + '   ' + $report.File.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))

    # A report written before the subject tabs existed carries only the six original ones. It
    # opens perfectly well - it just cannot show the estate, and nothing on screen would say why.
    $SUBJECT_TABS = @('storage', 'filesync', 'backup', 'network', 'servers', 'adjacent', 'provenance')

    while ($true) {
        $tabs = Get-AfsReportTabs -Path $path
        $ids = @($tabs | ForEach-Object { $_.Id })
        $hasSubjects = @($SUBJECT_TABS | Where-Object { $ids -contains $_ }).Count -gt 0

        # The report records the export it was made from, so it can be rebuilt without asking.
        $srcExport = ''
        $srcCustomer = ''
        $fjson = Join-Path $dir 'findings.json'
        if (Test-Path $fjson) {
            try {
                $fd = Get-Content $fjson -Raw | ConvertFrom-Json
                $srcExport = [string](Get-AfsProp $fd 'export' '')
                $srcCustomer = [string](Get-AfsProp $fd 'customer' '')
            } catch { }
        }
        $canRegen = $srcExport -and (Test-Path $srcExport)

        if (-not $hasSubjects) {
            Write-Host ''
            Write-Note ('this report has ' + $tabs.Count + ' tabs - it was written before the per-subject tabs existed.')
            Write-Explain "Findings, roadmap, scope and rules are all there. What is missing is the
estate itself: Storage, File Sync, Backup, Network, Servers, Guardrails
and Export - the evidence a finding is checked against."
            if ($canRegen) { Write-Explain ('It can be rebuilt from the export it was made from: ' + $srcExport) }
            elseif ($srcExport) { Write-Explain ('Its export is no longer at ' + $srcExport + ', so it cannot be rebuilt from here.') }
        }

        $labels = @('Open the whole report')
        foreach ($t in $tabs) { $labels += ('Open at: ' + $t.Label) }
        $labels += 'Show the headline numbers here'
        $labels += 'Open the folder it is in'
        if ($canRegen) {
            $regenLabel = 'Re-generate this report from its export'
            if (-not $hasSubjects) { $regenLabel += ' (adds the subject tabs)' }
            $labels += $regenLabel
        }
        $labels += 'Back'

        $c = Read-Choice -Question 'What would you like to see?' -Options $labels
        $iCounts = 1 + $tabs.Count
        $iFolder = $iCounts + 1
        $iRegen  = if ($canRegen) { $iFolder + 1 } else { -1 }
        $iBack   = $labels.Count - 1

        if ($c -eq $iBack) { return }

        if ($canRegen -and $c -eq $iRegen) {
            # Same export, same output folder, same name unless it is worth correcting.
            $name = $srcCustomer
            if (-not $name) { $name = 'Customer' }
            $name = Read-Answer -Question 'Name to put on the report?' -Why 'This is only a label - it does not change what is assessed.' -Default $name
            Write-Explain ('Re-assessing ' + $srcExport)
            try {
                & (Join-Path $script:Root 'Assess-AzFileSyncExport.ps1') -ExportPath $srcExport -OutputPath $dir -CustomerName $name | Out-Null
                Write-Good ('rebuilt ' + $path)
                $after = Get-AfsReportTabs -Path $path
                # int + string throws in PowerShell - the int wins the type coercion.
                Write-Good ([string]$after.Count + ' tabs now')
            } catch {
                Write-AfsLogException -ErrorRecord $_ -Context 'report rebuild failed'
                Write-Bad ('the report was not rebuilt: ' + $_.Exception.Message)
            }
            continue
        }

        if ($c -eq $iCounts) {
            # The terminal answer, for when opening a browser is not what you want.
            $fj = Join-Path $dir 'findings.json'
            if (-not (Test-Path $fj)) { Write-Note ('findings.json is not beside the report: ' + $dir); continue }
            try {
                $doc = Get-Content $fj -Raw | ConvertFrom-Json
                Write-Host ''
                foreach ($sev in @('High', 'Medium', 'Low', 'Info')) {
                    $n = 0
                    if ($doc.counts -and ($doc.counts.PSObject.Properties.Name -contains $sev)) { $n = [int]$doc.counts.$sev }
                    $colour = switch ($sev) { 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'DarkGray' } }
                    Write-Host ('    ' + $sev.PadRight(8) + ([string]$n).PadLeft(4)) -ForegroundColor $colour
                }
                $top = @($doc.findings | Where-Object { $_.severity -eq 'High' } | Select-Object -First 5)
                if ($top.Count) {
                    Write-Host ''
                    Write-Host '    highest first:' -ForegroundColor DarkGray
                    foreach ($f in $top) { Write-Host ('      ' + $f.id + '  ' + $f.title) -ForegroundColor DarkGray }
                }
            } catch { Write-Bad ('could not read findings.json: ' + $_.Exception.Message) }
            continue
        }

        if ($c -eq $iFolder) {
            try { Start-Process $dir; Write-Good $dir } catch { Write-Bad $_.Exception.Message }
            continue
        }

        # A fragment only means something on a URI - see the how-to guide for the same trap.
        $target = $path
        if ($c -gt 0) { $target = ([uri]$path).AbsoluteUri + '#' + $tabs[$c - 1].Id }
        try { Start-Process $target; Write-Good $target }
        catch {
            try { Start-Process $path; Write-Good $path; if ($c -gt 0) { Write-Note ('opened at the top - the tab you wanted is ' + $tabs[$c - 1].Label + '.') } }
            catch { Write-Bad ('could not open a browser: ' + $_.Exception.Message); Write-Explain ('Open this file by hand: ' + $path) }
        }
    }
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
            $kind = if ($r.Name -like 'AS-BUILT-*') { 'as-built  ' } elseif ($r.Name -like 'AzGovViz*') { 'governance' } else { 'assessment' }
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
        # Same defect as the governance flow had: an array splat binds positionally.
        $a = @{ ExportPath = $path; CustomerName = $customer }
        if ($private) { $a.PrivateTrafficRequired = $true }
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

function Show-AfsRequirements {
    <#  The deep check. Test-Prerequisites answers "what is installed here"; this answers "will
        the run succeed", which is a different and larger question - it covers the subscription,
        the roles a step needs, and the file server, none of which can be inferred from this
        machine. Read-only throughout. #>
    param([switch]$IncludeServer)

    $cfg = $null
    if (Test-Path $script:InputsFile) {
        try { $cfg = Resolve-AfsConfig -Inputs (Read-AfsJsonc -Path $script:InputsFile) } catch { }
    }

    $all = @()
    $all += Get-AfsLocalRequirements
    $all += Get-AfsAzureRequirements -Config $cfg

    if ($IncludeServer) {
        # Only ever the server the settings name, or one the operator types. Never a guess.
        $fs = ''
        $paths = @()
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'onPremises') -and $cfg.onPremises) {
            $fs = [string](Get-AfsProp $cfg.onPremises 'fileServer' '')
            $sp = Get-AfsProp $cfg.onPremises 'serverPaths'
            if ($sp) { foreach ($p in $sp.PSObject.Properties) { $paths += [string]$p.Value } }
        }
        if (-not $fs) {
            $fs = Read-Answer -Question 'Which file server should I check?' -Why 'Leave empty to skip the server checks.' -AllowEmpty
        }
        if ($fs) {
            $cred = $null
            if (Read-YesNo -Question ('Use a different account to reach ' + $fs + '?') -Why 'Reading the server state needs local-administrator rights there.' -DefaultYes $false) {
                $cred = Get-Credential -Message ('Local administrator on ' + $fs)
            }
            Write-Explain ('Checking ' + $fs + ' - this opens one session and asks everything at once.')
            $all += Get-AfsServerRequirements -FileServer $fs -Credential $cred -Paths $paths
        }
    }

    $area = ''
    foreach ($r in $all) {
        if ($r.Area -ne $area) { $area = $r.Area; Write-Host ''; Write-Host ('  ' + $area) -ForegroundColor White }
        $colour = switch ($r.State) { 'ok' { 'Green' } 'missing' { 'Red' } default { 'Yellow' } }
        $badge  = switch ($r.State) { 'ok' { '[ok]  ' } 'missing' { '[!]   ' } default { '[?]   ' } }
        $sev = if ($r.Severity -eq 'blocker') { '' } else { '  (' + $r.Severity + ')' }
        Write-Host ('    ' + $badge + $r.Name.PadRight(32) + $r.Detail + $sev) -ForegroundColor $colour
        if ($r.State -ne 'ok' -and $r.Fix) { Write-Host ('             ' + $r.Fix) -ForegroundColor DarkGray }
    }

    $v = Get-AfsRequirementVerdict -Results $all
    Write-Host ''
    Write-Host ('  {0} checks - {1} ok, {2} blocker(s), {3} could not be checked, {4} degraded' -f
                $v.Total, $v.Ok, $v.Blockers, $v.UnknownBlockers, $v.Degraded) -ForegroundColor White
    if ($v.Blockers -gt 0) {
        Write-Bad 'there are blockers - these steps cannot succeed until they are fixed.'
        foreach ($b in $v.BlockerList) { Write-Host ('    - ' + $b.Area + ': ' + $b.Name) -ForegroundColor Red }
    } elseif ($v.UnknownBlockers -gt 0) {
        # Saying nothing here would let "I could not check it" read as "it is fine".
        Write-Note ('nothing is known to be broken, but ' + $v.UnknownBlockers + ' requirement(s) could not be checked from here.')
        foreach ($b in $v.UnknownList) { Write-Host ('    ? ' + $b.Area + ': ' + $b.Name + ' - ' + $b.Detail) -ForegroundColor Yellow }
    } else {
        Write-Good 'everything the run needs is in place.'
    }
    return $v
}

function Invoke-RequirementsFlow {
    Write-Title 'Requirements'
    Write-Explain "Two questions, not one. What is installed on this machine, and whether the run
can actually succeed - the subscription, the roles each step needs, and the
file server. All of it read-only."

    if (-not (Test-Prerequisites -ForDeploy)) { return }

    $withServer = Read-YesNo -Question 'Also check the file server?' -Why 'Opens one PowerShell session to it and reads its state. Nothing is changed.' -DefaultYes $true
    [void](Show-AfsRequirements -IncludeServer:$withServer)
}

function Invoke-HowToUseFlow {
    <# The long-form guide. One self-contained page, so it opens from a file share, an
       air-gapped jump box or a customer laptop with nothing installed. #>
    Write-Title 'How to use it'
    Write-Explain "The full guide: every screen, every decision, and the reasons behind the
ones that cannot be undone. It opens in your browser and needs no network."

    $guide = Join-Path $script:Root 'docs\HOW-TO-USE.html'
    if (-not (Test-Path $guide)) {
        Write-Bad ('the guide is missing from this copy of the kit: ' + $guide)
        Write-Explain 'Pull the latest from the repository, or read docs/GETTING-STARTED.md instead.'
        return
    }

    # Each tab is addressable, so "read the DNS part" does not mean "open it and hunt".
    $tabs = @(
        @{ id = 'start';     n = 'Start here';           d = 'What the kit is, the two doors, and every menu option.' },
        @{ id = 'settings';  n = 'Deployment settings';  d = 'The four inputs, what is derived from them, and what cannot be changed later.' },
        @{ id = 'build';     n = 'Build';                d = 'The two phases, the 17 steps, and what the as-built records.' },
        @{ id = 'connect';   n = 'Connect your servers'; d = 'Agent and endpoint, DNS forwarders, AD DS join - the three steps that touch your machines.' },
        @{ id = 'protect';   n = 'Backup and restore';   d = 'What to protect, which tier restores one file, and how to prove it.' },
        @{ id = 'assess';    n = 'Assess';               d = 'Export read-only, assess offline, and what comes out.' },
        @{ id = 'govern';    n = 'Governance';           d = 'The tenant-wide question, and what it needs to answer it.' },
        @{ id = 'teardown';  n = 'Teardown';             d = 'The order, the two things outside the resource group, and the 14-day wait.' },
        @{ id = 'trouble';   n = 'When it goes wrong';   d = 'Real messages from real runs, and what each one actually means.' },
        @{ id = 'reference'; n = 'Reference';            d = 'Layout, dependencies, and the one-way doors in one list.' }
    )

    while ($true) {
        Write-Host ''
        $labels = @('Open the whole guide')
        foreach ($t in $tabs) { $labels += $t.n + "`n         " + $t.d }
        $labels += 'Back'

        $c = Read-Choice -Question 'Where would you like to start?' -Options $labels
        if ($c -eq ($labels.Count - 1)) { return }

        # A fragment takes the reader straight to the section they asked for - but a
        # fragment only means anything on a URI. Appending '#connect' to a Windows path
        # just names a file that does not exist, so build the file:// form for that case.
        $target = $guide
        if ($c -gt 0) { $target = ([uri]$guide).AbsoluteUri + '#' + $tabs[$c - 1].id }
        try {
            Start-Process $target
            Write-Good $target
        } catch {
            # Some locked-down machines have no handler for file:// even though they open
            # .html happily. Losing the fragment beats losing the guide.
            try {
                Start-Process $guide
                Write-Good $guide
                if ($c -gt 0) { Write-Note ('opened at the top - the section you wanted is ' + $tabs[$c - 1].n + '.') }
            } catch {
                Write-Bad ('could not open a browser: ' + $_.Exception.Message)
                Write-Explain ('Open this file by hand: ' + $guide)
            }
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
        @{ f = 'docs/VERSION-CONTROL.md';        n = 'Version control';         d = 'The version scheme, the change ledger, and how to cut a release.' },
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
            'How to use it - the full guide, with diagrams',
            'Deployment settings - names, region, network, backup, directory',
            'Build a new Azure File Sync environment',
            'Assess an existing environment',
            'See the assessment results - every tab, with the detail behind them',
            'Assess policy and governance across the tenant',
            'Remove an environment I built',
            'Check requirements - this machine, Azure, and the file server',
            'Read the documentation',
            'Browse the blueprints, playbooks and runbooks',
            'Connect your on-premises servers (agent, DNS, AD join)',
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
            0 { Invoke-HowToUseFlow }
            1 { Invoke-SettingsFlow }
            2 { Invoke-BuildFlow }
            3 { Invoke-AssessFlow }
            4 { Invoke-AssessmentResultsFlow }
            5 { Invoke-GovernanceFlow }
            6 { Invoke-RemoveFlow }
            7 { Invoke-RequirementsFlow }
            8 { Invoke-DocsFlow }
            9 { Invoke-CodexFlow }
            10 { Invoke-OnPremisesFlow }
            11 { Invoke-ResumeFlow }
            12 { Invoke-ReportsFlow }
            13 { Write-Host ''; Write-Host '  Bye.' -ForegroundColor White; Write-Host ''; Stop-AfsLog -Outcome 'ended by user'; return }
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
