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
    Verbose  same console, az adds --verbose            az: --verbose  (request/response summary)
    Debug    console adds DEBUG lines, az adds --debug  az: --debug    (full HTTP traces)

  The Azure CLI writes its --verbose/--debug chatter to stderr. It is captured and written to
  the log file at DEBUG, never to the console, so a Debug run stays readable on screen while
  the log holds the full trace.

  Everything is exported through environment variables (AFS_LOG_FILE, AFS_LOG_JSONL,
  AFS_LOG_LEVEL) so a script launched by the wizard writes into the same run's files, and a
  script run on its own starts a log of its own.
#>

Set-StrictMode -Version 2.0

$script:AfsLogRank = @{ DEBUG = 10; INFO = 20; STEP = 25; WARN = 30; ERROR = 40 }

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
    if (-not (Test-Path $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $base  = Join-Path $Directory ("{0}-{1}" -f $Name, $stamp)

    $env:AFS_LOG_FILE  = "$base.log"
    $env:AFS_LOG_JSONL = "$base.jsonl"
    $env:AFS_LOG_LEVEL = $Level
    $env:AFS_LOG_RUN   = "$Name-$stamp"

    # the transcript catches anything our own logging did not - including a crash in code
    # that runs before or outside a try block
    try { Start-Transcript -Path "$base.transcript.txt" -Append -ErrorAction SilentlyContinue | Out-Null } catch { }

    $azv = $null
    try { $azv = (& az version -o json 2>$null | ConvertFrom-Json).'azure-cli' } catch { }
    $who = $null
    try { $who = (& az account show --query user.name -o tsv 2>$null) } catch { }

    Write-AfsLog -Level INFO -Message ("log started: run={0} level={1}" -f $env:AFS_LOG_RUN, $Level) -Data @{
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
        Add-Content -Path $env:AFS_LOG_FILE -Value ("{0} [{1,-5}] {2}" -f $ts, $Level, $Message) -Encoding ascii
    } catch { }

    try {
        $rec = [ordered]@{ ts = $ts; run = $env:AFS_LOG_RUN; level = $Level; msg = $Message }
        if ($Data) { foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] } }
        Add-Content -Path $env:AFS_LOG_JSONL -Value ($rec | ConvertTo-Json -Compress -Depth 5) -Encoding ascii
    } catch { }

    # the scripts already print INFO/STEP/WARN/ERROR themselves; only DEBUG needs a console
    # echo, and only when someone asked for it
    if ($Level -eq 'DEBUG' -and $env:AFS_LOG_LEVEL -eq 'Debug') {
        Write-Host ("      dbg   " + $Message) -ForegroundColor DarkGray
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
    $all = @($Args) + @($extra)

    Write-AfsLog -Level DEBUG -Message ("run  " + $shown)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @all 2>&1
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
            if ($line.Trim()) { Write-AfsLog -Level DEBUG -Message ("  cli  " + $line.Trim()) }
        }
    }

    if ($code -ne 0) {
        $err = ($chatter + $stdout | Out-String).Trim()
        Write-AfsLog -Level ERROR -Message ("fail " + $shown + " -> exit " + $code + " in " + $sw.ElapsedMilliseconds + " ms") -Data @{
            exit = $code; ms = $sw.ElapsedMilliseconds
            stderr = $err.Substring(0, [Math]::Min(4000, $err.Length))
        }
        if ($AllowFailure) { return $null }
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