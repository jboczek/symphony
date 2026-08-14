---
name: push
description:
  Push current branch changes to origin and create or update the corresponding
  pull request; use when asked to push, publish updates, or create pull request.
---

# Push

## Goals

- Push current branch changes to `origin` safely.
- Inspect the current branch's active PR with `git prget`.
- Create a missing PR with `git prdesc`, or refresh an active PR's description
  with `git prupdate`.
- Keep branch history clean when remote has moved.

## Related Skills

- `pull`: use this when push is rejected or sync is not clean (non-fast-forward,
  merge conflict risk, or stale branch).

## Steps

1. Identify current branch and confirm remote state.
2. Run local validation (`make -C elixir all`) before pushing.
3. Push branch to `origin` with upstream tracking if needed, using whatever
   remote URL is already configured.
4. If push is not clean/rejected:
   - If the failure is a non-fast-forward or sync problem, run the `pull`
     skill to merge `origin/main`, resolve conflicts, and rerun validation.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If the failure is due to auth, permissions, or workflow restrictions on
     the configured remote, stop and surface the exact error instead of
     rewriting remotes or switching protocols as a workaround.

5. Inspect the current branch's active PR with `git prget`:
   - If it reports `No active PR found`, create one with `git prdesc`.
   - If it returns the active PR JSON, refresh its description with
     `git prupdate`.
   - Stop on any other `git prget` failure; do not treat authentication,
     permission, or service errors as a missing PR.
   - Give a new PR a title that describes its total scope. `git prupdate`
     changes only the description, so stop if the current title is no longer
     accurate.
6. Write/update PR body explicitly using `./references/pull_request_template.md`:
   - Fill every section with concrete content for this change.
   - Replace all placeholder comments (`<!-- ... -->`).
   - Keep bullets/checkboxes where template expects them.
   - Pass the completed body inline to `git prdesc` when creating a PR, or to
     `git prupdate` when refreshing an active PR. It must reflect the total PR
     scope, including newly added work, removed work, or changed approach.
   - Do not reuse stale description text from earlier iterations.
7. Validate PR body with `mix pr_body.check` and fix all reported issues.
8. Reply with the URL printed by `git prdesc` for a new PR, or with the active
   PR details from `git prget` after an update. Add the url as a task comment.

## Commands

```sh
# Identify branch
branch=$(git branch --show-current)

# Initial push: respect the current origin remote.
git push -u origin HEAD

# If that failed because the remote moved, use the pull skill. After
# pull-skill resolution and re-validation, retry the normal push:
git push -u origin HEAD

# If the configured remote rejects the push for auth, permissions, or workflow
# restrictions, stop and surface the exact error.

# Only if history was rewritten locally:
git push --force-with-lease origin HEAD

# Inspect the active PR before deciding whether to create or update it.
# `git prget` emits JSON for an active PR and a specific message when none exists.
pr_title="<clear PR title written for this change>"
if pr_details=$(git prget 2>&1); then
  # Active PR: `git prupdate` preserves its title and reads the body from stdin.
  git prupdate <<'EOF'
<completed PR body with every template section filled in>
EOF
elif [ "$pr_details" = "No active PR found for branch: $branch" ]; then
  # No active PR: the configured alias creates it and prints its web URL.
  git prdesc "$pr_title" <<'EOF'
<completed PR body with every template section filled in>
EOF
else
  printf '%s\n' "$pr_details" >&2
  exit 1
fi

# Show the active PR record after creation or update.
git prget
```

## Notes

- Do not use `--force`; only use `--force-with-lease` as the last resort.
- Distinguish sync problems from remote auth/permission problems:
  - Use the `pull` skill for non-fast-forward or stale-branch issues.
  - Surface auth, permissions, or workflow restrictions directly instead of
    changing remotes or protocols.
- The configured PR aliases target Azure DevOps and operate on the current
  branch. Do not substitute `gh pr` or direct `az repos pr` commands.
