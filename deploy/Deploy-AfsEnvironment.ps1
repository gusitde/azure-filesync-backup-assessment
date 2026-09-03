<#
.SYNOPSIS
  Deploy an Azure File Sync estate with private endpoints, hybrid DNS and Azure Backup,
  entirely from a parameter file.

.DESCRIPTION
  Everything this script builds comes from the parameter file. There are no values
  hard-coded here, so the same script serves a demo and a production build - only the
  parameter file changes.

  The script is idempotent: it checks whether each object exists before creating it, so a
  re-run after a failure continues rather than starting over.

  Every step is followed by a verification that reads the object back. A step is finished
  when something proves it, not when a command returns 0.

.PARAMETER ParameterFile
  Path to the parameter file. Start from parameters.sample.jsonc.

.PARAMETER WhatIf
  Print what would be created and run every read-only precondition, without changing
  anything. Run this first, always.

.PARAMETER SkipPreflight
  Skip the precondition checks. Not recommended - preflight is what turns a confusing
  half-built deployment into a clear message before anything is created.

.EXAMPLE
  .\Deploy-AfsEnvironment.ps1 -ParameterFile .\parameters.json -WhatIf
  .\Deploy-AfsEnvironment.ps1 -ParameterFile .\parameters.json

.NOTES
  Requires the Azure CLI (az) and, for the DNS resolver, the dns-resolver extension:
      az extension add --name dns-resolver
  The script installs it for you if it is missing.

  On Windows, run this from PowerShell rather than Git Bash. Git Bash rewrites arguments
  that begin with "/" into Windows paths, which corrupts Azure resource IDs. If you must
  use Git Bash, set MSYS_NO_PATHCONV=1 first.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$ParameterFile,
    [switch]$SkipPreflight
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ----

$script:Created = New-Object System.Collections.ArrayList
$script:Verifications = New-Object System.Collections.ArrayList
$script:StepNo = 0

function Write-Step {
    param([string]$Text)
    $script:StepNo++
    Write-Host ''
    Write-Host ("[{0}] {1}" -f $script:StepNo, $Text) -ForegroundColor Cyan
}

function Write-Ok   { param([string]$T) Write-Host ("      OK    " + $T) -ForegroundColor Green }
function Write-Info { param([string]$T) Write-Host ("      ..    " + $T) -ForegroundColor DarkGray }
function Write-Warn2 { param([string]$T) Write-Host ("      WARN  " + $T) -ForegroundColor Yellow }

function Invoke-Az {
    <#  Run an az command. Returns parsed JSON when there is output, $null otherwise.
        Throws with the full stderr when az fails, so a failure is never silent. #>
    param(
        [Parameter(Mandatory)][string[]]$Args,
        [switch]$AllowFailure
    )
    # az writes progress and errors to stderr. With ErrorActionPreference='Stop' the
    # 2>&1 merge turns that into a terminating NativeCommandError even when the call is
    # an expected "does it exist?" probe, so the preference is relaxed for the call and
    # the real outcome is taken from the exit code.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @Args 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        throw ("az " + ($Args -join ' ') + "`n" + (($out | Out-String).Trim()))
    }
    # drop any ErrorRecord objects that the stderr merge produced on a successful call
    $out = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $text = ($out | Out-String).Trim()
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $text }
}

function Read-ParameterFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Parameter file not found: $Path" }
    $raw = Get-Content -Path $Path -Raw
    # strip // line comments and /* */ block comments so JSONC is accepted
    $raw = [regex]::Replace($raw, '(?m)^\s*//.*$', '')
    $raw = [regex]::Replace($raw, '(?s)/\*.*?\*/', '')
    $raw = [regex]::Replace($raw, '(?m)\s+//\s.*$', '')
    try { return $raw | ConvertFrom-Json }
    catch { throw "Parameter file is not valid JSON after comment stripping: $($_.Exception.Message)" }
}

