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

# ============================================================= the DNS servers ==

function Get-AfsDnsRequirements {
    <#  The forwarder step changes name resolution for EVERY storage endpoint under
        file.core.windows.net and afs.azure.net - every account, not just this one - from two
        zones written on a domain controller. That blast radius is why the area is checked
        before the run rather than during it.

        Four things Set-AfsDnsForwarders.ps1 never checks are checked here, because each one
        produces a clean-looking, exit-0 run over a live outage:

          - whether the DNS SERVERS can reach the resolver. The script gates on the answer it
            gets, but it asks from the operator machine; nothing asks from the servers that
            will actually do the forwarding.
          - whether -ReplicationScope Forest is legal on each named server. The default is
            Forest, one scope is applied to the whole -DnsServer list, and a member server
            throws mid-run - after the servers before it were already changed, with no rollback.
          - whether a zone already forwards somewhere else. The script detects that, leaves it
            alone by design, and still prints "Conditional forwarders in place."
          - whether a zone of that name already exists as authoritative data.

        Read-only: it reads zones and asks questions. It never creates, repoints or removes
        one, and it never prompts - the caller passes any credential in.

        Two inferences are deliberately weaker than they look, because both feed a BLOCKER and
        a wrong blocker stops the whole run (Get-AfsRequirementVerdict fails on a proven-missing
        blocker, never on an unknown one):

          - a session that does not open is 'missing' only when the server authenticated us and
            said no. Anything else is 'unknown' - unchecked, not proven wrong.
          - a resolver that does not answer for a public canary name is 'missing' only when port
            53 is shut as well. A private resolver that refuses recursion for public names still
            answers the zones linked to its virtual network, and that is the only lookup the
            script itself gates on.  #>
    param([string[]]$DnsServer, [System.Management.Automation.PSCredential]$Credential, [string]$ResolverIpAddress)

    $area = 'DNS servers'
    $out = @()

    # powershell -File passes -DnsServer a,b as ONE string. The wizard splits it and so does the
    # forwarder script; accept either shape rather than probing a host called "a,b".
    $servers = @()
    foreach ($s in @($DnsServer)) {
        if (-not $s) { continue }
        foreach ($part in ([string]$s -split '[,;]')) {
            $t = $part.Trim()
            if ($t) { $servers += $t }
        }
    }
    $servers = @($servers | Select-Object -Unique)

    if (-not $servers.Count) {
        return ,@((New-AfsReq -Area $area -Name 'DNS readiness' -State 'unknown' -Severity 'blocker' -Remote `
            -Detail 'no DNS server was named, so no forwarder, zone type, replication scope or path to the resolver could be checked' `
            -Fix 'Pass -DnsServer <dc1>,<dc2>, or set onPremises.dnsServers in deploy\inputs.json.'))
    }

    # The PUBLIC zones. The forwarder script derives these by stripping "privatelink." from the
    # context, and refuses a privatelink zone outright.
    $zones = @('file.core.windows.net', 'afs.azure.net')

    # A port test that cannot hang - Test-NetConnection has no timeout on 5.1.
    $tcp = {
        param($hostName, $port, $ms)
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $c.BeginConnect($hostName, $port, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($ms, $false)) { return $false }
            $c.EndConnect($ar)
            return $true
        } catch { return $false } finally { $c.Close() }
    }

    # Remoting hands back a hashtable or a deserialized object, and StrictMode turns a missing
    # key into an exception rather than a $null. One reader, so no probe dies on a shape.
    $get = {
        param($obj, $key, $fallback)
        try {
            if ($null -eq $obj) { return $fallback }
            $v = $obj.$key
            if ($null -eq $v) { return $fallback }
            return $v
        } catch { return $fallback }
    }

    $out += New-AfsReq -Area $area -Name 'zones to be forwarded' -State 'ok' -Severity 'advisory' `
        -Detail ('the PUBLIC zones ' + ($zones -join ' and ') + ' - a forwarder on privatelink.* is never consulted, because the client never asks for that name (docs\AS-BUILT-TEMPLATE.md and the blueprint intro say the opposite; the script and the playbook are right)')

    # Not a duplicate of the machine-level module check: this says which route Set-AfsDnsForwarders
    # will take, and therefore how good its error text will be. This check always reads over a
    # session, so what IT proves is the session route.
    $out += Invoke-AfsProbe -Area $area -Name 'how zones will be read' -Severity 'degraded' -Probe {
        $m = @(Get-Module -ListAvailable -Name DnsServer -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
        if ($m.Count) {
            return @{ State = 'ok'; Detail = ('RSAT DnsServer v' + $m[0].Version + ' here, so Set-AfsDnsForwarders.ps1 tries Get-DnsServerZone -ComputerName before falling back to remoting. That module is CIM-based, so it still needs WinRM on each server - RSAT buys better errors, not independence from WinRM') }
        }
        return @{ State = 'missing'; Detail = 'not installed here, so every DnsServer cmdlet falls back to a remoting session on the DNS server, which needs rights on a domain controller that a plain domain account does not have' }
    } -Fix 'Install-WindowsFeature RSAT-DNS-Server   (elevated, once)   |   Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0   (Windows 10/11)'

    $out += Invoke-AfsProbe -Area $area -Name 'the run can be confirmed' -Severity 'degraded' -Probe {
        if (-not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
            return @{ State = 'ok'; Detail = 'a console is attached, so the ConfirmImpact=High prompt can be answered' }
        }
        return @{ State = 'missing'; Detail = 'this session is redirected. Set-AfsDnsForwarders.ps1 is ConfirmImpact=High, and ShouldProcess then fails with "Object reference not set to an instance of an object."' }
    } -Fix 'Run it from a console, or unattended as: powershell -Command "& ''.\onprem\Set-AfsDnsForwarders.ps1'' -Context <context> -DnsServer <servers> -Confirm:$false"   (the -Command form - powershell -File drops -Confirm:$false silently)'

    $out += Invoke-AfsProbe -Area $area -Name 'every resolver is listed' -Severity 'degraded' -Remote -Probe {
        $mine = @()
        foreach ($i in @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            foreach ($a in @(& $get $i 'ServerAddresses' @())) {
                if ($a -and ([string]$a) -notmatch '^(127\.|169\.254\.)') { $mine += [string]$a }
            }
        }
        $mine = @($mine | Select-Object -Unique)
        if (-not $mine.Count) { return @{ State = 'unknown'; Detail = 'this machine has no IPv4 DNS server configured, so the list could not be compared with anything' } }
        # The comparison is by ADDRESS, so it is only meaningful once at least one named server
        # has yielded one. With none, every configured resolver looks like a gap - which would
        # report a name-resolution failure here as a finding about the estate.
        $known = @()
        $haveAddress = $false
        foreach ($s in $servers) {
            $known += $s.ToLower()
            $known += ($s -split '\.')[0].ToLower()
            $lit = $null
            if ([System.Net.IPAddress]::TryParse($s, [ref]$lit)) { $haveAddress = $true }
            foreach ($rec in @(Resolve-DnsName -Name $s -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue)) {
                $ip4 = & $get $rec 'IP4Address' ''
                if ($ip4) { $known += ([string]$ip4).ToLower(); $haveAddress = $true }
            }
        }
        $gap = @($mine | Where-Object { $known -notcontains $_.ToLower() })
        if (-not $gap.Count) { return @{ State = 'ok'; Detail = ('this machine resolves through ' + ($mine -join ', ') + ', all of which are in the list') } }
        if (-not $haveAddress) {
            return @{ State = 'unknown'
                      Detail = ('this machine resolves through ' + ($mine -join ', ') + ', and not one of the named servers (' + ($servers -join ', ') + ') could be turned into an address from here, so the two lists could not be compared at all')
                      Fix = 'Name the DNS servers by address in -DnsServer, or fix name resolution on this machine, then re-run this check.' }
        }
        return @{ State = 'missing'; Detail = ('this machine resolves through ' + ($mine -join ', ') + ', and these are NOT in the list: ' + ($gap -join ', ') + '. Active Directory replicates these zones only to domain controllers that run the DNS role - member-server resolvers, Infoblox and BIND need the same forwarder added by hand') }
    } -Fix 'Enumerate the resolvers from the DHCP scope options and the client NIC settings, not from the DC list, and pass all of them to -DnsServer.'

    if ($ResolverIpAddress) {
        # Blocker is earned here: without -Force the script THROWS when this machine cannot get a
        # private answer out of the resolver, so a genuinely dead path does stop the step. It is
        # only genuinely dead when port 53 is shut too - see the header.
        $out += Invoke-AfsProbe -Area $area -Name 'resolver answers this machine' -Severity 'blocker' -Probe {
            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse($ResolverIpAddress, [ref]$parsed)) {
                return @{ State = 'missing'; Detail = ("'" + $ResolverIpAddress + "' is not an IP address - a conditional forwarder targets the inbound endpoint private IP, not a name")
                          Fix = 'az dns-resolver inbound-endpoint list -g <rg> --dns-resolver-name <resolver> -o json' }
            }
            $a = @(Resolve-DnsName -Name 'management.azure.com' -Type A -Server $ResolverIpAddress -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue)
            if ($a.Count) {
                return @{ State = 'ok'; Detail = ($ResolverIpAddress + ' answered on 53 with ' + $a.Count + ' record(s) for management.azure.com. That is the path only - it does not prove the privatelink zones are linked to the resolver virtual network') }
            }
            if (& $tcp $ResolverIpAddress 53 2500) {
                return @{ State = 'unknown'
                          Detail = ($ResolverIpAddress + ' accepts TCP 53 from here but returned nothing for management.azure.com. A resolver that refuses recursion for public names still answers the zones linked to its virtual network, and that is the only lookup the script gates on - so this neither proves nor disproves the path')
                          Fix = ('Resolve-DnsName -Name <account>.privatelink.file.core.windows.net -Server ' + $ResolverIpAddress + ' -Type A -DnsOnly -QuickTimeout   # this is the lookup the script itself makes') }
            }
            return @{ State = 'missing'; Detail = ($ResolverIpAddress + ' did not answer this machine on 53, and TCP 53 did not open either. There is no public route to an inbound endpoint by design, so this needs the VPN or ExpressRoute path - and without -Force the script throws rather than forwarding into a hole') }
        } -Fix 'Run from a host inside the on-premises network, and open UDP+TCP 53 to the resolver inbound subnet (the NSG on that subnet as well as the on-premises firewall).'

        $out += New-AfsReq -Area $area -Name 'answer is a private address' -State 'unknown' -Severity 'blocker' -Remote `
            -Detail ('not checkable here - this check is not given the storage account name, so it cannot ask ' + $ResolverIpAddress + ' for <account>.privatelink.file.core.windows.net. Reachability is not the test: a resolver that returns the PUBLIC address, or NXDOMAIN because the zones are not linked to its virtual network, hands that straight to the client with no fallback - and the script refuses to write anything when that lookup fails') `
            -Fix ('Resolve-DnsName -Name <account>.privatelink.file.core.windows.net -Server ' + $ResolverIpAddress + ' -Type A -DnsOnly -QuickTimeout   # expect 10.x, 172.16-31.x or 192.168.x')
    } else {
        $out += New-AfsReq -Area $area -Name 'resolver inbound address' -State 'unknown' -Severity 'blocker' -Remote `
            -Detail 'no resolver address was supplied, so neither the forwarder target, the answer it returns, nor any path to it could be checked' `
            -Fix 'Pass -ResolverIpAddress <ip>, or read it with: az dns-resolver inbound-endpoint list -g <rg> --dns-resolver-name <resolver> -o json'

        $out += Invoke-AfsProbe -Area $area -Name 'az dns-resolver extension' -Severity 'degraded' -Probe {
            if (-not (Get-Command Invoke-AfsAz -ErrorAction SilentlyContinue)) {
                return @{ State = 'unknown'; Detail = 'the Azure CLI wrapper is not loaded in this session, so the extension could not be checked' }
            }
            # Prove the CLI runs at all first. Invoke-AfsAz -AllowFailure returns $null for ANY
            # non-zero exit - az not on PATH, an unresolvable launcher, a broken profile - so a
            # bare $null from 'extension show' does not mean "not installed".
            if ($null -eq (Invoke-AfsAz -Args @('version', '-o', 'json') -AllowFailure)) {
                return @{ State = 'unknown'; Detail = 'the Azure CLI itself could not be run here, so whether the dns-resolver extension is installed is unknown'
                          Fix = 'Install the Azure CLI and re-run - or bypass Azure entirely by passing -ResolverIpAddress <ip>.' }
            }
            $v = Invoke-AfsAz -Args @('extension', 'show', '-n', 'dns-resolver', '-o', 'json') -AllowFailure
            if ($null -eq $v) { return @{ State = 'missing'; Detail = 'the CLI runs but has no dns-resolver extension - it is an extension, not built in. Without it the script cannot discover the inbound endpoint and reports "No resolver address", which names the wrong cause' } }
            return @{ State = 'ok'; Detail = ('v' + [string](& $get $v 'version' 'an unreported version')) }
        } -Fix 'az extension add --name dns-resolver   - or bypass Azure entirely by passing -ResolverIpAddress <ip>.'
    }

    foreach ($srv in $servers) {

        # Connect first and diagnose afterwards. A short NetBIOS or hosts-file name that WinRM
        # reaches perfectly well has no A record, so testing resolution first calls a working
        # server unreachable.
        $reach = Invoke-AfsProbe -Area $area -Name ($srv + ': WinRM on 5985') -Severity 'blocker' -Remote -Probe {
            if (& $tcp $srv 5985 2500) { return @{ State = 'ok'; Detail = 'listening on 5985' } }
            if (& $tcp $srv 5986 2500) { return @{ State = 'missing'; Detail = 'only 5986 (HTTPS) answers, and this kit builds sessions over HTTP 5985 with no -UseSSL option' } }
            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse($srv, [ref]$parsed)) {
                if (-not @(Resolve-DnsName -Name $srv -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue).Count) {
                    # A name that never resolved proves NOTHING about WinRM - we did not reach
                    # the host to find out. Calling this 'missing' makes it a proven blocker and
                    # stops a run on the strength of a typo or a DNS gap on THIS machine.
                    return @{ State = 'unknown'; Detail = 'the name did not resolve from here, so nothing was contacted and WinRM is unproven either way'; Fix = 'Check the spelling, or use the fully qualified name (the short name plus your own AD domain suffix).' }
                }
            }
            return @{ State = 'missing'; Detail = 'it resolves, but neither 5985 nor 5986 answers. Both routes need WinRM - the local DnsServer module is CIM-based, so -ComputerName opens a WSMan session too' }
        } -Fix 'Enable-PSRemoting -Force   (on the DNS server, elevated), and open TCP 5985 from this subnet to it.'
        $out += $reach

        if ($reach.State -ne 'ok') {
            $out += New-AfsReq -Area $area -Name ($srv + ': zones and forwarders') -State 'unknown' -Severity 'blocker' -Remote `
                -Detail 'its zones could not be read, so its DNS role, replication scope, existing forwarders and path to the resolver are all unknown' `
                -Fix ('Fix WinRM above, then re-run this check. Test it with: Test-WSMan -ComputerName ' + $srv)
            continue
        }

        # One session, every question in one round trip - a session per check is unusably slow.
        $sess = $null
        try {
            $opt = New-PSSessionOption -OpenTimeout 20000 -OperationTimeout 90000 -CancelTimeout 5000
            $p = @{ ComputerName = $srv; ErrorAction = 'Stop'; SessionOption = $opt }
            if ($Credential) { $p.Credential = $Credential }
            $sess = New-PSSession @p
        } catch {
            $msg = $_.Exception.Message
            # ONLY an authentication refusal proves the requirement is missing. WinRM dropping
            # between the port test and this call, TrustedHosts on a workgroup client, an SPN or
            # Kerberos mismatch, a lost packet - those are failures to CHECK, and 'missing' at
            # blocker severity would set CanProceed = $false and stop the entire run while
            # blaming the credential for a network fault.
            if ($msg -match 'Access is denied|Logon failure|logon attempt failed|user name or password|AccessDenied|unauthorized') {
                $out += New-AfsReq -Area $area -Name ($srv + ': rights to read its zones') -State 'missing' -Severity 'blocker' -Remote `
                    -Detail ('access denied as ' + $env:USERDOMAIN + '\' + $env:USERNAME + ' - a domain controller refuses an account that is not in DnsAdmins or Domain Admins and reports it as plain access denied, so being a domain user is not enough: ' + $msg) `
                    -Fix 'Re-run with -Credential using an account in DnsAdmins or Domain Admins (the wizard offers to collect one).'
            } else {
                $out += New-AfsReq -Area $area -Name ($srv + ': session to read its zones') -State 'unknown' -Severity 'blocker' -Remote `
                    -Detail ('5985 answered but the session did not open, and this is not an authentication refusal - so its rights, role, replication scope and forwarders are unchecked, not proven wrong: ' + $msg) `
                    -Fix ('Test-WSMan -ComputerName ' + $srv + '   and, if this machine is not domain-joined: winrm get winrm/config/client   (a workgroup client needs that server in TrustedHosts).')
            }
            continue
        }

        $info = $null
        $gatherError = ''
        try {
            $info = Invoke-Command -Session $sess -ArgumentList @($zones, $ResolverIpAddress) -ErrorAction Stop -ScriptBlock {
                param($zoneNames, $resolver)
                $o = @{ HasCmdlet = $false; Service = ''; DomainRole = -1; ZoneCount = -1; ZoneError = ''
                        Zones = @(); Probe = 'skipped'; ProbeDetail = ''; Tcp53 = 'not tested' }
                $o.HasCmdlet = [bool](Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)
                try { $o.Service = [string](Get-Service DNS -ErrorAction Stop).Status } catch { $o.Service = '' }
                try { $o.DomainRole = [int](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole } catch { $o.DomainRole = -1 }
                if ($o.HasCmdlet) {
                    try {
                        $all = @(Get-DnsServerZone -ErrorAction Stop)
                        $o.ZoneCount = $all.Count
                        foreach ($zn in @($zoneNames)) {
                            $row = @{ Name = $zn; Type = ''; Masters = @(); Timeout = ''; Scope = '' }
                            $hit = @($all | Where-Object { $_.ZoneName -eq $zn })
                            if ($hit.Count) {
                                $h = $hit[0]
                                $row.Type = [string]$h.ZoneType
                                try { $row.Timeout = [string]$h.ForwarderTimeout } catch { }
                                try { $row.Scope = [string]$h.ReplicationScope } catch { }
                                try {
                                    $mm = @()
                                    foreach ($x in @($h.MasterServers)) {
                                        if ($null -eq $x) { continue }
                                        if ($x.PSObject.Properties['IPAddress']) { $mm += [string]$x.IPAddress } else { $mm += [string]$x }
                                    }
                                    $row.Masters = $mm
                                } catch { }
                            }
                            $o.Zones += $row
                        }
                    } catch { $o.ZoneError = $_.Exception.Message }
                }
                if ($resolver) {
                    $o.Probe = 'failed'
                    try {
                        $a = @(Resolve-DnsName -Name 'management.azure.com' -Type A -Server $resolver -DnsOnly -QuickTimeout -ErrorAction Stop)
                        if ($a.Count) { $o.Probe = 'ok'; $o.ProbeDetail = ([string]$a.Count + ' record(s) for management.azure.com') }
                        else { $o.ProbeDetail = 'the resolver answered with no records' }
                    } catch { $o.ProbeDetail = $_.Exception.Message }
                    if ($o.Probe -ne 'ok') {
                        # Bounded by hand, for the reason the caller states about its own $tcp:
                        # Test-NetConnection has no timeout on 5.1, and this line runs ONLY when
                        # the resolver is already not answering - the case where it waits longest.
                        # Nothing bounds it from the client either: SessionOption OperationTimeout
                        # does not abort a running remote command, so an unbounded wait in here
                        # hangs the whole requirements check.
                        $c = $null
                        try {
                            $c = New-Object System.Net.Sockets.TcpClient
                            $ar = $c.BeginConnect($resolver, 53, $null, $null)
                            if ($ar.AsyncWaitHandle.WaitOne(2500, $false)) { $c.EndConnect($ar); $o.Tcp53 = 'open' }
                            else { $o.Tcp53 = 'closed' }
                        } catch { $o.Tcp53 = 'closed' } finally { if ($c) { $c.Close() } }
                    }
                }
                return $o
            }
        } catch { $gatherError = $_.Exception.Message }
        Remove-PSSession $sess -ErrorAction SilentlyContinue

        if (-not $info) {
            $out += New-AfsReq -Area $area -Name ($srv + ': zones and forwarders') -State 'unknown' -Severity 'blocker' -Remote `
                -Detail ('the session opened but the read failed: ' + $gatherError) `
                -Fix ('Test-WSMan -ComputerName ' + $srv + '   then   Get-DnsServerZone -ComputerName ' + $srv)
            continue
        }

        $out += Invoke-AfsProbe -Area $area -Name ($srv + ': DNS Server role') -Severity 'blocker' -Remote -Probe {
            $zc = [int](& $get $info 'ZoneCount' -1)
            $ze = [string](& $get $info 'ZoneError' '')
            $svc = [string](& $get $info 'Service' '')
            if ($zc -ge 0) {
                $svcText = 'DNS service ' + $(if ($svc) { $svc } else { 'state unreadable' })
                return @{ State = 'ok'; Detail = ([string]$zc + ' zones, ' + $svcText) }
            }
            if (-not (& $get $info 'HasCmdlet' $false)) {
                return @{ State = 'missing'; Detail = 'it answered, but Get-DnsServerZone does not exist there - that server does not run the DNS Server role' }
            }
            if ($ze -match 'denied') {
                return @{ State = 'missing'; Detail = ('reading its zones was refused: ' + $ze); Fix = 'Re-run with -Credential using an account in DnsAdmins or Domain Admins.' }
            }
            # The cmdlet exists, so the role is almost certainly there; the READ failed. That is
            # unchecked, not a proven-absent role - and this row is a blocker.
            if ($ze) { return @{ State = 'unknown'; Detail = ('Get-DnsServerZone exists there but the read failed, so the role is unproven either way: ' + $ze) } }
            return @{ State = 'unknown'; Detail = 'no zones came back and no error was reported' }
        } -Fix 'Drop it from -DnsServer, or install the DNS role on it. A caching resolver that is not a Windows DNS server needs its own vendor-specific forward zone instead.'

        $out += Invoke-AfsProbe -Area $area -Name ($srv + ': -ReplicationScope Forest') -Severity 'blocker' -Remote -Probe {
            $dr = [int](& $get $info 'DomainRole' -1)
            if ($dr -eq 4 -or $dr -eq 5) { return @{ State = 'ok'; Detail = ('domain controller (DomainRole ' + $dr + '), so the default -ReplicationScope Forest is legal here') } }
            if ($dr -lt 0) { return @{ State = 'unknown'; Detail = 'the domain role could not be read from that server, so it is not known whether Forest scope is legal there'
                                       Fix = ('(Get-CimInstance Win32_ComputerSystem -ComputerName ' + $srv + ').DomainRole   # 4 or 5 = domain controller; 2 or 3 = member server, which needs -ReplicationScope None') } }
            return @{ State = 'missing'; Detail = ('DomainRole ' + $dr + ' - not a domain controller. Add-DnsServerConditionalForwarderZone -ReplicationScope Forest fails here, and one scope is applied to the whole -DnsServer list, so it throws mid-run after the servers before it were already changed') }
        } -Fix ('Give it its own pass: .\onprem\Set-AfsDnsForwarders.ps1 -Context <context> -DnsServer ' + $srv + ' -ReplicationScope None')

        $out += Invoke-AfsProbe -Area $area -Name ($srv + ': reaches the resolver') -Severity 'blocker' -Remote -Probe {
            if (-not $ResolverIpAddress) {
                return @{ State = 'unknown'
                          Detail = 'no -ResolverIpAddress was supplied. Nothing else tests this either - the forwarder script probes the resolver from the operator machine, never from the servers that will forward'
                          Fix = ('Invoke-Command -ComputerName ' + $srv + ' -ScriptBlock { Resolve-DnsName -Name <account>.privatelink.file.core.windows.net -Server <inbound ip> -DnsOnly -QuickTimeout }') }
            }
            $probe = [string](& $get $info 'Probe' '')
            $pd = [string](& $get $info 'ProbeDetail' '')
            $t53 = [string](& $get $info 'Tcp53' 'not tested')
            if ($probe -eq 'ok') { return @{ State = 'ok'; Detail = ($srv + ' resolved through ' + $ResolverIpAddress + ' - ' + $pd) } }
            if ($probe -eq 'skipped') { return @{ State = 'unknown'; Detail = 'the probe did not run on that server, so its path to the resolver is untested'
                                                  Fix = ('Invoke-Command -ComputerName ' + $srv + ' -ScriptBlock { Resolve-DnsName -Name <account>.privatelink.file.core.windows.net -Server ' + $ResolverIpAddress + ' -DnsOnly -QuickTimeout }') } }
            if ($t53 -eq 'open') {
                return @{ State = 'unknown'
                          Detail = ($srv + ' reaches ' + $ResolverIpAddress + ' on TCP 53 but got no answer for management.azure.com: ' + $pd + '. A resolver that refuses recursion for public names still answers the zones linked to its virtual network, so the forwarding path is not disproven by this')
                          Fix = ('Invoke-Command -ComputerName ' + $srv + ' -ScriptBlock { Resolve-DnsName -Name <account>.privatelink.file.core.windows.net -Server ' + $ResolverIpAddress + ' -DnsOnly -QuickTimeout }   # expect a private address') }
            }
            if ($t53 -eq 'closed') {
                return @{ State = 'missing'; Detail = ($srv + ' got no answer from ' + $ResolverIpAddress + ', and TCP 53 is shut from there too: ' + $pd + '. Clients would then get SERVFAIL after about eleven seconds for EVERY endpoint under those zones') }
            }
            return @{ State = 'unknown'; Detail = ($srv + ' got no answer from ' + $ResolverIpAddress + ' and the port test did not run (' + $t53 + '): ' + $pd + '. Whether the path is shut or the resolver merely refused that one name is not established') }
        } -Fix 'Open UDP and TCP 53 from the DNS server subnet to the resolver inbound subnet - the NSG on the inbound subnet as well as the on-premises firewall.'

        foreach ($zrow in @(& $get $info 'Zones' @())) {
            $zname = [string](& $get $zrow 'Name' 'zone')
            $ztype = [string](& $get $zrow 'Type' '')
            $zmasters = @(& $get $zrow 'Masters' @())
            # Severity is decided from what was already read, so an HA forwarder is not reported
            # with the same weight as one aimed at a resolver that no longer exists.
            $zsev = 'blocker'
            if ($ztype -eq 'Forwarder' -and $ResolverIpAddress -and ($zmasters -contains $ResolverIpAddress) -and $zmasters.Count -gt 1) { $zsev = 'degraded' }

            $out += Invoke-AfsProbe -Area $area -Name ($srv + ': ' + $zname) -Severity $zsev -Remote -Probe {
                if (-not $ztype) { return @{ State = 'ok'; Detail = 'no zone of that name yet - the forwarder would be created' } }
                if ($ztype -ne 'Forwarder') {
                    return @{ State = 'missing'
                              Detail = ('already exists as a ' + $ztype + ' zone. The script refuses to touch it - a zone of that type is authoritative data, not a forwarder - and throws')
                              Fix = ('Find out why a ' + $ztype + ' zone for a Microsoft public suffix exists (usually an old split-brain hack). Removing it is a separate, deliberate change: Remove-DnsServerZone -Name ' + $zname + ' -ComputerName ' + $srv) }
                }
                $ms = $(if ($zmasters.Count) { $zmasters -join ', ' } else { '(no masters)' })
                $tmoRaw = [string](& $get $zrow 'Timeout' '')
                $tmo = $(if ($tmoRaw) { 'timeout ' + $tmoRaw + 's' } else { 'timeout unreadable' })
                if (-not $ResolverIpAddress) {
                    return @{ State = 'unknown'; Detail = ('already forwards to ' + $ms + ', and with no -ResolverIpAddress that cannot be compared with the inbound endpoint'); Fix = 'Pass -ResolverIpAddress <ip> and re-run this check.' }
                }
                if ($zmasters.Count -eq 1 -and $zmasters[0] -eq $ResolverIpAddress) {
                    return @{ State = 'ok'; Detail = ('already forwards to ' + $ResolverIpAddress + ', ' + $tmo) }
                }
                if ($zmasters -contains $ResolverIpAddress) {
                    return @{ State = 'missing'
                              Detail = ('forwards to ' + $ms + ' - correct as it stands, but -UpdateExisting judges any multi-master forwarder wrong and rewrites MasterServers to the single IP ' + $ResolverIpAddress + ', dropping the second inbound endpoint and forcing ForwarderTimeout to 3')
                              Fix = ('Do NOT pass -UpdateExisting. Set-DnsServerConditionalForwarderZone -Name ' + $zname + ' -MasterServers <ip1>,<ip2> -ForwarderTimeout 3 -ComputerName ' + $srv) }
                }
                return @{ State = 'missing'; Detail = ('forwards to ' + $ms + ', not ' + $ResolverIpAddress + '. The script detects this, leaves it alone, and still prints "Conditional forwarders in place." - an exit-0 run over an estate-wide outage if that target is dead') }
            } -Fix ('Capture it first - nothing restores it, and -Remove deletes the zone rather than putting the old masters back: Get-DnsServerZone -Name ' + $zname + ' -ComputerName ' + $srv + ' | Export-Clixml pre-change.xml   then re-run with -UpdateExisting')
        }
    }

    return ,$out
}

