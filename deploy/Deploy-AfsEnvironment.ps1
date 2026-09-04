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

.PARAMETER Context
  The deployment context written by Phase1-New-DeploymentIdentity.ps1. Phase 2 signs in as the
  identity it names and runs unattended.

.PARAMETER InputFile
  Alternatively, the four operator inputs. Uses whatever session you already have.

.PARAMETER ShowResolved
  Print what the four inputs expand into, then stop. Changes nothing.

.PARAMETER WhatIf
  Print what would be created and run every read-only precondition, without changing
  anything. Run this first, always.

.PARAMETER SkipPreflight
  Skip the precondition checks. Not recommended - preflight is what turns a confusing
  half-built deployment into a clear message before anything is created.

.EXAMPLE
  .\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json -WhatIf
  .\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json
  .\Deploy-AfsEnvironment.ps1 -InputFile .\inputs.json -ShowResolved

.NOTES
  Requires the Azure CLI (az) and, for the DNS resolver, the dns-resolver extension:
      az extension add --name dns-resolver
  The script installs it for you if it is missing.

  On Windows, run this from PowerShell rather than Git Bash. Git Bash rewrites arguments
  that begin with "/" into Windows paths, which corrupts Azure resource IDs. If you must
  use Git Bash, set MSYS_NO_PATHCONV=1 first.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Context')]
param(
    # PHASE 2, unattended: the context phase 1 wrote. Signs in as the deployment identity.
    [Parameter(Mandatory, ParameterSetName = 'Context')][string]$Context,

    # Or run against the four inputs directly, using whatever session you already have.
    [Parameter(Mandatory, ParameterSetName = 'Inputs')][string]$InputFile,

    # Print what the four inputs expand into, then stop. Changes nothing, calls nothing.
    [switch]$ShowResolved,

    [switch]$SkipPreflight
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AfsConfig.ps1')
. (Join-Path $PSScriptRoot 'AfsLog.ps1')
if (-not $env:AFS_LOG_FILE) { Start-AfsLog -Level Verbose -Name 'deploy' | Out-Null }
Write-Host ('  log: ' + $env:AFS_LOG_FILE) -ForegroundColor DarkGray

# ---------------------------------------------------------------- helpers ----

$script:Created = New-Object System.Collections.ArrayList
$script:Verifications = New-Object System.Collections.ArrayList
$script:StepNo = 0

$script:StepTotal = 17
$script:ProgressActivity = 'Azure File Sync deployment'
function Write-Step {
    param([string]$Text)
    Write-AfsStepTimer -Label $Text
    $script:StepNo++
    Write-AfsLog -Level STEP -Message ('[' + $script:StepNo + '] ' + $Text)
    Write-Host ''
    Write-AfsPhaseStrip -Done ($script:StepNo - 1) -Total $script:StepTotal
    Write-Host ("[{0}/{1}] {2}" -f $script:StepNo, $script:StepTotal, $Text) -ForegroundColor Cyan
    Write-AfsProgress -Activity $script:ProgressActivity -Status $Text -Step $script:StepNo -Total $script:StepTotal
}

function Write-Ok   { param([string]$T) Write-AfsLog -Level INFO -Message ("ok: " + $T); Write-Host ("      OK    " + $T) -ForegroundColor Green }
function Write-Info { param([string]$T) Write-Host ("      ..    " + $T) -ForegroundColor DarkGray }
function Write-Warn2 { param([string]$T) Write-AfsLog -Level WARN -Message $T; Write-Host ("      WARN  " + $T) -ForegroundColor Yellow }

function Invoke-Az {
    # every CLI call goes through the shared logger so the run is fully recorded
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFailure)
    if ($AllowFailure) { return Invoke-AfsAz -Args $Args -AllowFailure }
    return Invoke-AfsAz -Args $Args
}


