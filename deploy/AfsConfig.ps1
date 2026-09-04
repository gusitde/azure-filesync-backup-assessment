<#
  Shared configuration resolver. Dot-sourced by both phases.

  Turns the four inputs the operator supplies into the complete set of names and
  settings the deployment needs, so there is exactly one file to edit and no
  chance of the two phases disagreeing about what is being built.

  Derivation is deterministic: the same inputs always produce the same names, so
  a re-run targets the same objects and the deployment stays idempotent.
#>

Set-StrictMode -Version 2.0

function Get-AzureFailureAdvice {
    <#
      .SYNOPSIS
        Turn a raw Azure error into what actually went wrong and what to do about it.

      .DESCRIPTION
        Azure's errors are accurate and unhelpful. "AuthorizationFailed" covers a missing
        role, a Global Administrator with no Azure rights at all, and a token issued before
        a grant was made - three different problems with three different fixes, and the
        message is the same for all of them.

        This maps the message to a cause and the exact commands that resolve it, so nobody
        has to recognise the pattern themselves.
    #>
    param([string]$Message)

    if (-not $Message) { return $null }
    $m = $Message

    # the export script uses Az PowerShell, whose sign-in is separate from the Azure CLI's
    if ($m -match 'Az PowerShell session' -or $m -match 'Connect-AzAccount' -or $m -match 'No Azure context' -or $m -match 'Could not list subscriptions') {
        return [pscustomobject]@{
            Cause = 'The Az PowerShell module is not signed in, or its session no longer works.'
            Why   = 'Az PowerShell keeps its own sign-in, separate from the Azure CLI - az login does not cover it. A context can also exist yet be unusable, for example one that has expired or was created from a raw token; it passes a presence check and then fails on the first real call.'
            Fix   = @('Connect-AzAccount -Tenant <tenant-id>', '# then confirm it can actually call Azure:', '(Invoke-AzRestMethod -Method GET -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01").StatusCode   # expect 200')
            Then  = 'Then run the export again. The wizard now does this check for you before starting it.'
        }
    }

    # a token issued before the access was granted - checked FIRST because the message also
    # contains AuthorizationFailed, and this is the more specific case
    if ($m -match 'recently granted' -or $m -match 'refresh your credentials') {
        return [pscustomobject]@{
            Cause = 'Your access is correct, but the sign-in token was issued before it was granted.'
            Why   = 'Azure role changes do not appear in a token that already exists. Signing in again reissues it.'
            Fix   = @('az login')
            Then  = 'Then run this again. Nothing needs undoing.'
        }
    }

    # Conditional Access wants step-up authentication for writes. The CLI prints the exact
    # command including the claims challenge, so quote it back rather than paraphrasing.
    if ($m -match 'claims-challenge' -or $m -match 'claims_challenge' -or $m -match '"acrs"' -or $m -match 'authenticate interactively') {
        $cmd = 'az login --scope "https://management.core.windows.net//.default"'
        $mm = [regex]::Match($m, 'az login[^\r\n]*--claims-challenge\s+"[^"]+"')
        if ($mm.Success) { $cmd = $mm.Value }
        return [pscustomobject]@{
            Cause = 'Conditional Access requires step-up authentication before this tenant will allow a write.'
            Why   = 'Your sign-in is valid for reading but does not satisfy the authentication context this tenant demands for creating or changing resources. Re-authenticating with the claims challenge below satisfies it, and also reissues the token so any recent role grant is picked up.'
            Fix   = @('az logout', $cmd)
            Then  = 'Then run this again. The command above was produced by the CLI itself, so use it exactly as printed.'
        }
    }

    # multi-factor authentication is required for every write in this tenant
    if ($m -match 'RequestDisallowedByAzure' -or $m -match 'without authenticating through MFA' -or $m -match 'MFAforAzure') {
        return [pscustomobject]@{
            Cause = 'This tenant requires multi-factor authentication before any resource can be created.'
            Why   = 'Your session signed in without completing MFA. It can read everything and create nothing. This is not a permissions problem - granting yourself more roles will not help.'
            Fix   = @('az logout', 'az login')
            Then  = 'Complete the MFA prompt in the browser, then run this again.'
        }
    }

    # cannot create role assignments - needs Owner, User Access Administrator, or elevation
    if ($m -match 'Authorization/roleAssignments/write') {
        return [pscustomobject]@{
            Cause = 'This account cannot grant roles at that scope.'
            Why   = 'Creating the deployment identity needs Owner or User Access Administrator on the subscription. If you are an Entra Global Administrator with no Azure role, you have rights over the directory but none over Azure resources - they are separate, and this is the usual cause.'
            Fix   = @(
                '# if you are a Global Administrator, elevate once:',
                'az rest --method post --url "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"',
                'az login    # required - the elevation is not in your current token',
                'az role assignment create --assignee <your-upn> --role Owner --scope /subscriptions/<sub-id>'
            )
            Then  = 'Then run this again. Turn the elevation back off afterwards in Entra ID > Properties > Access management for Azure resources.'
        }
    }

    # a plain missing role
    if ($m -match 'AuthorizationFailed' -or $m -match 'does not have authorization to perform action') {
        return [pscustomobject]@{
            Cause = 'This account does not have the Azure role it needs at that scope.'
            Why   = 'Being a Global Administrator in Entra ID grants nothing over Azure resources - directory roles and Azure roles are separate. Check what you actually hold before assuming.'
            Fix   = @(
                'az role assignment list --assignee <your-upn> --all -o table',
                '# if that is empty and you are a Global Administrator:',
                'az rest --method post --url "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"',
                'az login',
                'az role assignment create --assignee <your-upn> --role Owner --scope /subscriptions/<sub-id>'
            )
            Then  = 'You need Contributor at minimum, or Owner to also create the deployment identity.'
        }
    }

    # storage account names are global
    if ($m -match 'StorageAccountAlreadyTaken' -or $m -match 'is already taken' -or $m -match 'AccountNameInvalid') {
        return [pscustomobject]@{
            Cause = 'That storage account name is not available.'
            Why   = 'Storage account names are globally unique across all of Azure, not just your tenant, and must be 3-24 lowercase letters and digits.'
            Fix   = @('# change azure.uniqueSuffix or azure.namePrefix in your inputs file, then:', 'az storage account check-name --name <candidate>')
            Then  = 'Run with -ShowResolved to see the derived name before trying again.'
        }
    }

    # the CLI extension is missing
    if ($m -match 'dns-resolver' -and ($m -match 'not in the' -or $m -match 'extension' -or $m -match 'misspelled')) {
        return [pscustomobject]@{
            Cause = 'The dns-resolver CLI extension is not installed.'
            Why   = 'It is an extension rather than part of the base CLI, so the command is reported as unrecognised instead of as a missing component.'
            Fix   = @('az extension add --name dns-resolver')
            Then  = 'Then run this again.'
        }
    }

    if ($m -match 'MissingSubscription' -or $m -match 'SubscriptionNotFound') {
        return [pscustomobject]@{
            Cause = 'The CLI has no subscription selected, or cannot see the one requested.'
            Why   = 'Either you are not signed in to the right tenant, or the account has no access to that subscription.'
            Fix   = @('az account list -o table', 'az account set --subscription <id>')
            Then  = 'Check the subscription id in your inputs file matches one you can see.'
        }
    }

    # first use of a service in a subscription
    if ($m -match 'MissingSubscriptionRegistration') {
        $ns = 'the namespace named in the error'
        $mm = [regex]::Match($m, "namespace '([^']+)'")
        if ($mm.Success) { $ns = $mm.Groups[1].Value }
        return [pscustomobject]@{
            Cause = "The subscription has never used $ns, so its resource provider is not registered."
            Why   = 'Azure registers a resource provider the first time a subscription needs it, and a create that arrives before that fails with MissingSubscriptionRegistration. It is a one-time step per subscription and takes a minute or two.'
            Fix   = @("az provider register -n $ns", "az provider show -n $ns --query registrationState -o tsv   # wait for Registered")
            Then  = 'Then run this again; the deployment is idempotent and continues where it stopped. The preflight now does this automatically.'
        }
    }

    if ($m -match 'ResourceGroupNotFound') {
        return [pscustomobject]@{
            Cause = 'The resource group does not exist yet.'
            Why   = 'Phase 1 creates it. If you are running phase 2 directly, phase 1 has not completed.'
            Fix   = @('.\Phase1-New-DeploymentIdentity.ps1 -InputFile .\inputs.json')
            Then  = 'Then run phase 2 with the context it writes.'
        }
    }

    return $null
}

