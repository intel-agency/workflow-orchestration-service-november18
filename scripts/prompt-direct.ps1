#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run opencode directly inside a devcontainer (no server required).

.DESCRIPTION
    Builds and executes a 'devcontainer exec' command that runs 'opencode run'
    inside an already-running devcontainer. Passes required API keys as
    --remote-env arguments and conditionally includes OPENAI_API_KEY and
    GEMINI_API_KEY when they are set.

.PARAMETER PromptString
    Inline prompt string to send to opencode.

.PARAMETER PromptFile
    Path to a file on the host whose content is read and passed as the prompt.

.PARAMETER Model
    Model identifier. Defaults to env:OPENCODE_MODEL or 'zai-coding-plan/glm-5'.

.PARAMETER Agent
    Agent name. Defaults to env:OPENCODE_AGENT or 'orchestrator'.

.PARAMETER LogLevel
    Log level: DEBUG, INFO, WARN, ERROR. Defaults to env:OPENCODE_LOG_LEVEL or 'INFO'.

.PARAMETER DevcontainerConfig
    Path to devcontainer.json. Defaults to env:DEVCONTAINER_CONFIG or
    '.devcontainer/devcontainer.json'.

.PARAMETER WorkspaceFolder
    Workspace folder on the host. Defaults to env:WORKSPACE_FOLDER or '.'.

.EXAMPLE
    ./scripts/prompt-direct.ps1 -PromptString "Refactor the auth module"

.EXAMPLE
    ./scripts/prompt-direct.ps1 -PromptFile ./prompts/plan.md -Model 'gpt-4o'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PromptString,

    [Parameter(Mandatory = $false)]
    [string]$PromptFile,

    [Parameter(Mandatory = $false)]
    [string]$Model = $(if ([string]::IsNullOrWhiteSpace($env:OPENCODE_MODEL)) { 'zai-coding-plan/glm-5' } else { $env:OPENCODE_MODEL }),

    [Parameter(Mandatory = $false)]
    [string]$Agent = $(if ([string]::IsNullOrWhiteSpace($env:OPENCODE_AGENT)) { 'orchestrator' } else { $env:OPENCODE_AGENT }),

    [Parameter(Mandatory = $false)]
    [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
    [string]$LogLevel = $(if ([string]::IsNullOrWhiteSpace($env:OPENCODE_LOG_LEVEL)) { 'INFO' } else { $env:OPENCODE_LOG_LEVEL }),

    [Parameter(Mandatory = $false)]
    [string]$DevcontainerConfig = $(if ([string]::IsNullOrWhiteSpace($env:DEVCONTAINER_CONFIG)) { '.devcontainer/devcontainer.json' } else { $env:DEVCONTAINER_CONFIG }),

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceFolder = $(if ([string]::IsNullOrWhiteSpace($env:WORKSPACE_FOLDER)) { '.' } else { $env:WORKSPACE_FOLDER })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Validate prompt input (mutually exclusive, one required) ----------------

if (-not $PromptString -and -not $PromptFile) {
    Write-Error 'Either -PromptString or -PromptFile is required.'
}

if ($PromptString -and $PromptFile) {
    Write-Error '-PromptString and -PromptFile are mutually exclusive.'
}

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
        Write-Error "Prompt file not found: $PromptFile"
    }
    $PromptString = Get-Content -LiteralPath $PromptFile -Raw
}

# --- Validate required environment variables ---------------------------------

$requiredVars = @(
    'GH_ORCHESTRATION_AGENT_TOKEN',
    'ZHIPU_API_KEY',
    'KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY'
)

foreach ($varName in $requiredVars) {
    $val = [System.Environment]::GetEnvironmentVariable($varName)
    if (-not $val) {
        Write-Error (
            "$varName is not set. Source your .env first:`n" +
            "  PowerShell: Get-Content .env | ForEach-Object { if (`$_ -match '^([^#]\S+?)=(.*)') { [Environment]::SetEnvironmentVariable(`$Matches[1], `$Matches[2]) } }`n" +
            "  Bash:       export `$(grep -v '^#' .env | grep -v '^\s*`$' | xargs)"
        )
    }
}

# --- Locate running devcontainer ---------------------------------------------

$absWorkspace = (Resolve-Path -LiteralPath $WorkspaceFolder).Path
$containerId  = docker ps -q --filter "label=devcontainer.local_folder=$absWorkspace" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "docker ps failed while locating the devcontainer for '$absWorkspace'"
}

if (-not $containerId) {
    Write-Error (
        "No running devcontainer found for workspace '$absWorkspace'.`n" +
        "Start it first: ./scripts/devcontainer-opencode.ps1 up"
    )
}

$containerDir = "/workspaces/$( Split-Path -Leaf $absWorkspace )"

# --- Build devcontainer exec arguments ---------------------------------------

$dcArgs = @(
    'exec',
    '--workspace-folder', $WorkspaceFolder,
    '--config',           $DevcontainerConfig,
    '--remote-env', "ZHIPU_API_KEY=$($env:ZHIPU_API_KEY)",
    '--remote-env', "KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY=$($env:KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY)",
    '--remote-env', "GITHUB_TOKEN=$($env:GH_ORCHESTRATION_AGENT_TOKEN)",
    '--remote-env', "GITHUB_PERSONAL_ACCESS_TOKEN=$($env:GH_ORCHESTRATION_AGENT_TOKEN)",
    '--remote-env', "GH_ORCHESTRATION_AGENT_TOKEN=$($env:GH_ORCHESTRATION_AGENT_TOKEN)",
    '--remote-env', "GH_TOKEN=$($env:GH_ORCHESTRATION_AGENT_TOKEN)",
    '--remote-env', 'OPENCODE_EXPERIMENTAL=1'
)

# Conditional keys — only forward when set on the host
if ($env:OPENAI_API_KEY) {
    $dcArgs += @('--remote-env', "OPENAI_API_KEY=$($env:OPENAI_API_KEY)")
}
if ($env:GEMINI_API_KEY) {
    $dcArgs += @('--remote-env', "GOOGLE_GENERATIVE_AI_API_KEY=$($env:GEMINI_API_KEY)")
}

$dcArgs += @(
    '--',
    'opencode', 'run',
    '--model',      $Model,
    '--agent',      $Agent,
    '--log-level',  $LogLevel,
    '--print-logs',
    '--thinking',
    '--dir',        $containerDir,
    $PromptString
)

# --- Execute -----------------------------------------------------------------

Write-Host "[prompt-direct] model: $Model | agent: $Agent | log-level: $LogLevel"
Write-Host "[prompt-direct] container: $containerId | dir: $containerDir"
Write-Host "[prompt-direct] prompt: $($PromptString.Length) chars"
Write-Host '---'

devcontainer @dcArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "devcontainer exec failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
