#Requires -Version 5.1
<#
.SYNOPSIS
  Collect a read-only diagnostic bundle from ONE Azure File Sync registered server
  (run on the server itself, elevated). Complements Export-AzFileSyncEnvironment.ps1,
  which sees the cloud side only.

.DESCRIPTION
  Captures, without changing anything:
    - OS, agent version (installed product + FileSyncSvc.exe file version), .NET version
    - Storage Sync Agent service + monitor process state, filter drivers (fltmc)
    - volumes (size, free, NTFS cluster size), dedup status, Windows Search state
    - roles/features that interact with sync (DFS-N, DFS-R, Dedup, FSRM), backup agents
      and antivirus products found in installed programs / Defender status + exclusions
    - time sync (w32tm), proxy (netsh winhttp), agent auto-update setting (registry)
    - SMB shares on the server (to map shares -> server endpoint paths)
    - Azure File Sync server cmdlets: Debug-StorageSyncServer -Diagnose,
      -TestNetworkConnectivity, -FileSyncErrorsReport (text captured)
    - self-service restore (Previous Versions) state per volume when the cmdlet exists
    - Telemetry event log, last N days: 9102 (sync session), 9121 (per-item errors),
      9302 (progress), 9301 (server heartbeat), 9003/9016/9029 (tiering),
      9005/9006/9009/9059/9071 (recall) - plus Operational log warnings/errors
    - optional: a tiered-file census per server endpoint path (-SampleTieredFiles)

  Output: <OutputPath>\<hostname>-afs-server-<stamp>\ (JSON + text) and a .zip.
  Copy the zip into the cloud export folder under servers\<hostname>\ before running
  Assess-AzFileSyncExport.ps1 so server-side findings are included.

.PARAMETER OutputPath
  Folder for the bundle. Default: current directory.

.PARAMETER EventLookbackDays
  Days of Telemetry/Operational events to export (default 7).

.PARAMETER SampleTieredFiles
  Walk each server endpoint path (from the registry) and count tiered files. Can take
  long on large namespaces; bounded by -MaxFiles.

.PARAMETER MaxFiles
  Upper bound of files inspected per server endpoint when -SampleTieredFiles is set
  (default 200000).

.PARAMETER SkipAfsDiag
  Skip Debug-StorageSyncServer -AFSDiag (log/trace collection). Default: skipped; pass
  -CollectAfsDiag to include it (large output, minutes).

.EXAMPLE
  .\Get-AfsServerDiagnostics.ps1 -OutputPath C:\temp

.NOTES
  Read-only. Requires elevation for event logs, fltmc and the server cmdlets.
  Luca Express - change-management/contoso-azure-file-sync-backup. Version 1.0.0.
