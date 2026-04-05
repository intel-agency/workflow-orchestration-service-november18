# Workflow Execution Plan: project-setup

**Dynamic Workflow:** `project-setup`  
**Workflow File:** `ai_instruction_modules/ai-workflow-assignments/dynamic-workflows/project-setup.md`  
**Repository:** `intel-agency/workflow-orchestration-service-november18`  
**Date:** 2026-04-03  
**Total Assignments:** 6  

---

## 1. Overview

### Workflow Description

The `project-setup` dynamic workflow initiates a new repository by executing a structured sequence of 6 assignments that establish the project foundation, create planning artifacts, scaffold the application structure, configure AI agent instructions, document learnings, and finalize the setup with PR approval and merge.

### Project Description

**workflow-orchestration-service Standalone Orchestration Service Migration**

This project migrates the orchestration workflow agent from a GitHub Actions-embedded model to a **standalone, self-hosted, networked client/server service**. The server runs the full orchestration stack (opencode CLI, agents, MCP servers) inside a Docker image. The client is a Python service that receives GitHub events via webhooks and dispatches prompts to the remote server.

**Key Insight:** The codebase already provides 80-100% implementation coverage for core components. This migration is primarily an **integration and packaging** effort—not a greenfield build.

### High-Level Summary

This workflow will:
1. Initialize the repository with proper branch protection, labels, and project board
2. Create a detailed application implementation plan based on the migration specification
3. Scaffold the project structure for both server and client components
4. Generate `AGENTS.md` for AI coding agents
5. Document learnings and create a debrief report
6. Merge all changes via a structured PR approval process

---

## 2. Project Context Summary

### Technology Stack

| Category | Technologies |
|----------|--------------|
| **Languages** | Python 3.12+, Bash, PowerShell |
| **Frameworks** | FastAPI, Pydantic, uvicorn |
| **HTTP Client** | httpx (async) |
| **Package Manager** | uv (Rust-based, fast) |
| **Containerization** | Docker, docker-compose |
| **AI Runtime** | opencode CLI, MCP servers (sequential-thinking, memory) |
| **Models** | ZhipuAI GLM-5, OpenAI GPT-5.4, Google Gemini 3 |
| **CI/CD** | GitHub Actions (SHA-pinned actions) |

### Repository Details

- **Repository:** `intel-agency/workflow-orchestration-service-november18`
- **Primary Branch:** `main`
- **Working Branch (this workflow):** `dynamic-workflow-project-setup`
- **Template Source:** `intel-agency/ai-new-workflow-app-template`

### Architecture Overview

```
GitHub App (webhooks) → Orchestration Client (FastAPI, :8000)
                         → TCP :4096 →
                       Orchestration Server (opencode serve, Docker, :4096)
```

**Components:**
- **Orchestration Server**: Docker container with opencode CLI, 27 specialist agents, MCP servers
- **Orchestration Client**: Python service with FastAPI webhook handler + Sentinel polling loop
- **GitHub App**: Delivers repository events as webhooks

### Existing Code Coverage

| Component | Coverage | Location |
|-----------|----------|----------|
| Sentinel Orchestrator | ~90% | `plan_docs/orchestrator_sentinel.py` |
| Webhook Notifier | ~80% | `plan_docs/notifier_service.py` |
| Work Item Model | ~95% | `plan_docs/src/models/work_item.py` |
| GitHub Queue | ~85% | `plan_docs/src/queue/github_queue.py` |
| Shell Bridge | 100% | `scripts/devcontainer-opencode.sh` |
| OpenCode Server Bootstrap | 100% | `scripts/start-opencode-server.sh` |

### Key Constraints

1. **SHA Pinning Mandate**: ALL GitHub Actions must be pinned to specific commit SHAs (no `@v3` or `@main` tags)
2. **Credential Scrubbing**: All GitHub-posted content must pass through `scrub_secrets()`
3. **Shell Bridge Protocol**: Sentinel interacts with server exclusively via `devcontainer-opencode.sh`
4. **Polling-First Resiliency**: Webhook delivery is an optimization; polling ensures self-healing
5. **Mandatory Validation**: `pwsh -NoProfile -File ./scripts/validate.ps1 -All` must pass before each phase gate

