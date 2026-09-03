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

function Write-Step  { param([string]$T) Write-Host ''; Write-Host ("-> " + $T) -ForegroundColor Cyan }
function Write-Ok    { param([string]$T) Write-Host ("   OK   " + $T) -ForegroundColor Green }
function Write-Warn2 { param([string]$T) Write-Host ("   WARN " + $T) -ForegroundColor Yellow }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFailure)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & az @Args 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        throw ("az " + ($Args -join ' ') + "`n" + (($out | Out-String).Trim()))
    }
    $out = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $text = ($out | Out-String).Trim()
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $text }
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
Invoke-Az @('account', 'set', '--subscription', $cfg.subscriptionId) -AllowFailure | Out-Null
Write-Ok 'subscription set'

# ------------------------------------------------------------ write probe ---

Write-Step 'Establishing write access, and the resource group'
$rg = Invoke-Az @('group', 'show', '-n', $cfg.resourceGroup, '-o', 'json') -AllowFailure
if ($rg) {
    Write-Ok "resource group $($cfg.resourceGroup) already exists"
} elseif ($PSCmdlet.ShouldProcess($cfg.resourceGroup, 'create resource group')) {
    $made = Invoke-Az @('group', 'create', '-n', $cfg.resourceGroup, '-l', $cfg.location,
        '--tags', 'purpose=azure-file-sync', "prefix=$($cfg.namePrefix)", '-o', 'json') -AllowFailure
    if (-not $made) {
        Write-Host ''
        Write-Warn2 'the resource group could not be created. The two usual causes:'
        Write-Host '     RequestDisallowedByAzure -> this session has not completed MFA.' -ForegroundColor Yellow
        Write-Host '                                 run:  az logout   then   az login' -ForegroundColor Yellow
        Write-Host '     AuthorizationFailed      -> the account is not Owner/Contributor here.' -ForegroundColor Yellow
        Write-Host ''
        throw 'Write access could not be established. Nothing was created.'
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
    $app = Invoke-Az @('ad', 'app', 'create', '--display-name', $IdentityName, '-o', 'json') -AllowFailure
    if (-not $app) { throw "Could not create the Entra application. The administrator needs Application Administrator or higher." }
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
        Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $spOid,
            '--assignee-principal-type', 'ServicePrincipal', '--role', $Role,
            '--scope', $scope, '-o', 'none') -AllowFailure | Out-Null
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
        secretFile  = $(if ($secret) { Split-Path -Leaf $SecretFile } else { $null })
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
if ($secret -and $appId -and $PSCmdlet.ShouldProcess($appId, 'sign in as the deployment identity')) {
    Invoke-Az @('logout') -AllowFailure | Out-Null
    $ok = Invoke-Az @('login', '--service-principal', '-u', $appId, '-p', $secret,
        '--tenant', $acct.tenantId, '--only-show-errors', '-o', 'json') -AllowFailure
    if ($ok) {
        Invoke-Az @('account', 'set', '--subscription', $cfg.subscriptionId) -AllowFailure | Out-Null
        $seen = Invoke-Az @('group', 'show', '-n', $cfg.resourceGroup, '--query', 'name', '-o', 'tsv') -AllowFailure
        if ($seen) { Write-Ok "the identity can reach $seen - phase 2 will run unattended" }
        else { Write-Warn2 'signed in, but the scope is not visible yet. Role assignments can take a minute to propagate; re-check before running phase 2.' }
    } else {
        Write-Warn2 'could not sign in as the new identity. Check the secret and tenant.'
    }
} else {
    Write-Warn2 'sign-in test skipped (federated identity, or a what-if run)'
}

Write-Host ''
Write-Host '=============================' -ForegroundColor White
Write-Host 'Phase 1 complete.' -ForegroundColor Green
Write-Host ''
Write-Host 'Phase 2 needs no human input:' -ForegroundColor White
Write-Host ("  .\Deploy-AfsEnvironment.ps1 -Context " + $ContextFile + " -WhatIf")
Write-Host ("  .\Deploy-AfsEnvironment.ps1 -Context " + $ContextFile)
Write-Host ''
Write-Host 'Verify the grant independently:' -ForegroundColor White
Write-Host ("  az role assignment list --assignee " + $appId + " --scope " + $scope + " -o table")
Write-Host ''
