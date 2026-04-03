# Development Instructions

This file provides guidance to chat clients and agents when working with code in this repository.

## Shell Environment

Default shell: **Linux bash** (WSL Ubuntu 24.04). PowerShell (pwsh) is also frequently used.

- Default to bash for terminal commands
- Use pwsh when running `.ps1` scripts or when PowerShell-specific features are needed
- Detect the current shell before running commands: `echo $0` (bash) or `$PSVersionTable` (pwsh)

## Common Development Commands

### GitHub Automation Scripts

```bash
# bash
pwsh ./scripts/import-labels.ps1
pwsh ./scripts/create-milestones.ps1
```

```powershell
# pwsh
./scripts/import-labels.ps1
./scripts/create-milestones.ps1
```

### PR Review Thread Management

**Use `scripts/query.ps1` to manage PR review comments.** This is the canonical tool for fetching, replying to, and resolving unresolved review threads on pull requests. Do NOT write ad-hoc Python or shell scripts for this — the PowerShell script handles GraphQL pagination, error handling, interactive mode, and filtering.

```powershell
# List unresolved threads (dry run, no resolution)
pwsh ./scripts/query.ps1 -Owner <owner> -Repo <repo> -PullRequestNumber <num> -DryRun

# Resolve all unresolved threads with a reply message
pwsh ./scripts/query.ps1 -Owner <owner> -Repo <repo> -PullRequestNumber <num> -AutoResolve -ReplyEach "Addressed in commit abc123."

# Filter by file path and resolve interactively
pwsh ./scripts/query.ps1 -Owner <owner> -Repo <repo> -PullRequestNumber <num> -Path "pyproject.toml" -Interactive

# Just list threads without resolving
pwsh ./scripts/query.ps1 -Owner <owner> -Repo <repo> -PullRequestNumber <num> -NoResolve
```

Key flags:

- `-AutoResolve` — resolve all matched threads without prompting
- `-DryRun` — show what would be resolved without doing it
- `-Interactive` — prompt for each thread individually
- `-NoResolve` — list/summarize only, do not resolve
- `-ReplyEach "message"` — post a reply to each thread before resolving
- `-Path "pattern"` — filter threads by file path (wildcard match)
- `-BodyContains "text"` — filter threads by comment body content
- `-ThreadId "id"` — target a specific thread by GraphQL ID

## Architecture Overview

### AI-Powered Template System

This repository is a **template for AI-assisted application development**. The architecture is built around:

1. **Remote Canonical Instructions**: Core AI instruction modules live in `nam20485/agent-instructions` repository
2. **Local Instruction Modules**: Local files in `local_ai_instruction_modules/` that reference and extend remote instructions
3. **Automation Layer**: Repository operations performed through MCP tools, `gh` CLI, terminal commands, scripts, and GitHub API
4. **Workflow Orchestration**: Dynamic workflows resolved from remote canonical sources

### GitHub Actions: SHA-Pinned Actions (MANDATORY)

Every `uses:` line in workflow files **MUST** reference the full 40-char commit SHA of the latest release. Tag refs (`@v4`, `@main`) are **prohibited** — mutable tags are a supply-chain attack vector.

Format: `uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2`

- Trailing `# vX.Y.Z` comment is mandatory for readability
- Applies to all actions: third-party, `actions/*`, `github/*`, reusable workflows
- Not enforced by `actionlint` — manual discipline via code review and agent instructions

### Tool Preference for GitHub Operations

1. **MCP GitHub Tools** (`mcp_github_*` functions) - Use first
2. **VS Code GitHub Integration** (`run_vscode_command`) - Fallback
3. **Terminal GitHub CLI** (`gh` commands) - Last resort only
4. **Manual GitHub Web Interface** - **PROHIBITED**

### Sequential Thinking, Memory, and Gemini Tools (MANDATORY — NON-NEGOTIABLE)

**ALL agents MUST use these MCP tools. This is a mandatory protocol defined in AGENTS.md `mandatory_tool_protocols`. Skipping these is a protocol violation.**

1. **Sequential Thinking Tool** (`sequential_thinking`) - **MUST USE on every non-trivial task** for:
   - **At task START**: Analyze the request, plan approach, identify risks BEFORE acting
   - **At decision points**: Evaluate trade-offs and alternatives
   - **Before delegation**: Plan delegation tree and success criteria
   - Breaking down complex problems into steps
   - Planning multi-stage implementations
   - Analyzing dependencies and relationships
   - Debugging and troubleshooting workflows

2. **Knowledge Graph Memory Tool** (`read_graph`, `search_nodes`, `open_nodes`, `create_entities`, `add_observations`, `create_relations`) - **MUST USE on every non-trivial task** for:
   - **At task START**: Call `read_graph`/`search_nodes` to load prior context BEFORE planning
   - **After significant work**: Persist findings, decisions, patterns via `create_entities`/`add_observations`
   - **At task END**: Store outcomes and lessons learned
   - Storing important context between tasks
   - Tracking project-specific patterns and conventions
   - Remembering user preferences and decisions
   - Maintaining state across workflow stages
   - **WRITE RESTRICTION — ORCHESTRATOR ONLY**: Only the orchestrator may call write tools (`create_entities`, `add_observations`, `create_relations`, `delete_entities`, `delete_observations`, `delete_relations`). Subagents MUST NOT call write tools — concurrent writes corrupt the shared JSONL file. Subagents may call `read_graph`, `search_nodes`, and `open_nodes` (read-only).

3. **Gemini Tool** (`mcp_gemini_*`) - **USE FOR CONTEXT CONSERVATION**:
   - Reading and analyzing large codebases (1M token context)
   - Processing extensive documentation or logs
   - Analyzing multiple files simultaneously
   - Conserving Claude's context window for other tasks
   - Delegating large-scale code comprehension tasks

### Key Architectural Patterns

**Remote-Local Instruction Split**:

- Remote canonical repository (`nam20485/agent-instructions`) contains authoritative workflow definitions
- Local `local_ai_instruction_modules/` contains workspace-specific references and configuration
- Never use local mirrors for workflow derivation
- When beginning a workflow, read all relevant instructions (local and remote) before planning or acting

### Core System Components

**Workflow Assignment System**:

- Assignments resolved from `nam20485/agent-instructions/ai_instruction_modules/ai-workflow-assignments/`
- Dynamic workflows in `nam20485/agent-instructions/ai_instruction_modules/ai-workflow-assignments/dynamic-workflows/`
- Always use RAW URLs when fetching remote workflow files
- Read all `ai_instruction_modules` before planning or acting

**Tool Configuration**:

- Use dynamic tool discovery to identify available capabilities
- Tool availability varies by environment — discover at runtime rather than relying on static lists

## Development Environment

- **.NET SDK**: 10.0.100 (pinned in `global.json`)
- **Shell**: bash (WSL Ubuntu 24.04) primary, pwsh also used
- **PowerShell**: 7+ for cross-platform script execution

## Critical Development Rules

1. **Shell Detection**: Check current shell (bash vs pwsh) before running commands
2. **Remote Authority**: Only use remote canonical repository files for workflow definitions
3. **Tool Priority**: Use MCP GitHub tools first, `gh` CLI as fallback, GitHub API when needed
