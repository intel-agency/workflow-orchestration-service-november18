#!/usr/bin/env pwsh
<#
.SYNOPSIS
    CLI wrapper around devcontainer for the opencode server workflow.

.DESCRIPTION
    Thin CLI wrapper around devcontainer for the opencode server workflow.
    Shared defaults mean callers only specify what differs.

    Commands:
      up      Start (or reconnect to) the devcontainer
      start   Ensure opencode serve is running inside the container
      prompt  Dispatch a prompt file to the agent via opencode run --attach
      status  Show container state, server health, and recent logs
      stop    Gracefully stop the container (keeps it for fast restart)
      down    Stop and remove the container (full teardown)

.PARAMETER Command
    The action to perform: up, start, prompt, status, stop, or down.

.PARAMETER DevcontainerConfig
    Path to devcontainer.json. Defaults to env:DEVCONTAINER_CONFIG or
    '.devcontainer/devcontainer.json'.

.PARAMETER WorkspaceFolder
    Workspace folder on the host. Defaults to env:WORKSPACE_FOLDER or '.'.

.PARAMETER PromptFile
    Path to an assembled prompt file (required for 'prompt', or use -PromptString).

.PARAMETER PromptString
    Inline prompt string (required for 'prompt', or use -PromptFile).

.PARAMETER OpenCodeServerUrl
    Opencode server URL. Defaults to env:OPENCODE_SERVER_URL or
    'http://127.0.0.1:4096'.

.PARAMETER OpenCodeServerDir
    Server-side working directory inside the container. Defaults to
    env:OPENCODE_SERVER_DIR or '/workspaces/<repo-basename>'.

.EXAMPLE
    ./scripts/devcontainer-opencode.ps1 up

.EXAMPLE
    ./scripts/devcontainer-opencode.ps1 start

.EXAMPLE
    ./scripts/devcontainer-opencode.ps1 prompt -PromptFile ./prompts/plan.md

.EXAMPLE
    ./scripts/devcontainer-opencode.ps1 prompt -PromptString "Refactor the auth module"

.EXAMPLE
    ./scripts/devcontainer-opencode.ps1 status

.EXAMPLE
    ./scripts/devcontainer-opencode.ps1 stop

.EXAMPLE
    ./scripts/devcontainer-opencode.ps1 down
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('up', 'start', 'prompt', 'status', 'stop', 'down')]
    [string]$Command,

    [Parameter(Mandatory = $false)]
    [string]$DevcontainerConfig = $(if ([string]::IsNullOrWhiteSpace($env:DEVCONTAINER_CONFIG)) { '.devcontainer/devcontainer.json' } else { $env:DEVCONTAINER_CONFIG }),

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceFolder = $(if ([string]::IsNullOrWhiteSpace($env:WORKSPACE_FOLDER)) { '.' } else { $env:WORKSPACE_FOLDER }),

    [Parameter(Mandatory = $false)]
    [string]$PromptFile,

    [Parameter(Mandatory = $false)]
    [string]$PromptString,

    [Parameter(Mandatory = $false)]
    [string]$OpenCodeServerUrl = $(if ([string]::IsNullOrWhiteSpace($env:OPENCODE_SERVER_URL)) { 'http://127.0.0.1:4096' } else { $env:OPENCODE_SERVER_URL }),

    [Parameter(Mandatory = $false)]
    [string]$OpenCodeServerDir = $(if ([string]::IsNullOrWhiteSpace($env:OPENCODE_SERVER_DIR)) { '' } else { $env:OPENCODE_SERVER_DIR })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Helpers ─────────────────────────────────────────────────────────

function Write-LogMessage {
    param([string]$Message)
    Write-Host "[devcontainer-opencode] $Message"
}

function Get-AbsWorkspace {
    <#
    .SYNOPSIS
        Resolves the workspace folder to an absolute path.
    #>
    return (Resolve-Path -LiteralPath $WorkspaceFolder).Path
}

function Find-DevcontainerId {
    <#
    .SYNOPSIS
        Finds the devcontainer ID via the docker label query pattern.
    #>
    param([string]$AbsWorkspace)
    $id = docker ps -aq --latest --filter "label=devcontainer.local_folder=$AbsWorkspace" 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    $id = "$id".Trim()
    if ([string]::IsNullOrWhiteSpace($id)) {
        return $null
    }
    return $id
}

function Get-SharedArgs {
    <#
    .SYNOPSIS
        Returns the shared devcontainer CLI arguments.
    #>
    return @(
        '--workspace-folder', $WorkspaceFolder,
        '--config', $DevcontainerConfig
    )
}

# ── Command implementations ────────────────────────────────────────

