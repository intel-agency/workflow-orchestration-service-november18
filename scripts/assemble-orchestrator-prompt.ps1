#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Assembles the orchestrator agent prompt by injecting GitHub event data into the prompt template.

.DESCRIPTION
    Called from orchestrator-agent.yml. Reads a prompt template, replaces the
    {{__EVENT_DATA__}} injection point with structured GitHub event context and
    the raw event JSON, then writes the assembled prompt to disk.

    If the CUSTOM_PROMPT environment variable is set, it is written directly as
    the assembled prompt and template processing is skipped.

    The script sets ORCHESTRATOR_PROMPT_PATH in GITHUB_ENV so downstream steps
    can locate the assembled file.

.PARAMETER EventName
    The GitHub event name (e.g. issues, pull_request, workflow_dispatch).

.PARAMETER EventAction
    The event action (e.g. opened, closed, labeled).

.PARAMETER Actor
    The GitHub actor (username) that triggered the event.

.PARAMETER Repository
    The full repository name (owner/repo).

.PARAMETER Ref
    The git ref associated with the event.

.PARAMETER SHA
    The git commit SHA associated with the event.

.EXAMPLE
    ./scripts/assemble-orchestrator-prompt.ps1 issues opened octocat owner/repo refs/heads/main abc123

.NOTES
    Requires PowerShell 7+. Cross-platform (Windows, Linux, macOS).
    Environment variables:
      EVENT_JSON     - Raw JSON payload of the GitHub event (required unless CUSTOM_PROMPT is set).
      CUSTOM_PROMPT  - If set, used as the assembled prompt verbatim (template is skipped).
      GITHUB_ENV     - Path to the GitHub Actions environment file.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$EventName = '',

    [Parameter(Position = 1)]
    [string]$EventAction = '',

    [Parameter(Position = 2)]
    [string]$Actor = '',

    [Parameter(Position = 3)]
    [string]$Repository = '',

    [Parameter(Position = 4)]
    [string]$Ref = '',

    [Parameter(Position = 5)]
    [string]$SHA = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$AssembledPrompt = '.assembled-orchestrator-prompt.md'
$PromptTemplate  = '.github/workflows/prompts/orchestrator-agent-prompt.md'

# ── Custom prompt short-circuit ──────────────────────────────────────────────
$customPrompt = $env:CUSTOM_PROMPT
if ($customPrompt) {
    Write-Output '::notice::Using custom prompt from workflow_dispatch input'
    Set-Content -Path $AssembledPrompt -Value $customPrompt -NoNewline
    if ($env:GITHUB_ENV) {
        Add-Content -Path $env:GITHUB_ENV -Value "ORCHESTRATOR_PROMPT_PATH=$AssembledPrompt"
    }
    exit 0
}

$eventJson = $env:EVENT_JSON
if ([string]::IsNullOrWhiteSpace($eventJson)) {
    Write-Error 'EVENT_JSON environment variable is required when CUSTOM_PROMPT is not set'
}

# ── Event metadata ───────────────────────────────────────────────────────────
Write-Output '::group::Event metadata'
Write-Output "event_name=$EventName"
Write-Output "event.action=$EventAction"
Write-Output "actor=$Actor"
Write-Output "repository=$Repository"
Write-Output "ref=$Ref"
Write-Output "sha=$SHA"
Write-Output '::endgroup::'

$eventBlock = @"
          Event Name: $EventName
          Action: $EventAction
          Actor: $Actor
          Repository: $Repository
          Ref: $Ref
          SHA: $SHA
"@

# ── Template diagnostics ─────────────────────────────────────────────────────
Write-Output '::group::Template diagnostics'
Write-Output "Template path: $PromptTemplate"

$templateExists = Test-Path -LiteralPath $PromptTemplate
Write-Output "Template exists: $(if ($templateExists) { 'YES' } else { 'NO' })"

