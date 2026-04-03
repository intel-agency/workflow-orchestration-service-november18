#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install, update, validate, and report on AI inference CLI tools.

.DESCRIPTION
    Manages these tools: Auggie (Augment Code), Codex CLI (OpenAI), Gemini CLI
    (Google), GitHub Copilot CLI, Kimi Code CLI (Moonshot AI), OpenCode AI, and
    Factory Droid CLI.

    Default (no flags): surveys installed state, installs missing tools,
    updates existing ones, then prints a summary report.

    Uses bun for Node.js packages, the official kimi installer script for kimi,
    and gh extension for GitHub Copilot CLI.

.PARAMETER Install
    Install any tools that are not currently installed.

.PARAMETER Update
    Update all currently installed tools to their latest versions.

.PARAMETER Validate
    Verify each tool responds to its version command.

.PARAMETER Report
    Print a summary table of installation status and versions.

.EXAMPLE
    ./scripts/install-inference-tools.ps1                  # survey + install + update + report
    ./scripts/install-inference-tools.ps1 -Report          # status report only
    ./scripts/install-inference-tools.ps1 -Install         # install missing tools only
    ./scripts/install-inference-tools.ps1 -Update          # update installed tools only
    ./scripts/install-inference-tools.ps1 -Validate        # validate installs
    ./scripts/install-inference-tools.ps1 -Install -Update # install missing + update existing
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Update,
    [switch]$Validate,
    [switch]$Report
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
$OnWindows = $IsWindows -or ($env:OS -eq 'Windows_NT')

