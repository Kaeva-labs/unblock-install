# Review rules

Rules for automated code review on this repository:

- Flag any change that removes or weakens a CI check, test, or gate.
- Flag hardcoded secrets, credentials, or tokens in code or config.
- Flag error handling that swallows failures silently (empty catch blocks, ignored exit codes, fail-open paths).
- Flag new network calls or new dependencies not clearly needed by the change.
- Flag workflow edits that change anything beyond what the PR description claims.
- Prefer small, focused PRs; call out unrelated drive-by edits.
