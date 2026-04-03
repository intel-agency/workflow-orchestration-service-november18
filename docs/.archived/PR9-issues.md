# PR #9 Review Comment Fix Plan

## Current Status Summary

Detailed execution plan: [`docs/PR9-issues-plan.md`](./PR9-issues-plan.md)

Validation status on current branch:

- `pwsh -NoProfile -File .\test\run-pester-tests.ps1` ✅ passed (`20/20`)
- `pwsh -NoProfile -File .\scripts\validate.ps1 -Test` ✅ passed
- Addressed review comments received follow-up replies; all 46 PR review threads were resolved

## Outcome Summary

| Area | Status | Summary |
|---|---|---|
| `scripts/devcontainer-opencode.ps1` | Fixed | Switched `start` and `prompt` paths from bash scripts to PowerShell scripts and corrected the `run_opencode_prompt.ps1` parameter names |
| `scripts/assemble-orchestrator-prompt.ps1` | Fixed | Corrected marker handling, fixed the `Select-String -SimpleMatch` bug, and now fail fast when `EVENT_JSON` is missing |
| `scripts/collect-trace-artifacts.ps1` | Fixed | Added explicit native-command exit handling and replaced the binary tar pipeline with temp-file extraction |
| `scripts/prompt-direct.ps1` | Fixed | Error guidance now points to the PowerShell workflow; Docker/devcontainer failures now propagate correctly |
| `scripts/start-opencode-server.ps1` | Fixed | Uses `GetTempPath()` defaults, treats non-2xx HTTP responses as reachable, detaches the Linux server process via `setsid` with combined log output, and now documents the non-Linux stderr split explicitly in-code |
| `run_opencode_prompt.ps1` | Fixed | Declares Linux/devcontainer-only scope, uses temp-path defaults, redacts credential-bearing debug output, and wires `-PrintLogs` so it is no longer misleading |
| `docs/code-guidelines.md` | Fixed | Removed the placeholder line and corrected the typo/grammar issues called out in review |
| `docs/pwsh-scripts.md` | Partially fixed | Updated the cross-platform-path and `-DryRun` wording; no extra change was made for the old `validate.yml` comment because that review note is outdated relative to the current branch state |
| `AGENTS.md` | Fixed | Corrected the typos noted in review |
| `.copilot/mcp-config.json` | Fixed | Removed introduced trailing whitespace |

## Deferred / No-op Items

| Item | Status | Why |
|---|---|---|
| `docs/pwsh-scripts.md` comment claiming `validate.yml` mismatch | No additional change | The review note is now stale relative to the branch contents; the current branch already contains the workflow updates referenced by the docs |
| `docs/code-guidelines.md` duplication vs `AGENTS.md` | Accepted for now | The immediate clarity issues were the typos and placeholder text. Keeping the doc avoids extra churn while still making it readable |

**PR:** feat: add PowerShell cross-platform equivalents for all shell scripts  
**Branch:** `feature/pwsh-cross-platform-scripts`  
**Reviewers:** augmentcode, copilot-pull-request-reviewer, gemini-code-assist

---

## Summary

All review comments are from automated reviewers (Augment, Copilot, Gemini). They fall into four severity tiers:

| Severity | Count | Files Affected |
|----------|-------|---------------|
| Critical | 1 | `scripts/devcontainer-opencode.ps1` |
| High | 2 | `scripts/start-opencode-server.ps1`, `scripts/assemble-orchestrator-prompt.ps1` |
| Medium | 11 | Multiple script and doc files |
| Low | 5 | Doc files, unused parameter |

---

## Critical Issues

### 1. `scripts/devcontainer-opencode.ps1` — `Invoke-Prompt` is broken (Gemini)

**Location:** `Invoke-Prompt` function  
**Reviewers:** gemini-code-assist (critical)

**Analysis:**  
The `Invoke-Prompt` function has two defects:

1. **Array embedding bug** — `$promptArgs` is embedded inside the `@(...)` array literal using a subexpression. In PowerShell you cannot embed an array inside another array literal via `@(...$array...)` syntax directly — it must be concatenated using `+`. The current code produces a nested object instead of a flat argument list, which causes `devcontainer exec` to receive malformed arguments.

2. **Wrong inner script and argument names** — The exec command calls `bash ./run_opencode_prompt.sh -f / -p / -a / -d`, which are the **bash** short flags. The PS1 equivalent `run_opencode_prompt.ps1` uses long-form PowerShell parameter names: `-File`, `-PromptString`, `-AttachUrl`, `-WorkDir`. This means the PowerShell path never actually invokes the `.ps1` script.

