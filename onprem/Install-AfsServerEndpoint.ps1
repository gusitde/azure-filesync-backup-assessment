<#
.SYNOPSIS
  Install the Azure File Sync agent on a file server, register it, and sync a local folder
  to an Azure file share - end to end, idempotently, from this machine.

.DESCRIPTION
  This is the first of the three steps the Azure build deliberately does not do, because it
  touches a machine rather than a subscription. It does all of it:

    on the file server (over PowerShell remoting)
      - checks the OS, .NET and disk are supported, and that the path is a local NTFS path
      - installs the Azure File Sync agent silently, from the download for that OS version
      - registers the server against the Storage Sync Service

    in Azure
      - one sync group per file share (a sync group holds exactly one cloud endpoint)
      - a cloud endpoint pointing at the Azure file share
      - a server endpoint pointing at the local folder

  Every step is skipped when it is already done, so a failed run is fixed and repeated rather
  than unpicked. -WhatIf shows the whole plan and changes nothing. -Remove walks the reverse
  path in the only order Azure accepts.

  WHO RUNS IT. Two identities are involved, and the script is explicit about both:
    - The CLOUD ENDPOINT step grants the Azure File Sync service reader access to your
      storage account, which is a role assignment. Contributor cannot create role
      assignments, so this one step needs the signed-in operator to hold Owner, User Access
      Administrator, or Azure File Sync Administrator on the storage account. The script
      checks that before it tries, and says exactly what to grant if not.
    - SERVER REGISTRATION runs inside the remote session, where the operator's browser
      sign-in does not exist. It uses the deployment identity from phase 1 (Contributor on
      the resource group is enough), with the secret passed to the session in memory only.

.PARAMETER Context
  deployment-context.json from phase 1. Everything about Azure comes from it.

.PARAMETER FileServer
  The file server to register, as a name PowerShell remoting can reach.

.PARAMETER SharePath
  Which local folder syncs to which Azure file share. Either a hashtable:
    -SharePath @{ 'dept-shares' = 'D:\Shares\dept-shares' }
  or one or more share=path strings, which is what you need when the script is started with
  powershell -File (that passes every argument as a string, so a hashtable never survives):
    -SharePath 'dept-shares=D:\Shares\dept-shares','home-drives=D:\Shares\home'
  The share must be one the build created. The path must be a local NTFS path on that server.

.PARAMETER Credential
  A credential for the file server with local administrator rights. Prompted for if omitted;
  AFS_SERVER_USER / AFS_SERVER_PASS are read first when both are set.

.PARAMETER CloudTiering
  Turn on cloud tiering for the server endpoints. Off by default: tiering is a capacity
  feature, and turning it on before the sync is proven makes a first run harder to read.

.PARAMETER VolumeFreeSpacePercent
  With -CloudTiering, the free space to keep on the volume. Default 20.

.PARAMETER Remove
  Reverse it: server endpoints, then cloud endpoints, then sync groups, then unregister the
  server. The agent stays unless -UninstallAgent is given. Share data is never deleted.

.PARAMETER UninstallAgent
  With -Remove, also uninstall the agent from the file server.

.EXAMPLE
  .\Install-AfsServerEndpoint.ps1 -Context ..\deploy\deployment-context.json -FileServer fs01 -SharePath @{ 'dept-shares' = 'D:\Shares\dept' } -WhatIf

.EXAMPLE
  .\Install-AfsServerEndpoint.ps1 -Context ..\deploy\deployment-context.json -FileServer fs01 -SharePath @{ 'dept-shares' = 'D:\Shares\dept' }

.NOTES
  Run from PowerShell, not Git Bash. Requires Az.Accounts, Az.Storage and Az.StorageSync on
  this machine; the same modules are installed on the file server if missing.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$Context,
    [Parameter(Mandatory)][string]$FileServer,
    [object[]]$SharePath,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$CloudTiering,
    [int]$VolumeFreeSpacePercent = 20,
    [int]$TierFilesOlderThanDays = 0,
    [switch]$Remove,
    [switch]$UninstallAgent,
    [switch]$SkipAgentInstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AfsOnPrem.ps1')
