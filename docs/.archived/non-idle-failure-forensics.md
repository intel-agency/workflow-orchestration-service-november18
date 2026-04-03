# Non-Idle Failure Forensics — Token Scope and Devcontainer Image Mismatches

> **Date:** 2026-03-26  
> **Scope:** Two non-idle orchestrator failures called out as exceptions in `docs/idle-timeout-forensic-report.md`  
> **Affected targets:**
> - `intel-agency/ai-new-workflow-app-template` run `23415797162` (2026-03-23)
> - `intel-agency/workflow-orchestration-queue-quebec50` run `23530174003` (2026-03-25)  
> **Pattern confirmed:** Yes — both are **configuration / invariant mismatches**, not runtime orchestration stalls

---

## 1. Executive Summary

These two failures do make sense once viewed as **logic mismatches between configuration layers**, not as normal runtime errors.

- The template repo failure was caused by an **over-strict token validation rule**: `run_opencode_prompt.sh` preferred `GH_ORCHESTRATION_AGENT_TOKEN` when present and rejected it for missing `read:org`, even though the workflow was running against the same repository and could have proceeded with the built-in `GITHUB_TOKEN`.
- The Quebec50 failure was caused by a **partial migration mismatch**: the clone’s `.devcontainer/devcontainer.json` already pointed to the shared `workflow-orchestration-prebuild` image, but its historical `orchestrator-agent.yml` still checked for a repo-specific image `ghcr.io/${github.repository}/devcontainer:main-latest` and suggested running workflows that did not exist in that repo.

So the two incidents are unrelated to the idle-timeout pattern, but they are related to each other at a higher level: both failures came from the system enforcing the **wrong invariant**.

---

## 2. Forensic Evidence

### 2.1 Failure Inventory

| # | Repo | Run ID | Date (UTC) | Failure Class | Immediate Error | Why It Looked Illogical |
|---|------|--------|------------|---------------|-----------------|-------------------------|
| 1 | `intel-agency/ai-new-workflow-app-template` | `23415797162` | 2026-03-23 00:07 | Token validation failure | `GH_ORCHESTRATION_AGENT_TOKEN is missing required scopes: read:org` | Same-repo run rejected a narrower-but-usable token path instead of falling back to `GITHUB_TOKEN` |
| 2 | `intel-agency/workflow-orchestration-queue-quebec50` | `23530174003` | 2026-03-25 07:39 | Image bootstrap mismatch | `Devcontainer image not found: ghcr.io/intel-agency/workflow-orchestration-queue-quebec50/devcontainer:main-latest` | Repo config pointed to shared prebuild image, but workflow checked a nonexistent per-repo image and suggested nonexistent workflows |

### 2.2 Template Repo Token Failure — Observed Evidence

From run `23415797162`:

```text
Using GH_ORCHESTRATION_AGENT_TOKEN for authentication (cross-repo access enabled)
Granted OAuth scopes: project, read:packages, repo, workflow
##[error]GH_ORCHESTRATION_AGENT_TOKEN is missing required scopes: read:org
##[error]Required: repo workflow project read:org  |  Granted: project, read:packages, repo, workflow
##[error]Process completed with exit code 1.
```

From `run_opencode_prompt.sh`:

- Token selection priority is:
  1. `GH_ORCHESTRATION_AGENT_TOKEN`
  2. `GITHUB_TOKEN`
- If `GH_ORCHESTRATION_AGENT_TOKEN` is present, the script **always** validates the scope set against:
  - `repo`
  - `workflow`
  - `project`
  - `read:org`
- If any are missing, it exits immediately instead of degrading to `GITHUB_TOKEN`

That behavior is explicit in the current script logic in `run_opencode_prompt.sh`.

### 2.3 Quebec50 Missing-Image Failure — Observed Evidence

From run `23530174003`:

```text
IMAGE="ghcr.io/intel-agency/workflow-orchestration-queue-quebec50/devcontainer:main-latest"
##[error]Devcontainer image not found: ghcr.io/intel-agency/workflow-orchestration-queue-quebec50/devcontainer:main-latest
##[error]Run the 'Publish Docker' and 'Pre-build dev container image' workflows first.
##[error]Process completed with exit code 1.
```

