#Requires -Version 5.1
<#
  AfsRequirements.ps1 - what must be true before a step can succeed.

  The wizard's own prerequisite check answers "what is installed on this machine". That is a
  smaller question than "will this run work", and the difference is where the time goes: on
  2026-09-04 a run spent twenty minutes on an agent install that could never have succeeded,
  and a DNS step failed on a module the check had reported only as a note.

  Three rules shape this file:

    1. THREE STATES, NOT TWO. 'unknown' is a first-class answer. "I could not check this" must
       never be reported as ok - that is how a check becomes worse than no check.
    2. SEVERITY DECIDES THE VERDICT. A blocker means the step cannot succeed; the caller stops.
       Degraded means it works but worse. Advisory is worth knowing. The old check returned
       $true while printing a warning that the forwarder step would fail.
    3. READ-ONLY, NON-INTERACTIVE, AND IT MUST NOT THROW. It runs before anything else, often
       on a machine that has nothing installed, and a checker that dies is a checker that lies.

  Remote probes run only when the caller supplies the target. Never guess a hostname.
#>

Set-StrictMode -Version 2.0

function New-AfsReq {
    <# One requirement result. Detail carries the OBSERVED value - a bare 'missing' is not
       actionable, and 'ok' with no evidence is not verifiable. #>
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('ok', 'missing', 'unknown')][string]$State = 'unknown',
        [ValidateSet('blocker', 'degraded', 'advisory')][string]$Severity = 'blocker',
        [string]$Detail = '',
        [string]$Fix = '',
        [switch]$Remote
    )
    return [pscustomobject]@{
        Area = $Area; Name = $Name; State = $State; Severity = $Severity
        Detail = $Detail; Fix = $Fix; Remote = [bool]$Remote
    }
}

function Invoke-AfsProbe {
    <# Run one probe and turn ANY failure into 'unknown' with the reason. The whole point of
       this file is that it cannot throw, so every probe goes through here. #>
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Probe,
        [string]$Severity = 'blocker',
        [string]$Fix = '',
        [switch]$Remote
    )
    try {
        $r = & $Probe
        if ($null -eq $r) { return (New-AfsReq -Area $Area -Name $Name -State 'unknown' -Severity $Severity -Detail 'the probe returned nothing' -Fix $Fix -Remote:$Remote) }
        # a probe returns @{ State; Detail; Fix }
        $st = 'unknown'; $dt = ''; $fx = $Fix
        if ($r -is [hashtable]) {
            if ($r.ContainsKey('State'))  { $st = [string]$r['State'] }
            if ($r.ContainsKey('Detail')) { $dt = [string]$r['Detail'] }
            if ($r.ContainsKey('Fix') -and $r['Fix']) { $fx = [string]$r['Fix'] }
        } else {
            $st = if ($r) { 'ok' } else { 'missing' }
        }
        return (New-AfsReq -Area $Area -Name $Name -State $st -Severity $Severity -Detail $dt -Fix $fx -Remote:$Remote)
    } catch {
        return (New-AfsReq -Area $Area -Name $Name -State 'unknown' -Severity $Severity -Detail ('probe failed: ' + $_.Exception.Message) -Fix $Fix -Remote:$Remote)
    }
}

# ============================================================== local tooling ==