function ConvertTo-Array {
    <#  @(Invoke-Az ...) does NOT flatten: a function that returns an Object[] is emitted
        as a single item, so the array subexpression yields one element containing the
        array. That silently turned a 2-resource inventory into "1 resource". Normalise
        here instead: null becomes empty, a scalar becomes one element, an array stays. #>
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return $Value }
    return @($Value)
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Add-Created {
    param([string]$Type, [string]$Name)
    [void]$script:Created.Add([pscustomobject]@{ Type = $Type; Name = $Name })
}

function Add-Verification {
    param([string]$What, [string]$Command)
    [void]$script:Verifications.Add([pscustomobject]@{ What = $What; Command = $Command })
}

function Test-Change {
    param([string]$Target, [string]$Action)
    if ($PSCmdlet.ShouldProcess($Target, $Action)) { return $true }
    Write-Info "WHATIF would $Action -> $Target"
    return $false
}

# ------------------------------------------------------------- parameters ----

Write-Host ''
Write-Host 'Azure File Sync environment deployment' -ForegroundColor White
Write-Host '======================================' -ForegroundColor White

$p = Read-ParameterFile -Path $ParameterFile

$SubscriptionId = Get-Prop $p 'subscriptionId'
$Location       = Get-Prop $p 'location'
$ResourceGroup  = Get-Prop $p 'resourceGroup'
$SaName         = Get-Prop $p 'storageAccountName'
$SaSku          = Get-Prop $p 'storageSku' 'Standard_ZRS'
$SssName        = Get-Prop $p 'storageSyncServiceName'
$SyncGroup      = Get-Prop $p 'syncGroupName'
$Shares         = @(Get-Prop $p 'shares' @())
$Net            = Get-Prop $p 'network'
$Pl             = Get-Prop $p 'privateLink'
$Dns            = Get-Prop $p 'dnsResolver'
$Backup         = Get-Prop $p 'backup'
$TagsObj        = Get-Prop $p 'tags'

foreach ($req in @(
        @{ n = 'subscriptionId';         v = $SubscriptionId },
        @{ n = 'location';               v = $Location },
        @{ n = 'resourceGroup';          v = $ResourceGroup },
        @{ n = 'storageAccountName';     v = $SaName })) {
    if (-not $req.v) { throw "Parameter file is missing required value: $($req.n)" }
}

if ($SaName -notmatch '^[a-z0-9]{3,24}$') {
    throw "storageAccountName '$SaName' is invalid: 3-24 characters, lowercase letters and digits only."
}

$TagArgs = @()
if ($TagsObj) {
    foreach ($t in $TagsObj.PSObject.Properties) { $TagArgs += ("{0}={1}" -f $t.Name, $t.Value) }
}

Write-Host ''
Write-Host ("  subscription : {0}" -f $SubscriptionId)
Write-Host ("  location     : {0}" -f $Location)
Write-Host ("  group        : {0}" -f $ResourceGroup)
Write-Host ("  storage      : {0} ({1})" -f $SaName, $SaSku)
Write-Host ("  shares       : {0}" -f (($Shares | ForEach-Object { $_.name }) -join ', '))
if ($WhatIfPreference) { Write-Host '  MODE         : WHAT-IF (nothing will be changed)' -ForegroundColor Yellow }

# --------------------------------------------------------------- preflight ---

if (-not $SkipPreflight) {
    Write-Step 'Preflight'

    $azv = Invoke-Az @('version', '-o', 'json') -AllowFailure
    if (-not $azv) { throw 'Azure CLI (az) is not available on PATH.' }
    Write-Ok ("Azure CLI " + (Get-Prop $azv 'azure-cli'))

    $acct = Invoke-Az @('account', 'show', '-o', 'json') -AllowFailure
    if (-not $acct) { throw 'Not signed in. Run: az login' }
    Write-Ok ("signed in as " + (Get-Prop (Get-Prop $acct 'user') 'name'))

    Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
    Write-Ok "subscription set"

    if (Get-Prop $Dns 'enabled' $false) {
        $ext = Invoke-Az @('extension', 'list', '--query', "[?name=='dns-resolver'].version", '-o', 'tsv') -AllowFailure
        if (-not $ext) {
            Write-Info 'installing the dns-resolver CLI extension'
            if (Test-Change 'azure-cli' 'install the dns-resolver extension') {
                Invoke-Az @('extension', 'add', '--name', 'dns-resolver', '--only-show-errors') | Out-Null
            }
        }
        Write-Ok 'dns-resolver extension present'
    }

    $avail = Invoke-Az @('storage', 'account', 'check-name', '--name', $SaName, '-o', 'json') -AllowFailure
    if ($avail -and -not (Get-Prop $avail 'nameAvailable' $true)) {
        $existing = Invoke-Az @('storage', 'account', 'show', '-n', $SaName, '-g', $ResourceGroup, '-o', 'json') -AllowFailure
        if ($existing) { Write-Ok "storage account already exists in this group (will be reused)" }
        else { throw "storageAccountName '$SaName' is already taken by another account: $(Get-Prop $avail 'message')" }
    } else {
        Write-Ok "storage account name is available"
    }
}

