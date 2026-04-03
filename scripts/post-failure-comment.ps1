#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Posts an enriched failure diagnostic comment on the triggering GitHub issue.

.DESCRIPTION
    When the orchestrator agent execution fails (typically due to idle timeout),
    this script constructs a structured markdown comment containing run context,
    likely cause analysis, recovery options, and workflow details, then posts it
    to the originating issue via the GitHub CLI.

    The script also emits GitHub Actions CI annotations (::error:: and ::notice::)
    so the failure is surfaced in the workflow summary.

.PARAMETER IssueNumber
    The GitHub issue number to post the failure comment on.

.PARAMETER Label
    The trigger label that initiated the orchestrator run.

.PARAMETER IssueTitle
    The title of the triggering issue.

.PARAMETER Actor
    The GitHub username that triggered the workflow.

.PARAMETER EventName
    The GitHub Actions event name (e.g. 'issues').

.PARAMETER EventAction
    The GitHub Actions event action (e.g. 'labeled').

.EXAMPLE
    ./scripts/post-failure-comment.ps1 -IssueNumber 42 -Label 'agent:plan' `
        -IssueTitle 'Implement feature X' -Actor 'octocat' `
        -EventName 'issues' -EventAction 'labeled'

.NOTES
    Requires: gh CLI authenticated with repo scope.
    Environment variables read from the GitHub Actions runner context:
      GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID,
      GITHUB_RUN_NUMBER, GITHUB_SHA, GITHUB_REF
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$IssueNumber,

    [Parameter(Mandatory)]
    [string]$Label,

    [Parameter(Mandatory)]
    [string]$IssueTitle,

    [Parameter(Mandatory)]
    [string]$Actor,

    [Parameter(Mandatory)]
    [string]$EventName,

    [Parameter(Mandatory)]
    [string]$EventAction
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
$ServerUrl  = Get-RequiredEnv 'GITHUB_SERVER_URL'
$RunId      = Get-RequiredEnv 'GITHUB_RUN_ID'
$RunNumber  = Get-RequiredEnv 'GITHUB_RUN_NUMBER'
$Sha        = Get-RequiredEnv 'GITHUB_SHA'
$Ref        = Get-RequiredEnv 'GITHUB_REF'
$RunUrl     = "$ServerUrl/$Repo/actions/runs/$RunId"

# ---------------------------------------------------------------------------
# CI annotation — error
# ---------------------------------------------------------------------------
Write-Output "::error::Orchestrator agent step failed — posting diagnostic comment to issue #$IssueNumber"

# ---------------------------------------------------------------------------
# Build the markdown comment body
# ---------------------------------------------------------------------------
$Body = @"
## :x: Orchestrator Run Failed

| Field | Value |
|-------|-------|
| **Run** | [#${RunNumber}](${RunUrl}) |
| **Trigger label** | ``${Label}`` |
| **Issue** | #${IssueNumber} — ${IssueTitle} |
| **Actor** | ${Actor} |
| **Event** | ``${EventName}.${EventAction}`` |
| **Ref / SHA** | ``${Ref}`` / ``${Sha}`` |

### Likely Cause
Agent idle timeout — opencode produced no client or server output for 15 minutes and was terminated (``SIGTERM``, exit 143).
When this happens the LLM prompt's own error-handling logic **does not execute** — the process is killed before it can react.

### Recovery Options
1. **Retry**: Remove and re-apply the ``${Label}`` label on this issue
2. **Manual**: Complete the stalled orchestration step by hand, then apply the next label in the sequence
3. **Debug**: Download [trace artifacts](${RunUrl}#artifacts) and check the opencode session logs

### Workflow Context
- Idle watchdog: ``IDLE_TIMEOUT_SECS=900`` (15 min), ``HARD_CEILING_SECS=5400`` (90 min)
- The watchdog monitors **both** client stdout staleness and server ``/proc/<pid>/io`` write_bytes
- Kill sequence: ``SIGTERM`` → 10s grace → ``SIGKILL``
"@

# ---------------------------------------------------------------------------
# Post the comment via gh CLI (arg-splatting)
# ---------------------------------------------------------------------------
$ghArgs = @(
    'issue', 'comment', $IssueNumber
    '--repo',  $Repo
    '--body',  $Body
)
& gh @ghArgs
if ($LASTEXITCODE -ne 0) {
    throw "gh issue comment failed with exit code $LASTEXITCODE"
}

# ---------------------------------------------------------------------------
# CI annotation — notice
# ---------------------------------------------------------------------------
Write-Output "::notice::Failure comment posted to issue #$IssueNumber"