#>
[CmdletBinding()]
param(
  [string]$OutputPath = (Get-Location).Path,
  [ValidateRange(1, 90)][int]$EventLookbackDays = 7,
  [switch]$SampleTieredFiles,
  [int]$MaxFiles = 200000,
  [switch]$CollectAfsDiag
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0.0'
$host_ = $env:COMPUTERNAME
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $OutputPath ("{0}-afs-server-{1}" -f $host_, $stamp)
New-Item -ItemType Directory -Path $out -Force | Out-Null
$errors = New-Object System.Collections.ArrayList
function Step([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Save([string]$name, $obj) {
  $p = Join-Path $out $name
  $json = if ($null -eq $obj) { 'null' } else { $obj | ConvertTo-Json -Depth 32 }
  [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
}
function SaveText([string]$name, [string]$text) { [System.IO.File]::WriteAllText((Join-Path $out $name), $text, (New-Object System.Text.UTF8Encoding($false))) }
function Try-Run([string]$label, [scriptblock]$sb) {
  try { return (& $sb) } catch { [void]$errors.Add(@{ where = $label; detail = $_.Exception.Message }); Write-Warning "$label : $($_.Exception.Message)"; return $null }
}
function Capture([string]$label, [scriptblock]$sb) {
  try { return ((& $sb) 2>&1 | Out-String) } catch { [void]$errors.Add(@{ where = $label; detail = $_.Exception.Message }); return "ERROR: $($_.Exception.Message)" }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning 'Not elevated: event logs, fltmc and server cmdlets may be incomplete. Re-run from an elevated PowerShell.' }
Step "Get-AfsServerDiagnostics v$ToolVersion on $host_ -> $out"

# -- 1. system --------------------------------------------------------------------------
Step 'System'
$os = Try-Run 'os' { Get-CimInstance Win32_OperatingSystem }
$cs = Try-Run 'computersystem' { Get-CimInstance Win32_ComputerSystem }
$agentProduct = Try-Run 'agent-product' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Storage Sync Agent*' } | Select-Object -First 1 DisplayName, DisplayVersion, InstallDate }
$agentExe = 'C:\Program Files\Azure\StorageSyncAgent\FileSyncSvc.exe'
$agentFileVersion = if (Test-Path $agentExe) { (Get-Item $agentExe).VersionInfo.FileVersion } else { $null }
$afsReg = Try-Run 'agent-registry' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync' -ErrorAction SilentlyContinue }
$autoUpdate = Try-Run 'agent-autoupdate' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\AutoUpdate' -ErrorAction SilentlyContinue }
$dotnet = Try-Run 'dotnet' { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release }
$cluster = Try-Run 'cluster' { if (Get-Command Get-Cluster -ErrorAction SilentlyContinue) { Get-Cluster -ErrorAction SilentlyContinue | Select-Object Name, Domain } }
Save 'system.json' ([ordered]@{
  hostname = $host_; domain = $cs.Domain; partOfDomain = $cs.PartOfDomain; manufacturer = $cs.Manufacturer; model = $cs.Model
  totalMemoryGiB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1); logicalProcessors = $cs.NumberOfLogicalProcessors
  osCaption = $os.Caption; osVersion = $os.Version; osBuild = $os.BuildNumber; lastBoot = $os.LastBootUpTime; installDate = $os.InstallDate
  agentProduct = $agentProduct; agentFileVersion = $agentFileVersion; agentRegistry = $afsReg; agentAutoUpdate = $autoUpdate
  dotNetRelease = $dotnet; cluster = $cluster; collectedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); toolVersion = $ToolVersion; elevated = $isAdmin
})

# -- 2. services / drivers / processes ----------------------------------------------------
Step 'Services, drivers'
$svc = Try-Run 'services' { Get-Service -Name FileSyncSvc, WSearch, W32Time, Dedup*, DFSR, Dfs, srmsvc, MpsSvc, WinDefend, obengine -ErrorAction SilentlyContinue | Select-Object Name, DisplayName, Status, StartType }
$mon = Try-Run 'monitor-process' { Get-Process -Name AzureStorageSyncMonitor, FileSyncSvc -ErrorAction SilentlyContinue | Select-Object Name, Id, StartTime, WorkingSet64 }
$fltmc = Capture 'fltmc' { fltmc filters }
Save 'services.json' ([ordered]@{ services = @($svc); processes = @($mon); filterDriversPresent = [ordered]@{ StorageSync = ($fltmc -match 'StorageSync\s'); StorageSyncGuard = ($fltmc -match 'StorageSyncGuard') } })
SaveText 'fltmc.txt' $fltmc

# -- 3. volumes / dedup / search / features -----------------------------------------------
Step 'Volumes, dedup, features'
$vols = Try-Run 'volumes' { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $cl = $null
    try { $info = (fsutil fsinfo ntfsinfo "$($_.DeviceID)\" 2>$null | Out-String); if ($info -match 'Bytes Per Cluster\s*:\s*([\d,]+)') { $cl = [int]($Matches[1] -replace ',', '') } } catch {}
    [ordered]@{ drive = $_.DeviceID; label = $_.VolumeName; fileSystem = $_.FileSystem; sizeGiB = [math]::Round($_.Size / 1GB, 1); freeGiB = [math]::Round($_.FreeSpace / 1GB, 1); freePercent = if ($_.Size) { [math]::Round(100 * $_.FreeSpace / $_.Size, 1) } else { $null }; bytesPerCluster = $cl }
  } }
$dedup = Try-Run 'dedup' { if (Get-Command Get-DedupVolume -ErrorAction SilentlyContinue) { Get-DedupVolume -ErrorAction SilentlyContinue | Select-Object Volume, Enabled, MinimumFileAgeDays, SavedSpace, OptimizedFilesCount, UsageType } }
$features = Try-Run 'features' { if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) { Get-WindowsFeature -Name FS-DFS-Namespace, FS-DFS-Replication, FS-Data-Deduplication, FS-Resource-Manager, FS-Search-Service, Windows-Defender, Failover-Clustering -ErrorAction SilentlyContinue | Select-Object Name, DisplayName, Installed } }
$searchIdx = Try-Run 'search-index-scopes' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex\WorkingSetRules\*' -ErrorAction SilentlyContinue | Select-Object URL, Include }
Save 'volumes.json' ([ordered]@{ volumes = @($vols); dedup = @($dedup); features = @($features); windowsSearchScopes = @($searchIdx) })

# -- 4. installed programs: backup agents, antivirus --------------------------------------
Step 'Installed programs (backup / AV)'
$progs = Try-Run 'programs' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Select-Object DisplayName, DisplayVersion, Publisher }
$backupAv = @($progs | Where-Object { $_.DisplayName -match 'Backup|Recovery Services Agent|Veeam|Commvault|Veritas|NetBackup|Backup Exec|Arcserve|Rubrik|Cohesity|Data Protection Manager|Acronis|Datto|Carbonite|Druva|Sophos|Symantec|McAfee|Trend|CrowdStrike|SentinelOne|Cylance|Kaspersky|ESET|Bitdefender|Carbon Black|Cortex|Defender' })
$mp = Try-Run 'defender' { if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) { $s = Get-MpComputerStatus; $p = Get-MpPreference; [ordered]@{ realTime = $s.RealTimeProtectionEnabled; amRunning = $s.AMServiceEnabled; engine = $s.AMEngineVersion; signatureAge = $s.AntivirusSignatureAge; exclusionPaths = @($p.ExclusionPath); exclusionProcesses = @($p.ExclusionProcess); exclusionExtensions = @($p.ExclusionExtension) } } }
Save 'programs.json' ([ordered]@{ backupOrAvProducts = $backupAv; defender = $mp; allPrograms = @($progs) })

