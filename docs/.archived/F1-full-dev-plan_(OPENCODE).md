# F1: Orchestration Migration to Prebuild Container — Full Development Plan

> **Status:** Planning  
> **Feature:** F1 — Move all orchestration-related code to the `intel-agency/workflow-orchestration-prebuild` prebuild container  
> **Last Updated:** 2026-03-27  
> **Related:** [new_features.md](new_features.md) § F1 | [F1-orchestration-migration-options.md](F1-orchestration-migration-options.md)

---

## 1. Overview

This document defines the comprehensive development plan for Feature F1: migrating all orchestration-related code from the template repository (`intel-agency/ai-new-workflow-app-template`) to a dedicated prebuild container repository (`intel-agency/workflow-orchestration-prebuild`).

### Goal

Achieve a **clean separation of concerns** where:

- **Template repos** contain ONLY application-level code and configuration
- **Prebuild container** contains ALL orchestration infrastructure (opencode server, agents, prompts, workflows, scripts)

This enables:
- Independent service model for orchestration
- Flexible execution contexts (workflow-based OR standalone service)
- Centralized maintenance of orchestration logic
- Cleaner, more modular codebase architecture

---

## 2. Strategic Direction

> **These are the user's strategic decisions and remarks that MUST drive all implementation choices.**

### 2.1 Complete Orchestration Logic Migration

> **ALL orchestration logic moves to prebuild container** — opencode server, orchestrator agent, prompt assembly, related workflows. The template repo should ONLY contain application-level code and configuration that references the prebuild container.

This is the foundational principle. Every file, script, and configuration related to orchestration belongs in the prebuild container. The template becomes purely a consumer of orchestration services.

### 2.2 Independent Service Model

> **The opencode server orchestration agent/logic will run as its own independent service** — invokable by GitHub App event-triggered webhooks.

The long-term vision is a self-hosted orchestration service that:
- Runs independently of any specific repository
- Accepts events via webhooks (from GitHub Apps or other sources)
- Executes orchestration logic in response to normalized event payloads
- Can be triggered from multiple contexts (workflows, manual invocation, external integrations)

### 2.3 Devcontainer-Based Execution for Template Clones

> **Running orchestration inside template clone repos** — resolved by running the `orchestrator-agent.yml` workflow INSIDE the devcontainer using `devcontainers/ci@v0.3` with the `runCmd` input.

The execution model for template clone repositories uses the `devcontainers/ci` action to:
1. Pull the prebuilt devcontainer image
2. Spin up the devcontainer
3. Execute orchestration commands inside the container via `runCmd`

**Example pattern (from devcontainers/ci Quick Start):**

```yaml
- name: Pre-build image and run make ci-build in dev container
  uses: devcontainers/ci@v0.3
  with:
    imageName: ghcr.io/example/example-devcontainer
    cacheFrom: ghcr.io/example/example-devcontainer
    push: always
    runCmd: make ci-build
```

**Reference implementation:** [`.github/workflows/.disabled/agent-runner.yml`](../.github/workflows/.disabled/agent-runner.yml) demonstrates this approach — it uses `devcontainers/ci@v0.3` with `runCmd` to execute the agent inside the devcontainer.

### 2.4 Full Containment and Isolation

> **This approach achieves full isolation requirements**, allowing the agent to run EITHER as:
> - A separate extra-workflow service (self-hosted Linux service), OR
> - An intra-workflow run like the current `orchestrator-agent.yml` approach

The architecture supports **dual execution modes**:

| Mode | Context | Trigger |
|------|---------|---------|
| **Workflow-based** | GitHub Actions workflow | `on:` triggers (issues, PRs, workflow_dispatch) |
| **Service-based** | Self-hosted Linux service | HTTP webhooks (GitHub App, external integrations) |

This flexibility means orchestration can be triggered by different events or manually from within the devcontainer without being tightly coupled to GitHub Actions.

