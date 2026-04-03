# Prompt Repetition Opportunities

> **Technique:** Repeating the prompt (or critical sections) increases the probability that the model follows instructions faithfully. The repeated content is separated by a `--- prompt repeated verbatim to aid comprehension... ---` marker so the model understands it is intentional reinforcement, not duplication.

```
$ASSEMBLED_PROMPT

--- prompt repeated verbatim to aid comprehension... ---

$ASSEMBLED_PROMPT
```

> **Constraint:** Never repeat action directives (e.g. `/orchestrate-dynamic-workflow`) — only repeat instructional / declarative content. Repeating an action could cause the agent to execute it twice.

---

## Opportunity Matrix

| # | Location | What to Repeat | Suitability | Impact | Risk | Notes |
|---|----------|----------------|-------------|--------|------|-------|
| 1 | `scripts/assemble-orchestrator-prompt.sh` | Full assembled prompt | **HIGH** | **HIGH** | LOW | Primary injection point — see below |
| 2 | `orchestrator-agent-prompt.md` — `## Final` section | Memory-write instructions | **HIGH** | MEDIUM | NONE | Most-skipped section; at end of long prompt |
| 3 | `orchestrator-agent-prompt.md` — match clause label-application steps | Per-clause "apply label" line | MEDIUM | **HIGH** | LOW | Directly addresses the papa89 stall class |
| 4 | `.opencode/commands/orchestrate-dynamic-workflow.md` | Core + assignment instruction links | MEDIUM | MEDIUM | LOW | Subagent instructions; reinforces reading upstream files |
| 5 | `.opencode/commands/resolve-pr-comments.md` | "ALL review comments MUST be addressed" | **HIGH** | MEDIUM | NONE | Known partial-completion failure mode |
| 6 | `.opencode/commands/grind-pr-reviews.md` | Full cycle steps (assign → wait → resolve) | MEDIUM | MEDIUM | LOW | Multi-step loop; easy to short-circuit |
| 7 | `scripts/assemble-local-prompt.sh` | Full assembled prompt (fixture mode) | LOW | LOW | NONE | Local testing only — mirrors #1 |
| 8 | `run_opencode_prompt.sh` | Prompt string before passing to opencode | LOW | **HIGH** | MEDIUM | Runtime doubling; increases token cost on every run |

---

## Detailed Analysis

### 1. `scripts/assemble-orchestrator-prompt.sh` — Full Prompt Repetition

**File:** [scripts/assemble-orchestrator-prompt.sh](../scripts/assemble-orchestrator-prompt.sh)
**Line:** ~80 (after the assembled prompt is written)

This is the **primary candidate**. The assembled prompt is written once to `.assembled-orchestrator-prompt.md`, then read by `run_opencode_prompt.sh` and passed as the prompt argument to `opencode run`. Doubling the prompt here means the model sees the full instruction set twice — clauses, helper functions, and the `## Final` section.

**Implementation:** After the prompt is assembled, append the separator and repeat:

```bash
# After the initial assembly block:
{
  sed '/{{__EVENT_DATA__}}/,$ d' "$PROMPT_TEMPLATE"
  echo "$EVENT_BLOCK"
  echo ""
  printf '```json\n'
  echo "$EVENT_JSON"
  printf '```\n'
  echo ""
  echo "--- prompt repeated verbatim to aid comprehension... ---"
  echo ""
  sed '/{{__EVENT_DATA__}}/,$ d' "$PROMPT_TEMPLATE"
  echo "$EVENT_BLOCK"
  echo ""
  printf '```json\n'
  echo "$EVENT_JSON"
  printf '```\n'
} > "$ASSEMBLED_PROMPT"
```

**Suitability:** HIGH — this is the single assembly point for all CI runs. One change here affects every orchestrator invocation.

**Impact:** HIGH — reinforces the entire instruction set: clause matching, label applications, memory writes, helper function definitions.

**Risk:** LOW — the prompt is declarative. The `## Match Clause Cases` section contains action steps, but the model processes the prompt as a whole before acting. The separator makes the repetition explicit. The only cost is ~2x token input (current prompt is ~310 lines / ~12K tokens; doubled = ~24K input tokens, well within GLM-5's 200K context).

**Caution:** The EVENT_DATA JSON is also repeated, which is fine — it's data, not an instruction to act. The `/orchestrate-dynamic-workflow` directives inside match clauses are conditional and only execute when the clause logic matches, so repeating the clause definitions doesn't cause double execution.

