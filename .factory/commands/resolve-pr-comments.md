# resolve-pr-comments

Review and resolve all PR comments on specified PR.

## Arguments
- `PR_NUMBER`: The GitHub PR number

## Steps

- Checkout PR
    - `gh pr checkout [PR_NUMBER]`


- Create TODO Plan Document (`docs/p0lan/PR-[PR_NUMBER]-TODO-PLAN.md`)

- Plan has two sections:

   - Complete PR Comment Status List (ALL PR comments)
      - List: checkbox, comment ID, comment text
   - Unresolved Comments List (ONLY unresolved comments)
      - List: checkbox, comment ID, comment text, resolution plan (or will not fix if behavior is as-designed)

- Foreach unresolved comment in the Unresolved Comments List:

1. Apply Fix (or mark as "will not fix" if behavior is as-designed)   
   - If "will not fix/works as designed": skip rest of steps and move to next comment
2. Test the Fix
   - Compile the code
   - Run relevant tests & valdiate expected behavior 
3. Commit and Push      
4. Reply to Comment
   - Explain the change made (or reason for "will not fix")
5. Mark Comment Thread as Resolved
   - Use GraphQL mutation: `markPullRequestReviewThreadAsResolved`
   - Or use GitHub CLI: `gh api graphql -f query='...'`
   - **CRITICAL: Do not skip this step**
6. Update Progress: mark checkboxes in TODO Plan document   

7. Continue to Next Comment - Repeat steps 1-6
   
## Error Handling

- If PR checkout fails: Verify PR number and permissions
- If comment can't be resolved: Check GitHub API permissions
- If fix breaks tests: Revert and reassess approach
- If GraphQL mutation fails: Use GitHub CLI or web interface as fallback

## DO NOT FORGET:
- Always compile, build, & test fixes before committing
- Double-check that threads are marked resolved on GitHub (use GraphQL mutation or GitHub CLI)