### Known Risks

| Risk ID | Risk | Mitigation |
|---------|------|------------|
| R1 | Shell bridge remote dispatch fails silently | Explicit connection test before dispatch; log all stderr |
| R6 | Credentials leak in agent output | `scrub_secrets()` on all GitHub-posted content |
| R7 | Budget runaway during autonomous execution | Budget monitor with daily limit; `agent:stalled-budget` halts processing |
| R10 | Prompt injection via crafted issue body | Only process verified GitHub App payloads; never execute raw user input |

---

## 3. Assignment Execution Plan

### Assignment 1: init-existing-repository

| Field | Content |
|-------|---------|
| **Assignment** | `init-existing-repository`: Initialize Repository Infrastructure |
| **Goal** | Set up repository infrastructure including branch protection, project board, labels, and initial PR |
| **Key Acceptance Criteria** | • New branch `dynamic-workflow-project-setup` created (FIRST step)<br>• Branch protection ruleset imported from `.github/protected-branches_ruleset.json`<br>• GitHub Project created with columns: Not Started, In Progress, In Review, Done<br>• Labels imported from `.github/.labels.json`<br>• Workspace/devcontainer files renamed to match project name<br>• PR created from branch to `main` |
| **Project-Specific Notes** | This repository is a template clone with existing `.github/` infrastructure. The branch protection ruleset already exists in the template. Focus on importing it correctly and ensuring `administration: write` scope is available for the PAT. |
| **Prerequisites** | • GitHub authentication with scopes: `repo`, `project`, `read:project`, `read:user`, `user:email`<br>• `administration: write` scope for branch protection ruleset import<br>• GitHub CLI (`gh`) installed and authenticated |
| **Dependencies** | None (first assignment) |
| **Risks / Challenges** | • Ruleset import may fail if PAT lacks `administration: write` scope<br>• Branch must be created BEFORE any commits (enforced by assignment)<br>• PR creation requires at least one commit pushed first |
| **Events** | None declared |

---

### Assignment 2: create-app-plan

| Field | Content |
|-------|---------|
| **Assignment** | `create-app-plan`: Create Application Implementation Plan |
| **Goal** | Create a comprehensive application plan documented as a GitHub Issue, based on the migration specification and supporting documents |
| **Key Acceptance Criteria** | • Application template analyzed (`plan_docs/Application Implementation Specification - workflow-orchestration-service v1.2.md`)<br>• Plan documented using template from `.github/ISSUE_TEMPLATE/application-plan.md`<br>• Detailed breakdown of all 6 phases (Phase 0-5)<br>• All 29 tasks from migration plan addressed<br>• Milestones created and linked to plan issue<br>• Issue added to GitHub Project and assigned to "Phase 1: Foundation" milestone<br>• Labels applied: `planning`, `documentation` |
| **Project-Specific Notes** | The migration plan already provides a detailed 6-phase breakdown with 29 tasks, agent assignments, validation plans, and risk register. This assignment will formalize it into a GitHub Issue for tracking. **This is PLANNING ONLY—no code implementation.** |
| **Prerequisites** | • `init-existing-repository` completed<br>• Project board and labels available |
| **Dependencies** | • Outputs from Assignment 1 (project board, labels) |
| **Risks / Challenges** | • Plan is already very detailed—ensure the issue doesn't just duplicate the existing spec but provides actionable tracking<br>• Technology stack must align with migration plan (Python 3.12+, FastAPI, Docker) |
| **Events** | • `pre-assignment-begin`: `gather-context` assignment<br>• `on-assignment-failure`: `recover-from-error` assignment<br>• `post-assignment-complete`: `report-progress` assignment |

---

### Assignment 3: create-project-structure