function Invoke-Up {
    $sharedArgs = Get-SharedArgs
    devcontainer up @sharedArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-Start {
    $absWorkspace = Get-AbsWorkspace
    $containerId = Find-DevcontainerId -AbsWorkspace $absWorkspace
    $sharedArgs = Get-SharedArgs

    if (-not $containerId) {
        Write-LogMessage 'no container found; creating via ''up'''
        devcontainer up @sharedArgs
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    else {
        $containerState = docker inspect --format '{{.State.Status}}' $containerId
        if ($containerState -ne 'running') {
            Write-LogMessage "restarting stopped container $containerId"
            docker start $containerId
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }

    devcontainer exec @sharedArgs -- pwsh ./scripts/start-opencode-server.ps1
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-Prompt {
    # Validate prompt input — at least one is required
    if (-not $PromptFile -and -not $PromptString) {
        Write-Error 'Either -PromptFile or -PromptString is required for the ''prompt'' command.'
    }

    # Validate required environment variables
    $requiredVars = @(
        'ZHIPU_API_KEY',
        'KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY',
        'GH_ORCHESTRATION_AGENT_TOKEN'
    )
    foreach ($varName in $requiredVars) {
        $val = [System.Environment]::GetEnvironmentVariable($varName)
        if (-not $val) {
            Write-Error "::error::${varName} is not set"
        }
    }

    # Build the prompt source arg: -PromptString takes precedence over -PromptFile
    if ($PromptString) {
        $promptArgs = @('-Prompt', $PromptString)
    }
    else {
        $promptArgs = @('-File', $PromptFile)
    }

    # Derive default server-side dir from the workspace folder basename
    $serverDir = $OpenCodeServerDir
    if (-not $serverDir) {
        $absWorkspace = Get-AbsWorkspace
        $repoBasename = Split-Path -Leaf $absWorkspace
        $serverDir = "/workspaces/$repoBasename"
    }

    $sharedArgs = Get-SharedArgs

    $execArgs = @('exec') + $sharedArgs + @(
        '--remote-env', "ZHIPU_API_KEY=$($env:ZHIPU_API_KEY)"
        '--remote-env', "KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY=$($env:KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY)"
        '--remote-env', "GITHUB_TOKEN=$($env:GH_ORCHESTRATION_AGENT_TOKEN)"
        '--remote-env', "GITHUB_PERSONAL_ACCESS_TOKEN=$($env:GH_ORCHESTRATION_AGENT_TOKEN)"
        '--remote-env', "GH_ORCHESTRATION_AGENT_TOKEN=$($env:GH_ORCHESTRATION_AGENT_TOKEN)"
        '--'
        'pwsh', './run_opencode_prompt.ps1',
        '-AttachUrl', $OpenCodeServerUrl,
        '-WorkDir', $serverDir
    ) + $promptArgs

    devcontainer @execArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-Status {
    $absWorkspace = Get-AbsWorkspace
    $containerId = Find-DevcontainerId -AbsWorkspace $absWorkspace

    Write-Host '=== Devcontainer Status ==='
    Write-Host "Workspace: $absWorkspace"
    Write-Host ''

    if (-not $containerId) {
        Write-Host 'Container: NOT FOUND'
        Write-Host '  No devcontainer found for this workspace.'
        Write-Host '  Run: pwsh scripts/devcontainer-opencode.ps1 up'
        exit 1
    }

    $containerState = docker inspect --format '{{.State.Status}}' $containerId
    $containerName = (docker inspect --format '{{.Name}}' $containerId) -replace '^/', ''

    Write-Host "Container: $containerId ($containerName)"
    Write-Host "  State: $containerState"

    if ($containerState -ne 'running') {
        Write-Host '  Server: UNAVAILABLE (container not running)'
        Write-Host '  Run: pwsh scripts/devcontainer-opencode.ps1 up'
        exit 1
    }

    Write-Host ''
    Write-Host '=== Opencode Server ==='

    # Run diagnostics inside the Linux container via bash
    $sharedArgs = Get-SharedArgs
    $statusScript = @'
if [[ -f /tmp/opencode-serve.pid ]]; then
    pid=$(cat /tmp/opencode-serve.pid)
    if kill -0 "$pid" 2>/dev/null; then
        echo "PID: $pid (running)"
    else
        echo "PID: $pid (DEAD)"
    fi
else
    echo "PID: no pidfile found"
fi
if curl -s -o /dev/null --connect-timeout 2 http://127.0.0.1:${OPENCODE_SERVER_PORT:-4096}/; then
    echo "Health: UP (port ${OPENCODE_SERVER_PORT:-4096})"
else
    echo "Health: DOWN (port ${OPENCODE_SERVER_PORT:-4096} not responding)"
fi
echo ""
echo "=== Memory ==="
mem="${MEMORY_FILE_PATH:-$PWD/.memory/memory.jsonl}"
if [[ -f "$mem" ]]; then
    echo "Memory file: $mem ($(wc -l < "$mem") entries, $(wc -c < "$mem") bytes)"
else
    echo "Memory file: $mem (not found)"
fi
echo ""
echo "=== Recent Server Log (last 20 lines) ==="
if [[ -f /tmp/opencode-serve.log ]]; then
    tail -20 /tmp/opencode-serve.log
else
    echo "(no log file)"
fi
'@

    devcontainer exec @sharedArgs -- bash -c $statusScript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-StopOrDown {
    param([bool]$RemoveContainer)

    $absWorkspace = Get-AbsWorkspace
    $containerId = Find-DevcontainerId -AbsWorkspace $absWorkspace

    if (-not $containerId) {
        Write-Error "[devcontainer-opencode] no running container found for workspace $absWorkspace"
    }

    Write-LogMessage "stopping container $containerId"
    docker stop $containerId
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    if ($RemoveContainer) {
        Write-LogMessage "removing container $containerId"
        docker rm $containerId
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}

# ── Dispatch ───────────────────────────────────────────────────────

switch ($Command) {
    'up'     { Invoke-Up }
    'start'  { Invoke-Start }
    'prompt' { Invoke-Prompt }
    'status' { Invoke-Status }
    'stop'   { Invoke-StopOrDown -RemoveContainer $false }
    'down'   { Invoke-StopOrDown -RemoveContainer $true }
}