function Get-AfsLocalRequirements {
    $out = @()

    $out += Invoke-AfsProbe -Area 'This machine' -Name 'Windows PowerShell 5.1' -Probe {
        $v = $PSVersionTable.PSVersion
        if ($v.Major -eq 5 -and $v.Minor -ge 1) { return @{ State = 'ok'; Detail = $v.ToString() } }
        if ($v.Major -ge 6) { return @{ State = 'missing'; Detail = ('running ' + $v.ToString() + ' - the AD DS join needs Windows PowerShell 5.1, which AzFilesHybrid requires') } }
        return @{ State = 'missing'; Detail = $v.ToString() }
    } -Fix 'Run from Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).'

    foreach ($m in @('Az.Accounts', 'Az.Storage', 'Az.StorageSync')) {
        $out += Invoke-AfsProbe -Area 'This machine' -Name ('module ' + $m) -Probe {
            $found = @(Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
            if ($found.Count) { return @{ State = 'ok'; Detail = ('v' + $found[0].Version) } }
            return @{ State = 'missing'; Detail = 'not installed' }
        } -Fix ('Install-Module ' + $m + ' -Scope CurrentUser')
    }

    # These two are named as blockers because in practice their absence stops the step dead -
    # see the DnsServer note below; the "it falls back to remoting" theory needs rights on a
    # domain controller that a normal domain account does not have.
    $out += Invoke-AfsProbe -Area 'This machine' -Name 'RSAT ActiveDirectory module' -Severity 'blocker' -Probe {
        if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue) { return @{ State = 'ok'; Detail = 'present' } }
        return @{ State = 'missing'; Detail = 'AzFilesHybrid fails with "requires an elevated PowerShell session", which names the wrong cause' }
    } -Fix 'Install-WindowsFeature RSAT-AD-PowerShell   (elevated, once)'

    $out += Invoke-AfsProbe -Area 'This machine' -Name 'RSAT DnsServer module' -Severity 'blocker' -Probe {
        if (Get-Module -ListAvailable -Name DnsServer -ErrorAction SilentlyContinue) { return @{ State = 'ok'; Detail = 'present' } }
        return @{ State = 'missing'; Detail = 'Get-DnsServerZone does not exist here; the remoting fallback needs rights ON the DNS server' }
    } -Fix 'Install-WindowsFeature RSAT-DNS-Server   (elevated, once)'

    $out += Invoke-AfsProbe -Area 'This machine' -Name 'PowerShell 7 (governance only)' -Severity 'degraded' -Probe {
        $portable = Join-Path (Split-Path -Parent $PSScriptRoot) '.pwsh7\pwsh.exe'
        if (Test-Path $portable) { return @{ State = 'ok'; Detail = 'portable copy in .pwsh7' } }
        $p = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($p) { return @{ State = 'ok'; Detail = $p.Source } }
        return @{ State = 'missing'; Detail = 'the governance assessment needs 7.0.3+; everything else runs on 5.1' }
    } -Fix 'Extract the PowerShell 7 zip to .pwsh7 beside the repo - no administrator needed.'

    return ,$out
}

# ================================================================ azure access ==

