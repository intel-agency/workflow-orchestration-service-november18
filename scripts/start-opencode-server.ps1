#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Starts the opencode serve daemon, managing its full lifecycle.

.DESCRIPTION
    Manages the opencode server daemon lifecycle:
    - Sets GH_TOKEN from GH_ORCHESTRATION_AGENT_TOKEN if available
    - Sets OPENCODE_EXPERIMENTAL=1
    - Checks for an existing running instance (PID file + health check)
    - Kills stale processes (graceful then forced)
    - Launches opencode serve as a background process
    - Polls a health-check endpoint until the server is ready or timeout

    All behaviour is configurable via environment variables.

.EXAMPLE
    ./scripts/start-opencode-server.ps1

.EXAMPLE
    $env:OPENCODE_SERVER_PORT = '8080'
    ./scripts/start-opencode-server.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Token propagation ───────────────────────────────────────────────
if ($env:GH_ORCHESTRATION_AGENT_TOKEN) {
    $env:GH_TOKEN = $env:GH_ORCHESTRATION_AGENT_TOKEN
}

$env:OPENCODE_EXPERIMENTAL = '1'

# ── Configurable defaults (all overridable via env vars) ────────────
$TempDir     = [IO.Path]::GetTempPath()
$Hostname    = if ($env:OPENCODE_SERVER_HOSTNAME)            { $env:OPENCODE_SERVER_HOSTNAME }            else { '0.0.0.0' }
$Port        = if ($env:OPENCODE_SERVER_PORT)                { $env:OPENCODE_SERVER_PORT }                else { '4096' }
$LogFile     = if ($env:OPENCODE_SERVER_LOG)                 { $env:OPENCODE_SERVER_LOG }                 else { Join-Path $TempDir 'opencode-serve.log' }
$PidFile     = if ($env:OPENCODE_SERVER_PIDFILE)             { $env:OPENCODE_SERVER_PIDFILE }             else { Join-Path $TempDir 'opencode-serve.pid' }
$ReadyTimeout = if ($env:OPENCODE_SERVER_READY_TIMEOUT_SECS) { [int]$env:OPENCODE_SERVER_READY_TIMEOUT_SECS } else { 30 }
$ReadyUrl    = if ($env:OPENCODE_SERVER_READY_URL)           { $env:OPENCODE_SERVER_READY_URL }           else { "http://127.0.0.1:${Port}/" }
$LogLevel    = if ($env:OPENCODE_SERVER_LOG_LEVEL)           { $env:OPENCODE_SERVER_LOG_LEVEL }           else { 'INFO' }

# ── Helpers ─────────────────────────────────────────────────────────

function Write-LogMessage {
    param([string]$Message)
    Write-Host "[start-opencode-server] $Message"
}

function Test-ServerReady {
    <#
    .SYNOPSIS
        Returns $true when the health-check URL responds successfully.
    #>
    try {
        $response = Invoke-WebRequest -Uri $ReadyUrl -TimeoutSec 2 -ErrorAction Stop -SkipHttpErrorCheck
        return ($null -ne $response)
    }
    catch {
        return $false
    }
}