### 2.5 Critical Issue: Trace Output stdout

> **Need to ensure all opencode process output and logging makes it up to the workflow run's console.**

When running inside the devcontainer via `devcontainers/ci`, stdout/stderr from the opencode process must be properly forwarded to the GitHub Actions workflow console for observability and debugging.

---

## 3. Architecture

### 3.1 Current State

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    TEMPLATE REPO (ai-new-workflow-app-template)             │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ APPLICATION-LEVEL (stays)                                           │   │
│  │  • .devcontainer/devcontainer.json (consumer config)                │   │
│  │  • .github/workflows/orchestrator-agent.yml                         │   │
│  │  • .github/workflows/validate.yml                                   │   │
│  │  • AGENTS.md (project-specific sections)                            │   │
│  │  • plan_docs/                                                       │   │
│  │  • local_ai_instruction_modules/                                    │   │
│  │  • Application code                                                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ ORCHESTRATION (currently mixed in — TO BE MOVED)                    │   │
│  │  • .opencode/agents/ (27 agents)                                    │   │
│  │  • .opencode/commands/ (20 commands)                                │   │
│  │  • opencode.json                                                    │   │
│  │  • scripts/start-opencode-server.sh                                 │   │
│  │  • scripts/assemble-orchestrator-prompt.sh                          │   │
│  │  • .github/workflows/prompts/orchestrator-agent-prompt.md           │   │
│  │  • models.json                                                      │   │
│  │  • Dockerfile / devcontainer build artifacts                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Target State

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    TEMPLATE REPO (ai-new-workflow-app-template)             │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ APPLICATION-LEVEL ONLY                                              │   │
│  │  • .devcontainer/devcontainer.json (image ref → prebuild)           │   │
│  │  • .github/workflows/orchestrator-agent.yml (skeleton)              │   │
│  │  • .github/workflows/validate.yml                                   │   │
│  │  • AGENTS.local.md (project-specific only)                          │   │
│  │  • .github/.labels.json                                             │   │
│  │  • plan_docs/                                                       │   │
│  │  • local_ai_instruction_modules/                                    │   │
│  │  • Application code                                                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ references
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              PREBUILD REPO (intel-agency/workflow-orchestration-prebuild)   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ DOCKER IMAGE (baked in)                                             │   │
│  │  • .NET SDK, Bun, uv, opencode CLI                                  │   │
│  │  • MCP servers (sequential-thinking, memory)                        │   │
│  │  • scripts/start-opencode-server.sh                                 │   │
│  │  • scripts/devcontainer-opencode.sh                                 │   │
│  │  • scripts/run-orchestrator.sh (entry point)                        │   │
│  │  • Runtime utilities                                                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ CONFIG (checked out at runtime)                                     │   │
│  │  • .opencode/agents/ (27 agents)                                    │   │
│  │  • .opencode/commands/ (20 commands)                                │   │
│  │  • opencode.json                                                    │   │
│  │  • models.json                                                      │   │
│  │  • prompts/orchestrator-agent-prompt.md                             │   │
│  │  • AGENTS.md (generic sections)                                     │   │
│  │  • .github/workflows/publish-docker.yml                             │   │
│  │  • .github/workflows/prebuild-devcontainer.yml                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 Migration Approach: Option C (Hybrid) — Recommended

**Option C** splits concerns by change frequency:

| Layer | Contents | Change Frequency | Storage |
|-------|----------|------------------|---------|
| **Runtime** | Scripts, CLIs, MCP server binaries, opencode bootstrapper | Rare | Baked into Docker image |
| **Config** | Agents, commands, prompt templates, opencode.json, models.json | Frequent | Checked out at workflow time |

**Workflow skeleton (target):**

