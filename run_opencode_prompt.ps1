#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Launches opencode with an orchestrator prompt and monitors for idle activity.
.DESCRIPTION
    PowerShell 7+ equivalent of run_opencode_prompt.sh.
    This script is designed to run inside a Linux devcontainer with pwsh.
    It is not intended for direct Windows/macOS host execution because its
    process-management and watchdog logic rely on Linux userland tools.

    Features:
    - Parameter parsing and validation (same behaviour as bash version)
    - Token validation and OAuth scope checking via gh CLI
    - Auth URL embedding for basic auth
    - Real-time output streaming with prefix tagging
    - Server log streaming with noise filtering
    - Watchdog idle detection with split read/write I/O tracking via /proc
    - Hard ceiling timeout (90 minutes)
    - Clean process cleanup and exit code propagation
.EXAMPLE
    ./run_opencode_prompt.ps1 -File prompt.md
.EXAMPLE
    ./run_opencode_prompt.ps1 -Prompt "Implement feature X" -AttachUrl https://host:4096 -AuthUser bot -AuthPass s3cret
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Read prompt from file')]
    [string]$File,

    [Parameter(HelpMessage = 'Use prompt string directly')]
    [string]$Prompt,

    [Parameter(HelpMessage = 'Attach to a running opencode server (e.g. https://host:4096)')]
    [string]$AttachUrl,

    [Parameter(HelpMessage = 'Basic auth username (prefer env var OPENCODE_AUTH_USER)')]
    [string]$AuthUser,

    [Parameter(HelpMessage = 'Basic auth password (prefer env var OPENCODE_AUTH_PASS)')]
    [string]$AuthPass,

    [Parameter(HelpMessage = 'Working directory on the server (used with -AttachUrl)')]
    [string]$WorkDir,

    [Parameter(HelpMessage = 'opencode log level (DEBUG|INFO|WARN|ERROR), default: INFO')]
    [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
    [string]$LogLevel = 'INFO',

    [Parameter(HelpMessage = 'Enable --print-logs (defaults to on; pass -PrintLogs:$false to suppress)')]
    [switch]$PrintLogs
)

$ErrorActionPreference = 'Stop'

if (-not $IsLinux) {
    Write-Host '::error::run_opencode_prompt.ps1 is designed for Linux devcontainer environments only'
    exit 1
}

# ── Constants ──────────────────────────────────────────────────────────────────
$IDLE_TIMEOUT_SECS    = 900    # 15 min of total I/O silence → kill
$READ_ONLY_GRACE_SECS = 1200   # 20 min with reads-only (no writes) → kill
$HARD_CEILING_SECS    = 5400   # 90-minute absolute safety net