# -- 5. time, proxy, network ---------------------------------------------------------------
Step 'Time / proxy / network'
SaveText 'w32tm.txt' (Capture 'w32tm' { w32tm /query /status })
SaveText 'winhttp-proxy.txt' (Capture 'winhttp' { netsh winhttp show proxy })
$ips = Try-Run 'ipconfig' { Get-NetIPConfiguration -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, @{n = 'IPv4'; e = { @($_.IPv4Address.IPAddress) } }, @{n = 'DNS'; e = { @($_.DNSServer.ServerAddresses) } }, @{n = 'Gateway'; e = { @($_.IPv4DefaultGateway.NextHop) } } }
$dnsTests = @()
foreach ($n in @('management.azure.com', 'login.microsoftonline.com')) { $dnsTests += (Try-Run "dns:$n" { $r = Resolve-DnsName $n -ErrorAction Stop | Select-Object -First 1; [ordered]@{ name = $n; type = $r.Type; address = $r.IPAddress; nameHost = $r.NameHost } }) }
Save 'network.json' ([ordered]@{ ipConfiguration = @($ips); dnsTests = @($dnsTests) })

# -- 6. SMB shares (map to endpoint paths) -----------------------------------------------
Step 'SMB shares'
$shares = Try-Run 'smbshares' { Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\w\$$|^(ADMIN|IPC)\$$' } | Select-Object Name, Path, ScopeName, EncryptData, FolderEnumerationMode, ContinuouslyAvailable }
Save 'smbshares.json' @($shares)

# -- 7. Azure File Sync server cmdlets ----------------------------------------------------
Step 'Azure File Sync server cmdlets'
$dll = 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll'
$serverEndpointsReg = Try-Run 'endpoints-registry' { Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue; if ($p.PSObject.Properties['ServerLocalPath'] -or $p.PSObject.Properties['LocalPath']) { $p } } }
Save 'registry-storagesync.json' @($serverEndpointsReg | Select-Object * -ExcludeProperty PSPath, PSParentPath, PSChildName, PSDrive, PSProvider)
if (Test-Path $dll) {
  $imp = Try-Run 'import-servercmdlets' { Import-Module $dll -ErrorAction Stop; 'imported' }
  if ($imp) {
    SaveText 'debug-diagnose.txt' (Capture 'Debug-StorageSyncServer -Diagnose' { Debug-StorageSyncServer -Diagnose })
    SaveText 'debug-network.txt' (Capture 'Debug-StorageSyncServer -TestNetworkConnectivity' { Debug-StorageSyncServer -TestNetworkConnectivity })
    SaveText 'debug-filesyncerrors.txt' (Capture 'Debug-StorageSyncServer -FileSyncErrorsReport' { Debug-StorageSyncServer -FileSyncErrorsReport })
    if (Get-Command Get-StorageSyncSelfServiceRestore -ErrorAction SilentlyContinue) {
      $ssr = @(); foreach ($v in @($vols)) { $ssr += (Try-Run "selfservicerestore:$($v.drive)" { $r = Get-StorageSyncSelfServiceRestore -DriveLetter $v.drive.TrimEnd(':') -ErrorAction Stop; [ordered]@{ drive = $v.drive; result = ($r | Out-String).Trim() } }) }
      Save 'selfservicerestore.json' @($ssr)
    }
    if ($CollectAfsDiag) { $d = Join-Path $out 'afsdiag'; New-Item -ItemType Directory -Path $d -Force | Out-Null; SaveText 'afsdiag-run.txt' (Capture 'AFSDiag' { Debug-StorageSyncServer -AFSDiag -OutputDirectory $d -KernelModeTraceLevel Verbose -UserModeTraceLevel Verbose }) }
  }
} else {
  [void]$errors.Add(@{ where = 'servercmdlets'; detail = "agent DLL not found at $dll - is the Azure File Sync agent installed on this server?" })
}

