<#
  Shared logging. Dot-sourced by the wizard and by every deploy script.

  Three outputs per run, all under <repo>/logs/:
    <name>-<stamp>.log             human-readable, one line per event, timestamped in UTC
    <name>-<stamp>.jsonl           one JSON object per event, for telemetry and tooling
    <name>-<stamp>.transcript.txt  everything the console showed, captured by Start-Transcript,
                                   so a crash is recorded even if it happened outside our code

  Levels, in order: DEBUG < INFO < STEP < WARN < ERROR.
  The log file always receives everything. The level chooses what the console also shows and
  how chatty the Azure CLI is asked to be:
    Quiet    console shows WARN and ERROR only          az: --only-show-errors
    Normal   console shows what the scripts print       az: default
    Verbose  adds every command WE run and its result   az: --verbose
    Debug    adds the CLI's own output as well          az: --debug    (full HTTP traces)

  The difference between Verbose and Debug is the one that matters in practice. Verbose shows
  what this kit did - the command, the exit code, how long it took. Debug also shows what the
  Azure CLI said while doing it, which runs to hundreds of lines per call and buries the steps
  it is meant to explain. Both are written to the log file in full either way; the level only
  decides what reaches the screen.

  Each step is timed. The elapsed time prints under the step it belongs to, and a run ends with
  a total and the three steps that cost the most. Set AFS_STEP_PAUSE to a number of seconds to
  slow a run down for a demo; it is off by default.

  Everything is exported through environment variables (AFS_LOG_FILE, AFS_LOG_JSONL,
  AFS_LOG_LEVEL) so a script launched by the wizard writes into the same run's files, and a
  script run on its own starts a log of its own.
#>

Set-StrictMode -Version 2.0

$script:AfsLogRank = @{ DEBUG = 10; INFO = 20; STEP = 25; WARN = 30; ERROR = 40 }
$script:AfsAzLauncher = $null

function Get-AfsAzLauncher {
    <# How to start the Azure CLI. The Windows MSI install's az.cmd is one batch block:
         IF EXIST "..\python.exe" ( "..\python.exe" -IBm azure.cli %* ) ELSE ( ... )
       so a ')' inside ANY argument - every JMESPath function call has one: length(@),
       contains(...), join(...) - closes that block early and the command dies with
       "-o was unexpected at this time" (exit 255). Two live-run steps read nothing because of
       it. Calling the bundled python directly skips the batch layer; any other install
       (az.exe, pip, Linux, macOS) is used as found. Resolved once per process. #>
    if ($script:AfsAzLauncher) { return $script:AfsAzLauncher }
    $exe = 'az'; $prefix = @()
    try {
        $cmd = Get-Command az -ErrorAction Stop | Select-Object -First 1
        if ($cmd.Source -and $cmd.Source -like '*.cmd') {
            $py = Join-Path (Split-Path -Parent (Split-Path -Parent $cmd.Source)) 'python.exe'
            if (Test-Path $py) { $exe = $py; $prefix = @('-IBm', 'azure.cli'); $env:AZ_INSTALLER = 'MSI' }
        }
    } catch { }
    $script:AfsAzLauncher = @{ Exe = $exe; Prefix = $prefix }
    return $script:AfsAzLauncher
}

function Get-AfsLogDirectory {
    # <repo>/logs - this file lives in <repo>/deploy
    $repo = Split-Path -Parent $PSScriptRoot
    return (Join-Path $repo 'logs')
}

