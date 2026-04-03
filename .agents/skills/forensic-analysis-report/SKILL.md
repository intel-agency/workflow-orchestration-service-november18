---
name: forensic-analysis-report
description: >-
  Investigate a repository, workflow, or workflow run and produce a structured
  forensic markdown report with evidence-backed root cause analysis, solution
  options with pros and cons, and recommendations with rationale.
  Use when: analyzing a failing GitHub Actions workflow, investigating repeated
  regressions, auditing a repo-wide failure pattern, writing a post-mortem from
  run logs, or turning workflow/run evidence into a decision-ready report.
---

# Forensic Analysis Report

## What I Do

- Investigate evidence across a **repo**, a **workflow**, or a specific **workflow run**
- Build a timeline and failure inventory from concrete artifacts and logs
- Separate observed evidence from inference so the report stays defensible
- Produce a markdown document in a consistent format matching the bundled exemplar
- Compare multiple solution options using explicit pros/cons tables
- Finish with a recommendation section that explains **why** the chosen path is best

## Inputs

Expected inputs:

- `${repo}` — repository slug or URL, or current repo if omitted
- `${content}` — one of:
  - `repo` — investigate a repository-level pattern across multiple runs/issues/PRs
  - `workflow` — investigate a specific workflow across runs
  - `workflow run` — investigate one concrete run in depth
- Optional scoping details:
  - workflow name or path
  - run ID(s)
  - time range
  - suspected pattern to verify
  - output path

If the scope is ambiguous, ask only the minimum clarifying questions needed to identify the target and evidence boundary.

## Output

Produce a markdown report that follows the same structure and quality bar as the exemplar:

- title + metadata block
- executive summary
- forensic evidence
- root cause analysis
- solutions with pros/cons
- recommendation + why
- appendix with raw signatures or notable traces when helpful

Use the bundled reference file as the target shape:

- [`references/forensic-report-exemplar.md`](./references/forensic-report-exemplar.md)

That reference is not just a template; it explains **what belongs in each section**, what evidence quality is expected, and how to avoid mixing fact with speculation.

When drafting the final report, actively map your findings into the exemplar’s sections rather than inventing a new structure. The exemplar is the canonical reference for:

- section order
- expected depth per section
- table shapes for evidence and solution comparisons
- the distinction between observed facts, inference, and recommendation

## Workflow

### 1. Define the Investigation Scope

Classify the request into one of three modes:

- **Repo mode** — multiple failures, trend analysis, pattern detection
- **Workflow mode** — one workflow across several runs
- **Run mode** — one concrete run or incident

Then identify:

- target repo
- target workflow(s)
- target run(s)
- comparison window
- suspected failure pattern (if any)

### 2. Build an Evidence Inventory

Gather evidence first, analysis second.

Potential sources:

- workflow run list and durations
- failed logs and annotations
- issue and PR state tied to the runs
- labels, milestones, comments, and triggering events
- relevant scripts, prompts, workflows, and watchdog logic in the codebase
- recent changes that may explain regressions

For each claim you intend to make later, make sure you can point back to:

- a run ID
- a file path
- a log line/time range
- an issue/PR number
- or a directly observed behavior

### 3. Reconstruct the Failure Timeline

Create a chronological narrative from the evidence:

- what started
- what succeeded
- what failed
- what happened immediately before failure
- whether the same signature repeats in adjacent runs

If multiple runs are involved, compare:

- trigger type
- stage reached before failure
- last meaningful output
- duration before termination
- exit codes / annotations

### 4. Test the Pattern Hypothesis

If the user suspects a pattern, explicitly test it.

Examples:

- “Are the last few failures all idle timeouts?”
- “Did every failure happen after subagent delegation?”
- “Is this a permissions failure or only one outlier?”

Report both:

- supporting evidence
- disconfirming evidence / exceptions

If the pattern is real, say so plainly.
If it is mixed, quantify the split.

### 5. Identify Root Cause Levels

Separate findings into layers:

- **Immediate cause** — what directly caused the failure
- **Mechanistic cause** — why the system behaved that way
- **Structural cause** — why this area keeps failing or is fragile

Avoid overstating certainty. If a root cause is strongly inferred but not directly proven, label it as such.

### 6. Generate Solution Options

Provide multiple plausible solutions, not just the favorite.

For each option include:

- what would change
- why it could work
- pros
- cons
- risk / effort / time-to-value if relevant

Good options differ in tradeoff profile, e.g.:

- immediate mitigation
- medium-term hardening
- architectural fix

### 7. Recommend and Justify

Recommend one option or a phased combination.

The recommendation must answer:

- why this is the best fit now
- what it addresses directly
- what it leaves unresolved
- why it is better than the nearby alternatives

### 8. Write the Final Report

Use the exemplar’s structure and section order unless the user explicitly wants a different format.

If saving to disk, prefer a descriptive filename such as:

- `docs/<topic>-forensic-report.md`
- `docs/<workflow>-failure-analysis.md`
- `docs/<run-id>-postmortem.md`

## Decision Rules

### When to use repo mode

Use repo mode when:

- the user asks whether failures form a pattern
- multiple repos or clone instances must be compared
- the recommendation concerns systemic hardening

### When to use workflow mode

Use workflow mode when:

- the problem centers on one workflow definition
- the same workflow behaves differently across runs
- configuration or orchestration logic is the likely source

### When to use run mode

Use run mode when:

- the user wants a deep dive on one incident
- one run contains enough evidence to explain the failure
- the incident is unusual or not clearly part of a trend

## Quality Bar

Before finalizing, verify:

- [ ] Every major conclusion is backed by specific evidence
- [ ] The report clearly distinguishes evidence from interpretation
- [ ] The pattern claim is quantified, not hand-wavy
- [ ] At least two solution paths are considered
- [ ] The recommended path explains **why this one**
- [ ] The final markdown closely follows the exemplar structure

## Reference Bundle

Use these bundled references while drafting:

- [`references/forensic-report-exemplar.md`](./references/forensic-report-exemplar.md) — canonical output scaffold with section-by-section guidance and annotated example content

Always consult the exemplar before writing the final markdown document if the user asks for a formal report, post-mortem, root-cause analysis, or recommendation memo.

## Example Prompts

- `/forensic-analysis-report repo=intel-agency/workflow-orchestration-queue-delta61 content=workflow`
- `/forensic-analysis-report repo=intel-agency/ai-new-workflow-app-template content=repo`
- `/forensic-analysis-report repo=intel-agency/workflow-orchestration-queue-kilo57 content="workflow run"`
- `Investigate whether the last few failures in this workflow are all the same class of timeout and write a forensic report`

## Notes

- Start broad, then narrow: inventory first, root cause second
- Repeated failures should be compared side-by-side in a table whenever possible
- Recommendations should favor operational usefulness over theoretical perfection
- If an exemplar section is not applicable, explicitly state why instead of silently omitting it
