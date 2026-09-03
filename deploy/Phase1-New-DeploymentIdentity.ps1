<#
.SYNOPSIS
  PHASE 1 - create the Entra deployment identity, grant it RBAC, and write the deployment
  context that phase 2 runs from unattended.

.DESCRIPTION
  Run this ONCE, interactively, signed in as the Entra global administrator named in the
  inputs file. That sign-in is the single human step in the whole process, and it exists
  because most tenants require multi-factor authentication for every ARM write.

  What it does:
    1. Signs in as the administrator (interactive, satisfies MFA).
    2. Expands the four operator inputs into the full deployment configuration.
    3. Creates an Entra application and service principal - the deployment identity.
    4. Creates the target resource group and grants the identity Contributor ON THAT GROUP,
       not on the subscription.
    5. Writes deployment-context.json: the resolved configuration plus a reference to the
       identity. That file is what phase 2 consumes - it is where the identity and the build
       definition come together.
    6. Signs in as the new identity and proves it can read the scope, so a failure surfaces
       here rather than halfway through phase 2.

  After this, phase 2 needs no human:

      .\Deploy-AfsEnvironment.ps1 -Context .\deployment-context.json

.PARAMETER InputFile
  The inputs file. Start from inputs.sample.jsonc.

.PARAMETER IdentityName
  Display name for the deployment identity. Default: derived from the name prefix.

.PARAMETER Role
  Role granted at the resource group scope. Default Contributor.

.PARAMETER Federate
  Issue no secret. Instead add a GitHub Actions federated credential so a pipeline
  authenticates with OIDC and nothing sensitive is ever stored. Requires -GitHubRepo.

.PARAMETER SkipLogin
  Use the session you already have instead of prompting.

.EXAMPLE
  .\Phase1-New-DeploymentIdentity.ps1 -InputFile .\inputs.json

.EXAMPLE
  .\Phase1-New-DeploymentIdentity.ps1 -InputFile .\inputs.json -Federate -GitHubRepo myorg/myrepo

.NOTES
  Permissions the administrator needs:
    - Application Administrator or Global Administrator in Entra ID, to create the identity.
    - Owner or User Access Administrator on the subscription, to grant the role.
  Nothing else in this kit needs privilege that high. The deployment identity it creates is
  scoped to a single resource group.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [string]$IdentityName,
    [string]$Role = 'Contributor',
    [switch]$Federate,
    [string]$GitHubRepo,
    [string]$GitHubBranch = 'main',
    [string]$ContextFile = '.\deployment-context.json',
    [string]$SecretFile = '.\deployment-identity.json',
    [switch]$SkipLogin
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AfsConfig.ps1')
. (Join-Path $PSScriptRoot 'AfsLog.ps1')
if (-not $env:AFS_LOG_FILE) { Start-AfsLog -Level Verbose -Name 'phase1' | Out-Null }
Write-Host ('  log: ' + $env:AFS_LOG_FILE) -ForegroundColor DarkGray

$script:StepNo = 0
$script:StepTotal = 9
$script:ProgressActivity = 'Phase 1 - deployment identity'
function Write-Step {
    param([string]$T)
    $script:StepNo++
    Write-AfsLog -Level STEP -Message ('[' + $script:StepNo + '/' + $script:StepTotal + '] ' + $T)
    Write-Host ''
    Write-AfsPhaseStrip -Done ($script:StepNo - 1) -Total $script:StepTotal
    Write-Host ("-> [{0}/{1}] {2}" -f $script:StepNo, $script:StepTotal, $T) -ForegroundColor Cyan
    Write-AfsProgress -Activity $script:ProgressActivity -Status $T -Step $script:StepNo -Total $script:StepTotal
}
function Write-Ok    { param([string]$T) Write-AfsLog -Level INFO -Message ("ok: " + $T); Write-Host ("   OK   " + $T) -ForegroundColor Green }
function Write-Warn2 { param([string]$T) Write-AfsLog -Level WARN -Message $T; Write-Host ("   WARN " + $T) -ForegroundColor Yellow }

