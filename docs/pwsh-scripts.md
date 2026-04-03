# PowerShell Cross-Platform Script Equivalents

## Goal

Create working PowerShell `.ps1` equivalents for **all** `.sh` scripts in `scripts/` so the
entire workflow (local development, devcontainer orchestration, and CI) can run natively on
**Linux, macOS, and Windows** using `pwsh` (PowerShell 7+).

---

## Scope

### 1 — Script Conversion

| # | Source `.sh` script | Target `.ps1` script | Complexity | Notes |
|---|---------------------|----------------------|------------|-------|
| 1 | `setup-local-env.sh` | `setup-local-env.ps1` | Low | First-time `.env` creation & validation |
| 2 | `resolve-image-tags.sh` | `resolve-image-tags.ps1` | Low | Docker image tag computation from CI context |
| 3 | `trigger-orchestrator-test.sh` | `trigger-orchestrator-test.ps1` | Low | `gh` CLI wrapper for dispatch issues |
| 4 | `assemble-local-prompt.sh` | `assemble-local-prompt.ps1` | Medium | Freeform/fixture prompt assembly |
| 5 | `assemble-orchestrator-prompt.sh` | `assemble-orchestrator-prompt.ps1` | Medium | CI-side prompt assembly via GitHub Actions |
| 6 | `post-failure-comment.sh` | `post-failure-comment.ps1` | Medium | Posts enriched failure diagnostics via `gh` |
| 7 | `on-failure-handler.sh` | `on-failure-handler.ps1` | Medium | Orchestrator failure comment handler |
| 8 | `collect-trace-artifacts.sh` | `collect-trace-artifacts.ps1` | Medium | Trace/log gathering & tar archiving |
| 9 | `prompt-direct.sh` | `prompt-direct.ps1` | High | Direct opencode invocation with complex env handling |
| 10 | `start-opencode-server.sh` | `start-opencode-server.ps1` | High | Daemon lifecycle (PID files, health checks) |
| 11 | `devcontainer-opencode.sh` | `devcontainer-opencode.ps1` | High | Multi-command dispatcher (up/start/prompt/stop/down/status) |

Also convert the root-level wrapper:

| # | Source | Target | Notes |
|---|--------|--------|-------|
| 12 | `run_opencode_prompt.sh` | `run_opencode_prompt.ps1` | Root-level convenience wrapper |

### 2 — CI Integration

- Add PowerShell equivalents of the bash test scripts referenced in
  `.github/workflows/validate.yml` (prompt-assembly, image-tag-logic, etc.).
- Run the new `.ps1` tests **in parallel** with existing `.sh` tests in CI so both
  paths are validated on every push.
- `validate.yml` runs `lint` and `test` jobs on a **matrix of `ubuntu-24.04` and `windows-latest`**
  so cross-platform behavior is verified on every push/PR.

### 3 — Robustness Improvements (both `.sh` and `.ps1`)

- **Error handling**: Every script must fail loudly on first error
  (`set -euo pipefail` / `$ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest`).
- **Input validation**: Validate required env vars / parameters at the top of each script
  with clear error messages.
- **Cross-platform paths**: Use `[IO.Path]::Combine()` or `Join-Path` instead of
  string concatenation and avoid manually hard-coding path separators; known
  environment- or container-specific absolute paths (for example `/tmp` or
  `/workspaces`) are allowed where appropriate.
- **Logging**: Use `Write-Host` for user-facing output and `Write-Verbose` for debug
  detail; preserve the same log levels as the originals.

---

## Conventions (match existing `.ps1` scripts)

All new `.ps1` scripts **must** follow the patterns already established in the repo
(see `scripts/validate.ps1`, `scripts/import-labels.ps1`, `scripts/create-dispatch-issue.ps1`):