```yaml
steps:
  - checkout  # this repo (plan_docs, AGENTS.local.md, devcontainer.json)
  
  - checkout  # prebuild repo → .orchestration/
    with:
      repository: intel-agency/workflow-orchestration-prebuild
      path: .orchestration
      
  - run: |
      # Overlay config from orchestration repo into workspace
      cp -r .orchestration/.opencode .opencode
      cp .orchestration/opencode.json opencode.json
      cp .orchestration/prompts/orchestrator-agent-prompt.md \
         .github/workflows/prompts/orchestrator-agent-prompt.md
         
  - uses: devcontainers/ci@v0.3
    with:
      imageName: ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer
      cacheFrom: ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer
      push: never
      runCmd: |
        bash /opt/orchestration/scripts/run-orchestrator.sh \
          --event-json "$EVENT_JSON" \
          --event-name "$EVENT_NAME"
```

---

## 4. Migration Scope

### 4.1 Files to Move → Prebuild Repo

#### Docker/Image Build Artifacts

| File (this template) | Destination in Prebuild Repo | Notes |
|---------------------|------------------------------|-------|
| `.github/.devcontainer/Dockerfile` | Root or `.devcontainer/Dockerfile` | Core image definition — .NET SDK, Bun, uv, opencode CLI |
| `.github/.devcontainer/devcontainer.json` | `.devcontainer/devcontainer.json` | Build-time devcontainer config (Features: node, python, gh CLI) |
| `.github/workflows/publish-docker.yml` | `.github/workflows/publish-docker.yml` | Builds & pushes Docker image to GHCR |
| `.github/workflows/prebuild-devcontainer.yml` | `.github/workflows/prebuild-devcontainer.yml` | Layers devcontainer Features on Docker image |

#### Runtime Scripts

| File (this template) | Destination in Prebuild Repo | Notes |
|---------------------|------------------------------|-------|
| `scripts/start-opencode-server.sh` | `scripts/start-opencode-server.sh` | opencode serve daemon bootstrapper |
| `scripts/resolve-image-tags.sh` | `scripts/resolve-image-tags.sh` | Image tag resolution helper |
| `scripts/install-dev-tools.ps1` | `scripts/install-dev-tools.ps1` | Dev tooling installer |
| `scripts/devcontainer-opencode.sh` | `scripts/devcontainer-opencode.sh` | Devcontainer CLI wrapper (up/start/prompt/stop/down) |
| `run_opencode_prompt.sh` | `run_opencode_prompt.sh` | opencode run entrypoint (gh auth + agent invocation) |

#### Tests

| File (this template) | Destination in Prebuild Repo | Notes |
|---------------------|------------------------------|-------|
| `test/test-devcontainer-build.sh` | `test/test-devcontainer-build.sh` | Devcontainer build test |
| `test/test-devcontainer-tools.sh` | `test/test-devcontainer-tools.sh` | Tool availability test |
| `test/test-image-tag-logic.sh` | `test/test-image-tag-logic.sh` | Image tag resolution test |

#### Agent Definitions and Config (Option C: checked out at runtime)

| File (this template) | Destination in Prebuild Repo | Notes |
|---------------------|------------------------------|-------|
| `.opencode/agents/*.md` | `.opencode/agents/*.md` | 27 specialist agents |
| `.opencode/commands/*.md` | `.opencode/commands/*.md` | 20 reusable command prompts |
| `.opencode/package.json` | `.opencode/package.json` | MCP server dependencies |
| `opencode.json` | `opencode.json` | Model configs, MCP server definitions |
| `models.json` | `models.json` | Model definitions |
| `.github/workflows/prompts/orchestrator-agent-prompt.md` | `prompts/orchestrator-agent-prompt.md` | Match clauses / state machine |

### 4.2 Files That Stay in Template