function Get-AfsAzureRequirements {
    <# Needs a resolved config to know which subscription and which resources to ask about.
       Every call is a read. #>
    param($Config)
    $out = @()
    $sub = ''
    if ($Config -and ($Config.PSObject.Properties.Name -contains 'subscriptionId')) { $sub = [string]$Config.subscriptionId }

    $out += Invoke-AfsProbe -Area 'Azure' -Name 'signed in' -Probe {
        $who = Invoke-AfsAz -Args @('account', 'show', '--query', 'user.name', '-o', 'tsv') -AllowFailure
        if ($who) { return @{ State = 'ok'; Detail = [string]$who } }
        return @{ State = 'missing'; Detail = 'no Azure CLI session' }
    } -Fix 'az login'

    if (-not $sub) {
        $out += New-AfsReq -Area 'Azure' -Name 'subscription' -State 'unknown' -Detail 'no resolved config was supplied, so nothing subscription-scoped could be checked' -Fix 'Open Deployment settings and fill in the subscription id.'
        return ,$out
    }

    # The five namespaces the build creates in. A subscription that has never used a service has
    # its provider switched off, and the first create fails with MissingSubscriptionRegistration -
    # a message that names nothing the operator did.
    foreach ($ns in @('Microsoft.Storage', 'Microsoft.Network', 'Microsoft.StorageSync', 'Microsoft.RecoveryServices', 'Microsoft.Insights')) {
        $out += Invoke-AfsProbe -Area 'Azure' -Name ('provider ' + $ns) -Probe {
            $s = Invoke-AfsAz -Args @('provider', 'show', '-n', $ns, '--query', 'registrationState', '-o', 'tsv', '--subscription', $sub) -AllowFailure
            if (-not $s) { return @{ State = 'unknown'; Detail = 'could not read the registration state' } }
            if ([string]$s -eq 'Registered') { return @{ State = 'ok'; Detail = 'Registered' } }
            return @{ State = 'missing'; Detail = [string]$s }
        } -Fix ('az provider register -n ' + $ns + ' --subscription ' + $sub)
    }

    # Creating a cloud endpoint creates a ROLE ASSIGNMENT (the sync service gets reader on the
    # storage account). Contributor explicitly cannot do that - this is the single most common
    # "why did it fail at the last step" on this kit.
    $out += Invoke-AfsProbe -Area 'Azure' -Name 'role assignment rights' -Severity 'blocker' -Probe {
        $me = Invoke-AfsAz -Args @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv') -AllowFailure
        if (-not $me) { return @{ State = 'unknown'; Detail = 'could not read the signed-in user' } }
        $roles = Invoke-AfsAz -Args @('role', 'assignment', 'list', '--assignee', [string]$me, '--all',
                                      '--query', '[].roleDefinitionName', '-o', 'json', '--subscription', $sub) -AllowFailure
        $names = @()
        if ($roles) { try { $names = @(($roles | ConvertFrom-Json)) } catch { } }
        $good = @($names | Where-Object { $_ -in @('Owner', 'User Access Administrator', 'Azure File Sync Administrator', 'Role Based Access Control Administrator') })
        if ($good.Count) { return @{ State = 'ok'; Detail = ($good -join ', ') } }
        if (-not $names.Count) { return @{ State = 'unknown'; Detail = 'no role assignments were returned - Graph may be blocked for this account' } }
        return @{ State = 'missing'; Detail = ('holds only: ' + (($names | Select-Object -Unique) -join ', ')) }
    } -Fix 'Grant Owner, User Access Administrator, or Azure File Sync Administrator on the storage account. Contributor is not enough - it cannot create the role assignment a cloud endpoint needs.'

    return ,$out
}

# ========================================================== the file server ==

