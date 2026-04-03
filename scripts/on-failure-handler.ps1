#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Dedicated failure handler for the orchestrator workflow.

.DESCRIPTION
    Runs in the on-failure job after the orchestrate job fails.
    Gathers context, fetches failed job details via the GitHub API,
    posts a catch-all comment to the triggering issue (with dedup to
    avoid duplicating the in-job failure comment), and annotates the
    workflow run with ::error:: annotations.

.PARAMETER EventName
    The GitHub Actions event name (e.g. 'issues').

.PARAMETER EventAction
    The GitHub Actions event action (e.g. 'labeled').

.PARAMETER Label
    The trigger label name that initiated the orchestrator run.

.PARAMETER Actor
    The GitHub username that triggered the workflow.

.PARAMETER IssueNumber
    The GitHub issue number (may be empty for non-issue events).

.PARAMETER IssueTitle
    The title of the triggering issue (may be empty for non-issue events).

.EXAMPLE
    ./scripts/on-failure-handler.ps1 -EventName 'issues' -EventAction 'labeled' `
        -Label 'agent:plan' -Actor 'octocat' `
        -IssueNumber 42 -IssueTitle 'Implement feature X'

.NOTES
    Requires: gh CLI authenticated with repo scope.
    Environment variables read from the GitHub Actions runner context:
      GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID, GITHUB_RUN_NUMBER
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EventName,

    [Parameter(Mandatory)]
    [string]$EventAction,

    [Parameter(Mandatory)]
    [string]$Label,

    [Parameter(Mandatory)]
    [string]$Actor,

    [Parameter()]
    [string]$IssueNumber,

    [Parameter()]
    [string]$IssueTitle
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
$ServerUrl = Get-RequiredEnv 'GITHUB_SERVER_URL'
$RunId     = Get-RequiredEnv 'GITHUB_RUN_ID'
$RunNumber = Get-RequiredEnv 'GITHUB_RUN_NUMBER'
$RunUrl    = "$ServerUrl/$Repo/actions/runs/$RunId"

$LabelDisplay = if ([string]::IsNullOrEmpty($Label)) { 'N/A' } else { $Label }

# ── Step 1: Gather context ──────────────────────────────────────────
Write-Output '========================================'
Write-Output ' ON-FAILURE HANDLER'
Write-Output ' Orchestrate job failed — running'
Write-Output ' post-failure diagnostics'
Write-Output '========================================'
Write-Output "Run:    #$RunNumber (ID: $RunId)"
Write-Output "Event:  $EventName.$EventAction"
Write-Output "Label:  $LabelDisplay"
Write-Output "Actor:  $Actor"
Write-Output "Repo:   $Repo"
Write-Output ''

# ── Failed job details ──────────────────────────────────────────────
Write-Output '::group::Failed job details'
try {
    $ghApiJobsArgs = @(
        'api'
        "repos/$Repo/actions/runs/$RunId/jobs"
        '--jq', '.jobs[] | select(.conclusion == "failure") | {name, conclusion, started_at, completed_at, html_url}'
    )
    & gh @ghApiJobsArgs 2>$null
} catch {
    Write-Output 'Could not fetch job details'
}
if ($LASTEXITCODE -ne 0) {
    Write-Output 'Could not fetch job details'
}
Write-Output '::endgroup::'

# ── Run start time ──────────────────────────────────────────────────
try {
    $ghApiRunArgs = @(
        'api'
        "repos/$Repo/actions/runs/$RunId"
        '--jq', '.run_started_at'
    )
    $Started = & gh @ghApiRunArgs 2>$null
} catch {
    $Started = $null
}
if (-not [string]::IsNullOrEmpty($Started)) {
    Write-Output "Run started at: $Started"
}

# ── Step 2: Post catch-all comment (with dedup) ─────────────────────
if ($EventName -eq 'issues' -and -not [string]::IsNullOrEmpty($IssueNumber)) {
    $ExistingCount = 0
    try {
        $ghApiCommentsArgs = @(
            'api'
            "repos/$Repo/issues/$IssueNumber/comments"
        )
        $commentsJson = & gh @ghApiCommentsArgs 2>$null
        $comments = $commentsJson | ConvertFrom-Json -ErrorAction Stop
        $ExistingCount = @($comments | Where-Object {
            $_.body -match 'Orchestrator [Rr]un [Ff]ailed'
        }).Count
    } catch {
        $ExistingCount = 0
    }

    if ($ExistingCount -gt 0) {
        Write-Output '::notice::In-job failure comment already posted — skipping duplicate from on-failure handler'
    } else {
        $Body = @"
## :x: Orchestrator Workflow Failed (on-failure handler)

The orchestrator job failed **before** the agent execution step completed.
This typically means a setup failure (devcontainer build, image pull, prompt assembly, etc.).

| Field | Value |
|-------|-------|
| **Run** | [#$RunNumber]($RunUrl) |
| **Trigger label** | ``$Label`` |
| **Issue** | #$IssueNumber — $IssueTitle |
| **Event** | ``$EventName.$EventAction`` |

### Recovery
1. Check the [workflow run logs]($RunUrl) to identify which step failed
2. Fix the underlying issue (image not found, secret missing, etc.)
3. Remove and re-apply ``$Label`` to retry
"@

        $ghCommentArgs = @(
            'issue', 'comment', $IssueNumber
            '--repo',  $Repo
            '--body',  $Body
        )
        & gh @ghCommentArgs
        if ($LASTEXITCODE -ne 0) {
            throw "gh issue comment failed with exit code $LASTEXITCODE"
        }
        Write-Output "::notice::On-failure handler posted catch-all comment to issue #$IssueNumber"
    }
}

# ── Step 3: Annotate the run ────────────────────────────────────────
Write-Output "::error::ORCHESTRATOR FAILED — The 'orchestrate' job did not complete successfully."
Write-Output "::error::Event: $EventName.$EventAction | Label: $LabelDisplay | Run: #$RunNumber"
Write-Output "::error::Review the 'orchestrate' job logs and trace artifacts for root cause."
