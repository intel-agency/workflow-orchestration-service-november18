# New Features

To plan and implment...

## **F1:** Move all server/opencode/orchestraton-related/non-template clone-related code to the `intel-agency/workflow-orchestration-prebuild` container

The child tremplates can just reference and use the prebuild package without worrying about the server related code. This will also make the codebase cleaner and more modular, separating the disparate converns cleanly and totally. All the funciotrnality and file3s wil be moved into the lowedt layre, the Docker container so that higher layers have access, i.e. the devonctainer layer on top. Then functionality that used to use all the code in the existing template repo can just exec into the devcontainer and use the prebuild container to run the orchestration process, without needing to worry about the underlying code or dependencies. This will also make it easier to maintain and update the orchestration code, as it will be centralized in one place rather than being scattered across multiple templates.

**IMPORTANT:** The other requirement I'd like to add explore is transitioning the devcontainer opencode server orchestraiton agent to the standalone long-running instance that is not contained i any applicaitn's repo, not in the cloned instances. So the use case is that it runs in a devcotnaineer (on top of a docker container) that runs as a service at a know address. Then other repos/apps woudl call devcontainer prompt with the server's address, and then once running in the server, the agent would have to git clone a copy of the repo to work on it in that prompt attach instance. So in this approach the event triggers would trigger in the repo, which a orchestration client workflow would be respsonsible for calling the server with run attach and a prompt (i.e. the devcontainer_opencode prompt command). The other approach would be having a GH app with event triggers that trigger webhooks to the server with a payload, which the webhook listewner in the server then call devontainer_opencode prompt and attaches to the server. Actaully this 2nd option is probably better as it fully decouples the orchestration process from the GH workflow execution environment, and allows for more flexible invocation of the orchestration process, as it can be triggered by different events or manually from within the devcontainer, without being tightly coupled to the GitHub Actions workflow execution environment.

**See also:** [F1-orchestration-migration-options.md](F1-orchestration-migration-options.md) — Options analysis for moving agent files, AGENTS.md, prompt, and orchestration config into the prebuild repo (Options A/B/C, AGENTS.md split strategy, recommendation).

**Full Dev Plan:** [F1-feature-full-dev-plan.md](F1-feature-full-dev-plan.md) — Detailed development plan incorporating all remarks, migration strategy (Option C hybrid), execution phases, file migration plan, risks, and success criteria.

**REMARKS:** All logic related to the orchestration process, including the opencode server, orchestrator agent, prompt assembly, and related workflows should be moved to the prebuild container. The template repo should only contain application-level code and configuration that references the prebuild container for orchestration functionality. This is because the opencode server orchestration agent/logic will run in its opwn service which run sindependetly and can be invoked e.g. by GH app event-triggered webhooks

1. The issues raised below about how to run the orchestration inside the template clone repose can be resolved by entering and running the orchestration-agent.yml workflow inside of the devcontainer. Once inside the running devcontainer, all the calls can be made similar to before.
- See e.g. the "Both at once" section of the Quick Start section of the devcontainer repo README <https://github.com/devcontainers/ci#quick-start>, this uses the `runCmd` input of the `devcontainers/ci@v0.3`:

Both at once:

```
- name: Pre-build image and run make ci-build in dev container
  uses: devcontainers/ci@v0.3
  with:
    imageName: ghcr.io/example/example-devcontainer
    cacheFrom: ghcr.io/example/example-devcontainer
    push: always
    runCmd: make ci-build
```

- Also see e.g. [.github/workflows/.disabled/agent-runner.yml](../.github/workflows/.disabled/agent-runner.yml) which also demonstrates this approach.

2. The achieves the full containment/isolation requirements, allowing the agent to be run as separate extra-workflow run service (self-hosted linux service), as well as run like the more normal intra-orchestration-agent.yml workflow run that we have now. This also allows for more flexible invocation of the orchestration process, as it can be triggered by different events or manually from within the devcontainer, without being tightly coupled to the GitHub Actions workflow execution environment.