function Get-AfsServerRequirements {
    <# The gap that cost twenty minutes: everything here is a property of ANOTHER machine, so
       none of it can be inferred from this one. Runs only when a server is named. #>
    param([string]$FileServer, [System.Management.Automation.PSCredential]$Credential, [string[]]$Paths)

    $out = @()
    if (-not $FileServer) {
        return ,@((New-AfsReq -Area 'File server' -Name 'server readiness' -State 'unknown' `
            -Detail 'no file server was named, so nothing server-side could be checked' `
            -Fix 'Pass -FileServer, or set onPremises.fileServer in deploy\inputs.json.' -Remote))
    }

    $out += Invoke-AfsProbe -Area 'File server' -Name ('reachable: ' + $FileServer) -Remote -Probe {
        if (-not (Test-Connection -ComputerName $FileServer -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
            return @{ State = 'missing'; Detail = 'does not answer ping (which some networks block - check WinRM below regardless)' }
        }
        return @{ State = 'ok'; Detail = 'answers' }
    } -Fix 'Check the name and the network path.'

    # The kit builds sessions over plain HTTP 5985 - it has no -UseSSL switch, so a server that
    # only listens on 5986 cannot be driven by it at all.
    $out += Invoke-AfsProbe -Area 'File server' -Name 'WinRM on 5985' -Remote -Probe {
        $t = Test-NetConnection -ComputerName $FileServer -Port 5985 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($t -and $t.TcpTestSucceeded) { return @{ State = 'ok'; Detail = 'listening' } }
        $s = Test-NetConnection -ComputerName $FileServer -Port 5986 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($s -and $s.TcpTestSucceeded) { return @{ State = 'missing'; Detail = 'only 5986 (HTTPS) answers - this kit builds sessions over HTTP 5985 and has no -UseSSL option' } }
        return @{ State = 'missing'; Detail = 'neither 5985 nor 5986 answers' }
    } -Fix 'Enable-PSRemoting -Force   (on the file server, elevated)'

    # Everything below needs a session. One session, many questions - a remote round trip per
    # check would make this unusably slow.
    $sess = $null
    try {
        $p = @{ ComputerName = $FileServer; ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        $sess = New-PSSession @p
    } catch {
        $out += New-AfsReq -Area 'File server' -Name 'PowerShell session' -State 'missing' -Remote `
            -Detail ('could not open a session: ' + $_.Exception.Message) `
            -Fix 'Supply a credential with local-administrator rights on that server (the wizard offers one).'
        return ,$out
    }
    $out += New-AfsReq -Area 'File server' -Name 'PowerShell session' -State 'ok' -Detail 'opened' -Remote

    $state = $null
    try {
        $state = Invoke-Command -Session $sess -ArgumentList (,$Paths) -ScriptBlock {
            param($paths)
            $o = @{}
            $o.Build = [System.Environment]::OSVersion.Version.Build
            $o.Caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
            $o.PSVersion = $PSVersionTable.PSVersion.ToString()
            try { $o.NetRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release } catch { $o.NetRelease = 0 }
            try { $a = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\Agent' -ErrorAction Stop; $o.AgentVersion = [string]$a.Version } catch { $o.AgentVersion = '' }
            try { $o.Filter = [bool](@(& fltmc.exe filters 2>$null) -match 'StorageSync') } catch { $o.Filter = $null }
            try {
                $pf = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
                $o.PendingSync = @($pf | Where-Object { $_ -match 'StorageSync' }).Count
            } catch { $o.PendingSync = 0 }
            try { $o.Scheduler = (Get-Service Schedule -ErrorAction Stop).Status.ToString() } catch { $o.Scheduler = '' }
            try { $o.Modules = @(Get-Module -ListAvailable -Name Az.Accounts, Az.StorageSync -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Select-Object -Unique) } catch { $o.Modules = @() }
            $o.Paths = @()
            foreach ($x in @($paths)) {
                if (-not $x) { continue }
                $row = @{ Path = $x; Exists = (Test-Path -LiteralPath $x); Root = ''; FS = ''; System = $false }
                try {
                    $row.Root = [System.IO.Directory]::GetDirectoryRoot($x)
                    $row.System = ($row.Root -eq ($env:SystemDrive + '\'))
                    $v = Get-Volume -FilePath $x -ErrorAction SilentlyContinue
                    if ($v) { $row.FS = [string]$v.FileSystemType }
                } catch { }
                $o.Paths += $row
            }
            return $o
        }
    } catch {
        $out += New-AfsReq -Area 'File server' -Name 'server state' -State 'unknown' -Remote -Detail ('could not read it: ' + $_.Exception.Message)
        Remove-PSSession $sess -ErrorAction SilentlyContinue
        return ,$out
    }

    $out += Invoke-AfsProbe -Area 'File server' -Name 'supported Windows Server' -Remote -Probe {
        $ok = @(14393, 17763, 20348, 26100) -contains $state.Build
        if ($ok) { return @{ State = 'ok'; Detail = ([string]$state.Caption + '  (build ' + $state.Build + ')') } }
        return @{ State = 'missing'; Detail = ([string]$state.Caption + '  (build ' + $state.Build + ') - Azure File Sync supports 2016, 2019, 2022 and 2025') }
    }

    $out += Invoke-AfsProbe -Area 'File server' -Name '.NET Framework 4.7.2+' -Remote -Probe {
        if ([int]$state.NetRelease -ge 461808) { return @{ State = 'ok'; Detail = ('release ' + $state.NetRelease) } }
        if ([int]$state.NetRelease -eq 0) { return @{ State = 'unknown'; Detail = 'the release key could not be read' } }
        return @{ State = 'missing'; Detail = ('release ' + $state.NetRelease + ' is below 4.7.2 (461808)') }
    } -Fix 'Install .NET Framework 4.7.2 or later on the file server.'

    # THE one that cost twenty minutes on 2026-09-04.
    $out += Invoke-AfsProbe -Area 'File server' -Name 'no half-removed agent' -Remote -Probe {
        if ($null -eq $state.Filter) { return @{ State = 'unknown'; Detail = 'fltmc could not be run by this credential' } }
        if ($state.AgentVersion) { return @{ State = 'ok'; Detail = ('agent ' + $state.AgentVersion + ' installed') } }
        if ($state.Filter -or [int]$state.PendingSync -gt 0) {
            return @{ State = 'missing'; Detail = 'no agent, but the StorageSync filter is still loaded / renames are pending - an install here fails with MSI 1603 about seven seconds in' }
        }
        return @{ State = 'ok'; Detail = 'no agent, and nothing left over - clean to install' }
    } -Fix 'Restart the file server. An agent uninstall returns 3010 (restart required) and the filter cannot unload until it does.'

    $out += Invoke-AfsProbe -Area 'File server' -Name 'Task Scheduler running' -Remote -Probe {
        if ($state.Scheduler -eq 'Running') { return @{ State = 'ok'; Detail = 'Running' } }
        return @{ State = 'missing'; Detail = ('Schedule service is ' + $state.Scheduler + ' - the agent MSI is launched from a scheduled task, because the installer closes PowerShell sessions') }
    } -Fix 'Start-Service Schedule   (on the file server)'

    $out += Invoke-AfsProbe -Area 'File server' -Name 'Az modules on the server' -Severity 'degraded' -Remote -Probe {
        $have = @($state.Modules)
        if ($have.Count -ge 2) { return @{ State = 'ok'; Detail = ($have -join ', ') } }
        return @{ State = 'missing'; Detail = ('registration runs ON the server and needs Az.Accounts + Az.StorageSync there; found: ' + $(if ($have.Count) { $have -join ', ' } else { 'neither' })) }
    } -Fix 'The install step installs them, falling back to copying from this machine when the Gallery is unreachable.'

    foreach ($row in @($state.Paths)) {
        $out += Invoke-AfsProbe -Area 'File server' -Name ('path ' + $row.Path) -Remote -Probe {
            if (-not $row.Exists) { return @{ State = 'missing'; Detail = 'does not exist on that server' } }
            if ($row.FS -and $row.FS -ne 'NTFS') { return @{ State = 'missing'; Detail = ('is ' + $row.FS + ' - Azure File Sync needs NTFS') } }
            if ($row.System) { return @{ State = 'missing'; Detail = ('is on the system volume ' + $row.Root + ' - cloud tiering is not supported there'); Fix = 'Choose a path on a non-system NTFS volume.' } }
            return @{ State = 'ok'; Detail = ($row.FS + ' on ' + $row.Root) }
        } -Fix 'Use a local NTFS path on a non-system volume - not a mapped drive and not a UNC path.'
    }

    Remove-PSSession $sess -ErrorAction SilentlyContinue
    return ,$out
}

# ==================================================================== verdict ==

function Get-AfsRequirementVerdict {
    <# One place decides pass/fail, so no caller has to re-derive it - and an 'unknown' blocker
       is NOT a pass. #>
    param([Parameter(Mandatory)]$Results)
    $r = @($Results)
    $blockers = @($r | Where-Object { $_.Severity -eq 'blocker' -and $_.State -eq 'missing' })
    $unknownBlockers = @($r | Where-Object { $_.Severity -eq 'blocker' -and $_.State -eq 'unknown' })
    return [pscustomobject]@{
        Total = $r.Count
        Ok = @($r | Where-Object { $_.State -eq 'ok' }).Count
        Blockers = $blockers.Count
        UnknownBlockers = $unknownBlockers.Count
        Degraded = @($r | Where-Object { $_.Severity -eq 'degraded' -and $_.State -ne 'ok' }).Count
        # Only a PROVEN-missing blocker stops the run. An unknown one does not - blocking on
        # "I could not check" would make the gate unusable behind a locked-down Graph or without
        # a server credential - but it is counted and printed, so it is never mistaken for a pass.
        CanProceed = ($blockers.Count -eq 0)
        BlockerList = $blockers
        UnknownList = $unknownBlockers
    }
}
