---
name: verify-code-review
description: Review committed implementation changes against requirements and material technical risks. Prefer the active pull request as the review scope when available, but if the current branch has local commits beyond the PR head, review the local branch tip because those commits are still part of the same PR work. Otherwise compare the current branch with the repository primary branch. Use one reviewer only. Use when Codex should independently review implementation changes or when review is nested inside verify.
---

# Code Review

Review the implementation as one senior engineer. Do not implement fixes and do not issue the task-level verdict.

When nested under `verify`, return structured review data to `verify`; `verify` owns `Pass`, `Fail`, or `Inconclusive`.

## Safety and boundaries

Keep the repository and external systems read-only.

Allowed:
- read repository files and applicable guidance;
- run read-only Git commands;
- read pull-request metadata through an already available provider CLI;
- inspect code outside the changed files when needed to understand changed behavior, contracts, call sites, tests, or nearby conventions.

Do not:
- edit, stage, commit, reset, checkout, fetch, pull, push, deploy, or change configuration;
- create or update pull requests, comments, votes, labels, work items, or other external state;
- install missing tools or extensions;
- widen the reviewed implementation scope because additional repository context was inspected;
- report unrelated pre-existing issues.

Repository context may be broad. The reviewed implementation scope must remain fixed.

## Workflow

### 1. Resolve requirements

When nested under `verify`, use the requirement context and mechanical-validation summary supplied by `verify` unchanged.

For standalone review, resolve requirements in this order:
1. explicit requirements or specification supplied by the user;
2. linked repository-backed task/specification;
3. the current request.

If no meaningful requirement exists but the user explicitly requested a technical review, continue and mark requirement alignment as unknown.

If requirement sources materially conflict and the conflict affects the review, record it under `Unknowns` and return `Review status: Inconclusive`.

### 2. Read repository guidance

Read relevant repository guidance before reviewing, for example:
- `AGENTS.md`;
- contribution or coding standards;
- language/framework configuration;
- nearby conventions relevant to the changed implementation.

Use repository-specific evidence over generic style preferences.

### 3. Freeze the implementation scope

Prefer immutable commit SHAs.

If explicit `base` and `head` revisions were supplied, use them.

Otherwise:

#### GitHub

When `gh` is available and the current branch has an open pull request, inspect:

```bash
gh pr view --json number,url,state,baseRefName,baseRefOid,headRefName,headRefOid
```

Use `baseRefOid` as `base_sha`.

Then check whether the current branch tip contains additional local commits beyond the PR head:

```bash
git rev-list --left-right --count <headRefOid>...HEAD
```

- If `HEAD` is ahead of the PR head, treat those local commits as part of the same PR work and set `head_sha` to `HEAD`.
- Otherwise keep `headRefOid` as `head_sha`.

This prevents a stale remote PR head from hiding new local commits that are still part of the same branch/PR.

#### Azure DevOps

When the repository remote is Azure DevOps and `az repos` is already available, inspect the active pull request for the current branch:

```bash
# Show the active PR record after creation or update.
git prget
```

Use the PR target/source commit IDs from the returned PR metadata as `base_sha` and `head_sha`, but apply the same rule: if the local branch tip has additional commits beyond the PR head, use `HEAD` as the effective `head_sha`.

If more than one active PR matches the current branch, do not guess. Record the ambiguity and return `Inconclusive` unless explicit revisions were supplied.

#### Local Git fallback

If no active PR can be resolved, compare `HEAD` with the repository primary branch.

Resolve the primary branch in this order:
1. `review.primaryBranch`;
2. `repository.primaryBranch`;
3. `refs/remotes/origin/HEAD`;
4. locally available `main`, `master`, `origin/main`, or `origin/master`.

Do not fetch missing refs.

Resolve both sides to commit SHAs and calculate:

```bash
git merge-base <base_sha> <head_sha>
```

Freeze:
- `base_sha`;
- `head_sha`;
- `merge_base_sha`;
- changed files from:

```bash
git diff --name-status --find-renames <merge_base_sha> <head_sha>
```

The reviewed changes are exactly:

```bash
git diff <merge_base_sha> <head_sha>
```

Do not independently change this scope later in the review.

If the scope cannot be resolved safely, return `Review status: Inconclusive`.

An empty diff is valid evidence of an empty scope, but it cannot produce a passing task verification.

### 4. Use mechanical validation from verify

When nested under `verify`, use the supplied build/test/lint results as evidence.