# ── Helpers ────────────────────────────────────────────────────────────────────
function Get-EpochSeconds { [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Send-Signal ([int]$ProcessId, [string]$Signal = 'TERM') {
    if ($Signal -eq 'KILL') {
        bash -c "kill -9 $ProcessId 2>/dev/null" | Out-Null
    } else {
        bash -c "kill $ProcessId 2>/dev/null" | Out-Null
    }
}

function Test-ProcessAlive ([int]$ProcessId) {
    bash -c "kill -0 $ProcessId 2>/dev/null"
    return ($LASTEXITCODE -eq 0)
}

# Shell-escape a single string for inclusion inside single quotes in bash.
function ConvertTo-BashSingleQuoted ([string]$Value) {
    # Replace every ' with the end-quote, escaped-quote, start-quote sequence.
    "'" + $Value.Replace("'", "'\''") + "'"
}

function Show-Usage {
    @"
Usage: run_opencode_prompt.ps1 -File <file> | -Prompt <prompt> [-AttachUrl <url>] [-AuthUser <user>] [-AuthPass <pass>] [-WorkDir <dir>] [-LogLevel <level>] [-PrintLogs]
  -File       <file>    Read prompt from file
  -Prompt     <prompt>  Use prompt string directly
  -AttachUrl  <url>     Attach to a running opencode server (e.g. https://host:4096)
  -AuthUser   <user>    Basic auth username (prefer env var OPENCODE_AUTH_USER)
  -AuthPass   <pass>    Basic auth password (prefer env var OPENCODE_AUTH_PASS)
  -WorkDir    <dir>     Working directory on the server (used with -AttachUrl)
  -LogLevel   <level>   opencode log level (DEBUG|INFO|WARN|ERROR), default: INFO
  -PrintLogs            Enable --print-logs

  Credentials are resolved in order: flags > env vars OPENCODE_AUTH_USER / OPENCODE_AUTH_PASS
"@ | Write-Host
    exit 1
}

# ── Resolve prompt ─────────────────────────────────────────────────────────────
if ($File) {
    if (-not (Test-Path -LiteralPath $File)) {
        Write-Host "::error::Prompt file not found: $File"
        exit 1
    }
    $Prompt = Get-Content -LiteralPath $File -Raw
}
if (-not $Prompt) { Show-Usage }

# ── Resolve auth credentials (env vars as defaults, flags override) ────────────
if (-not $AuthUser -and $env:OPENCODE_AUTH_USER) { $AuthUser = $env:OPENCODE_AUTH_USER }
if (-not $AuthPass -and $env:OPENCODE_AUTH_PASS) { $AuthPass = $env:OPENCODE_AUTH_PASS }

# ── Validate required API keys ─────────────────────────────────────────────────
if (-not $env:ZHIPU_API_KEY) {
    Write-Host '::error::ZHIPU_API_KEY is not set'
    exit 1
}
if (-not $env:KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY) {
    Write-Host '::error::KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY is not set'
    exit 1
}
if (-not $env:GH_ORCHESTRATION_AGENT_TOKEN) {
    Write-Host '::error::GH_ORCHESTRATION_AGENT_TOKEN is not set — orchestrator execution requires this token'
    Write-Host '::error::Configure it as an org or repo secret with scopes: repo, workflow, project, read:org'
    exit 1
}
Write-Host 'Using GH_ORCHESTRATION_AGENT_TOKEN for authentication'

# Export under all names that tools (gh CLI, MCP servers, opencode) may read.
$env:GH_TOKEN                     = $env:GH_ORCHESTRATION_AGENT_TOKEN
$env:GITHUB_TOKEN                 = $env:GH_ORCHESTRATION_AGENT_TOKEN
$env:GITHUB_PERSONAL_ACCESS_TOKEN = $env:GH_ORCHESTRATION_AGENT_TOKEN
$env:OPENCODE_EXPERIMENTAL        = '1'

# ── Token scope validation ─────────────────────────────────────────────────────
# --include surfaces response headers; X-OAuth-Scopes lists granted scopes.
$apiResponse = ''
try {
    $apiResponse = (& gh api rate_limit --include 2>&1) -join "`n"
} catch {
    $apiResponse = $_.Exception.Message
}
if ($apiResponse -notmatch '(?m)^HTTP') {
    Write-Host '::error::gh CLI token validation failed — unexpected response:'
    Write-Host $apiResponse
    exit 1
}
Write-Host 'gh CLI token validation succeeded'

$grantedScopes = ''
if ($apiResponse -match '(?mi)^X-OAuth-Scopes:\s*(.+)$') {
    $grantedScopes = $Matches[1].Trim().TrimEnd("`r")
}
Write-Host "Granted OAuth scopes: $(if ($grantedScopes) { $grantedScopes } else { '<none>' })"

$scopeTokens = if ($grantedScopes) {
    $grantedScopes -split '[,\s]+' | Where-Object { $_ }
} else { @() }

$requiredScopes = @('repo', 'workflow', 'project', 'read:org')
$missingScopes  = $requiredScopes | Where-Object { $_ -notin $scopeTokens }

if ($missingScopes.Count -gt 0) {
    Write-Host "::error::GH_ORCHESTRATION_AGENT_TOKEN is missing required scopes: $($missingScopes -join ', ')"
    Write-Host "::error::Required: $($requiredScopes -join ', ')  |  Granted: $grantedScopes"
    exit 1
}
Write-Host "All required scopes verified: $($requiredScopes -join ' ')"

# ── Auth URL embedding ─────────────────────────────────────────────────────────
if ($AttachUrl -and $AuthUser -and $AuthPass) {
    if ($AttachUrl -match '^http://') {
        Write-Host '::warning::Basic auth credentials over http:// are sent in plaintext — use https://'
    }
    if ($AttachUrl -match '^([^:]+)://(.+)$') {
        $scheme = $Matches[1]
        $rest   = $Matches[2]
        $AttachUrl = "${scheme}://${AuthUser}:${AuthPass}@${rest}"
    }
} elseif (($AuthUser -or $AuthPass) -and -not $AttachUrl) {
    Write-Host '::error::OPENCODE_AUTH_USER/PASS (or -AuthUser/-AuthPass) require -AttachUrl <url>'
    exit 1
}

# ── Debug mode ─────────────────────────────────────────────────────────────────
$formatFlag = @()
if ($env:DEBUG_ORCHESTRATOR -eq 'true') {
    $LogLevel   = 'DEBUG'
    $formatFlag = @('--format', 'json')
    Write-Host '[debug] DEBUG_ORCHESTRATOR=true — enabling verbose output'
}

# ── Build opencode args ───────────────────────────────────────────────────────
# print_logs is always enabled (matching bash default behaviour where it is
# initialised to "--print-logs" and the -L flag is effectively a no-op).
$opencodeArgs = [System.Collections.Generic.List[string]]::new()
$opencodeArgs.AddRange([string[]]@(
    'run',
    '--model',     'zai-coding-plan/glm-5',
    '--agent',     'orchestrator',
    '--log-level', $LogLevel,
    '--thinking'
))
$shouldPrintLogs = $PrintLogs.IsPresent -or -not $PSBoundParameters.ContainsKey('PrintLogs')
if ($shouldPrintLogs) { $opencodeArgs.Add('--print-logs') }
if ($formatFlag.Count -gt 0)  { $opencodeArgs.AddRange([string[]]$formatFlag) }
if ($AttachUrl)                { $opencodeArgs.Add('--attach'); $opencodeArgs.Add($AttachUrl) }
if ($WorkDir)                  { $opencodeArgs.Add('--dir');    $opencodeArgs.Add($WorkDir) }
$opencodeArgs.Add($Prompt)

# ── Summary ────────────────────────────────────────────────────────────────────
$attachDisplay = if ($AttachUrl) { $AttachUrl -replace '://[^@]+@', '://<redacted>@' } else { 'local' }
Write-Host "Prompt: $($Prompt.Length) chars | attach: $attachDisplay | log-level: $LogLevel"

if ($env:DEBUG_ORCHESTRATOR -eq 'true') {
    Write-Host '=== run_opencode_prompt.ps1 diagnostics ==='
    Write-Host "Timestamp: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host "PWD: $(Get-Location)"
    $ocBin = Get-Command opencode -ErrorAction SilentlyContinue
    Write-Host "opencode binary: $(if ($ocBin) { $ocBin.Source } else { 'NOT FOUND' })"
    try   { Write-Host "opencode version: $(& opencode --version 2>&1)" }
    catch { Write-Host 'opencode version: UNKNOWN' }
    Write-Host "Prompt first 200 chars: $($Prompt.Substring(0, [Math]::Min(200, $Prompt.Length)))"
    Write-Host "Prompt last 200 chars:  $($Prompt.Substring([Math]::Max(0, $Prompt.Length - 200)))"
    Write-Host 'opencode args (excluding prompt):'
    for ($i = 0; $i -lt $opencodeArgs.Count - 1; $i++) {
        $safeArg = $opencodeArgs[$i] -replace '://[^:@/]+:[^@/]+@', '://<redacted>@'
        Write-Host "  [$i] $safeArg"
    }
    Write-Host "  [$($opencodeArgs.Count - 1)] <prompt content, $($Prompt.Length) chars>"
    Write-Host '=== end diagnostics ==='
}

Write-Host "Starting opencode at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"

# ── Temp files and paths ──────────────────────────────────────────────────────
$tempBase      = [System.IO.Path]::GetTempPath()
$OutputLog     = Join-Path $tempBase "opencode-output.$PID.$(Get-Random)"
$ServerLog     = if ($env:OPENCODE_SERVER_LOG)     { $env:OPENCODE_SERVER_LOG }     else { Join-Path $tempBase 'opencode-serve.log' }
$ServerPidFile = if ($env:OPENCODE_SERVER_PIDFILE) { $env:OPENCODE_SERVER_PIDFILE } else { Join-Path $tempBase 'opencode-serve.pid' }

# Touch the output log so tail can start immediately
[System.IO.File]::WriteAllText($OutputLog, '')

Write-Host "Output log: $OutputLog"
Write-Host "Server log: $ServerLog"
Write-Host "Server PID file: $ServerPidFile (monitored for process I/O activity)"

# ── Build a bash launcher script ──────────────────────────────────────────────
# We write the prompt to a temp file and read it with $(cat …) so that
# arbitrary prompt content (quotes, $, etc.) is never interpolated by bash.
$promptFile   = Join-Path $tempBase "opencode-prompt-$PID"
$launcherPath = Join-Path $tempBase "opencode-launch-$PID.sh"

[System.IO.File]::WriteAllText($promptFile, $Prompt, [System.Text.Encoding]::UTF8)

# Shell-escape every arg except the final prompt (handled via cat).
$argsWithoutPrompt = [string[]]$opencodeArgs[0..($opencodeArgs.Count - 2)]
$bashSafeArgs = ($argsWithoutPrompt | ForEach-Object { ConvertTo-BashSingleQuoted $_ }) -join ' '

# exec replaces bash with stdbuf so the PID we track IS the opencode process
# tree root. stdbuf itself execs opencode, keeping the same PID.
$launcherBody = @"
#!/usr/bin/env bash
exec stdbuf -oL -eL opencode $bashSafeArgs "`$(cat '${promptFile}')" > '${OutputLog}' 2>&1
"@
[System.IO.File]::WriteAllText($launcherPath, $launcherBody, [System.Text.Encoding]::UTF8)
bash -c "chmod +x '$launcherPath'" | Out-Null

$displayArgs = ($argsWithoutPrompt) -join ' '
Write-Host "Launching: opencode $displayArgs <prompt>"

# ── Launch opencode ────────────────────────────────────────────────────────────
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName  = $launcherPath
$psi.UseShellExecute = $false
$opencodeProcess = [System.Diagnostics.Process]::Start($psi)
$OPENCODE_PID = $opencodeProcess.Id
Write-Host "opencode PID: $OPENCODE_PID"

# Verify the process actually started
Start-Sleep -Seconds 1
if ($opencodeProcess.HasExited) {
    Write-Host '::error::opencode process died immediately after launch'
    Write-Host '=== Output log contents ==='
    if (Test-Path $OutputLog) { Get-Content $OutputLog | Write-Host }
    Write-Host '=== end output log ==='
    Remove-Item -Force $OutputLog, $promptFile, $launcherPath -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "opencode process $OPENCODE_PID confirmed running after 1s"

# ── Stream client output log ──────────────────────────────────────────────────
# Prefix subagent delegation events (•✓) and tool operations (→%⚙) so they
# are visually distinct from [server] / [watchdog] lines in the CI log.
# We write a small bash helper so there are zero quoting issues with Start-Process.
$clientTailScript = Join-Path $tempBase "opencode-client-tail-$PID.sh"
$clientTailBody = @"
#!/usr/bin/env bash
trap 'kill 0' EXIT
tail -f '${OutputLog}' 2>/dev/null \
  | sed -u -e '/[•✓]/s/^/[subagent] /' -e '/[→%⚙]/s/^/[agent] /'
"@
[System.IO.File]::WriteAllText($clientTailScript, $clientTailBody, [System.Text.Encoding]::UTF8)
bash -c "chmod +x '$clientTailScript'" | Out-Null

$clientTailPsi = [System.Diagnostics.ProcessStartInfo]::new()
$clientTailPsi.FileName = $clientTailScript
$clientTailPsi.UseShellExecute = $false
$clientTailProc = [System.Diagnostics.Process]::Start($clientTailPsi)

# ── Stream server log ─────────────────────────────────────────────────────────
# Patterns suppressed from server log streaming — per-token / init noise:
$SERVER_LOG_NOISE = 'service=bus |service=tool\.registry |service=permission |service=bash-tool |service=provider |service=lsp |service=file\.time |service=snapshot |cwd=.*tracking|service=session\.processor |service=session\.compaction |service=session\.prompt status=|service=format |service=vcs |service=storage |ruleset=\[\{"permission|action=\{"permission|mcp stderr: .*running on|service=llm .*stream$|session\.prompt step=.*loop$|mcp stderr:\s*$'

$serverTailProc       = $null
$serverTailScript     = $null

if (Test-Path -LiteralPath $ServerLog) {
    $serverLogStartLines = 0
    try {
        $serverLogStartLines = [int](bash -c "wc -l < '$ServerLog' 2>/dev/null || echo 0")
    } catch { $serverLogStartLines = 0 }
    $startLine = $serverLogStartLines + 1

    $serverTailScript = Join-Path $tempBase "opencode-server-tail-$PID.sh"
    $serverTailBody = @"
#!/usr/bin/env bash
trap 'kill 0' EXIT
tail -f -n +${startLine} '${ServerLog}' 2>/dev/null \
  | grep --line-buffered -Ev '${SERVER_LOG_NOISE}' \
  | grep --line-buffered -v '^\s*$' \
  | sed -u 's/^/[server] /'
"@
    [System.IO.File]::WriteAllText($serverTailScript, $serverTailBody, [System.Text.Encoding]::UTF8)
    bash -c "chmod +x '$serverTailScript'" | Out-Null

    $serverTailPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $serverTailPsi.FileName = $serverTailScript
    $serverTailPsi.UseShellExecute = $false
    $serverTailProc = [System.Diagnostics.Process]::Start($serverTailPsi)

    Write-Host "Server log tailer started (pid $($serverTailProc.Id)), streaming from line $startLine"
} else {
    Write-Host "Server log not found at $ServerLog — server-side traces will not be streamed"
}

# ── Read server I/O counters from /proc ───────────────────────────────────────
# Returns a hashtable @{ Read = <string>; Write = <string> } or $null.
function Read-ServerIoSplit {
    if (-not (Test-Path -LiteralPath $ServerPidFile)) { return $null }
    $spid = $null
    try { $spid = (Get-Content -LiteralPath $ServerPidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim() } catch { # Intentionally empty — cleanup best-effort }
    if (-not $spid) { return $null }

    $ioPath = "/proc/$spid/io"
    if (-not (Test-Path -LiteralPath $ioPath)) { return $null }

    $readBytes  = ''
    $writeBytes = ''
    try {
        foreach ($line in (Get-Content -LiteralPath $ioPath -ErrorAction SilentlyContinue)) {
            if ($line -match '^read_bytes:\s*(\d+)')  { $readBytes  = $Matches[1] }
            if ($line -match '^write_bytes:\s*(\d+)') { $writeBytes = $Matches[1] }
        }
    } catch { return $null }

    if ($readBytes -and $writeBytes) {
        return @{ Read = $readBytes; Write = $writeBytes }
    }
    return $null
}

# ── Watchdog loop ─────────────────────────────────────────────────────────────
# Idle watchdog: kill opencode if it produces no output for IDLE_TIMEOUT_SECS.
# See bash version comments for the full rationale on split read/write tracking.
$ErrorActionPreference = 'Continue'

$START_TIME      = Get-EpochSeconds
$IDLE_KILLED     = 0
$prevServerRead  = ''
$prevServerWrite = ''
$lastWriteTime   = $START_TIME
$lastReadTime    = $START_TIME

while (-not $opencodeProcess.HasExited) {
    Start-Sleep -Seconds 30

    $now     = Get-EpochSeconds
    $elapsed = $now - $START_TIME

    # ── Output log stats ──────────────────────────────────────────────────
    $logSize       = 0
    $logLines      = 0
    $outputLastMod = $now
    if (Test-Path $OutputLog) {
        $fi         = [System.IO.FileInfo]::new($OutputLog)
        $logSize    = $fi.Length
        try { $logLines = [int](bash -c "wc -l < '$OutputLog' 2>/dev/null || echo 0") } catch { # Intentionally empty — cleanup best-effort }
        $outputLastMod = [long][DateTimeOffset]::new($fi.LastWriteTimeUtc).ToUnixTimeSeconds()
    }
    $outputIdle = $now - $outputLastMod

    # ── Server activity detection (split read/write tracking) ─────────────
    $writeActive    = $false
    $readActive     = $false
    $curServerRead  = ''
    $curServerWrite = ''

    $ioSplit = Read-ServerIoSplit
    if ($null -ne $ioSplit) {
        $curServerRead  = $ioSplit.Read
        $curServerWrite = $ioSplit.Write

        # Detect write activity (strong progress signal)
        if ($prevServerWrite -and $curServerWrite -ne $prevServerWrite) {
            $writeActive   = $true
            $lastWriteTime = $now
        }
        # Detect read activity (weaker "alive" signal)
        if ($prevServerRead -and $curServerRead -ne $prevServerRead) {
            $readActive   = $true
            $lastReadTime = $now
        }
        $prevServerRead  = $curServerRead
        $prevServerWrite = $curServerWrite
    }

    # Server log mtime as secondary signal (when /proc/io unavailable)
    $serverLogIdle = $outputIdle
    if (Test-Path -LiteralPath $ServerLog) {
        $sfi = [System.IO.FileInfo]::new($ServerLog)
        $serverLastMod = [long][DateTimeOffset]::new($sfi.LastWriteTimeUtc).ToUnixTimeSeconds()
        $serverLogIdle = $now - $serverLastMod
    }

    # ── Determine effective server idle using tiered logic ────────────────
    #   write_bytes active  → definitely not idle (strong progress signal)
    #   read_bytes active   → grant READ_ONLY_GRACE period
    #   neither active      → standard idle timeout
    #   /proc/io unavailable → fall back to server log mtime
    $writeIdle      = $now - $lastWriteTime
    $readIdle       = $now - $lastReadTime
    $serverIoActive = $false

    if ($writeActive) {
        $serverIdle     = 0
        $serverIoActive = $true
    } elseif ($readActive -and $writeIdle -lt $READ_ONLY_GRACE_SECS) {
        $serverIdle     = 0
        $serverIoActive = $true
    } elseif ($curServerWrite) {
        # /proc/io available but no qualifying activity this interval
        $serverIdle = $writeIdle
    } else {
        # /proc/io not available — fall back to log mtime
        $serverIdle = $serverLogIdle
    }

    # Effective idle = min(client output idle, server idle)
    $idle = [Math]::Min($outputIdle, $serverIdle)

    # ── Watchdog status output ────────────────────────────────────────────
    if ($env:DEBUG_ORCHESTRATOR -eq 'true') {
        $rbDisplay = if ($curServerRead)  { $curServerRead }  else { 'n/a' }
        $wbDisplay = if ($curServerWrite) { $curServerWrite } else { 'n/a' }
        Write-Host "[watchdog] elapsed=${elapsed}s output_idle=${outputIdle}s server_idle=${serverIdle}s write_active=$writeActive read_active=$readActive effective_idle=${idle}s log_size=${logSize}b log_lines=$logLines pid=$OPENCODE_PID read_bytes=$rbDisplay write_bytes=$wbDisplay write_idle=${writeIdle}s read_idle=${readIdle}s"
    } elseif ($outputIdle -ge 60 -and $serverIoActive) {
        if ($writeActive) {
            Write-Host "[watchdog] client output idle ${outputIdle}s, server write I/O active (write_bytes=$curServerWrite) — subagent likely running"
        } else {
            Write-Host "[watchdog] client output idle ${outputIdle}s, server read I/O active (read_bytes=$curServerRead, write_idle=${writeIdle}s/${READ_ONLY_GRACE_SECS}s grace) — subagent likely running"
        }
        if ($env:DEBUG_ORCHESTRATOR -eq 'true' -and (Test-Path -LiteralPath $ServerLog)) {
            $recent = bash -c "tail -20 '$ServerLog' 2>/dev/null | grep -Ev '${SERVER_LOG_NOISE}' | grep -v '^\$' | tail -3" 2>$null
            if ($recent) {
                Write-Host '[watchdog] recent server activity:'
                foreach ($rLine in $recent) { Write-Host "  | $rLine" }
            }
        }
    }

    # ── Hard ceiling safety net ───────────────────────────────────────────
    if ($elapsed -ge $HARD_CEILING_SECS) {
        Write-Host ''
        Write-Host "::error::opencode hit ${HARD_CEILING_SECS}s hard ceiling; terminating"
        Send-Signal -ProcessId $OPENCODE_PID -Signal 'TERM'
        Start-Sleep -Seconds 10
        if (Test-ProcessAlive -ProcessId $OPENCODE_PID) {
            Write-Host '::warning::opencode did not exit after SIGTERM; sending SIGKILL'
            Send-Signal -ProcessId $OPENCODE_PID -Signal 'KILL'
        }
        $IDLE_KILLED = 1
        break
    }

    # ── Idle detection ────────────────────────────────────────────────────
    if ($idle -ge $IDLE_TIMEOUT_SECS) {
        $idleMins = [Math]::Floor($idle / 60)
        Write-Host ''
        Write-Host "::error::opencode idle for ${idleMins}m (no output from client or server); terminating"
        Send-Signal -ProcessId $OPENCODE_PID -Signal 'TERM'
        Start-Sleep -Seconds 10
        if (Test-ProcessAlive -ProcessId $OPENCODE_PID) {
            Write-Host '::warning::opencode did not exit after SIGTERM; sending SIGKILL'
            Send-Signal -ProcessId $OPENCODE_PID -Signal 'KILL'
        }
        $IDLE_KILLED = 1
        break
    }
}

# ── Wait for opencode to finish ───────────────────────────────────────────────
if (-not $opencodeProcess.HasExited) {
    $opencodeProcess.WaitForExit()
}
$OPENCODE_EXIT = $opencodeProcess.ExitCode

# ── Cleanup tail processes ─────────────────────────────────────────────────────
# Send SIGTERM to the bash wrappers — their 'trap "kill 0" EXIT' propagates
# the signal to the tail/sed/grep pipeline children.
if ($null -ne $clientTailProc -and -not $clientTailProc.HasExited) {
    Send-Signal -ProcessId $clientTailProc.Id -Signal 'TERM'
    Start-Sleep -Milliseconds 500
    if (-not $clientTailProc.HasExited) { Send-Signal -ProcessId $clientTailProc.Id -Signal 'KILL' }
}
if ($null -ne $serverTailProc -and -not $serverTailProc.HasExited) {
    Send-Signal -ProcessId $serverTailProc.Id -Signal 'TERM'
    Start-Sleep -Milliseconds 500
    if (-not $serverTailProc.HasExited) { Send-Signal -ProcessId $serverTailProc.Id -Signal 'KILL' }
}

# Final safety net: kill any remaining child processes
bash -c 'jobs -p 2>/dev/null | xargs -r kill 2>/dev/null' | Out-Null

Write-Host ''
Write-Host "opencode exit code: $OPENCODE_EXIT"

# ── Dump server log on idle kill ───────────────────────────────────────────────
if ($IDLE_KILLED -eq 1 -and (Test-Path -LiteralPath $ServerLog)) {
    Write-Host '=== server log tail (last 80 lines before idle kill) ==='
    bash -c "tail -n 80 '$ServerLog' 2>/dev/null" | ForEach-Object { Write-Host $_ }
    Write-Host '=== end server log ==='
}

# ── Debug post-execution diagnostics ──────────────────────────────────────────
if ($env:DEBUG_ORCHESTRATOR -eq 'true') {
    Write-Host '=== opencode post-execution diagnostics ==='
    Write-Host "Timestamp: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host "Idle killed: $IDLE_KILLED"
    Write-Host "Output log file: $OutputLog"
    if (Test-Path $OutputLog) {
        $fi     = [System.IO.FileInfo]::new($OutputLog)
        $lLines = 0
        try { $lLines = [int](bash -c "wc -l < '$OutputLog' 2>/dev/null || echo 0") } catch { # Intentionally empty — cleanup best-effort }
        Write-Host "Output log size: $($fi.Length) bytes, $lLines lines"
        Write-Host '=== Full output log contents ==='
        Get-Content $OutputLog | Write-Host
        Write-Host ''
        Write-Host '=== end output log ==='
    } else {
        Write-Host "WARNING: Output log file $OutputLog does not exist!"
    }
    Write-Host "Server log file: $ServerLog"
    if (Test-Path -LiteralPath $ServerLog) {
        $sfi    = [System.IO.FileInfo]::new($ServerLog)
        $sLines = 0
        try { $sLines = [int](bash -c "wc -l < '$ServerLog' 2>/dev/null || echo 0") } catch { # Intentionally empty — cleanup best-effort }
        Write-Host "Server log size: $($sfi.Length) bytes, $sLines lines"
        Write-Host '=== Full server log contents ==='
        Get-Content -LiteralPath $ServerLog | Write-Host
        Write-Host ''
        Write-Host '=== end server log ==='
    } else {
        Write-Host 'Server log not found (opencode may be running in local mode)'
    }
    Write-Host '=== end post-execution diagnostics ==='
}

# ── Cleanup temp files ─────────────────────────────────────────────────────────
$tempFiles = @($OutputLog, $promptFile, $launcherPath, $clientTailScript)
if ($serverTailScript) { $tempFiles += $serverTailScript }
Remove-Item -Force $tempFiles -ErrorAction SilentlyContinue

$ErrorActionPreference = 'Stop'

# Exit non-zero on idle kill so the workflow properly reports failure.
if ($IDLE_KILLED -eq 1) { exit 1 }

exit $OPENCODE_EXIT