if (-not $env:AFS_LOG_FILE) { Start-AfsLog -Level Verbose -Name 'serverendpoint' | Out-Null }
Write-Host ('  log: ' + $env:AFS_LOG_FILE) -ForegroundColor DarkGray

$ctx = Read-AfsContext -Path $Context
$cfg = $ctx.config
$sub = $cfg.subscriptionId
$rg  = $cfg.resourceGroup
$sss = $cfg.storageSyncServiceName
$sa  = $cfg.storageAccountName
$env:AFS_SUBSCRIPTION_ID = $sub

# Which shares, and where they live on the server. Accepts a hashtable or share=path strings,
# and falls back to the on-premises section of the inputs when neither is given, so a second
# run needs no arguments at all.
$map = @{}
foreach ($item in (ConvertTo-AfsArray $SharePath)) {
    if ($null -eq $item) { continue }
    if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
        foreach ($k in $item.Keys) { $map[[string]$k] = [string]$item[$k] }
    } elseif ($item -is [string]) {
        $i = $item.IndexOf('=')
        if ($i -lt 1) { throw ("Cannot read '" + $item + "' as a share mapping. Use share=path, for example dept-shares=D:\Shares\dept.") }
        $map[$item.Substring(0, $i).Trim()] = $item.Substring($i + 1).Trim()
    } else {
        throw ('-SharePath takes a hashtable or share=path strings, not ' + $item.GetType().Name + '.')
    }
}
if ($map.Count -eq 0) {
    $onprem = Get-AfsProperty $cfg 'onPremises'
    $paths  = Get-AfsProperty $onprem 'serverPaths'
    if ($paths) { foreach ($p in $paths.PSObject.Properties) { $map[$p.Name] = [string]$p.Value } }
}
if ($map.Count -eq 0) {
    throw "No share-to-path mapping. Pass -SharePath @{ '<share>' = '<local path>' } or -SharePath '<share>=<local path>', or add onPremises.serverPaths to your inputs file."
}
$Mapping = $map   # normalised: share name -> local path
$known = @(ConvertTo-AfsArray $cfg.shares | ForEach-Object { $_.name })
foreach ($s in $Mapping.Keys) {
    if ($known -notcontains $s) { throw ("'" + $s + "' is not a share this deployment created. Known shares: " + ($known -join ', ')) }
}

Set-AfsStepTotal -Total $(if ($Remove) { 5 } else { 8 }) -Activity 'Azure File Sync - server endpoint'

Write-Host ''
Write-Host ("  file server  : " + $FileServer) -ForegroundColor White
Write-Host ("  sync service : " + $sss + " (" + $rg + ")")
Write-Host ("  storage      : " + $sa)
foreach ($s in ($Mapping.Keys | Sort-Object)) { Write-Host ("  share        : " + $s + "  <->  " + $Mapping[$s]) }
Write-Host ("  cloud tiering: " + $(if ($CloudTiering) { "on, keep $VolumeFreeSpacePercent% free" } else { 'off' }))

$serverCred = Get-AfsCredential -Credential $Credential -Message ("Local administrator on " + $FileServer) -UserEnvName 'AFS_SERVER_USER' -PasswordEnvName 'AFS_SERVER_PASS'
$session = $null
$verify  = New-Object System.Collections.ArrayList
function Add-Verify { param([string]$What, [string]$Cmd) [void]$verify.Add([pscustomobject]@{ What = $What; Cmd = $Cmd }) }

try {

# ================================================================= preflight ==

Write-AfsStep 'Preflight'

foreach ($m in @('Az.Accounts', 'Az.Storage', 'Az.StorageSync')) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw ("$m is not installed on this machine. Install it with: Install-Module $m -Scope CurrentUser")
    }
}
Write-AfsOk 'Az modules present on this machine'

