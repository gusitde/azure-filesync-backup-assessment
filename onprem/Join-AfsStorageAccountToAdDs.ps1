<#
.SYNOPSIS
  Domain-join the storage account to on-premises AD DS, so people reach the file shares with
  the credentials they already have and existing NTFS permissions still apply.

.DESCRIPTION
  The third of the three steps the Azure build does not do, because it has to run on a
  domain-joined machine with rights in Active Directory.

  What it does, in order:
    1. Preflight - every requirement checked HERE, before AzFilesHybrid is even imported.
       That matters: Join-AzStorageAccount validates in its begin block, which runs even
       under -WhatIf, so a dry run on an unprepared machine still fails - and it fails with
       "This cmdlet requires an elevated PowerShell session", which sounds like the wrong
       problem. The real cause is almost always that RSAT AD PowerShell is missing.
    2. Fetch and import the AzFilesHybrid module (from the extracted folder, so nothing is
       copied into your profile and the version is exactly what was downloaded).
    3. Create the AD object and write the domain properties onto the storage account.
    4. Verify, with the module's own diagnostics, filtered to the checks a join can pass.
    5. Print what is still needed before anyone can actually read a file: share-level RBAC,
       and the NTFS permissions inside the share.

  IDEMPOTENT. A second run checks three things - the account says AD, the SamAccountName
  matches, and the AD object's password really is one of the storage account's Kerberos keys
  - and stops with "already joined" when all three hold. That last check matters: an account
  can claim to be joined while the shared secret has drifted, and then every mount fails.

  -Remove reverses it: capture the AD object, disable AD DS on the storage account, then
  delete the object. In that order, because once AD DS is disabled Azure no longer knows
  which AD object was its own.

.PARAMETER Context
  deployment-context.json from phase 1.

.PARAMETER OrganizationalUnit
  Distinguished name of the OU to create the object in. Defaults to the value in your inputs.
  Always give one: without it AzFilesHybrid puts the object wherever THIS machine's computer
  account lives, which is rarely what anyone wants.

.PARAMETER SamAccountName
  The AD account name. Defaults to the storage account name, or a deterministic 15-character
  form when that is too long. Never left to the module: it invents a RANDOM suffix, so two
  runs produce two different accounts.

.PARAMETER DomainAccountType
  ComputerAccount (default) or ServiceLogonAccount. Use a computer account unless policy
  forbids it - its password does not expire on the OU policy.

.PARAMETER CreateOrganizationalUnit
  Create the OU if it does not exist. Off by default: where the object lives is usually
  someone else's decision.

.PARAMETER AdCredential
  An account with rights in Active Directory, used for the OU steps. Prompted for against the
  account named in your inputs when it is needed and not supplied; AFS_AD_USER / AFS_AD_PASS
  are read first when both are set.

  Note what this does NOT cover. Join-AzStorageAccount has no credential parameter at all - it
  creates the computer object as WHOEVER IS RUNNING THE SCRIPT. So this credential can create
  the OU for you, but the join itself still needs the running account to hold create-computer
  rights in that OU. The script says so, with the delegation command, if it does not.

.PARAMETER GrantShareAccess
  One or more users or groups to grant share-level access to, as UPNs or object ids. Without
  this, a joined share still lets nobody in - the default share permission is None.

.PARAMETER ShareRole
  Which role -GrantShareAccess assigns. Default: Storage File Data SMB Share Contributor.

.EXAMPLE
  .\Join-AfsStorageAccountToAdDs.ps1 -Context ..\deploy\deployment-context.json -WhatIf

.EXAMPLE
  .\Join-AfsStorageAccountToAdDs.ps1 -Context ..\deploy\deployment-context.json -OrganizationalUnit 'OU=AzureFiles,DC=corp,DC=contoso,DC=com' -GrantShareAccess 'file-users@contoso.com'

