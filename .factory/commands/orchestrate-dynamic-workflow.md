---
mode: 'agent'

tools: ['githubRepo', 'testFailure', 'think', 'search', 'usages', 'vscodeAPI', 'problems', 'changes', 'fetch', 'runTests', 'add_comment_to_pending_review', 'add_issue_comment', 'add_sub_issue', 'create_and_submit_pull_request_review', 'create_branch', 'create_issue', 'create_or_update_file', 'create_pending_pull_request_review', 'create_pull_request', 'delete_file', 'delete_pending_pull_request_review', 'get_commit', 'get_file_contents', 'get_issue', 'get_issue_comments', 'get_job_logs', 'get_pull_request', 'get_pull_request_comments', 'get_pull_request_diff', 'get_pull_request_files', 'get_pull_request_reviews', 'get_pull_request_status', 'get_workflow_run', 'get_workflow_run_logs', 'get_workflow_run_usage', 'list_branches', 'list_commits', 'list_issues', 'list_pull_requests', 'list_sub_issues', 'list_workflow_jobs', 'list_workflow_run_artifacts', 'list_workflow_runs', 'list_workflows', 'merge_pull_request', 'push_files', 'remove_sub_issue', 'reprioritize_sub_issue', 'rerun_failed_jobs', 'rerun_workflow_run', 'run_workflow', 'search_code', 'search_issues', 'search_pull_requests', 'search_repositories', 'submit_pending_pull_request_review', 'update_issue', 'update_pull_request', 'edit', 'runCommands', 'sequential-thinking', 'memory', 'filesystem']
description: 'Assigns agent the `orchestrate-dynamic-workflow` assignment with provided inputs: $workflow_name'
---

You have been assigned the `orchestrate-dynamic-workflow` assignment with input variables: $workflow_name

## Input

1. ${input:workflow_name}: string

>Example:

## Instructions

- Your custom instructions are located in the files inside of the [nam20485/agent-instructions](https://github.com/nam20485/agent-instructions) repository
- Look at the files in the `main` branch
- Start with your core instructions (linked below)
- Then follow the links to the other instruction files in that repo as required or needed.
- You will need to follow the links and read the files to understand your instructions
- Some files are **REQUIRED** and some are **OPTIONAL**
- Files marked **REQUIRED** are ALWAYS active and so must be followed and read
- Otherwise files are optionally active based on user needs and your assigned roles and workflow assignments

## Core Instructions (**REQUIRED**)
[ai-core-instructions.md](https://github.com/nam20485/agent-instructions/blob/main/ai_instruction_modules/ai-core-instructions.md)

## Workflow Assignment Specific Instructions (**REQUIRED**)
[orchestrate-dynamic-workflow.md](https://github.com/nam20485/agent-instructions/blob/main/ai_instruction_modules/ai-workflow-assignments/orchestrate-dynamic-workflow.md)

[ai-workflow-assignments.md](https://github.com/nam20485/agent-instructions/blob/main/ai_instruction_modules/ai-workflow-assignments.md)

## Workflow Assingment ## 

- Perform the `orchestrate-dynamic-workflow` assignment with $workflow_name variable provided as input. 
- Delegate to the `orchestator` agent to perform this work.

