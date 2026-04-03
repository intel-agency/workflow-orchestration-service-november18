#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sets up and validates the local .env file for development.

.DESCRIPTION
    Cross-platform PowerShell equivalent of scripts/setup-local-env.sh.
    Copies .env.example to .env (if .env does not already exist), sources the
    variables, validates that all required keys are present, and optionally
    authenticates Docker to ghcr.io via the GitHub CLI.

.PARAMETER CheckOnly
    Only validate environment variables — do not create or copy files.

.PARAMETER GhcrLogin
    After validation, authenticate Docker to ghcr.io using `gh auth token`.

.EXAMPLE
    ./scripts/setup-local-env.ps1
    # Creates .env from .env.example (if needed) and validates required vars.

.EXAMPLE
    ./scripts/setup-local-env.ps1 -CheckOnly
    # Validates environment variables without touching files.

.EXAMPLE
    ./scripts/setup-local-env.ps1 -GhcrLogin
    # Sets up .env, validates, then logs Docker into ghcr.io.

.NOTES
    Requires PowerShell 7+. On all platforms, paths are resolved with Join-Path.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$CheckOnly,

    [Parameter()]
    [switch]$GhcrLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$EnvExample = Join-Path $RepoRoot '.env.example'
$EnvFile    = Join-Path $RepoRoot '.env'

function Write-LogMessage {
    param([string]$Message)
    Write-Host "[setup-local-env] $Message"
}

# ---------------------------------------------------------------------------
# 1. Copy .env.example → .env (unless --CheckOnly)
# ---------------------------------------------------------------------------
if (-not $CheckOnly) {
    if (Test-Path $EnvFile) {
        Write-LogMessage '.env already exists — not overwriting'
    }
    else {
        if (-not (Test-Path $EnvExample)) {
            Write-Error "ERROR: $EnvExample not found"
        }
        Copy-Item -Path $EnvExample -Destination $EnvFile
        Write-LogMessage 'Created .env from .env.example — edit it to add your API keys'
    }
}

# ---------------------------------------------------------------------------
# 2. Source .env into the current process environment
# ---------------------------------------------------------------------------
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content -Path $EnvFile) {
        # Skip comments and blank lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        # Match KEY=VALUE (value may be quoted)
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $key   = $Matches[1]
            $value = $Matches[2].Trim()

            # Strip surrounding quotes (single or double)
            if ($value.Length -ge 2 -and
                (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                 ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
    }
    Write-LogMessage "Sourced $EnvFile"
}

# ---------------------------------------------------------------------------
# 3. Validate required variables
# ---------------------------------------------------------------------------
$RequiredVars = @(
    'GH_ORCHESTRATION_AGENT_TOKEN'
    'ZHIPU_API_KEY'
    'KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY'
)

$Missing = @()
foreach ($var in $RequiredVars) {
    $val = [System.Environment]::GetEnvironmentVariable($var, 'Process')
    if ([string]::IsNullOrEmpty($val)) {
        $Missing += $var
    }
}

if ($Missing.Count -gt 0) {
    Write-Host ''
    Write-LogMessage 'WARNING: The following required variables are not set:'
    foreach ($var in $Missing) {
        Write-Host "  - $var"
    }
    Write-Host ''
    Write-LogMessage 'Edit .env and fill in the values, then re-run this script.'
    if ($CheckOnly) {
        exit 1
    }
}
else {
    Write-LogMessage 'All required variables are set'
}

# ---------------------------------------------------------------------------
# 4. Optional GHCR login
# ---------------------------------------------------------------------------
if ($GhcrLogin) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error 'ERROR: gh CLI not found — install it from https://cli.github.com'
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error 'ERROR: docker not found'
    }

    Write-LogMessage 'Logging into ghcr.io via gh CLI...'
    $ghUser  = gh api user --jq '.login'
    if ($LASTEXITCODE -ne 0) { Write-Error 'Failed to retrieve GitHub username via gh CLI' }

    $ghToken = gh auth token
    if ($LASTEXITCODE -ne 0) { Write-Error 'Failed to retrieve auth token via gh CLI' }

    $ghToken | docker login ghcr.io -u $ghUser --password-stdin
    if ($LASTEXITCODE -ne 0) { Write-Error 'docker login to ghcr.io failed' }

    Write-LogMessage 'GHCR login successful'
}

# ---------------------------------------------------------------------------
# 5. Environment summary
# ---------------------------------------------------------------------------
function Get-MaskedValue {
    param(
        [string]$VarName,
        [switch]$Required
    )
    $val = [System.Environment]::GetEnvironmentVariable($VarName, 'Process')
    if (-not [string]::IsNullOrEmpty($val)) {
        return "SET ($($val.Length) chars)"
    }
    return $Required ? 'not set (required)' : 'not set (optional)'
}

$portValue = [System.Environment]::GetEnvironmentVariable('OPENCODE_SERVER_PORT', 'Process')
if ([string]::IsNullOrEmpty($portValue)) { $portValue = '4096 (default)' }

Write-Host ''
Write-LogMessage '=== Environment Summary ==='
Write-LogMessage "  GH_ORCHESTRATION_AGENT_TOKEN: $(Get-MaskedValue 'GH_ORCHESTRATION_AGENT_TOKEN' -Required)"
Write-LogMessage "  ZHIPU_API_KEY:                $(Get-MaskedValue 'ZHIPU_API_KEY' -Required)"
Write-LogMessage "  KIMI_CODE_..._API_KEY:        $(Get-MaskedValue 'KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY' -Required)"
Write-LogMessage "  OPENAI_API_KEY:               $(Get-MaskedValue 'OPENAI_API_KEY')"
Write-LogMessage "  GEMINI_API_KEY:               $(Get-MaskedValue 'GEMINI_API_KEY')"
Write-LogMessage "  OPENCODE_SERVER_PORT:         $portValue"
Write-Host ''