| Field | Content |
|-------|---------|
| **Assignment** | `create-project-structure`: Create Project Structure and Scaffolding |
| **Goal** | Create the actual project structure and scaffolding based on the application plan, including solution files, Docker configurations, CI/CD workflows, and documentation structure |
| **Key Acceptance Criteria** | • Solution/project structure created following Python/FastAPI conventions<br>• Dockerfile for orchestration server (Phase 0)<br>• Dockerfile for orchestration client (Phase 3)<br>• docker-compose.yml for local development<br>• Basic CI/CD workflow structure established (`.github/workflows/`)<br>• Documentation structure created (README, docs/, API docs)<br>• Repository summary document created (`.ai-repository-summary.md`)<br>• All GitHub Actions workflows SHA-pinned<br>• Initial commit made with complete scaffolding |
| **Project-Specific Notes** | This project has a **dual-component structure**:<br>• **Server side**: `/opt/orchestration/` with agents, commands, scripts, opencode.json<br>• **Client side**: `client/` directory with Python modules (sentinel, notifier, queue, models)<br><br>Key files to create:<br>• Server Dockerfile (consolidates agents, commands, scripts, configs)<br>• Client Dockerfile (Python 3.12-slim base)<br>• `requirements.txt` for Python dependencies (FastAPI, httpx, Pydantic, uvicorn)<br>• `pyproject.toml` for client package<br>• CI/CD workflows (build, test, deploy) |
| **Prerequisites** | • `create-app-plan` completed<br>• Application plan issue available |
| **Dependencies** | • Plan issue from Assignment 2 (provides structure guidance)<br>• Tech stack decisions documented |
| **Risks / Challenges** | • Dual-component structure requires careful directory organization<br>• Existing Python modules in `plan_docs/` must be copied to `client/src/` with updated import paths<br>• Docker healthchecks must NOT use `curl` (use Python stdlib instead)<br>• SHA pinning for ALL actions in ALL workflows |
| **Events** | None declared |

---

### Assignment 4: create-agents-md-file

| Field | Content |
|-------|---------|
| **Assignment** | `create-agents-md-file`: Create AGENTS.md for AI Coding Agents |
| **Goal** | Create a comprehensive `AGENTS.md` file at the repository root that provides AI coding agents with the context and instructions they need to work effectively on the project |
| **Key Acceptance Criteria** | • `AGENTS.md` exists at repository root<br>• Project overview section (purpose, tech stack)<br>• Setup/build/test commands verified to work<br>• Code style and conventions section<br>• Project structure/directory layout section<br>• Testing instructions<br>• PR/commit guidelines<br>• All listed commands validated by running them |
| **Project-Specific Notes** | This project has unique characteristics that must be documented:<br>• **Dual-mode operation**: Webhook handler + Sentinel polling loop<br>• **Shell bridge protocol**: `devcontainer-opencode.sh` is the primary API<br>• **Remote server dispatch**: Client sends prompts to server via `-u <server-url>`<br>• **Credential scrubbing mandate**: All GitHub output must use `scrub_secrets()`<br>• **SHA pinning enforcement**: No version tags in workflows |
| **Prerequisites** | • `create-project-structure` completed<br>• Build/test tooling in place |
| **Dependencies** | • Project structure from Assignment 3<br>• README.md and `.ai-repository-summary.md` for cross-referencing |
| **Risks / Challenges** | • Commands must be validated—many are specific to this orchestration system (e.g., `opencode serve`, shell bridge dispatch)<br>• Must complement, not duplicate, existing README.md<br>• Monorepo considerations: may need nested AGENTS.md for server vs. client |
| **Events** | None declared |

---

### Assignment 5: debrief-and-document

