# Inference CLI Client Installer Script

## Task

Create a pwsh `.ps1` script to install all AI inference CLI clients.

### Requirements

- Run a survey to see what's installed
- At a minimum: augment, codex cli, gemini cli, gh copilot cli, kimi code cli, opencode.ai cli, factory droid cli
- Idempotent: update if installed, install if not
- Install using bun (not npm)
- Validate installations, report validated installed/updated version
- Run in ubuntu/debian/mint linux/WSL bash AND Windows pwsh — one script
- Arguments: `-Update`, `-Install`, `-Validate`, `-Report` (when invoking from bash via `pwsh`, pass these PowerShell switches exactly as shown)

---

## Implementation Status

**Script**: `scripts/install-inference-tools.ps1` ✅ Implemented

### Planned Items

| Item | Status | Notes |
|------|--------|-------|
| Survey installed state | ✅ Implemented | `Get-ToolSurvey` — checks each tool on PATH / via `gh extension list` |
| Install missing tools | ✅ Implemented | `-Install` flag; default mode includes install |
| Update existing tools | ✅ Implemented | `-Update` flag; default mode includes update |
| Validate installations | ✅ Implemented | `-Validate` flag; runs version command per tool |
| Status report | ✅ Implemented | `-Report` flag (table of tool / status / version); included in default mode |
| Idempotent | ✅ Implemented | Install checks if already present; update uses bun/uv/gh upgrade |
| Use bun (not npm) | ✅ Implemented | All Node.js packages installed via `bun install -g` / `bun update -g` |
| Cross-platform (Windows + Linux) | ✅ Implemented | Single script; platform-gated via `$IsWindows`; kimi installer uses `.ps1` on Windows, `.sh` on Linux |
| All 7 tools covered | ✅ Implemented | auggie, codex, gemini, gh-copilot, kimi, opencode, droid |

### Tool Catalog Summary

| Tool | Manager | Package |
|------|---------|---------|
| Augment Code (Auggie) | bun | `@augmentcode/auggie` |
| OpenAI Codex CLI | bun | `@openai/codex` |
| Gemini CLI | bun | `@google/gemini-cli` |
| GitHub Copilot CLI | gh extension | `github/gh-copilot` |
| Kimi Code CLI | kimi-installer | official install script |
| OpenCode AI | bun | `opencode-ai` |
| Factory Droid CLI | bun | `droid` |

### Validation

- PSScriptAnalyzer: ✅ 0 warnings
- All repo tests: ✅ 20/20 Pester passing