From Quebec50’s workflow inventory at the time of inspection:

- Active workflows:
  - `orchestrator-agent`
  - `validate`
  - `CodeQL`
- Present under `.github/workflows/`:
  - `.disabled/`
  - `orchestrator-agent.yml`
  - `prompts/`
  - `validate.yml`
- **Missing**:
  - `publish-docker.yml`
  - `prebuild-devcontainer.yml`

From Quebec50’s `.devcontainer/devcontainer.json`:

```json
{
  "image": "ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest"
}
```

From the historical `orchestrator-agent.yml` used by the failing run:

```yaml
- name: Verify devcontainer image exists
  run: |
    IMAGE="ghcr.io/${{ github.repository }}/devcontainer:main-latest"
    if ! docker manifest inspect "$IMAGE" > /dev/null 2>&1; then
      echo "::error::Devcontainer image not found: $IMAGE"
      echo "::error::Run the 'Publish Docker' and 'Pre-build dev container image' workflows first."
      exit 1
    fi
```

This proves the workflow was checking a **different image** from the one the repo’s devcontainer config actually referenced.

### 2.4 Design-Intent Evidence

From `AGENTS.md` in this template repo:

- The template design says fresh clones should tolerate the absence of a prebuilt image.
- The consumer `.devcontainer/devcontainer.json` is expected to reference a prebuilt GHCR image.
- The migration goal is to centralize orchestration image logic into the shared prebuild repo.

That makes the Quebec50 failure especially important: it violated the declared design constraint for fresh clones by checking the wrong image source and suggesting a remediation path the clone could not execute.

---

## 3. Root Cause Analysis

## 3A. Issue One — `GH_ORCHESTRATION_AGENT_TOKEN` Missing `read:org`

### 3A.1 Immediate Cause

The workflow failed because `run_opencode_prompt.sh` detected that `GH_ORCHESTRATION_AGENT_TOKEN` lacked the `read:org` OAuth scope and terminated before launching the orchestrator.

### 3A.2 Mechanism

The failure chain was:

1. The workflow exported both `GITHUB_TOKEN` and `GH_ORCHESTRATION_AGENT_TOKEN`.
2. `run_opencode_prompt.sh` preferred `GH_ORCHESTRATION_AGENT_TOKEN` when present.
3. It validated that token unconditionally against the hard-coded required scope set: `repo workflow project read:org`.
4. The actual granted scopes were `project, read:packages, repo, workflow`.
5. Because `read:org` was missing, the script exited immediately.
6. The script did **not** fall back to `GITHUB_TOKEN`, even though fallback logic exists when the PAT is absent.

### 3A.3 Why It Does Not Make Sense at First Glance

At first glance this failure looks contradictory because the script advertises `GITHUB_TOKEN` as a same-repo fallback, and this run was operating on the template repo itself.

The non-obvious behavior is:

- fallback is only used when `GH_ORCHESTRATION_AGENT_TOKEN` is **absent**
- fallback is **not** used when the PAT is present but fails validation

So the system behaved like this:

> “A stronger token exists, but because it is missing one scope from a global cross-repo requirement, the run must fail — even if a weaker token would be sufficient for this specific same-repo run.”

That is logically inconsistent with the stated priority model of “use PAT for cross-repo access, otherwise use `GITHUB_TOKEN` for same-repo access.”

### 3A.4 Structural Cause

The real design flaw is that the script enforces a **global capability contract** (`read:org` always required when PAT exists) rather than a **contextual capability contract** (“only require org-reading scopes when the upcoming work actually needs them”).

This makes the PAT behave as a hard gate instead of an enhancement.

### 3A.5 Confidence Notes

- **Directly observed:** run log error lines and current token validation logic
- **Strongly inferred:** this specific run could have proceeded without `read:org` because the failure happened before any cross-repo/org operation was attempted
- **Not yet proven in this report:** whether every workflow-run trigger in the template repo can safely operate with `GITHUB_TOKEN` only

---

## 3B. Issue Two — Quebec50 Missing Devcontainer Image

### 3B.1 Immediate Cause

The Quebec50 orchestrator workflow failed because it checked for a repo-specific image:

