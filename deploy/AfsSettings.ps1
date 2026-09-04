<#
  The deployment settings editor behind the wizard's "Deployment settings" option.

  Everything the build does is derived from four inputs plus an optional overrides section.
  That is a good design for repeatability and a poor one for discoverability: unless you read
  AfsConfig.ps1 you cannot tell that the resource group name, the address space or the backup
  retention are yours to change at all.

  So this lists every setting with the value that is actually in force - the one you set, or
  the one derived from your name prefix - and lets you change any of them. A setting left
  alone stays derived, so changing the prefix still renames everything that follows from it.

  Dot-sourced by start.ps1. Reads and writes deploy/inputs.json.
#>

Set-StrictMode -Version 2.0

# Group, key, where it lives in the inputs file, and what it means. 'Derived' settings live
# under overrides and are shown with the value the resolver would pick when they are absent.
function Get-AfsSettingCatalog {
    @(
        @{ Group = 'Azure';     Path = 'azure.subscriptionId'; Label = 'Subscription id'
           Why = 'Where everything is built.'; Pattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; Help = 'a subscription GUID' }
        @{ Group = 'Azure';     Path = 'azure.location'; Label = 'Region'
           Why = 'The vault must be in the same region as the storage account, so this moves both.'; Pattern = '^[a-z0-9]+$'; Help = 'a region short name such as eastus' }
        @{ Group = 'Azure';     Path = 'azure.namePrefix'; Label = 'Name prefix'
           Why = 'Every derived name starts from this. Changing it renames the group, storage account, sync service, vault, network and resolver in one go.'; Pattern = '^[a-z0-9]{2,8}$'; Help = '2 to 8 lowercase letters or digits' }
        @{ Group = 'Azure';     Path = 'azure.uniqueSuffix'; Label = 'Storage name suffix'
           Why = 'Storage account names are globally unique; this is what makes yours unlikely to collide.'; Pattern = '^[a-z0-9]{1,6}$'; Help = '1 to 6 lowercase letters or digits' }

        @{ Group = 'Names';     Path = 'overrides.resourceGroup'; Label = 'Resource group'; Derived = 'resourceGroup'
           Why = 'Derived from the prefix unless you set it.' }
        @{ Group = 'Names';     Path = 'overrides.storageAccountName'; Label = 'Storage account'; Derived = 'storageAccountName'
           Why = 'Must be globally unique, 3 to 24 lowercase letters and digits.'; Pattern = '^[a-z0-9]{3,24}$'; Help = '3 to 24 lowercase letters and digits' }
        @{ Group = 'Names';     Path = 'overrides.storageSyncServiceName'; Label = 'Storage Sync Service'; Derived = 'storageSyncServiceName' }
        @{ Group = 'Names';     Path = 'overrides.vaultName'; Label = 'Recovery Services vault'; Derived = 'vaultName' }
        @{ Group = 'Names';     Path = 'overrides.vnetName'; Label = 'Virtual network'; Derived = 'vnetName' }
        @{ Group = 'Names';     Path = 'overrides.dnsResolverName'; Label = 'DNS Private Resolver'; Derived = 'dnsResolverName' }

        @{ Group = 'Network';   Path = 'overrides.vnetAddressPrefix'; Label = 'Address space'; Derived = 'vnetAddressPrefix'
           Why = 'Must not overlap anything it will be peered or routed to.'; Pattern = '^\d+\.\d+\.\d+\.\d+/\d+$'; Help = 'CIDR, for example 10.60.0.0/16' }
        @{ Group = 'Network';   Path = 'overrides.peSubnetName'; Label = 'Private endpoint subnet'; Derived = 'peSubnetName' }
        @{ Group = 'Network';   Path = 'overrides.peSubnetPrefix'; Label = 'Private endpoint subnet range'; Derived = 'peSubnetPrefix'
           Pattern = '^\d+\.\d+\.\d+\.\d+/\d+$'; Help = 'CIDR inside the address space' }
        @{ Group = 'Network';   Path = 'overrides.inboundSubnetName'; Label = 'Resolver inbound subnet'; Derived = 'inboundSubnetName' }
        @{ Group = 'Network';   Path = 'overrides.inboundSubnetPrefix'; Label = 'Resolver inbound range'; Derived = 'inboundSubnetPrefix'
           Why = 'Delegated to the resolver, so nothing else may use it. A /28 is the documented minimum.'; Pattern = '^\d+\.\d+\.\d+\.\d+/\d+$'; Help = 'CIDR, /28 or larger' }
        @{ Group = 'Network';   Path = 'overrides.deployDnsResolver'; Label = 'Deploy the DNS resolver'; Derived = 'deployDnsResolver'; Bool = $true
           Why = 'Turn off if on-premises name resolution is handled another way.' }

        @{ Group = 'Storage';   Path = 'overrides.storageSku'; Label = 'Redundancy'; Derived = 'storageSku'
           Why = 'One way in places: you cannot move from zone-redundant back to locally redundant.'; Pattern = '^Standard_(LRS|ZRS|GRS|GZRS|RAGRS|RAGZRS)$'; Help = 'Standard_LRS, Standard_ZRS, Standard_GRS, Standard_GZRS, Standard_RAGRS or Standard_RAGZRS' }

        @{ Group = 'Backup';    Path = 'overrides.deployBackup'; Label = 'Deploy backup'; Derived = 'deployBackup'; Bool = $true }
        @{ Group = 'Backup';    Path = 'overrides.backupDailyRetentionDays'; Label = 'Daily retention (days)'; Derived = 'backupRetentionDays'; Int = $true
           Why = 'The snapshot tier keeps up to 200 days and is the only tier that restores a single file.'; Pattern = '^\d+$'; Help = 'a number of days, 1 to 200' }
        @{ Group = 'Backup';    Path = 'overrides.backupStorageRedundancy'; Label = 'Vault redundancy'; Derived = 'storageRedundancy'
           Why = 'One way, and it must be set before the first protected item.'; Pattern = '^(LocallyRedundant|GeoRedundant|ZoneRedundant)$'; Help = 'LocallyRedundant, GeoRedundant or ZoneRedundant' }
        @{ Group = 'Backup';    Path = 'overrides.enableCrossRegionRestore'; Label = 'Cross-region restore'; Derived = 'crossRegionRestore'; Bool = $true
           Why = 'Also one way, and geo-redundant only.' }

        @{ Group = 'Directory'; Path = 'overrides.enableAdDsJoin'; Label = 'Domain-join the storage account'; Derived = 'enableAdDsJoin'; Bool = $true }
        @{ Group = 'Directory'; Path = 'activeDirectory.domainFqdn'; Label = 'AD domain'; Why = 'The domain the file servers and users belong to.' }
        @{ Group = 'Directory'; Path = 'activeDirectory.netBiosName'; Label = 'NetBIOS name' }
        @{ Group = 'Directory'; Path = 'activeDirectory.organizationalUnitDistinguishedName'; Label = 'Organizational unit'
           Why = 'Where the storage account object is created. A dedicated OU is easier to find, audit and delegate than the default Computers container.' }
        @{ Group = 'Directory'; Path = 'activeDirectory.identityObjectType'; Label = 'Object type'
           Why = 'A computer account is the default; its password does not expire on the OU policy.'; Pattern = '^(ComputerAccount|ServiceLogonAccount)$'; Help = 'ComputerAccount or ServiceLogonAccount' }
        @{ Group = 'Directory'; Path = 'activeDirectoryAdmin.userPrincipalName'; Label = 'AD admin account'
           Why = 'Needs only the right to create an object in that OU - not Domain Admin.' }

        @{ Group = 'On-premises'; Path = 'onPremises.fileServer'; Label = 'File server'
           Why = 'The server to register with the sync service. A name PowerShell remoting can reach.'; Pattern = '^[A-Za-z0-9._-]+$'; Help = 'a computer name, for example fs01.corp.contoso.com' }
        @{ Group = 'On-premises'; Path = 'onPremises.dnsServers'; Label = 'DNS servers'
           Why = 'Every resolver your clients use. Active Directory replicates a conditional forwarder to domain controllers running DNS and nowhere else, so member servers and appliances belong here too.'; Pattern = '^[A-Za-z0-9._,\s-]+$'; Help = 'one or more computer names separated by commas' }
    )
}

