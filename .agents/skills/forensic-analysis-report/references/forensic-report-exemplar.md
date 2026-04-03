# Forensic Report Exemplar

> Use this as the canonical report shape for the `forensic-analysis-report` skill.
> 
> This is an **annotated exemplar**: each section includes guidance explaining what belongs there, what evidence standard to meet, and how to write it.

---

# <Incident or Topic> — Forensic Report

> **Date:** YYYY-MM-DD  
> *What goes here:* The report date, usually when the analysis was completed.
>
> **Scope:** <repo / workflow / workflow run / multi-repo comparison>  
> *What goes here:* The investigation boundary. Be explicit so readers know what was and was not analyzed.
>
> **Affected targets:** <repo(s), workflow(s), run(s)>  
> *What goes here:* Name the impacted repositories, workflows, runs, or environments.
>
> **Pattern confirmed:** <Yes / No / Mixed> — <short verdict>  
> *What goes here:* A one-line answer to the pattern question if one was investigated, e.g. whether several recent failures share the same class.

---

## 1. Executive Summary

*What goes here:* A concise, decision-ready summary. Answer three things in plain language:*

- *What happened?*
- *What is the most likely root cause?*
- *What should be done next?*

*Write this for a reader who may only read one section of the report.*

Example:

> The last 5 failures were all idle-timeout terminations during subagent delegation in the PR review phase. Evidence across multiple runs shows the watchdog stops seeing qualifying activity after the subagent enters a quiet wait state, even though the orchestration flow has not logically completed. The recommended next step is a phased watchdog hardening change: raise the timeout immediately, then improve the activity signal.

---

## 2. Forensic Evidence

*What goes here:* The factual basis for the report. This section should be evidence-heavy and interpretation-light.*

### 2.1 Failure Inventory

*What goes here:* A table of the investigated failures or incidents. Use one row per run/incident.*

| # | Repo / Workflow | Run ID / Artifact | Date (UTC) | Stage Reached | Last Meaningful Output | Duration / Idle Gap | Exit / Result |
|---|------------------|-------------------|------------|---------------|------------------------|---------------------|---------------|
| 1 | <repo> | <run> | <timestamp> | <stage> | <last output> | <duration> | <exit/result> |
| 2 | <repo> | <run> | <timestamp> | <stage> | <last output> | <duration> | <exit/result> |

*Include enough columns to support pattern claims later.*

### 2.2 Exceptions / Non-Matching Cases

*What goes here:* Any counterexamples, outliers, or adjacent failures that do **not** match the main pattern. This prevents overclaiming.*

Example prompts for yourself:

- *Were there failures caused by permissions instead?*
- *Were there missing-image or config failures mixed in?*
- *Did any runs succeed under similar conditions?*

### 2.3 Success / Baseline Context

*What goes here:* The comparison context that helps quantify the problem. Examples include success rates, unaffected phases, or prior known-good behavior.*

Suggested content:

- success/failure split
- which steps consistently succeed
- whether the problem is isolated to one phase
- whether it is new or recurring

---

## 3. Root Cause Analysis

*What goes here:* The analytical core of the report. Move from immediate cause to deeper mechanism. Keep evidence references concrete.*

### 3.1 Immediate Cause

*What goes here:* The direct trigger of the failure.*

Examples:

- watchdog terminated the process after 15 minutes of no qualifying activity
- token lacked `read:org`
- workflow failed because the devcontainer image did not exist

*This should usually map closely to the final annotation, exit code, or error message.*

### 3.2 Mechanism

*What goes here:* Explain **how** the system got from normal operation to failure. Walk the reader through the causal chain step by step.*

Good pattern:

1. *System performed action A*
2. *That led to state B*
3. *The monitoring / workflow logic interpreted B as failure condition C*
4. *Termination or failure outcome followed*

### 3.3 Why This Area Is Fragile

*What goes here:* The structural reason this class of failure is likely to recur unless hardened. This is where you identify systemic design weakness, not just the one-run symptom.*

Examples:

- monitoring signal is an imperfect proxy
- orchestration phase depends on quiet external waits
- retry logic exists but observability is weak
- clause matching relies on fragile title parsing

### 3.4 Confidence / Uncertainty Notes

*What goes here:* Be explicit about what is directly proven versus strongly inferred.*

Suggested phrasing:

- *Directly observed in logs: ...*
- *Strongly inferred from timing and repeated signatures: ...*
- *Not yet proven without deeper instrumentation: ...*

---

## 4. Solutions with Pros/Cons

*What goes here:* A set of realistic response options. Include more than one credible path.*

### Solution A: <short name>

**Change:** <one-paragraph description of what would be changed>

| Pros | Cons |
|------|------|
| <benefit> | <tradeoff> |
| <benefit> | <tradeoff> |

**Implementation notes:**

*What goes here:* Practical notes, snippets, rollout concerns, or effort estimates.

---

### Solution B: <short name>

**Change:** <what would change>

| Pros | Cons |
|------|------|
| <benefit> | <tradeoff> |
| <benefit> | <tradeoff> |

**Implementation notes:**

*What goes here:* Operational details, compatibility concerns, or why this is medium-term instead of immediate.*

---

### Solution C: <short name>

**Change:** <what would change>

| Pros | Cons |
|------|------|
| <benefit> | <tradeoff> |
| <benefit> | <tradeoff> |

**Implementation notes:**

*What goes here:* Use this when a third option is valuable for contrast, such as a strategic or architectural alternative.*

---

## 5. Recommendation

*What goes here:* State the recommended option or phased plan, then explain **why this one** is preferred over nearby alternatives.*

Suggested structure:

### Recommended Path

1. *Immediate mitigation*
2. *Short-term hardening*
3. *Longer-term structural fix (if needed)*

### Why This Recommendation

*Answer explicitly:*

- *Why is it the best fit now?*
- *What evidence supports it?*
- *What does it fix directly?*
- *What does it leave unresolved?*
- *Why not the other leading options?*

Example:

> Recommend a phased fix: increase the timeout now to stop the bleeding, then improve the activity signal so the watchdog measures real work rather than a narrow proxy. This balances urgency, risk, and correctness better than either a timeout-only band-aid or a large architectural rewrite.

---

## 6. Appendix

*What goes here:* Supporting signatures, excerpts, repeatable fingerprints, or additional detail that strengthens the report without cluttering the main sections.*

### 6.1 Raw Error Signatures

*What goes here:* Exact or near-exact error text that operators can grep for later.*

```text
<example error line or signature>
```

### 6.2 Representative Last-Known-Good / Last-Known-Bad Output

*What goes here:* Short excerpts showing the transition point just before failure.*

```text
<example pre-failure output>
```

### 6.3 Sources Consulted

*What goes here:* A bullet list of the concrete evidence sources used.*

- workflow runs: <run IDs or links>
- files: `<path>`
- issues / PRs: <numbers>
- logs / annotations / artifacts: <which ones>

---

## Authoring Rules for This Exemplar

- Keep **evidence** and **interpretation** visibly separate
- Quantify patterns whenever possible
- Include exceptions and non-matching cases
- Prefer specific references over vague claims
- Recommendations must include a **why**, not just a preference
- If a section is not applicable, say so explicitly instead of dropping it silently
