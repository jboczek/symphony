---
title: Task execution worktrees and automatic context management
summary: Add Todoist task overrides, repository worktrees, Blocked workflow state, and durable checkpoint-compaction recovery.
status: done
---

# Task execution worktrees and automatic context management

## tldr;

Allow each Todoist task to select a local repository, Codex model, and reasoning effort in YAML
front matter; run it in a readable isolated Git worktree; and automatically checkpoint durable state
to Todoist before compacting and resuming a thread whose active context reaches 70%.

## Scope

- Parse optional `symphony.repo`, `symphony.model`, and `symphony.thinking` values from YAML front
  matter at the beginning of a Todoist description while keeping YAML concerns isolated.
- Resolve repository names as direct children of a configurable local repository root required by
  Todoist workflows, with exact matching and traversal protection.
- Use one independent Git branch/worktree per repository-backed task; reuse worktrees by stable task
  identity, clean them up through Git, and never mutate or remove a primary working tree.
- Name new workspaces `<source>-<stable-task-id>-<safe-title-slug>` without making title text part of
  workspace identity.
- Apply task model/reasoning overrides through Codex App Server and validate them against
  `model/list` metadata when available.
- Add non-dispatchable Todoist state `Blocked`, distinct from `HumanReview`, and record the blocker,
  reason, and exact required human action before moving a task there.
- Monitor `thread/tokenUsage/updated` using current-context tokens and `modelContextWindow`, not
  cumulative lifetime usage.
- At a configurable threshold, wait for the active turn boundary, run an explicit local checkpoint
  skill, verify a new durable Todoist checkpoint comment, compact the same thread, and resume from
  the newest checkpoint.
- Expose resolved task, repository, worktree, branch, model, reasoning, context, checkpoint, and
  compaction state in worker/debug information.
- Update Todoist workflow instructions and repository documentation for the new configuration and
  behavior.

## Non-goals

- Repository aliases, fuzzy matching, per-task cloning, or arbitrary repository paths.
- Task-type or implementation/research routing, new worker types, or other tracker providers.
- Model aliases or a generic model-routing layer.
- Changing the distinct meanings of `InProgress`, `Rework`, `Merging`, `HumanReview`, or `Done`.
- Interrupting an in-flight command solely because context usage crossed the threshold.
- Persisting checkpoint state in the Todoist task description or relying solely on Codex's compacted
  summary.

## Acceptance criteria

### Task metadata

- [x] No front matter preserves current behavior and the original description.
- [x] `repo` alone, and all three settings together, parse into one typed execution-settings value.
- [x] Human-readable description text after Symphony front matter remains available to the worker.
- [x] Malformed YAML, unknown/invalid settings, traversal, an invalid repository, model, or reasoning
  combination produce a concise Todoist comment and move the task to `Blocked` instead of being
  ignored or retried indefinitely.
- [x] Omitted model/thinking retain the configured or App Server default values.

### Repository and workspace

- [x] A task repository resolves to the exact direct child of the configured repository root.
- [x] A repository-backed workspace is that task's Git worktree; Codex starts with the worktree as
  `cwd` and no per-task clone is performed.
- [x] Concurrent tasks for one source repository receive independent deterministic
  `feature/<task-id>-<slug>` branches and worktrees. An explicit task ID takes precedence; Todoist
  tasks fall back to their native stable ID.
- [x] Resume reuses the correct worktree by stable task identity even after a title rename.
- [x] Resume adopts an existing owned feature branch and migrates legacy `symphony/...` branches to
  the feature convention.
- [x] Local owned worktrees use a scoped Codex permission profile that permits Git metadata writes
  without granting unrestricted filesystem access.
- [x] A workspace associated with another repository fails safely.
- [x] Cleanup invokes the before-remove behavior, detaches only a Symphony-owned linked worktree,
  tolerates stale worktree metadata, and never modifies/removes a primary working tree.
- [x] New workspace names contain source, stable task ID, and a lowercase safe title slug; whitespace,
  punctuation, Unicode, separators, traversal text, and long titles remain filesystem-safe.
- [x] Identical titles with different IDs remain distinct.

### Codex runtime and workflow state

- [x] Task model/reasoning overrides are sent on App Server `thread/start`/`turn/start`, with exact
  values and no CLI subprocess routing or aliases.
- [x] `model/list` validates a requested model and supported reasoning effort and supplies observable
  effective defaults.
