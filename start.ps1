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
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root      = $PSScriptRoot
$script:DeployDir = Join-Path $script:Root 'deploy'
$script:InputsFile = Join-Path $script:DeployDir 'inputs.json'
$script:ContextFile = Join-Path $script:DeployDir 'deployment-context.json'

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
    Write-Host ''
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Rule
}

function Write-Explain {
    param([string]$Text)
    foreach ($line in ($Text -split "`n")) { Write-Host ("  " + $line) -ForegroundColor DarkGray }
}

function Write-Good { param([string]$T) Write-Host ("  [ok]   " + $T) -ForegroundColor Green }
function Write-Bad  { param([string]$T) Write-Host ("  [!]    " + $T) -ForegroundColor Red }
function Write-Note { param([string]$T) Write-Host ("  [i]    " + $T) -ForegroundColor Yellow }

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
        if (-not $a) { return $DefaultYes }
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
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $Options.Count) { return ([int]$a - 1) }
        Write-Bad ("choose 1 to " + $Options.Count)
    }
}

function Invoke-Cli {
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFailure)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & az @Args 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        throw (($out | Out-String).Trim())
    }
    $out = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $text = ($out | Out-String).Trim()
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $text }
}

function ConvertTo-Array {
    <#  @(Invoke-Cli ...) does NOT flatten: a function returning an Object[] is emitted as a
        single item, so the array subexpression yields one element containing the array. That
        turned a six-subscription menu into one entry with every name concatenated. Normalise
        here instead. #>
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return $Value }
    return @($Value)
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
        $labels = @($subs | ForEach-Object { "$($_.name)   ($($_.id))" })
        $idx = Read-Choice -Question 'Which subscription?' -Options $labels
        $subId = $subs[$idx].id
    } else {
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

function Invoke-BuildFlow {
    if (-not (Test-Prerequisites -ForDeploy)) { return }

    if (Test-Path $script:InputsFile) {
        Write-Title 'Your answers'
        Write-Good ("found " + $script:InputsFile)
        if (Read-YesNo -Question 'Answer the questions again?' -DefaultYes $false) { New-InputsFile }
    } else {
        New-InputsFile
    }
    if (-not (Test-Path $script:InputsFile)) { Write-Bad 'no inputs file; cannot continue.'; return }

    # show what will be built
    Write-Title 'What this will create'
    Push-Location $script:DeployDir
    try {
        & (Join-Path $script:DeployDir 'Deploy-AfsEnvironment.ps1') -InputFile $script:InputsFile -ShowResolved
    } finally { Pop-Location }

    if (-not (Read-YesNo -Question 'Does that look right?' -DefaultYes $true)) {
        Write-Note 'nothing has been changed. Re-run and answer the questions again.'
        return
    }

    # sign in
    $inputs = Get-Content $script:InputsFile -Raw | ConvertFrom-Json
    $acct = Ensure-SignedIn -TenantId $inputs.entraGlobalAdmin.tenantId
    if (-not $acct) { return }

    # phase 1
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

    Write-Title 'Phase 2 - building'
    Push-Location $script:DeployDir
    try {
        & (Join-Path $script:DeployDir 'Deploy-AfsEnvironment.ps1') -Context $script:ContextFile
    } catch {
        Write-Bad $_.Exception.Message
        Write-Explain "The script is idempotent - fix the cause and run this again. It continues
from where it stopped rather than starting over."
        Pop-Location
        return
    }
    Pop-Location

    Write-Title 'Done'
    Write-Explain "Three things still need a human, on a specific machine:
  1. install the Azure File Sync agent on the file server and register it
  2. point your on-premises DNS at the resolver IP shown above, for the
     privatelink zones only
  3. domain-join the storage account, from a domain-joined machine

docs/AS-BUILT-TEMPLATE.md tells you what to capture as evidence."
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
        Write-Note 'the export makes only read calls - no keys, no SAS, no data.'
        if (-not (Read-YesNo -Question 'Run the export now?' -DefaultYes $true)) { return }
        Push-Location $script:Root
        try { & (Join-Path $script:Root 'Export-AzFileSyncEnvironment.ps1') }
        catch { Write-Bad $_.Exception.Message }
        finally { Pop-Location }
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
    } catch { Write-Bad $_.Exception.Message }
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

# ------------------------------------------------------------------ main ----

Write-Banner
Write-Host ''
Write-Explain "This walks you through whichever job you are here for. Nothing is changed
without showing you first and asking."

while ($true) {
    try {
        $c = Read-Choice -Question 'What would you like to do?' -Options @(
        'Build a new Azure File Sync environment',
        'Assess an existing environment',
        'Remove an environment I built',
        'Just check my prerequisites',
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
            4 { Write-Host ''; Write-Host '  Bye.' -ForegroundColor White; Write-Host ''; return }
        }
    } catch {
        Write-Host ''
        Write-Bad $_.Exception.Message
        Write-Explain 'Nothing further was changed. You can choose again, or quit.'
    }
    Write-Host ''
    Write-Rule
}