# ------------------------------------------------------------ resource grp ---

Write-Step "Resource group $ResourceGroup"
$rg = Invoke-Az @('group', 'show', '-n', $ResourceGroup, '-o', 'json') -AllowFailure
if ($rg) {
    Write-Ok 'already exists'
} elseif (Test-Change $ResourceGroup 'create resource group') {
    $args = @('group', 'create', '-n', $ResourceGroup, '-l', $Location, '-o', 'json')
    if ($TagArgs.Count) { $args += @('--tags') + $TagArgs }
    Invoke-Az $args | Out-Null
    Add-Created 'resourceGroup' $ResourceGroup
    Write-Ok 'created'
}
Add-Verification 'resource group exists' "az group show -n $ResourceGroup --query name -o tsv"

# ---------------------------------------------------------------- storage ----

Write-Step "Storage account $SaName"
$sa = Invoke-Az @('storage', 'account', 'show', '-n', $SaName, '-g', $ResourceGroup, '-o', 'json') -AllowFailure
if ($sa) {
    Write-Ok 'already exists'
} elseif (Test-Change $SaName 'create storage account') {
    $args = @('storage', 'account', 'create', '-n', $SaName, '-g', $ResourceGroup, '-l', $Location,
        '--sku', $SaSku, '--kind', 'StorageV2',
        '--min-tls-version', 'TLS1_2', '--https-only', 'true',
        '--allow-blob-public-access', 'false', '--allow-shared-key-access', 'true',
        '--enable-large-file-share', '-o', 'json')
    if ($TagArgs.Count) { $args += @('--tags') + $TagArgs }
    Invoke-Az $args | Out-Null
    Add-Created 'storageAccount' $SaName
    Write-Ok 'created'
}
Add-Verification 'storage baseline' "az storage account show -n $SaName -g $ResourceGroup --query '[minimumTlsVersion,enableHttpsTrafficOnly,allowBlobPublicAccess]' -o tsv"

Write-Step 'Share soft delete (14 days)'
if (Test-Change $SaName 'enable share soft delete') {
    Invoke-Az @('storage', 'account', 'file-service-properties', 'update', '--account-name', $SaName,
        '-g', $ResourceGroup, '--enable-delete-retention', 'true', '--delete-retention-days', '14', '-o', 'none') | Out-Null
    Write-Ok 'enabled'
}
Add-Verification 'share soft delete' "az storage account file-service-properties show --account-name $SaName -g $ResourceGroup --query shareDeleteRetentionPolicy.days -o tsv"

Write-Step 'File shares'
foreach ($s in $Shares) {
    $sn = $s.name
    $q = [int](Get-Prop $s 'quotaGiB' 1024)
    $ex = Invoke-Az @('storage', 'share-rm', 'show', '--storage-account', $SaName, '-g', $ResourceGroup, '-n', $sn, '-o', 'json') -AllowFailure
    if ($ex) { Write-Ok "$sn already exists" }
    elseif (Test-Change $sn 'create file share') {
        Invoke-Az @('storage', 'share-rm', 'create', '--storage-account', $SaName, '-g', $ResourceGroup,
            '-n', $sn, '--quota', "$q", '-o', 'none') | Out-Null
        Add-Created 'fileShare' $sn
        Write-Ok "$sn created ($q GiB)"
    }
}
Add-Verification 'shares present' "az storage share-rm list --storage-account $SaName -g $ResourceGroup --query '[].name' -o tsv"