$acct = Invoke-AfsAz -Args @('account', 'show', '-o', 'json') -AllowFailure
if (-not $acct) { throw 'Not signed in. Run: az login' }
Write-AfsOk ('signed in as ' + $acct.user.name)

[void](Confirm-AfsAzPowerShell -SubscriptionId $sub -TenantId (Get-AfsProperty $ctx.identity 'tenantId'))

$reach = Test-AfsRemoting -ComputerName $FileServer -Credential $serverCred
if (-not $reach.Ok) {
    Write-AfsWarn ('cannot reach ' + $FileServer + ' over PowerShell remoting: ' + $reach.Detail)
    Write-AfsSay "Check that WinRM is running on the server (Enable-PSRemoting -Force), that
port 5985 is open, and that the credential is a local administrator there.
From this machine:  Test-WSMan -ComputerName $FileServer"
    throw ('PowerShell remoting to ' + $FileServer + ' failed.')
}
Write-AfsOk ('WinRM reached ' + $FileServer)

$session = New-AfsSession -ComputerName $FileServer -Credential $serverCred

$state = Invoke-AfsRemote -Session $session -What 'read the server state' -ArgumentList (,($Mapping.Values | ForEach-Object { $_ })) -ScriptBlock {
    param($paths)
    $agent = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\Agent' -ErrorAction SilentlyContinue
    $rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    $vol = @()
    foreach ($p in $paths) {
        $root = $null; $fs = $null; $sys = $false
        try {
            $root = [System.IO.Directory]::GetDirectoryRoot($p)
            $v = Get-Volume -FilePath $root -ErrorAction SilentlyContinue
            if ($v) { $fs = $v.FileSystem }
            $sys = ($root -eq ($env:SystemDrive + '\'))
        } catch { }
        $vol += [pscustomobject]@{ Path = $p; Root = $root; FileSystem = $fs; IsSystemVolume = $sys; Exists = (Test-Path $p) }
    }
    [pscustomobject]@{
        ComputerName   = $env:COMPUTERNAME
        Build          = [System.Environment]::OSVersion.Version.Build
        Caption        = (Get-CimInstance Win32_OperatingSystem).Caption
        PSVersion      = $PSVersionTable.PSVersion.ToString()
        DotNetRelease  = $rel
        AgentVersion   = $(if ($agent) { $agent.Version } else { $null })
        AgentInstallDir= $(if ($agent) { $agent.InstallDir } else { $null })
        ServiceState   = (Get-Service FileSyncSvc -ErrorAction SilentlyContinue).Status
        InstallationType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\').InstallationType
        Volumes        = $vol
    }
}

Write-AfsOk ($state.ComputerName + ' - ' + $state.Caption + ' (build ' + $state.Build + '), PowerShell ' + $state.PSVersion)

$supported = @{ 26100 = 'Server2025'; 20348 = 'Server2022'; 17763 = 'Server2019'; 14393 = 'Server2016' }
if (-not $supported.ContainsKey([int]$state.Build)) {
    throw ('Azure File Sync supports Windows Server 2016, 2019, 2022 and 2025. That server reports build ' + $state.Build + '.')
}
$osTag = $supported[[int]$state.Build]

# .NET Framework 4.7.2 is release 461808; server registration will not run below it.
if (-not $state.DotNetRelease -or [int]$state.DotNetRelease -lt 461808) {
    throw ('.NET Framework 4.7.2 or later is required on the file server (found release ' + $state.DotNetRelease + '). Install it, then run this again.')
}
Write-AfsOk ('.NET Framework release ' + $state.DotNetRelease + ' meets the 4.7.2 requirement')

foreach ($v in (ConvertTo-AfsArray $state.Volumes)) {
    if ($v.FileSystem -ne 'NTFS') {
        throw ('A server endpoint path must be on a local NTFS volume. ' + $v.Path + ' resolves to ' + $v.Root + ' (' + $(if ($v.FileSystem) { $v.FileSystem } else { 'not a local volume' }) + ').')
    }
    if ($CloudTiering -and $v.IsSystemVolume) {
        throw ('Cloud tiering cannot be enabled on the system volume, and ' + $v.Path + ' is on ' + $v.Root + '. Use another volume or drop -CloudTiering.')
    }
    if (-not $v.Exists) { Write-AfsInfo ($v.Path + ' does not exist yet - it will be created') }
}
Write-AfsOk 'every server path is on a local NTFS volume'

# The agent reaches Azure over the public endpoint. If the sync service was locked to its
# private endpoint, an on-premises server without a VPN cannot register at all.
$policy = Invoke-AfsAz -Args @('resource', 'show', '-g', $rg, '-n', $sss, '--resource-type', 'Microsoft.StorageSync/storageSyncServices', '--query', 'properties.incomingTrafficPolicy', '-o', 'tsv') -AllowFailure
if ($policy -eq 'AllowVirtualNetworksOnly') {
    Write-AfsWarn 'the Storage Sync Service only accepts traffic from virtual networks'
    Write-AfsSay "The server can only register over a private path. Either give it one (VPN or
ExpressRoute plus the DNS forwarders from Set-AfsDnsForwarders.ps1), or set the
policy back with:
  az resource update -g $rg -n $sss --resource-type Microsoft.StorageSync/storageSyncServices --set properties.incomingTrafficPolicy=AllowAllTraffic"
} else {
    Write-AfsOk ('sync service traffic policy: ' + $(if ($policy) { $policy } else { 'AllowAllTraffic' }))
}

$keyAccess = Invoke-AfsAz -Args @('storage', 'account', 'show', '-n', $sa, '-g', $rg, '--query', 'allowSharedKeyAccess', '-o', 'tsv') -AllowFailure
# null means the property was never set, which Azure treats as allowed - so the default is $true
if (-not (ConvertTo-AfsBool $keyAccess -Default $true)) {
    throw ("Azure File Sync needs 'Allow storage account key access' enabled on " + $sa + ". Enable it with: az storage account update -n $sa -g $rg --allow-shared-key-access true")
}
Write-AfsOk 'storage account key access is allowed'

if ($Remove) { . (Join-Path $PSScriptRoot 'AfsServerEndpointRemove.ps1'); return }

# ============================================================ azure modules ===

Write-AfsStep 'Azure PowerShell on the file server'
Write-AfsSay 'Registering a server is done by the server itself, so it needs Az.Accounts and Az.StorageSync locally.'
[void](Install-AfsRemoteModule -Session $session -Name @('Az.Accounts', 'Az.StorageSync') -WhatIfMode:$WhatIfPreference)

# =================================================================== agent ====

Write-AfsStep 'Azure File Sync agent'

if ($state.AgentVersion) {
    Write-AfsOk ('agent ' + $state.AgentVersion + ' already installed (service ' + $state.ServiceState + ')')
} elseif ($SkipAgentInstall) {
    throw 'The agent is not installed and -SkipAgentInstall was given.'
} elseif ($PSCmdlet.ShouldProcess($FileServer, 'install the Azure File Sync agent')) {
    $url = 'https://aka.ms/afs/agent/' + $osTag
    Write-AfsInfo ('downloading ' + $url)
    # The installer closes PowerShell sessions while it runs - a documented behaviour that
    # would kill this remote session mid-install. Running it from a scheduled task detaches
    # it from the session, so the install survives and we poll for the result.
    $installed = Invoke-AfsRemote -Session $session -What 'install the agent' -ArgumentList @($url) -ScriptBlock {
        param($url)
        $dir = 'C:\Windows\Temp\afs-agent'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $msi = Join-Path $dir 'StorageSyncAgent.msi'
        $log = Join-Path $dir 'AFSInstaller.log'

        # An uninstall of this agent returns 3010 - done, but Windows needs a restart to
        # unload the file system filter. Install again before that restart and the MSI dies
        # with 1603 in about seven seconds. Catching it here costs two seconds; not catching
        # it costs the full install timeout and produces a log that names no cause.
        $pendingRename = @()
        try {
            $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
            if ($pfro) { $pendingRename = @($pfro | Where-Object { $_ -match 'StorageSync|FileSync' }) }
        } catch { }
        $filterLoaded = $false
        try { $filterLoaded = [bool](@(& fltmc.exe filters 2>$null) -match 'StorageSync') } catch { }
        $alreadyThere = [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\Agent' -ErrorAction SilentlyContinue)
        if (-not $alreadyThere -and ($pendingRename.Count -gt 0 -or $filterLoaded)) {
            throw ("This server still has the previous Azure File Sync agent's file system filter " +
                   "loaded, waiting for a restart. Installing now fails with MSI error 1603. " +
                   "Restart $env:COMPUTERNAME and run this step again.")
        }
        # A restart pending for some other reason does not stop the agent installing, so it is
        # worth saying and not worth blocking on.
        $genericPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                          (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        if ($genericPending) { Write-Warning "$env:COMPUTERNAME has a restart pending for another reason - continuing, but restart it soon." }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -TimeoutSec 600
        $sig = Get-AuthenticodeSignature $msi
        if ($sig.Status -ne 'Valid') { throw ('The downloaded agent is not validly signed: ' + $sig.Status) }
        $msiArgs = '/i "' + $msi + '" /qn /norestart /l*v "' + $log + '" ACCEPTEULA=1 ENABLE_MU_ENROLL=1 ENABLE_AGENT_AUTO_UPDATE=0'
        # A scheduled task, not Start-Process: the installer closes PowerShell sessions while
        # it runs, which would kill this remote session. The task cmdlets are used rather than
        # schtasks.exe because schtasks writes advisory text to stderr ("/ST is earlier than
        # current time") and PowerShell turns any native stderr into a terminating error.
        $task = 'AfsAgentInstall'
        $action = New-ScheduledTaskAction -Execute 'msiexec.exe' -Argument $msiArgs
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $task
        $deadline = (Get-Date).AddMinutes(20)
        $agent = $null
        $msiExit = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $agent = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\Agent' -ErrorAction SilentlyContinue
            if ($agent -and $agent.Version) { break }
            # Watching only for the success key means a failed MSI is indistinguishable from a
            # slow one, and the wait runs to the deadline for an install that died in seconds.
            # The task knows: ask it. 267011 is SCHED_S_TASK_HAS_NOT_RUN.
            $st   = (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).State
            $info = Get-ScheduledTaskInfo -TaskName $task -ErrorAction SilentlyContinue
            if ($st -and $st -ne 'Running' -and $info -and $info.LastTaskResult -ne 267011) {
                if ($info.LastTaskResult -ne 0 -and $info.LastTaskResult -ne 3010) { $msiExit = $info.LastTaskResult; break }
            }
        }
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        if (-not ($agent -and $agent.Version)) {
            # The last 25 lines of an MSI log are the teardown, which names no cause. These
            # patterns are the lines that do.
            $why = @()
            if (Test-Path $log) {
                $why = @(Get-Content $log -ErrorAction SilentlyContinue |
                         Where-Object { $_ -match 'Installation failed|error status: \d+|Error \d{4}|return value 3|Note: 1: 2262|MainEngineThread is returning' } |
                         Select-Object -Last 8)
            }
            $meaning = switch ($msiExit) {
                1603 { 'MSI 1603 - fatal error during installation. The usual cause is a previous agent whose file system filter is still loaded, waiting for a restart.' }
                1618 { 'MSI 1618 - another installation is already in progress. Wait for it to finish.' }
                1638 { 'MSI 1638 - another version of this product is already installed. Remove it first.' }
                1601 { 'MSI 1601 - the Windows Installer service could not be accessed.' }
                $null { $null }
                default { ('msiexec exited ' + $msiExit) }
            }
            $head = if ($msiExit -ne $null) { 'The agent installer failed. ' + $meaning }
                    else { 'The agent did not install within 20 minutes, and the installer task never reported a result.' }
            $detail = if ($why.Count) { "`n`nFrom $log :`n" + ($why -join "`n") } else { "`n`n(no usable detail in $log)" }
            throw ($head + $detail)
        }
        return [pscustomobject]@{ Version = $agent.Version; InstallDir = $agent.InstallDir; Service = (Get-Service FileSyncSvc -ErrorAction SilentlyContinue).Status }
    }
    Write-AfsOk ('agent ' + $installed.Version + ' installed (service ' + $installed.Service + ')')
    $state | Add-Member -NotePropertyName AgentVersion -NotePropertyValue $installed.Version -Force
}
Add-Verify 'agent version on the server' ("Invoke-Command -ComputerName $FileServer -ScriptBlock { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\Agent').Version }")

# ============================================================== registration ==

Write-AfsStep ('Register ' + $FileServer + ' with ' + $sss)

$registered = Get-AfsRegisteredServer -ResourceGroup $rg -StorageSyncService $sss -ComputerName $state.ComputerName

if ($registered) {
    Write-AfsOk ('already registered as ' + $registered.FriendlyName + ' (agent ' + $registered.AgentVersion + ', last heartbeat ' + $registered.LastHeartBeat + ')')
} elseif ($PSCmdlet.ShouldProcess($FileServer, 'register with the Storage Sync Service')) {
    $sec = Get-AfsDeploymentSecret -Context $ctx -ContextPath $Context
    if (-not $sec) {
        throw ('Server registration runs inside the session on ' + $FileServer + ', where your browser sign-in does not exist, so it needs the deployment identity from phase 1. ' +
               'deploy/deployment-identity.json was not found next to the context - re-run phase 1, or register the server by hand with ServerRegistration.exe.')
    }
    # Internet Explorer Enhanced Security blocks the registration flow; the previous value is
    # recorded so the reverse path can put it back.
    $prevEsc = Invoke-AfsRemote -Session $session -What 'relax IE Enhanced Security for registration' -ScriptBlock {
        $k = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
        if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\').InstallationType -eq 'Server Core') { return 'servercore' }
        $before = (Get-ItemProperty $k -ErrorAction SilentlyContinue).IsInstalled
        Set-ItemProperty -Path $k -Name IsInstalled -Value 0 -Force -ErrorAction SilentlyContinue
        return $before
    }
    Write-AfsInfo ('IE Enhanced Security was ' + $prevEsc + ' before this run')

    $result = Invoke-AfsRemote -Session $session -What 'register the server' -ArgumentList @($sec.appId, $sec.password, $sec.tenantId, $sub, $rg, $sss) -ScriptBlock {
        param($appId, $secret, $tenant, $subId, $rgName, $sssName)
        Import-Module Az.Accounts -ErrorAction Stop
        Import-Module Az.StorageSync -ErrorAction Stop
        $c = New-Object System.Management.Automation.PSCredential($appId, (ConvertTo-SecureString $secret -AsPlainText -Force))
        # -Scope Process keeps the secret out of the profile on disk.
        Connect-AzAccount -ServicePrincipal -Credential $c -Tenant $tenant -Subscription $subId -Scope Process -WarningAction SilentlyContinue | Out-Null
        $r = Register-AzStorageSyncServer -ResourceGroupName $rgName -StorageSyncServiceName $sssName
        Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null
        return [pscustomobject]@{ ServerId = $r.ServerId; FriendlyName = $r.FriendlyName; AgentVersion = $r.AgentVersion }
    }
    Write-AfsOk ('registered as ' + $result.FriendlyName + ' (server id ' + $result.ServerId + ')')
    $registered = Get-AfsRegisteredServer -ResourceGroup $rg -StorageSyncService $sss -ComputerName $state.ComputerName
}
Add-Verify 'registered server' ("Get-AzStorageSyncServer -ResourceGroupName $rg -StorageSyncServiceName $sss | Select-Object FriendlyName,AgentVersion,LastHeartBeat")

# ============================================================== sync groups ===

Write-AfsStep 'Sync groups'
foreach ($share in ($Mapping.Keys | Sort-Object)) {
    $sg = Get-AfsSyncGroupName -Config $cfg -ShareName $share
    $have = Get-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss -Name $sg -ErrorAction SilentlyContinue
    if ($have) { Write-AfsOk ($sg + ' already exists') }
    elseif ($PSCmdlet.ShouldProcess($sg, 'create sync group')) {
        New-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss -Name $sg | Out-Null
        Write-AfsOk ($sg + ' created')
    }
}
Add-Verify 'sync groups' ("Get-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss | Select-Object SyncGroupName,ProvisioningState")

# =========================================================== cloud endpoints ==

Write-AfsStep 'Cloud endpoints (one per Azure file share)'

$saId = Invoke-AfsAz -Args @('storage', 'account', 'show', '-n', $sa, '-g', $rg, '--query', 'id', '-o', 'tsv')
$needCloud = @()
foreach ($share in ($Mapping.Keys | Sort-Object)) {
    $sg = Get-AfsSyncGroupName -Config $cfg -ShareName $share
    $have = Get-AzStorageSyncCloudEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $sg -Name $share -ErrorAction SilentlyContinue
    if ($have) { Write-AfsOk ($share + ' cloud endpoint already exists') } else { $needCloud += $share }
}

if ($needCloud.Count) {
    # Creating a cloud endpoint assigns a role on the storage account, which Contributor is
    # not allowed to do. Check before trying, so the failure is a sentence and not an
    # AuthorizationFailed stack.
    $scope = Test-AfsAzureWriteScope -Scope $saId
    if (-not $scope.Ok) {
        Write-AfsWarn ('the signed-in account cannot create the cloud endpoint: ' + $scope.Detail)
        Write-AfsSay "Creating a cloud endpoint grants the Azure File Sync service 'Reader and Data
Access' on the storage account. That is a role assignment, and Contributor is
explicitly not allowed to create one.

Sign in as an account holding Owner, User Access Administrator, or Azure File
Sync Administrator on the storage account - or grant it to this one:

  az role assignment create --assignee $($scope.Who) --role 'Azure File Sync Administrator' --scope $saId

Everything else in this script has already been done; re-run it when that is in
place and it will continue from here."
        throw 'The signed-in account cannot create a cloud endpoint (needs to create a role assignment).'
    }
    Write-AfsOk ($scope.Who + ' ' + $scope.Detail)
    foreach ($share in $needCloud) {
        $sg = Get-AfsSyncGroupName -Config $cfg -ShareName $share
        if ($PSCmdlet.ShouldProcess($share, 'create cloud endpoint')) {
            New-AzStorageSyncCloudEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $sg `
                -Name $share -StorageAccountResourceId $saId -AzureFileShareName $share | Out-Null
            Write-AfsOk ($share + ' cloud endpoint created')
        }
    }
}
Add-Verify 'cloud endpoints' ("Get-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss | ForEach-Object { Get-AzStorageSyncCloudEndpoint -ParentObject `$_ } | Select-Object CloudEndpointName,AzureFileShareName,ProvisioningState")
Add-Verify 'the role the cloud endpoint granted' ("az role assignment list --scope $saId --query `"[?roleDefinitionName=='Reader and Data Access'].principalName`" -o tsv")

# ========================================================== server endpoints ==

Write-AfsStep 'Server endpoints (one per local folder)'

if (-not $registered -and -not $WhatIfPreference) { throw 'The server is not registered, so no server endpoint can be created.' }
$serverResourceId = $(if ($registered) { $registered.ResourceId } else { '<server resource id>' })

foreach ($share in ($Mapping.Keys | Sort-Object)) {
    $sg   = Get-AfsSyncGroupName -Config $cfg -ShareName $share
    $path = $Mapping[$share]
    $name = $state.ComputerName
    $have = Get-AzStorageSyncServerEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $sg -Name $name -ErrorAction SilentlyContinue
    if ($have) {
        Write-AfsOk ($share + ' server endpoint already exists (' + $have.ServerLocalPath + ')')
        continue
    }
    [void](Invoke-AfsRemote -Session $session -What ('ensure ' + $path + ' exists') -ArgumentList @($path) -ScriptBlock {
        param($p) if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    })
    if ($PSCmdlet.ShouldProcess(($share + ' -> ' + $path), 'create server endpoint')) {
        $p = @{
            ResourceGroupName     = $rg
            StorageSyncServiceName= $sss
            SyncGroupName         = $sg
            Name                  = $name
            ServerResourceId      = $serverResourceId
            ServerLocalPath       = $path
        }
        if ($CloudTiering) {
            $p.CloudTiering = $true
            $p.VolumeFreeSpacePercent = $VolumeFreeSpacePercent
            if ($TierFilesOlderThanDays -gt 0) { $p.TierFilesOlderThanDays = $TierFilesOlderThanDays }
        } else {
            $p.CloudTiering = $false
        }
        New-AzStorageSyncServerEndpoint @p | Out-Null
        Write-AfsOk ($share + ' server endpoint created for ' + $path)
    }
}
Add-Verify 'server endpoints and their health' ("Get-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss | ForEach-Object { Get-AzStorageSyncServerEndpoint -ParentObject `$_ } | Select-Object ServerEndpointName,ServerLocalPath,@{n='Health';e={`$_.SyncStatus.CombinedHealth}}")

# ================================================================== verify ====

Write-AfsStep 'First sync'
Write-AfsSay 'Health is Pending for a few minutes after creation; the server knows before Azure does.'

if (-not $WhatIfPreference) {
    $ev = Invoke-AfsRemote -Session $session -What 'read the sync telemetry log' -AllowFailure -ScriptBlock {
        Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-FileSync-Agent/Telemetry'; Id = 9301, 9302, 9102 } -MaxEvents 5 -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, @{ n = 'Msg'; e = { ($_.Message -replace "`r?`n", ' ').Substring(0, [Math]::Min(160, $_.Message.Length)) } }
    }
    if ($ev) { foreach ($e in (ConvertTo-AfsArray $ev)) { Write-AfsInfo ('' + $e.TimeCreated + '  ' + $e.Id + '  ' + $e.Msg) } }
    else { Write-AfsInfo 'no sync telemetry events yet - normal in the first minutes' }
}

Complete-AfsSteps -Outcome $(if ($WhatIfPreference) { 'WHAT-IF complete. Nothing was changed.' } else { 'Server endpoint setup complete.' })

Write-Host 'Verify with:' -ForegroundColor White
foreach ($v in $verify) { Write-Host ('  # ' + $v.What) -ForegroundColor DarkGray; Write-Host ('  ' + $v.Cmd) }
Write-Host ''
Write-Host 'What to expect:' -ForegroundColor White
Write-Host '  Files already on the server upload first; the share fills up over the next minutes.'
Write-Host '  Files added to the Azure share directly are detected once every 24 hours - to see'
Write-Host '  them sooner, force detection:'
Write-Host ("    Invoke-AzStorageSyncChangeDetection -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName <sync group> -CloudEndpointName <share>")
Write-Host ''
Write-Host ('Reverse it with: .\Install-AfsServerEndpoint.ps1 -Context ' + $Context + ' -FileServer ' + $FileServer + ' -Remove')

} finally {
    # closing a session is housekeeping, not a change - it must happen under -WhatIf too
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue -WhatIf:$false }
    Stop-AfsLog -Outcome 'server endpoint run ended'
}