3. Issues to watch out for:
  - trace output stdout: Need to make sure all opencode process output and logging makes it up to the workflow run's console.


### Development Analysis

#### Architecture

The prebuild repo (`intel-agency/workflow-orchestration-prebuild`) already exists and the consumer `devcontainer.json` already references its image (`ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest`). The work is to move the remaining build-side artifacts out of this template repo and into that prebuild repo so the template is purely application-level content.

#### Files to Move → Prebuild Repo

| File / Dir (this template) | Destination in prebuild repo | Notes |
|-|-|-|
| `.github/.devcontainer/Dockerfile` | Root or `.devcontainer/Dockerfile` | Core image definition — .NET SDK, Bun, uv, opencode CLI |
| `.github/.devcontainer/devcontainer.json` | `.devcontainer/devcontainer.json` | Build-time devcontainer config (Features: node, python, gh CLI) |
| `.github/workflows/publish-docker.yml` | `.github/workflows/publish-docker.yml` | Builds & pushes Docker image to GHCR |
| `.github/workflows/prebuild-devcontainer.yml` | `.github/workflows/prebuild-devcontainer.yml` | Layers devcontainer Features on Docker image |
| `scripts/start-opencode-server.sh` | `scripts/start-opencode-server.sh` | opencode serve daemon bootstrapper |
| `scripts/resolve-image-tags.sh` | `scripts/resolve-image-tags.sh` | Image tag resolution helper |
| `scripts/install-dev-tools.ps1` | `scripts/install-dev-tools.ps1` | Dev tooling installer |
| `test/test-devcontainer-build.sh` | `test/test-devcontainer-build.sh` | Devcontainer build test |
| `test/test-devcontainer-tools.sh` | `test/test-devcontainer-tools.sh` | Tool availability test |

#### Files That Stay in Template

| File | Reason |
|-|-|
| `.devcontainer/devcontainer.json` | Consumer config — references prebuild GHCR image; stays so clones get a working devcontainer |
| `.github/workflows/orchestrator-agent.yml` | Application-level workflow — uses the prebuild image but is project-specific |
| `.github/workflows/prompts/orchestrator-agent-prompt.md` | Project-specific orchestrator prompt |
| `.github/workflows/validate.yml` | Project-level CI |
| `.opencode/` | Agent definitions — project-specific |
| `scripts/assemble-orchestrator-prompt.sh` | Prompt assembly — project-specific |
| `scripts/run-devcontainer-orchestrator.sh` | One-shot runner — can stay but may need path updates |

#### Plan / Execution Order

1. **Clone prebuild repo**, verify its current state (it may already have a Dockerfile and publish workflow).
2. **Copy build artifacts** from this template into the prebuild repo (files listed above).
3. **Update prebuild workflows** — ensure `publish-docker.yml` and `prebuild-devcontainer.yml` build and push correctly from the new repo context.
4. **Run prebuild CI** — push to prebuild repo, verify the image publishes to GHCR at the same tag path (`ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest`).
5. **Delete moved files** from this template repo.
6. **Update `validate.yml`** — remove or update the `test-devcontainer-build` job (already disabled).
7. **Update AGENTS.md** — remove references to `.github/.devcontainer/Dockerfile` and publish/prebuild workflows.
8. **Verify end-to-end** — create a test clone from the template, confirm devcontainer pulls prebuild image and orchestrator runs.

#### Requirements

- Consumer `devcontainer.json` image URL must not change (or all existing clones break).
- `start-opencode-server.sh` must be available inside the prebuild container at a known path.
- The prebuild repo must publish both `main-latest` (stable) and versioned tags for pinning.
- Template placeholder replacement in `create-repo-with-plan-docs.ps1` must be verified — it currently replaces `ai-new-workflow-app-template` in file contents; the consumer `devcontainer.json` image URL references `workflow-orchestration-prebuild` so it should be unaffected, but this needs confirmation.