`ghcr.io/intel-agency/workflow-orchestration-queue-quebec50/devcontainer:main-latest`

That image did not exist.

### 3B.2 Mechanism

The failure chain was:

1. Quebec50 was generated from a template state where orchestration image handling was mid-migration.
2. Its `.devcontainer/devcontainer.json` already pointed to the shared prebuild image:
   `ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest`
3. But its historical `orchestrator-agent.yml` still verified and pulled the old per-repo image form:
   `ghcr.io/${github.repository}/devcontainer:main-latest`
4. The repo had no `publish-docker.yml` or `prebuild-devcontainer.yml` workflows, so there was no local mechanism to create that per-repo image.
5. The workflow then suggested a remediation path — run `Publish Docker` and `Pre-build dev container image` — that was impossible in the repo as cloned.
6. The orchestrator failed before doing any real orchestration work.

### 3B.3 Why It Does Not Make Sense at First Glance

This failure looks illogical because three layers disagreed with each other:

- **Devcontainer runtime config:** use shared prebuild image
- **Template design intent:** fresh clones should tolerate absence of a local prebuilt image
- **Historical orchestrator workflow:** require a repo-specific image and suggest repo-local publish/prebuild workflows

So the system effectively said:

> “Use the shared image in config, but fail the workflow unless a per-repo image exists, and fix it by running workflows that aren’t even present here.”

That is not operator error; it is a configuration split-brain condition.

### 3B.4 Structural Cause

The root structural flaw is a **partial migration** from per-repo image publishing to the centralized `workflow-orchestration-prebuild` model.

The migration updated at least one consumer-facing layer (`.devcontainer/devcontainer.json`) but did not update the orchestration workflow in the same template state. That left fresh clones with internally inconsistent assumptions.

### 3B.5 Confidence Notes

- **Directly observed:** failing run log, workflow inventory, repo file listing, devcontainer config, and historical workflow content
- **Directly supported:** the remediation message referenced workflows absent from the repo
- **Strongly inferred:** Quebec50 was cloned from a template snapshot before the orchestrator workflow was fully migrated to the shared prebuild image path

---

## 4. Solutions with Pros/Cons

### Solution A: Make Token Validation Context-Aware

**Change:** In `run_opencode_prompt.sh`, only require `read:org` when the upcoming orchestration task actually needs org-level access. Otherwise allow `repo` + `workflow` + `project` to proceed.

| Pros | Cons |
|------|------|
| Aligns required scopes with real runtime needs | Requires deciding how to detect “org access needed” |
| Prevents same-repo runs from failing unnecessarily | Slightly more logic in a critical script |
| Preserves PAT benefits where actually needed | Harder to reason about than a single fixed scope set |

### Solution B: Fall Back to `GITHUB_TOKEN` When PAT Fails Optional Scope Checks

**Change:** If `GH_ORCHESTRATION_AGENT_TOKEN` is present but fails a non-critical scope check, log a warning and retry with `GITHUB_TOKEN` for same-repo execution.

| Pros | Cons |
|------|------|
| Matches the intended “PAT preferred, built-in token fallback” mental model | Need a robust rule for when fallback is safe |
| Keeps workflows usable during secret drift or partial PAT misconfiguration | Could hide under-scoped PAT problems if warning visibility is poor |
| Small behavioral change with high operator value | Must avoid fallback in truly cross-repo flows |

### Solution C: Fix the Secret and Keep the Hard Gate

**Change:** Ensure `GH_ORCHESTRATION_AGENT_TOKEN` always includes `read:org` in every environment.

| Pros | Cons |
|------|------|
| Simplest operational fix for the token issue | Treats the symptom, not the design flaw |
| No script changes needed | Same-repo runs remain over-constrained |
| Maintains one universal PAT contract | Future scope drift causes the same class of outage |

### Solution D: Use a Single Source of Truth for Devcontainer Image Resolution

**Change:** Derive the image to verify/pull from the same source used by `.devcontainer/devcontainer.json`, or centralize image resolution in one script used by both workflow and config generation.

| Pros | Cons |
|------|------|
| Eliminates split-brain between workflow and devcontainer config | Requires refactoring workflow/image-resolution logic |
| Prevents future partial-migration regressions | Slightly more indirection in setup flow |
| Makes error messages reflect actual runtime configuration | Needs careful rollout across template and clones |

