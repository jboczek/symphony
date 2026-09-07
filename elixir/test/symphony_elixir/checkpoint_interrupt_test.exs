defmodule SymphonyElixir.CheckpointInterruptTest do
  use SymphonyElixir.TestSupport

  test "interrupt RPC failure aborts the turn" do
    with_server(start_turn(), emit(%{"id" => "checkpoint-interrupt:work", "error" => %{"message" => "denied"}}), fn session ->
      assert {:error, {:interrupt_failed, %{"message" => "denied"}}} =
               AppServer.run_turn(session, "work", issue(), interrupt_when: fn -> true end)
    end)
  end

  test "interrupt acknowledgement does not complete the turn and timeout is bounded" do
    updates = Enum.map_join(1..10, "\n", fn _ -> "sleep 0.03\n" <> emit(%{"method" => "item/updated"}) end)

    with_server(start_turn(), emit(%{"id" => "checkpoint-interrupt:work", "result" => %{}}) <> updates, fn session ->
      assert {:error, :interrupt_timeout} =
               AppServer.run_turn(session, "work", issue(), interrupt_when: fn -> true end)
    end)
  end

  test "natural completion racing the interrupt is successful" do
    with_server(start_turn(), emit(completed("work", "completed")), fn session ->
      assert {:ok, %{result: :turn_completed}} =
               AppServer.run_turn(session, "work", issue(), interrupt_when: fn -> true end)
    end)
  end

  test "unrelated and unidentified completion cannot satisfy an interrupt" do
    notifications =
      emit(completed("stale", "interrupted")) <>
        emit(%{"method" => "turn/completed"}) <>
        emit(completed("work", "interrupted") |> put_in(["params", "threadId"], "other")) <>
        emit(completed("work", "interrupted"))

    with_server(start_turn(), notifications, fn session ->
      assert {:ok, %{result: :checkpoint_interrupted}} =
               AppServer.run_turn(session, "work", issue(),
                 interrupt_when: fn -> true end,
                 on_message: fn message ->
                   if message.event == :turn_completed, do: send(self(), {:terminal, message.payload})
                 end
               )

      assert_receive {:terminal, %{"params" => %{"threadId" => "thread", "turn" => %{"id" => "work"}}}}
      refute_receive {:terminal, _}
    end)
  end

  test "failed and unsolicited interrupted turns are failures" do
    for {status, reason} <- [{"failed", :turn_failed}, {"interrupted", :turn_cancelled}] do
      with_server(start_turn() <> emit(completed("work", status)), "", fn session ->
        assert {:error, {^reason, _}} = AppServer.run_turn(session, "work", issue())
      end)
    end
  end

  test "failed compaction terminal never resumes even after its item completes" do
    notifications = compact_start() <> compact_item_completed("compact-item") <> emit(completed("compact", "failed"))

    with_server(notifications, "", fn session ->
      assert {:error, {:compaction_failed, %{"params" => %{"turn" => %{"id" => "compact"}}}}} = AppServer.compact_thread(session)
    end)
  end

  test "compaction ignores stale terminals, foreign threads, and wrong item IDs" do
    notifications =
      compact_start() <>
        emit(%{"method" => "thread/compacted", "params" => %{"threadId" => "other"}}) <>
        emit(completed("stale", "failed")) <>
        compact_item_completed("wrong-item") <>
        emit(completed("compact", "completed")) <>
        emit(completed("compact", "failed"))

    with_server(notifications, "", fn session ->
      assert {:error, {:compaction_failed, %{"params" => %{"turn" => %{"id" => "compact"}}}}} = AppServer.compact_thread(session)
    end)
  end

  defp compact_start do
    emit(%{"id" => 5, "result" => %{}}) <>
      emit(%{"method" => "item/started", "params" => %{"threadId" => "thread", "turnId" => "compact", "item" => %{"id" => "compact-item", "type" => "contextCompaction"}}})
  end

  defp compact_item_completed(id) do
    emit(%{"method" => "item/completed", "params" => %{"threadId" => "thread", "turnId" => "compact", "item" => %{"id" => id, "type" => "contextCompaction"}}})
  end

  defp start_turn, do: emit(%{"id" => 3, "result" => %{"turn" => %{"id" => "work"}}})

  defp completed(id, status) do
    %{"method" => "turn/completed", "params" => %{"threadId" => "thread", "turn" => %{"id" => id, "status" => status}}}
  end

  defp emit(payload), do: "printf '%s\\n' '" <> Jason.encode!(payload) <> "'\n"

  defp issue, do: %Issue{id: "interrupt", identifier: "INT-1", title: "Interrupt", state: "In Progress"}

  defp with_server(first, second, run) do
    root = Path.join(System.tmp_dir!(), "symphony-interrupt-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "task")
    binary = Path.join(root, "codex")
    File.mkdir_p!(workspace)

    File.write!(binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread"}}}' ;;
        4) #{first} ;;
        5) #{second}
           : ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{binary} app-server",
      codex_turn_timeout_ms: 150
    )

    assert {:ok, session} = AppServer.start_session(workspace)

    try do
      run.(session)
    after
      AppServer.stop_session(session)
    end
  end
end
