---
title: Operations dashboard improvements
summary: Add a dark operations dashboard, cached-input token accounting, and a bounded completed-session history.
status: in_progress
---

# Operations dashboard improvements

## tldr;

Make the Phoenix operations dashboard dark, show token usage as raw input, cached input, and
output, and add a bottom-of-page history of the 50 most recently ended sessions.

## Scope

- Use a dark visual palette for the dashboard and its static controls, tables, panels, and states.
- Preserve the existing token totals while exposing cached input tokens from Codex usage events.
- Retain the 50 most recent ended worker sessions in memory, including normal, failed, timed-out,
  stalled, and interrupted sessions.
- Render the completed-session history below the existing dashboard sections with issue, session,
  completion, runtime/turn, and token details.

## Non-goals

- Persisting completed sessions across Symphony restarts.
- Changing dispatch, retry, blocking, or workspace lifecycle semantics.
- Adding a theme toggle or a second visual theme.

## Acceptance criteria

- [ ] The operations dashboard uses a dark color scheme without light card, table, control, code,
  warning, or error surfaces.
- [ ] Aggregate and per-session token payloads expose `input_tokens`, `cached_input_tokens`,
  `output_tokens`, and `total_tokens`, with cached values derived from cumulative Codex usage
  snapshots without double-counting.
- [ ] The dashboard labels the three token components `Raw in`, `Cached in`, and `Out` for both
  aggregate usage and session rows.
- [ ] The state/API payload exposes at most 50 ended sessions in newest-first order, including
  sessions ending normally or abnormally, and retains them only for the current process lifetime.
- [ ] A `Completed Sessions` section appears after the existing sections, renders the ended-session
  details, and has an explicit empty state.
- [ ] Existing focused dashboard, API, orchestrator, and token-accounting tests remain green.

## Implementation notes

- Keep `completed` bookkeeping unchanged; add a separate bounded `completed_sessions` list so
  scheduling behavior does not depend on dashboard history.
- Treat a worker process `:DOWN` event as the end of one displayed session and capture its latest
  cumulative token values before removing it from `running`.
- Keep the existing public token field names for raw input/output and add only the cached field.
- Add focused tests before implementation for cached cumulative deltas, history ordering/bounds,
  payload projection, and dashboard rendering.

## Tasks

- [ ] Add failing tests for token deltas, completed-session retention/projection, and dashboard
  rendering.
- [ ] Implement bounded session history and cached-token accounting.
- [ ] Update presenter, LiveView markup, and dark CSS.
- [ ] Run focused tests, formatting/spec checks, and the repository quality gate.
- [ ] Audit acceptance criteria, mark this spec `done`, move it to `docs/specs/done/`, and make the
  lifecycle commit.
