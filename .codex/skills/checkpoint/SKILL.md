---
name: checkpoint
description: Save the minimum durable task state to a marked Todoist comment before context compaction.
---

# Checkpoint

Create a durable continuation checkpoint for the current Todoist task.

1. Inspect the task, current workspace, repository, branch, Git status, relevant commits, and existing verification.
2. Use the injected `todoist` tool to create a new comment on the current task. Do not update the task description or Workpad.
3. The comment's first line must be exactly `[SYMPHONY_CHECKPOINT_V1]`.
4. Keep the comment concise. After the marker, include: Goal; Progress; Decisions; Repository/Branch; Changes (task-owned vs. unrelated); Commits; Verification; Open issues; External effects (if any); and one exact Next action with its expected result. Use `unknown` where evidence is unavailable.
5. Confirm the comment was created successfully. Do not change the task's workflow state.
