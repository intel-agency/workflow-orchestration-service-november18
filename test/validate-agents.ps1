#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates each agent in .opencode/agents/ by sending a minimal test prompt via
    `opencode run --agent <name>` and reporting pass/fail per agent.

    Mirrors the real orchestration path more closely than validate-models.ps1:
    - Uses --agent flag (same as devcontainer server invocation)
    - Tests the actual model each agent resolves to (explicit frontmatter or default)
    - Reports which model/provider each agent used (from response or config)

.PARAMETER AgentsDir
    Path to the agents directory. Defaults to .opencode/agents relative to repo root.

.PARAMETER ConfigFile
    Path to opencode.json. Defaults to opencode.json in the repo root.

.PARAMETER Prompt
    Test prompt sent to each agent. Should produce a short, verifiable response.
    Defaults to "Reply with only the word PASS and nothing else."

.PARAMETER TimeoutSeconds
    Per-agent timeout in seconds. Defaults to 90.

.PARAMETER Agent
    If specified, only test this single agent by name (e.g. "planner").

.PARAMETER FailedOutputFile
    Path to write failed_agents.json. Defaults to test/failed_agents.json.

.PARAMETER FailedFile
    Path to a failed_agents.json from a prior run — only re-tests those agents.

.PARAMETER DelegatorAgent
    Primary agent used to delegate tests to subagents. Defaults to 'developer'.
    Must be a non-subagent (mode != subagent) to avoid recursive fallback.

.EXAMPLE
    pwsh test/validate-agents.ps1
    pwsh test/validate-agents.ps1 -Agent researcher
    pwsh test/validate-agents.ps1 -FailedFile test/failed_agents.json
    pwsh test/validate-agents.ps1 -DelegatorAgent orchestrator