.NOTES
  Windows PowerShell 5.1 only. PowerShell 7 and Cloud Shell do not work for this - the AD
  cmdlets AzFilesHybrid depends on are Desktop-edition. Microsoft documents this explicitly.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$Context,
    [string]$OrganizationalUnit,
    [string]$SamAccountName,
    [ValidateSet('ComputerAccount', 'ServiceLogonAccount')][string]$DomainAccountType,
    [switch]$CreateOrganizationalUnit,
    [System.Management.Automation.PSCredential]$AdCredential,
    [string[]]$GrantShareAccess,
    [ValidateSet('Storage File Data SMB Share Reader', 'Storage File Data SMB Share Contributor', 'Storage File Data SMB Share Elevated Contributor')]
    [string]$ShareRole = 'Storage File Data SMB Share Contributor',
    [string]$ModuleUrl = 'https://github.com/Azure-Samples/azure-files-samples/releases/download/v0.3.2/AzFilesHybrid.zip',
    [switch]$Remove
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AfsOnPrem.ps1')
if (-not $env:AFS_LOG_FILE) { Start-AfsLog -Level Verbose -Name 'addsjoin' | Out-Null }
Write-Host ('  log: ' + $env:AFS_LOG_FILE) -ForegroundColor DarkGray
Confirm-AfsCanPrompt -BoundParameters $PSBoundParameters -ScriptName 'onprem\Join-AfsStorageAccountToAdDs.ps1'

$ctx = Read-AfsContext -Path $Context
$cfg = $ctx.config
$sub = $cfg.subscriptionId
$rg  = $cfg.resourceGroup
$sa  = $cfg.storageAccountName
$env:AFS_SUBSCRIPTION_ID = $sub

if (-not $OrganizationalUnit) { $OrganizationalUnit = [string](Get-AfsProperty $cfg 'adOuDn' '') }
if (-not $DomainAccountType)  { $DomainAccountType  = [string](Get-AfsProperty $cfg 'adIdentityObjectType' 'ComputerAccount') }
if ($DomainAccountType -notin @('ComputerAccount', 'ServiceLogonAccount')) { $DomainAccountType = 'ComputerAccount' }

if (-not $SamAccountName) {
    # Deterministic, always. Left to itself the module takes the first 10 characters and adds
    # five RANDOM ones, so re-running the join creates a second, differently named account and
    # the idempotency check can never match.
    if ($sa.Length -le 15) {
        $SamAccountName = $sa
    } else {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($sa))).Replace('-', '')
        $SamAccountName = $sa.Substring(0, 10) + $hash.Substring(0, 5).ToLower()
    }
}

Set-AfsStepTotal -Total $(if ($Remove) { 4 } else { 6 }) -Activity 'Azure Files - AD DS join'

Write-Host ''
Write-Host ("  storage account : " + $sa + " (" + $rg + ")") -ForegroundColor White
Write-Host ("  AD domain       : " + (Get-AfsProperty $cfg 'adDomainFqdn' '(this machine''s domain)'))
Write-Host ("  organizational  : " + $(if ($OrganizationalUnit) { $OrganizationalUnit } else { '(NOT SET - see below)' }))
Write-Host ("  account         : " + $SamAccountName + " (" + $DomainAccountType + ")")

$verify = New-Object System.Collections.ArrayList
function Add-Verify { param([string]$What, [string]$Cmd) [void]$verify.Add([pscustomobject]@{ What = $What; Cmd = $Cmd }) }

# ================================================================== preflight ==

Write-AfsStep 'Preflight'

if ($PSVersionTable.PSEdition -and $PSVersionTable.PSEdition -ne 'Desktop') {
    throw ('This must run in Windows PowerShell 5.1. PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ') cannot load the Active Directory cmdlets AzFilesHybrid needs.')
}
Write-AfsOk ('Windows PowerShell ' + $PSVersionTable.PSVersion)

# the CimCmdlets module defines its aliases on load, and Set-Alias honours -WhatIf, so a dry
# run otherwise prints a dozen "What if: Set Alias" lines before the first real check
$prevWhatIf = $global:WhatIfPreference
try { $global:WhatIfPreference = $false; $cs = Get-CimInstance -ClassName Win32_ComputerSystem }
finally { $global:WhatIfPreference = $prevWhatIf }
if (-not $cs.PartOfDomain) {
    throw 'This machine is not domain-joined. Join-AzStorageAccount refuses to run anywhere else - even with -WhatIf. Run this from a domain-joined machine, such as an admin workstation or a domain controller.'
}
Write-AfsOk ('domain-joined to ' + $cs.Domain)

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-AfsWarn 'the Active Directory PowerShell module (RSAT) is not installed on this machine'
    Write-AfsSay @"
AzFilesHybrid uses it to create the account, and it tries to install it for you -
from a block that runs even under -WhatIf, and that install needs elevation. The
error you would see is "This cmdlet requires an elevated PowerShell session",
which points at the wrong problem.

Install it once, from an ELEVATED PowerShell on this machine:
  Install-WindowsFeature RSAT-AD-PowerShell        # Windows Server
  Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0   # Windows client