function Start-AfsLog {
    param(
        [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')][string]$Level = 'Verbose',
        [string]$Name = 'afs',
        [string]$Directory
    )
    if (-not $Directory) { $Directory = Get-AfsLogDirectory }
    if (-not (Test-Path $Directory)) { New-Item -ItemType Directory -Path $Directory -Force -WhatIf:$false -Confirm:$false | Out-Null }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $base  = Join-Path $Directory ("{0}-{1}" -f $Name, $stamp)

    $env:AFS_LOG_FILE  = "$base.log"
    $env:AFS_LOG_JSONL = "$base.jsonl"
    $env:AFS_LOG_LEVEL = $Level
    $env:AFS_LOG_RUN   = "$Name-$stamp"

    # the transcript catches anything our own logging did not - including a crash in code
    # that runs before or outside a try block
    try { Start-Transcript -Path "$base.transcript.txt" -Append -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }

    $azv = $null
    try { $azv = (& az version -o json 2>$null | ConvertFrom-Json).'azure-cli' } catch { }
    $who = $null
    try { $who = (& az account show --query user.name -o tsv 2>$null) } catch { }

    Write-AfsLog -Level INFO -Message ("log started: run={0} level={1} version={2}" -f $env:AFS_LOG_RUN, $Level, $script:AfsProductVersion) -Data @{
        version    = $script:AfsProductVersion
        powershell = $PSVersionTable.PSVersion.ToString()
        azureCli   = $azv
        account    = $who
        cwd        = (Get-Location).Path
        host       = $Host.Name
        machine    = $env:COMPUTERNAME
    }
    return $env:AFS_LOG_FILE
}

function Stop-AfsLog {
    param([string]$Outcome = 'ended')
    if ($env:AFS_LOG_FILE) { Write-AfsLog -Level INFO -Message ("log " + $Outcome) }
    # Stop-Transcript has no -WhatIf; only Start-Transcript needs the preference override
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
}

function Write-AfsLog {
    param(
        [ValidateSet('DEBUG', 'INFO', 'STEP', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data
    )
    # no-op when no log is active, so every script also runs unchanged without one
    if (-not $env:AFS_LOG_FILE) { return }

    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    try {
        Add-Content -Path $env:AFS_LOG_FILE -Value ("{0} [{1,-5}] {2}" -f $ts, $Level, $Message) -Encoding ascii -WhatIf:$false -Confirm:$false
    } catch { }

    try {
        $rec = [ordered]@{ ts = $ts; run = $env:AFS_LOG_RUN; level = $Level; msg = $Message }
        if ($Data) { foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] } }
        Add-Content -Path $env:AFS_LOG_JSONL -Value ($rec | ConvertTo-Json -Compress -Depth 5) -Encoding ascii -WhatIf:$false -Confirm:$false
    } catch { }

    # the scripts already print INFO/STEP/WARN/ERROR themselves. DEBUG carries every command,
    # its result, and the CLI's own --verbose/--debug output - and at Verbose or Debug the
    # operator asked to SEE that, so it is echoed to the console as well as filed.
    if ($Level -eq 'DEBUG' -and $env:AFS_LOG_LEVEL -in @('Verbose', 'Debug')) {
        # Verbose means "show me what this script is doing" - the commands it runs and how
        # they came back. It does not mean "show me the Azure CLI's internal commentary",
        # which is hundreds of lines per call and buries the steps. That stays in the file,
        # where it is wanted, and only Debug puts it on screen as well.
        if ($env:AFS_LOG_LEVEL -eq 'Debug' -or $Message -notlike 'cli  *') {
            Write-Host ("      | " + $Message) -ForegroundColor DarkGray
        }
    }
}

function Write-AfsLogException {
    <# Record a thrown error with everything needed to find it: message, the script line that
       threw, and the stack. This is the line to look for after a crash. #>
    param([Parameter(Mandatory)]$ErrorRecord, [string]$Context = 'unhandled error')
    $e = $ErrorRecord
    $where = ''
    try { $where = $e.InvocationInfo.PositionMessage } catch { }
    $stack = ''
    try { $stack = $e.ScriptStackTrace } catch { }
    Write-AfsLog -Level ERROR -Message ("{0}: {1}" -f $Context, $e.Exception.Message) -Data @{
        exceptionType = $e.Exception.GetType().FullName
        where         = $where
        stack         = $stack
        category      = $e.CategoryInfo.ToString()
        fullyQualifiedErrorId = $e.FullyQualifiedErrorId
    }
}

function Get-AfsAzVerbosityArgs {
    switch ($env:AFS_LOG_LEVEL) {
        'Debug'   { return @('--debug') }
        'Verbose' { return @('--verbose') }
        'Quiet'   { return @('--only-show-errors') }
        default   { return @() }
    }
}

function Invoke-AfsAz {
    <#
      The one place every Azure CLI call goes through. Logs the command, the exit code, how
      long it took, and on failure the full stderr. With Verbose/Debug the CLI's own chatter
      is written to the log at DEBUG and kept off the console.
    #>
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFailure)

    $shown = 'az ' + ($Args -join ' ')
    # never let a secret reach the log
    $shown = [regex]::Replace($shown, '(-p|--password|--client-secret)\s+\S+', '$1 ***')
    $shown = [regex]::Replace($shown, '--claims-challenge\s+"[^"]+"', '--claims-challenge "***"')

    $extra = Get-AfsAzVerbosityArgs
    # the CLI refuses --verbose/--debug alongside --only-show-errors, so a command that asks
    # for quiet output (sign-in does) must not have verbosity appended
    if ($Args -contains '--only-show-errors') {
        $extra = @($extra | Where-Object { $_ -ne '--verbose' -and $_ -ne '--debug' })
    }
    $all = @($Args) + @($extra)

    # Pin every call to the subscription this run resolved. The CLI's default subscription
    # lives in a profile SHARED by every window on the machine, so an 'az login' or
    # 'az account set' somewhere else in the middle of a build silently retargets the next
    # call - the first live run lost a share's backup protection to exactly that. Commands
    # that take no --subscription are left alone.
    $noSub = @('login', 'logout', 'account', 'extension', 'version', 'config', 'configure', 'upgrade', 'find', 'feedback', 'interactive', 'ad', 'rest', 'cloud', 'self-test')
    if ($env:AFS_SUBSCRIPTION_ID -and ($Args -notcontains '--subscription') -and ($noSub -notcontains $Args[0])) {
        $all += @('--subscription', $env:AFS_SUBSCRIPTION_ID)
        $shown += ' --subscription ' + $env:AFS_SUBSCRIPTION_ID
    }

    Write-AfsLog -Level DEBUG -Message ("run  " + $shown)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $launcher = Get-AfsAzLauncher
        $argv = @($launcher.Prefix) + @($all)
        $out = & $launcher.Exe @argv 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $sw.Stop()

    $chatter = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    $stdout  = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

    if ($chatter.Count -and $env:AFS_LOG_LEVEL -in @('Verbose', 'Debug')) {
        # the CLI's --verbose/--debug output, kept in the file only
        foreach ($line in ($chatter | Select-Object -First 400)) {
            if ($line.Trim()) { Write-AfsLog -Level DEBUG -Message ("cli  " + $line.Trim()) }
        }
    }

    if ($code -ne 0) {
        $err = ($chatter + $stdout | Out-String).Trim()
        if ($AllowFailure) {
            # an expected "no" from an existence probe, not a failure - keep it out of ERROR
            Write-AfsLog -Level DEBUG -Message ("probe " + $shown + " -> exit " + $code + " (tolerated) in " + $sw.ElapsedMilliseconds + " ms") -Data @{
                exit = $code; ms = $sw.ElapsedMilliseconds; tolerated = $true
                stderr = $err.Substring(0, [Math]::Min(1000, $err.Length))
            }
            return $null
        }
        Write-AfsLog -Level ERROR -Message ("fail " + $shown + " -> exit " + $code + " in " + $sw.ElapsedMilliseconds + " ms") -Data @{
            exit = $code; ms = $sw.ElapsedMilliseconds
            stderr = $err.Substring(0, [Math]::Min(4000, $err.Length))
        }
        if (Get-Command Show-AzureFailure -ErrorAction SilentlyContinue) {
            Show-AzureFailure -Message $err -Context ("Failed: " + $shown)
        }
        throw ($shown + "`n" + $err)
    }

    Write-AfsLog -Level DEBUG -Message ("ok   " + $shown + " in " + $sw.ElapsedMilliseconds + " ms") -Data @{ exit = 0; ms = $sw.ElapsedMilliseconds }

    $text = ($stdout | Out-String).Trim()
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $text }
}