function Get-AfsInputValue {
    <# Read a dotted path out of the inputs object, or $null when any part is missing. #>
    param($Inputs, [string]$Path)
    $node = $Inputs
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $node) { return $null }
        $p = $node.PSObject.Properties[$part]
        if (-not $p) { return $null }
        $node = $p.Value
    }
    return $node
}

function Set-AfsInputValue {
    <# Write a dotted path into the inputs object, creating the sections it needs. #>
    param($Inputs, [string]$Path, $Value)
    $parts = $Path -split '\.'
    $node = $Inputs
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $name = $parts[$i]
        if (-not $node.PSObject.Properties[$name] -or $null -eq $node.$name) {
            $node | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $node = $node.$name
    }
    $leaf = $parts[-1]
    if ($null -eq $Value) {
        if ($node.PSObject.Properties[$leaf]) { $node.PSObject.Properties.Remove($leaf) }
    } else {
        $node | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value -Force
    }
}

function Get-AfsEffectiveValue {
    <# What is actually in force: the value in the file, or the one the resolver derives. #>
    param($Inputs, $Resolved, $Setting)
    $explicit = Get-AfsInputValue -Inputs $Inputs -Path $Setting.Path
    if ($null -ne $explicit -and "$explicit" -ne '') {
        return [pscustomobject]@{ Value = $explicit; Source = 'set' }
    }
    if ($Setting.ContainsKey('Derived') -and $Resolved) {
        $d = Get-AfsProp $Resolved $Setting.Derived
        if ($null -ne $d) { return [pscustomobject]@{ Value = $d; Source = 'derived' } }
    }
    return [pscustomobject]@{ Value = $null; Source = 'not set' }
}

function Save-AfsOnPremisesAnswers {
    <# Remember what was just answered, so the next run offers it instead of asking cold.
       Best effort by design: this is a convenience, and failing to record it must never stop
       the work that was actually asked for. #>
    param([string]$FileServer, [hashtable]$ServerPaths, [string]$DnsServers, [string]$InputsPath)
    if (-not $InputsPath) { $InputsPath = Join-Path $PSScriptRoot 'inputs.json' }
    if (-not (Test-Path $InputsPath)) { return }
    try {
        $inputs = Read-AfsJsonc -Path $InputsPath
        if ($FileServer) { Set-AfsInputValue -Inputs $inputs -Path 'onPremises.fileServer' -Value $FileServer }
        if ($DnsServers) { Set-AfsInputValue -Inputs $inputs -Path 'onPremises.dnsServers' -Value $DnsServers }
        if ($ServerPaths -and $ServerPaths.Count) {
            foreach ($k in $ServerPaths.Keys) {
                Set-AfsInputValue -Inputs $inputs -Path ('onPremises.serverPaths.' + $k) -Value $ServerPaths[$k]
            }
        }
        Save-AfsInputs -Inputs $inputs -Path $InputsPath
    } catch { }
}

function Save-AfsInputs {
    param($Inputs, [Parameter(Mandatory)][string]$Path)
    $json = $Inputs | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}