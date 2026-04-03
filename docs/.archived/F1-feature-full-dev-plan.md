# F1 Feature Full Dev Plan: Orchestration Migration to Prebuild Container

> **Parent:** [new_features.md](new_features.md) § F1
> **Options analysis:** [F1-orchestration-migration-options.md](F1-orchestration-migration-options.md)
> **Status:** Planning
> **Dependencies:** None (F2, F3 depend on this)

---

## 1. Vision & Goals

Move **all** orchestration logic — opencode server, orchestrator agent, prompt assembly, CLI wrappers, MCP server infrastructure, and related workflows — out of this template repo and into the `intel-agency/workflow-orchestration-prebuild` container. The template repo becomes a **thin application-level scaffold** that references the prebuild container for all orchestration functionality.

### End-State Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Prebuild Container (intel-agency/workflow-orchestration-prebuild) │
│                                                                   │
│  Baked into Docker image:                                         │
│    - opencode CLI, MCP server binaries, .NET SDK, Bun, uv        │
│    - scripts/ (start-opencode-server.sh, devcontainer-opencode.sh,│
│      assemble-orchestrator-prompt.sh, resolve-image-tags.sh, …)   │
│    - run_opencode_prompt.sh                                       │
│                                                                   │
│  Checked out at runtime (from prebuild repo):                     │
│    - .opencode/agents/*.md (27 agents)                            │
│    - .opencode/commands/*.md (20 commands)                        │
│    - opencode.json (model configs, MCP defs)                      │
│    - models.json                                                  │
│    - AGENTS.md (generic orchestration instructions)               │
│    - prompts/orchestrator-agent-prompt.md (match clauses)         │
└─────────────────────────────────────────────────────────────────┘
                              │
               devcontainer up / exec
                              │
┌─────────────────────────────────────────────────────────────────┐
│  Template Clone Repo (application instance)                      │
│                                                                   │
│    - .devcontainer/devcontainer.json (image ref, env, ports)     │
│    - .github/workflows/orchestrator-agent.yml (skeleton)          │
│    - .github/workflows/validate.yml (project CI)                 │
│    - .github/.labels.json (project labels)                       │
│    - AGENTS.local.md (project-specific instructions)             │
│    - local_ai_instruction_modules/ (project overrides)           │
│    - plan_docs/ (seeded at clone time)                           │
│    - (application code)                                          │
└─────────────────────────────────────────────────────────────────┘
```

### Key Principle

The opencode server orchestration agent/logic will ultimately run as its own **independent service** — not embedded in any application repo. It can be invoked by GitHub App event-triggered webhooks (F3) or by the intra-workflow `devcontainers/ci` approach described below. F1 lays the groundwork by centralizing all orchestration code in the prebuild container.

---

## 2. Execution Model: Running Orchestration Inside the Devcontainer

### The Core Insight

The issues previously raised about how to run orchestration inside template clone repos are resolved by **executing the orchestrator-agent.yml workflow steps inside the devcontainer itself**. Once inside the running devcontainer, all calls work as before — the full orchestration runtime is available from the prebuild image.

### Approach: `devcontainers/ci` with `runCmd`

Use the [`devcontainers/ci`](https://github.com/devcontainers/ci) GitHub Action to spin up the devcontainer and execute orchestration commands inside it. This is the "Both at once" pattern from the devcontainers/ci Quick Start:

```yaml
- name: Run orchestration in devcontainer
  uses: devcontainers/ci@v0.3
  with:
    imageName: ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer
    cacheFrom: ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer
    push: never
    runCmd: |
      # Inside the devcontainer — full orchestration runtime available
      bash /opt/orchestration/scripts/assemble-orchestrator-prompt.sh \
        --event-name "$EVENT_NAME" \
        --event-json "$EVENT_JSON"
      bash /opt/orchestration/scripts/devcontainer-opencode.sh prompt \
        -f "$ORCHESTRATOR_PROMPT_PATH"
```

This pattern is also demonstrated in the existing (disabled) reference workflow at [.github/workflows/.disabled/agent-runner.yml](../.github/workflows/.disabled/agent-runner.yml), which uses `devcontainers/ci@v0.3` with `runCmd` to execute an opencode agent inside the container.

### Dual Execution Modes

This approach achieves full containment/isolation while supporting **two deployment modes**:

| Mode | Description | Trigger |
|-|-|-|
| **Intra-workflow** (current model, improved) | orchestrator-agent.yml uses `devcontainers/ci` `runCmd` to run orchestration inside the devcontainer as a GitHub Actions job step | GitHub event → workflow trigger → devcontainer exec |
| **Standalone service** (F3 target) | Prebuild container runs as a long-lived service at a known address; repos call it via `opencode run --attach` | GitHub App webhook → service endpoint → prompt attach |

Both modes use the **exact same container image and orchestration code**. The only difference is the invocation path.

---

## 3. Migration Strategy: Option C (Hybrid)

Per the [options analysis](F1-orchestration-migration-options.md), **Option C (Hybrid)** is the recommended approach:

- **Runtime** (scripts, CLIs, MCP server binaries, server bootstrapper) → **baked into Docker image**
- **Config** (agents, commands, prompt template, opencode.json, models.json) → **lives in prebuild repo, checked out at workflow time**

This gives fast iteration on agent definitions and prompts (no image rebuild needed) while keeping the stable runtime layer in the image.

### AGENTS.md Split

`AGENTS.md` must be split because it mixes generic orchestration instructions with project-specific content:

| New File | Location | Contains |
|-|-|-|
| `AGENTS.md` (generic) | Prebuild repo (checked out at runtime) | `<purpose>`, `<tech_stack>`, `<agent_specific_guardrails>`, `<tool_use_instructions>`, `<available_tools>`, `<testing>`, `<agent_readiness>`, `<validation_before_handoff>`, `<mandatory_tool_protocols>` |
| `AGENTS.local.md` (project-specific) | Template repo (stays in clones) | `<template_usage>`, `<repository_map>`, `<coding_conventions>`, `<environment_setup>` |

`opencode.json` instructions array becomes:

```json
"instructions": ["AGENTS.md", "AGENTS.local.md"]
```

opencode merges both files — generic base + project overlay.

See the [full section mapping](F1-orchestration-migration-options.md#the-agentsmd-split) in the options doc.

---

## 4. File Migration Plan

### Files to Move → Prebuild Repo (Docker Image Layer)

These are baked into the Docker image at build time. They change rarely and belong in the stable runtime layer.

| File / Dir (this template) | Destination in prebuild repo | Notes |
|-|-|-|
| `scripts/start-opencode-server.sh` | `/opt/orchestration/scripts/start-opencode-server.sh` | opencode serve daemon bootstrapper (uses `setsid` — critical for devcontainer exec survival) |
| `scripts/devcontainer-opencode.sh` | `/opt/orchestration/scripts/devcontainer-opencode.sh` | Primary CLI wrapper for devcontainer orchestration |
| `scripts/resolve-image-tags.sh` | `/opt/orchestration/scripts/resolve-image-tags.sh` | Image tag resolution helper |
| `scripts/install-dev-tools.ps1` | `/opt/orchestration/scripts/install-dev-tools.ps1` | Dev tooling installer |
| `run_opencode_prompt.sh` | `/opt/orchestration/run_opencode_prompt.sh` | opencode run entrypoint (gh auth + agent invocation) |
| `test/test-devcontainer-build.sh` | `test/test-devcontainer-build.sh` | Devcontainer build test |
| `test/test-devcontainer-tools.sh` | `test/test-devcontainer-tools.sh` | Tool availability test |
| `test/test-image-tag-logic.sh` | `test/test-image-tag-logic.sh` | Image tag resolution test |

### Files to Move → Prebuild Repo (Config Layer — Checked Out at Runtime)

These change more frequently (agent definitions, prompt tuning) and are overlaid at workflow time via a second `actions/checkout`.

| File / Dir (this template) | Destination in prebuild repo | Notes |
|-|-|-|
| `.opencode/agents/*.md` (27 agents) | `.opencode/agents/` | Specialist agent pool |
| `.opencode/commands/*.md` (20 commands) | `.opencode/commands/` | Reusable command prompts |
| `.opencode/package.json` + `node_modules/` | `.opencode/` | MCP server deps |
| `opencode.json` | `opencode.json` | Model configs, MCP defs |
| `models.json` | `models.json` | Model definitions |
| `.github/workflows/prompts/orchestrator-agent-prompt.md` | `prompts/orchestrator-agent-prompt.md` | Match clauses / orchestration state machine |
| `scripts/assemble-orchestrator-prompt.sh` | `scripts/assemble-orchestrator-prompt.sh` | Prompt assembly (may need path updates) |
| `AGENTS.md` (generic sections only) | `AGENTS.md` | After split — generic orchestration instructions |

### Files That Stay in Template

| File | Reason |
|-|-|
| `.devcontainer/devcontainer.json` | Consumer config — references prebuild GHCR image; clones need a working devcontainer |
| `.github/workflows/orchestrator-agent.yml` | Must live in the repo for GitHub Actions triggers — becomes a thin skeleton |
| `.github/workflows/validate.yml` | Project-level CI |
| `.github/.labels.json` | Project-specific label set |
| `AGENTS.local.md` (new) | Project-specific agent instructions (split from AGENTS.md) |
| `local_ai_instruction_modules/` | Project-specific instruction overrides |
| `plan_docs/` | Seeded at clone time per project |
| `scripts/validate.ps1` | Project-level validation (may slim down) |
| Application code | The whole point of the template |

---

## 5. Execution Plan

### Phase 1: Audit & Prepare Prebuild Repo

1. **Audit `intel-agency/workflow-orchestration-prebuild`** — inventory what's already there (Dockerfile, workflows, scripts). Identify overlaps and gaps.
2. **Define the `/opt/orchestration/` directory structure** inside the Docker image for baked-in runtime files.
3. **Plan the prebuild repo directory layout** for config files that get checked out at runtime.

### Phase 2: Split AGENTS.md

4. **Extract generic sections** from `AGENTS.md` into a new `AGENTS.md` in the prebuild repo.
5. **Create `AGENTS.local.md`** in this template with only project-specific sections (`<template_usage>`, `<repository_map>`, `<coding_conventions>`, `<environment_setup>`).
6. **Update `opencode.json`** instructions array to `["AGENTS.md", "AGENTS.local.md"]`.
7. **Verify opencode merges both files** correctly — test locally that agent behavior is unchanged.

### Phase 3: Move Runtime Scripts to Docker Image

8. **Add `COPY` directives** to the prebuild Dockerfile for runtime scripts → `/opt/orchestration/scripts/`.
9. **Update `start-opencode-server.sh`** path references — the consumer `devcontainer.json` `postStartCommand` must reference the new absolute path (`/opt/orchestration/scripts/start-opencode-server.sh`) or use a symlink.
10. **Move `run_opencode_prompt.sh`** into the image.
11. **Rebuild and publish** the prebuild image. Verify tag path unchanged: `ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest`.

### Phase 4: Move Config Files to Prebuild Repo

12. **Copy agent definitions** (`.opencode/agents/`, `.opencode/commands/`), `opencode.json`, `models.json`, and prompt template to the prebuild repo.
13. **Move prompt assembly script** and update paths for the new repo context.
14. **Move tests** that belong with the moved code (`test-devcontainer-build.sh`, `test-devcontainer-tools.sh`, `test-image-tag-logic.sh`).

### Phase 5: Update orchestrator-agent.yml Workflow

15. **Rewrite orchestrator-agent.yml** as a thin skeleton:
    - Checkout application repo (this repo)
    - Checkout prebuild repo → `.orchestration/`
    - Overlay config: copy/symlink `.opencode/`, `opencode.json`, `AGENTS.md`, prompt template into workspace
    - GHCR login + devcontainer up
    - `devcontainers/ci` `runCmd` executes orchestration inside the container
16. **Pin the `devcontainers/ci` action by full SHA** per coding conventions.
17. **Ensure trace output (stdout/stderr)** from the opencode process inside the devcontainer makes it up to the workflow run console. Test this explicitly.

### Phase 6: Delete Moved Files from Template

18. **Remove moved files** from this template repo (scripts, agents, commands, etc.).
19. **Update `validate.yml`** — remove or adjust jobs that referenced moved test files.
20. **Update `AGENTS.md`** (now `AGENTS.local.md`) `<repository_map>` — remove entries for deleted files, add entries for the overlay mechanism.

### Phase 7: Update Template Creation Scripts

21. **Update `create-repo-with-plan-docs.ps1`** in `workflow-launch2` — verify placeholder replacement still works. The consumer `devcontainer.json` image URL references `workflow-orchestration-prebuild` (not `ai-new-workflow-app-template`), so it should be unaffected, but confirm.
22. **Update placeholder list** — if any new files (e.g., `AGENTS.local.md`) contain template placeholders, ensure the creation script replaces them.

### Phase 8: Validate End-to-End

23. **Create a test clone** from the template via the creation script.
24. **Verify devcontainer pulls** the prebuild image and starts (including `opencode serve` via updated path).
25. **Trigger an orchestration run** (dispatch issue with a known label) and verify:
    - Config overlay works (agents, prompt, opencode.json present in workspace)
    - Prompt assembly succeeds with the new paths
    - opencode orchestrator runs and delegates correctly
    - Trace output appears in the workflow run console
26. **Run validation** in both repos: `./scripts/validate.ps1 -All`.

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|-|-|-|
| **Consumer `devcontainer.json` image URL changes** | All existing clones break | Keep image URL unchanged: `ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest` |
| **`start-opencode-server.sh` path dependency** | Devcontainer startup fails | Use absolute path `/opt/orchestration/scripts/start-opencode-server.sh` in `postStartCommand`, or keep a thin wrapper in template that calls the image path |
| **`setsid` behavior in `devcontainers/ci` `runCmd`** | opencode serve daemon may die when `runCmd` completes | Verify `setsid` still works in `devcontainers/ci` exec context (different from `devcontainer exec`). If not, use `runCmd` for one-shot prompt execution instead of daemon mode |
| **opencode expects `.opencode/` in workspace root** | Agent definitions not found | Overlay via `cp -r` or symlink from checkout path into workspace root before running opencode |
| **Config/runtime version skew** | Agents reference scripts or features not in the current image | Tag both image and config checkouts with matching version numbers. Use a version manifest file |
| **Trace output not reaching workflow console** | Silent failures, no debugging visibility | Explicitly test stdout/stderr propagation through `devcontainers/ci` `runCmd` in Phase 8 |
| **Secret/variable alignment** | Prebuild repo missing required secrets | Verify `VERSION_PREFIX` variable and GHCR push secrets exist in prebuild repo |
| **Two-checkout workflow adds latency** | Slower workflow startup | The prebuild repo checkout is small (config files only) — minimal overhead. Cache if needed |

---

## 7. Issues to Watch

### Trace Output (stdout)

All opencode process output and logging must propagate up to the workflow run's console. When using `devcontainers/ci` `runCmd`, verify:

- stdout from the orchestration scripts appears in the GitHub Actions step log
- stderr is captured (not swallowed)
- Long-running output is streamed, not buffered until completion

### `devcontainers/ci` vs. `devcontainer exec`

The existing workflow uses raw `devcontainer exec`. The `devcontainers/ci` action uses a different execution model:

- It can **build** and **run** the container in one step
- `runCmd` executes a command inside the container and waits for it to finish
- Behavior around process groups, session teardown, and background processes may differ from raw `devcontainer exec`

The known issue with `devcontainer exec` killing `nohup` background processes (requiring `setsid`) must be re-tested in the `devcontainers/ci` context.

### Template Placeholder Replacement

The `create-repo-with-plan-docs.ps1` script replaces `ai-new-workflow-app-template` → new repo name and `intel-agency` → new owner in file contents. After the migration:

- The consumer `devcontainer.json` references `workflow-orchestration-prebuild` (not the template name) — should be unaffected
- The new `AGENTS.local.md` will contain template placeholders — must be included in the replacement scope
- The overlay mechanism (checking out the prebuild repo) uses a hardcoded repo path — this is intentional and should **not** be placeholder-replaced

---

## 8. Relationship to F2 and F3

| Feature | Dependency on F1 | How F1 Enables It |
|-|-|-|
| **F2** (resolve open issues dispatch) | Soft dependency — F2 can work pre- or post-migration | Post-F1, the dynamic workflow and match clause live in the prebuild repo, making them available to all clones automatically |
| **F3** (generic event source / standalone service) | **Hard dependency** — F3 requires the self-hosted service to use the prebuild container as its runtime | F1 centralizes all orchestration code in the prebuild container, which becomes the runtime image for the standalone service. The dual execution mode (intra-workflow + standalone service) is designed into F1's architecture |

---

## 9. Success Criteria

- [ ] All orchestration runtime scripts live in the prebuild Docker image at `/opt/orchestration/`
- [ ] All orchestration config (agents, commands, prompt, opencode.json) lives in the prebuild repo and is overlaid at workflow time
- [ ] `AGENTS.md` is split: generic in prebuild repo, project-specific `AGENTS.local.md` in template
- [ ] Template `orchestrator-agent.yml` is a thin skeleton (~30 lines of logic)
- [ ] Consumer `devcontainer.json` image URL unchanged
- [ ] Existing template clones continue to work without changes
- [ ] New clones from the template work with the overlay mechanism
- [ ] Trace output from opencode processes is visible in workflow run console
- [ ] Both execution modes work: intra-workflow (`devcontainers/ci` `runCmd`) and manual devcontainer exec
- [ ] All validation passes in both repos (`./scripts/validate.ps1 -All`)
- [ ] The architecture supports the future standalone service model (F3) without further restructuring