# -- 8. event logs ----------------------------------------------------------------------
Step "Event logs (last $EventLookbackDays days)"
$since = (Get-Date).AddDays(-1 * $EventLookbackDays)
$telemetryIds = @(9102, 9121, 9302, 9301, 9003, 9016, 9029, 9005, 9006, 9009, 9059, 9071)
$tel = Try-Run 'telemetry-log' { Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-FileSync-Agent/Telemetry'; StartTime = $since; Id = $telemetryIds } -ErrorAction Stop -MaxEvents 5000 | ForEach-Object { [ordered]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); id = $_.Id; level = $_.LevelDisplayName; message = $_.Message } } }
Save 'events-telemetry.json' @($tel)
$ops = Try-Run 'operational-log' { Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-FileSync-Agent/Operational'; StartTime = $since; Level = @(1, 2, 3) } -ErrorAction Stop -MaxEvents 2000 | ForEach-Object { [ordered]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); id = $_.Id; level = $_.LevelDisplayName; message = $_.Message } } }
Save 'events-operational.json' @($ops)
# compact sync-session digest: 9102 HResult + PerItemErrorCount
$digest = @()
foreach ($e in @($tel | Where-Object { $_.id -eq 9102 })) {
  $h = if ($e.message -match 'HResult:\s*(-?\d+|0x[0-9A-Fa-f]+)') { $Matches[1] } else { $null }
  $pi = if ($e.message -match 'PerItemErrorCount:\s*(\d+)') { [int]$Matches[1] } else { $null }
  $sg = if ($e.message -match 'SyncGroupName:\s*([^\r\n,]+)') { $Matches[1].Trim() } else { $null }
  $dir = if ($e.message -match 'SyncDirection:\s*([^\r\n,]+)') { $Matches[1].Trim() } else { $null }
  $digest += [ordered]@{ time = $e.time; syncGroup = $sg; direction = $dir; hresult = $h; perItemErrorCount = $pi }
}
Save 'sync-session-digest.json' @($digest)

# -- 9. optional tiered-file census ----------------------------------------------------
if ($SampleTieredFiles) {
  Step 'Tiered file census (bounded)'
  $paths = @($serverEndpointsReg | ForEach-Object { if ($_.PSObject.Properties['ServerLocalPath']) { $_.ServerLocalPath } elseif ($_.PSObject.Properties['LocalPath']) { $_.LocalPath } } | Where-Object { $_ } | Select-Object -Unique)
  $census = @()
  foreach ($p in $paths) {
    if (-not (Test-Path $p)) { continue }
    $n = 0; $tiered = 0; $bytesLocal = 0L; $bytesTieredLogical = 0L
    try {
      Get-ChildItem -LiteralPath $p -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $n++; if ($n -gt $MaxFiles) { throw 'limit' }
        if ($_.Attributes -band 0x400000) { $tiered++; $bytesTieredLogical += $_.Length } else { $bytesLocal += $_.Length }
      }
    } catch { }
    $census += [ordered]@{ path = $p; filesInspected = [math]::Min($n, $MaxFiles); truncated = ($n -gt $MaxFiles); tieredFiles = $tiered; localBytesGiB = [math]::Round($bytesLocal / 1GB, 2); tieredLogicalGiB = [math]::Round($bytesTieredLogical / 1GB, 2) }
  }
  Save 'tiered-census.json' @($census)
}

Save 'errors.json' @($errors)
$zip = "$out.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -CompressionLevel Optimal
Step "Done. $($errors.Count) warning(s). Bundle: $zip"
Write-Host 'Copy the zip into the cloud export folder under servers\<hostname>\ and run Assess-AzFileSyncExport.ps1.'