if (-not $templateExists) {
    Write-Error "Prompt template not found: $PromptTemplate"
}

$templateContent = Get-Content -LiteralPath $PromptTemplate -Raw
$templateLines   = Get-Content -LiteralPath $PromptTemplate

Write-Output "Template size: $($templateContent.Length) bytes, $($templateLines.Count) lines"

Write-Output 'Injection point occurrences:'
$injectionHits = $templateLines |
    Select-String -Pattern '{{__EVENT_DATA__}}' -SimpleMatch
if ($injectionHits) {
    $injectionHits | ForEach-Object { Write-Output $_.ToString() }
} else {
    Write-Output '  WARNING: no {{__EVENT_DATA__}} found in template!'
}
Write-Output '::endgroup::'

# ── Assemble prompt ──────────────────────────────────────────────────────────
# Equivalent of: sed '/{{__EVENT_DATA__}}/,$ d' — keep lines before the marker.
$markerIndex = -1
for ($i = 0; $i -lt $templateLines.Count; $i++) {
    if ($templateLines[$i].Contains('{{__EVENT_DATA__}}')) {
        $markerIndex = $i
        break
    }
}

if ($markerIndex -lt 0) {
    $beforeMarker = $templateLines
} elseif ($markerIndex -eq 0) {
    $beforeMarker = @()
} else {
    $beforeMarker = $templateLines[0..($markerIndex - 1)]
}

$assembled = @(
    $beforeMarker
    $eventBlock
    ''
    '```json'
    $eventJson
    '```'
) -join "`n"

Set-Content -Path $AssembledPrompt -Value $assembled -NoNewline

# ── Assembled prompt diagnostics ─────────────────────────────────────────────
Write-Output '::group::Assembled prompt diagnostics'
Write-Output "Output path: $AssembledPrompt"

$outputExists = Test-Path -LiteralPath $AssembledPrompt
Write-Output "Output exists: $(if ($outputExists) { 'YES' } else { 'NO' })"

$outputContent = Get-Content -LiteralPath $AssembledPrompt -Raw
$outputLines   = Get-Content -LiteralPath $AssembledPrompt

Write-Output "Output size: $($outputContent.Length) bytes, $($outputLines.Count) lines"

Write-Output '--- First 20 lines ---'
$outputLines | Select-Object -First 20 | ForEach-Object { Write-Output $_ }

Write-Output '--- Last 30 lines ---'
$outputLines | Select-Object -Last 30 | ForEach-Object { Write-Output $_ }

# Helper: count matching lines (returns 0 when nothing matches, like grep -c || echo 0)
function Get-MatchCount {
    param([string[]]$Lines, [string]$Pattern)
    ($Lines | Select-String -Pattern $Pattern -SimpleMatch).Count
}

Write-Output '--- Key sections present ---'
Write-Output "  Instructions:      $(Get-MatchCount $outputLines '## Instructions')"
Write-Output "  Branching Logic:   $(Get-MatchCount $outputLines 'EVENT_DATA Branching Logic')"
Write-Output "  Match Clauses:     $(Get-MatchCount $outputLines '## Match Clause Cases')"
Write-Output "  Helper Functions:  $(Get-MatchCount $outputLines '## Helper Functions')"
Write-Output "  Final section:     $(Get-MatchCount $outputLines '## Final')"
Write-Output "  Event Name line:   $(Get-MatchCount $outputLines 'Event Name:')"
Write-Output "  JSON code block:   $(($outputLines | Select-String -Pattern '^\`\`\`json').Count)"
Write-Output "  Injection leftover:$(Get-MatchCount $outputLines '{{__EVENT_DATA__}}')"
Write-Output '::endgroup::'

# ── Export prompt path ───────────────────────────────────────────────────────
if ($env:GITHUB_ENV) {
    Add-Content -Path $env:GITHUB_ENV -Value "ORCHESTRATOR_PROMPT_PATH=$AssembledPrompt"
}
