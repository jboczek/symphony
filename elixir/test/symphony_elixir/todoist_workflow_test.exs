defmodule SymphonyElixir.Todoist.WorkflowTest do
  use ExUnit.Case

  alias SymphonyElixir.{Config.Schema, Workflow}

  @workflow_path Path.expand("../../WORKFLOW.todoist.md", __DIR__)

  test "Todoist workflow selects the live project, states, Codex model, and sandbox policies" do
    assert {:ok, workflow} = Workflow.load(@workflow_path)
    assert {:ok, settings} = Schema.parse(workflow.config)

    assert settings.tracker.kind == "todoist"
    assert settings.tracker.provider == %{"project" => "_agents"}
    assert settings.tracker.active_states == ["Todo", "InProgress", "Rework", "Merging"]
    assert settings.tracker.terminal_states == ["Done"]

    assert settings.codex.command =~ "--model gpt-5.6-luna"
    assert settings.codex.command =~ "model_reasoning_effort=xhigh"
    assert settings.codex.model == "gpt-5.6-luna"
    assert settings.codex.reasoning_effort == "xhigh"
    assert settings.codex.approval_policy == "never"
    assert settings.codex.thread_sandbox == "workspace-write"

    assert settings.codex.turn_sandbox_policy == %{
             "type" => "workspaceWrite",
             "networkAccess" => true
           }

    assert workflow.prompt =~ "## Codex Workpad"
    assert workflow.prompt =~ "Todo -> InProgress"
    assert workflow.prompt =~ "`Blocked`: missing external input"
    assert workflow.prompt =~ "Move the task to `Blocked`"
    assert workflow.prompt =~ "HumanReview"
    assert workflow.prompt =~ "Rework"
    refute workflow.prompt =~ "td task complete"
  end
end