**Root Cause:**  
Lines in `Invoke-Prompt` that build `$execArgs`:

```powershell
# BUG 1: array embedding
$execArgs = @('exec') + $sharedArgs + @(
    ...
    'bash', './run_opencode_prompt.sh',   # BUG 2: wrong script + wrong arg names
    '-a', $OpenCodeServerUrl,
    '-d', $serverDir
) + $promptArgs
```

**Fix:**  
- Change `bash ./run_opencode_prompt.sh` → `pwsh ./run_opencode_prompt.ps1`
- Change `-a` → `-AttachUrl`, `-d` → `-WorkDir`
- Change `-f` / `-p` (in `$promptArgs`) → `-File` / `-PromptString`
- Use `+` concatenation for the final `$promptArgs` array (already done in current code — verify the inner `$promptArgs` definition uses matching long names)

---

## High Issues

### 2. `scripts/start-opencode-server.ps1:154` — `Start-Process` does not detach from session (Augment, Copilot x2)

**Location:** Line ~154 where `Start-Process` is called  
**Reviewers:** augmentcode (high), copilot-pull-request-reviewer (x2)

**Analysis:**  
The bash original uses `setsid opencode serve ... &` which creates a **new session** for the child process. This is required so that `opencode serve` survives `devcontainer exec` teardown — when the exec session ends, its process group receives SIGHUP, which would kill any children that share the group. `setsid` moves the child into a new session/process group, immune to that signal.

The PowerShell version uses `Start-Process` without an equivalent detach mechanism. On Linux (where devcontainers run), this means `opencode serve` may be killed when the `devcontainer exec` session exits.

Additionally, the bash version appends both stdout and stderr to a **single log file**. The PS1 version redirects stderr to a separate `*.stderr` file, breaking the assumption of downstream log-tailers that read one file.

**Root Cause:**  

```powershell
$proc = Start-Process -FilePath 'opencode' `
    -ArgumentList @('serve', '--hostname', $Hostname, ...) `
    -NoNewWindow `
    -RedirectStandardOutput $LogFile `         # truncates, not appends
    -RedirectStandardError $stderrLog `        # separate file — behavioral difference
    -PassThru
```

**Fix:**
- On `$IsLinux`, launch via `setsid` as the `-FilePath` and pass `opencode` as the first element of `-ArgumentList`
- Use `Start-Process` with `-NoNewWindow` and `-PassThru` to get the PID
- Merge stderr into the stdout log by redirecting stderr to stdout inside a wrapper (or use `bash -c 'setsid opencode ... >> $log 2>&1 &'` for the Linux path)

---

### 3. `scripts/assemble-orchestrator-prompt.ps1:138` — Missing marker drops entire template (Augment, Copilot, Gemini)

**Location:** Line 138 — marker search and `$beforeMarker` assignment  
**Reviewers:** augmentcode (medium), copilot-pull-request-reviewer (medium), gemini-code-assist (high)

**Analysis:**  

```powershell
if ($markerIndex -le 0) {
    $beforeMarker = @()    # BUG: sets to empty when marker is missing OR at line 0
} else {
    $beforeMarker = $templateLines[0..($markerIndex - 1)]
}
```

When `$markerIndex` is `-1` (marker not found), this condition is **true** (`-1 -le 0`), so `$beforeMarker` is set to an empty array. The assembled prompt then contains only the event block and JSON — the entire template content is silently discarded.

The bash equivalent uses `sed '/{{__EVENT_DATA__}}/,$ d'`, which **keeps the entire file unchanged** when the marker is absent. The PS1 behavior diverges significantly.

Additionally, when `$markerIndex` is `0` (marker on the very first line), the condition is also true, which would also incorrectly discard the template. This is a secondary bug.

**Fix:**

```powershell
if ($markerIndex -lt 0) {
    # Marker not found — fall back to full template (matches bash sed behavior)
    $beforeMarker = $templateLines
} elseif ($markerIndex -eq 0) {
    $beforeMarker = @()   # marker on line 1 — nothing before it
} else {
    $beforeMarker = $templateLines[0..($markerIndex - 1)]
}
```

---

## Medium Issues

### 4. `scripts/assemble-orchestrator-prompt.ps1` — `Select-String -SimpleMatch` never matches (Copilot x2)

**Location:** Template diagnostics section — `Select-String` call  
**Reviewers:** copilot-pull-request-reviewer (x2)

**Analysis:**  

```powershell
$injectionHits = $templateLines |
    Select-String -Pattern '\{\{__EVENT_DATA__\}\}' -SimpleMatch