# ---------------------------------------------------------------------------
# Tool catalog
# Manager values: 'bun' | 'gh-extension' | 'kimi-installer'
# VersionArgs: space-delimited string, split into array when invoked
# ---------------------------------------------------------------------------
$ToolCatalog = @(
    @{
        Name        = 'auggie'
        Label       = 'Augment Code (Auggie)'
        Manager     = 'bun'
        Package     = '@augmentcode/auggie'
        Command     = 'auggie'
        VersionArgs = '--version'
        Docs        = 'https://docs.augmentcode.com/cli'
    }
    @{
        Name        = 'codex'
        Label       = 'OpenAI Codex CLI'
        Manager     = 'bun'
        Package     = '@openai/codex'
        Command     = 'codex'
        VersionArgs = '--version'
        Docs        = 'https://github.com/openai/codex'
    }
    @{
        Name        = 'gemini'
        Label       = 'Gemini CLI'
        Manager     = 'bun'
        Package     = '@google/gemini-cli'
        Command     = 'gemini'
        VersionArgs = '--version'
        Docs        = 'https://github.com/google-gemini/gemini-cli'
    }
    @{
        Name        = 'gh-copilot'
        Label       = 'GitHub Copilot CLI'
        Manager     = 'gh-extension'
        Package     = 'github/gh-copilot'
        Command     = 'gh'
        VersionArgs = 'copilot --version'
        Docs        = 'https://cli.github.com/manual/gh_copilot'
    }
    @{
        Name        = 'kimi'
        Label       = 'Kimi Code CLI'
        Manager     = 'kimi-installer'
        Package     = 'kimi-cli'
        Command     = 'kimi'
        VersionArgs = '--version'
        Docs        = 'https://moonshotai.github.io/kimi-cli/en/'
    }
    @{
        Name        = 'opencode'
        Label       = 'OpenCode AI'
        Manager     = 'bun'
        Package     = 'opencode-ai'
        Command     = 'opencode'
        VersionArgs = '--version'
        Docs        = 'https://opencode.ai'
    }
    @{
        Name        = 'droid'
        Label       = 'Factory Droid CLI'
        Manager     = 'bun'
        Package     = 'droid'
        Command     = 'droid'
        VersionArgs = '--version'
        Docs        = 'https://docs.factory.ai/cli'
    }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-CommandPath ([string]$Name) {
    Get-Command $Name -ErrorAction SilentlyContinue
}

function Get-ToolVersion ($Tool) {
    try {
        $argList = $Tool.VersionArgs -split ' '
        $out = & $Tool.Command @argList 2>&1 | Select-Object -First 1
        return ("$out").Trim()
    } catch {
        return $null
    }
}

function Test-ToolInstalled ($Tool) {
    try {
        if ($Tool.Manager -eq 'gh-extension') {
            if (-not (Get-CommandPath 'gh')) { return $false }
            $list = gh extension list 2>&1
            return [bool]($list | Select-String -Quiet 'copilot')
        }
        return [bool](Get-CommandPath $Tool.Command)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Per-manager install / update implementations
# ---------------------------------------------------------------------------
function Invoke-ToolInstall ($Tool) {
    switch ($Tool.Manager) {
        'bun' {
            bun install -g $Tool.Package
        }
        'gh-extension' {
            if (-not (Get-CommandPath 'gh')) {
                Write-Warning "  gh CLI not found — install from https://cli.github.com"
                return
            }
            gh extension install $Tool.Package
        }
        'kimi-installer' {
            Write-Warning "  Kimi installer downloads and executes a remote script. Review the script at https://code.kimi.com/install.ps1 (Windows) or https://code.kimi.com/install.sh (Linux/macOS) before proceeding."
            if ($OnWindows) {
                $installerScript = Invoke-RestMethod https://code.kimi.com/install.ps1
                Invoke-Expression $installerScript
            } else {
                bash -c 'curl -LsSf https://code.kimi.com/install.sh | bash'
            }
        }
    }
}

function Invoke-ToolUpdate ($Tool) {
    switch ($Tool.Manager) {
        'bun' {
            bun update -g $Tool.Package
        }
        'gh-extension' {
            if (-not (Get-CommandPath 'gh')) { return }
            gh extension upgrade copilot
        }
        'kimi-installer' {
            if (Get-CommandPath 'uv') {
                uv tool upgrade kimi-cli --no-cache
            } else {
                # uv not found — re-run the installer; it will update via uv
                Invoke-ToolInstall $Tool
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Survey: snapshot the current state of every tool
# ---------------------------------------------------------------------------
function Get-ToolSurvey {
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($tool in $ToolCatalog) {
        $installed = Test-ToolInstalled $tool
        $version   = if ($installed) { Get-ToolVersion $tool } else { $null }
        $results.Add([pscustomobject]@{
            Tool      = $tool.Name
            Label     = $tool.Label
            Installed = $installed
            Version   = $version
            ToolDef   = $tool
        })
    }
    return $results
}

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------
function Invoke-InstallMissing ($Survey) {
    $missing = @($Survey | Where-Object { -not $_.Installed })
    if ($missing.Count -eq 0) {
        Write-Host "`n  All tools already installed." -ForegroundColor Green
        return
    }
    Write-Host "`n--- Installing missing tools ---" -ForegroundColor Cyan
    foreach ($item in $missing) {
        Write-Host "`n$($item.Label)" -ForegroundColor Cyan
        try {
            Invoke-ToolInstall $item.ToolDef
            if (Test-ToolInstalled $item.ToolDef) {
                $item.Installed = $true
                $item.Version   = Get-ToolVersion $item.ToolDef
                Write-Host "  [ok] Installed — $($item.Version)" -ForegroundColor Green
            } else {
                Write-Warning "  Not found on PATH after install — you may need to restart your shell."
            }
        } catch {
            Write-Warning "  Install failed: $_"
        }
    }
}

function Invoke-UpdateInstalled ($Survey) {
    $installed = @($Survey | Where-Object { $_.Installed })
    if ($installed.Count -eq 0) {
        Write-Host "`n  No installed tools to update." -ForegroundColor Yellow
        return
    }
    Write-Host "`n--- Updating installed tools ---" -ForegroundColor Cyan
    foreach ($item in $installed) {
        Write-Host "`n$($item.Label)" -ForegroundColor Cyan
        $before = $item.Version
        try {
            Invoke-ToolUpdate $item.ToolDef
            $after        = Get-ToolVersion $item.ToolDef
            $item.Version = $after
            if ($after -and $before -ne $after) {
                Write-Host "  [ok] Updated: $before → $after" -ForegroundColor Green
            } else {
                Write-Host "  [ok] Already at latest ($($after ?? $before ?? 'unknown'))" -ForegroundColor Green
            }
        } catch {
            Write-Warning "  Update failed: $_"
        }
    }
}

function Invoke-ValidateAll ($Survey) {
    Write-Host "`n--- Validating tools ---" -ForegroundColor Cyan
    $ok = 0; $fail = 0
    foreach ($item in $Survey) {
        if ($item.Installed -and $item.Version) {
            Write-Host "  [ok] $($item.Label) — $($item.Version)" -ForegroundColor Green
            $ok++
        } elseif ($item.Installed) {
            Write-Host "  [??] $($item.Label) — installed but version check failed" -ForegroundColor Yellow
            $ok++
        } else {
            Write-Host "  [!!] $($item.Label) — NOT INSTALLED" -ForegroundColor Red
            $fail++
        }
    }
    $color = if ($fail -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "`n  $ok / $($Survey.Count) tools validated" -ForegroundColor $color
}

function Invoke-PrintReport ($Survey) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host '  AI Inference CLI Tools — Status Report' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    $Survey | ForEach-Object {
        [pscustomobject]@{
            Tool    = $_.Tool
            Status  = if ($_.Installed) { 'installed' } else { 'missing' }
            Version = if ($_.Version) { $_.Version } else { '—' }
        }
    } | Format-Table -AutoSize
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host "`n=== AI Inference CLI Tools ===" -ForegroundColor Cyan

if (-not (Get-CommandPath 'bun')) {
    Write-Warning "bun not found — install from https://bun.sh (required for most tools)"
}

$defaultMode = -not ($Install -or $Update -or $Validate -or $Report)

Write-Host "`n--- Surveying installed tools ---" -ForegroundColor Cyan
$survey = Get-ToolSurvey

foreach ($item in $survey) {
    if ($item.Installed) {
        Write-Host "  [ok] $($item.Label) — $($item.Version)" -ForegroundColor Green
    } else {
        Write-Host "  [--] $($item.Label) — not installed" -ForegroundColor DarkGray
    }
}

if ($Install -or $defaultMode) { Invoke-InstallMissing $survey }
if ($Update  -or $defaultMode) { Invoke-UpdateInstalled $survey }
if ($Validate)                  { Invoke-ValidateAll $survey }
if ($Report  -or $defaultMode) { Invoke-PrintReport $survey }