---

### 2. `orchestrator-agent-prompt.md` — `## Final` Section Repetition

**File:** [.github/workflows/prompts/orchestrator-agent-prompt.md](../.github/workflows/prompts/orchestrator-agent-prompt.md#L293)
**Lines:** 293–302

The `## Final` section contains the mandatory memory-write instructions (`add_observations` / `create_entities`). This is the section most likely to be skipped because:
- It's at the very end of a long prompt
- The model has already completed its primary work (clause execution)
- Token budget pressure increases as the conversation progresses

**Implementation:** Add a repeated copy of the `## Final` section immediately below the original, with a marker:

```markdown
## Final

  - **MANDATORY COMPLETION — WRITE MEMORY NOW**: ...
  - Say goodbye! and finish execution.

--- prompt repeated verbatim to aid comprehension... ---

  - **MANDATORY COMPLETION — WRITE MEMORY NOW**: ...
  - Say goodbye! and finish execution.
```

**Suitability:** HIGH — this section is purely declarative (no actions that could be doubled). The "say goodbye" is idempotent.

**Impact:** MEDIUM — memory writes are important for cross-run context but not pipeline-critical. Missing memory doesn't stall the pipeline; it just makes the next run less informed.

**Risk:** NONE — there's no harm in writing memory twice; `add_observations` is idempotent on existing entities.

---

### 3. `orchestrator-agent-prompt.md` — Label Application Steps

**File:** [.github/workflows/prompts/orchestrator-agent-prompt.md](../.github/workflows/prompts/orchestrator-agent-prompt.md)
**Lines:** Various (each match clause's final `apply label` step)

This directly targets the papa89 failure class. The label application is the single most critical action in each clause — it's what drives the state machine forward. When it's skipped, the pipeline stalls silently.

**Implementation:** After each `apply label` instruction, add a reinforcement line:

```
- apply label "orchestration:epic-complete" to the newly-created epic issue.
- **CRITICAL: verify the label above was applied. If not, apply it now. The pipeline cannot advance without this label.**
```

**Suitability:** MEDIUM — this isn't full prompt repetition, it's targeted reinforcement. It's essentially Solution B from the forensic report.

**Impact:** HIGH — directly addresses the most damaging failure mode (silent pipeline stall).

**Risk:** LOW — the reinforcement is conditional ("if not, apply it now"), so if the label was already applied, this is a no-op check. However, as noted in the papa89 analysis, the model's response may have already terminated before reaching this point, so prompt-level reinforcement may not help if the runtime kills the session.

---

### 4. `.opencode/commands/orchestrate-dynamic-workflow.md` — Instruction Links

**File:** [.opencode/commands/orchestrate-dynamic-workflow.md](../.opencode/commands/orchestrate-dynamic-workflow.md)

This command is invoked every time the orchestrator delegates to a subagent. The subagent must read its instructions from the remote `nam20485/agent-instructions` repo. If it skips reading, it operates without its assignment-specific instructions.

**Implementation:** Repeat the "Core Instructions (REQUIRED)" and "Workflow Assignment Specific Instructions (REQUIRED)" sections:

```markdown
## Core Instructions (**REQUIRED**)
[ai-core-instructions.md](...)

## Workflow Assignment Specific Instructions (**REQUIRED**)
[orchestrate-dynamic-workflow.md](...)
[ai-workflow-assignments.md](...)

--- prompt repeated verbatim to aid comprehension... ---

## Core Instructions (**REQUIRED**)
[ai-core-instructions.md](...)

## Workflow Assignment Specific Instructions (**REQUIRED**)
[orchestrate-dynamic-workflow.md](...)
[ai-workflow-assignments.md](...)
```

**Suitability:** MEDIUM — the content is declarative (links to read), not actions to execute. This invocation pattern is used for every dynamic workflow dispatch.

**Impact:** MEDIUM — ensures the subagent doesn't skip reading its assignment instructions. The most common failure mode is the subagent operating with only partial instructions.

**Risk:** LOW — reading a file twice is harmless. The subagent won't execute the workflow assignment twice because the actual assignment dispatch is in a separate section.

---

### 5. `.opencode/commands/resolve-pr-comments.md` — Completeness Reinforcement

**File:** [.opencode/commands/resolve-pr-comments.md](../.opencode/commands/resolve-pr-comments.md)

This command explicitly instructs "**ALL REVIEW COMMENTS MUST BE ADDRESSED.**" and "**DO NOT SKIP ANY STEPS.**" — but agents frequently address only a subset or skip the GraphQL thread-resolve step.

**Implementation:** Repeat the full prompt section after the steps:

```markdown
--- prompt repeated verbatim to aid comprehension... ---

# Prompt
In PR #$ARGUMENTS, address **ALL** review comments.
**ALL REVIEW COMMENTS MUST BE ADDRESSED.**
...
**DO NOT SKIP ANY STEPS.**
```

**Suitability:** HIGH — this is a known reliability problem. The instructions are purely directive (what to do), not action invocations.

**Impact:** MEDIUM — improves PR comment resolution completeness, which is a quality-of-life improvement for the review cycle.

**Risk:** NONE — the prompt describes a procedure, not a one-shot action. Repeating it reinforces thoroughness without causing double execution.

---

### 6. `.opencode/commands/grind-pr-reviews.md` — Cycle Loop Reinforcement

**File:** [.opencode/commands/grind-pr-reviews.md](../.opencode/commands/grind-pr-reviews.md)

The "grind" loop (assign reviewers → wait → resolve comments → repeat) is a multi-step cycle that agents tend to short-circuit after one iteration.

**Implementation:** Repeat the cycle description after the detailed steps.

**Suitability:** MEDIUM — the cycle is a loop by design, so repeating the loop description reinforces "keep going."

**Impact:** MEDIUM — more thorough PR review grinding.

**Risk:** LOW — the model understands iteration from the loop description. Repetition reinforces "don't stop after one round."

---

### 7. `scripts/assemble-local-prompt.sh` — Local Prompt Repetition

**File:** [scripts/assemble-local-prompt.sh](../scripts/assemble-local-prompt.sh)
**Lines:** ~120-138 (fixture mode assembly)

Mirror of #1 for local testing. If #1 is implemented, this should match for consistency.

**Suitability:** LOW — local testing only. Not production-impacting.

**Impact:** LOW — useful for validating that repetition works locally before deploying to CI.

**Risk:** NONE.

---

### 8. `run_opencode_prompt.sh` — Runtime Prompt Doubling

**File:** [run_opencode_prompt.sh](../run_opencode_prompt.sh)
**Lines:** ~130 (where prompt is loaded and passed to opencode)

Instead of doubling at assembly time (#1), double the prompt string at runtime before passing to `opencode run`.

**Implementation:**
```bash
prompt="${prompt}

--- prompt repeated verbatim to aid comprehension... ---

${prompt}"
```

**Suitability:** LOW — this is a blunt instrument that doubles every prompt, including custom `workflow_dispatch` prompts and freeform local prompts that don't benefit from repetition.

**Impact:** HIGH (same as #1 for CI runs) — but applies to all invocation modes.

**Risk:** MEDIUM — doubles token cost for every prompt, including prompts that don't need it. Custom prompts from `workflow_dispatch` might contain action instructions that shouldn't be repeated. Better to be selective at the assembly point (#1).

---

## Recommended Implementation Order

1. **#1 — `assemble-orchestrator-prompt.sh`** — Highest ROI. Single change, affects all CI runs, reinforces the full instruction set including label applications and memory writes.

2. **#3 — Label application reinforcement** — Targeted fix for the most damaging failure class. Can be done independently of #1.

3. **#5 — `resolve-pr-comments.md`** — Known reliability gap, zero risk, easy to implement.

4. **#2 — `## Final` section** — If #1 is implemented, this is redundant (the Final section is already repeated as part of the full prompt). Only needed if #1 is skipped.

5. **#4 — `orchestrate-dynamic-workflow.md`** — Moderate value, affects every subagent dispatch.

6. **#6, #7, #8** — Lower priority. Implement if the technique proves effective with #1–#5.

## Token Budget Impact

| Scenario | Input Tokens (est.) | Context Budget Used |
|----------|--------------------|--------------------|
| Current (no repetition) | ~12K | 6% of 200K |
| #1 only (full prompt doubled) | ~24K | 12% of 200K |
| #1 + #3 + #5 (recommended set) | ~25K | 12.5% of 200K |
| All opportunities | ~30K | 15% of 200K |

Token overhead is minimal relative to the 200K context window of GLM-5. The conversation itself (tool calls, subagent results, status updates) consumes far more tokens than the prompt doubling.