```

With `-SimpleMatch`, PowerShell treats the pattern as a **literal string**, not a regex. The literal string here is `\{\{__EVENT_DATA__\}\}` — with backslashes — which will **never** match the actual marker text `{{__EVENT_DATA__}}`. The diagnostic will always report the marker as missing, even when it is present.

**Fix:** Use the literal string with `-SimpleMatch`:

```powershell
Select-String -Pattern '{{__EVENT_DATA__}}' -SimpleMatch
```

Or drop `-SimpleMatch` and use the correctly escaped regex:

```powershell
Select-String -Pattern '\{\{__EVENT_DATA__\}\}'
```

---

### 5. `scripts/assemble-orchestrator-prompt.ps1:144` — `EVENT_JSON` not validated (Augment, Copilot)

**Location:** Line 144 — `$eventJson = $env:EVENT_JSON`  
**Reviewers:** augmentcode (medium), copilot-pull-request-reviewer (medium)

**Analysis:**  
The bash source uses `set -u`, which causes the script to fail immediately if `EVENT_JSON` is unset. The PS1 version assigns `$env:EVENT_JSON` to `$eventJson` without validation. If `EVENT_JSON` is empty or unset, the assembled prompt will contain an empty ` ```json ``` ` block, and the orchestrator may mis-route the event because it cannot read event data.

**Fix:** After the `$customPrompt` short-circuit block, add explicit validation:

```powershell
$eventJson = $env:EVENT_JSON
if ([string]::IsNullOrWhiteSpace($eventJson)) {
    Write-Error 'EVENT_JSON environment variable is required when CUSTOM_PROMPT is not set'
}
```

---

### 6. `scripts/devcontainer-opencode.ps1:161,211` — Still calls bash scripts (Augment, Copilot)

**Location:** Lines 161 (start command) and 211 (prompt command)  
**Reviewers:** augmentcode (medium), copilot-pull-request-reviewer

**Analysis:**  
- `Invoke-Start` at line 161: `devcontainer exec @sharedArgs -- bash ./scripts/start-opencode-server.sh`  
  → Should use `pwsh ./scripts/start-opencode-server.ps1`
- `Invoke-Prompt` at line 211: `bash ./run_opencode_prompt.sh` (also covered in Critical item #1)  
  → Should use `pwsh ./run_opencode_prompt.ps1`

This defeats the purpose of the new `.ps1` scripts — neither is ever exercised by the primary `devcontainer-opencode.ps1` dispatcher.

**Fix:** Replace both bash invocations with `pwsh` equivalents.

---

### 7. `scripts/start-opencode-server.ps1` — Hardcoded `/tmp` paths (Copilot, Gemini)

**Location:** `$LogFile` and `$PidFile` defaults  
**Reviewers:** copilot-pull-request-reviewer, gemini-code-assist (medium)

**Analysis:**  

```powershell
$LogFile = if ($env:OPENCODE_SERVER_LOG) { ... } else { '/tmp/opencode-serve.log' }
$PidFile = if ($env:OPENCODE_SERVER_PIDFILE) { ... } else { '/tmp/opencode-serve.pid' }
```

`/tmp` does not exist on Windows. While this script runs inside a Linux devcontainer, it is described as cross-platform, and `/tmp` hardcoding violates the repo's own cross-platform convention.

**Fix:**

```powershell
$TempDir = [IO.Path]::GetTempPath()
$LogFile = if ($env:OPENCODE_SERVER_LOG) { $env:OPENCODE_SERVER_LOG } else { Join-Path $TempDir 'opencode-serve.log' }
$PidFile = if ($env:OPENCODE_SERVER_PIDFILE) { $env:OPENCODE_SERVER_PIDFILE } else { Join-Path $TempDir 'opencode-serve.pid' }
```

---

### 8. `scripts/start-opencode-server.ps1` — `Test-ServerReady` false negatives (Copilot x2)

**Location:** `Test-ServerReady` function  
**Reviewers:** copilot-pull-request-reviewer (x2)

**Analysis:**  

```powershell
Invoke-WebRequest -Uri $ReadyUrl -TimeoutSec 2 -ErrorAction Stop | Out-Null
```

`Invoke-WebRequest` throws on **any non-2xx** HTTP status code. The bash readiness check uses `curl -s -o /dev/null` which only checks TCP connectivity — a 404 from the server means "server is up." This behavioral difference causes unnecessary timeouts and server restart attempts in scenarios where the server returns e.g. 404 on the root path but is otherwise healthy.

**Fix:**

```powershell
$response = Invoke-WebRequest -Uri $ReadyUrl -TimeoutSec 2 -ErrorAction Stop -SkipHttpErrorCheck
return ($null -ne $response)
```

---

### 9. `scripts/collect-trace-artifacts.ps1` — `try/catch` misses native command failures (Augment, Copilot x2)

**Location:** Lines ~96+ — the three `try { devcontainer exec ... } catch { ... }` blocks  
**Reviewers:** augmentcode (medium), copilot-pull-request-reviewer (x2)

**Analysis:**  
`try/catch` in PowerShell only catches **terminating errors** (thrown exceptions). External native commands like `devcontainer exec` do **not** throw — they only set `$LASTEXITCODE`. The `catch` block therefore never executes when `devcontainer exec` fails, and the script silently proceeds as if artifacts were collected.

Furthermore, the script sets `Set-StrictMode -Version Latest` but does **not** set `$ErrorActionPreference = 'Stop'`, so cmdlet errors are also non-terminating and uncaught.

**Fix:**
1. Add `$ErrorActionPreference = 'Stop'` at top of script
2. After each `devcontainer exec` call, check `$LASTEXITCODE`:

```powershell
if ($LASTEXITCODE -ne 0) {
    Write-Warning "devcontainer exec (gather logs) failed with exit code $LASTEXITCODE"
}
```

---

### 10. `scripts/collect-trace-artifacts.ps1` — Binary tar pipeline unsafe (Copilot)

**Location:** Step 3 tar extraction  
**Reviewers:** copilot-pull-request-reviewer

**Analysis:**  

```powershell
devcontainer exec ... -- bash -c 'tar -cf - -C /tmp/trace-bundle .' | tar -xf - -C $TraceArtifactsDir
```

PowerShell's native command pipeline is not reliably binary-safe. String encoding conversions applied to pipeline data can corrupt binary tar streams, producing broken or incomplete artifacts.

**Fix:** Write tar output to a temporary file and extract from that file:

```powershell
$bundleTar = Join-Path $TraceArtifactsDir 'trace-bundle.tar'
devcontainer exec ... -- bash -c 'tar -cf - -C /tmp/trace-bundle .' > $bundleTar 2>$null
tar -xf $bundleTar -C $TraceArtifactsDir 2>$null
Remove-Item $bundleTar -ErrorAction SilentlyContinue
```

---

### 11. `scripts/prompt-direct.ps1` (and `scripts/devcontainer-opencode.ps1`) — `devcontainer` exit code not checked (Copilot)

**Location:** Final `devcontainer @dcArgs` call in `prompt-direct.ps1`  
**Reviewers:** copilot-pull-request-reviewer

**Analysis:**  

```powershell
devcontainer @dcArgs
# No $LASTEXITCODE check
```

If `devcontainer exec` fails, the script exits with code 0, hiding the failure from CI and callers.

**Fix:**

```powershell
devcontainer @dcArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "devcontainer exec failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
```

---

### 12. `run_opencode_prompt.ps1:63` — Linux-only despite "cross-platform" claim (Augment)

**Location:** `Send-Signal`, `Test-ProcessAlive`, watchdog loop, and tail scripts  
**Reviewers:** augmentcode (medium)

**Analysis:**  
The script uses:
- `bash -c "kill -9 $pid"` / `bash -c "kill -0 $pid"` for process signaling
- `sed`, `tail`, `/proc/<pid>/io` in bash subshells
- `stdbuf`, `setsid` (via bash launcher)

These are Linux-only utilities. On Windows or macOS without a Linux userland, this script will fail at runtime. The PR describes it as a "cross-platform equivalent" but the implementation is explicitly Linux/devcontainer-scoped.

**Fix options:**
1. **Clarify scope** — Update the `.DESCRIPTION` and PR docs to state this script is designed exclusively for Linux devcontainer environments (matching the bash original's runtime environment), not for direct Windows/macOS host execution.
2. **Add platform guard** — Add an early check:

```powershell
if (-not $IsLinux) {
    Write-Error 'run_opencode_prompt.ps1 is designed for Linux devcontainer environments only'
    exit 1
}
```

Option 1 is the minimal, correct fix. Option 2 adds a guard that makes the scope explicit at runtime.

---

### 13. `run_opencode_prompt.ps1` — Hardcoded `/tmp` for server log and PID (Copilot, Gemini)

**Location:** `$ServerLog` and `$ServerPidFile` defaults  
**Reviewers:** copilot-pull-request-reviewer, gemini-code-assist (medium)

**Analysis:**  
Same issue as item #7 — `/tmp` hardcoded. Consistent with item #7 fix.

**Fix:**

```powershell
$tempBase      = [System.IO.Path]::GetTempPath()
$ServerLog     = if ($env:OPENCODE_SERVER_LOG)    { $env:OPENCODE_SERVER_LOG }    else { Join-Path $tempBase 'opencode-serve.log' }
$ServerPidFile = if ($env:OPENCODE_SERVER_PIDFILE) { $env:OPENCODE_SERVER_PIDFILE } else { Join-Path $tempBase 'opencode-serve.pid' }
```

---

### 14. `run_opencode_prompt.ps1` — Debug mode logs credentials (Copilot)

**Location:** Debug diagnostics loop that prints `$opencodeArgs`  
**Reviewers:** copilot-pull-request-reviewer

**Analysis:**  
When `DEBUG_ORCHESTRATOR=true`, the script iterates `$opencodeArgs` and prints each argument. If basic-auth credentials are embedded in `-AttachUrl` as `https://user:pass@host:port`, the full credential string is printed to CI logs.