After that this script runs without elevation.
"@
    if (-not $isAdmin) { Write-AfsSay 'This session is NOT elevated, so it cannot install it for you.' }
    throw 'RSAT Active Directory PowerShell is required. See the instructions above.'
}
Write-AfsOk 'Active Directory PowerShell module present'

$azStorage = Get-Module -ListAvailable Az.Storage | Sort-Object Version -Descending | Select-Object -First 1
if (-not $azStorage) { throw 'Az.Storage is not installed. Run: Install-Module Az.Storage -Scope CurrentUser' }
if ($azStorage.Version -lt [version]'8.1.0') { throw ('AzFilesHybrid needs Az.Storage 8.1.0 or later; this machine has ' + $azStorage.Version + '.') }
Write-AfsOk ('Az.Storage ' + $azStorage.Version)

[void](Confirm-AfsAzPowerShell -SubscriptionId $sub -TenantId (Get-AfsProperty $ctx.identity 'tenantId'))

$account = Get-AzStorageAccount -ResourceGroupName $rg -Name $sa -ErrorAction Stop
$idAuth  = $account.AzureFilesIdentityBasedAuth
$current = $(if ($idAuth) { [string]$idAuth.DirectoryServiceOptions } else { '' })
if ($current -and $current -notin @('AD', 'None')) {
    throw ("$sa already uses a different identity source ($current). A storage account supports one at a time - disable that one before enabling AD DS.")
}
Write-AfsOk ('storage account identity source: ' + $(if ($current) { $current } else { 'none' }))

Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false

# ==================================================================== remove ===

if ($Remove) {
    Write-AfsStep 'Capture the AD object before Azure forgets it'
    # Order matters: Get-AzStorageAccountADObject resolves through the storage account's own
    # ActiveDirectoryProperties, and disabling AD DS erases them. Capture first.
    $adObj = $null
    $spn = 'cifs/' + $sa + '.file.core.windows.net'
    try { $adObj = Get-ADObject -LDAPFilter ("(servicePrincipalName=" + $spn + ")") -Properties DistinguishedName, ObjectClass -ErrorAction Stop } catch { }
    if ($adObj) { Write-AfsOk ('found ' + $adObj.ObjectClass + ' ' + $adObj.DistinguishedName) }
    else { Write-AfsInfo ('no AD object carries the SPN ' + $spn) }

    Write-AfsStep 'Disable AD DS on the storage account'
    if ($current -ne 'AD') {
        Write-AfsOk 'AD DS is not enabled on this storage account'
    } elseif ($PSCmdlet.ShouldProcess($sa, 'disable AD DS authentication')) {
        # NOTE the parameter name. -EnableAzureActiveDirectoryDomainServicesForFile is a
        # DIFFERENT feature (Entra Domain Services) and would not undo this join.
        Set-AzStorageAccount -ResourceGroupName $rg -AccountName $sa -EnableActiveDirectoryDomainServicesForFile $false | Out-Null
        Write-AfsOk 'AD DS authentication disabled'
        Write-AfsSay 'Windows ACLs on the files are kept - they simply stop being evaluated until a re-join.'
    }

    Write-AfsStep 'Remove the AD object'
    if (-not $adObj) {
        Write-AfsOk 'nothing to remove'
    } elseif ($PSCmdlet.ShouldProcess($adObj.DistinguishedName, 'delete the AD object')) {
        if ($adObj.ObjectClass -eq 'computer') { Remove-ADComputer -Identity $adObj.DistinguishedName -Confirm:$false }
        else { Remove-ADUser -Identity $adObj.DistinguishedName -Confirm:$false }
        Write-AfsOk ('deleted ' + $adObj.DistinguishedName)
    }

    Complete-AfsSteps -Outcome $(if ($WhatIfPreference) { 'WHAT-IF complete. Nothing was changed.' } else { 'AD DS join reversed.' })
    Write-Host ('  az storage account show -n ' + $sa + ' -g ' + $rg + ' --query azureFilesIdentityBasedAuthentication -o json')
    Stop-AfsLog -Outcome 'ad ds join reversed'
    return
}

# =================================================================== module ====

Write-AfsStep 'AzFilesHybrid module'
Write-AfsSay 'Imported before anything else, because the check for an existing join uses one of its cmdlets.'