- [x] Todoist scope/state mappings and the structured tool include `Blocked`; configured active states
  do not dispatch it.
- [x] A genuine blocker records what/why/action, moves to `Blocked`, and stops the worker; moving the
  task back to an active state permits dispatch again.
- [x] `HumanReview` remains the completed-work review gate and is not reused for blockers.

### Context management and durable recovery

- [x] Configuration supports `context_management.enabled` (default `true`) and
  `context_management.checkpoint_threshold` (default `0.70`).
- [x] Current usage is `tokenUsage.last.totalTokens / tokenUsage.modelContextWindow`; below-threshold
  events do nothing and repeated above-threshold events schedule only one cycle.
- [x] A pending checkpoint waits for normal turn completion, then enters explicit checkpointing,
  compacting, and resuming states without normal work overlapping compaction.
- [x] `.codex/skills/checkpoint/SKILL.md` captures goal, progress, decisions, repository/branch,
  changes, commits, verification, blockers, and exact next action in a new Todoist comment whose
  first line is `[SYMPHONY_CHECKPOINT_V1]`.
- [x] The checkpoint skill is passed as an App Server `skill` input, and a newly persisted matching
  comment is verified before `thread/compact/start` is sent.
- [x] Checkpoint failure prevents compaction; compaction failure retains the checkpoint and surfaces
  an explicit failure.
- [x] Successful compaction waits for the context-compaction lifecycle, then starts a turn in the
  same thread instructing Codex to read the newest Todoist checkpoint, reconcile Git/worktree state,
  and continue the recorded next action.
- [x] After successful resume the single-flight guard resets so a later threshold crossing can
  schedule another cycle.

### Observability and compatibility

- [x] Worker/debug state exposes task identifier/state/title, repository, workspace, branch, thread
  and turn/session IDs, model, reasoning effort, current context tokens, model window, usage percent,
  checkpoint status/time, and compaction state without secrets or JSONL parsing.
- [x] Existing workspace, scheduler, retry, tracker, App Server, and dashboard behavior stays green
  unless explicitly changed above.

## Implementation notes

- Use `TaskExecutionSettings -> RepositoryResolver -> Workspace -> AgentRunner/AppServer` as the
  narrow data flow; keep provider policy out of the scheduler.
- Use the installed Codex App Server 0.147.0 protocol: `model/list` advertises
  `supportedReasoningEfforts`; `thread/tokenUsage/updated` carries `tokenUsage.last.totalTokens` and
  `tokenUsage.modelContextWindow`; skill turn input is `{type: "skill", name, path}`; compaction is
  requested by `thread/compact/start` and completed through context-compaction lifecycle events.
- Preserve the existing non-repository workspace/hook path when `repo` is omitted.
- Add the smallest failing tests before each behavioral slice and keep each verified acceptance
  outcome in its own reviewable commit.

## Tasks

- [x] Add task metadata parser and repository resolver tests/implementation.
- [x] Add readable workspace discovery and Git worktree lifecycle tests/implementation.
- [x] Add model/reasoning validation and resolved runtime observability.
- [x] Add `Blocked` state mapping, automatic blocking behavior, and workflow tests/docs.
- [x] Add context state machine, checkpoint skill, App Server compaction/resume, and focused tests.
- [x] Extend dashboard/debug projection and documentation.
- [x] Run focused tests, format/spec checks, and `make all`; audit every criterion.
- [x] Mark this spec `done`, move it to `docs/specs/done/`, and make the lifecycle commit.

## Verification

- Baseline before implementation: 137 focused workspace/config, Todoist, App Server, and orchestrator
  tests passed with 0 failures.
- Installed protocol probe: Codex CLI/App Server 0.147.0 returned model metadata, repo/user skill
  metadata, and accepted `thread/compact/start`, emitting a `contextCompaction` lifecycle item.
- Focused final App Server verification: 23 tests passed with 0 failures, including explicit
  checkpoint input, compaction lifecycle, and compaction response-error coverage.
- Final `mise exec -- make all`: build and formatting passed; public-spec check and Credo reported no
  issues; 347 tests passed with 0 failures and 6 skipped; enforced coverage was 100%; Dialyzer
  reported 0 errors.
- Dependency resolution reported security advisories in unchanged locked dependencies. Dependency
  upgrades are outside this spec and no dependency or lockfile was modified.