**Fix:** Redact credentials in debug output:

```powershell
$safeArg = $opencodeArgs[$i] -replace '://[^:@/]+:[^@/]+@', '://<redacted>@'
Write-Host "  [$i] $safeArg"
```

---

### 15. `scripts/prompt-direct.ps1:112` — Error message references bash script (Augment, Copilot, Gemini)

**Location:** Line 112 — error for missing devcontainer  
**Reviewers:** augmentcode (low), copilot-pull-request-reviewer, gemini-code-assist (medium)

**Analysis:**  

```powershell
"Start it first: bash scripts/devcontainer-opencode.sh up"
```

A Windows/macOS user running `prompt-direct.ps1` to stay in the PowerShell workflow would be confused by an error telling them to run a bash script.

**Fix:**

```powershell
"Start it first: ./scripts/devcontainer-opencode.ps1 up"
```

---

## Low Issues

### 16. `docs/code-guidelines.md` — Typos, placeholder, and duplication (Augment, Copilot, Gemini)

**Location:** Entire file  
**Reviewers:** augmentcode (low), copilot-pull-request-reviewer (x2), gemini-code-assist (medium)

**Analysis:**  
The file contains multiple typos introduced at creation:
- Line 4: `"Add code guidelines to AGENTS.md"` — leftover task instruction, not documentation
- Line 5: `"Guideliens"` → `"Guidelines"`
- Line 9: `"unncessary"` → `"unnecessary"`
- Line 11: `"Dont"` → `"Don't"`
- Line 13: `"speifici firth-hand"` → `"specific first-hand"`
- Line 15: `"havent"` → `"haven't"`, `"proscribed"` → `"prescribed"`

