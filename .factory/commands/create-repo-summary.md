---
description: Analayzes repository and creates repository summary file
---

## Overview

1. Read [`ai_instruction_modules/ai-creating-repository-summary.md`](https://github.com/nam20485/agent-instructions/blob/main/ai_instruction_modules/ai-creating-repository-summary.md)
2. Analyze current repo
3. Generate current repo-specific summary based on `ai-creating-repository-summary.md` and analyzed information
4. Write to file

## Detailed Steps:

- Place the current repository's URL into a variable hereafter refferred to as `${var:__current_repo_url}`
- Always replace the variable `${var:__current_repo_url}` with the actual URL of the current repository when using it in any output, file content, or paths
- Add the generated repository summary to a file called '.ai-repo-summary.md` located at the root of the current repository
- Instructions for creating the custom repository instructions can be found in a file called `ai-creating-repository-summary.md`
- `ai-creating-repository-summary.md` file can be found in a directory called `ai_instruction_modules` which is located at the root of the current repository
- If repository summary file already exists for this current repository, list a link the existing file, ask the user if they want to re-create
    - If they want to re-create:
        - When finished generating but before writing to the exisitng file, confirm that the user wants over-write the file
        - When overwriting, create a backup of the existing file by copying it a new file with `.bak (*current date/time stamp)` appended to end
- Record completion status back to user.

## Runtime Flow (pseudo):
1. Detect path: ./ai-repo-summary.md
2. If exists:
   a. Output notice with link (${var:__current_repo_url}/blob/HEAD/ai-repo-summary.md)  
   b. Ask: "Regenerate? (yes/no)"
   c. If no -> stop.
   d. If yes -> generate new content (do not write yet), show diff summary (line counts).
   e. Ask: "Overwrite? (yes/no)"
   f. If yes -> backup original to ai-repo-summary.md.bak-YYYYMMDD-HHMMSS; then write.
3. If not exists: generate then write.
4. Report success + backup path if created.

## Backup Filename Pattern:
ai-repo-summary.md.bak-<UTC-YYYYMMDD-HHMMSS>

## Notes:
- Never lose original without .bak creation when overwriting.
- Keep variable ${var:__current_repo_url} instead of hardcoding duplicates.