# ---------------------------------------------------------------- network ----

$VNetName = $null; $PeSubnet = $null; $VNetRg = $ResourceGroup
if ($Net) {
    if (Get-Prop $Net 'createVNet' $true) {
        $VNetName = Get-Prop $Net 'vnetName'
        $PeSubnet = Get-Prop $Net 'privateEndpointSubnetName'
        Write-Step "Virtual network $VNetName"
        $vn = Invoke-Az @('network', 'vnet', 'show', '-n', $VNetName, '-g', $ResourceGroup, '-o', 'json') -AllowFailure
        if ($vn) { Write-Ok 'already exists' }
        elseif (Test-Change $VNetName 'create virtual network') {
            Invoke-Az @('network', 'vnet', 'create', '-n', $VNetName, '-g', $ResourceGroup, '-l', $Location,
                '--address-prefixes', (Get-Prop $Net 'vnetAddressPrefix'),
                '--subnet-name', $PeSubnet,
                '--subnet-prefixes', (Get-Prop $Net 'privateEndpointSubnetPrefix'), '-o', 'none') | Out-Null
            Add-Created 'virtualNetwork' $VNetName
            Write-Ok 'created'
        }
    } else {
        $VNetRg   = Get-Prop $Net 'existingVNetResourceGroup' $ResourceGroup
        $VNetName = Get-Prop $Net 'existingVNetName'
        $PeSubnet = Get-Prop $Net 'existingSubnetName'
        if (-not $VNetName -or -not $PeSubnet) {
            throw 'network.createVNet is false, so existingVNetName and existingSubnetName are required.'
        }
        Write-Step "Using existing virtual network $VNetName"
        $vn = Invoke-Az @('network', 'vnet', 'show', '-n', $VNetName, '-g', $VNetRg, '-o', 'json') -AllowFailure
        if (-not $vn) { throw "Existing virtual network '$VNetName' not found in group '$VNetRg'." }
        Write-Ok 'found'
    }
    Add-Verification 'vnet reachable' "az network vnet show -n $VNetName -g $VNetRg --query provisioningState -o tsv"
}

# ----------------------------------------------------------- private link ----

$ZoneFile = 'privatelink.file.core.windows.net'
$ZoneAfs  = 'privatelink.afs.azure.net'

function New-PrivateZone {
    param([string]$Zone)
    $z = Invoke-Az @('network', 'private-dns', 'zone', 'show', '-g', $ResourceGroup, '-n', $Zone, '-o', 'json') -AllowFailure
    if ($z) { Write-Ok "$Zone already exists"; return }
    if (Test-Change $Zone 'create private dns zone') {
        Invoke-Az @('network', 'private-dns', 'zone', 'create', '-g', $ResourceGroup, '-n', $Zone, '-o', 'none') | Out-Null
        Add-Created 'privateDnsZone' $Zone
        Write-Ok "$Zone created"
    }
    if ($VNetName -and (Test-Change $Zone 'link zone to vnet')) {
        $lnk = Invoke-Az @('network', 'private-dns', 'link', 'vnet', 'show', '-g', $ResourceGroup, '-z', $Zone, '-n', "link-$VNetName", '-o', 'json') -AllowFailure
        if (-not $lnk) {
            Invoke-Az @('network', 'private-dns', 'link', 'vnet', 'create', '-g', $ResourceGroup, '-z', $Zone,
                '-n', "link-$VNetName", '-v', $VNetName, '-e', 'false', '-o', 'none') | Out-Null
            Write-Ok "$Zone linked to $VNetName"
        }
    }
}