| File | Reason |
|------|--------|
| `.devcontainer/devcontainer.json` | Consumer config — references prebuild GHCR image; stays so clones get a working devcontainer |
| `.github/workflows/orchestrator-agent.yml` | Must live in the repo for GH Actions to trigger it; becomes a thin skeleton |
| `.github/workflows/validate.yml` | Project-level CI |
| `.github/.labels.json` | Project-specific label set |
| `AGENTS.local.md` | Project-specific agent instructions (created from AGENTS.md split) |
| `local_ai_instruction_modules/` | Project-specific local instruction overrides |
| `plan_docs/` | Seeded at clone time per project |
| `scripts/run-devcontainer-orchestrator.sh` | One-shot runner — may need path updates but stays as local helper |

### 4.3 AGENTS.md Split Strategy

`AGENTS.md` currently mixes generic orchestration instructions with project-specific content. It must be split:

#### New Structure

| File | Location | Contents |
|------|----------|----------|
| `AGENTS.md` | Prebuild repo (overlaid at runtime) | Generic sections — same in every clone |
| `AGENTS.local.md` | Template repo (stays) | Project-specific sections — placeholder-replaced at clone time |

#### Section Mapping

| AGENTS.md Section | Generic or Project | Goes To |
|-------------------|-------------------|---------|
| `<purpose>` | Generic | `AGENTS.md` (prebuild repo) |
| `<template_usage>` | Project | `AGENTS.local.md` (template) |
| `<tech_stack>` | Generic | `AGENTS.md` (prebuild repo) |
| `<repository_map>` | Project | `AGENTS.local.md` (template) |
| `<instruction_source>` | Generic | `AGENTS.md` (prebuild repo) |
| `<environment_setup>` | Project | `AGENTS.local.md` (template) |
| `<testing>` | Generic | `AGENTS.md` (prebuild repo) |
| `<coding_conventions>` | Project | `AGENTS.local.md` (template) |
| `<agent_specific_guardrails>` | Generic | `AGENTS.md` (prebuild repo) |
| `<agent_readiness>` | Generic | `AGENTS.md` (prebuild repo) |
| `<validation_before_handoff>` | Generic | `AGENTS.md` (prebuild repo) |
| `<tool_use_instructions>` | Generic | `AGENTS.md` (prebuild repo) |
| `<available_tools>` | Generic | `AGENTS.md` (prebuild repo) |
| `<mandatory_tool_protocols>` | Generic | `AGENTS.md` (prebuild repo) |

#### opencode.json Update

The instructions array in `opencode.json` becomes:

```json
"instructions": ["AGENTS.md", "AGENTS.local.md"]
```

opencode merges both files — generic base + project overlay.

---

## 5. Execution Approach: Devcontainer-Based Orchestration

### 5.1 The devcontainers/ci Pattern

The key insight is using `devcontainers/ci@v0.3` with the `runCmd` input to execute orchestration **inside** the devcontainer, where all the prebuild tooling is available.

**Reference:** [`.github/workflows/.disabled/agent-runner.yml`](../.github/workflows/.disabled/agent-runner.yml)

```yaml
name: Agent Runner

on:
  pull_request:
    types: [opened, synchronize]
  issues:
    types: [opened]

jobs:
  run-agent:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      pull-requests: write
      issues: write

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Save Event Payload
        run: |
          echo '${{ toJson(github.event) }}' > event_payload.json
          echo "Triggered by: ${{ github.event_name }}"

      - name: Execute Agent in DevContainer
        uses: devcontainers/ci@v0.3
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          subFolder: "."
          imageName: ghcr.io/${{ github.repository }}/devcontainer
          cacheFrom: ghcr.io/${{ github.repository }}/devcontainer
          push: never
          runCmd: |
            echo "Running Agent for trigger: ${{ github.event_name }}"
            opencode run \
              --trigger "${{ github.event_name }}" \
              --payload-file event_payload.json \
              --prompt "Act on this ${{ github.event_name }} event based on the payload data."
```

### 5.2 Target Workflow Pattern (Post-Migration)

The `orchestrator-agent.yml` workflow becomes a thin skeleton:

