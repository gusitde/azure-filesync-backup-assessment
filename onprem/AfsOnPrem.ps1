<#
  Shared helpers for the three on-premises scripts in this folder.

  These scripts differ from deploy/ in one important way: they touch machines you own -
  a file server, a DNS server, a domain controller - not just Azure. So every helper here
  is built around three ideas:

    1. Say what will happen on which machine before it happens.
    2. Prove the target is reachable and in the expected state before changing it.
    3. Leave a reverse path, and record enough to walk it.

  Dot-source this file; it exports functions only. Logging, config and the Azure CLI wrapper
  come from ..\deploy\AfsLog.ps1 and ..\deploy\AfsConfig.ps1, so an on-premises run appears in
  the same logs/ files as the Azure build.
#>

Set-StrictMode -Version 2.0

$script:AfsOnPremRoot = $PSScriptRoot
$script:AfsDeployDir  = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy'

. (Join-Path $script:AfsDeployDir 'AfsConfig.ps1')
. (Join-Path $script:AfsDeployDir 'AfsLog.ps1')

# ------------------------------------------------------------------- ui ------

function Write-AfsOk    { param([string]$T) Write-AfsLog -Level INFO -Message ("ok: " + $T); Write-Host ("      OK    " + $T) -ForegroundColor Green }
function Write-AfsInfo  { param([string]$T) Write-Host ("      ..    " + $T) -ForegroundColor DarkGray }
function Write-AfsWarn  { param([string]$T) Write-AfsLog -Level WARN -Message $T; Write-Host ("      WARN  " + $T) -ForegroundColor Yellow }
function Write-AfsSay   { param([string]$T) foreach ($l in ($T -split "`n")) { Write-Host ("            " + $l) -ForegroundColor DarkGray } }

function Get-AfsProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function ConvertTo-AfsBool {
    <#  Never compare an Azure CLI answer to the STRING 'true' or 'false'.

        Invoke-AfsAz parses its output as JSON when it can, so `-o tsv` returning "true"
        arrives here as a real boolean. PowerShell then coerces the right-hand side of the
        comparison, and every non-empty string is $true - so `$true -eq 'false'` is TRUE.
        That inverted a storage-account check on the first run of this script and refused a
        correctly configured account. Convert once, compare properly.  #>
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $s = ([string]$Value).Trim()
    if ($s -eq '') { return $Default }
    return [bool]($s -match '^(?i:true|1|yes|enabled|on)$')
}

function ConvertTo-AfsArray {
    <# A function returning an Object[] is emitted as ONE item, so @(f) nests it; and
       'return $array' unwraps a one-element array back to a scalar. Normalise both. #>
    param($Value)
    # ,@() and not @(): an empty array returned bare goes through the pipeline as NOTHING,
    # so the caller gets $null and .Count throws under Set-StrictMode
    if ($null -eq $Value) { return ,@() }
    if ($Value -is [System.Array]) { return ,$Value }
    return ,@($Value)
}

# --------------------------------------------------------------- context -----

function Read-AfsContext {
    <# The deployment context written by phase 1: resolved config + the identity. Everything
       these scripts need about Azure comes from here, so an on-premises run cannot disagree
       with what was built. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Deployment context not found: $Path. Run phase 1 (deploy/Phase1-New-DeploymentIdentity.ps1), or pass -Context."
    }
    $ctx = Read-AfsJsonc -Path $Path
    if (-not (Get-AfsProperty $ctx 'config')) { throw "That file is not a deployment context (no 'config' section): $Path" }
    return $ctx
}

function Get-AfsDeploymentSecret {
    <# The service principal phase 1 created. Used only where an unattended sign-in is
       genuinely needed (registering a server from inside a remote session). Returns $null
       when the secret file is absent - the caller then falls back to the operator session. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$ContextPath)
    $file = Get-AfsProperty $Context.identity 'secretFile'
    if (-not $file) { return $null }
    $path = Join-Path (Split-Path -Parent (Resolve-Path $ContextPath)) $file
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