#### Immediate Issues

1. **Unknown state of prebuild repo** — need to audit `intel-agency/workflow-orchestration-prebuild` to see what's already there and what overlaps.
2. **`start-opencode-server.sh` path dependency** — the consumer `devcontainer.json` `postStartCommand` references `bash ./scripts/start-opencode-server.sh` relative to the workspace root. If this script moves into the Docker image, the path changes. Options: (a) bake it into the image and change `postStartCommand` to call the absolute path, or (b) keep a thin wrapper in the template that delegates to the image's copy.
3. **`test-image-tag-logic.sh`** — test file that validates image tag resolution; needs to move with the publish workflow or be duplicated.
4. **Secret/variable alignment** — prebuild repo needs `VERSION_PREFIX` variable and any required secrets for GHCR push.

---

## **F2:** Add a dispatch message case to trigger the orchestration process to find and begin resolving existing open issues with specific labels

Can work them in prioirty order, if > 1 openiussue w/ a target label, then we can pick the one with the oldest creation date to work on first. This will help us to resolve the existing open issues in a more systematic and efficient way, rather than just randomly picking one to work on. It will also help us to ensure that we are addressing the most urgent and important issues first, rather than just working on whatever happens to be at the top of the list.

### Development Analysis

#### Architecture

A new match clause in `orchestrator-agent-prompt.md` would handle a new label (e.g., `orchestration:resolve-open-issues`) or a dispatch body keyword. When matched, the orchestrator queries open issues with target labels, sorts by priority/date, and orchestrates each one sequentially.

**REMARKS**: Let's have it pick the highest priority single issue (or *n* issues) and have it resolve that one, then post another dispatch message or label, i.e. `open-issue-resolved`, so then in another match case we can have logic about what to do after one issue is resolved, i.e. pick the next one to work on, or if no more issues remain, post a summary comment and end. This implies a loop. Arguments/parameter object to the dispatch issue can specify *int count*, *bool continueLoop*, or enum postResolutionAction { Stop, Continue, }.

#### Design Options

| Option | Trigger Mechanism | Pros | Cons |
|-|-|-|-|
| A. New label clause | `orchestration:resolve-open-issues` label on a control issue | Consistent with existing label-driven model | Needs a control issue to exist |
| B. Dispatch body keyword | `orchestration:dispatch` label, body: `$workflow_name = resolve-open-issues { $target_labels = "bug,needs-fix" }` | Reuses existing dispatch mechanism | More complex body parsing |
| C. Scheduled/cron trigger | `on: schedule` in workflow YAML | Fully automatic | Adds a new trigger type to `orchestrator-agent.yml`, harder to debug |

**Recommended: Option B** — Reuse the existing `orchestration:dispatch` mechanism. Create a new dynamic workflow `resolve-open-issues` that accepts `$target_labels` as input.

#### New Components

1. **Dynamic workflow: `resolve-open-issues.md`** (in `nam20485/agent-instructions`)
   - Input: `$target_labels` (comma-separated label names to query)
   - Steps:
     1. Query open issues with matching labels, sorted by creation date (oldest first)
     2. For each issue (in order):
        - Read issue body and comments for context
        - Delegate to `perform-task` or `implement-story` assignment to resolve
        - Post progress update on the issue
        - If resolved, close the issue; if blocked, label with `needs-triage` and move on
     3. Report summary of what was resolved vs. what remains

2. **Helper function: `find_open_issues_by_labels(labels, sort_by?)`** in orchestrator prompt
   - Queries `gh issue list --label <label> --state open --sort created --json number,title,labels,createdAt`
   - Returns sorted array of issue metadata

3. **New match clause** (if Option A chosen): Add to orchestrator prompt after existing dispatch clause

#### Plan / Execution Order