```yaml
name: Orchestrator Agent

on:
  issues:
    types: [labeled, opened, edited]
  issue_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
  workflow_dispatch:

jobs:
  orchestrate:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      pull-requests: write
      issues: write

    steps:
      - name: Checkout application repo
        uses: actions/checkout@v4

      - name: Checkout orchestration config
        uses: actions/checkout@v4
        with:
          repository: intel-agency/workflow-orchestration-prebuild
          path: .orchestration
          ref: main

      - name: Overlay orchestration config
        run: |
          cp -r .orchestration/.opencode .opencode
          cp .orchestration/opencode.json opencode.json
          cp .orchestration/AGENTS.md AGENTS.md
          mkdir -p .github/workflows/prompts
          cp .orchestration/prompts/orchestrator-agent-prompt.md \
             .github/workflows/prompts/orchestrator-agent-prompt.md

      - name: Save event payload
        run: |
          echo '${{ toJson(github.event) }}' > event_payload.json
          echo "EVENT_PAYLOAD_PATH=$(pwd)/event_payload.json" >> $GITHUB_ENV
          echo "EVENT_NAME=${{ github.event_name }}" >> $GITHUB_ENV

      - name: Execute orchestrator in devcontainer
        uses: devcontainers/ci@v0.3
        env:
          GITHUB_TOKEN: ${{ secrets.GH_ORCHESTRATION_AGENT_TOKEN }}
          ZHIPU_API_KEY: ${{ secrets.ZHIPU_API_KEY }}
          KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY: ${{ secrets.KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY }}
        with:
          subFolder: "."
          imageName: ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer
          cacheFrom: ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer
          push: never
          runCmd: |
            bash /opt/orchestration/scripts/run-orchestrator.sh \
              --event-json "$EVENT_PAYLOAD_PATH" \
              --event-name "$EVENT_NAME"
```

### 5.3 Dual Execution Model

The architecture supports both execution modes:

#### Mode 1: Workflow-Based (Current Transition Path)

```
GitHub Event → orchestrator-agent.yml → devcontainers/ci → Prebuild Image → opencode run
```

- Triggered by GitHub Actions `on:` triggers
- Runs inside GitHub-hosted runner
- Uses prebuild image via GHCR

#### Mode 2: Service-Based (Long-Term Target)

```
GitHub App Webhook → Self-hosted Service → Prebuild Image → opencode run
```

- Runs on self-hosted Linux server
- Accepts webhooks from GitHub App or other sources
- Same prebuild image, same orchestration logic
- Independent of GitHub Actions runtime

---

## 6. Detailed Execution Plan

### Phase 1: Audit and Preparation

| Step | Description | Deliverable | Validation |
|------|-------------|-------------|------------|
| 1.1 | Audit prebuild repo state | Inventory of existing files in `intel-agency/workflow-orchestration-prebuild` | Document current structure |
| 1.2 | Identify conflicts/overlaps | Map template files to prebuild repo destinations | Conflict resolution plan |
| 1.3 | Verify image URL stability | Confirm `ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest` is correct | Test image pull |
| 1.4 | Audit secrets/variables | Verify prebuild repo has `VERSION_PREFIX` variable and required secrets | GHCR push capability confirmed |

### Phase 2: AGENTS.md Split

| Step | Description | Deliverable | Validation |
|------|-------------|-------------|------------|
| 2.1 | Create `AGENTS.local.md` in template | Project-specific sections extracted | File contains only project-specific content |
| 2.2 | Create `AGENTS.md` for prebuild | Generic sections extracted | File contains only generic content |
| 2.3 | Update `opencode.json` | `"instructions": ["AGENTS.md", "AGENTS.local.md"]` | Local test confirms both files are loaded |

### Phase 3: Copy Build Artifacts to Prebuild