function Invoke-Az {
    # every CLI call goes through the shared logger so the run is fully recorded
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFailure)
    if ($AllowFailure) { return Invoke-AfsAz -Args $Args -AllowFailure }
    return Invoke-AfsAz -Args $Args
}

Write-Host ''
Write-Host 'PHASE 1 - deployment identity' -ForegroundColor White
Write-Host '=============================' -ForegroundColor White

# --------------------------------------------------------------- resolve ----

Write-Step 'Reading and expanding the inputs'
$inputs = Read-AfsJsonc -Path $InputFile
$cfg = Resolve-AfsConfig -Inputs $inputs
Show-AfsConfig -Config $cfg

if (-not $IdentityName) { $IdentityName = "sp-$($cfg.namePrefix)-afs-deploy" }
$scope = "/subscriptions/$($cfg.subscriptionId)/resourceGroups/$($cfg.resourceGroup)"

# --------------------------------------------------------------- sign in ----

if (-not $SkipLogin) {
    Write-Step "Signing in as $($cfg.adminUpn)"
    Write-Host '   A browser window will open. Complete MFA if prompted.' -ForegroundColor DarkGray
    if ($PSCmdlet.ShouldProcess($cfg.adminUpn, 'interactive sign-in')) {
        $loginArgs = @('login', '--only-show-errors', '-o', 'json')
        if ($cfg.tenantId) { $loginArgs += @('--tenant', $cfg.tenantId) }
        Invoke-Az $loginArgs -AllowFailure | Out-Null
    }
}

$acct = Invoke-Az @('account', 'show', '-o', 'json') -AllowFailure
if (-not $acct) { throw 'Not signed in. Run az login, or re-run without -SkipLogin.' }
Write-Ok ("signed in as " + $acct.user.name)
if ($cfg.adminUpn -and $acct.user.name -ne $cfg.adminUpn) {
    Write-Warn2 "signed in as $($acct.user.name) but the inputs file names $($cfg.adminUpn)"
}
$env:AFS_SUBSCRIPTION_ID = $cfg.subscriptionId   # every az call is pinned to it (see Invoke-AfsAz)
Invoke-Az @('account', 'set', '--subscription', $cfg.subscriptionId) -AllowFailure | Out-Null
Write-Ok 'subscription set'

# ------------------------------------------------------------ write probe ---

Write-Step 'Establishing write access, and the resource group'
$rg = Invoke-Az @('group', 'show', '-n', $cfg.resourceGroup, '-o', 'json') -AllowFailure
if ($rg) {
    Write-Ok "resource group $($cfg.resourceGroup) already exists"
} elseif ($PSCmdlet.ShouldProcess($cfg.resourceGroup, 'create resource group')) {
    # capture the real error rather than a boolean, so the failure can be explained
    $err = $null
    try {
        Invoke-Az @('group', 'create', '-n', $cfg.resourceGroup, '-l', $cfg.location,
            '--tags', 'purpose=azure-file-sync', "prefix=$($cfg.namePrefix)", '-o', 'json') | Out-Null
    } catch {
        $err = $_.Exception.Message
    }
    if ($err) {
        Show-AzureFailure -Message $err -Context 'The resource group could not be created, so nothing else was attempted.'
        throw 'Stopped before creating anything. Fix the above and run this again.'
    }
    Write-Ok "resource group $($cfg.resourceGroup) created"
}

# ---------------------------------------------------------------- identity --

Write-Step "Entra deployment identity $IdentityName"
$existing = Invoke-Az @('ad', 'sp', 'list', '--display-name', $IdentityName, '--query', '[0]', '-o', 'json') -AllowFailure
$appId = $null
$secret = $null