1. **Design the `resolve-open-issues` dynamic workflow** — define inputs, steps, acceptance criteria per the dynamic-workflow-syntax spec.
2. **Add workflow to agent-instructions repo** — create `ai_instruction_modules/ai-workflow-assignments/dynamic-workflows/resolve-open-issues.md`.
3. **Update dynamic workflows index** — add entry to `ai-dynamic-workflows.md` in both `agent-instructions` and `workflow-launch2` local mirrors.
4. **Add helper function** to orchestrator prompt (if needed) — `find_open_issues_by_labels()`.
5. **Test via dispatch** — create a dispatch issue with body referencing `resolve-open-issues` and verify the orchestrator picks it up and processes issues correctly.
6. **Add to labels JSON** — if any new labels are needed, add to `.github/.labels.json`.

#### Requirements

- Must handle the case where zero open issues match the target labels (no-op with a status message).
- Must process issues sequentially, not in parallel, to avoid conflicting changes.
- Must respect rate limits — each issue resolution may trigger multiple API calls.
- Must not re-resolve already-in-progress issues (check for `in-progress` or similar labels).
- Priority ordering: issues with `priority:critical` > `priority:high` > `priority:medium` > `priority:low` > no priority label; within same priority, oldest creation date first.

#### Immediate Issues

1. **Scope control** — need a max-issues-per-run parameter to prevent unbounded execution. Suggest default of 5.
2. **Label taxonomy** — need to define which labels mark an issue as "resolvable by automation." Currently the label set (`.github/.labels.json`) has `bug`, `enhancement`, `needs-triage`, etc. The `$target_labels` input gives flexibility but we need documented defaults.
3. **Conflict with active orchestration** — if an issue is part of an active epic's orchestration sequence, the resolve-open-issues workflow should skip it. Need a way to detect this (e.g., check for `epic` label or `orchestration:*` labels).
4. **Error recovery** — if resolving one issue fails, the workflow should continue to the next rather than aborting the entire run.

---

## **F3:** Remove explicit dependence on Github for event source

Dependencies: **F1** (moving orchestration code to prebuild container)

1. Create REST or webhook interface to the orchestration prompt that can receive event data from any source (e.g., GitHub, GitLab, Jira, etc.)
2. Update the datamodel to not depend exactly on GH event data (we can keep the same conceppt but make it slightly more generic to accomodate other sources)
3. Update the orchestration prompt to use the new generic datamodel
4. Move the devcontainer opencode server to run as a service that we can self-host on my linux server
5. Create GH App that listens listens for events and sned a webhook with the data to the new interface when relevant events occur (e.g., issue labeled with `orchestration:plan-approved`)

### Development Analysis

#### Architecture

This is a significant architectural evolution: decoupling the orchestration engine from GitHub Actions as the sole event source. The end state is a self-hosted orchestration service that receives events via a generic webhook/REST API, with GitHub being one of many possible event producers via a dedicated GitHub App.

#### Layers

```
┌────────────────────────────────────────────────────────┐
│  Event Sources (GitHub App, GitLab webhook, Jira, …)   │
└─────────────────────┬──────────────────────────────────┘
                      │ HTTP POST (generic event envelope)
                      ▼
┌────────────────────────────────────────────────────────┐
│  Orchestration Service (self-hosted)                   │
│  - REST endpoint: POST /events                         │
│  - Event normalizer → generic event model              │
│  - Prompt assembler (replaces assemble-orchestrator-   │
│    prompt.sh)                                          │
│  - opencode server manager                             │
│  - Agent executor (opencode run --attach)              │
└─────────────────────┬──────────────────────────────────┘
                      │
                      ▼
┌────────────────────────────────────────────────────────┐
│  opencode serve (port 4096)                            │
│  - Orchestrator agent + specialist subagents           │
└────────────────────────────────────────────────────────┘
```

#### Generic Event Model (Draft)

