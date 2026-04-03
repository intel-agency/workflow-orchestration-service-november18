---
mode: agent
description: 'Assigns agent the `orchestrate-dynamic-workflow` assignment with $workflow_name = `breakdown-plan`'
---

/orchestrate-dynamic-workflow
    - $workflow_name = `breakdown-plan`,
        - $issue_number # (optional)
        - $repo # (optional)

    <!-- - Delegate to the `orchestrator` agent to perform this work. -->