$modDir = Join-Path ([IO.Path]::GetTempPath()) 'AzFilesHybrid'
if ($true) {
    if (-not (Test-Path (Join-Path $modDir 'AzFilesHybrid.psd1'))) {
        if ($PSCmdlet.ShouldProcess($ModuleUrl, 'download the AzFilesHybrid module')) {
            $zip = Join-Path ([IO.Path]::GetTempPath()) 'AzFilesHybrid.zip'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $ModuleUrl -OutFile $zip -UseBasicParsing -TimeoutSec 300
            if (Test-Path $modDir) { Remove-Item $modDir -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $modDir -Force
            # files out of a downloaded zip carry the mark of the web and will not import
            Get-ChildItem $modDir -Recurse | Unblock-File
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            Write-AfsOk ('downloaded and extracted to ' + $modDir)
        }
    } else {
        Write-AfsOk ('already extracted at ' + $modDir)
    }
    # Imported from the extracted folder rather than installed with CopyToPSPath.ps1: nothing
    # is written into the profile, and the version is exactly what was just downloaded.
    if (Test-Path (Join-Path $modDir 'AzFilesHybrid.psd1')) {
        Import-Module (Join-Path $modDir 'AzFilesHybrid.psd1') -Force -Verbose:$false -ErrorAction Stop
        Write-AfsOk ('AzFilesHybrid ' + (Get-Module AzFilesHybrid).Version + ' imported')
    }
}

# =============================================================== already done ==

Write-AfsStep 'Is it already joined?'

$joined = $false
if ($current -eq 'AD') {
    $props = $idAuth.ActiveDirectoryProperties
    $sameName = ($props -and [string]$props.SamAccountName -eq $SamAccountName)
    Write-AfsInfo ('the account reports AD DS for ' + $(if ($props) { $props.DomainName } else { '?' }) + ' as ' + $(if ($props) { $props.SamAccountName } else { '?' }))
    if (-not $sameName) {
        Write-AfsWarn ('it is joined as ' + $(if ($props) { $props.SamAccountName } else { '(unknown)' }) + ', not ' + $SamAccountName)
        Write-AfsSay 'Pass -SamAccountName with that name to work with the existing join, or -Remove first.'
        throw 'The storage account is joined under a different account name.'
    }
    # A joined-looking account whose shared secret has drifted authenticates nobody, so the
    # key check is part of "already done", not part of the verification afterwards.
    $keyOk = $false
    try {
        $m = Test-AzStorageAccountADObjectPasswordIsKerbKey -ResourceGroupName $rg -StorageAccountName $sa -ErrorAction Stop
        $keyOk = [bool](@($m | Where-Object { $_.KeyMatches }).Count)
    } catch { Write-AfsInfo ('could not compare the Kerberos keys yet: ' + $_.Exception.Message) }
    if ($keyOk) {
        Write-AfsOk 'already joined, and the AD password matches a Kerberos key'
        $joined = $true
    } else {
        Write-AfsWarn 'joined, but the AD object password does not match either Kerberos key - the join will be repaired'
    }
} else {
    Write-AfsInfo 'not joined yet'
}

# ======================================================================= OU ====

Write-AfsStep 'Organizational unit'

if (-not $OrganizationalUnit) {
    Write-AfsWarn 'no organizational unit was given'
    Write-AfsSay @"
Without one the module creates the object wherever THIS machine's computer account
lives, which is almost never intended. Pass -OrganizationalUnit with a distinguished
name, for example:
  -OrganizationalUnit 'OU=AzureFiles,$((Get-ADDomain).DistinguishedName)'
"@
    throw 'An organizational unit is required. See above.'
}

$adArgs = @{}
if ($AdCredential) { $adArgs.Credential = $AdCredential }

$ouExists = $false
try { $ouExists = [bool](Get-ADObject -Identity $OrganizationalUnit @adArgs -ErrorAction Stop) } catch { }
if ($ouExists) {
    Write-AfsOk ($OrganizationalUnit + ' exists')
} elseif ($CreateOrganizationalUnit) {
    $name = ($OrganizationalUnit -split ',')[0] -replace '^OU=', ''
    $parent = ($OrganizationalUnit -split ',', 2)[1]
    if (-not $AdCredential) {
        # Creating an OU is a directory change, and the account running this is usually not the
        # one allowed to make it. Ask before failing with a bare "Access is denied".
        $adUpn = [string](Get-AfsProperty $cfg 'adAdminUpn' '')
        Write-AfsInfo ('creating an organizational unit needs an account with rights in ' + $cs.Domain)
        $AdCredential = Get-AfsCredential -UserName $adUpn -Message ('An account that may create an OU in ' + $cs.Domain) -UserEnvName 'AFS_AD_USER' -PasswordEnvName 'AFS_AD_PASS'
        $adArgs = @{ Credential = $AdCredential }
    }
    if ($PSCmdlet.ShouldProcess($OrganizationalUnit, 'create the organizational unit')) {
        try {
            New-ADOrganizationalUnit -Name $name -Path $parent -ProtectedFromAccidentalDeletion $true @adArgs -ErrorAction Stop
        } catch {
            Write-AfsWarn ('could not create ' + $OrganizationalUnit + ': ' + $_.Exception.Message)
            Write-AfsSay ("The account used (" + $(if ($AdCredential) { $AdCredential.UserName } else { $env:USERNAME }) + ") may not create an organizational unit there.
Ask a directory administrator to create it, or pass -AdCredential with an account that can.")
            throw
        }
        Write-AfsOk ('created ' + $OrganizationalUnit)
    }
} else {
    Write-AfsWarn ($OrganizationalUnit + ' does not exist')
    Write-AfsSay "Create it yourself, or re-run with -CreateOrganizationalUnit:
  New-ADOrganizationalUnit -Name '$(($OrganizationalUnit -split ',')[0] -replace '^OU=', '')' -Path '$(($OrganizationalUnit -split ',', 2)[1])'"
    throw 'The organizational unit does not exist.'
}
Add-Verify 'the organizational unit' ("Get-ADObject -Identity '" + $OrganizationalUnit + "'")

# ===================================================================== join ====

Write-AfsStep 'Join the storage account to AD DS'

if ($joined) {
    Write-AfsOk 'nothing to do'
} else {
    $keyAccess = ConvertTo-AfsBool $account.AllowSharedKeyAccess -Default $true
    if (-not $keyAccess) {
        Write-AfsWarn 'shared key access is disabled on this storage account'
        Write-AfsSay @"
The join reads the account's Kerberos key to use as the AD object's password. That
read is a control-plane call, so it should still work - but Microsoft does not
document the interaction either way, so if the join fails on key retrieval, allow
shared key access for the join and turn it off again afterwards:
  az storage account update -n $sa -g $rg --allow-shared-key-access true
"@
    }
    if ($PSCmdlet.ShouldProcess($sa, ('join to AD DS as ' + $SamAccountName))) {
        # Named parameters only, one per line. Two of this cmdlet's parameters are both
        # declared at position 5, so anything positional binds to the wrong one.
        $p = @{
            ResourceGroupName                   = $rg
            StorageAccountName                  = $sa
            SamAccountName                      = $SamAccountName
            DomainAccountType                   = $DomainAccountType
            OrganizationalUnitDistinguishedName = $OrganizationalUnit
            ErrorAction                         = 'Stop'
        }
        $domain = Get-AfsProperty $cfg 'adDomainFqdn' ''
        if ($domain) { $p.Domain = $domain }
        # No -EncryptionType: it was removed in AzFilesHybrid v0.2.9 and AES-256 is now
        # unconditional. Passing it to a current module is a parameter binding error.
        try {
            Join-AzStorageAccount @p
        } catch {
            $msg = $_.Exception.Message
            # the module rewrites the AD error into its own wording, and the same wording is
            # also what it emits for a SamAccountName that is too long - so both are named
            if ($msg -match 'Access is denied|privilege is not held|Insufficient access|Unable to create AD object|permission to create an identity') {
                Write-AfsWarn 'Active Directory refused to create the account'
                Write-AfsSay @"
Join-AzStorageAccount has no credential parameter - it creates the computer
object as whoever is running this script, which right now is $env:USERDOMAIN\$env:USERNAME.
That account needs the right to create a computer object in

  $OrganizationalUnit

Either run this script as an account that has it, or have a directory
administrator delegate it - which is what Microsoft's least-privilege guidance
describes:

  dsacls "$OrganizationalUnit" /I:T /G "$env:USERDOMAIN\$env:USERNAME:CC;computer"

If the permissions really are in place, check the account name length instead:
the module reports a SamAccountName that is too long with this same message.
Yours is '$SamAccountName' ($($SamAccountName.Length) characters, limit 15).

Nothing was changed in Azure; re-run when that is in place.
"@
            }
            throw
        }
        Write-AfsOk ('joined as ' + $SamAccountName)
    }
}
Add-Verify 'identity source' ("az storage account show -n $sa -g $rg --query azureFilesIdentityBasedAuthentication.directoryServiceOptions -o tsv")
Add-Verify 'domain properties' ("az storage account show -n $sa -g $rg --query azureFilesIdentityBasedAuthentication.activeDirectoryProperties -o json")
Add-Verify 'the AD password really is a Kerberos key' ("Test-AzStorageAccountADObjectPasswordIsKerbKey -ResourceGroupName $rg -StorageAccountName $sa -Verbose")

# =================================================================== verify ====

Write-AfsStep 'Verify and grant access'

if (-not $WhatIfPreference) {
    $after = Get-AzStorageAccount -ResourceGroupName $rg -Name $sa
    $ap = $after.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties
    if ($ap) {
        Write-AfsOk ('domain ' + $ap.DomainName + ', account ' + $ap.SamAccountName + ' (' + $ap.AccountType + ')')
        Write-AfsInfo ('storage SID ' + $ap.AzureStorageSid)
    }
    # Only the checks a join alone can pass. The share-level and file-level checks fail by
    # design until the two steps below are done, and reporting them as failures here would
    # be misleading.
    try {
        Debug-AzStorageAccountAuth -StorageAccountName $sa -ResourceGroupName $rg `
            -Filter 'CheckADObject,CheckADObjectPasswordIsCorrect,CheckStorageAccountDomainJoined,CheckDomainLineOfSight,CheckKerberosTicketEncryption' -Verbose
    } catch { Write-AfsWarn ('the diagnostics did not complete: ' + $_.Exception.Message) }
}

if ($GrantShareAccess) {
    foreach ($who in $GrantShareAccess) {
        foreach ($share in (ConvertTo-AfsArray $cfg.shares)) {
            $scope = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$sa/fileServices/default/fileshares/" + $share.name
            $have = ConvertTo-AfsArray (Invoke-AfsAz -Args @('role', 'assignment', 'list', '--assignee', $who, '--scope', $scope, '--query', "[?roleDefinitionName=='$ShareRole'].id", '-o', 'json') -AllowFailure)
            if ($have.Count) { Write-AfsOk ($who + ' already has ' + $ShareRole + ' on ' + $share.name); continue }
            if ($PSCmdlet.ShouldProcess(($who + ' on ' + $share.name), ('grant ' + $ShareRole))) {
                Invoke-AfsAz -Args @('role', 'assignment', 'create', '--assignee', $who, '--role', $ShareRole, '--scope', $scope, '-o', 'none') | Out-Null
                Write-AfsOk ($who + ' granted ' + $ShareRole + ' on ' + $share.name)
            }
        }
    }
    Add-Verify 'share-level access' ("az role assignment list --scope /subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$sa/fileServices/default/fileshares/<share> -o table")
}

Complete-AfsSteps -Outcome $(if ($WhatIfPreference) { 'WHAT-IF complete. Nothing was changed.' } else { 'AD DS join complete.' })

Write-Host 'Verify with:' -ForegroundColor White
foreach ($v in $verify) { Write-Host ('  # ' + $v.What) -ForegroundColor DarkGray; Write-Host ('  ' + $v.Cmd) }

Write-Host ''
Write-Host 'A join on its own lets nobody in. Two more layers decide access:' -ForegroundColor White
Write-Host '  1. Share level - who may reach the share at all. The default is nobody.'
if (-not $GrantShareAccess) {
    Write-Host ("     .\Join-AfsStorageAccountToAdDs.ps1 -Context $Context -GrantShareAccess '<group-upn>'")
}
Write-Host '  2. File level - the NTFS permissions inside it. Mount the share once with the'
Write-Host '     account key and set them; use net use, not New-PSDrive, or Explorer and'
Write-Host '     cmd.exe will not see the drive:'
Write-Host ("       net use Z: \\$sa.file.core.windows.net\<share> /user:localhost\$sa <account-key>")
Write-Host '       icacls Z: /grant <group-upn>:(f)'
Write-Host '       cmdkey /delete:Domain:target=' -NoNewline; Write-Host ($sa + '.file.core.windows.net')
Write-Host ''
Write-Host 'Only members of a hybrid identity - synced from AD DS to Entra ID - can be granted'
Write-Host 'share-level access. A cloud-only account cannot be used here.'
Write-Host ''
Write-Host ('Reverse it with: .\Join-AfsStorageAccountToAdDs.ps1 -Context ' + $Context + ' -Remove')

Stop-AfsLog -Outcome 'ad ds join run ended'