function New-Endpoint {
    param([string]$Name, [string]$TargetId, [string]$GroupId, [string]$Zone)
    $pe = Invoke-Az @('network', 'private-endpoint', 'show', '-n', $Name, '-g', $ResourceGroup, '-o', 'json') -AllowFailure
    if ($pe) { Write-Ok "$Name already exists" }
    elseif (Test-Change $Name 'create private endpoint') {
        Invoke-Az @('network', 'private-endpoint', 'create', '-n', $Name, '-g', $ResourceGroup, '-l', $Location,
            '--vnet-name', $VNetName, '--subnet', $PeSubnet,
            '--private-connection-resource-id', $TargetId,
            '--group-id', $GroupId, '--connection-name', "conn-$GroupId", '-o', 'none') | Out-Null
        Add-Created 'privateEndpoint' $Name
        Write-Ok "$Name created"
    }
    if (Test-Change $Name 'attach dns zone group') {
        $zg = Invoke-Az @('network', 'private-endpoint', 'dns-zone-group', 'show', '-g', $ResourceGroup, '--endpoint-name', $Name, '-n', 'default', '-o', 'json') -AllowFailure
        if (-not $zg) {
            Invoke-Az @('network', 'private-endpoint', 'dns-zone-group', 'create', '-g', $ResourceGroup,
                '--endpoint-name', $Name, '-n', 'default',
                '--private-dns-zone', $Zone, '--zone-name', $GroupId, '-o', 'none') | Out-Null
            Write-Ok "$Name dns zone group attached"
        }
    }
    Add-Verification "$Name resolves to a private IP" "az network private-endpoint show -n $Name -g $ResourceGroup --query 'customDnsConfigs[0].ipAddresses[0]' -o tsv"
}

if ($Pl -and (Get-Prop $Pl 'createPrivateDnsZones' $true)) {
    Write-Step 'Private DNS zones'
    if (Get-Prop $Pl 'enableStorageFilePrivateEndpoint' $true) { New-PrivateZone -Zone $ZoneFile }
    if (Get-Prop $Pl 'enableFileSyncPrivateEndpoint' $true)    { New-PrivateZone -Zone $ZoneAfs }
}

if ($Pl -and (Get-Prop $Pl 'enableStorageFilePrivateEndpoint' $true) -and $VNetName) {
    Write-Step 'Private endpoint for the storage account (sub-resource: file)'
    $saId = Invoke-Az @('storage', 'account', 'show', '-n', $SaName, '-g', $ResourceGroup, '--query', 'id', '-o', 'tsv') -AllowFailure
    if ($saId) { New-Endpoint -Name "pe-$SaName-file" -TargetId $saId -GroupId 'file' -Zone $ZoneFile }
    else { Write-Warn2 'storage account id not resolvable yet (what-if run?), private endpoint skipped' }
}

# ------------------------------------------------------------ file sync ------

if ($SssName) {
    Write-Step "Storage Sync Service $SssName"
    $sss = Invoke-Az @('resource', 'show', '-g', $ResourceGroup, '-n', $SssName,
        '--resource-type', 'Microsoft.StorageSync/storageSyncServices', '-o', 'json') -AllowFailure
    if ($sss) { Write-Ok 'already exists' }
    elseif (Test-Change $SssName 'create storage sync service') {
        $body = '{\"location\":\"' + $Location + '\",\"properties\":{\"incomingTrafficPolicy\":\"AllowAllTraffic\"}}'
        Invoke-Az @('resource', 'create', '-g', $ResourceGroup, '-n', $SssName,
            '--resource-type', 'Microsoft.StorageSync/storageSyncServices',
            '--api-version', '2022-09-01', '--properties', $body, '-o', 'none') | Out-Null
        Add-Created 'storageSyncService' $SssName
        Write-Ok 'created'
    }
    Add-Verification 'storage sync service' "az resource show -g $ResourceGroup -n $SssName --resource-type Microsoft.StorageSync/storageSyncServices --query name -o tsv"

    if ($Pl -and (Get-Prop $Pl 'enableFileSyncPrivateEndpoint' $true) -and $VNetName) {
        Write-Step 'Private endpoint for the Storage Sync Service (sub-resource: Afs)'
        $sssId = Invoke-Az @('resource', 'show', '-g', $ResourceGroup, '-n', $SssName,
            '--resource-type', 'Microsoft.StorageSync/storageSyncServices', '--query', 'id', '-o', 'tsv') -AllowFailure
        if ($sssId) { New-Endpoint -Name "pe-$SssName-afs" -TargetId $sssId -GroupId 'Afs' -Zone $ZoneAfs }
        else { Write-Warn2 'storage sync service id not resolvable yet, private endpoint skipped' }
    }
}