Do not rerun build, tests, lint, formatters, generators, migrations, or other commands that may write repository state.

For standalone review, mechanical validation may remain `unknown`.

### 5. Review the implementation

Act as one senior reviewer. Inspect the diff and read any repository files needed to understand it.

Consider all dimensions below, but report only material findings. Do not create findings merely to fill a category.

#### Requirements and scope
- Does the implementation satisfy the requested behavior?
- Is anything required missing, partial, contradictory, or unintentionally out of scope?
- Are public behavior or contracts changed without corresponding requirement support?

#### Correctness and logic
- Control flow, state transitions, invariants, and data flow.
- Null, empty, boundary, invalid, timeout, cancellation, and partial-failure paths when relevant.
- Error handling and unintended behavior changes.
- Regression risk introduced by the change.

#### Tests and reliability
- Do tests protect the changed behavior and important edge cases?
- Are assertions meaningful and deterministic?
- Is failure handling sufficient?
- Are retries, idempotency, ordering, concurrency, recovery, or cancellation relevant and handled correctly?
- Is the change diagnosable in production when that matters?

#### Design and maintainability
- Cohesion and responsibility boundaries.
- Consistency with repository architecture and nearby code.
- Changeability and unnecessary complexity.
- Language/platform idioms supported by repository evidence.
- Naming or readability only when they create material maintenance risk.

#### Performance
- Plausible hot paths.
- CPU, allocation, I/O, queries, network calls, batching, caching, backpressure, concurrency limits, and resource exhaustion.
- Report only issues with a concrete mechanism and plausible operational impact.

#### Security
- Authentication and authorization.
- Trust boundaries and untrusted input.
- Injection or unsafe parsing.
- Secrets or sensitive data.
- Logging/error disclosure.
- Abuse resistance where relevant.

#### Compatibility and data
- Public APIs, events, serialization formats, schemas, migrations, and persisted data.
- Producer/consumer or old/new version compatibility.
- Data loss or irreversible transformation risk.

### 6. Findings rules

Report only issues caused or exposed by the frozen changed scope.

Do not report:
- unrelated pre-existing issues;
- generic best-practice suggestions without concrete impact;
- speculative performance/security concerns without a clear mechanism;
- cosmetic style preferences.

Use these severities:
- `Critical`: blocks safe use or risks severe harm;
- `High`: risks major failure, security incident, data loss, or clear requirement breach;
- `Medium`: material but bounded correctness, maintenance, operational, or compatibility risk;
- `Low`: limited risk or a small improvement worth addressing.

For every finding include:
- severity;
- location;
- concise problem statement;
- evidence explaining why it matters;
- concrete recommendation.

Prefer precise file/line citations when stable. Otherwise cite the relevant file, symbol, requirement, or diff behavior.

### 7. Review status

`Review status: Complete` means:
- the scope was resolved and frozen;
- the relevant requirements and repository guidance were available or explicitly marked unknown;
- the review covered all applicable dimensions above;
- no material evidence required for the review remains unavailable.

`Complete` does not mean approved and may contain findings.

Use `Review status: Inconclusive` when missing, stale, ambiguous, or contradictory evidence prevents a reliable review.

### 8. Return structured result

When nested under `verify`, return:

```text
Scope:
- Source: pull-request | primary-branch | explicit
- Base: <sha>
- Head: <sha>
- Merge base: <sha>
- Changed files: <count>

Validation:
- <mechanical validation supplied by verify, or unknown>

Findings:
- F1 [Critical|High|Medium|Low] <location>
  - Summary: ...
  - Evidence: ...
  - Recommendation: ...

Unknowns:
- <material unavailable/ambiguous evidence, or none>

Review status: Complete | Inconclusive
```

If there are no findings, return:

```text
Findings: none
```

Do not issue `Pass`, `Fail`, `Approve`, or `Reject`.

### 9. Standalone report

When invoked standalone, write one fresh concise Markdown report under `.agent-output/`. Never overwrite an existing report.

Use:

```markdown
# Code review — <task>

- Scope: <source>; <merge-base>..<head>
- Requirement source: <path/request/unknown>
- Review status: Complete | Inconclusive

## Findings

- [High] F1 — <location>: <problem>
  - Evidence: <evidence>
  - Recommendation: <next step>

## Unknowns

- <unknown or none>
```

Return only a short chat summary and the report path after writing the standalone report.