| Step | Description | Deliverable | Validation |
|------|-------------|-------------|------------|
| 3.1 | Copy Dockerfile and devcontainer.json | Build-side devcontainer config in prebuild repo | Image builds successfully |
| 3.2 | Copy publish-docker.yml | Image publishing workflow in prebuild repo | Workflow runs, image pushes to GHCR |
| 3.3 | Copy prebuild-devcontainer.yml | Devcontainer prebuild workflow in prebuild repo | Workflow runs, devcontainer image pushes |
| 3.4 | Copy runtime scripts | `scripts/` directory populated in prebuild repo | Scripts are executable, paths correct |

### Phase 4: Copy Config Files to Prebuild

| Step | Description | Deliverable | Validation |
|------|-------------|-------------|------------|
| 4.1 | Copy `.opencode/agents/` | 27 agent definitions in prebuild repo | All agents present |
| 4.2 | Copy `.opencode/commands/` | 20 command prompts in prebuild repo | All commands present |
| 4.3 | Copy `opencode.json` and `models.json` | Config files in prebuild repo | Model references resolve |
| 4.4 | Copy prompt template | `prompts/orchestrator-agent-prompt.md` in prebuild repo | Prompt loads correctly |

### Phase 5: Copy Tests to Prebuild

| Step | Description | Deliverable | Validation |
|------|-------------|-------------|------------|
| 5.1 | Copy devcontainer tests | `test/test-devcontainer-build.sh`, `test/test-devcontainer-tools.sh` | Tests pass in prebuild repo |
| 5.2 | Copy image tag test | `test/test-image-tag-logic.sh` | Test passes |
| 5.3 | Update test paths | Adjust any hardcoded paths for new repo structure | All tests pass |

### Phase 6: Verify Prebuild Pipeline

| Step | Description | Deliverable | Validation |
|------|-------------|-------------|------------|
| 6.1 | Push to prebuild repo | All files committed | CI runs |
| 6.2 | Verify publish-docker workflow | Image builds and pushes to GHCR | Image available at expected tag |
| 6.3 | Verify prebuild-devcontainer workflow | Devcontainer image builds | Image available for consumption |
| 6.4 | Test image pull | Pull from clean environment | Image loads correctly |

### Phase 7: Update Template Repo

| Step | Description | Deliverable | Validation |
|------|-------------|-------------|------------|
| 7.1 | Delete moved files from template | Remove Dockerfile, scripts, agents, etc. | Template repo cleaned |
| 7.2 | Update `orchestrator-agent.yml` | Convert to skeleton with dual checkout + devcontainers/ci | Workflow runs successfully |
| 7.3 | Update `validate.yml` | Remove or update devcontainer build test job | Validation passes |
| 7.4 | Update AGENTS.md references | Remove references to moved files | Documentation accurate |

### Phase 8: End-to-End Verification

| Step | Description | Deliverable | Validation |
|------|-------------|-------------|------------|
| 8.1 | Test template clone | Create test repo from template | Clone succeeds |
| 8.2 | Verify devcontainer | Open in devcontainer, confirm image pulls | Devcontainer works |
| 8.3 | Verify orchestrator | Trigger orchestrator via issue label | Orchestration runs successfully |
| 8.4 | Verify stdout forwarding | Confirm opencode output appears in workflow logs | Full observability |
| 8.5 | Verify backward compat | Existing clones still work | No breaking changes |

---

## 7. Requirements and Constraints

### 7.1 Image URL Stability

| Requirement | Details |
|-------------|---------|
| Consumer image URL must not change | `ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest` |
| All existing clones must continue to work | No breaking changes to image location |
| Versioned tags for pinning | Prebuild repo must publish both `main-latest` and versioned tags (e.g., `main-1.0.123`) |

### 7.2 Script Path Dependencies

| Requirement | Details |
|-------------|---------|
| Known paths for runtime scripts | Scripts baked into image at `/opt/orchestration/scripts/` |
| Consumer devcontainer compatibility | `postStartCommand` in consumer `devcontainer.json` must work with new paths |
| Backward-compatible symlinks | If needed, create symlinks for old paths during transition |