function Test-ProcessAlive {
    <#
    .SYNOPSIS
        Returns $true when a process with the given PID exists.
    #>
    param([int]$ProcessId)
    return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Stop-StaleProcess {
    <#
    .SYNOPSIS
        Gracefully stops a process; escalates to forced kill after timeout.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$ProcessId)

    if (-not $PSCmdlet.ShouldProcess("process $ProcessId", 'Stop')) { return }

    try { Stop-Process -Id $ProcessId -ErrorAction SilentlyContinue } catch { # Intentionally empty — process may already be gone }

    $gracefulTimeout = 5
    $waitStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    while (Test-ProcessAlive -ProcessId $ProcessId) {
        $current = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($current - $waitStart) -ge $gracefulTimeout) {
            Write-LogMessage "process did not terminate gracefully within ${gracefulTimeout}s; sending forced kill"
            try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { # Intentionally empty — process may already be gone }
            break
        }
        Start-Sleep -Milliseconds 500
    }
}

# ── Pre-flight: opencode must be on PATH ────────────────────────────
if (-not (Get-Command 'opencode' -ErrorAction SilentlyContinue)) {
    Write-Error 'opencode is not installed or not on PATH'
    exit 1
}

# ── Ensure parent directories exist ────────────────────────────────
$logDir = Split-Path -Parent $LogFile
$pidDir = Split-Path -Parent $PidFile
if ($logDir) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if ($pidDir) { New-Item -ItemType Directory -Path $pidDir -Force | Out-Null }

# ── Handle existing PID file ───────────────────────────────────────
if (Test-Path $PidFile) {
    $existingPidText = (Get-Content $PidFile -Raw).Trim()

    if ($existingPidText -and $existingPidText -match '^\d+$') {
        $existingPid = [int]$existingPidText

        if (Test-ProcessAlive -ProcessId $existingPid) {
            if (Test-ServerReady) {
                Write-LogMessage "opencode serve already running on port ${Port} (pid ${existingPid})"
                exit 0
            }

            # Process alive but server not ready → stale
            Write-LogMessage "stale opencode serve process found (pid ${existingPid}); terminating before restart"
            Stop-StaleProcess -ProcessId $existingPid
            Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
        }
        else {
            # PID file points to a dead process
            Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        # PID file is empty or invalid
        Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
    }
}

# ── If the port is already serving traffic, leave it alone ─────────
if (Test-ServerReady) {
    Write-LogMessage "port ${Port} is already serving traffic; leaving existing opencode server untouched"
    exit 0
}

# ── Launch opencode serve as a background process ──────────────────
Write-LogMessage "starting opencode serve on ${Hostname}:${Port} (log-level: ${LogLevel}, print-logs: on)"

$serverPid = $null
$stderrLog = $null

if ($IsLinux) {
    $command = "setsid opencode serve --hostname '" +
        [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Hostname) +
        "' --port '" +
        [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Port) +
        "' --log-level '" +
        [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($LogLevel) +
        "' --print-logs >> '" +
        [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($LogFile) +
        "' 2>&1 < /dev/null & echo `$!"

    $serverPid = & bash -lc $command
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serverPid)) {
        Write-Error 'Failed to start opencode serve with setsid'
        exit 1
    }
    $serverPid = $serverPid.Trim()
} else {
    # Start-Process cannot append both streams into one file, so keep stderr separate on non-Linux hosts.
    $stderrLog = "${LogFile}.stderr"
    $proc = Start-Process -FilePath 'opencode' `
        -ArgumentList @(
            'serve',
            '--hostname', $Hostname,
            '--port', $Port,
            '--log-level', $LogLevel,
            '--print-logs'
        ) `
        -NoNewWindow `
        -RedirectStandardOutput $LogFile `
        -RedirectStandardError $stderrLog `
        -PassThru

    $serverPid = [string]$proc.Id
}

Set-Content -Path $PidFile -Value $serverPid -NoNewline

# ── Health-check polling loop ──────────────────────────────────────
$readyStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$deadline   = $readyStart + $ReadyTimeout

while ($true) {
    if (Test-ServerReady) {
        Write-LogMessage "opencode serve is ready (pid ${serverPid}); logs: ${LogFile}"
        exit 0
    }

    if (-not (Test-ProcessAlive -ProcessId ([int]$serverPid))) {
        Write-Error "opencode serve exited before becoming ready; tail of log:"
        if (Test-Path $LogFile)   { Get-Content $LogFile -Tail 50 | Write-Host }
        if ($stderrLog -and (Test-Path $stderrLog)) { Get-Content $stderrLog -Tail 50 | Write-Host }
        exit 1
    }

    $current = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($current -ge $deadline) {
        break
    }

    Start-Sleep -Seconds 1
}

Write-Error "Timed out waiting ${ReadyTimeout}s for opencode serve on ${ReadyUrl}"
if (Test-Path $LogFile)   { Get-Content $LogFile   -Tail 50 | Write-Host }
if (Test-Path $stderrLog) { Get-Content $stderrLog -Tail 50 | Write-Host }
exit 1
