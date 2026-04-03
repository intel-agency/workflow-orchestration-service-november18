# Prompt Repetition Implementation Guide

> **Purpose:** Instructions for implementing prompt repetition in a template-clone repository.
> Copy this file to the target repo's `docs/` directory and provide it to the implementing agent.

## Technique

Repeating instructional/declarative prompt content increases the probability that the model follows all instructions faithfully. The repeated content is separated by a marker line so the model recognizes it as intentional reinforcement, not duplication.

### Separator Token

```
--- prompt repeated verbatim to aid comprehension... ---
```

### Safety Rule

**Only repeat instructional and declarative content.** Never repeat action invocations or dynamic workflow dispatches. For example:
- **SAFE to repeat:** "apply label X", "verify the label was applied", step descriptions, completeness checks
- **NEVER repeat:** `/orchestrate-dynamic-workflow` calls — this would cause the workflow to run twice

## Changes to Implement

### 1. Full Prompt Doubling in `scripts/assemble-orchestrator-prompt.sh`

The assembled prompt is emitted twice in the output file, separated by the comprehension marker.

**Before:**
```bash
{
  sed '/{{__EVENT_DATA__}}/,$ d' "$PROMPT_TEMPLATE"
  echo "$EVENT_BLOCK"
  echo ""
  printf '```json\n'
  echo "$EVENT_JSON"
  printf '```\n'
} > "$ASSEMBLED_PROMPT"
```

**After:**
```bash
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

Also add a diagnostic line in the diagnostics section:
```bash
echo "  Repeat marker:     $(grep -c 'prompt repeated verbatim'  "$ASSEMBLED_PROMPT" || echo 0)"
```

### 2. Label Application Reinforcement in `orchestrator-agent-prompt.md`

After every `apply label "orchestration:*"` instruction in each match clause, add a verification line:

```
- apply label "orchestration:<label-name>" to the newly-created epic issue.
- **CRITICAL: verify the `orchestration:<label-name>` label was applied to the epic issue. If not, apply it now. The pipeline CANNOT advance without this label.**
```

This applies to all five labels:
- `orchestration:epic-ready` (in `plan-approved` and `epic-complete` clauses)
- `orchestration:epic-implemented` (in `epic-ready` clause)
- `orchestration:epic-reviewed` (in `epic-implemented` clause)
- `orchestration:epic-complete` (in `epic-reviewed` clause)

### 3. `resolve-pr-comments.md` Completeness Reinforcement

After the final instruction ("fetch the list again to make sure that there are 0 unresolved comments left"), append:

```markdown
--- prompt repeated verbatim to aid comprehension... ---

In PR #$ARGUMENTS, address **ALL** review comments.

**ALL REVIEW COMMENTS MUST BE ADDRESSED.**

Resolving a review comment means:

1. analyzing the comment
    a. if functionality is working as designed or otherwise no code change is needed, skip to step 4. and explain why no code change is needed.
2. making necessary code changes to address the comment
3. committing/pushing the changes
4. replying to the comment with an explanation of the changes made
5. using the Graphql API to resolve the review comment thread.

**DO NOT SKIP ANY STEPS.**
```

Place this **before** the `<!-- copilot-source: ... -->` comment block.

### 4. Update `test/test-prompt-assembly.sh`

The test's `assemble_prompt()` function must mirror the production assembly logic. Update it to emit the prompt twice with the separator, matching the structure in change #1.

## Token Budget Impact

| Scenario | Input Tokens (est.) | Context Budget Used |
|----------|---------------------|---------------------|
| Before (no repetition) | ~12K | 6% of 200K |
| After (full prompt doubled + reinforcements) | ~25K | 12.5% of 200K |

Overhead is minimal relative to the 200K context window.

## Validation

After implementing all changes, run:

```bash
pwsh -NoProfile -File ./scripts/validate.ps1 -All
```

Specifically verify:
1. `bash test/test-prompt-assembly.sh` passes — confirms the doubled prompt assembles correctly
2. No `{{__EVENT_DATA__}}` placeholder leaks in the output
3. JSON extraction from the assembled prompt still validates with `jq`
