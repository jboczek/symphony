---
title: Todoist tracker integration
summary: Add a project-scoped Todoist tracker backed by the official td CLI and prove it with the live _agents workflow.
status: done
---

# Todoist tracker integration

## tldr;

Add Todoist as a first-class Symphony tracker without changing the scheduler, worker lifecycle,
workspace isolation, retry behavior, concurrency, or Codex App Server integration. The adapter uses
the authenticated official `td` CLI, confines every operation to the existing `_agents` project,
offers only allowlisted non-destructive agent operations, and is proven against the two real Todoist
tasks currently in `Todo`.

## Context

Symphony currently supports Linear, GitHub Issues, Jira, Asana, GitLab, and memory adapters. Asana
is the closest reference because it maps project sections to Symphony states. The local Todoist CLI
is version 3.1.5 and supports JSON/NDJSON output for all required reads and JSON output for relevant
writes. Codex CLI 0.147.0 advertises `gpt-5.6-luna` with `xhigh` reasoning.

The live `_agents` project resolves uniquely. Its existing section names are `Backlog`, `Todo`,
`InProgress`, `HumanReview`, `Rework`, `Merging`, and `Done`. The user explicitly chose these exact
existing names instead of renaming the two no-space variants.

## Problem

Symphony cannot currently discover, reconcile, or safely update Todoist work. Exposing raw `td`
access would allow the agent to reach unrelated personal projects and destructive operations, while
using task completion as state would make terminal work disappear from normal project queries.

## Scope

- Register `tracker.kind: todoist` and default `tracker.provider.project` to `_agents`.
- Resolve the configured project uniquely to its canonical ID and verify all seven existing
  sections during configuration load without changing project structure.
- Add a typed, timeout-aware `td` process boundary using argv execution and JSON/NDJSON parsing.
- Implement project-scoped task reads, issue normalization, state filtering, and ID refresh.
- Add one structured `todoist` agent tool with explicit non-destructive operations for task reads,
  moves, updates and creation; comment reads, creation and updates; and Workpad upsert.
- Enforce project ownership for tasks, sections, and comment parents before mutations; force new
  tasks into `_agents`/`Backlog`.
- Add a Todoist workflow derived from `elixir/WORKFLOW.md`, using the live section names and
  persistent `## Codex Workpad` recovery.
- Configure the live worker command for `gpt-5.6-luna`, `xhigh`, `approval_policy: never`,
  `workspace-write`, and network-enabled turn sandboxing.
- Add focused automated coverage and run existing full repository gates.
- Run Symphony against the two existing tasks `Komentarz` and `Research ADF`, leaving each in the
  accurate final workflow state with recoverable Workpad evidence.

## Non-goals

- Todoist REST authentication or a separate token client.
- Scheduler, retry, workspace, turn, concurrency, observability, or App Server redesign.
- Todoist dependency graphs; `blocked_by` remains `[]`.
- Task completion/uncompletion, deletion, project/section creation, archive, rename, or deletion.
- Access to any Todoist project other than `_agents`.
- Automatic workflow-section bootstrap during normal startup.

## Acceptance criteria

### Repository and configuration

- [x] The local repository is the `jboczek/symphony` fork with `openai/symphony` configured as
  `upstream`, inside the original start directory.
- [x] `tracker.kind: todoist` is registered without provider branches in the orchestrator.
- [x] Omitted Todoist project configuration defaults to `_agents`; a non-string/blank project is
  rejected.
- [x] Startup resolves exactly one active `_agents` project and caches its canonical ID for the
  effective configuration; missing and ambiguous matches fail clearly.
- [x] Startup verifies the exact sections `Backlog`, `Todo`, `InProgress`, `HumanReview`, `Rework`,
  `Merging`, and `Done`, rejects missing/ambiguous/cross-project sections, and performs no structure
  mutation.
- [x] The runnable workflow uses active states `Todo`, `InProgress`, `Rework`, `Merging`, terminal
  state `Done`, and does not dispatch `Backlog` or `HumanReview`.

### CLI and tracker behavior

- [x] The implementation executes the installed `td` executable with argv, never interpolated
  shell commands, and uses JSON/NDJSON wherever supported.
- [x] Missing executable, unauthenticated status, non-zero exit, timeout, malformed JSON, and
  malformed NDJSON return structured non-secret errors.
- [x] Candidate and ID reads are CLI-filtered by canonical project ID and independently reject any
  returned task whose `projectId` differs.
- [x] Empty state/ID reads return `{:ok, []}` without invoking `td`.
- [x] Todoist tasks normalize to the current `Issue` contract with `TODOIST-<id>`, section state,
  lowercase/deduplicated labels, Todoist-to-Symphony priority ordering, timestamps, URL,
  project/task/section native refs, explicit dispatchability, and `blocked_by: []`.
- [x] Todoist task completion is never used as the workflow transition to `Done`.
- [x] `InProgress` items remain discoverable, `Rework` is dispatchable, `HumanReview` is not active,
  and `Done` is terminal.

### Agent tool and safety

- [x] The agent receives only one structured `todoist` tool with a closed operation enum; it cannot
  execute arbitrary `td` arguments.
- [x] The tool supports only required task/comment/Workpad operations and exposes no task complete,
  uncomplete, delete, project/section mutation, archive, or arbitrary account operation.
- [x] Task mutations first verify `task.projectId == configured_project_id`.
- [x] Section moves use a cached section owned by `_agents` and reject foreign or unknown sections.
- [x] Comment updates resolve the parent task and verify that task belongs to `_agents`.
- [x] Task creation always supplies canonical `_agents` project and `Backlog` section IDs; callers
  cannot override either.