function ConvertTo-Array {
    <#  @(Invoke-Az ...) does NOT flatten: a function that returns an Object[] is emitted
        as a single item, so the array subexpression yields one element containing the
        array. That silently turned a 2-resource inventory into "1 resource". Normalise
        here instead: null becomes empty, a scalar becomes one element, an array stays. #>
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

# Two ways in. Either way the configuration is produced by the same resolver, so the two
# phases can never disagree about what is being built.
$ctx = $null
if ($PSCmdlet.ParameterSetName -eq 'Context') {
    $ctx = Read-AfsJsonc -Path $Context
    if ($ctx.schema -ne 'afs-deployment-context/1') {
        throw "Unexpected context schema '$($ctx.schema)'. Regenerate it with Phase1-New-DeploymentIdentity.ps1."
    }
    $cfg = $ctx.config
    Write-Host ("  context      : {0}" -f $Context)
    Write-Host ("  identity     : {0} ({1})" -f $ctx.identity.displayName, $ctx.identity.appId)
} else {
    $cfg = Resolve-AfsConfig -Inputs (Read-AfsJsonc -Path $InputFile)
    Write-Host ("  inputs       : {0}" -f $InputFile)
}

if ($ShowResolved) {
    Show-AfsConfig -Config $cfg
    Write-Host 'Nothing was changed and nothing was called. Remove -ShowResolved to continue.' -ForegroundColor Yellow
    return
}

$SubscriptionId = $cfg.subscriptionId
$env:AFS_SUBSCRIPTION_ID = $SubscriptionId   # every az call is pinned to it (see Invoke-AfsAz)
$Location       = $cfg.location
$ResourceGroup  = $cfg.resourceGroup
$SaName         = $cfg.storageAccountName
$SaSku          = $cfg.storageSku
$SssName        = $cfg.storageSyncServiceName
$SyncGroup      = $cfg.syncGroupName
$Shares         = @($cfg.shares)

# The rest of the script reads these grouped objects, so build them from the resolved config
# rather than threading a dozen variables through every step.
$Net = [pscustomobject]@{
    createVNet                  = $cfg.createVNet
    vnetName                    = $cfg.vnetName
    vnetAddressPrefix           = $cfg.vnetAddressPrefix
    privateEndpointSubnetName   = $cfg.peSubnetName
    privateEndpointSubnetPrefix = $cfg.peSubnetPrefix
    existingVNetResourceGroup   = $cfg.vnetResourceGroup
    existingVNetName            = $cfg.vnetName
    existingSubnetName          = $cfg.peSubnetName
}
$Pl = [pscustomobject]@{
    enableStorageFilePrivateEndpoint     = $true
    enableFileSyncPrivateEndpoint        = $true
    createPrivateDnsZones                = $true
    disableStoragePublicAccess           = $false
    restrictFileSyncToVirtualNetworksOnly = $false
}
$Dns = [pscustomobject]@{
    enabled             = $cfg.deployDnsResolver
    name                = $cfg.dnsResolverName
    inboundSubnetName   = $cfg.inboundSubnetName
    inboundSubnetPrefix = $cfg.inboundSubnetPrefix
    createOutboundEndpoint = $false
}
$Backup = [pscustomobject]@{
    enabled                  = $cfg.deployBackup
    vaultName                = $cfg.vaultName
    storageRedundancy        = $cfg.storageRedundancy
    enableCrossRegionRestore = $cfg.crossRegionRestore
    policyName               = $cfg.backupPolicyName
    dailyRetentionDays       = $cfg.backupRetentionDays
}
$TagArgs = @('purpose=azure-file-sync', "prefix=$($cfg.namePrefix)")

if ($SaName -notmatch '^[a-z0-9]{3,24}$') {
    throw "Derived storage account name '$SaName' is invalid: 3-24 lowercase letters and digits. Shorten azure.namePrefix."
}

Write-Host ("  subscription : {0}" -f $SubscriptionId)
Write-Host ("  location     : {0}" -f $Location)
Write-Host ("  group        : {0}" -f $ResourceGroup)
Write-Host ("  storage      : {0} ({1})" -f $SaName, $SaSku)
Write-Host ("  shares       : {0}" -f (($Shares | ForEach-Object { $_.name }) -join ', '))
if ($WhatIfPreference) { Write-Host '  MODE         : WHAT-IF (nothing will be changed)' -ForegroundColor Yellow }

# ------------------------------------------------------- unattended sign-in --
# Phase 2 signs in as the identity phase 1 created, so it needs no human and no MFA.
if ($ctx) {
    Write-Host ''
    Write-Host '[0] Which identity runs this' -ForegroundColor Cyan
    # If a session already exists and can reach the resource group - the wizard's, or a
    # pipeline's federated one - use it and leave it alone. Only sign in as the deployment
    # identity when nothing else is signed in; that is the genuinely unattended case, and
    # "az login --service-principal" would otherwise replace the operator's own session.
    $who = $null
    $probe = Invoke-Az @('account', 'show', '--query', 'user.name', '-o', 'tsv') -AllowFailure
    if ($probe) {
        $canRead = Invoke-Az @('group', 'show', '-n', $ResourceGroup, '--subscription', $SubscriptionId, '--query', 'name', '-o', 'tsv') -AllowFailure
        if ($canRead) { $who = $probe }
    }
    if ($who) {
        Write-Host ("      OK    using the current session: " + $who) -ForegroundColor Green
        Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) -AllowFailure | Out-Null
    } else {
        $secretPath = $null
        if ($ctx.identity.secretFile) { $secretPath = Join-Path (Split-Path -Parent (Resolve-Path $Context)) $ctx.identity.secretFile }
        if ($secretPath -and (Test-Path $secretPath)) {
            $sec = Get-Content $secretPath -Raw | ConvertFrom-Json
            Write-Host ("      ..    no usable session - signing in as the deployment identity " + $sec.appId) -ForegroundColor DarkGray
            if (-not $WhatIfPreference) {
                $t = Test-AfsServicePrincipal -TenantId $sec.tenantId -AppId $sec.appId -Secret $sec.password -Scope ("/subscriptions/" + $SubscriptionId + "/resourceGroups/" + $ResourceGroup) -MaxAttempts 6
                if (-not $t.Ok) { throw ('The deployment identity cannot sign in yet: ' + $t.Detail + '. Wait a minute and try again, or re-run phase 1.') }
                Invoke-Az @('login', '--service-principal', '-u', $sec.appId, '-p', $sec.password, '--tenant', $sec.tenantId, '--only-show-errors', '-o', 'none') | Out-Null
                Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) -AllowFailure | Out-Null
                Write-Host '      OK    signed in unattended' -ForegroundColor Green
            } else {
                Write-Host '      ..    what-if: would sign in as the deployment identity' -ForegroundColor DarkGray
            }
        } else {
            throw 'No signed-in session and no deployment secret file. Run az login, or re-run phase 1.'
        }
    }
}

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

    # Resource providers. A subscription that has never used a service has its provider
    # unregistered, and the first create fails with MissingSubscriptionRegistration - which is
    # how the first live build of this kit stopped at the Storage Sync Service. Every namespace
    # this build touches is checked here and registered if needed; registration is idempotent
    # and usually completes within a minute or two.
    $providers = @(
        @{ ns = 'Microsoft.Storage';          why = 'storage account and file shares' },
        @{ ns = 'Microsoft.Network';          why = 'virtual network, private endpoints, private DNS zones, DNS Private Resolver' },
        @{ ns = 'Microsoft.StorageSync';      why = 'Storage Sync Service (Azure File Sync)' },
        @{ ns = 'Microsoft.RecoveryServices'; why = 'Recovery Services vault and Azure Backup' },
        @{ ns = 'Microsoft.Insights';         why = 'diagnostic settings and metric alerts' }
    )
    $pending = @()
    foreach ($pr in $providers) {
        $state = Invoke-Az @('provider', 'show', '-n', $pr.ns, '--query', 'registrationState', '-o', 'tsv') -AllowFailure
        if ($state -eq 'Registered') {
            Write-Ok ("provider " + $pr.ns + " registered")
        } else {
            Write-Info ("provider " + $pr.ns + " is " + $(if ($state) { $state } else { 'unknown' }) + " - needed for " + $pr.why)
            if (Test-Change $pr.ns 'register resource provider') {
                Invoke-Az @('provider', 'register', '-n', $pr.ns, '-o', 'none') -AllowFailure | Out-Null
                $pending += $pr.ns
            }
        }
    }
    if ($pending.Count) {
        Write-Info ("waiting for registration: " + ($pending -join ', ') + " (usually 1-3 minutes)")
        $deadline = (Get-Date).AddMinutes(10)
        while ($pending.Count -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $still = @()
            foreach ($ns in $pending) {
                $st = Invoke-Az @('provider', 'show', '-n', $ns, '--query', 'registrationState', '-o', 'tsv') -AllowFailure
                if ($st -eq 'Registered') { Write-Ok ("provider " + $ns + " registered") } else { $still += $ns }
            }
            $pending = $still
        }
        if ($pending.Count) { throw ("These resource providers did not finish registering in 10 minutes: " + ($pending -join ', ') + ". Check 'az provider show -n <namespace>' and run again.") }
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
        # 'dns-zone-group show' answers {} with exit code 0 when nothing is attached, so an
        # exit-code test passes and the A records are never written - the endpoint then only
        # resolves publicly (first live build: both zones held nothing but their SOA). Test for
        # an actual zone config instead.
        $zg = Invoke-Az @('network', 'private-endpoint', 'dns-zone-group', 'show', '-g', $ResourceGroup, '--endpoint-name', $Name, '-n', 'default', '-o', 'json') -AllowFailure
        $attached = [bool]($zg -and $zg.PSObject.Properties['privateDnsZoneConfigs'] -and @($zg.privateDnsZoneConfigs).Count -gt 0)
        if ($attached) { Write-Ok "$Name dns zone group already attached" }
        else {
            Invoke-Az @('network', 'private-endpoint', 'dns-zone-group', 'create', '-g', $ResourceGroup,
                '--endpoint-name', $Name, '-n', 'default',
                '--private-dns-zone', $Zone, '--zone-name', $GroupId, '-o', 'none') | Out-Null
            Write-Ok "$Name dns zone group attached"
        }
    }
    Add-Verification "$Name resolves to a private IP" "az network private-endpoint show -n $Name -g $ResourceGroup --query 'customDnsConfigs[0].ipAddresses[0]' -o tsv"
    Add-Verification "$Zone holds the A record(s) for $Name" "az network private-dns record-set a list -g $ResourceGroup -z $Zone --query '[].{name:name,ip:aRecords[0].ipv4Address}' -o table"
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
    # JSON list, counted here: 'length(@)' in --query is re-parsed by the az.cmd wrapper on
    # Windows ("-o was unexpected"), which made this read fail silently and report zero items
    $items = ConvertTo-Array (Invoke-Az @('backup', 'item', 'list', '-v', $VaultName, '-g', $ResourceGroup, '--query', '[].name', '-o', 'json') -AllowFailure)
    if ($items.Count -gt 0) {
        Write-Warn2 "vault already protects $($items.Count) item(s) - redundancy can no longer be changed"
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
    Add-Verification 'protected items' "az backup item list -v $VaultName -g $ResourceGroup --query '[].properties.friendlyName' -o tsv"

    # ---- backup policy. Azure Files backup in a Recovery Services vault is snapshot-based:
    # one daily snapshot, kept N days, item-level restore. The JSON is the shape that
    # 'az backup policy show' returns, written to a temp file because the CLI reads the
    # policy from a path.
    $PolicyName    = Get-Prop $Backup 'policyName' 'afs-daily-60d'
    $RetentionDays = [int](Get-Prop $Backup 'dailyRetentionDays' 60)
    Write-Step "Backup policy $PolicyName (daily snapshot, $RetentionDays days)"
    $pol = Invoke-Az @('backup', 'policy', 'show', '-v', $VaultName, '-g', $ResourceGroup, '-n', $PolicyName, '-o', 'json') -AllowFailure
    if ($pol) { Write-Ok 'already exists' }
    elseif (Test-Change $PolicyName 'create backup policy') {
        $policy = [ordered]@{
            properties = [ordered]@{
                backupManagementType = 'AzureStorage'
                workloadType         = 'AzureFileShare'
                schedulePolicy       = [ordered]@{
                    schedulePolicyType   = 'SimpleSchedulePolicy'
                    scheduleRunFrequency = 'Daily'
                    scheduleRunTimes     = @('2026-01-01T02:00:00Z')
                }
                retentionPolicy      = [ordered]@{
                    retentionPolicyType = 'LongTermRetentionPolicy'
                    dailySchedule       = [ordered]@{
                        retentionTimes    = @('2026-01-01T02:00:00Z')
                        retentionDuration = [ordered]@{ count = $RetentionDays; durationType = 'Days' }
                    }
                }
                timeZone             = 'UTC'
            }
        }
        $policyFile = Join-Path ([IO.Path]::GetTempPath()) ('afs-policy-' + $PolicyName + '.json')
        [System.IO.File]::WriteAllText($policyFile, ($policy | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        try {
            Invoke-Az @('backup', 'policy', 'create', '-v', $VaultName, '-g', $ResourceGroup, '-n', $PolicyName,
                '--backup-management-type', 'AzureStorage', '--workload-type', 'AzureFileShare',
                '--policy', $policyFile, '-o', 'none') | Out-Null
        } finally { Remove-Item $policyFile -ErrorAction SilentlyContinue }
        Add-Created 'backupPolicy' $PolicyName
        Write-Ok "created ($RetentionDays day daily retention)"
    }
    Add-Verification 'backup policy retention days' "az backup policy show -v $VaultName -g $ResourceGroup -n $PolicyName --query 'properties.retentionPolicy.dailySchedule.retentionDuration.count' -o tsv"

    # ---- protect every share. The first protected item registers the storage account with
    # the vault and freezes the vault redundancy - which is why redundancy was set first.
    # Needs 'Allow storage account key access' on the account (kept on by this build).
    Write-Step 'Protect the file shares'
    # one plain list, counted here: a JMESPath filter with brackets, parentheses and '=='
    # is re-parsed by the az.cmd wrapper on Windows ("-o was unexpected at this time")
    # JSON, not tsv: a multi-line tsv answer comes back from Invoke-Az as ONE string, so a
    # two-share list never matched either name and both shares were "protected" twice
    $protected = ConvertTo-Array (Invoke-Az @('backup', 'item', 'list', '-v', $VaultName, '-g', $ResourceGroup,
        '--backup-management-type', 'AzureStorage', '--workload-type', 'AzureFileShare',
        '--query', '[].properties.friendlyName', '-o', 'json') -AllowFailure)
    foreach ($s in $Shares) {
        $sn = $s.name
        if ($protected -contains $sn) { Write-Ok "$sn already protected" }
        elseif (Test-Change $sn 'enable backup protection') {
            Invoke-Az @('backup', 'protection', 'enable-for-azurefileshare', '-v', $VaultName, '-g', $ResourceGroup,
                '--policy-name', $PolicyName, '--storage-account', $SaName, '--azure-file-share', $sn, '-o', 'none') | Out-Null
            Add-Created 'protectedShare' $sn
            Write-Ok "$sn protected by $PolicyName"
        }
    }
    Add-Verification 'protected shares' "az backup item list -v $VaultName -g $ResourceGroup --backup-management-type AzureStorage --query '[].{share:properties.friendlyName,state:properties.protectionState,policy:properties.policyName}' -o table"
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

Complete-AfsProgress -Activity $script:ProgressActivity
Write-AfsRunSummary -Outcome $(if ($WhatIfPreference) { 'what-if' } else { 'deployed' })
Write-Host ''
Write-AfsPhaseStrip -Done $script:StepTotal -Total $script:StepTotal
Write-Host '======================================' -ForegroundColor White
if ($WhatIfPreference) {
    Write-Host 'WHAT-IF complete. Nothing was changed.' -ForegroundColor Yellow
} else {
    Write-Host ("Deployment complete. {0} object(s) created this run." -f $script:Created.Count) -ForegroundColor Green
    if ($script:Created.Count) {
        $script:Created | Format-Table -AutoSize | Out-String | Write-Host
    }
    # the as-built is generated from what actually exists now, not from what was intended
    if ($ctx) {
        Write-Host ''
        Write-Host 'Generating the as-built from the live estate' -ForegroundColor Cyan
        try {
            $ab = & (Join-Path $PSScriptRoot 'Export-AfsAsBuilt.ps1') -Context $Context
            if ($ab) { Add-Verification 'as-built document' ("Get-Content '" + $ab.Markdown + "'") }
        } catch {
            Write-Warn2 ('as-built not generated: ' + $_.Exception.Message)
            Write-Warn2 ('generate it later with: .\Export-AfsAsBuilt.ps1 -Context ' + $Context)
        }
    } else {
        Write-Host ''
        Write-Host 'Tip: run phase 2 with -Context to have the as-built generated automatically.' -ForegroundColor DarkGray
    }
}

Write-Host 'Verify with:' -ForegroundColor White
foreach ($v in $script:Verifications) {
    Write-Host ("  # " + $v.What) -ForegroundColor DarkGray
    Write-Host ("  " + $v.Command)
}

Write-Host ''
Write-Host 'Three steps remain, each on a machine of yours rather than in Azure.' -ForegroundColor White
Write-Host 'There is a script for each, under onprem\ - or use option 7 in start.ps1:'
Write-Host ''
Write-Host '  1. Install the Azure File Sync agent, register the server, and sync a folder:'
Write-Host ("     .\onprem\Install-AfsServerEndpoint.ps1 -Context " + $Context + " -FileServer <server> -SharePath '<share>=<path>'")
Write-Host '  2. Point on-premises DNS at the resolver. Forward the PUBLIC zones -'
Write-Host '     file.core.windows.net and afs.azure.net - not the privatelink ones, which'
Write-Host '     are never consulted. The script proves the resolver answers privately first:'
Write-Host ("     .\onprem\Set-AfsDnsForwarders.ps1 -Context " + $Context + " -DnsServer <dns servers>")
Write-Host '  3. Domain-join the storage account for AD DS authentication:'
Write-Host ("     .\onprem\Join-AfsStorageAccountToAdDs.ps1 -Context " + $Context + " -OrganizationalUnit '<OU DN>'")
Write-Host ''
$removeArg = if ($PSCmdlet.ParameterSetName -eq 'Context') { "-Context $Context" } else { "-InputFile $InputFile" }
Write-Host ('Remove everything with: .\Remove-AfsEnvironment.ps1 ' + $removeArg)
Write-Host ''
