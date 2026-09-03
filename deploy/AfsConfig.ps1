<#
  Shared configuration resolver. Dot-sourced by both phases.

  Turns the four inputs the operator supplies into the complete set of names and
  settings the deployment needs, so there is exactly one file to edit and no
  chance of the two phases disagreeing about what is being built.

  Derivation is deterministic: the same inputs always produce the same names, so
  a re-run targets the same objects and the deployment stays idempotent.
#>

Set-StrictMode -Version 2.0

function Get-AfsProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    if ($p.Value -is [string] -and $p.Value -eq '') { return $Default }
    return $p.Value
}

function Read-AfsJsonc {
    <# JSON with comments. Strips // line comments and /* */ blocks, leaving URLs alone
       because the trailing-comment pattern requires whitespace on both sides of the //. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    $raw = Get-Content -Path $Path -Raw
    $raw = [regex]::Replace($raw, '(?m)^\s*//.*$', '')
    $raw = [regex]::Replace($raw, '(?s)/\*.*?\*/', '')
    $raw = [regex]::Replace($raw, '(?m)\s+//\s.*$', '')
    try { return $raw | ConvertFrom-Json }
    catch { throw "Not valid JSON after comment stripping: $($_.Exception.Message)" }
}

function Resolve-AfsConfig {
    <#
      .SYNOPSIS
        Expand the four operator inputs into the full deployment configuration.
      .OUTPUTS
        A flat object every script can consume without re-deriving anything.
    #>
    param([Parameter(Mandatory)]$Inputs)

    # -- the four inputs, validated up front so a bad value fails here and not
    #    part way through a build --------------------------------------------
    $admin  = Get-AfsProp $Inputs 'entraGlobalAdmin'
    $az     = Get-AfsProp $Inputs 'azure'
    $adAdm  = Get-AfsProp $Inputs 'activeDirectoryAdmin'
    $ad     = Get-AfsProp $Inputs 'activeDirectory'
    $ovr    = Get-AfsProp $Inputs 'overrides'

    if (-not $az) { throw 'inputs file is missing the "azure" section.' }

    $sub    = Get-AfsProp $az 'subscriptionId'
    $loc    = Get-AfsProp $az 'location' 'eastus'
    $prefix = (Get-AfsProp $az 'namePrefix' '').ToLower()
    $suffix = (Get-AfsProp $az 'uniqueSuffix' '01').ToLower()

    foreach ($r in @(@{n='azure.subscriptionId';v=$sub}, @{n='azure.namePrefix';v=$prefix})) {
        if (-not $r.v) { throw "inputs file is missing required value: $($r.n)" }
    }
    if ($prefix -notmatch '^[a-z0-9]{2,8}$') {
        throw "azure.namePrefix '$prefix' is invalid: 2-8 lowercase letters or digits. Every resource name derives from it."
    }
    if ($sub -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "azure.subscriptionId '$sub' does not look like a GUID."
    }

    # -- derived names ------------------------------------------------------
    $sa = "st${prefix}fs${suffix}"
    if ($sa.Length -gt 24) { throw "derived storage account name '$sa' is longer than 24 characters. Shorten azure.namePrefix." }

    $cfg = [ordered]@{
        # identity / scope
        tenantId               = Get-AfsProp $admin 'tenantId'
        adminUpn               = Get-AfsProp $admin 'userPrincipalName'
        subscriptionId         = $sub
        location               = $loc
        namePrefix             = $prefix

        # core resources
        resourceGroup          = Get-AfsProp $ovr 'resourceGroup'          "rg-${prefix}-filesync"
        storageAccountName     = Get-AfsProp $ovr 'storageAccountName'     $sa
        storageSku             = Get-AfsProp $ovr 'storageSku'             'Standard_ZRS'
        storageSyncServiceName = Get-AfsProp $ovr 'storageSyncServiceName' "sss-${prefix}-filesync"
        syncGroupName          = Get-AfsProp $ovr 'syncGroupName'          "sg-${prefix}-shares"

        # network
        vnetName               = Get-AfsProp $ovr 'vnetName'               "vnet-${prefix}-filesync"
        vnetAddressPrefix      = Get-AfsProp $ovr 'vnetAddressPrefix'      '10.60.0.0/16'
        peSubnetName           = Get-AfsProp $ovr 'peSubnetName'           'snet-privateendpoints'
        peSubnetPrefix         = Get-AfsProp $ovr 'peSubnetPrefix'         '10.60.1.0/26'

        # dns resolver
        deployDnsResolver      = [bool](Get-AfsProp $ovr 'deployDnsResolver' $true)
        dnsResolverName        = Get-AfsProp $ovr 'dnsResolverName'        "dnspr-${prefix}-${loc}"
        inboundSubnetName      = Get-AfsProp $ovr 'inboundSubnetName'      'snet-dnsresolver-inbound'
        inboundSubnetPrefix    = Get-AfsProp $ovr 'inboundSubnetPrefix'    '10.60.2.0/28'

        # backup
        deployBackup           = [bool](Get-AfsProp $ovr 'deployBackup' $true)
        vaultName              = Get-AfsProp $ovr 'vaultName'              "rsv-${prefix}-${loc}"
        storageRedundancy      = Get-AfsProp $ovr 'backupStorageRedundancy' 'GeoRedundant'
        crossRegionRestore     = [bool](Get-AfsProp $ovr 'enableCrossRegionRestore' $true)
        backupRetentionDays    = [int](Get-AfsProp $ovr 'backupDailyRetentionDays' 60)

        # identity / ad ds
        enableAdDsJoin         = [bool](Get-AfsProp $ovr 'enableAdDsJoin' $true)
        adDomainFqdn           = Get-AfsProp $ad 'domainFqdn'
        adNetBiosName          = Get-AfsProp $ad 'netBiosName'
        adOuDn                 = Get-AfsProp $ad 'organizationalUnitDistinguishedName'
        adIdentityObjectType   = Get-AfsProp $ad 'identityObjectType' 'ComputerAccount'
        adDomainControllerHint = Get-AfsProp $ad 'domainControllerOrSite' ''
        adAdminUpn             = Get-AfsProp $adAdm 'userPrincipalName'
        adPasswordSource       = Get-AfsProp $adAdm 'passwordSource' 'prompt'

        # fixed by the platform, not the operator
        zoneFile               = 'privatelink.file.core.windows.net'
        zoneAfs                = 'privatelink.afs.azure.net'
    }

    # backup policy name reflects the retention, so it is self-describing in the portal
    $cfg['backupPolicyName'] = Get-AfsProp $ovr 'backupPolicyName' ("afs-daily-$($cfg.backupRetentionDays)d")

    # shares
    $shares = Get-AfsProp $ovr 'shares'
    if (-not $shares) {
        $shares = @(
            [pscustomobject]@{ name = 'dept-shares'; quotaGiB = 1024 },
            [pscustomobject]@{ name = 'home-drives'; quotaGiB = 2048 }
        )
    }
    $cfg['shares'] = @($shares)

    # existing network instead of a new one
    $ex = Get-AfsProp $ovr 'existingVNet'
    if ($ex) {
        $cfg['createVNet']    = $false
        $cfg['vnetResourceGroup'] = Get-AfsProp $ex 'resourceGroup' $cfg.resourceGroup
        $cfg['vnetName']      = Get-AfsProp $ex 'name'
        $cfg['peSubnetName']  = Get-AfsProp $ex 'subnet'
        if (-not $cfg.vnetName -or -not $cfg.peSubnetName) {
            throw 'overrides.existingVNet needs both "name" and "subnet".'
        }
    } else {
        $cfg['createVNet']        = $true
        $cfg['vnetResourceGroup'] = $cfg.resourceGroup
    }

    # AD DS join needs all four AD values, or it is not attempted
    if ($cfg.enableAdDsJoin) {
        $missing = @()
        foreach ($k in @('adDomainFqdn','adNetBiosName','adOuDn','adAdminUpn')) {
            if (-not $cfg[$k]) { $missing += $k }
        }
        if ($missing.Count) {
            $cfg['enableAdDsJoin'] = $false
            $cfg['adDsSkipReason'] = "missing: $($missing -join ', ')"
        }
    }

    return [pscustomobject]$cfg
}

