#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Resolves Docker image tags from CI context environment variables.

.DESCRIPTION
    Computes Docker image tags (branch-latest, versioned, etc.) from GitHub Actions
    CI context. Supports both direct push/PR events and workflow_run events.

    When the event is "workflow_run", the branch and run number are taken from the
    triggering workflow run. Otherwise they come from the current ref and run number.

    Outputs are written to GITHUB_OUTPUT when running in GitHub Actions, or printed
    to stdout for local/diagnostic use.

.PARAMETER EventName
    The GitHub Actions event name (e.g. push, pull_request, workflow_run).
    Falls back to the EVENT_NAME environment variable.

.PARAMETER RefName
    The git ref name (branch or tag). Falls back to REF_NAME env var.

.PARAMETER RunNumber
    The current workflow run number. Falls back to RUN_NUMBER env var.

.PARAMETER WorkflowRunHeadBranch
    The head branch of the triggering workflow_run event.
    Falls back to WORKFLOW_RUN_HEAD_BRANCH env var.

.PARAMETER WorkflowRunRunNumber
    The run number of the triggering workflow_run event.
    Falls back to WORKFLOW_RUN_RUN_NUMBER env var.

.PARAMETER VersionPrefix
    Semantic version prefix (major.minor). Falls back to VERSION_PREFIX env var,
    defaulting to "0.0".

.EXAMPLE
    # Direct invocation with parameters
    ./resolve-image-tags.ps1 -EventName push -RefName main -RunNumber 42

.EXAMPLE
    # Using environment variables (typical in GitHub Actions)
    $env:EVENT_NAME = 'workflow_run'
    $env:WORKFLOW_RUN_HEAD_BRANCH = 'feature/foo'
    $env:WORKFLOW_RUN_RUN_NUMBER = '7'
    ./resolve-image-tags.ps1

.NOTES
    Cross-platform PowerShell 7+ equivalent of resolve-image-tags.sh.
    Requires pwsh (PowerShell 7+).
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$EventName = $env:EVENT_NAME,

    [Parameter()]
    [string]$RefName = $env:REF_NAME,

    [Parameter()]
    [string]$RunNumber = $env:RUN_NUMBER,

    [Parameter()]
    [string]$WorkflowRunHeadBranch = $env:WORKFLOW_RUN_HEAD_BRANCH,

    [Parameter()]
    [string]$WorkflowRunRunNumber = $env:WORKFLOW_RUN_RUN_NUMBER,

    [Parameter()]
    [string]$VersionPrefix = $(if ($env:VERSION_PREFIX) { $env:VERSION_PREFIX } else { '0.0' })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Validate required input ------------------------------------------------

if ([string]::IsNullOrEmpty($EventName)) {
    Write-Error 'EVENT_NAME is required'
}

# --- Determine branch name and effective run number --------------------------

if ($EventName -eq 'workflow_run') {
    $BranchName          = $WorkflowRunHeadBranch
    $EffectiveRunNumber  = $WorkflowRunRunNumber
}
else {
    $BranchName          = $RefName
    $EffectiveRunNumber  = $RunNumber
}

if ([string]::IsNullOrEmpty($BranchName)) {
    Write-Error "Unable to determine branch name for event '$EventName'"
}

if ([string]::IsNullOrEmpty($EffectiveRunNumber)) {
    Write-Error "Unable to determine run number for event '$EventName'"
}

# --- Compute image tags ------------------------------------------------------

$LatestTag       = "$BranchName-latest"
$VersionImageTag = "$VersionPrefix.$EffectiveRunNumber"
$VersionedTag    = "$BranchName-$VersionImageTag"

# --- Write outputs -----------------------------------------------------------

$outputs = @(
    "branch_name=$BranchName"
    "run_number=$EffectiveRunNumber"
    "latest_tag=$LatestTag"
    "version_image_tag=$VersionImageTag"
    "versioned_tag=$VersionedTag"
)

if ($env:GITHUB_OUTPUT) {
    $outputs | Add-Content -Path $env:GITHUB_OUTPUT -Encoding utf8
}
else {
    $outputs | ForEach-Object { Write-Output $_ }
}
