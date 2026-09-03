<#
  The reverse path for Install-AfsServerEndpoint.ps1. Dot-sourced by it when -Remove is
  given, so it shares the session, the context and the resolved names.

  The order is not a preference, it is the only order Azure accepts:

      server endpoint  ->  cloud endpoint  ->  sync group  ->  unregister server

  Removing a server endpoint stops sync for that folder. The local files stay, and the files
  in the Azure file share stay - nothing here deletes data. The one real hazard is cloud
  tiering: a tiered file is a pointer, and removing the endpoint leaves that pointer with
  nothing behind it. So when tiering is on anywhere on this server, the files are recalled
  first and the run refuses to continue if the recall did not finish.
#>

Write-AfsStep 'Server endpoints'

$groups = ConvertTo-AfsArray (Get-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss -ErrorAction SilentlyContinue)
$mine = @()
foreach ($g in $groups) {
    $eps = ConvertTo-AfsArray (Get-AzStorageSyncServerEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $g.SyncGroupName -ErrorAction SilentlyContinue)
    foreach ($e in $eps) {
        if ((($e.ServerEndpointName -split '\.')[0]) -ieq (($state.ComputerName -split '\.')[0])) { $mine += [pscustomobject]@{ Group = $g.SyncGroupName; Endpoint = $e } }
    }
}

if ($mine.Count -eq 0) {
    Write-AfsOk ('no server endpoints for ' + $state.ComputerName)
} else {
    $tiered = @($mine | Where-Object { $_.Endpoint.CloudTiering -eq 'on' -or $_.Endpoint.CloudTiering -eq $true })
    if ($tiered.Count) {
        Write-AfsWarn ($tiered.Count.ToString() + ' endpoint(s) have cloud tiering on - recalling before removal')
        Write-AfsSay "A tiered file on disk is a pointer to the cloud copy. Remove the endpoint while
files are still tiered and those pointers stop resolving, so every file is pulled
back down first. This can take a long time and needs free space on the volume."
        foreach ($t in $tiered) {
            $path = $t.Endpoint.ServerLocalPath
            if ($PSCmdlet.ShouldProcess($path, 'recall tiered files')) {
                $recall = Invoke-AfsRemote -Session $session -What ('recall tiered files under ' + $path) -ArgumentList @($path) -ScriptBlock {
                    param($p)
                    Import-Module 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll' -ErrorAction Stop
                    Invoke-StorageSyncFileRecall -Path $p -ErrorAction Stop
                    $left = Get-ChildItem -Path $p -Recurse -Force -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Attributes -band [IO.FileAttributes]::Offline }
                    return @($left).Count
                }
                if ($recall -gt 0) { throw ($recall.ToString() + ' file(s) under ' + $path + ' are still tiered. Recall them before removing the endpoint.') }
                Write-AfsOk ('recalled everything under ' + $path)
            }
        }
    }
    foreach ($m in $mine) {
        if ($PSCmdlet.ShouldProcess(($m.Group + '/' + $m.Endpoint.ServerEndpointName), 'remove server endpoint')) {
            Remove-AzStorageSyncServerEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $m.Group -Name $m.Endpoint.ServerEndpointName -Force | Out-Null
            Write-AfsOk ('removed server endpoint ' + $m.Group + '/' + $m.Endpoint.ServerEndpointName)
        }
    }
}

Write-AfsStep 'Cloud endpoints'

foreach ($share in ($Mapping.Keys | Sort-Object)) {
    $sg = Get-AfsSyncGroupName -Config $cfg -ShareName $share
    $ce = Get-AzStorageSyncCloudEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $sg -Name $share -ErrorAction SilentlyContinue
    if (-not $ce) { Write-AfsOk ($share + ' cloud endpoint already gone'); continue }
    # Refuse while another server still syncs this group - removing the cloud endpoint would
    # break that server's sync, and this script only knows about its own file server.
    $others = ConvertTo-AfsArray (Get-AzStorageSyncServerEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $sg -ErrorAction SilentlyContinue)
    if ($others.Count) {
        Write-AfsWarn ($sg + ' still has ' + $others.Count + ' server endpoint(s): ' + (($others | ForEach-Object { $_.ServerEndpointName }) -join ', '))
        Write-AfsSay 'Leaving the cloud endpoint and the sync group in place - another server is using them.'
        continue
    }
    if ($PSCmdlet.ShouldProcess($share, 'remove cloud endpoint')) {
        Remove-AzStorageSyncCloudEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $sg -Name $share -Force | Out-Null
        Write-AfsOk ('removed cloud endpoint ' + $share + ' (the file share and its contents are untouched)')
    }
}

