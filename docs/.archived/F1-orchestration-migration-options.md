# F1 Addendum: Orchestration File Migration Options

> Companion to [new_features.md](new_features.md) § F1.
> Analyzes options for moving agent definitions, AGENTS.md, prompt, and orchestration
> functionality into the prebuild repo alongside the Dockerfile/image artifacts.

---

## File Classification: Generic vs. Project-Specific

### Generic (same in every clone — candidates for migration)

| File(s) | Purpose |
|-|-|
| `.opencode/agents/*.md` (27 agents) | Specialist agent pool (orchestrator, developer, code-reviewer, etc.) |
| `.opencode/commands/*.md` (20 commands) | Reusable command prompts (orchestrate-dynamic-workflow, grind-pr-reviews, etc.) |
| `.opencode/package.json` + `node_modules/` | MCP server deps (sequential-thinking, memory) |
| `opencode.json` | Model configs (GLM-5, GPT-5.4, Gemini 3), MCP server definitions |
| `scripts/devcontainer-opencode.sh` | Devcontainer CLI wrapper (up/start/prompt/stop/down) |
| `scripts/start-opencode-server.sh` | opencode serve daemon bootstrapper |
| `scripts/assemble-orchestrator-prompt.sh` | Prompt assembly — injects event data into template |
| `run_opencode_prompt.sh` | opencode run entrypoint (gh auth + agent invocation) |
| `scripts/resolve-image-tags.sh` | Image tag resolution helpers |
| `.github/workflows/prompts/orchestrator-agent-prompt.md` | Match clauses / state machine — label-driven orchestration logic is the same in every clone |
| `models.json` | Model definitions |

### Project-Specific (must stay in template)

| File | Reason |
|-|-|
| `AGENTS.md` | Contains `<repository_map>`, `<coding_conventions>`, `<template_usage>` — references this repo by name and describes its specific structure |
| `.devcontainer/devcontainer.json` | Consumer config — project-specific port forwards, extensions, env vars |
| `.github/workflows/orchestrator-agent.yml` | Must live in the repo for GH Actions to trigger it |
| `.github/workflows/validate.yml` | Project-level CI |
| `.github/.labels.json` | Project-specific label set |
| `plan_docs/` | Seeded at clone time per project |
| `local_ai_instruction_modules/` | Project-specific local instruction overrides |

---

## Migration Options

### Option A: Bake Everything into the Docker Image

Move all generic files into the prebuild Dockerfile via `COPY`. They land at a known absolute path (e.g., `/opt/orchestration/`).

```dockerfile
# In prebuild Dockerfile
COPY .opencode/agents/    /opt/orchestration/.opencode/agents/
COPY .opencode/commands/  /opt/orchestration/.opencode/commands/
COPY opencode.json        /opt/orchestration/opencode.json
COPY scripts/             /opt/orchestration/scripts/
COPY prompts/             /opt/orchestration/prompts/
```

The template's workflow skeleton becomes:

```yaml
steps:
  - checkout   # this repo only
  - login to GHCR
  - pull prebuild image
  - devcontainer up
  # Everything below runs INSIDE the container using baked-in scripts:
  - devcontainer exec -- /opt/orchestration/scripts/run-orchestrator.sh \
      --event-json "$EVENT_JSON" --event-name "$EVENT_NAME" ...
```

| Pros | Cons |
|-|-|
| Single source of truth for orchestration code | Image rebuild required for any agent/prompt change |
| Template becomes very thin | `opencode` expects `.opencode/` in workspace root — need symlinks or `--config` flag |
| No duplication across clones | Debugging harder — can't just edit a file in the clone and re-run |
| No extra checkout step | Slower iteration cycle (change → rebuild image → test) |

### Option B: Clone/Checkout at Workflow Runtime

Move generic files to the prebuild **repo** (not image). The workflow checks out both repos and overlays:

```yaml
steps:
  - uses: actions/checkout@...  # this repo (application code)
  - uses: actions/checkout@...  # prebuild repo → .orchestration/
    with:
      repository: intel-agency/workflow-orchestration-prebuild
      path: .orchestration
  - run: |
      # Overlay orchestration config into workspace
      ln -s "$(pwd)/.orchestration/.opencode" .opencode
      ln -s "$(pwd)/.orchestration/opencode.json" opencode.json
      cp .orchestration/prompts/orchestrator-agent-prompt.md \
         .github/workflows/prompts/orchestrator-agent-prompt.md
      bash .orchestration/scripts/devcontainer-opencode.sh up
      bash .orchestration/scripts/devcontainer-opencode.sh prompt -f "$PROMPT_PATH"
```