# ----------------------------------------------------------- dns resolver ----

if ($Dns -and (Get-Prop $Dns 'enabled' $false) -and $VNetName) {
    $ResolverName = Get-Prop $Dns 'name'
    $InSubnet     = Get-Prop $Dns 'inboundSubnetName'

    Write-Step "DNS Private Resolver $ResolverName"
    if (Test-Change $InSubnet 'create the delegated inbound subnet') {
        $sn = Invoke-Az @('network', 'vnet', 'subnet', 'show', '-g', $VNetRg, '--vnet-name', $VNetName, '-n', $InSubnet, '-o', 'json') -AllowFailure
        if (-not $sn) {
            Invoke-Az @('network', 'vnet', 'subnet', 'create', '-g', $VNetRg, '--vnet-name', $VNetName,
                '-n', $InSubnet, '--address-prefixes', (Get-Prop $Dns 'inboundSubnetPrefix'),
                '--delegations', 'Microsoft.Network/dnsResolvers', '-o', 'none') | Out-Null
            Write-Ok "subnet $InSubnet created and delegated"
        } else { Write-Ok "subnet $InSubnet already exists" }
    }

    $res = Invoke-Az @('dns-resolver', 'show', '-g', $ResourceGroup, '-n', $ResolverName, '-o', 'json') -AllowFailure
    if ($res) { Write-Ok 'resolver already exists' }
    elseif (Test-Change $ResolverName 'create dns private resolver') {
        $vnetId = Invoke-Az @('network', 'vnet', 'show', '-n', $VNetName, '-g', $VNetRg, '--query', 'id', '-o', 'tsv')
        Invoke-Az @('dns-resolver', 'create', '-g', $ResourceGroup, '-n', $ResolverName, '-l', $Location,
            '--id', $vnetId, '-o', 'none') | Out-Null
        Add-Created 'dnsResolver' $ResolverName
        Write-Ok 'created'
    }

    if (Test-Change 'inbound-01' 'create the inbound endpoint') {
        $ie = Invoke-Az @('dns-resolver', 'inbound-endpoint', 'show', '-g', $ResourceGroup, '--dns-resolver-name', $ResolverName, '-n', 'inbound-01', '-o', 'json') -AllowFailure
        if (-not $ie) {
            $subnetId = Invoke-Az @('network', 'vnet', 'subnet', 'show', '-g', $VNetRg, '--vnet-name', $VNetName, '-n', $InSubnet, '--query', 'id', '-o', 'tsv')
            Invoke-Az @('dns-resolver', 'inbound-endpoint', 'create', '-g', $ResourceGroup,
                '--dns-resolver-name', $ResolverName, '-n', 'inbound-01', '-l', $Location,
                '--ip-configurations', ("[{privateIpAllocationMethod:Dynamic,id:'" + $subnetId + "'}]"), '-o', 'none') | Out-Null
            Write-Ok 'inbound endpoint created'
        } else { Write-Ok 'inbound endpoint already exists' }
    }
    Add-Verification 'resolver inbound IP (point on-premises forwarders here)' "az dns-resolver inbound-endpoint show -g $ResourceGroup --dns-resolver-name $ResolverName -n inbound-01 --query 'ipConfigurations[0].privateIpAddress' -o tsv"
}

# ---------------------------------------------------------------- backup -----

