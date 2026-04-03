#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run an opencode prompt locally via the devcontainer, mirroring how the
    orchestrator-agent.yml workflow dispatches prompts.

.DESCRIPTION
    1. Ensures the devcontainer + opencode server are running (via devcontainer-opencode.sh start).
    2. Dispatches the prompt (via devcontainer-opencode.sh prompt) with the server-side
       workspace directory set correctly so opencode can resolve session context.

    The server-side path defaults to /workspaces/<repo-basename>, which matches how
    devcontainers mount the workspace.

.PARAMETER Prompt
    Inline prompt string.  Mutually exclusive with -File.

.PARAMETER File
    Path to a pre-assembled prompt file.  Mutually exclusive with -Prompt.

.PARAMETER ServerUrl
    URL of the opencode server inside the devcontainer.
    Default: http://127.0.0.1:4096

.PARAMETER ServerDir
    Working directory on the server side (container path).
    Default: /workspaces/<repo-basename>

.PARAMETER SkipStart
    Skip the 'start' step — use when the devcontainer + server are already running.

.EXAMPLE
    ./scripts/prompt-local.ps1 -Prompt "say hello"

.EXAMPLE
    ./scripts/prompt-local.ps1 -File .github/workflows/prompts/orchestrator-agent-prompt.md

.EXAMPLE
    ./scripts/prompt-local.ps1 -Prompt "list open issues" -SkipStart
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Inline',  Mandatory)]
    [string] $Prompt,

    [Parameter(ParameterSetName = 'File',    Mandatory)]
    [string] $File,

    [string] $ServerUrl = 'http://127.0.0.1:4096',
    [string] $ServerDir = '',
    [switch] $SkipStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve repo root (script lives in scripts/)
# ---------------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$RunnerScript = Join-Path $RepoRoot 'scripts' 'devcontainer-opencode.sh'

if (-not (Test-Path $RunnerScript)) {
    Write-Error "Could not find $RunnerScript"
    exit 1
}

# ---------------------------------------------------------------------------
# Default server-side dir = /workspaces/<repo-basename>
# ---------------------------------------------------------------------------
if (-not $ServerDir) {
    $ServerDir = "/workspaces/$(Split-Path -Leaf $RepoRoot)"
}

Write-Host "[prompt-local] server-dir : $ServerDir"
Write-Host "[prompt-local] server-url : $ServerUrl"

# ---------------------------------------------------------------------------
# Always run bash scripts from the repo root so WORKSPACE_FOLDER=$PWD works
# ---------------------------------------------------------------------------
Push-Location $RepoRoot

# ---------------------------------------------------------------------------
# Step 1 — ensure devcontainer + opencode server are running
# ---------------------------------------------------------------------------
if (-not $SkipStart) {
    Write-Host "[prompt-local] starting devcontainer + opencode server..."
    bash $RunnerScript start
    if ($LASTEXITCODE -ne 0) {
        Write-Error "devcontainer-opencode.sh start failed (exit $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
}

# ---------------------------------------------------------------------------
# Step 2 — dispatch the prompt
# ---------------------------------------------------------------------------
$PromptArgs = @('prompt', '-u', $ServerUrl, '-d', $ServerDir)

if ($PSCmdlet.ParameterSetName -eq 'Inline') {
    Write-Host "[prompt-local] prompt     : $($Prompt.Substring(0, [Math]::Min(80, $Prompt.Length)))..."
    $PromptArgs += @('-p', $Prompt)
} else {
    $AbsFile = Resolve-Path $File
    Write-Host "[prompt-local] prompt file: $AbsFile"
    $PromptArgs += @('-f', $AbsFile)
}

Write-Host "[prompt-local] dispatching..."
bash $RunnerScript @PromptArgs
$ec = $LASTEXITCODE
Pop-Location
exit $ec