#>
param(
    [string] $AgentsDir        = (Join-Path $PSScriptRoot ".." ".opencode" "agents"),
    [string] $ConfigFile       = (Join-Path $PSScriptRoot ".." "opencode.json"),
    [string] $Prompt           = "Reply with only the word PASS and nothing else.",
    [int]    $TimeoutSeconds   = 90,
    [string] $Agent            = "",
    [string] $FailedFile       = "",
    [string] $FailedOutputFile = (Join-Path $PSScriptRoot "failed_agents.json"),
    [string] $DelegatorAgent   = "developer"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Pass   { param([string]$msg) Write-Host "  [PASS] $msg" -ForegroundColor Green  }
function Write-Fail   { param([string]$msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red    }
function Write-Skip   { param([string]$msg) Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }
function Write-Header { param([string]$msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan  }
function Write-Info   { param([string]$msg) Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

# ── locate repo root and resolve paths ───────────────────────────────────────

$repoRoot   = Resolve-Path (Join-Path $PSScriptRoot "..") -ErrorAction Stop
$agentsPath = Resolve-Path $AgentsDir  -ErrorAction Stop
$configPath = Resolve-Path $ConfigFile -ErrorAction Stop

$config = Get-Content -Raw $configPath | ConvertFrom-Json
$defaultModel = $config.model ?? "zai-coding-plan/glm-5"

# ── collect agents ────────────────────────────────────────────────────────────

$agentFiles = Get-ChildItem -Path $agentsPath -Filter "*.md" | Sort-Object Name

if ($Agent) {
    $agentFiles = $agentFiles | Where-Object { $_.BaseName -eq $Agent }
    if (-not $agentFiles) {
        Write-Error "Agent '$Agent' not found in $agentsPath"
        exit 1
    }
}

# Apply -FailedFile filter
if ($FailedFile) {
    $failedPath = Resolve-Path $FailedFile -ErrorAction Stop
    $failedJson = Get-Content -Raw $failedPath | ConvertFrom-Json
    $failedNames = @($failedJson.failed_agents | ForEach-Object { $_.agent })
    if ($failedNames.Count -eq 0) {
        Write-Warning "-FailedFile '$FailedFile' contains no failed agents."
        exit 0
    }
    $agentFiles = $agentFiles | Where-Object { $failedNames -contains $_.BaseName }
    Write-Host "Re-testing $($agentFiles.Count) agent(s) from $failedPath" -ForegroundColor Yellow
}

if (-not $agentFiles) {
    Write-Warning "No agents found to test."
    exit 0
}

# ── helper: extract frontmatter value ────────────────────────────────────────

function Get-FrontmatterValue {
    param([string]$FilePath, [string]$Key)
    $lines = Get-Content $FilePath
    $inFrontmatter = $false
    foreach ($line in $lines) {
        if ($line -match '^---\s*$') {
            if (-not $inFrontmatter) { $inFrontmatter = $true; continue }
            else { break }
        }
        if ($inFrontmatter -and $line -match "^$Key\s*:\s*(.+)$") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# ── display plan ─────────────────────────────────────────────────────────────

Write-Host "`nAgent Validation Plan" -ForegroundColor Cyan
Write-Host "Repo root : $repoRoot"
Write-Host "Agents dir: $agentsPath"
Write-Host "Default model: $defaultModel"
Write-Host "Timeout   : ${TimeoutSeconds}s (2x for subagents)"
Write-Host "Prompt    : `"$Prompt`""
Write-Host "Delegator : $DelegatorAgent (used for mode:subagent agents)`n"

$plan = @()
foreach ($file in $agentFiles) {
    $agentName  = $file.BaseName
    $agentModel = Get-FrontmatterValue $file.FullName "model"
    $agentMode  = Get-FrontmatterValue $file.FullName "mode"
    $isSubagent = ($agentMode -eq "subagent")
    $resolvedModel = if ($agentModel) { $agentModel } else { "$defaultModel (default)" }
    $modeTag = if ($isSubagent) { " [subagent->via $DelegatorAgent]" } else { "" }
    $plan += [PSCustomObject]@{ Agent = $agentName; Model = "$resolvedModel$modeTag" }
}

$plan | Format-Table -AutoSize
Write-Host ""

# ── run tests ─────────────────────────────────────────────────────────────────

$results = [System.Collections.Generic.List[hashtable]]::new()
$passCount = 0
$failCount = 0

foreach ($file in $agentFiles) {
    $agentName  = $file.BaseName
    $agentModel = Get-FrontmatterValue $file.FullName "model"
    $agentMode  = Get-FrontmatterValue $file.FullName "mode"
    $isSubagent = ($agentMode -eq "subagent")
    $resolvedModel = if ($agentModel) { $agentModel } else { $defaultModel }

    $effectiveTimeout = if ($isSubagent) { $TimeoutSeconds * 2 } else { $TimeoutSeconds }
    $routeNote = if ($isSubagent) { " [subagent->via $DelegatorAgent, timeout ${effectiveTimeout}s]" } else { "" }
    Write-Header "$agentName  (model: $resolvedModel)$routeNote"

    $passed    = $false
    $output    = ""
    $errMsg    = ""
    $exitCode  = -1

    try {
        if ($isSubagent) {
            # Subagents cannot be invoked directly — route via a primary agent delegation.
            # The delegator uses the task tool to spin up the subagent.
            $delegationMsg = "You must use the task tool to invoke the '$agentName' agent with exactly this message: '$Prompt'. Do not answer yourself. Return only the agent's response verbatim."
            Write-Host "  opencode run --agent $DelegatorAgent --message [delegate to $agentName] ..."

            $job = Start-Job -ScriptBlock {
                Set-Location $using:repoRoot
                $out = opencode run --agent $using:DelegatorAgent --message $using:delegationMsg 2>&1
                [pscustomobject]@{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
            }
        } else {
            Write-Host "  opencode run --agent $agentName --message `"$Prompt`" ..."

            $job = Start-Job -ScriptBlock {
                Set-Location $using:repoRoot
                $out = opencode run --agent $using:agentName --message $using:Prompt 2>&1
                [pscustomobject]@{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
            }
        }

        $remaining = $effectiveTimeout
        $completed = $null
        while ($remaining -ge 0) {
            Write-Host "`r  [$remaining s remaining]  " -NoNewline
            $completed = Wait-Job $job -Timeout 1
            if ($completed) { break }
            $remaining--
        }
        Write-Host ""

        if (-not $completed) {
            Stop-Job  $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            throw "Timed out after ${effectiveTimeout}s"
        }

        $result   = Receive-Job $job
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        $output   = $result.Output
        $exitCode = $result.ExitCode

        # Show last 6 lines of output for review
        $preview = ($output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 6) -join "`n"
        Write-Host "  Output (last 6 non-empty lines):"
        $preview -split "`n" | ForEach-Object { Write-Host "    $_" }

        if ($exitCode -ne 0) {
            throw "opencode exited with code $exitCode"
        }
        if ([string]::IsNullOrWhiteSpace($output)) {
            throw "Empty response"
        }
        # For subagents invoked via delegation, detect if opencode fell back to default instead of delegating
        if ($isSubagent -and $output -match 'is a subagent, not a primary agent') {
            throw "Delegation failed: '$DelegatorAgent' did not use task tool — subagent fell back to default"
        }
        # Detect common auth/quota/error patterns
        if ($output -match 'error|Error|exception|401|403|429|quota|Payment Required|Unauthorized|RESOURCE_EXHAUSTED|AI_APICallError') {
            throw "Response contains error indicator: $(($output -split '\n' | Select-String 'error|Error|401|403|429|quota' | Select-Object -First 1).Line)"
        }

        $passed = $true
        $passCount++
        Write-Pass "$agentName responded successfully (exit 0)"

    } catch {
        $errMsg = $_.Exception.Message
        $failCount++
        Write-Fail "$agentName FAILED — $errMsg"
        if ($output) {
            $errPreview = ($output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join " | "
            Write-Info "Last output: $errPreview"
        }
    }

    $results.Add(@{
        agent          = $agentName
        model          = $resolvedModel
        mode           = if ($isSubagent) { "subagent" } else { "primary" }
        model_explicit = (-not [string]::IsNullOrEmpty($agentModel))
        passed         = $passed
        exit_code      = $exitCode
        error          = $errMsg
        output_preview = ($output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join " | "
    })
}

# ── summary ───────────────────────────────────────────────────────────────────

Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
Write-Host "RESULTS: $passCount passed, $failCount failed out of $($results.Count) agents" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host ("=" * 60) -ForegroundColor Cyan

$results | ForEach-Object {
    $icon     = if ($_.passed) { "✓" } else { "✗" }
    $color    = if ($_.passed) { "Green" } else { "Red" }
    $defNote  = if ($_.model_explicit) { "" } else { " [default]" }
    $modeNote = if ($_.mode -eq "subagent") { " [subagent]" } else { "" }
    Write-Host "  $icon  $($_.agent.PadRight(30)) $($_.model)$defNote$modeNote" -ForegroundColor $color
}

# ── write failed_agents.json ──────────────────────────────────────────────────

$failedAgents = $results | Where-Object { -not $_.passed }
$outputObj = [ordered]@{
    timestamp     = (Get-Date -Format "o")
    total         = $results.Count
    passed        = $passCount
    failed        = $failCount
    failed_agents = @($failedAgents | ForEach-Object {
        [ordered]@{
            agent    = $_.agent
            model    = $_.model
            error    = $_.error
            exit_code = $_.exit_code
        }
    })
}
$outputObj | ConvertTo-Json -Depth 5 | Set-Content -Path $FailedOutputFile -Encoding utf8
Write-Host "`nFailed agents written to: $FailedOutputFile" -ForegroundColor DarkGray

exit $(if ($failCount -gt 0) { 1 } else { 0 })