if ($existing) {
    $appId = $existing.appId
    Write-Ok "already exists ($appId)"
} elseif ($PSCmdlet.ShouldProcess($IdentityName, 'create Entra application and service principal')) {
    $err = $null; $app = $null
    try { $app = Invoke-Az @('ad', 'app', 'create', '--display-name', $IdentityName, '-o', 'json') }
    catch { $err = $_.Exception.Message }
    if (-not $app) {
        Show-AzureFailure -Message $err -Context 'The Entra application could not be created.'
        Write-Host '  This step needs a DIRECTORY role, not an Azure one: Application' -ForegroundColor Gray
        Write-Host '  Administrator or Global Administrator in Entra ID. Check yours with:' -ForegroundColor Gray
        Write-Host '    az rest --method get --url "https://graph.microsoft.com/v1.0/me/memberOf?$select=displayName"' -ForegroundColor Cyan
        Write-Host ''
        throw 'Stopped. The resource group exists; nothing else was created.'
    }
    $appId = $app.appId
    Invoke-Az @('ad', 'sp', 'create', '--id', $appId, '-o', 'none') -AllowFailure | Out-Null
    Write-Ok "created $appId"
}

if ($Federate) {
    if (-not $GitHubRepo) { throw '-Federate needs -GitHubRepo in owner/repo form.' }
    Write-Step 'Federated credential - no secret is issued'
    $subject = "repo:${GitHubRepo}:ref:refs/heads/${GitHubBranch}"
    $params = [ordered]@{
        name        = ('gh-' + ($GitHubRepo -replace '[^A-Za-z0-9]', '-') + '-' + $GitHubBranch)
        issuer      = 'https://token.actions.githubusercontent.com'
        subject     = $subject
        description = 'Azure File Sync deployment'
        audiences   = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    if ($PSCmdlet.ShouldProcess($subject, 'add federated credential')) {
        $tmp = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tmp -Value $params -Encoding ascii
        Invoke-Az @('ad', 'app', 'federated-credential', 'create', '--id', $appId, '--parameters', "@$tmp", '-o', 'none') -AllowFailure | Out-Null
        Remove-Item $tmp -Force
        Write-Ok "federated $subject"
    }
} elseif ($appId -and $PSCmdlet.ShouldProcess($appId, 'issue a client secret')) {
    Write-Step 'Issuing a client secret, valid one year'
    $cred = Invoke-Az @('ad', 'sp', 'credential', 'reset', '--id', $appId, '--years', '1', '-o', 'json') -AllowFailure
    if ($cred) { $secret = $cred.password; Write-Ok 'issued' }
    else { Write-Warn2 'no secret issued - use -Federate, or create one in the portal' }
}

# ------------------------------------------------------------------ grant ---

Write-Step "Granting $Role on the resource group, not the subscription"
if ($appId -and $PSCmdlet.ShouldProcess($scope, "grant $Role")) {
    $spOid = Invoke-Az @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv') -AllowFailure
    $have = Invoke-Az @('role', 'assignment', 'list', '--assignee', $appId, '--scope', $scope,
        '--query', "length([?roleDefinitionName=='$Role'])", '-o', 'tsv') -AllowFailure
    if ($have -and [int]$have -gt 0) {
        Write-Ok 'already granted'
    } else {
        # a role assignment for a just-created principal can fail with PrincipalNotFound until
        # the directory has replicated it; --assignee-object-id avoids the Graph lookup, and
        # this retries the remaining window rather than failing on the first attempt
        $err = $null
        for ($try = 1; $try -le 6; $try++) {
            $err = $null
            try {
                Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $spOid,
                    '--assignee-principal-type', 'ServicePrincipal', '--role', $Role,
                    '--scope', $scope, '-o', 'none') | Out-Null
                break
            } catch { $err = $_.Exception.Message }
            if ($err -notmatch 'PrincipalNotFound' -and $err -notmatch 'does not exist in the directory') { break }
            Write-Warn2 ("principal not replicated yet (attempt " + $try + "/6) - waiting 10 s")
            Start-Sleep -Seconds 10
        }
        if ($err) {
            Show-AzureFailure -Message $err -Context "The identity was created, but $Role could not be granted to it."
            throw 'Stopped. Grant the role, then run this again - it will reuse the identity.'
        }
        Write-Ok "$Role granted at $scope"
    }
}