- [x] Workpad upsert discovers the comment whose content begins exactly `## Codex Workpad`, reuses
  and updates it, or creates one when absent without progress-comment spam.
- [x] Dynamic-tool results never contain Todoist credentials and the adapter declares no token
  environment because authentication remains inside the local CLI profile.

### Workflow and Codex runtime

- [x] A Todoist workflow preserves the reference workflow's unattended planning, reproduction,
  implementation, validation, self-review, acceptance audit, persistent Workpad, active-task
  persistence, Rework recovery, and HumanReview quality gate.
- [x] `Todo -> InProgress` occurs before work; completed/verified work moves to `HumanReview`; Rework
  reuses the workspace and Workpad; no code/content change occurs merely because an item is already
  in `HumanReview`.
- [x] The effective App Server command explicitly selects `gpt-5.6-luna` and `xhigh`; startup and a
  real thread prove that the installed Codex accepts them without fallback.
- [x] Effective runtime policies are `approval_policy: never`, thread sandbox `workspace-write`, and
  turn sandbox `workspaceWrite` with network enabled and per-task workspace isolation.

### Automated and live verification

- [x] Focused tests cover registration, configuration, scope/section discovery, task reads and
  normalization, JSON/NDJSON/error handling, state behavior, Workpad lifecycle, project guards,
  forced task creation, absent destructive operations, and secret-safe results.
- [x] Existing adapter/orchestrator/workspace/App Server behavior remains green under formatting,
  specs, lint, coverage, Dialyzer, and the full test suite.
- [x] A real Symphony run discovers and dispatches the existing `Komentarz` and `Research ADF`
  tasks from `Todo` through normal scheduler concurrency.
- [x] `Komentarz` receives its requested comment; `Research ADF` receives a short, sourced connector
  summary and a documented estimate for the described daily two-million-row ADX flow.
- [x] Each real task has one recoverable Workpad, validation evidence, and an accurate final state;
  a genuinely blocked task records the precise blocker instead of claiming success.
- [x] Final read-only inspection confirms `_agents` was the only project modified, no unrelated
  task changed, and no destructive Todoist operation or credential exposure occurred.

## Implementation notes

- Follow the existing `Tracker`/Asana boundaries. Keep provider policy in Todoist modules and the
  workflow prompt, never in `Orchestrator`.
- Cache only non-secret resolved scope metadata after successful configuration validation. Refresh
  it when workflow configuration changes; keep the previous last-known-good scope when reload
  validation fails.
- Use `td --no-spinner ... --ndjson --full` for lists and `--json --full` for entity reads. Ignore
  human success text for mutations and verify the returned/refetched entity structurally.
- Every `td` reference generated by Symphony is `id:<canonical-id>`; caller-supplied names never
  select projects, sections, tasks, or comments.
- Map Todoist priorities `4,3,2,1` to Symphony ordering `1,2,3,4` respectively.
- Treat task/comment strings as untrusted argv values. Bound captured CLI diagnostics and do not
  return authentication-status output through the agent tool.
- The live workflow uses `InProgress`/`HumanReview`, matching the user's clarification and the
  existing project; do not create or rename sections.
- The official OpenAI model ID is `gpt-5.6-luna`; local model catalog verification must also show
  `xhigh` support before the live run.
- Start with TDD: add the smallest failing test for each behavior before production code.
- Keep commits small and coherent; exceed three files only when registration and its proof are safer
  as one atomic adapter slice.
- Preserve behavior outside Todoist and add no dependency unless the standard library/current
  dependencies cannot satisfy the boundary.

## Verification evidence

- Repository gates passed at `f221485`: 316 tests, 0 failures, 6 skipped, 100% coverage; build,
  formatting, strict Credo, public-spec checks, and Dialyzer all passed.
- The live scheduler discovered both existing `Todo` tasks concurrently and used distinct
  per-task workspaces.
- Effective runtime records prove `gpt-5.6-luna`, `xhigh`, approval `never`, workspace-write, and
  network-enabled turn sandboxing after explicit model enforcement disabled provider fallback.
- Final Todoist inspection found only `Komentarz` and `Research ADF` in `_agents`; both are
  unchecked in `HumanReview`, each has one recoverable Workpad, and each has its requested
  deliverable comment.
- The seven pre-existing sections remain active and unchanged; no completion, deletion, archive,
  project creation, or access outside `_agents` was performed.

## Tasks

- [x] Commit 1 — add CLI/scope tests, implement typed `td` execution, parsing, startup resolution,
  section verification, scoped reads/mutations, and run focused tests.
- [x] Commit 2 — add tracker registration/adapter tests, implement normalization and adapter
  delegation, and run focused plus existing tracker tests.
- [x] Commit 3 — add tool/Workpad safety tests, implement the closed operation tool and ownership
  guards, and run focused tool tests.
- [x] Commit 4 — add `elixir/WORKFLOW.todoist.md` and adapter documentation, validate config/model
  schema, formatting, and static documentation checks.
- [x] Run `make all` and all relevant/full regression tests; fix only task-owned failures.
- [x] Checkpoint before external mutation, record the two task IDs/initial states, and start Symphony
  with the Todoist workflow.
- [x] Observe both real dispatches, verify requested work and Workpads, and inspect final Todoist
  state/safety invariants.
- [x] Audit every acceptance criterion against direct evidence, update this spec to `done`, move it
  to `docs/specs/done/`, make the lifecycle commit, and update the canonical checkpoint.
