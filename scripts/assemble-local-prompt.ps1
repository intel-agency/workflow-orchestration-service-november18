#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Assembles an orchestrator prompt for local testing.

.DESCRIPTION
    Builds a ready-to-use orchestrator prompt file in one of two modes:

      Freeform  (-PromptString)  Wraps a user-supplied string with a minimal
                                 context header (timestamp, repository URL).

      Fixture   (-FixtureFile)   Reads a JSON event fixture, extracts metadata
                                 (action, actor, repo), and injects the data into
                                 the orchestrator-agent-prompt.md template.

    The assembled prompt is written to .assembled-orchestrator-prompt.md by
    default (override with -OutputFile).

.PARAMETER PromptString
    Freeform prompt text.  Mutually exclusive with -FixtureFile.

.PARAMETER FixtureFile
    Path to a JSON event fixture file (e.g. test/fixtures/issues-opened.json).
    Mutually exclusive with -PromptString.

.PARAMETER OutputFile
    Destination path for the assembled prompt.
    Default: <repo-root>/.assembled-orchestrator-prompt.md

.EXAMPLE
    pwsh scripts/assemble-local-prompt.ps1 -PromptString "say hello"

.EXAMPLE
    pwsh scripts/assemble-local-prompt.ps1 -FixtureFile test/fixtures/issues-opened.json

.EXAMPLE
    pwsh scripts/assemble-local-prompt.ps1 -PromptString "list issues" -OutputFile my-prompt.md

.NOTES
    Requires PowerShell 7+.  Uses ConvertFrom-Json for JSON parsing (no jq dependency).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PromptString,

    [Parameter(Mandatory = $false)]
    [string]$FixtureFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -----------------------------------------------------------------------
# Resolve paths
# -----------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot  = Split-Path -Parent $ScriptDir
$PromptTemplate = Join-Path $RepoRoot '.github' 'workflows' 'prompts' 'orchestrator-agent-prompt.md'

if (-not $OutputFile) {
    $OutputFile = Join-Path $RepoRoot '.assembled-orchestrator-prompt.md'
}

# -----------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------
if (-not $PromptString -and -not $FixtureFile) {
    Write-Error 'Either -PromptString or -FixtureFile is required.'
}

if ($PromptString -and $FixtureFile) {
    Write-Error '-PromptString and -FixtureFile are mutually exclusive.'
}

# -----------------------------------------------------------------------
# Freeform mode — wrap user prompt with minimal context
# -----------------------------------------------------------------------
if ($PromptString) {
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    try {
        $repoUrl = git -C $RepoRoot config --get remote.origin.url 2>$null
    }
    catch {
        $repoUrl = $null
    }
    if (-not $repoUrl) { $repoUrl = 'unknown' }

    $content = @"
# Orchestrator Agent Prompt — Local Invocation

## Context
- **Source**: Local manual dispatch
- **Timestamp**: $timestamp
- **Repository**: $repoUrl

## Prompt

$PromptString
"@

    Set-Content -Path $OutputFile -Value $content -NoNewline
    $bytes = (Get-Item $OutputFile).Length
    Write-Host "[assemble-local-prompt] Wrote freeform prompt to $OutputFile ($bytes bytes)"
    exit 0
}

# -----------------------------------------------------------------------
# Fixture mode — mimic CI prompt assembly
# -----------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $FixtureFile)) {
    Write-Error "Fixture file not found: $FixtureFile"
}

if (-not (Test-Path -LiteralPath $PromptTemplate)) {
    Write-Error "Prompt template not found: $PromptTemplate"
}

# Parse fixture JSON
$fixtureJson = Get-Content -LiteralPath $FixtureFile -Raw | ConvertFrom-Json

$eventAction = if ($null -ne $fixtureJson.action)          { $fixtureJson.action }          else { 'unknown' }
$actor       = if ($null -ne $fixtureJson.sender -and
                   $null -ne $fixtureJson.sender.login)     { $fixtureJson.sender.login }     else { 'local-user' }
$repo        = if ($null -ne $fixtureJson.repository -and
                   $null -ne $fixtureJson.repository.full_name) { $fixtureJson.repository.full_name } else { 'local/repo' }

# Derive event name from fixture filename (e.g. issues-opened.json → issues)
$fixtureBasename = [System.IO.Path]::GetFileNameWithoutExtension($FixtureFile)
$dashIndex = $fixtureBasename.IndexOf('-')
$eventName = if ($dashIndex -gt 0) { $fixtureBasename.Substring(0, $dashIndex) } else { $fixtureBasename }

# Build context header
$epochSeconds = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
$contextHeader = @"
Event Name: $eventName
Action: $eventAction
Actor: $actor
Repository: $repo
Ref: refs/heads/main
SHA: local-$epochSeconds
"@

# Read prompt template lines (for marker search)
$templateLines = Get-Content -LiteralPath $PromptTemplate

# Read raw fixture text (preserves original formatting)
$fixtureRaw = Get-Content -LiteralPath $FixtureFile -Raw

# Find the {{__EVENT_DATA__}} marker — same approach as assemble-orchestrator-prompt.ps1
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

$eventBlock = @"
## Event Context

``````
$contextHeader
``````
"@

# Assemble: lines before marker, then event context + fixture JSON
$assembled = @(
    $beforeMarker
    $eventBlock
    '```json'
    $fixtureRaw.TrimEnd()
    '```'
) -join "`n"

Set-Content -Path $OutputFile -Value $assembled -NoNewline
$bytes = (Get-Item $OutputFile).Length
Write-Host "[assemble-local-prompt] Wrote fixture prompt to $OutputFile ($bytes bytes)"
Write-Host "[assemble-local-prompt]   event: $eventName, action: $eventAction, actor: $actor"
