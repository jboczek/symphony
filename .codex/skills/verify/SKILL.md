---
name: verify
description: Verify completed work against explicit requirements using direct traceable evidence and a task-level Pass, Fail, or Inconclusive verdict. Delegate executable implementation review to the `verify-code-review` skill. Use when Codex should determine whether a completed task actually satisfies its requirements and post the verification report back to the current task.
---

# Verify

Determine whether completed work satisfies its requirements.

`Verify` owns:
- requirement resolution;
- atomic verification checks;
- evidence collection for non-code outcomes;
- mapping code-review findings to requirements;
- the task-level `Pass`, `Fail`, or `Inconclusive` verdict;
- posting the final verification report as a comment to the current task.

`verify-code-review` owns semantic review of executable implementation changes. Do not duplicate or depend on its internal review process.

## Safety and boundaries

Keep evaluated work and external systems read-only except for one allowed side effect:

- posting the final verification report as a comment to the current task.

Do not:
- edit source or artifacts being verified;
- stage, commit, reset, checkout, fetch, pull, push, or deploy;
- change configuration or external system state;
- send or repeat business actions merely to obtain proof;
- modify the task except for posting the final verification report.

Inspect existing evidence instead of recreating side effects.

If a required proof cannot be obtained safely, mark the affected check `Inconclusive`.

## Workflow

### 1. Resolve the requirement source

Use this precedence:

1. explicit requirement/specification supplied by the user;
2. requirement/specification linked from the current task;
3. the current task description and request.

Record the selected source.

If requirement sources materially conflict and the conflict affects verification, record the conflict under `Unknowns` and return `Inconclusive`. Do not silently choose the most convenient interpretation.

### 2. Decompose requirements into atomic checks

Split compound requirements into observable obligations and assign stable IDs:

```text
R1
R2
R3
...
```

Each applicable check must have:
- one concise requirement statement;
- direct evidence or a clearly identified missing proof;
- one result:
  - `Pass`
  - `Fail`
  - `Inconclusive`
  - `Not applicable`

Rules:
- `Pass` requires direct evidence that the obligation is satisfied.
- `Fail` requires evidence that the obligation is not satisfied.
- `Inconclusive` means available evidence is missing, ambiguous, stale, conflicting, or unsafe to obtain.
- `Not applicable` is allowed only when the requirement itself makes the condition irrelevant.

Do not treat lack of evidence as `Pass`.

### 3. Collect direct evidence

Choose evidence appropriate to each requirement.

Typical sources:

- **Document/artifact** — inspect the source or rendered result.
- **UI/website** — inspect the existing UI or captured artifact read-only.
- **Data/query** — inspect query logic and existing read-only results.
- **Configuration/deployment** — inspect current configuration, resource state, or health information without changing it.
- **External message/action** — inspect an existing connector/API/audit/task record; do not repeat the action.
- **Executable implementation** — delegate semantic implementation review to `verify-code-review`.

Use the closest direct evidence available.

Evidence should be traceable using a concise locator such as:
- file and line/symbol;
- task/comment/message ID;
- artifact/path;
- query/result locator;
- resource/property;
- URL or UI location;
- `verify-code-review` finding ID.

If direct proof remains unavailable, mark the check `Inconclusive`.

### 4. Route executable work to `verify-code-review`

If any applicable requirement concerns:
- source code;
- scripts;
- tests;
- generated code;
- executable configuration or configuration logic;

invoke `verify-code-review` as a mandatory nested review.

Pass:
- the resolved requirement source;
- the relevant atomic requirement IDs and text;
- any explicit user-supplied base/head or review-scope constraint;
- `nested=true`, so the review returns structured findings without posting a separate task report.

Do not independently resolve or redefine the implementation diff. `verify-code-review` owns implementation review scope and semantic code review.

Do not run build, test, lint, formatter, generator, migration, or deployment commands from `Verify`. Assume implementation-time validation is handled by the implementation workflow or CI unless the current task already exposes existing validation results that can be inspected read-only.

If existing PR/CI validation results are available, they may be used as supporting evidence. Their absence alone does not automatically make verification inconclusive unless a requirement explicitly requires that validation.

If `verify-code-review` is unavailable or returns `Review status: Inconclusive`, continue other safe verification checks but do not allow an overall `Pass` for executable work that required review.

### 5. Map code-review findings to requirements

Do not automatically convert every technical finding into a failed task.

For each `verify-code-review` finding:

- map it to one or more requirement IDs only when the evidence supports the relationship;
- mark a requirement `Fail` when the finding proves the requirement is not satisfied;
- mark a requirement `Inconclusive` when the finding exposes a material unresolved risk that prevents reliable verification;
- otherwise retain the finding in the final report without inventing a requirement failure.

A code review may be `Complete` and still contain findings.

### 6. Roll up the task verdict

Across all applicable atomic requirements:

1. `Fail` if any applicable requirement is `Fail`.
2. Otherwise `Inconclusive` if:
   - any applicable requirement is `Inconclusive`;
   - executable work required `verify-code-review` and that review was unavailable or `Inconclusive`;
   - no applicable requirement passed.
3. Otherwise `Pass`.

All-`Not applicable` results produce `Inconclusive`.

The task-level verdict belongs only to `Verify`.

### 7. Create the final report

Produce one concise Markdown verification report:

```markdown
# Verification report — <task>

- Verdict: Pass | Fail | Inconclusive
- Requirement source: <path, task, specification, or request>
- Scope: <short description of what was verified>

## Requirements

- [Pass] R1 — <atomic requirement>
  - Evidence: <short direct locator>

- [Fail] R2 — <atomic requirement>
  - Evidence: <short direct locator>

## Findings

- [Critical|High|Medium|Low] F1 — <location>: <problem>
  - Recommendation: <smallest concrete next step>

## Unknowns

- <missing, conflicting, stale, ambiguous, or unavailable evidence>

## Code review

- Status: Complete | Inconclusive | Not required
- Scope: <PR / branch / explicit revisions / not required>
- Findings: <count or none>
```

Rules:
- omit `Findings` when there are no findings;
- omit `Unknowns` when there are no unknowns;
- omit implementation details of how `verify-code-review` performed its review;
- keep evidence pointers short and traceable;
- do not duplicate large diffs, logs, task descriptions, or artifacts.

### 8. Post the report to the current task

Post the complete Markdown verification report as a new comment on the task under which `Verify` is running.

This is the only allowed external write.

Do not:
- edit an existing verification comment;
- change task status;
- add labels;
- assign users;
- create subtasks;
- post additional review comments.

If posting the comment fails, do not change the verification verdict. Return the report in the handoff and explicitly state that task-comment delivery failed.

### 9. Return a short handoff

After posting the report, return only:

```text
Verdict: <Pass | Fail | Inconclusive>
<most important blocker, finding, or "No blocking issues found.">
Report posted to task: <task reference>
```

If posting failed:

```text
Verdict: <Pass | Fail | Inconclusive>
<most important blocker, finding, or "No blocking issues found.">
Report could not be posted to the task: <reason>
```