# ============================================================== the AD DS join ==

function Get-AfsAdRequirements {
    <#
      The AD DS join - the step that fails on somebody else's system.

      Nothing here can be inferred from Azure. The join needs a Desktop-edition PowerShell, RSAT,
      a writable DC answering ADWS, an OU that already exists, and the right to create a computer
      object in it as the account RUNNING the script. Join-AzStorageAccount has no credential
      parameter at all, so -AdCredential covers the OU step and nothing else - which is why the
      OU security descriptor below is read against the CURRENT token on purpose, not against
      -Credential.

      Three lies this exists to stop, all recorded in logs\addsjoin-* on 2026-09-04:
        - no RSAT           -> AzFilesHybrid says "This cmdlet requires an elevated PowerShell
                               session". Elevation is not the problem.
        - ADWS down, no DC, a malformed DN or a denied read -> the join script's own OU probe
                               swallows the exception and concludes "The organizational unit does
                               not exist." Here that is three separate states, and the raw error
                               is carried out.
        - anything at all   -> the module rewrites unrelated failures (kerb keys it could not
                               read, a SamAccountName over 15 characters) into "check that you
                               have permission to create an identity", so an answer about
                               permissions alone is not enough. The name, the key path and any
                               leftover SPN are checked too.

      Reads only: one directory round trip, one CLI read. No install, no prompt, no change.
    #>
    param([string]$DomainFqdn, [string]$OrganizationalUnit, [System.Management.Automation.PSCredential]$Credential, $Config)

    $area = 'AD DS join'
    $out = @()

    # ------------------------------------------------------------------ settings --
    $cv = @{}
    if ($Config) {
        try {
            if ($Config -is [hashtable]) { foreach ($k in @($Config.Keys)) { $cv[[string]$k] = $Config[$k] } }
            else { foreach ($p in $Config.PSObject.Properties) { $cv[$p.Name] = $p.Value } }
        } catch { }
    }
    $val = {
        param([string]$Name)
        if ($cv.ContainsKey($Name) -and $null -ne $cv[$Name]) { return [string]$cv[$Name] }
        return ''
    }
    $sub     = & $val 'subscriptionId'
    $rg      = & $val 'resourceGroup'
    $sa      = & $val 'storageAccountName'
    $objType = & $val 'adIdentityObjectType'
    if (-not $objType) { $objType = 'ComputerAccount' }

    $domain = $DomainFqdn
    if (-not $domain) { $domain = & $val 'adDomainFqdn' }
    $ou = $OrganizationalUnit
    if (-not $ou) { $ou = & $val 'adOuDn' }
    # A domain can be read off the OU's own DC= components. That is the caller's own value
    # rearranged, not a guess - and a guessed domain is exactly what this file refuses to make.
    if (-not $domain -and $ou) {
        $dcParts = @([regex]::Matches($ou, '(?i)(?:^|,)\s*DC=([^,]+)') | ForEach-Object { $_.Groups[1].Value })
        if ($dcParts.Count) { $domain = ($dcParts -join '.') }
    }

    if (-not $domain -and -not $ou) {
        return ,@((New-AfsReq -Area $area -Name 'AD DS join readiness' -State 'unknown' -Severity 'blocker' `
            -Detail 'no AD domain and no organizational unit were named, so nothing about the join could be checked' `
            -Fix 'Pass -DomainFqdn and -OrganizationalUnit, or set activeDirectory.domainFqdn and activeDirectory.organizationalUnitDistinguishedName in deploy\inputs.json.' -Remote))
    }

    # ------------------------------------------------------- this machine, once --
    $cs = $null
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue } catch { }

    $out += Invoke-AfsProbe -Area $area -Name 'this machine is domain-joined' -Probe {
        if ($null -eq $cs) { return @{ State = 'unknown'; Detail = 'Win32_ComputerSystem could not be read on this machine' } }
        if (-not $cs.PartOfDomain) {
            return @{ State = 'missing'; Detail = ('workgroup ' + [string]$cs.Domain + ' - Join-AzStorageAccount refuses to run off a domain, even under -WhatIf') }
        }
        return @{ State = 'ok'; Detail = ('joined to ' + [string]$cs.Domain) }
    } -Fix 'Run the join from a domain-joined admin station or a domain controller.'

    $out += Invoke-AfsProbe -Area $area -Name 'the domain being joined' -Severity 'degraded' -Remote -Probe {
        if ($null -eq $cs -or -not $cs.PartOfDomain) { return @{ State = 'unknown'; Detail = ('this machine has no domain to compare with ' + $domain) } }
        $mine = [string]$cs.Domain
        if (-not $domain) { return @{ State = 'unknown'; Detail = ('no domain was named; this machine is in ' + $mine) } }
        if ($mine -eq $domain) { return @{ State = 'ok'; Detail = ($domain + ' - the domain this machine is in') } }
        return @{ State = 'missing'; Detail = ('this machine is in ' + $mine + ', the join targets ' + $domain + ' - that needs a trust and create-computer rights over there') }
    } -Fix ('nltest /domain_trusts /all_trusts /v    (or run the join from a machine in ' + $domain + ')')

    $adMod = $null
    try { $adMod = Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1 } catch { }
    $adLoaded = $false
    $adLoadErr = ''
    if ($adMod) {
        try { Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false; $adLoaded = $true }
        catch { $adLoadErr = $_.Exception.Message }
    }

    $out += Invoke-AfsProbe -Area $area -Name 'AD cmdlets (RSAT)' -Probe {
        if (-not $adMod) {
            return @{ State = 'missing'; Detail = 'not installed - AzFilesHybrid then fails with "This cmdlet requires an elevated PowerShell session", which names the wrong cause' }
        }
        if (-not $adLoaded) {
            return @{ State = 'missing'; Detail = ('v' + [string]$adMod.Version + ' is present but will not import: ' + $adLoadErr) }
        }
        return @{ State = 'ok'; Detail = ('v' + [string]$adMod.Version + ' imported') }
    } -Fix 'Install-WindowsFeature RSAT-AD-PowerShell    (elevated, once; Windows client: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0)'

    # The wizard's local check accepts ANY Az.Storage. AzFilesHybrid does not: below 8.1.0 the
    # join stops - after the operator has already answered every prompt.
    $azStorage = $null
    try { $azStorage = Get-Module -ListAvailable -Name Az.Storage -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1 } catch { }

    $out += Invoke-AfsProbe -Area $area -Name 'Az.Storage 8.1.0 or later' -Probe {
        if (-not $azStorage) { return @{ State = 'missing'; Detail = 'not installed' } }
        if ([version]$azStorage.Version -lt [version]'8.1.0') {
            return @{ State = 'missing'; Detail = ('v' + [string]$azStorage.Version + ' - AzFilesHybrid needs 8.1.0 or later') }
        }
        return @{ State = 'ok'; Detail = ('v' + [string]$azStorage.Version) }
    } -Fix 'Install-Module Az.Storage -MinimumVersion 8.1.0 -Scope CurrentUser'

    # An `az login` does NOT sign in Az PowerShell - a different token store. Everything the join
    # touches in Azure goes through the Az cmdlets, so the CLI session the wizard checks proves
    # nothing here.
    $azCtx = $null
    $azCtxErr = ''
    try {
        if (Get-Command Get-AzContext -ErrorAction SilentlyContinue) { $azCtx = Get-AzContext -ErrorAction Stop }
        else { $azCtxErr = 'Az.Accounts is not installed, so there is no Az PowerShell session to check' }
    } catch { $azCtxErr = $_.Exception.Message }

    $out += Invoke-AfsProbe -Area $area -Name 'Az PowerShell sign-in' -Probe {
        if ($null -eq $azCtx) {
            $d = 'no Az PowerShell session'
            if ($azCtxErr) { $d = $azCtxErr }
            return @{ State = 'missing'; Detail = ($d + ' - an Azure CLI sign-in does not cover the Az cmdlets the join uses') }
        }
        $who = ''
        if ($azCtx.Account) { $who = [string]$azCtx.Account.Id }
        $on = ''
        if ($azCtx.Subscription) { $on = [string]$azCtx.Subscription.Id }
        if ($sub -and $on -and $on -ne $sub) {
            return @{ State = 'missing'
                      Detail = ($who + ' is on subscription ' + $on + ', the deployment targets ' + $sub)
                      Fix = ('Set-AzContext -Subscription ' + $sub) }
        }
        $d = $who
        if ($on) { $d = $who + ' on ' + $on }
        return @{ State = 'ok'; Detail = $d }
    } -Fix 'Connect-AzAccount'

    # Join-AzStorageAccount, Debug-AzStorageAccountAuth and the kerb-key comparison ship in no
    # Gallery module - only in this zip, from github.com, over TLS 1.2.
    $modUrl = 'https://github.com/Azure-Samples/azure-files-samples/releases/download/v0.3.2/AzFilesHybrid.zip'
    $modDir = Join-Path ([IO.Path]::GetTempPath()) 'AzFilesHybrid'

    $out += Invoke-AfsProbe -Area $area -Name 'AzFilesHybrid v0.3.2' -Remote -Probe {
        $psd1 = Join-Path $modDir 'AzFilesHybrid.psd1'
        if (Test-Path -LiteralPath $psd1) { return @{ State = 'ok'; Detail = ('already extracted at ' + $modDir) } }
        $ProgressPreference = 'SilentlyContinue'
        $prevTls = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $prevTls -bor [Net.SecurityProtocolType]::Tls12
            $r = Invoke-WebRequest -Uri $modUrl -Method Head -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            return @{ State = 'ok'; Detail = ('not staged, but github.com answers HTTP ' + [int]$r.StatusCode + ' - the join downloads it') }
        } catch {
            return @{ State = 'missing'; Detail = ('not staged at ' + $modDir + ', and the download is not reachable: ' + $_.Exception.Message) }
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $prevTls
        }
    } -Fix ('Extract AzFilesHybrid.zip into ' + $modDir + ' from a machine with egress, or pass -ModuleUrl <internal mirror> to the join script.')

    # ------------------------------------------ the directory, in one round trip --
    $ad = @{
        Dc = ''; Site = ''; DcError = ''
        Now = $null; ClockError = ''; MaxPwdAge = ''
        OuState = 'unknown'; OuDetail = ''
        ParentDn = ''; ParentState = 'unknown'; ParentDetail = ''
        SpnState = 'unknown'; SpnDetail = ''
        AclState = 'unknown'; AclDetail = ''
    }

    if ($adLoaded) {
        try {
            $disc = @{ Discover = $true; Service = 'ADWS'; Writable = $true; ErrorAction = 'Stop' }
            if ($domain) { $disc.DomainName = $domain }
            $dc = Get-ADDomainController @disc
            $hn = @($dc.HostName)
            if ($hn.Count) { $ad.Dc = [string]$hn[0] }
            $ad.Site = [string]$dc.Site
        } catch { $ad.DcError = $_.Exception.Message }

        if ($ad.Dc) {
            # One server, one credential, every question - and each answer kept apart, so no
            # failure can be reported as another one.
            $srv = @{ Server = $ad.Dc; ErrorAction = 'Stop' }
            if ($Credential) { $srv.Credential = $Credential }

            try {
                $root = Get-ADRootDSE @srv
                $ct = $root.currentTime
                if ($ct -is [datetime]) { $ad.Now = $ct }
                elseif ($ct) {
                    $ad.Now = [datetime]::ParseExact(([string]$ct).Substring(0, 14), 'yyyyMMddHHmmss', $null,
                              ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
                }
            } catch { $ad.ClockError = $_.Exception.Message }

            try { $ad.MaxPwdAge = [string](Get-ADDefaultDomainPasswordPolicy @srv).MaxPasswordAge } catch { }

            if ($ou) {
                $parts = $ou -split ',', 2
                if ($parts.Count -eq 2) { $ad.ParentDn = $parts[1] }
                # A DN that is not a DN comes back from the AD cmdlets as "Cannot find an object
                # with identity", which reads as "somebody deleted the OU". Separate the two.
                $shaped = ($ou -match '(?i)^\s*(OU|CN)=.+,\s*DC=')
                if (-not $shaped) {
                    $ad.OuState = 'missing'
                    $ad.OuDetail = 'not a distinguished name; it has to read like OU=AzureFiles,DC=example,DC=com'
                    $ad.ParentState = 'unknown'
                    $ad.ParentDetail = 'the organizational unit is not a distinguished name, so it has no parent to check'
                } else {
                    try {
                        $ouObj = Get-ADObject -Identity $ou -Properties objectClass @srv
                        $ad.OuState = 'ok'
                        $ad.OuDetail = ('exists (' + [string]$ouObj.ObjectClass + ')')
                    } catch {
                        $m = $_.Exception.Message
                        # THE fix this file exists for: the join script catches this and blames the OU.
                        if ($m -match 'Directory object not found|Cannot find an object with identity') {
                            $ad.OuState = 'missing'; $ad.OuDetail = ('does not exist in ' + $domain)
                        } else {
                            $ad.OuState = 'unknown'; $ad.OuDetail = ('the read failed for another reason: ' + $m)
                        }
                    }
                }

                if ($shaped -and $ad.OuState -eq 'ok') {
                    $ad.ParentState = 'ok'; $ad.ParentDetail = 'the OU itself exists, so nothing has to be created'
                } elseif ($shaped -and -not $ad.ParentDn) {
                    $ad.ParentState = 'unknown'; $ad.ParentDetail = ($ou + ' has no parent component to check')
                } elseif ($shaped) {
                    try {
                        $null = Get-ADObject -Identity $ad.ParentDn @srv
                        $ad.ParentState = 'ok'; $ad.ParentDetail = ($ad.ParentDn + ' exists, so -CreateOrganizationalUnit can build the leaf')
                    } catch {
                        $m = $_.Exception.Message
                        if ($m -match 'Directory object not found|Cannot find an object with identity') {
                            $ad.ParentState = 'missing'; $ad.ParentDetail = ($ad.ParentDn + ' does not exist either - the join creates only the LEAF OU and then blames permissions')
                        } else {
                            $ad.ParentState = 'unknown'; $ad.ParentDetail = ('the read failed for another reason: ' + $m)
                        }
                    }
                }
            }

            if ($sa) {
                $spn = 'cifs/' + $sa + '.file.core.windows.net'
                try {
                    $held = @(Get-ADObject -LDAPFilter ('(servicePrincipalName=' + $spn + ')') -Properties ObjectClass @srv)
                    if ($held.Count) {
                        $ad.SpnState = 'missing'
                        $ad.SpnDetail = ([string]$held[0].ObjectClass + ' ' + [string]$held[0].DistinguishedName + ' already carries ' + $spn)
                    } else {
                        $ad.SpnState = 'ok'; $ad.SpnDetail = ('no object carries ' + $spn)
                    }
                } catch { $ad.SpnState = 'unknown'; $ad.SpnDetail = ('the search failed: ' + $_.Exception.Message) }
            }

            # Read against the CURRENT token, deliberately: Join-AzStorageAccount creates the
            # object as whoever runs the script, and -AdCredential does not reach this.
            if ($ad.OuState -eq 'ok') {
                try {
                    $acl = Get-Acl -Path ('AD:\' + $ou) -ErrorAction Stop
                    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
                    $sids = @([string]$me.User.Value)
                    foreach ($g in @($me.Groups)) { $sids += [string]$g.Value }
                    $computerClass = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2'
                    $anyClass = [guid]::Empty
                    $hits = @()
                    $aces = @($acl.Access)
                    foreach ($ace in $aces) {
                        if ([string]$ace.AccessControlType -ne 'Allow') { continue }
                        $sid = ''
                        try {
                            if ($ace.IdentityReference -is [Security.Principal.SecurityIdentifier]) { $sid = [string]$ace.IdentityReference.Value }
                            else { $sid = [string]$ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
                        } catch { }
                        if (-not $sid -or ($sids -notcontains $sid)) { continue }
                        $rights = [string]$ace.ActiveDirectoryRights
                        if ($rights -notmatch 'CreateChild|GenericAll') { continue }
                        $onClass = $anyClass
                        try { $onClass = [guid]$ace.ObjectType } catch { }
                        if ($onClass -eq $anyClass -or $onClass -eq $computerClass) {
                            $hits += ([string]$ace.IdentityReference + ' (' + $rights + ')')
                        }
                    }
                    $ownerSid = ''
                    try { $ownerSid = [string](New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
                    $whoami = $env:USERDOMAIN + '\' + $env:USERNAME
                    if ($hits.Count) {
                        $ad.AclState = 'ok'
                        $ad.AclDetail = ($whoami + ' has it via ' + ((@($hits | Select-Object -Unique) | Select-Object -First 2) -join '; '))
                    } elseif ($ownerSid -and ($sids -contains $ownerSid)) {
                        $ad.AclState = 'ok'
                        $ad.AclDetail = ($whoami + ' owns the OU (' + [string]$acl.Owner + '), so it can grant itself the right')
                    } else {
                        $ad.AclState = 'missing'
                        $ad.AclDetail = ('none of the ' + $aces.Count + ' ACEs grants create-computer to ' + $whoami + ' or its groups')
                    }
                } catch {
                    $ad.AclState = 'unknown'
                    $ad.AclDetail = ('the OU security descriptor could not be read: ' + $_.Exception.Message)
                }
            } else {
                $ad.AclState = 'unknown'
                $ad.AclDetail = 'the OU could not be read, so its security descriptor could not be either'
            }
        }
    }

    if (-not $adLoaded) {
        # One honest row instead of five identical unknowns - the module above is the blocker.
        $out += New-AfsReq -Area $area -Name 'the directory itself' -State 'unknown' -Severity 'blocker' -Remote `
            -Detail 'the ActiveDirectory module could not be loaded here, so the DC, the OU, its ACL and the SPN went unchecked' `
            -Fix 'Install-WindowsFeature RSAT-AD-PowerShell    (elevated, once), then run this check again.'
    } else {
        $out += Invoke-AfsProbe -Area $area -Name 'a writable DC answering ADWS' -Remote -Probe {
            if ($ad.Dc) {
                $d = $ad.Dc
                if ($ad.Site) { $d = $ad.Dc + ' (site ' + $ad.Site + ')' }
                return @{ State = 'ok'; Detail = $d }
            }
            # Discovery failing is not the same as there being no DC. A domain that does not
            # resolve, or cannot be reached from here, proves nothing about the directory - and a
            # proven blocker stops the whole run. Only call it missing when the domain answered
            # and still yielded no writable DC.
            $e = [string]$ad.DcError
            # Windows' own words are "The specified domain either does not exist or could not be
            # contacted" - it will not say which, and neither should we.
            if ($e -match 'either does not exist or could not be contacted|not operational|could not be contacted|cannot be contacted|referral was returned|No such host|could not be resolved|RPC server is unavailable') {
                return @{ State = 'unknown'; Detail = ('the domain ' + $domain + ' could not be contacted from here, so its domain controllers are unproven either way: ' + $e) }
            }
            if (-not $e) {
                return @{ State = 'unknown'; Detail = ('discovery for ' + $domain + ' returned nothing and gave no reason') }
            }
            return @{ State = 'missing'; Detail = ('the domain answered, but no writable DC with ADWS was found for ' + $domain + ': ' + $e) }
        } -Fix ('nltest /dsgetdc:' + $domain + ' /writable    then on that DC: Get-Service ADWS   (TCP 9389, plus 88/389/636/464 from here)')

        if (-not $ad.Dc) {
            $out += New-AfsReq -Area $area -Name 'the OU and its rights' -State 'unknown' -Severity 'blocker' -Remote `
                -Detail 'no domain controller was reached, so the OU, its ACL and the SPN went unchecked' `
                -Fix ('nltest /dsgetdc:' + $domain + ' /writable')
        } else {
            $ouFix = 'Set activeDirectory.organizationalUnitDistinguishedName in deploy\inputs.json to the OU''s distinguished name, for example OU=AzureFiles,DC=example,DC=com.'
            $parentFix = $ouFix
            if ($ad.ParentDn) {
                $ouFix = 'New-ADOrganizationalUnit -Name ''' + (($ou -split ',')[0] -replace '(?i)^OU=', '') + ''' -Path ''' + $ad.ParentDn + '''    (or re-run the join with -CreateOrganizationalUnit -AdCredential)'
                $parentFix = 'New-ADOrganizationalUnit -Name ''' + (($ad.ParentDn -split ',')[0] -replace '(?i)^OU=', '') + ''' -Path ''' + (($ad.ParentDn -split ',', 2)[1]) + '''    - the join builds only the LEAF OU, so the parent has to exist first.'
            }

            $out += Invoke-AfsProbe -Area $area -Name 'the organizational unit' -Remote -Probe {
                if (-not $ou) { return @{ State = 'unknown'; Detail = 'none was named - without one AzFilesHybrid drops the object wherever this machine''s own computer account lives' } }
                return @{ State = $ad.OuState; Detail = ($ou + ' - ' + $ad.OuDetail) }
            } -Fix $ouFix

            $out += Invoke-AfsProbe -Area $area -Name 'the OU parent' -Severity 'degraded' -Remote -Probe {
                if (-not $ou) { return @{ State = 'unknown'; Detail = 'no organizational unit was named' } }
                return @{ State = $ad.ParentState; Detail = $ad.ParentDetail }
            } -Fix $parentFix

            $out += Invoke-AfsProbe -Area $area -Name 'create-computer right in the OU' -Remote -Probe {
                return @{ State = $ad.AclState; Detail = $ad.AclDetail }
            } -Fix ('dsacls "' + $ou + '" /I:T /G "' + $env:USERDOMAIN + '\' + $env:USERNAME + ':CC;computer"    (the join runs as THIS account - -AdCredential does not cover it)')

            $out += Invoke-AfsProbe -Area $area -Name 'no leftover object with the SPN' -Severity 'degraded' -Remote -Probe {
                if (-not $sa) { return @{ State = 'unknown'; Detail = 'the settings name no storage account, so the SPN to look for is not known' } }
                return @{ State = $ad.SpnState; Detail = $ad.SpnDetail }
            } -Fix '.\onprem\Join-AfsStorageAccountToAdDs.ps1 -Context .\deploy\deployment-context.json -Remove -Confirm:$false    (the join never passes -OverwriteExistingADObject)'

            $out += Invoke-AfsProbe -Area $area -Name 'clock vs the domain controller' -Severity 'advisory' -Remote -Probe {
                if ($null -eq $ad.Now) { return @{ State = 'unknown'; Detail = ('the DC clock could not be read: ' + $ad.ClockError) } }
                $skew = [Math]::Abs(((Get-Date).ToUniversalTime() - $ad.Now.ToUniversalTime()).TotalMinutes)
                $shown = [string][Math]::Round($skew * 60, 0) + ' s from ' + $ad.Dc
                if ($skew -ge 5) { return @{ State = 'missing'; Detail = ($shown + ' - Kerberos rejects a ticket beyond 5 minutes') } }
                if ($skew -ge 2) { return @{ State = 'ok'; Detail = ($shown + ' - inside the 5-minute Kerberos tolerance, but close to it') } }
                return @{ State = 'ok'; Detail = $shown }
            } -Fix 'w32tm /resync /force    (and fix the time source if w32tm /query /status reports Local CMOS Clock)'
        }
    }

    # --------------------------------------- the storage account, in one CLI read --
    $acct = $null
    $acctErr = ''
    if ($sa -and $rg) {
        if (Get-Command Invoke-AfsAz -ErrorAction SilentlyContinue) {
            try {
                $q = '{ids:azureFilesIdentityBasedAuthentication.directoryServiceOptions,' +
                     'sam:azureFilesIdentityBasedAuthentication.activeDirectoryProperties.samAccountName,' +
                     'shared:allowSharedKeyAccess,' +
                     'def:azureFilesIdentityBasedAuthentication.defaultSharePermission}'
                $azArgs = @('storage', 'account', 'show', '-n', $sa, '-g', $rg, '--query', $q, '-o', 'json')
                if ($sub) { $azArgs += @('--subscription', $sub) }
                $acct = Invoke-AfsAz -Args $azArgs -AllowFailure
                if ($acct -is [string]) { $acct = $acct | ConvertFrom-Json }
            } catch { $acctErr = $_.Exception.Message }
        } else { $acctErr = 'Invoke-AfsAz is not loaded (deploy\AfsLog.ps1 was not dot-sourced)' }
    } else { $acctErr = 'the settings name no storage account and resource group' }

    # Every fix below has to be a command that can actually be run, so it is only built when
    # the settings name the account it would run against.
    $showFix = 'Set overrides.storageAccountName and overrides.resourceGroup in deploy\inputs.json.'
    $keyFix = $showFix
    $defFix = $showFix
    $rotFix = 'Set activeDirectory.identityObjectType to ComputerAccount in deploy\inputs.json.'
    if ($sa -and $rg) {
        $saRef  = '-n ' + $sa + ' -g ' + $rg
        $showFix = 'az storage account show ' + $saRef + ' --query azureFilesIdentityBasedAuthentication -o json    (run it to see the error this probe could not)'
        $keyFix  = 'az storage account update ' + $saRef + ' --allow-shared-key-access true    (and set it back to false once the join is done)'
        $defFix  = 'az storage account update ' + $saRef + ' --default-share-permission None'
        $rotFix  = 'Set activeDirectory.identityObjectType to ComputerAccount in deploy\inputs.json, or schedule: Update-AzStorageAccountADObjectPassword -ResourceGroupName ' + $rg + ' -StorageAccountName ' + $sa + ' -RotateToKerbKey kerb2'
    }

    $out += Invoke-AfsProbe -Area $area -Name 'storage account identity source' -Remote -Probe {
        if ($null -eq $acct) {
            $d = 'could not be read'
            if ($acctErr) { $d = $d + ': ' + $acctErr }
            return @{ State = 'unknown'; Detail = ($d + ' - it may not exist yet, or the read was denied') }
        }
        $ids = [string]$acct.ids
        if (-not $ids -or $ids -eq 'None') { return @{ State = 'ok'; Detail = 'none - ready for an AD DS join' } }
        if ($ids -eq 'AD') { return @{ State = 'ok'; Detail = ('already AD DS, as ' + [string]$acct.sam) } }
        return @{ State = 'missing'
                  Detail = ($ids + ' is enabled - an account supports exactly one identity source, for every share in it')
                  Fix = ('az storage account update -n ' + $sa + ' -g ' + $rg + ' --enable-files-aadkerb false --enable-files-aadds false') }
    } -Fix $showFix

    $out += Invoke-AfsProbe -Area $area -Name 'shared key access' -Severity 'degraded' -Remote -Probe {
        if ($null -eq $acct) { return @{ State = 'unknown'; Detail = 'the storage account could not be read' } }
        if ($acct.shared -eq $false) {
            return @{ State = 'missing'; Detail = 'disabled - the AD object''s password IS the account''s Kerberos key, and the join has to read it' }
        }
        return @{ State = 'ok'; Detail = 'allowed - the join can read the Kerberos key' }
    } -Fix $keyFix

    $out += Invoke-AfsProbe -Area $area -Name 'default share permission' -Severity 'advisory' -Remote -Probe {
        if ($null -eq $acct) { return @{ State = 'unknown'; Detail = 'the storage account could not be read' } }
        $d = [string]$acct.def
        if (-not $d -or $d -eq 'None') {
            return @{ State = 'ok'; Detail = 'None - so every reader needs a share-level role on a SYNCED group; computer accounts, sMSAs and gMSAs have no Entra identity and can be let in ONLY by changing this' }
        }
        return @{ State = 'missing'
                  Detail = ($d + ' for every authenticated hybrid identity - where a default and an explicit grant both exist the HIGHER wins, so this overrides your per-group grants')
                  Fix = ('az storage account update -n ' + $sa + ' -g ' + $rg + ' --default-share-permission None') }
    } -Fix $defFix

    # ------------------------------------------------------------ naming and type --
    $samName = ''
    if ($sa) {
        if ($sa.Length -le 15) { $samName = $sa }
        else {
            try {
                $md5 = [System.Security.Cryptography.MD5]::Create()
                $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($sa))).Replace('-', '')
                $samName = $sa.Substring(0, 10) + $hash.Substring(0, 5).ToLower()
            } catch { $samName = '' }
        }
    }

    $out += Invoke-AfsProbe -Area $area -Name 'the AD account name' -Severity 'advisory' -Probe {
        if (-not $samName) { return @{ State = 'unknown'; Detail = 'the settings name no storage account, so the account name cannot be derived' } }
        $joinedAs = ''
        if ($null -ne $acct) { $joinedAs = [string]$acct.sam }
        if ($joinedAs -and $joinedAs -ne $samName) {
            return @{ State = 'missing'
                      Detail = ('already joined as ' + $joinedAs + ', but this run would use ' + $samName)
                      Fix = ('Pass -SamAccountName ' + $joinedAs + ' to work with the existing join, or -Remove first.') }
        }
        return @{ State = 'ok'; Detail = ($samName + ' (' + $samName.Length + ' characters, limit 15) - derived, never random, so a re-run matches') }
    } -Fix 'Pass -SamAccountName to the join script to adopt an existing object under another name.'

    $out += Invoke-AfsProbe -Area $area -Name 'identity object type' -Severity 'advisory' -Remote -Probe {
        if ($objType -eq 'ComputerAccount') {
            return @{ State = 'ok'; Detail = 'ComputerAccount - its password does not expire under the OU policy' }
        }
        $age = 'the domain password policy'
        if ($ad.MaxPwdAge) { $age = 'MaxPasswordAge ' + $ad.MaxPwdAge }
        return @{ State = 'missing'; Detail = ($objType + ' is a user object, so it inherits ' + $age + ' - and its password IS the Kerberos key, so every share in the account fails with 1396 the day it expires') }
    } -Fix $rotFix

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