Write-AfsStep 'Sync groups'

foreach ($share in ($Mapping.Keys | Sort-Object)) {
    $sg = Get-AfsSyncGroupName -Config $cfg -ShareName $share
    $g = Get-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss -Name $sg -ErrorAction SilentlyContinue
    if (-not $g) { Write-AfsOk ($sg + ' already gone'); continue }
    $ce = ConvertTo-AfsArray (Get-AzStorageSyncCloudEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $sg -ErrorAction SilentlyContinue)
    $se = ConvertTo-AfsArray (Get-AzStorageSyncServerEndpoint -ResourceGroupName $rg -StorageSyncServiceName $sss -SyncGroupName $sg -ErrorAction SilentlyContinue)
    if ($ce.Count -or $se.Count) { Write-AfsWarn ($sg + ' still has endpoints - left in place'); continue }
    if ($PSCmdlet.ShouldProcess($sg, 'remove sync group')) {
        Remove-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss -Name $sg -Force | Out-Null
        Write-AfsOk ('removed sync group ' + $sg)
    }
}

Write-AfsStep 'Server registration'

$reg = Get-AfsRegisteredServer -ResourceGroup $rg -StorageSyncService $sss -ComputerName $state.ComputerName

if (-not $reg) {
    Write-AfsOk ($state.ComputerName + ' is not registered')
} elseif ($PSCmdlet.ShouldProcess($state.ComputerName, 'unregister from the Storage Sync Service')) {
    Unregister-AzStorageSyncServer -ResourceGroupName $rg -StorageSyncServiceName $sss -ServerId $reg.ServerId -Force | Out-Null
    Write-AfsOk ('unregistered ' + $state.ComputerName)
}

if ($UninstallAgent) {
    if ($PSCmdlet.ShouldProcess($FileServer, 'uninstall the Azure File Sync agent')) {
        $r = Invoke-AfsRemote -Session $session -What 'uninstall the agent' -ScriptBlock {
            $p = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
                Get-ItemProperty | Where-Object { $_.DisplayName -like '*Storage Sync Agent*' -or $_.DisplayName -like '*Azure File Sync*' } | Select-Object -First 1
            if (-not $p) { return 'not installed' }
            $proc = Start-Process msiexec.exe -ArgumentList ('/x ' + $p.PSChildName + ' /qn /norestart') -Wait -PassThru
            return ('msiexec exit ' + $proc.ExitCode)
        }
        Write-AfsOk ('agent uninstall: ' + $r)
    }
} else {
    Write-AfsInfo 'the agent is left installed - add -UninstallAgent to remove it as well'
}

Complete-AfsSteps -Outcome $(if ($WhatIfPreference) { 'WHAT-IF complete. Nothing was changed.' } else { 'Reverse path complete.' })

Write-Host 'Confirm with:' -ForegroundColor White
Write-Host ("  Get-AzStorageSyncServer -ResourceGroupName $rg -StorageSyncServiceName $sss | Select-Object FriendlyName")
Write-Host ("  Get-AzStorageSyncGroup -ResourceGroupName $rg -StorageSyncServiceName $sss | Select-Object SyncGroupName")
Write-Host ''
Write-Host 'Two things this does not do, by design:' -ForegroundColor White
Write-Host '  The Azure file shares and their contents are left alone.'
Write-Host "  Azure File Sync takes a share snapshot when a cloud endpoint is created and never"
Write-Host '  deletes it. List them with:'
Write-Host ("    az storage share list --account-name $sa --include-snapshots --query `"[?snapshot].{name:name,snapshot:snapshot}`" -o table")