Additionally, the file duplicates rules already added to `AGENTS.md`, undermining AGENTS.md as the single source of truth.

**Fix options:**
1. Fix all typos, remove the placeholder line — keep the file as supplementary documentation with a note that AGENTS.md is canonical
2. Delete the file and add a cross-reference in AGENTS.md if needed

Option 1 is safer (preserves documentation for human readers unfamiliar with AGENTS.md).

---

### 17. `docs/pwsh-scripts.md:35-42` — Claims `validate.yml` updated when it isn't (Augment)

**Location:** Acceptance criteria section, lines 35-42  
**Reviewers:** augmentcode (medium)

**Analysis:**  
The document states "validate.yml is updated to exercise the PowerShell scripts" but the PR diff shows no changes to `.github/workflows/validate.yml`. The validate.yml diff in the PR adds a matrix (`ubuntu-24.04` and `windows-latest`) which does run the Pester tests on Windows — so the CI coverage claim is partially true. However, the document says "validate.yml is updated" in the acceptance criteria checklist, which is misleading since the actual yml file is not listed as changed.

**Fix:** Update the doc to accurately describe what was changed: the matrix expansion in validate.yml runs existing Pester tests on both platforms.

---

### 18. `docs/pwsh-scripts.md` — Cross-platform paths convention contradicts scripts (Copilot)

