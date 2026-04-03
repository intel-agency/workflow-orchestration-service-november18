#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Collect trace artifacts from the devcontainer and print job outcome summary.

.DESCRIPTION
    Called from the orchestrate job's always() steps.
    Gathers opencode logs, server logs, and subagent traces from inside the
    devcontainer, extracts them to a local trace-artifacts directory, then
    prints a job outcome summary with CI annotations.

    Individual trace-collection commands are wrapped in try/catch because
    failures are expected (missing files, container not started, etc.).

.PARAMETER JobStatus
    The orchestrate job status ("success", "failure", "cancelled").

.PARAMETER EventName
    The GitHub Actions event name (e.g. "issues").

.PARAMETER EventAction
    The GitHub Actions event action (e.g. "labeled").

.PARAMETER Label
    The trigger label that initiated the orchestrator run (may be empty).

.PARAMETER Actor
    The GitHub username that triggered the workflow.

.EXAMPLE
    ./scripts/collect-trace-artifacts.ps1 -JobStatus failure `
        -EventName issues -EventAction labeled `
        -Label 'agent:plan' -Actor octocat

.NOTES
    Requires: devcontainer CLI on PATH.
    Environment variables read from the GitHub Actions runner context:
      GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_NUMBER, GITHUB_SHA, GITHUB_REF
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('success', 'failure', 'cancelled')]
    [string]$JobStatus,

    [Parameter(Mandatory)]
    [string]$EventName,

    [Parameter(Mandatory)]
    [string]$EventAction,

    [Parameter()]
    [string]$Label,

    [Parameter(Mandatory)]
[string]$Actor
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Resolve required environment variables
# ---------------------------------------------------------------------------
function Get-RequiredEnv([string]$Name) {
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) {
        throw "Required environment variable '$Name' is not set."
    }
    return $value
}

$Repo      = Get-RequiredEnv 'GITHUB_REPOSITORY'
$RunId     = Get-RequiredEnv 'GITHUB_RUN_ID'
$RunNumber = Get-RequiredEnv 'GITHUB_RUN_NUMBER'
$Sha       = Get-RequiredEnv 'GITHUB_SHA'
$Ref       = Get-RequiredEnv 'GITHUB_REF'

$LabelDisplay = if ([string]::IsNullOrEmpty($Label)) { 'N/A' } else { $Label }

# ---------------------------------------------------------------------------
# Cross-platform temp paths
# ---------------------------------------------------------------------------
$TraceArtifactsDir = Join-Path ([IO.Path]::GetTempPath()) "trace-artifacts-$RunId"

# Clear stale artifacts from a prior attempt for this run
if (Test-Path $TraceArtifactsDir) {
    Remove-Item -Recurse -Force $TraceArtifactsDir
}

function Write-DevcontainerWarning {
    param(
        [string]$StepName,
        [int]$ExitCode
    )

    Write-Warning "devcontainer exec ($StepName) failed with exit code $ExitCode"
}

# ── Collect trace artifacts ─────────────────────────────────────────
Write-Output '::group::Trace artifact collection (runs on success AND failure)'
Write-Output "Job status: $JobStatus"
Write-Output 'Run outcome will be preserved in trace artifacts for post-mortem analysis'

if (-not (Test-Path $TraceArtifactsDir)) {
    New-Item -ItemType Directory -Path $TraceArtifactsDir -Force | Out-Null
}

# Step 1 — Gather logs inside the devcontainer
devcontainer exec `
    --workspace-folder . `
    --config .devcontainer/devcontainer.json `
    -- bash -c "
        mkdir -p /tmp/trace-bundle;
        cp ~/.local/share/opencode/log/*.log /tmp/trace-bundle/ 2>/dev/null || true;
        cp /tmp/opencode-serve.log /tmp/trace-bundle/opencode-serve.log 2>/dev/null || true;
        python3 scripts/trace-extract.py --scrub > /tmp/trace-bundle/subagent-traces.txt 2>&1 || true;
    "
if ($LASTEXITCODE -ne 0) {
    Write-DevcontainerWarning -StepName 'gather logs' -ExitCode $LASTEXITCODE
}

# Step 2 — Extract subagent traces text file
$subagentOut = Join-Path $TraceArtifactsDir 'subagent-traces.txt'
devcontainer exec `
    --workspace-folder . `
    --config .devcontainer/devcontainer.json `
    -- bash -c 'cat /tmp/trace-bundle/subagent-traces.txt' > $subagentOut 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-DevcontainerWarning -StepName 'subagent traces' -ExitCode $LASTEXITCODE
}

# Step 3 — Extract full trace bundle via temp file to avoid PowerShell binary-pipeline corruption
$bundleTar = Join-Path $TraceArtifactsDir 'trace-bundle.tar'
devcontainer exec `
    --workspace-folder . `
    --config .devcontainer/devcontainer.json `
    -- bash -c 'tar -cf - -C /tmp/trace-bundle .' > $bundleTar 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-DevcontainerWarning -StepName 'tar bundle export' -ExitCode $LASTEXITCODE
} elseif (Test-Path -LiteralPath $bundleTar) {
    tar -xf $bundleTar -C $TraceArtifactsDir 2>$null
    Remove-Item $bundleTar -ErrorAction SilentlyContinue
}

# Count and list collected artifacts
$artifacts = @(Get-ChildItem -Path $TraceArtifactsDir -File -ErrorAction SilentlyContinue)
$artifactCount = $artifacts.Count
Write-Output "Trace artifacts collected: $artifactCount files"

if ($artifactCount -eq 0) {
    Write-Output '::warning::No trace artifacts found — devcontainer may not have started or logs were not produced'
} else {
    Write-Output 'Artifact listing:'
    $artifacts |
        Sort-Object Length -Descending |
        Format-Table Name, @{Label='Size'; Expression={
            if ($_.Length -ge 1MB) { '{0:N1} MB' -f ($_.Length / 1MB) }
            elseif ($_.Length -ge 1KB) { '{0:N1} KB' -f ($_.Length / 1KB) }
            else { '{0} B' -f $_.Length }
        }}, LastWriteTime -AutoSize |
        Out-String |
        Write-Output
}
Write-Output '::endgroup::'

# ── Job outcome summary ─────────────────────────────────────────────
Write-Output '========================================'
Write-Output " ORCHESTRATOR JOB OUTCOME: $JobStatus"
Write-Output '========================================'
Write-Output "Run:    #$RunNumber (ID: $RunId)"
Write-Output "Event:  $EventName.$EventAction"
Write-Output "Label:  $LabelDisplay"
Write-Output "Actor:  $Actor"
Write-Output "Repo:   $Repo"
Write-Output "Ref:    $Ref"
Write-Output "SHA:    $Sha"

switch ($JobStatus) {
    'failure' {
        Write-Output "::error::Orchestrator job FAILED — check 'Post failure comment' step and trace artifacts for diagnostics"
    }
    'success' {
        Write-Output '::notice::Orchestrator job completed successfully'
    }
    default {
        Write-Output "::warning::Orchestrator job ended with status: $JobStatus"
    }
}
Write-Output '========================================'