function Show-AfsConfig {
    param([Parameter(Mandatory)]$Config)
    Write-Host ''
    Write-Host 'Resolved configuration' -ForegroundColor White
    Write-Host '----------------------' -ForegroundColor White
    Write-Host ''
    Write-Host '  Scope'
    Write-Host ("    subscription        {0}" -f $Config.subscriptionId)
    Write-Host ("    location            {0}" -f $Config.location)
    Write-Host ("    resource group      {0}" -f $Config.resourceGroup)
    Write-Host ''
    Write-Host '  Storage'
    Write-Host ("    account             {0}  ({1})" -f $Config.storageAccountName, $Config.storageSku)
    Write-Host ("    shares              {0}" -f (($Config.shares | ForEach-Object { "$($_.name) ($($_.quotaGiB) GiB)" }) -join ', '))
    Write-Host ''
    Write-Host '  Network'
    if ($Config.createVNet) {
        Write-Host ("    vnet                {0}  {1}" -f $Config.vnetName, $Config.vnetAddressPrefix)
    } else {
        Write-Host ("    vnet (existing)     {0}/{1}" -f $Config.vnetResourceGroup, $Config.vnetName)
    }
    Write-Host ("    pe subnet           {0}  {1}" -f $Config.peSubnetName, $Config.peSubnetPrefix)
    Write-Host ("    private dns zones   {0}, {1}" -f $Config.zoneFile, $Config.zoneAfs)
    Write-Host ''
    Write-Host '  File Sync'
    Write-Host ("    sync service        {0}" -f $Config.storageSyncServiceName)
    Write-Host ("    sync group          {0}" -f $Config.syncGroupName)
    Write-Host ''
    if ($Config.deployDnsResolver) {
        Write-Host '  DNS'
        Write-Host ("    resolver            {0}" -f $Config.dnsResolverName)
        Write-Host ("    inbound subnet      {0}  {1}" -f $Config.inboundSubnetName, $Config.inboundSubnetPrefix)
        Write-Host ''
    }
    if ($Config.deployBackup) {
        Write-Host '  Backup'
        Write-Host ("    vault               {0}" -f $Config.vaultName)
        Write-Host ("    redundancy          {0}   cross-region restore: {1}" -f $Config.storageRedundancy, $Config.crossRegionRestore)
        Write-Host ("    policy              {0}  ({1} day daily retention)" -f $Config.backupPolicyName, $Config.backupRetentionDays)
        Write-Host ''
    }
    Write-Host '  Identity'
    if ($Config.enableAdDsJoin) {
        Write-Host ("    ad domain           {0}  ({1})" -f $Config.adDomainFqdn, $Config.adNetBiosName)
        Write-Host ("    identity object     {0} in {1}" -f $Config.adIdentityObjectType, $Config.adOuDn)
        Write-Host ("    join run as         {0}" -f $Config.adAdminUpn)
    } else {
        $why = if ($Config.PSObject.Properties['adDsSkipReason']) { $Config.adDsSkipReason } else { 'disabled' }
        Write-Host ("    AD DS join          NOT configured - {0}" -f $why) -ForegroundColor Yellow
    }
    Write-Host ''
}