**Location:** Conventions section, "Cross-platform paths" bullet  
**Reviewers:** copilot-pull-request-reviewer

**Analysis:**  
Convention reads: "never hard-code `/` or `\`" — but several scripts in the PR legitimately hard-code container-specific paths (`/tmp`, `/workspaces/...`) because they run inside a Linux devcontainer where those paths are guaranteed.

**Fix:** Relax the convention wording:
> For scripts intended to run on multiple platforms, use `Join-Path` instead of hard-coded separators; known environment- or container-specific absolute paths (e.g., `/tmp`, `/workspaces`) are allowed where appropriate.

---

### 19. `docs/pwsh-scripts.md` — `-DryRun` convention not consistently implemented (Copilot)

**Location:** Conventions section, bullet 6  
**Reviewers:** copilot-pull-request-reviewer

**Analysis:**  
Convention bullet 6 states: "Include a `-DryRun` switch for any script that mutates state." Several new scripts mutate state but do not implement `-DryRun` (e.g., `setup-local-env.ps1` writes `.env`, `start-opencode-server.ps1` writes PID/log files).

**Fix:** Soften the convention bullet to express intent without mandating it retroactively on existing scripts:
> Prefer including a `-DryRun` switch for new scripts that mutate state, even though some existing scripts may not yet implement this.

---

### 20. `scripts/start-opencode-server.ps1` — `-PrintLogs` parameter unused (Copilot)

**Location:** Parameter declaration and argument building  
**Reviewers:** copilot-pull-request-reviewer

**Analysis:**  
The script declares `[switch]$PrintLogs` as a parameter but never references `$PrintLogs` in the body. The `--print-logs` flag is always added to the opencode arguments unconditionally, making the parameter a no-op that misleads the user about what the flag does.

**Fix option A:** Remove `-PrintLogs` parameter (simplest — matches current behavior where it's always on).  
**Fix option B:** Wire it up:

```powershell
if ($PrintLogs) { $arguments += '--print-logs' }
```

Option B preserves the API contract implied by the parameter declaration.

---

## Implementation Order

| Priority | Item | File(s) | Effort |
|----------|------|---------|--------|
| 1 | Fix `Invoke-Prompt` array bug + wrong script/args | `devcontainer-opencode.ps1` | Small |
| 2 | Fix marker-missing behavior in prompt assembly | `assemble-orchestrator-prompt.ps1` | Small |
| 3 | Fix `Select-String -SimpleMatch` pattern bug | `assemble-orchestrator-prompt.ps1` | Trivial |
| 4 | Validate `EVENT_JSON` when `CUSTOM_PROMPT` unset | `assemble-orchestrator-prompt.ps1` | Trivial |
| 5 | Switch `Invoke-Start` to call `start-opencode-server.ps1` | `devcontainer-opencode.ps1` | Trivial |
| 6 | Add `setsid` detach on Linux for server process | `start-opencode-server.ps1` | Small |
| 7 | Fix `/tmp` hardcoding → `GetTempPath()` | `start-opencode-server.ps1`, `run_opencode_prompt.ps1` | Trivial |
| 8 | Fix `Test-ServerReady` with `-SkipHttpErrorCheck` | `start-opencode-server.ps1` | Trivial |
| 9 | Add `$ErrorActionPreference='Stop'` + `$LASTEXITCODE` checks | `collect-trace-artifacts.ps1` | Small |
| 10 | Fix binary tar pipeline | `collect-trace-artifacts.ps1` | Small |
| 11 | Add `$LASTEXITCODE` check after `devcontainer` | `prompt-direct.ps1` | Trivial |
| 12 | Clarify Linux-only scope | `run_opencode_prompt.ps1` | Trivial |
| 13 | Redact credentials in debug output | `run_opencode_prompt.ps1` | Trivial |
| 14 | Fix error message to reference `.ps1` | `prompt-direct.ps1` | Trivial |
| 15 | Fix typos + placeholder line | `docs/code-guidelines.md` | Trivial |
| 16 | Clarify `validate.yml` claim | `docs/pwsh-scripts.md` | Trivial |
| 17 | Relax cross-platform paths convention | `docs/pwsh-scripts.md` | Trivial |
| 18 | Soften `-DryRun` convention bullet | `docs/pwsh-scripts.md` | Trivial |
| 19 | Wire up or remove `-PrintLogs` parameter | `start-opencode-server.ps1` | Trivial |