| Field | Content |
|-------|---------|
| **Assignment** | `debrief-and-document`: Debrief and Document Learnings |
| **Goal** | Perform a comprehensive debriefing session that captures key learnings, insights, and areas for improvement from the project setup workflow |
| **Key Acceptance Criteria** | • Detailed report created following structured template (12 sections)<br>• Report documented in `.md` file format<br>• All deviations from assignments documented<br>• Report reviewed and approved by stakeholders<br>• Report committed and pushed to repo<br>• Execution trace saved as `debrief-and-document/trace.md` |
| **Project-Specific Notes** | This is the first execution of the `project-setup` workflow for this repository. The debrief should capture:<br>• Challenges with template clone infrastructure (ruleset import, label sync)<br>• Planning document quality (migration spec was very detailed—was it sufficient?)<br>• Dual-component scaffolding complexity<br>• SHA pinning enforcement experience<br>• Shell bridge remote dispatch validation |
| **Prerequisites** | • All preceding assignments completed |
| **Dependencies** | • Outputs from all previous assignments |
| **Risks / Challenges** | • Must flag plan-impacting findings as ACTION ITEMS<br>• Execution trace must capture all terminal output, commands, file changes<br>• Review with stakeholder before finalizing |
| **Events** | None declared |

---

### Assignment 6: pr-approval-and-merge

| Field | Content |
|-------|---------|
| **Assignment** | `pr-approval-and-merge`: Pull Request Approval and Merge |
| **Goal** | Complete the full PR approval and merge process, including resolving all PR comments, obtaining approval, merging the PR, and closing associated issues |
| **Key Acceptance Criteria** | • All CI/CD status checks pass (CI remediation loop up to 3 attempts)<br>• Code review delegated to `code-reviewer` subagent (NOT self-review)<br>• Auto-reviewer comments (Copilot, CodeQL, etc.) waited for and resolved<br>• PR comment protocol executed (`ai-pr-comment-protocol.md`)<br>• All review threads resolved via GraphQL mutation<br>• Stakeholder/Delegating Agent approval obtained<br>• Merge performed (or blocked reason documented)<br>• Source branch deleted (if merge succeeded)<br>• Related issues closed or updated |
| **Project-Specific Notes** | **Special handling for this workflow:**<br>• This is an **automated setup PR**—self-approval by the orchestrator is acceptable per the workflow definition<br>• No human stakeholder approval required<br>• CI remediation loop (Phase 0.5) MUST still be executed<br>• PR number comes from `#initiate-new-repository` output (Assignment 1) |
| **Prerequisites** | • All preceding assignments completed<br>• PR created in Assignment 1 has commits ready |
| **Dependencies** | • PR number from Assignment 1<br>• All code changes from Assignments 2-5 committed to branch |
| **Risks / Challenges** | • CI failures may require up to 3 fix cycles—budget time accordingly<br>• Must follow `ai-pr-comment-protocol.md` exactly (non-negotiable)<br>• GraphQL verification artifacts required (`pr-unresolved-threads.json`)<br>• **CRITICAL**: Commit all changes BEFORE merge or lose work |
| **Events** | None declared |

---

## 4. Sequencing Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    PROJECT-SETUP WORKFLOW                            │
└─────────────────────────────────────────────────────────────────────┘

START
  │
  ├── [PRE-SCRIPT-BEGIN EVENT]
  │     └── create-workflow-plan ← YOU ARE HERE
  │           └── Output: plan_docs/workflow-plan.md
  │
  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ ASSIGNMENT 1: init-existing-repository                              │
│   • Create branch: dynamic-workflow-project-setup                   │
│   • Import branch protection ruleset                                │
│   • Create GitHub Project board                                     │
│   • Import labels from .github/.labels.json                         │
│   • Rename workspace/devcontainer files                             │
│   • Create PR (after first commit)                                  │
│   Output: PR number for Assignment 6                                │
└─────────────────────────────────────────────────────────────────────┘
  │
  ├── [POST-ASSIGNMENT-COMPLETE EVENT]
  │     ├── validate-assignment-completion
  │     └── report-progress
  │
  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ ASSIGNMENT 2: create-app-plan                                       │