function Show-AzureFailure {
    <# Print the advice above in a form somebody can act on without reading Azure docs. #>
    param([string]$Message, [string]$Context)

    Write-Host ''
    if ($Context) { Write-Host ("  " + $Context) -ForegroundColor Red }

    $a = Get-AzureFailureAdvice -Message $Message
    if (-not $a) {
        Write-Host '  The error Azure returned:' -ForegroundColor Yellow
        Write-Host ''
        foreach ($line in ($Message -split "`n" | Select-Object -First 6)) {
            Write-Host ("    " + $line.Trim()) -ForegroundColor Gray
        }
        Write-Host ''
        Write-Host '  This one is not recognised. docs/GETTING-STARTED.md has a troubleshooting table.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    Write-Host ''
    Write-Host ('  What went wrong:  ' + $a.Cause) -ForegroundColor Yellow
    Write-Host ''
    foreach ($line in ($a.Why -split "(?<=\.)\s+")) {
        if ($line.Trim()) { Write-Host ("  " + $line.Trim()) -ForegroundColor Gray }
    }
    Write-Host ''
    Write-Host '  Do this:' -ForegroundColor White
    foreach ($cmd in $a.Fix) {
        if ($cmd -match '^\s*#') { Write-Host ("    " + $cmd) -ForegroundColor DarkGray }
        else { Write-Host ("    " + $cmd) -ForegroundColor Cyan }
    }
    Write-Host ''
    Write-Host ("  " + $a.Then) -ForegroundColor Gray
    Write-Host ''
}

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

    # The machines on the customer's side. Optional - the on-premises scripts each take these
    # as parameters - but carrying them here means the wizard can offer what you used last
    # time, and show the expected shape of an answer instead of asking cold.
    $op = Get-AfsProp $Inputs 'onPremises'
    $cfg['onPremises'] = [pscustomobject]@{
        fileServer  = [string](Get-AfsProp $op 'fileServer' '')
        serverPaths = Get-AfsProp $op 'serverPaths' ([pscustomobject]@{})
        dnsServers  = [string](Get-AfsProp $op 'dnsServers' '')
    }

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
