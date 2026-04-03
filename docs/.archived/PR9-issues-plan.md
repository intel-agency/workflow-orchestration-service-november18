# PR #9 Review Fix Execution Plan

PR: [#9 feat: add PowerShell cross-platform equivalents for all shell scripts](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9)

Source detail doc: [`docs/PR9-issues.md`](./PR9-issues.md)

## Purpose

This document converts the raw review-comment inventory into an execution plan.

Each grouped item is rated on two axes:

- `Gain` = seriousness of the issue plus the value of fixing it now
- `Risk` = complexity plus regression risk

Both are scored `1-5`, where `5` is highest.

## Phase Strategy

The work is grouped to maximize safety:

1. Fix correctness bugs that can break the PowerShell path or produce wrong runtime behavior.
2. Fix operational parity issues that affect reliability but touch process-management code.
3. Fix observability, safety, and low-risk UX issues.
4. Fix documentation and typo issues.
5. Defer anything with weak value relative to churn if it is already superseded by a better fix.

## Phase Summary

| Phase | Theme | Why first/why later |
|---|---|---|
| Phase 1 | Broken execution paths and silent incorrect behavior | Highest gain, lowest ambiguity |
| Phase 2 | Server lifecycle and runtime parity | High gain, but touches fragile process-management code |
| Phase 3 | Diagnostics, safety, and operator UX | Valuable, mostly localized |
| Phase 4 | Documentation and wording cleanup | Important, but lowest product/runtime risk |
| Deferred | Low-value or already-covered variants | Avoid extra churn where one fix resolves several comments |

## Execution Matrix

### Phase 1 — Functional correctness and path parity

| Group ID | Gain | Risk | Decision | Files | Review comments |
|---|---:|---:|---|---|---|
| P1-A | 5 | 2 | Implement | `scripts/devcontainer-opencode.ps1` | [Gemini critical: Invoke-Prompt broken](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025940088), [Augment: still calls bash start script](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924804), [Copilot: still calls bash start script](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935037), [Copilot outdated: prompt command still calls `.sh`](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935040) |
| P1-B | 5 | 1 | Implement | `scripts/assemble-orchestrator-prompt.ps1` | [Augment: marker-missing drops template](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924794), [Copilot: marker not found builds empty beforeMarker](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025934998), [Gemini: marker logic bug](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025940090), [Copilot: escaped regex with `-SimpleMatch`](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025934986), [Copilot later pass: same `-SimpleMatch` bug](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610699), [Augment: `EVENT_JSON` not validated](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924802), [Copilot later pass: `EVENT_JSON` unset should fail fast](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610724), [Copilot later pass: same marker issue after rebasing](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027678907) |
| P1-C | 4 | 2 | Implement | `scripts/collect-trace-artifacts.ps1` | [Augment: `try/catch` misses `$LASTEXITCODE`](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924808), [Copilot: missing `$ErrorActionPreference='Stop'`](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935044), [Copilot: non-zero `devcontainer exec` not handled](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935051), [Copilot: binary tar pipeline unsafe](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935060) |
| P1-D | 4 | 1 | Implement | `scripts/prompt-direct.ps1` | [Augment: error message points to bash script](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924814), [Gemini: same bash-vs-pwsh message](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025940100), [Copilot: same bash-vs-pwsh message](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610788), [Copilot: missing `$LASTEXITCODE` after `devcontainer`](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935111), [Copilot later pass: docker command captured without checking `$LASTEXITCODE`](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027678969) |

#### Phase 1 rationale

These fixes unblock the PowerShell flow itself:

- `prompt` currently does not actually exercise the new `.ps1` runner.
- prompt assembly can silently generate broken output.
- artifact collection can fail without telling CI.
- direct prompting reports the wrong remediation path and can hide command failures.

These are the safest high-gain fixes because they are localized and easy to validate.

### Phase 2 — Runtime lifecycle parity

| Group ID | Gain | Risk | Decision | Files | Review comments |
|---|---:|---:|---|---|---|
| P2-A | 5 | 4 | Implement | `scripts/start-opencode-server.ps1` | [Augment: `Start-Process` may stay tied to exec session](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924803), [Copilot: use `setsid` for lifecycle parity](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935030), [Copilot later pass: same detach/log-parity concern](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610757), [Copilot later pass: implementation/comment mismatch on single-log behavior](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027679050) |
| P2-B | 4 | 1 | Implement | `scripts/start-opencode-server.ps1`, `run_opencode_prompt.ps1` | [Copilot: `/tmp` hardcoded in start script](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935009), [Gemini: temp-path portability in runner](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025940098) |
| P2-C | 4 | 1 | Implement | `scripts/start-opencode-server.ps1` | [Copilot: readiness check throws on non-2xx](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935021), [Copilot later pass: same readiness false-negative](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610742) |
| P2-D | 3 | 1 | Implement | `run_opencode_prompt.ps1` | [Augment: script is Linux/devcontainer-only despite cross-platform wording](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924805) |

#### Phase 2 rationale

These changes touch the most delicate behavior in the PR: background process detachment, logs, and readiness checks. They should happen after the safer correctness fixes so the repo is in a known-good state first.

### Phase 3 — Diagnostics, secrets hygiene, and interface cleanup

| Group ID | Gain | Risk | Decision | Files | Review comments |
|---|---:|---:|---|---|---|
| P3-A | 4 | 1 | Implement | `run_opencode_prompt.ps1` | [Copilot: debug logs may leak basic-auth credentials](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610777) |
| P3-B | 2 | 1 | Implement | `run_opencode_prompt.ps1` or `scripts/start-opencode-server.ps1` | [Copilot: `-PrintLogs` parameter is exposed but not actually wired up](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935074) |
| P3-C | 2 | 1 | Implement | `.copilot/mcp-config.json` | [Copilot: trailing whitespace introduced](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027679035) |

#### Phase 3 rationale

These are not core blockers, but they are cheap and worthwhile once runtime parity is in place.

### Phase 4 — Documentation and wording cleanup

| Group ID | Gain | Risk | Decision | Files | Review comments |
|---|---:|---:|---|---|---|
| P4-A | 3 | 1 | Implement | `docs/code-guidelines.md` | [Augment: duplicated guidance + typos](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924820), [Copilot: document has spelling/grammar errors](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935077), [Copilot: more typos](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935089), [Gemini: typo batch](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025940092), [Copilot later pass: header typo](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610800), [Copilot later pass: spelling `unncessary`](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610818), [Copilot later pass: remove TODO-style line](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610835) |
| P4-B | 3 | 1 | Implement | `docs/pwsh-scripts.md` | [Augment: misleading `validate.yml` wording](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025924816), [Copilot: cross-platform-path rule contradicts container paths](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3025935098), [Copilot later pass: `-DryRun` rule stronger than repo practice](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027610845) |
| P4-C | 2 | 1 | Implement | `AGENTS.md` | [Copilot: `technologie4s` typo](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027678992), [Copilot: `anaylsis` typo](https://github.com/intel-agency/ai-new-workflow-app-template/pull/9#discussion_r3027679012) |

#### Phase 4 rationale

These are safe cleanups and should be done after the runtime changes so the final docs match the actual implementation, not the pre-fix state.

## Deferred / Non-separate Items

These comments will not be treated as separate implementation tracks because they are fully covered by grouped fixes above.

| Covered by | Not split separately because |
|---|---|
| P1-A | Multiple comments describe the same `devcontainer-opencode.ps1` bash-to-pwsh invocation problem |
| P1-B | Marker handling, `Select-String`, and `EVENT_JSON` are all the same prompt-assembly surface and should be changed together |
| P2-A | The detach concern, single-log behavior, and implementation/comment mismatch are all the same lifecycle-parity fix |
| P4-A | The code-guidelines comments are all typo / placeholder variants in the same tiny doc |

## True Deferrals

At planning time, these are the only items that may be deferred if validation shows they add churn without meaningful benefit:

| Item | Current leaning | Why it may be deferred |
|---|---|---|
| `-PrintLogs` parameter cleanup | Probably implement | Trivial, but only worth changing if it improves clarity without breaking parity expectations |
| `.copilot/mcp-config.json` trailing whitespace | Probably implement | Very low risk, but unrelated to runtime behavior |

## Status Tracker

| Group ID | Status | Notes |
|---|---|---|
| P1-A | Done | `devcontainer-opencode.ps1` now invokes the PowerShell runner and uses PowerShell parameter names |
| P1-B | Done | Prompt assembly now validates `EVENT_JSON`, finds the marker correctly, and keeps the template when the marker is absent |
| P1-C | Done | Artifact collection now treats native-command failures explicitly and avoids the binary tar pipeline |
| P1-D | Done | `prompt-direct.ps1` now reports PowerShell-native guidance and propagates Docker/devcontainer failures |
| P2-A | Done | Linux path now launches `opencode serve` via `setsid` and writes combined output to the main log; the non-Linux stderr split is now documented explicitly in-code |
| P2-B | Done | Temp-file defaults now use `GetTempPath()` instead of hard-coded `/tmp` |
| P2-C | Done | Readiness checks now treat any HTTP response as evidence that the server is reachable |
| P2-D | Done | `run_opencode_prompt.ps1` now declares and enforces its Linux/devcontainer execution scope |
| P3-A | Done | Debug logging now redacts embedded basic-auth credentials |
| P3-B | Done | `-PrintLogs` now has real behavior while preserving the previous default-on behavior |
| P3-C | Done | Trailing whitespace in `.copilot/mcp-config.json` removed |
| P4-A | Done | `docs/code-guidelines.md` typos fixed and TODO-style placeholder removed |
| P4-B | Partial | Cross-platform-path and `-DryRun` wording updated; the old `validate.yml` comment was already outdated relative to the current branch and did not require an additional code/doc change |
| P4-C | Done | `AGENTS.md` typos fixed |

All addressed review comments received reply summaries, and all 46 PR review threads were resolved after validation passed.

## Update Protocol For Execution

As fixes land:

1. Update this file with `Done` / `Deferred` / `Partially done`.
2. Update `docs/PR9-issues.md` with per-item disposition and a short summary of the implemented fix.
3. Reply to each addressed PR review comment with a short fix summary.
4. Resolve the corresponding PR review thread after validation passes.