function Test-AfsServicePrincipal {
    <#
      .SYNOPSIS
        Prove a freshly created service principal can sign in and read its scope - WITHOUT
        touching the operator's own Azure CLI session.

      .DESCRIPTION
        "az login --service-principal" replaces the current account in the shared CLI profile,
        so testing that way logs the human out. This asks Entra for a token directly with the
        client-credentials grant and then reads the scope over REST with that token.

        A new application, service principal and secret take a while to replicate - typically
        10 to 60 seconds, occasionally longer - and sign-in fails with AADSTS7000215 or
        AADSTS700016 until they have. So it retries, and says so, rather than reporting a
        failure that would have succeeded a minute later.
    #>
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][string]$Scope,     # e.g. /subscriptions/<id>/resourceGroups/<rg>
        [int]$MaxAttempts = 12,
        [int]$DelaySeconds = 10
    )
    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $AppId
        client_secret = $Secret
        scope         = 'https://management.azure.com/.default'
        grant_type    = 'client_credentials'
    }
    $lastErr = ''
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $tok = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
            if ($tok -and $tok.access_token) {
                Write-AfsLog -Level DEBUG -Message ("sp token acquired on attempt " + $i)
                $uri = "https://management.azure.com$Scope" + "?api-version=2022-09-01"
                try {
                    $r = Invoke-WebRequest -Method Get -Uri $uri -Headers @{ Authorization = 'Bearer ' + $tok.access_token } -UseBasicParsing -ErrorAction Stop
                    if ($r.StatusCode -eq 200) {
                        Write-AfsLog -Level INFO -Message ("service principal " + $AppId + " can read " + $Scope + " (attempt " + $i + ")")
                        return [pscustomobject]@{ Ok = $true; Attempts = $i; Detail = 'token acquired and scope readable' }
                    }
                    $lastErr = "scope read returned HTTP " + $r.StatusCode
                } catch {
                    # the token is good but the role has not propagated yet - keep waiting
                    $lastErr = "scope read failed: " + $_.Exception.Message
                }
            }
        } catch {
            $lastErr = $_.Exception.Message
            try {
                $resp = $_.Exception.Response
                if ($resp) {
                    $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $lastErr = $sr.ReadToEnd(); $sr.Close()
                }
            } catch { }
        }
        Write-AfsLog -Level DEBUG -Message ("sp test attempt " + $i + "/" + $MaxAttempts + " not ready: " + $lastErr.Substring(0, [Math]::Min(160, $lastErr.Length)))
        if ($i -lt $MaxAttempts) {
            Write-Host ("      ..    identity not usable yet (attempt " + $i + "/" + $MaxAttempts + ") - waiting " + $DelaySeconds + " s for Entra to replicate") -ForegroundColor DarkGray
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    Write-AfsLog -Level WARN -Message ("service principal " + $AppId + " still not usable after " + $MaxAttempts + " attempts: " + $lastErr)
    return [pscustomobject]@{ Ok = $false; Attempts = $MaxAttempts; Detail = $lastErr }
}