# ---------------------------------------------------------------- context ---

Write-Step 'Writing the deployment context'
$context = [ordered]@{
    schema     = 'afs-deployment-context/1'
    createdUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    createdBy  = $acct.user.name
    identity   = [ordered]@{
        displayName = $IdentityName
        appId       = $appId
        tenantId    = $acct.tenantId
        authMode    = $(if ($Federate) { 'federated' } else { 'clientSecret' })
        scope       = $scope
        role        = $Role
        # a re-run that found the identity already there issues no new secret; keep pointing
        # at the secret file a previous run wrote, so unattended phase 2 still works
        secretFile  = $(if ($secret) { Split-Path -Leaf $SecretFile } elseif (Test-Path $SecretFile) { Split-Path -Leaf $SecretFile } else { $null })
    }
    config     = $cfg
}
if ($WhatIfPreference) {
    Write-Warn2 "what-if: $ContextFile would be written, but nothing has been created so it is not"
} else {
    $context | ConvertTo-Json -Depth 8 | Set-Content -Path $ContextFile -Encoding ascii
    Write-Ok "wrote $ContextFile"
}

if ($secret -and -not $WhatIfPreference) {
    [ordered]@{ appId = $appId; tenantId = $acct.tenantId; password = $secret } |
        ConvertTo-Json | Set-Content -Path $SecretFile -Encoding ascii
    Write-Ok "wrote $SecretFile"
    Write-Warn2 'that file holds a secret. It is gitignored. Move it into your secret store.'
}

# ----------------------------------------------------------------- verify ---

Write-Step 'Proving the new identity works, before phase 2 depends on it'
$identityVerified = $false
if ($secret -and $appId -and $PSCmdlet.ShouldProcess($appId, 'request a token as the deployment identity and read the scope')) {
    # This does NOT run "az login --service-principal": that would replace YOUR session in
    # the shared CLI profile and log you out. It asks Entra for a token directly and reads
    # the resource group with it, retrying while the new identity replicates.
    Write-Host '      ..    a new identity takes 10-60 s to replicate; retrying until it answers' -ForegroundColor DarkGray
    $t = Test-AfsServicePrincipal -TenantId $acct.tenantId -AppId $appId -Secret $secret -Scope $scope
    if ($t.Ok) {
        $identityVerified = $true
        Write-Ok ("the identity can sign in and read " + $cfg.resourceGroup + " (ready after " + $t.Attempts + " attempt(s)) - phase 2 will run unattended")
    } else {
        Write-Warn2 ('the identity is not usable yet: ' + $t.Detail)
        Write-Warn2 'this is usually replication delay. Wait a minute and run phase 2 with -WhatIf; it re-tests before building.'
    }
} else {
    Write-Warn2 'sign-in test skipped (federated identity, or a what-if run)'
}
Write-Ok ("your own session is untouched: still signed in as " + $acct.user.name)

Write-Host ''
Write-Host '=============================' -ForegroundColor White
Complete-AfsProgress -Activity $script:ProgressActivity
Write-AfsPhaseStrip -Done $script:StepTotal -Total $script:StepTotal
Write-Host 'Phase 1 complete.' -ForegroundColor Green
Write-Host ''
Write-Host 'Phase 2 needs no human input:' -ForegroundColor White
Write-Host ("  .\Deploy-AfsEnvironment.ps1 -Context " + $ContextFile + " -WhatIf")
Write-Host ("  .\Deploy-AfsEnvironment.ps1 -Context " + $ContextFile)
Write-Host ''
Write-Host 'Verify the grant independently:' -ForegroundColor White
Write-Host ("  az role assignment list --assignee " + $appId + " --scope " + $scope + " -o table")
Write-Host ''
