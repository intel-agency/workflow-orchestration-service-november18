#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Triggers an orchestrator-agent workflow by creating a dispatch issue.

.DESCRIPTION
    Creates a dispatch issue on the specified GitHub repository using the gh CLI,
    then waits briefly and lists the most recent orchestrator-agent workflow run
    to confirm the workflow was triggered.

.PARAMETER Repo
    The owner/name of the target GitHub repository.
    Defaults to 'intel-agency/workflow-orchestration-queue-uniform39'.

.EXAMPLE
    ./trigger-orchestrator-test.ps1
    # Uses the default repository.

.EXAMPLE
    ./trigger-orchestrator-test.ps1 -Repo 'myorg/my-repo'
    # Targets a custom repository.

.NOTES
    Requires GitHub CLI (gh) to be installed and authenticated.
    PowerShell 7+ cross-platform equivalent of trigger-orchestrator-test.sh.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Repo = 'intel-agency/workflow-orchestration-queue-uniform39'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($IsWindows) {
    $env:GH_PAGER = 'more'
} else {
    $env:GH_PAGER = 'cat'
}

$Title = 'orchestrate-dynamic-workflow'
$Body = @'
/orchestrate-dynamic-workflow
$workflow_name = create-epic-v2 { $phase = "1", $line_item = "1.1" }
'@

Write-Host "Creating dispatch issue on ${Repo}..."
Write-Host "  Title: ${Title}"
Write-Host "  Body:  ${Body}"
Write-Host ''

$ghCreateArgs = @(
    'issue', 'create'
    '--repo', $Repo
    '--title', $Title
    '--body', $Body
)
$IssueUrl = & gh @ghCreateArgs
if ($LASTEXITCODE -ne 0) {
    throw "gh issue create failed with exit code ${LASTEXITCODE}"
}

Write-Host "Issue created: ${IssueUrl}"
Write-Host ''
Write-Host 'Waiting for orchestrator-agent workflow to start...'
Start-Sleep -Seconds 5

$ghRunArgs = @(
    'run', 'list'
    '--repo', $Repo
    '--workflow=orchestrator-agent.yml'
    '--limit', '1'
    '--json', 'status,conclusion,headBranch,displayTitle,databaseId,url'
)
& gh @ghRunArgs
if ($LASTEXITCODE -ne 0) {
    throw "gh run list failed with exit code ${LASTEXITCODE}"
}