# ---- Progress -------------------------------------------------------------------------
# A real console progress bar (Write-Progress) plus an inline strip, in the same style as the
# other operator tools: "[############............]  7/17 steps". Block glyphs are built from
# char codes so this file stays strictly ASCII. Never written to the log - the STEP line is.

$script:AfsStepClock = $null
$script:AfsStepLabel = $null
$script:AfsRunClock  = $null
$script:AfsStepTimes = New-Object System.Collections.ArrayList

# ============================================================ product stamp ==
#  V YYYY.MM.DD.NNN - the date of the change, then its ordinal on that day.
#  THIS IS THE ONE PLACE THE VERSION LIVES. The banner, the run logs, the as-built and any
#  shipped zip read it from here. Bump it with every change and record the change in
#  docs/VERSION-CONTROL.md - same scheme as the sibling Server-Ops product, deliberately.
$script:AfsProductName    = 'Luca AZ Consulting Helper'
$script:AfsProductVersion = 'V 2026.09.10.002'
$script:AfsProductAuthor  = 'Gustavo Assuncao'

function Get-AfsProductInfo {
    return [pscustomobject]@{ Name = $script:AfsProductName; Version = $script:AfsProductVersion; Author = $script:AfsProductAuthor }
}

function Format-AfsDuration {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 1)  { return ('{0:N0} ms' -f $Span.TotalMilliseconds) }
    if ($Span.TotalSeconds -lt 90) { return ('{0:N1} s' -f $Span.TotalSeconds) }
    return ('{0:N0} m {1:00} s' -f [math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Write-AfsStepTimer {
    <#  Called by each script's step function BEFORE it prints its own header, so the line
        lands under the step that just finished rather than the one about to start. Without
        this a run is a wall of steps with no sense of which one cost the time. #>
    param([string]$Label)
    $now = Get-Date
    if (-not $script:AfsRunClock) { $script:AfsRunClock = $now }
    if ($script:AfsStepLabel) {
        $d = $now - $script:AfsStepClock
        [void]$script:AfsStepTimes.Add([pscustomobject]@{ Step = $script:AfsStepLabel; Span = $d })
        Write-AfsLog -Level INFO -Message ('step done: ' + $script:AfsStepLabel + ' in ' + (Format-AfsDuration $d))
        Write-Host ('            ' + (Format-AfsDuration $d)) -ForegroundColor DarkGray
    }
    $script:AfsStepLabel = $Label
    $script:AfsStepClock = $now
    # A demo needs time to read what just happened; automation does not. Off unless asked.
    if ($env:AFS_STEP_PAUSE) {
        $p = 0.0
        if ([double]::TryParse($env:AFS_STEP_PAUSE, [ref]$p) -and $p -gt 0) { Start-Sleep -Milliseconds ([int]($p * 1000)) }
    }
}

function Write-AfsRunSummary {
    <# Close the last step and say where the time actually went. #>
    param([string]$Outcome)
    $now = Get-Date
    if ($script:AfsStepLabel) {
        $d = $now - $script:AfsStepClock
        [void]$script:AfsStepTimes.Add([pscustomobject]@{ Step = $script:AfsStepLabel; Span = $d })
        Write-AfsLog -Level INFO -Message ('step done: ' + $script:AfsStepLabel + ' in ' + (Format-AfsDuration $d))
        Write-Host ('            ' + (Format-AfsDuration $d)) -ForegroundColor DarkGray
        $script:AfsStepLabel = $null
    }
    if (-not $script:AfsRunClock) { return }
    $total = $now - $script:AfsRunClock
    Write-AfsLog -Level INFO -Message ('run finished in ' + (Format-AfsDuration $total) + $(if ($Outcome) { ' - ' + $Outcome } else { '' }))
    Write-Host ''
    Write-Host ('  Took ' + (Format-AfsDuration $total) + ' in total.') -ForegroundColor White
    $slow = @($script:AfsStepTimes | Sort-Object { $_.Span.TotalSeconds } -Descending | Select-Object -First 3 | Where-Object { $_.Span.TotalSeconds -ge 1 })
    if ($slow.Count) {
        Write-Host '  Where it went:' -ForegroundColor DarkGray
        foreach ($x in $slow) { Write-Host ('    ' + (Format-AfsDuration $x.Span).PadLeft(9) + '  ' + $x.Step) -ForegroundColor DarkGray }
    }
}

function Write-AfsProgress {
    param(
        [Parameter(Mandatory)][string]$Activity,   # stable across a run, e.g. 'Azure File Sync deployment'
        [Parameter(Mandatory)][string]$Status,     # what is happening right now
        [int]$Step = -1, [int]$Total = -1,         # determinate bar when both are given
        [int]$Id = 0
    )
    $p = @{ Activity = $Activity; Status = $Status; Id = $Id }
    if ($Step -ge 0 -and $Total -gt 0) {
        $pct = [int][Math]::Min(100, [Math]::Max(0, [Math]::Round(($Step / [double]$Total) * 100)))
        $p.PercentComplete  = $pct
        $p.CurrentOperation = ("step {0} of {1}  ({2}%)" -f $Step, $Total, $pct)
    }
    try { Write-Progress @p } catch { }
}

function Complete-AfsProgress {
    param([string]$Activity = 'Working', [int]$Id = 0)
    try { Write-Progress -Activity $Activity -Id $Id -Completed } catch { }
}

function Write-AfsPhaseStrip {
    param([Parameter(Mandatory)][int]$Done, [Parameter(Mandatory)][int]$Total, [int]$Width = 26, [string]$Label = 'steps')
    if ($Total -le 0) { return }
    $full  = [string][char]0x2588   # solid block
    $faint = [string][char]0x2591   # light shade
    $n = [int][Math]::Round(($Done / [double]$Total) * $Width)
    if ($n -lt 0) { $n = 0 }; if ($n -gt $Width) { $n = $Width }
    Write-Host '  ' -NoNewline
    Write-Host '[' -NoNewline -ForegroundColor DarkCyan
    if ($n -gt 0) { Write-Host ($full * $n) -NoNewline -ForegroundColor Cyan }
    if ($n -lt $Width) { Write-Host ($faint * ($Width - $n)) -NoNewline -ForegroundColor DarkGray }
    Write-Host ']' -NoNewline -ForegroundColor DarkCyan
    Write-Host ("  {0}/{1} {2}" -f $Done, $Total, $Label) -ForegroundColor DarkGray
}