### 7.3 Authentication

| Requirement | Details |
|-------------|---------|
| Prebuild repo secrets | Must have `VERSION_PREFIX` variable for tag versioning |
| GHCR push permissions | Prebuild repo workflow must have write access to packages |
| Token alignment | `GH_ORCHESTRATION_AGENT_TOKEN` must work from both execution contexts |

### 7.4 Template Placeholder Replacement

| Requirement | Details |
|-------------|---------|
| Verify replacement logic | `create-repo-with-plan-docs.ps1` currently replaces `ai-new-workflow-app-template` |
| Prebuild image URL unaffected | Consumer `devcontainer.json` references `workflow-orchestration-prebuild` — should be unaffected |
| Test placeholder replacement | Create test clone and verify all placeholders resolved correctly |

### 7.5 Backward Compatibility

| Requirement | Details |
|-------------|---------|
| Existing clones continue to work | Must not break repos already created from template |
| Graceful migration path | Document how existing clones can update if needed |
| No forced updates | Migration should be transparent to existing users |

---

## 8. Known Issues and Risks

### 8.1 Prebuild Repo State

| Issue | Impact | Mitigation |
|-------|--------|------------|
| Unknown current state of prebuild repo | May have conflicting files or outdated structure | Phase 1 audit to inventory and resolve conflicts |
| Missing secrets/variables in prebuild repo | CI may fail | Verify and configure before Phase 6 |

### 8.2 stdout Trace Forwarding

| Issue | Impact | Mitigation |
|-------|--------|------------|
| opencode output may not reach workflow console | Loss of observability, harder debugging | Test thoroughly in Phase 8.4; may need `tee` or explicit logging |

### 8.3 Script Path Changes

| Issue | Impact | Mitigation |
|-------|--------|------------|
| `start-opencode-server.sh` path changes | Consumer `devcontainer.json` `postStartCommand` may break | Update path to absolute location or create symlink |
| Relative paths in scripts | May break when run from different context | Audit and convert to absolute paths where needed |

### 8.4 Secret Alignment

| Issue | Impact | Mitigation |
|-------|--------|------------|
| Different secret names between repos | Auth failures | Align secret names or use mapping in workflows |
| Token scope differences | Permission errors | Verify `GH_ORCHESTRATION_AGENT_TOKEN` has required scopes in both contexts |

### 8.5 Test Migration

| Issue | Impact | Mitigation |
|-------|--------|------------|
| Tests may have hardcoded paths | Tests fail after migration | Update paths in Phase 5.3 |
| Tests depend on template-specific files | Tests fail in prebuild context | Identify and isolate template-specific test logic |

### 8.6 AGENTS.md Merge Complexity

| Issue | Impact | Mitigation |
|-------|--------|------------|
| opencode may not merge files as expected | Agents miss instructions | Test thoroughly in Phase 2.3 |
| Section ordering may matter | Instructions applied in wrong order | Document expected merge behavior |

---

## 9. Success Criteria

### 9.1 Functional Criteria

| # | Criterion | Validation Method |
|---|-----------|-------------------|
| 1 | Template repo contains ONLY application-level code | File audit confirms no orchestration files |
| 2 | Prebuild repo contains ALL orchestration infrastructure | File audit confirms complete migration |
| 3 | Consumer devcontainer pulls prebuild image successfully | Fresh clone opens in devcontainer |
| 4 | Orchestrator runs inside devcontainer via `devcontainers/ci` | Workflow execution succeeds |
| 5 | All opencode output appears in workflow console | Manual review of workflow logs |
| 6 | AGENTS.md + AGENTS.local.md merge correctly | Agent receives both instruction sets |
| 7 | Existing clones continue to work | Test existing repo still functions |

### 9.2 Non-Functional Criteria