| Pros | Cons |
|-|-|
| Changes to agents/prompts take effect immediately (no image rebuild) | Adds a checkout step + symlink/copy setup |
| Clear separation: orchestration repo vs. application repo | Symlink management can be fragile across devcontainer boundaries |
| Easy to test changes by pointing checkout to a feature branch | Requires prebuild repo to be accessible (read permission) |
| Version pinning via checkout ref/tag | Slightly longer workflow startup |

### Option C: Hybrid — Runtime in Image, Config Overlaid at Checkout (Recommended)

Split the concern by change frequency:

- **Runtime** (scripts, opencode CLI, MCP server binaries, server bootstrapper) → baked into Docker image
- **Config** (agents, commands, prompt template, opencode.json, models.json) → lives in prebuild repo, checked out at workflow time

```yaml
steps:
  - checkout  # this repo (plan_docs, AGENTS.local.md, devcontainer.json)
  - checkout  # prebuild repo → .orchestration/ (agents, commands, prompt, opencode.json)
    with:
      repository: intel-agency/workflow-orchestration-prebuild
      path: .orchestration
  - run: |
      # Overlay config from orchestration repo into workspace
      cp -r .orchestration/.opencode .opencode
      cp .orchestration/opencode.json opencode.json
      cp .orchestration/prompts/orchestrator-agent-prompt.md \
         .github/workflows/prompts/orchestrator-agent-prompt.md
  - devcontainer up   # uses image with baked-in runtime scripts
  - devcontainer exec -- bash /opt/orchestration/scripts/run-orchestrator.sh ...
```

| Pros | Cons |
|-|-|
| Fast iteration on agents/prompts (no image rebuild) | Two checkouts + copy step |
| Runtime changes are rare → image rebuilds are rare | Slightly more complex workflow setup |
| Clean separation of "what changes often" vs. "what's stable" | Need to keep image scripts and repo config in sync |
| Version pinning for both layers independently | |

---

## The AGENTS.md Split

Regardless of which option is chosen, `AGENTS.md` must be split because it mixes generic orchestration instructions with project-specific content.

### Current state

`opencode.json` references: `"instructions": ["AGENTS.md"]`

`AGENTS.md` contains both:
- **Generic sections** (same in every clone): `<purpose>`, `<tech_stack>`, `<agent_specific_guardrails>`, `<tool_use_instructions>`, `<available_tools>`, `<testing>`, `<agent_readiness>`, `<validation_before_handoff>`
- **Project-specific sections** (vary per clone): `<template_usage>`, `<repository_map>`, `<coding_conventions>`, `<environment_setup>`

### Proposed split

1. **`AGENTS.md`** (generic) → moves to prebuild repo, overlaid into workspace at runtime
   - Contains: `<purpose>`, `<tech_stack>`, `<agent_specific_guardrails>`, `<tool_use_instructions>`, `<available_tools>`, `<testing>`, `<agent_readiness>`, `<validation_before_handoff>`

2. **`AGENTS.local.md`** (project-specific) → stays in template
   - Contains: `<template_usage>`, `<repository_map>`, `<coding_conventions>`, `<environment_setup>`
   - Placeholder-replaced at clone time by `create-repo-with-plan-docs.ps1`

3. **`opencode.json`** instructions array becomes:
   ```json
   "instructions": ["AGENTS.md", "AGENTS.local.md"]
   ```
   opencode merges both files — generic base + project overlay.

### Section mapping

| AGENTS.md Section | Generic or Project | Goes To |
|-|-|-|
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

---

## Recommendation

**Option C (Hybrid)** is the strongest choice:

1. **Runtime** baked into Docker image — scripts, CLIs, MCP server binaries change rarely; when they do, a single image rebuild propagates to all clones.
2. **Config** checked out at workflow time — agent definitions, prompt template, model configs, and command prompts iterate frequently and take effect immediately without image rebuilds.
3. **AGENTS.md split** into generic (`AGENTS.md` in prebuild repo) + project-specific (`AGENTS.local.md` in template) — clean separation with `opencode.json` merging both.
4. **Workflow skeleton** shrinks to ~30 lines: checkout app repo, checkout orchestration repo, overlay config, GHCR login, devcontainer up, exec single entry point.

### Resulting template structure (post-migration)

```
template-repo/
├── .devcontainer/devcontainer.json     # consumer config (image ref, env vars, ports)
├── .github/
│   ├── .labels.json                    # project labels
│   └── workflows/
│       ├── orchestrator-agent.yml      # skeleton: checkout × 2 + exec entry point
│       └── validate.yml                # project CI
├── AGENTS.local.md                     # project-specific agent instructions
├── local_ai_instruction_modules/       # project-specific instruction overrides
├── plan_docs/                          # seeded at clone time
└── (application code)
```

Everything else lives in `intel-agency/workflow-orchestration-prebuild`.