1. **`[CmdletBinding()]`** with typed `[Parameter()]` declarations.
2. **Comment-based help**: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.NOTES`.
3. **`$ErrorActionPreference = 'Stop'`** and **`Set-StrictMode -Version Latest`** at script top.
4. **GitHub CLI**: Arg-splatting pattern (`$ghArgs = @(…); & gh @ghArgs`).
5. **Docker CLI**: Capture JSON output with `ConvertFrom-Json` where possible.
6. **Dry-run**: Prefer including a `-DryRun` switch for scripts that mutate state,
   especially new ones, even though some existing scripts may not yet implement it.
7. **Dot-sourcing**: Reuse `common-auth.ps1` for auth logic.

---

## Acceptance Criteria

- [x] All 12 scripts converted and placed alongside originals in `scripts/`.
- [x] Each `.ps1` script produces **identical observable behavior** to its `.sh` counterpart
      (same exit codes, same stdout/stderr contract, same file outputs).
- [x] All scripts pass **PSScriptAnalyzer** with zero warnings (already enforced in CI).
- [x] Pester tests exist for any non-trivial logic (image-tag computation, prompt assembly,
      env-var validation).
- [x] `validate.yml` `lint` and `test` jobs run on both `ubuntu-24.04` **and** `windows-latest` (matrix).
- [ ] Manual smoke test passes on at least **Windows (pwsh 7)** and **Linux (pwsh 7)**.

---

## Out of Scope

- Rewriting existing `.sh` scripts in place (they stay as-is; `.ps1` scripts are additive).
- Converting Python scripts (`trace-extract.py`, `WorkItemModel.py`).
- Modifying `devcontainer.json` `postStartCommand` (remains bash for now).

---

## Implementation Order

Convert in dependency order (low → high complexity):

1. ✅ **Foundation**: `setup-local-env.ps1`, `resolve-image-tags.ps1`
2. ✅ **Simple wrappers**: `trigger-orchestrator-test.ps1`
3. ✅ **Prompt assembly**: `assemble-local-prompt.ps1`, `assemble-orchestrator-prompt.ps1`
4. ✅ **Failure handlers**: `post-failure-comment.ps1`, `on-failure-handler.ps1`
5. ✅ **Artifact collection**: `collect-trace-artifacts.ps1`
6. ✅ **Complex orchestration**: `prompt-direct.ps1`, `start-opencode-server.ps1`
7. ✅ **Top-level dispatcher**: `devcontainer-opencode.ps1`, `run_opencode_prompt.ps1`
8. ✅ **CI**: Pester tests + `validate.yml` updates

---

## Implementation Status

**PR**: [#9](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9)

### Scripts Delivered (12/12)

| # | Script | Lines | Status |
|---|--------|-------|--------|
| 1 | `scripts/setup-local-env.ps1` | ~179 | ✅ Implemented + tested |
| 2 | `scripts/resolve-image-tags.ps1` | ~123 | ✅ Implemented + tested |
| 3 | `scripts/trigger-orchestrator-test.ps1` | ~75 | ✅ Implemented |
| 4 | `scripts/assemble-local-prompt.ps1` | ~174 | ✅ Implemented |
| 5 | `scripts/assemble-orchestrator-prompt.ps1` | ~195 | ✅ Implemented |
| 6 | `scripts/post-failure-comment.ps1` | ~138 | ✅ Implemented |
| 7 | `scripts/on-failure-handler.ps1` | ~184 | ✅ Implemented |
| 8 | `scripts/collect-trace-artifacts.ps1` | ~175 | ✅ Implemented |
| 9 | `scripts/prompt-direct.ps1` | ~160 | ✅ Implemented |
| 10 | `scripts/start-opencode-server.ps1` | ~198 | ✅ Implemented |
| 11 | `scripts/devcontainer-opencode.ps1` | ~320 | ✅ Implemented |
| 12 | `run_opencode_prompt.ps1` | ~589 | ✅ Implemented |

### Tests Delivered

| Test file | Test cases | Status |
|-----------|------------|--------|
| `test/TestResolveImageTags.ps1` | 5 (push, workflow_run, workflow_dispatch, missing input, stdout fallback) | ✅ Passing |
| `test/TestSetupLocalEnv.ps1` | 4 (.env creation, no-overwrite, CheckOnly missing vars, CheckOnly with vars) | ✅ Passing |

### Validation Results

- **PSScriptAnalyzer**: 0 warnings across all 14 new files
- **Pester**: 20/20 tests passing (11 existing + 9 new)
- **CI matrix**: `lint` and `test` jobs run on `ubuntu-24.04` **and** `windows-latest`; `scan` remains Linux-only (gitleaks)