│   • Analyze migration specification                                 │
│   • Create plan issue using application-plan.md template            │
│   • Document 6 phases, 29 tasks, agent assignments                 │
│   • Create milestones (Phase 0-5)                                   │
│   • Link issue to project board                                     │
│   Output: Plan issue number, milestone structure                    │
└─────────────────────────────────────────────────────────────────────┘
  │
  ├── [POST-ASSIGNMENT-COMPLETE EVENT]
  │     ├── validate-assignment-completion
  │     └── report-progress
  │
  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ ASSIGNMENT 3: create-project-structure                              │
│   • Create server directory structure (/opt/orchestration/)         │
│   • Create client directory structure (client/)                     │
│   • Create Dockerfiles (server + client)                            │
│   • Create docker-compose.yml                                       │
│   • Create CI/CD workflow templates (SHA-pinned)                    │
│   • Create documentation structure (README, docs/, API)            │
│   • Create .ai-repository-summary.md                                │
│   Output: Complete project scaffolding                              │
└─────────────────────────────────────────────────────────────────────┘
  │
  ├── [POST-ASSIGNMENT-COMPLETE EVENT]
  │     ├── validate-assignment-completion
  │     └── report-progress
  │
  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ ASSIGNMENT 4: create-agents-md-file                                 │
│   • Gather project context (README, repo summary, plan docs)        │
│   • Validate build/test commands                                    │
│   • Draft AGENTS.md with all required sections                      │
│   • Cross-reference with existing documentation                     │
│   • Validate all commands work                                      │
│   Output: AGENTS.md at repository root                              │
└─────────────────────────────────────────────────────────────────────┘
  │
  ├── [POST-ASSIGNMENT-COMPLETE EVENT]
  │     ├── validate-assignment-completion
  │     └── report-progress
  │
  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ ASSIGNMENT 5: debrief-and-document                                  │
│   • Create 12-section debrief report                                │
│   • Document all deviations from assignments                        │
│   • Create execution trace (debrief-and-document/trace.md)          │
│   • Review with stakeholder                                         │
│   • Commit and push report                                          │
│   Output: Debrief report, execution trace                           │
└─────────────────────────────────────────────────────────────────────┘
  │
  ├── [POST-ASSIGNMENT-COMPLETE EVENT]
  │     ├── validate-assignment-completion
  │     └── report-progress
  │
  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ ASSIGNMENT 6: pr-approval-and-merge                                 │
│   • Verify CI checks pass (remediation loop up to 3 attempts)       │
│   • Delegate code review to code-reviewer subagent                  │
│   • Wait for auto-reviewer comments (Copilot, CodeQL)               │
│   • Execute PR comment protocol (ai-pr-comment-protocol.md)         │
│   • Resolve all review threads via GraphQL                          │
│   • Obtain orchestrator approval (automated setup PR)               │
│   • Merge PR to main                                                │
│   • Delete setup branch                                             │
│   • Close related setup issues                                      │
│   Output: Merged PR, clean main branch                              │
└─────────────────────────────────────────────────────────────────────┘
  │
  ├── [POST-SCRIPT-COMPLETE EVENT]
  │     └── Apply orchestration:plan-approved label to plan issue
  │           (triggers next orchestration phase)
  │
  ▼
END

═══════════════════════════════════════════════════════════════════════

DEPENDENCY CHAIN:
  Assignment 1 → Assignment 2 → Assignment 3 → Assignment 4 → Assignment 5 → Assignment 6
       │              │              │              │              │              │
       └──────────────┴──────────────┴──────────────┴──────────────┴──────────────┘
                              All must complete sequentially
