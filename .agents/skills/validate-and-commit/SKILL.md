---
name: validate-and-commit
description: "Finishing workflow: run validation, update docs with implementation status, group changes into logical commits with meaningful messages, push only agent-changed files (leave unrelated uncommitted files alone). Use when: wrapping up a task, committing work, finalizing implementation, updating task doc status, grouping commits, push changes, finish up, done implementing, ready to commit."
argument-hint: "Optional: describe what was implemented (used to write commit messages and doc summary)"
---

# Validate and Commit

End-of-task finishing workflow. Updates documentation, groups changes into logical commits, and pushes — without touching files you didn't change.

## When to Use

- You've finished implementing something and need to commit + push
- You want the doc (plan, task file, README) updated with what was done
- You need changes split into logical commit groups rather than one giant commit
- You want a clean push that doesn't accidentally stage unrelated files

---

## Procedure

### Step 1 — Survey the workspace

Run `git status --short` and `git diff --stat HEAD` to get the full picture:
- Which files are **modified** (M), **new** (??), or **deleted** (D)?
- What was already staged vs. unstaged?
- Are there files you did NOT touch that should be left alone?

```powershell
git --no-pager status --short
git --no-pager diff --stat HEAD
```

### Step 2 — Update documentation *(optional — skip if no plan/task doc was used)*

**When to do this step**: Only if a plan or task document was created at the start of the task and used to guide the work (e.g., a session `plan.md`, a `docs/feature-name.md`, a task spec, or any doc that listed planned items to implement). If no such doc exists, skip to Step 3.

**How to identify the doc**: Look for a file that was referenced at the start of the task to describe what needed to be done — it may be in `docs/`, the session workspace, or the repo root. If unsure, check the conversation history for when a plan or task file was created or updated.

**What to write**: Update the doc in-place (do not create a new file). Include:

1. **Summary of changes made** — a brief description or table of what was created, modified, or deleted, and what it does.

2. **Status of planned items** — for each item that was planned, mark it as one of:
   - ✅ **Implemented** — done, with a one-line summary of what was produced
   - ⏭️ **Deferred** — not done this session; note why (out of scope, blocked, deprioritised)
   - ❌ **Not implemented** — explicitly decided against; note the reason
   - ⚠️ **Partial** — started but incomplete; note what remains

3. **Issues or deviations** — anything that didn't go as planned: unexpected failures, workarounds applied, scope changes, or follow-up items discovered during implementation.

Keep entries factual and brief. A table or short bullet list per item is ideal. Do not pad — if everything went smoothly and all items are implemented, a simple status table is sufficient.

Only update docs that are part of the task. Never create new markdown files for tracking.

### Step 3 — Identify YOUR changes

Separate files into two buckets:

| Bucket | Action |
|--------|--------|
| Files you created or modified as part of this task | Stage and commit |
| Pre-existing uncommitted files you did NOT touch | Leave unstaged — do NOT `git add .` |

Use `git diff --name-only HEAD` and `git ls-files --others --exclude-standard` to identify candidates. When in doubt about a file, check `git log --follow -- <file>` or skip it.

### Step 4 — Run validation *(REQUIRED — do not commit until this passes)*

> **Nothing may be committed until all validation passes.** This is a hard gate.

Check `AGENTS.md` (or `docs/README.validation.md`, `CONTRIBUTING.md`) for the project's validation conventions — it will specify the exact commands to run. If no such file exists, apply common sense (lint, tests, type-check, build).

**Typical validation sequence:**

```powershell
# 1. Run the project's own validation script (most common pattern)
pwsh -NoProfile -File ./scripts/validate.ps1 -All    # or -Lint, -Test, -Scan individually

# 2. Or run individual tools if no unified script exists
#    e.g. npm test, pytest, go test ./..., dotnet test, etc.
```

**If validation fails:**

1. Read the error output carefully — identify the specific file(s) and rule(s) failing.
2. Fix the issue(s) in the affected files.
3. Re-run the full validation suite (not just the failing check in isolation).
4. Repeat until **all checks pass with zero errors**.
5. Report what failed and what was fixed — include this in the relevant commit message body.

**Do not skip or work around failing checks.** If a check cannot be fixed (e.g., a pre-existing failure unrelated to your changes), document it explicitly and confirm with the user before proceeding.

### Step 5 — Group into logical commits

Think about the *type* and *purpose* of each file changed and form groups. Common groupings:

| Group | Example files |
|-------|--------------|
| **feat** | New source files, scripts, main implementation |
| **test** | Test files, fixtures, test helpers |
| **docs** | README, plan docs, task files |
| **ci** | Workflow YAML, CI config |
| **fix** | Bug fixes, corrections to prior commits |
| **refactor** | Renames, restructuring without behavior change |

**Rule**: 1 group = 1 commit. If only 1–3 files total, one commit is fine.

### Step 6 — Commit each group

For each group:

```powershell
# Stage only the files in this group
git add <file1> <file2> ...

# Commit with a conventional message
git commit --no-gpg-sign -m "<type>(<scope>): <short summary>

<optional body: what and why, not how>

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

**Commit message rules**:
- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `test:`, `docs:`, `ci:`, `refactor:`
- Subject line: imperative mood, ≤72 chars, no period
- Body: explain *what* changed and *why*, not *how*
- Always include the `Co-authored-by` trailer

### Step 7 — Verify before pushing

```powershell
git --no-pager log --oneline -5          # Review commit history
git --no-pager status --short            # Confirm nothing unintentionally staged
git --no-pager diff HEAD                 # Should be empty (or only expected unstaged files)
```

If anything looks wrong (wrong files staged, missing files), fix before pushing.

### Step 8 — Push

```powershell
git push
```

If the branch has no upstream yet:
```powershell
git push -u origin <branch-name>
```

---

## Quality Checks

Before finishing, verify:

- [ ] **Validation passed** — all checks in `AGENTS.md` ran successfully with zero errors
- [ ] Docs updated with implementation summary and item statuses (if a plan/task doc was used)
- [ ] Each commit has a meaningful conventional message
- [ ] No unrelated files were accidentally staged
- [ ] `git status` is clean (or only expected pre-existing uncommitted files remain)
- [ ] Push succeeded

---

## Notes

- **GPG signing failures**: Use `--no-gpg-sign` if the commit hangs waiting for a pinentry prompt.
- **Merge conflicts**: Resolve before running this skill.
- **Active PR**: After pushing, the PR is automatically updated — no separate action needed.
- **Large changes**: If >5 logical groups exist, consider whether some belong in a separate PR.