# ------------------------------------------------------------ credentials ----

function Get-AfsCredential {
    <# One credential, from the least surprising place: an explicit -Credential, then a pair
       of environment variables (for a pipeline), then a prompt. Never written to disk, never
       logged - only the user name is recorded. #>
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [string]$UserName,
        [string]$Message = 'Credential',
        [string]$UserEnvName,
        [string]$PasswordEnvName
    )
    if ($Credential) { return $Credential }
    if ($UserEnvName -and $PasswordEnvName) {
        $u = [Environment]::GetEnvironmentVariable($UserEnvName)
        $p = [Environment]::GetEnvironmentVariable($PasswordEnvName)
        if ($u -and $p) {
            Write-AfsLog -Level DEBUG -Message ("credential taken from " + $UserEnvName + "/" + $PasswordEnvName + " for " + $u)
            return (New-Object System.Management.Automation.PSCredential($u, (ConvertTo-SecureString $p -AsPlainText -Force)))
        }
    }
    if ($UserName) { return (Get-Credential -UserName $UserName -Message $Message) }
    return (Get-Credential -Message $Message)
}

# --------------------------------------------------------------- remoting ----

function Test-AfsRemoting {
    <# Prove WinRM before anything else: a clear message here beats a failure three steps in. #>
    param([Parameter(Mandatory)][string]$ComputerName, [System.Management.Automation.PSCredential]$Credential)
    $p = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
    # Test-WSMan defaults to "no authentication" and rejects a credential unless an
    # authentication method is named - it fails with "credentials were specified along with
    # the 'no authentication' flag", which reads like a WinRM outage and is not one.
    if ($Credential) { $p.Credential = $Credential; $p.Authentication = 'Default' }
    try {
        $null = Test-WSMan @p
        return [pscustomobject]@{ Ok = $true; Detail = 'WinRM responded' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    }
}

function New-AfsSession {
    <# One PSSession reused by every remote step, so the server sees one logon rather than a
       dozen. The caller disposes it in a finally block. #>
    param([Parameter(Mandatory)][string]$ComputerName, [System.Management.Automation.PSCredential]$Credential)
    $p = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
    if ($Credential) { $p.Credential = $Credential }
    Write-AfsLog -Level DEBUG -Message ("opening a PowerShell session to " + $ComputerName + $(if ($Credential) { " as " + $Credential.UserName } else { " as the current user" }))
    return (New-PSSession @p)
}

function Invoke-AfsRemote {
    <# Run a script block on the remote machine, logged like an az call: what ran, how long,
       and the failure text when it fails. -AllowFailure turns an expected "no" into $null. #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [string]$What = 'remote command',
        [switch]$AllowFailure
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-AfsLog -Level DEBUG -Message ("run  [" + $Session.ComputerName + "] " + $What)
    try {
        $out = Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        $sw.Stop()
        Write-AfsLog -Level DEBUG -Message ("ok   [" + $Session.ComputerName + "] " + $What + " in " + $sw.ElapsedMilliseconds + " ms")
        return $out
    } catch {
        $sw.Stop()
        if ($AllowFailure) {
            Write-AfsLog -Level DEBUG -Message ("probe [" + $Session.ComputerName + "] " + $What + " -> " + $_.Exception.Message + " (tolerated)")
            return $null
        }
        Write-AfsLog -Level ERROR -Message ("fail [" + $Session.ComputerName + "] " + $What + ": " + $_.Exception.Message)
        throw
    }
}

function Copy-AfsModuleToSession {
    <# Deliver a PowerShell module to a server that cannot reach the PowerShell Gallery.
       Saves it on this machine first (where the Gallery does work) and copies the folder in.
       This is the documented fallback for a file server with no outbound access to the
       Gallery - which is the common case, and was the case on our own test server. #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)][string[]]$Name,
        [string]$StagingPath
    )
    if (-not $StagingPath) { $StagingPath = Join-Path ([IO.Path]::GetTempPath()) ('afs-modules-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
    New-Item -ItemType Directory -Path $StagingPath -Force | Out-Null
    try {
        foreach ($m in $Name) {
            Write-AfsInfo ("saving " + $m + " for offline install")
            Save-Module -Name $m -Path $StagingPath -Force -ErrorAction Stop
        }
        $dest = Invoke-AfsRemote -Session $Session -What 'find the machine module path' -ScriptBlock {
            $p = ($env:PSModulePath -split ';') | Where-Object { $_ -like "$env:ProgramFiles*" } | Select-Object -First 1
            if (-not $p) { $p = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules' }
            if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
            return $p
        }
        foreach ($dir in (Get-ChildItem $StagingPath -Directory)) {
            Write-AfsInfo ("copying " + $dir.Name + " to " + $Session.ComputerName)
            Copy-Item -Path $dir.FullName -Destination $dest -ToSession $Session -Recurse -Force -ErrorAction Stop
        }
        return $true
    } finally {
        Remove-Item $StagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-AfsRemoteModule {
    <# Make sure a module is importable on the remote machine. Tries the Gallery first
       (bootstrapping the NuGet provider, which a fresh server does not have), then falls
       back to copying from this machine. Idempotent: present is present. #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)][string[]]$Name,
        [switch]$WhatIfMode
    )
    $missing = Invoke-AfsRemote -Session $Session -What 'check installed modules' -ArgumentList (,$Name) -ScriptBlock {
        param($names)
        $out = @()
        foreach ($n in $names) { if (-not (Get-Module -ListAvailable -Name $n)) { $out += $n } }
        return ,$out
    }
    $missing = ConvertTo-AfsArray $missing
    if ($missing.Count -eq 0) { Write-AfsOk ('modules present on ' + $Session.ComputerName + ': ' + ($Name -join ', ')); return $true }
    if ($WhatIfMode) { Write-AfsInfo ('WHATIF would install on ' + $Session.ComputerName + ': ' + ($missing -join ', ')); return $true }

    Write-AfsInfo ('installing on ' + $Session.ComputerName + ': ' + ($missing -join ', '))
    $viaGallery = Invoke-AfsRemote -Session $Session -What 'install modules from the Gallery' -AllowFailure -ArgumentList (,$missing) -ScriptBlock {
        param($names)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
            }
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            foreach ($n in $names) { Install-Module -Name $n -Force -AllowClobber -Scope AllUsers -ErrorAction Stop }
            return $true
        } catch { return $false }
    }
    if (-not $viaGallery) {
        Write-AfsWarn ('the PowerShell Gallery is not reachable from ' + $Session.ComputerName + ' - copying the modules from this machine instead')
        [void](Copy-AfsModuleToSession -Session $Session -Name $missing)
    }
    $still = ConvertTo-AfsArray (Invoke-AfsRemote -Session $Session -What 're-check installed modules' -ArgumentList (,$Name) -ScriptBlock {
        param($names)
        $out = @()
        foreach ($n in $names) { if (-not (Get-Module -ListAvailable -Name $n)) { $out += $n } }
        return ,$out
    })
    if ($still.Count) { throw ('These modules could not be installed on ' + $Session.ComputerName + ': ' + ($still -join ', ') + '. Install them by hand and run this again.') }
    Write-AfsOk ('modules ready on ' + $Session.ComputerName + ': ' + ($Name -join ', '))
    return $true
}

# ------------------------------------------------------------ azure access ---

function Confirm-AfsAzPowerShell {
    <# The Az PowerShell cmdlets and the Azure CLI are two different sign-ins with two
       different current subscriptions. Az.StorageSync has no CLI equivalent for several of
       the calls here, so both have to be right - and a context left pointing at another
       subscription is the failure that looks like "the resource does not exist". #>
    param([Parameter(Mandatory)][string]$SubscriptionId, [string]$TenantId)
    # Importing the Az modules and choosing a subscription are session operations - they
    # change nothing in Azure - so they must run even under -WhatIf. Without the override
    # Set-AzContext returns nothing during a dry run and every later cmdlet aims at whatever
    # subscription the session happened to be on.
    # Import-Module has no -WhatIf, but the Az modules call Update-TypeData while loading and
    # that does - so a dry run prints "What if: Performing the operation Update TypeData" for
    # every type file. Clearing the preference across the import keeps the output readable.
    # The preference has to be cleared GLOBALLY, not locally: a module has its own scope root,
    # so code inside it reads the global $WhatIfPreference rather than the caller's.
    $prevWhatIf = $global:WhatIfPreference
    try {
        $global:WhatIfPreference = $false
        foreach ($m in @('Az.Accounts', 'Az.Storage', 'Az.StorageSync')) {
            if (-not (Get-Module -Name $m)) { Import-Module $m -ErrorAction SilentlyContinue -Verbose:$false | Out-Null }
        }
    } finally { $global:WhatIfPreference = $prevWhatIf }
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) {
        Write-AfsWarn 'no Azure PowerShell session'
        Write-AfsSay "The Azure CLI sign-in does not cover the Az PowerShell cmdlets this script needs.
Sign in once:
  Connect-AzAccount$(if ($TenantId) { ' -Tenant ' + $TenantId })"
        throw 'No Azure PowerShell session. Run Connect-AzAccount, then run this again.'
    }
    if ($ctx.Subscription -and $ctx.Subscription.Id -eq $SubscriptionId) {
        Write-AfsOk ('Azure PowerShell session: ' + $ctx.Account.Id + ' on ' + $ctx.Subscription.Name)
        return $ctx
    }
    Write-AfsInfo ('pointing the Azure PowerShell session at ' + $SubscriptionId)
    $who = $ctx.Account.Id
    try { $ctx = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop -WhatIf:$false }
    catch { throw ('The Azure PowerShell session (' + $who + ') cannot select subscription ' + $SubscriptionId + ': ' + $_.Exception.Message) }
    if (-not $ctx -or -not $ctx.Account) { throw ('The Azure PowerShell session (' + $who + ') could not select subscription ' + $SubscriptionId + '.') }
    Write-AfsOk ('Azure PowerShell session: ' + $ctx.Account.Id + ' on ' + $ctx.Subscription.Name)
    return $ctx
}

function Confirm-AfsCanPrompt {
    <#  A high-impact script asks PowerShell's own "Are you sure?" before each change. That is
        right at a console and impossible anywhere else - and the way it fails is horrible:
        ShouldProcess cannot reach a host to prompt, and throws

            Exception calling "ShouldProcess" with "2" argument(s):
            "Object reference not set to an instance of an object."

        which tells the operator nothing at all.

        Worse, the obvious escape does not work. `powershell -File script.ps1 -Confirm:$false`
        SILENTLY DROPS the parameter - it never binds, $ConfirmPreference stays High, and the
        script fails exactly as if it had not been passed. (-File binds arguments as strings,
        and the colon form of a switch does not survive that.)

        So detect it here, once, and say what to do instead.  #>
    param([Parameter(Mandatory)][hashtable]$BoundParameters, [string]$ScriptName)
    if ($BoundParameters.ContainsKey('Confirm') -or $BoundParameters.ContainsKey('WhatIf')) { return }
    if ($ConfirmPreference -eq 'None') { return }
    if (-not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) { return }

    Write-AfsWarn 'this session cannot show a confirmation prompt, and this script asks for one before every change'
    Write-AfsSay @"
Run it from a PowerShell console, or - to run it unattended - suppress the prompt
in a way that actually binds:

  powershell -Command "& '.\$ScriptName' -Context <context> ... -Confirm:`$false"

-File does NOT work for this: `powershell -File $ScriptName -Confirm:`$false` drops
the parameter silently and the script still tries to prompt.

start.ps1 already calls these scripts correctly.
"@
    throw 'No console is available to confirm against. See the note above.'
}

function Test-AfsAzureWriteScope {
    <# Answer one question before a step that needs more than Contributor: does the CURRENT
       session hold a role that can create role assignments at this scope? Creating a File
       Sync cloud endpoint does exactly that (it grants the sync service reader access to the
       storage account), which is why Contributor alone fails with AuthorizationFailed. #>
    param([Parameter(Mandatory)][string]$Scope)
    $upn = Invoke-AfsAz -Args @('account', 'show', '--query', 'user.name', '-o', 'tsv') -AllowFailure
    if (-not $upn) { return [pscustomobject]@{ Ok = $false; Who = $null; Roles = @(); Detail = 'not signed in' } }
    $roles = ConvertTo-AfsArray (Invoke-AfsAz -Args @('role', 'assignment', 'list', '--assignee', $upn, '--scope', $Scope, '--include-inherited', '--query', '[].roleDefinitionName', '-o', 'json') -AllowFailure)
    $good = @('Owner', 'User Access Administrator', 'Azure File Sync Administrator', 'Role Based Access Control Administrator')
    $has = @($roles | Where-Object { $good -contains $_ })
    return [pscustomobject]@{
        Ok     = ($has.Count -gt 0)
        Who    = $upn
        Roles  = $roles
        Detail = $(if ($has.Count) { 'holds ' + ($has -join ', ') } else { 'holds ' + $(if ($roles.Count) { ($roles -join ', ') } else { 'no role at this scope' }) })
    }
}

function Get-AfsRegisteredServer {
    <# Find a registered server by name, tolerantly. Registration records the FriendlyName the
       agent reports, which may be the short name (FS01) or the fully qualified one
       (FS01.CORP.EXAMPLE.COM) depending on the machine - so an exact match against either
       form misses half the time, and the caller then decides the server is not registered
       when it plainly is. Compare the first label, case-insensitively. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$StorageSyncService,
        [Parameter(Mandatory)][string]$ComputerName
    )
    $short = ($ComputerName -split '\.')[0]
    $all = ConvertTo-AfsArray (Get-AzStorageSyncServer -ResourceGroupName $ResourceGroup -StorageSyncServiceName $StorageSyncService -ErrorAction SilentlyContinue)
    foreach ($s in $all) {
        $name = [string](Get-AfsProperty $s 'FriendlyName' '')
        if (-not $name) { $name = [string](Get-AfsProperty $s 'ServerName' '') }
        if (($name -split '\.')[0] -ieq $short) { return $s }
    }
    return $null
}

function Get-AfsSyncGroupName {
    <# One sync group per Azure file share, because a sync group holds exactly one cloud
       endpoint. Derived so the on-premises script and the build cannot drift apart. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ShareName)
    $prefix = Get-AfsProperty $Config 'namePrefix' 'afs'
    return ('sg-' + $prefix + '-' + $ShareName)
}

# ------------------------------------------------------------------ steps ----

$script:AfsStepNo = 0
$script:AfsStepTotal = 0
$script:AfsActivity = 'Azure File Sync - on-premises'

function Set-AfsStepTotal { param([int]$Total, [string]$Activity) $script:AfsStepNo = 0; $script:AfsStepTotal = $Total; if ($Activity) { $script:AfsActivity = $Activity } }

function Write-AfsStep {
    param([string]$Text)
    $script:AfsStepNo++
    Write-AfsLog -Level STEP -Message ('[' + $script:AfsStepNo + '] ' + $Text)
    Write-Host ''
    Write-AfsPhaseStrip -Done ($script:AfsStepNo - 1) -Total $script:AfsStepTotal
    Write-Host ("[{0}/{1}] {2}" -f $script:AfsStepNo, $script:AfsStepTotal, $Text) -ForegroundColor Cyan
    Write-AfsProgress -Activity $script:AfsActivity -Status $Text -Step $script:AfsStepNo -Total $script:AfsStepTotal
}

function Complete-AfsSteps {
    param([string]$Outcome)
    Complete-AfsProgress -Activity $script:AfsActivity
    Write-Host ''
    Write-AfsPhaseStrip -Done $script:AfsStepTotal -Total $script:AfsStepTotal
    Write-Host '======================================' -ForegroundColor White
    if ($Outcome) { Write-Host $Outcome -ForegroundColor Green }
}