```

---

## 5. Open Questions — RESOLVED

> **Status:** All questions resolved by orchestrator approval on 2026-04-03

---

### 5.1 Planning Document Completeness ✅ RESOLVED

**Question:** The migration specification references additional expected documents that may not exist yet:
- `plan_docs/workflow-orchestration-service Architecture Guide v3.2.md`
- `plan_docs/workflow-orchestration-service Development Plan v4.2.md`
- `plan_docs/architecture.md`
- `plan_docs/tech-stack.md`

**Decision:** **YES** — Create `plan_docs/architecture.md` and `plan_docs/tech-stack.md` if they don't exist during the `create-app-plan` assignment.

**Rationale:** The Implementation Specification already contains sufficient detail. These documents should be generated as part of the planning phase.

**Implementation:** Assignment 2 (`create-app-plan`) will create these files if missing.

---

### 5.2 Existing Code Migration Strategy ✅ RESOLVED

**Question:** The planning documents indicate existing Python modules in `plan_docs/` (sentinel, notifier, queue, models) with 80-100% completion. Should these be copied to `client/src/` during scaffolding?

**Decision:** **NO** — Do not copy existing Python modules during `create-project-structure`. This will be done in implementation phases (Phase 2 per the migration plan).

**Rationale:** The setup workflow focuses on structure and scaffolding, not implementation code migration. Actual code integration happens in later phases.

**Implementation:** Assignment 3 (`create-project-structure`) will create directory structure but leave existing modules in `plan_docs/`.

---

### 5.3 CI/CD Workflow Scope ✅ RESOLVED

**Question:** Should `create-project-structure` create full CI/CD workflows or basic CI only?

**Decision:** **Basic CI only** — Create lint, test, and build workflows. Deployment pipelines come later in Phase 5 (Production Hardening).

**Rationale:** Setup workflow establishes foundation. Advanced deployment workflows belong in production hardening phase per migration plan.

**Implementation:** Assignment 3 (`create-project-structure`) will create basic CI workflows only (lint, test, build).

---

### 5.4 AGENTS.md Scope for Dual-Component System ✅ RESOLVED

**Question:** Should we use a single root `AGENTS.md` or nested files for server/client components?

**Decision:** **Single root `AGENTS.md`** is sufficient for this initial setup.

**Rationale:** The project is cohesive enough that a single file can cover both components. Nested files can be added later if complexity warrants.

**Implementation:** Assignment 4 (`create-agents-md-file`) will create a single comprehensive `AGENTS.md` at repository root.

---

### 5.5 PR Review Automation Level ✅ RESOLVED

**Question:** Should the `pr-approval-and-merge` assignment execute full review protocol or simplified automated review?

**Decision:** **Simplified automated review** — Orchestrator self-approval is acceptable for this setup PR. Full review protocol (auto-reviewer wait, extensive comment resolution) is not required.

**Rationale:** This is explicitly designated as an "automated setup PR" in the workflow definition. Quality is ensured through validation gates and the structured workflow itself.

**Implementation:** Assignment 6 (`pr-approval-and-merge`) will use simplified review with orchestrator self-approval.

---

## 6. Summary

This workflow execution plan covers the complete `project-setup` sequence for the **workflow-orchestration-service Standalone Orchestration Service Migration**. The project benefits from substantial existing code coverage (80-100% for core components), making this primarily an integration and packaging effort.

**Key Success Factors:**
1. **Sequential execution**—each assignment depends on the previous
2. **SHA pinning enforcement**—no version tags in any workflow
3. **Credential scrubbing**—all GitHub output sanitized
4. **Validation gates**—`./scripts/validate.ps1 -All` must pass at each phase
5. **Stakeholder checkpoints**—approval required for plan, structure, AGENTS.md, and final merge

**Estimated Timeline:**
- Assignment 1 (init): 30-45 minutes
- Assignment 2 (plan): 60-90 minutes
- Assignment 3 (structure): 90-120 minutes
- Assignment 4 (AGENTS.md): 45-60 minutes
- Assignment 5 (debrief): 30-45 minutes
- Assignment 6 (PR merge): 60-90 minutes (including CI remediation loops)

**Total Estimated Duration:** 5.5-8 hours

**Next Step:** Stakeholder review and approval of this workflow execution plan.

---

**Plan Prepared By:** Planner Agent  
**Date:** 2026-04-03  
**Status:** Ready for Stakeholder Review  
**Next Action:** Present to stakeholder for approval, then commit to `plan_docs/workflow-plan.md`