| # | Criterion | Validation Method |
|---|-----------|-------------------|
| 1 | Image pull time < 2 minutes (cached) | Measure from workflow logs |
| 2 | No breaking changes to existing clones | Test suite on existing repos |
| 3 | Workflow execution time not significantly increased | Compare before/after timing |
| 4 | Documentation is accurate and complete | Manual review |

### 9.3 Definition of Done

F1 is **DONE** when:

1. ✅ All files listed in § 4.1 have been moved to `intel-agency/workflow-orchestration-prebuild`
2. ✅ All files listed in § 4.2 remain in the template repo
3. ✅ AGENTS.md has been split per § 4.3
4. ✅ Prebuild repo CI publishes images to GHCR at the expected URL
5. ✅ Template repo `orchestrator-agent.yml` uses `devcontainers/ci@v0.3` pattern
6. ✅ New clones from template work out of the box
7. ✅ Existing clones continue to work without modification
8. ✅ All tests pass in both repos
9. ✅ Documentation (AGENTS.md, new_features.md) is updated
10. ✅ Success criteria in § 9.1 and § 9.2 are met

---

## 10. References

### Related Documents

| Document | Purpose |
|----------|---------|
| [new_features.md](new_features.md) § F1 | Original feature definition and initial analysis |
| [F1-orchestration-migration-options.md](F1-orchestration-migration-options.md) | Detailed options analysis (A/B/C), AGENTS.md split strategy |
| [AGENTS.md](../AGENTS.md) | Current agent instructions (to be split) |

### Reference Implementations

| File | Purpose |
|------|---------|
| [`.github/workflows/.disabled/agent-runner.yml`](../.github/workflows/.disabled/agent-runner.yml) | Proof of concept for `devcontainers/ci@v0.3` with `runCmd` |
| [`.devcontainer/devcontainer.json`](../.devcontainer/devcontainer.json) | Consumer devcontainer config (references prebuild image) |

### External Resources

| Resource | URL |
|----------|-----|
| devcontainers/ci Quick Start | https://github.com/devcontainers/ci#quick-start |
| Prebuild Repo | https://github.com/intel-agency/workflow-orchestration-prebuild |
| Template Repo | https://github.com/intel-agency/ai-new-workflow-app-template |

---

## Appendix A: File Classification Summary

### Generic (Same in Every Clone) → Prebuild Repo

- `.opencode/agents/*.md` (27 agents)
- `.opencode/commands/*.md` (20 commands)
- `.opencode/package.json` + `node_modules/`
- `opencode.json`
- `models.json`
- `scripts/devcontainer-opencode.sh`
- `scripts/start-opencode-server.sh`
- `scripts/assemble-orchestrator-prompt.sh`
- `run_opencode_prompt.sh`
- `scripts/resolve-image-tags.sh`
- `.github/workflows/prompts/orchestrator-agent-prompt.md`

### Project-Specific (Must Stay in Template)

- `AGENTS.local.md` (project sections extracted from AGENTS.md)
- `.devcontainer/devcontainer.json`
- `.github/workflows/orchestrator-agent.yml`
- `.github/workflows/validate.yml`
- `.github/.labels.json`
- `plan_docs/`
- `local_ai_instruction_modules/`

---

## Appendix B: Resulting Template Structure (Post-Migration)

```
template-repo/
├── .devcontainer/
│   └── devcontainer.json         # Consumer config (image ref → prebuild)
├── .github/
│   ├── .labels.json              # Project labels
│   └── workflows/
│       ├── orchestrator-agent.yml  # Skeleton: checkout × 2 + exec entry point
│       └── validate.yml            # Project CI
├── AGENTS.local.md               # Project-specific agent instructions
├── local_ai_instruction_modules/ # Project-specific instruction overrides
├── plan_docs/                    # Seeded at clone time
└── (application code)
```

Everything else lives in `intel-agency/workflow-orchestration-prebuild`.