Replace direct `github.event` references with a platform-agnostic envelope:

```json
{
  "source": "github",
  "event_type": "issue_labeled",
  "timestamp": "2026-03-25T12:00:00Z",
  "actor": { "id": "nam20485", "type": "user" },
  "repository": { "owner": "intel-agency", "name": "my-app", "url": "..." },
  "ref": { "branch": "main", "sha": "abc123" },
  "entity": {
    "type": "issue",
    "number": 42,
    "title": "Epic: Phase 1 — ...",
    "body": "...",
    "labels": ["orchestration:plan-approved", "epic"],
    "state": "open"
  },
  "action": "labeled",
  "label": { "name": "orchestration:plan-approved" },
  "raw_payload": { }
}
```

The `raw_payload` preserves the original platform-specific data for source-specific logic.

#### Plan / Execution Order

1. **Define the generic event schema** — JSON Schema for the platform-agnostic envelope.
2. **Build event normalizers** — one per source platform:
   - `GitHubEventNormalizer` — transforms `github.event` JSON to the generic model
   - Others added later (GitLab, Jira, etc.)
3. **Update orchestrator prompt** — replace `EVENT_DATA` references with generic field paths. The match clauses (`type = issues && action = labeled && labels contains`) map cleanly to the generic model (`event_type = issue_labeled && entity.labels contains`).
4. **Build the orchestration service** — lightweight HTTP server:
   - `POST /events` — accepts generic event envelope, assembles prompt, dispatches to opencode
   - `GET /health` — health check
   - Runs as a systemd service on the Linux server
5. **Containerize** — the service runs in the same devcontainer image (or a derivative) since it needs opencode CLI, gh CLI, and all the tooling.
6. **Build the GitHub App** — listens for configured webhook events, normalizes to generic model, POSTs to the orchestration service endpoint.
7. **Migrate orchestrator-agent.yml** — thin shim that POSTs to the service instead of running opencode directly (backward compat during transition).
8. **Decommission workflow-based execution** once the service is stable.

#### Requirements

- The generic event model must be a strict superset of what the current prompt needs — no information loss.
- The self-hosted service must authenticate to GitHub with the same permissions currently granted by `GITHUB_TOKEN` + `GH_ORCHESTRATION_AGENT_TOKEN`.
- The GitHub App must only forward events that match the current `on:` trigger filters (issues labeled, workflow_dispatch, etc.) to avoid noise.
- The REST endpoint must validate incoming payloads (schema validation, HMAC signature verification for webhooks).
- The service must be restartable without losing in-flight orchestration state (or at minimum, must be able to detect and skip duplicate events).

#### Immediate Issues

1. **Dependency on F1** — the self-hosted service needs the prebuild container as its runtime. F1 must complete first to cleanly separate the container from the template.
2. **Authentication model** — GitHub Actions `GITHUB_TOKEN` is auto-provisioned per-run with scoped permissions. A self-hosted service needs a GitHub App installation token or a PAT with equivalent permissions. The `GH_ORCHESTRATION_AGENT_TOKEN` PAT is already used for cross-repo triggers, but a proper GitHub App would be cleaner.
3. **Networking** — the self-hosted service must be reachable by the GitHub App webhook. Options: (a) public endpoint with HTTPS, (b) Cloudflare Tunnel, (c) ngrok for development. Need to decide on the hosting approach.
4. **Prompt assembly rework** — `assemble-orchestrator-prompt.sh` is tightly coupled to GitHub Actions environment variables (`$GITHUB_ENV`, `${{ toJson(github.event) }}`). The service version needs its own prompt assembly that works from the generic event model.
5. **Observability** — the current system uses GitHub Actions logging. The self-hosted service needs its own logging, metrics, and error reporting infrastructure.
6. **Scale** — this is a single-tenant system for now. No need to over-engineer for multi-tenancy, but the generic event model should not preclude it.
