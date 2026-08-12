defmodule SymphonyElixir.ContextCheckpointFlowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TaskExecutionSettings

  defmodule FakeTodoistCLI do
    @spec validate_settings(map()) :: :ok
    def validate_settings(_settings), do: :ok

    @spec secret_environment_names(map()) :: [String.t()]
    def secret_environment_names(_settings), do: []

    @spec list_comments(map(), String.t()) :: {:ok, [map()]}
    def list_comments(_settings, _task_id) do
      if Process.get(:checkpoint_comment_mode) == :missing do
        {:ok, []}
      else
        checkpoint_comments()
      end
    end

    defp checkpoint_comments do
      count = Process.get(:checkpoint_comment_reads, 0) + 1
      Process.put(:checkpoint_comment_reads, count)

      if count == 1 do
        {:ok, []}
      else
        {:ok,
         [
           %{
             "id" => "checkpoint-new",
             "content" => "[SYMPHONY_CHECKPOINT_V1]\nNext action: continue",
             "postedAt" => "2026-08-12T12:00:00Z"
           }
         ]}
      end
    end
  end

  test "threshold crossing checkpoints, compacts, and resumes in the same thread" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-context-checkpoint-flow-#{System.unique_integer([:positive])}"
      )

    previous_cli = Application.get_env(:symphony_elixir, :todoist_cli_module)
    previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

    on_exit(fn ->
      restore_app_env(:todoist_cli_module, previous_cli)
      restore_env("SYMP_TEST_CODEX_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")
    File.mkdir_p!(test_root)
    Application.put_env(:symphony_elixir, :todoist_cli_module, FakeTodoistCLI)
    System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
    Process.delete(:checkpoint_comment_reads)
    Process.delete(:checkpoint_comment_mode)

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$SYMP_TEST_CODEX_TRACE"
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-flow"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-normal"}}}'
          printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-flow","turnId":"turn-normal","tokenUsage":{"last":{"inputTokens":60,"outputTokens":10,"totalTokens":70},"total":{"totalTokens":7000},"modelContextWindow":100}}}'
          printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-flow","turnId":"turn-normal","tokenUsage":{"last":{"inputTokens":70,"outputTokens":10,"totalTokens":80},"total":{"totalTokens":9000},"modelContextWindow":100}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-flow","turn":{"id":"turn-normal"}}}'
          ;;
        5)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-checkpoint"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-flow","turn":{"id":"turn-checkpoint"}}}'
          ;;
        6)
          printf '%s\\n' '{"id":5,"result":{}}'
          printf '%s\\n' '{"method":"item/started","params":{"threadId":"thread-flow","turnId":"turn-compact","item":{"type":"contextCompaction","id":"compact-item"}}}'
          printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-flow","turnId":"turn-compact","item":{"type":"contextCompaction","id":"compact-item"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-flow","turn":{"id":"turn-compact"}}}'
          ;;
        7)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-resume"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-flow","turn":{"id":"turn-resume"}}}'
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "todoist",
      tracker_active_states: ["InProgress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      context_management_enabled: true,
      context_checkpoint_threshold: 0.70
    )

    issue = %Issue{
      id: "flow-task",
      identifier: "TODOIST-flow-task",
      title: "Checkpoint flow",
      description: "Continue safely",
      state: "InProgress",
      execution_settings: %TaskExecutionSettings{},
      dispatchable: true
    }

    Process.put(:checkpoint_issue_fetches, 0)

    issue_state_fetcher = fn [_issue_id] ->
      fetches = Process.get(:checkpoint_issue_fetches, 0) + 1
      Process.put(:checkpoint_issue_fetches, fetches)
      state = if fetches == 1, do: "InProgress", else: "Done"
      {:ok, [%{issue | state: state}]}
    end

    assert :ok =
             AgentRunner.run(issue, self(),
               max_turns: 3,
               issue_state_fetcher: issue_state_fetcher
             )

    payloads =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))

    turn_requests = Enum.filter(payloads, &(&1["method"] == "turn/start"))
    assert length(turn_requests) == 3

    [normal_request, checkpoint_request, resume_request] = turn_requests
    assert get_in(normal_request, ["params", "threadId"]) == "thread-flow"

    assert [
             %{"type" => "skill", "name" => "checkpoint", "path" => skill_path},
             %{"type" => "text", "text" => checkpoint_instruction}
           ] = get_in(checkpoint_request, ["params", "input"])

    assert String.ends_with?(skill_path, "/.codex/skills/checkpoint/SKILL.md")
    assert checkpoint_instruction =~ "[SYMPHONY_CHECKPOINT_V1]"

    assert get_in(resume_request, ["params", "threadId"]) == "thread-flow"
    resume_prompt = get_in(resume_request, ["params", "input", Access.at(0), "text"])
    assert resume_prompt =~ "latest Todoist comment"
    assert resume_prompt =~ "[SYMPHONY_CHECKPOINT_V1]"

    compact_request = Enum.find(payloads, &(&1["method"] == "thread/compact/start"))
    assert get_in(compact_request, ["params", "threadId"]) == "thread-flow"
  end

  test "missing checkpoint marker fails the cycle without compacting" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-context-checkpoint-failure-#{System.unique_integer([:positive])}"
      )

    previous_cli = Application.get_env(:symphony_elixir, :todoist_cli_module)
    previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

    on_exit(fn ->
      restore_app_env(:todoist_cli_module, previous_cli)
      restore_env("SYMP_TEST_CODEX_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")
    File.mkdir_p!(test_root)
    Application.put_env(:symphony_elixir, :todoist_cli_module, FakeTodoistCLI)
    System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
    Process.put(:checkpoint_comment_mode, :missing)

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$SYMP_TEST_CODEX_TRACE"
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-failure"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-normal"}}}'
          printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"totalTokens":70},"total":{"totalTokens":7000},"modelContextWindow":100}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
        5)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-checkpoint"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "todoist",
      tracker_active_states: ["InProgress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue = %Issue{
      id: "failure-task",
      identifier: "TODOIST-failure-task",
      title: "Checkpoint failure",
      state: "InProgress",
      execution_settings: %TaskExecutionSettings{},
      dispatchable: true
    }

    assert_raise RuntimeError, ~r/checkpoint_not_persisted/, fn ->
      AgentRunner.run(issue, self(),
        max_turns: 2,
        issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end
      )
    end

    payloads =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))

    refute Enum.any?(payloads, &(&1["method"] == "thread/compact/start"))
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