### Solution E: Add a Fresh-Clone Compatibility Guard

**Change:** Before checking for a local image, detect whether the repo is configured to use the shared prebuild image or lacks local publish/prebuild workflows; if so, switch to the shared image path or skip the local-image invariant entirely.

| Pros | Cons |
|------|------|
| Directly addresses the Quebec50 failure mode | Adds special-case logic |
| Honors the documented fresh-clone design constraint | Could become messy if migration states proliferate |
| Gives clearer operator-facing diagnostics | Still better as a guardrail than as final architecture |

### Solution F: Add a Template Consistency Test

**Change:** Add a validation check that compares:

- `.devcontainer/devcontainer.json`
- `.github/workflows/orchestrator-agent.yml`
- presence/absence of `publish-docker.yml` and `prebuild-devcontainer.yml`

and fails CI if they express conflicting image strategies.

| Pros | Cons |
|------|------|
| Catches this exact class of split-brain before clones are generated | Preventive only — does not fix existing bad clones |
| Very high leverage for a template repo | Another CI rule to maintain |
| Converts a confusing runtime failure into an early template failure | Needs careful implementation to avoid false positives |

---

## 5. Recommendation

### Recommended Path

1. **Immediate:**
   - Fix any remaining environments where `GH_ORCHESTRATION_AGENT_TOKEN` lacks `read:org`
   - Keep current migrated orchestrator workflow on the shared prebuild image path
2. **Short-term hardening:**
   - Make token validation context-aware **or** fall back to `GITHUB_TOKEN` when PAT validation fails in same-repo scenarios
   - Add a template consistency validation so image strategy cannot diverge across workflow/config layers
3. **Medium-term cleanup:**
   - Centralize devcontainer image resolution into one reusable source of truth used by both orchestration workflows and repo configs

### Why This Recommendation

This combination addresses both incidents at the correct layer:

- The token problem is best fixed by reducing **unnecessary rigidity** in auth validation, not just by asking operators to maintain a perfect PAT forever.
- The Quebec50 problem is best fixed by eliminating **configuration split-brain** at the template level, because fresh clones should never be able to inherit contradictory image assumptions.

Why not only patch the symptoms?

- Only fixing the PAT scope leaves same-repo runs over-constrained.
- Only fixing the historical image check leaves no protection against future migration drift.
- Only documenting the issue is too weak; these are invariant mismatches that should be mechanically prevented.

The best practical approach is therefore:

- operational fix now
- invariant checks next
- architecture cleanup after that

---

## 6. Appendix

### 6.1 Raw Error Signatures

#### Template repo token failure

```text
Granted OAuth scopes: project, read:packages, repo, workflow
GH_ORCHESTRATION_AGENT_TOKEN is missing required scopes: read:org
Required: repo workflow project read:org  |  Granted: project, read:packages, repo, workflow
```

#### Quebec50 image failure

```text
Devcontainer image not found: ghcr.io/intel-agency/workflow-orchestration-queue-quebec50/devcontainer:main-latest
Run the 'Publish Docker' and 'Pre-build dev container image' workflows first.
```

### 6.2 Representative Contradiction Snapshot

#### Quebec50 config vs workflow expectation

```json
// .devcontainer/devcontainer.json
{
  "image": "ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest"
}
```

```yaml
# historical orchestrator-agent.yml
IMAGE="ghcr.io/${{ github.repository }}/devcontainer:main-latest"
```

These cannot both be the correct invariant for the same repo.

### 6.3 Sources Consulted

- Workflow run `23415797162` logs (`intel-agency/ai-new-workflow-app-template`)
- Workflow run `23530174003` logs (`intel-agency/workflow-orchestration-queue-quebec50`)
- `run_opencode_prompt.sh`
- Historical template workflow at commit `c0f799e0a3d271479e62ff4df5bff305598e1361`:
  `.github/workflows/orchestrator-agent.yml`
- Quebec50 `.github/workflows/` inventory
- Quebec50 `.devcontainer/devcontainer.json`
- `AGENTS.md` template design constraints