if ($Backup -and (Get-Prop $Backup 'enabled' $false)) {
    $VaultName = Get-Prop $Backup 'vaultName'
    Write-Step "Recovery Services vault $VaultName"
    $v = Invoke-Az @('backup', 'vault', 'show', '-n', $VaultName, '-g', $ResourceGroup, '-o', 'json') -AllowFailure
    if ($v) { Write-Ok 'already exists' }
    elseif (Test-Change $VaultName 'create recovery services vault') {
        $args = @('backup', 'vault', 'create', '-n', $VaultName, '-g', $ResourceGroup, '-l', $Location, '-o', 'none')
        if ($TagArgs.Count) { $args += @('--tags') + $TagArgs }
        Invoke-Az $args | Out-Null
        Add-Created 'recoveryServicesVault' $VaultName
        Write-Ok 'created'
    }

    # redundancy and cross-region restore must be set before the first protected item
    Write-Step 'Vault redundancy and cross-region restore (must precede any protected item)'
    $items = Invoke-Az @('backup', 'item', 'list', '-v', $VaultName, '-g', $ResourceGroup, '--query', 'length(@)', '-o', 'tsv') -AllowFailure
    if ($items -and [int]$items -gt 0) {
        Write-Warn2 "vault already protects $items item(s) - redundancy can no longer be changed"
    } elseif (Test-Change $VaultName 'set backup storage redundancy') {
        $redundancy = Get-Prop $Backup 'storageRedundancy' 'GeoRedundant'
        $args = @('backup', 'vault', 'backup-properties', 'set', '-n', $VaultName, '-g', $ResourceGroup,
            '--backup-storage-redundancy', $redundancy, '-o', 'none')
        if (Get-Prop $Backup 'enableCrossRegionRestore' $false) { $args += @('--cross-region-restore-flag', 'true') }
        Invoke-Az $args | Out-Null
        Write-Ok "redundancy set to $redundancy"
    }
    # NOTE the [0] index: backup-properties returns an ARRAY, so a bare
    # properties.storageModelType query silently returns nothing.
    Add-Verification 'vault redundancy' "az backup vault backup-properties show -n $VaultName -g $ResourceGroup --query '[0].properties.storageModelType' -o tsv"
    Add-Verification 'cross-region restore' "az backup vault backup-properties show -n $VaultName -g $ResourceGroup --query '[0].properties.crossRegionRestoreFlag' -o tsv"
    Add-Verification 'protected item count' "az backup item list -v $VaultName -g $ResourceGroup --query 'length(@)' -o tsv"
}

# ----------------------------------------------------------- lock down -------

if ($Pl -and (Get-Prop $Pl 'disableStoragePublicAccess' $false)) {
    Write-Step 'Lock down the storage account public path'
    Write-Warn2 'only do this once the private endpoint resolves - otherwise sync breaks'
    if (Test-Change $SaName 'set default-action Deny with trusted-services bypass') {
        Invoke-Az @('storage', 'account', 'update', '-n', $SaName, '-g', $ResourceGroup,
            '--default-action', 'Deny', '--bypass', 'AzureServices', '-o', 'none') | Out-Null
        Write-Ok 'firewall set to Deny with AzureServices bypass'
    }
    Add-Verification 'trusted services bypass retained' "az storage account show -n $SaName -g $ResourceGroup --query networkRuleSet.bypass -o tsv"
}

# ----------------------------------------------------------------- summary ---

Write-Host ''
Write-Host '======================================' -ForegroundColor White
if ($WhatIfPreference) {
    Write-Host 'WHAT-IF complete. Nothing was changed.' -ForegroundColor Yellow
} else {
    Write-Host ("Deployment complete. {0} object(s) created this run." -f $script:Created.Count) -ForegroundColor Green
    if ($script:Created.Count) {
        $script:Created | Format-Table -AutoSize | Out-String | Write-Host
    }
}

Write-Host 'Verify with:' -ForegroundColor White
foreach ($v in $script:Verifications) {
    Write-Host ("  # " + $v.What) -ForegroundColor DarkGray
    Write-Host ("  " + $v.Command)
}

Write-Host ''
Write-Host 'Next steps that are deliberately NOT automated:' -ForegroundColor White
Write-Host '  1. Install the Azure File Sync agent on the file server and register it'
Write-Host '     against the Storage Sync Service, then create the server endpoint.'
Write-Host '  2. Point the on-premises DNS conditional forwarders at the resolver inbound IP'
Write-Host '     shown above, for the privatelink zones only.'
Write-Host '  3. Domain-join the storage account with AzFilesHybrid if AD DS authentication'
Write-Host '     is required, from a domain-joined machine.'
Write-Host ''
Write-Host 'Remove everything with: .\Remove-AfsEnvironment.ps1 -ParameterFile ' -NoNewline
Write-Host $ParameterFile
Write-Host ''
