defmodule SymphonyElixir.Todoist.AgentToolTest do
  use ExUnit.Case

  alias SymphonyElixir.Todoist.{Adapter, AgentTool}

  @tracker_settings %{
    kind: "todoist",
    provider: %{"project" => "_agents"},
    active_states: ["Todo", "InProgress", "Rework", "Merging"],
    terminal_states: ["Done"]
  }

  test "advertises one closed, non-destructive todoist operation contract" do
    assert [
             %{
               "name" => "todoist",
               "inputSchema" => %{
                 "additionalProperties" => false,
                 "properties" => %{"operation" => %{"enum" => operations}},
                 "required" => ["operation"],
                 "type" => "object"
               }
             }
           ] = AgentTool.tool_specs()

    assert operations == [
             "task_get",
             "task_move",
             "task_update",
             "task_create",
             "comment_list",
             "comment_create",
             "comment_update",
             "workpad_upsert"
           ]

    refute Enum.any?(operations, &(&1 in ["task_delete", "task_complete", "project_delete", "section_archive"]))
  end

  test "adapter advertises and executes the structured Todoist tool" do
    assert [%{"name" => "todoist"}] = Adapter.agent_tool_specs()

    response =
      Adapter.execute_agent_tool(
        "todoist",
        %{"operation" => "task_get", "task_id" => "task-1"},
        tracker_settings: @tracker_settings,
        todoist_client: fn :task_get, %{task_id: "task-1"}, @tracker_settings ->
          {:ok, %{"id" => "task-1", "projectId" => "project-1"}}
        end
      )

    assert response["success"]
    assert Jason.decode!(response["output"])["result"]["id"] == "task-1"
  end

  test "executes only allowlisted task and comment operations with normalized arguments" do
    test_pid = self()

    client = fn operation, payload, settings ->
      send(test_pid, {:todoist_client, operation, payload, settings})
      {:ok, %{"operation" => Atom.to_string(operation)}}
    end

    assert success?(
             AgentTool.execute(
               "todoist",
               %{"operation" => "task_move", "task_id" => "task-1", "section" => "InProgress"},
               tracker_settings: @tracker_settings,
               todoist_client: client
             )
           )

    assert_received {:todoist_client, :task_move, %{task_id: "task-1", section: "InProgress"}, @tracker_settings}

    assert success?(
             AgentTool.execute(
               "todoist",
               %{
                 "operation" => "task_create",
                 "content" => "Follow-up",
                 "description" => "Details",
                 "labels" => ["agent"],
                 "priority" => "p2"
               },
               tracker_settings: @tracker_settings,
               todoist_client: client
             )
           )

    assert_received {:todoist_client, :task_create,
                     %{
                       content: "Follow-up",
                       attributes: %{
                         "description" => "Details",
                         "labels" => ["agent"],
                         "priority" => "p2"
                       }
                     }, @tracker_settings}

    assert success?(
             AgentTool.execute(
               "todoist",
               %{"operation" => "comment_create", "task_id" => "task-1", "content" => "Result"},
               tracker_settings: @tracker_settings,
               todoist_client: client
             )
           )

    assert_received {:todoist_client, :comment_create, %{task_id: "task-1", content: "Result"}, @tracker_settings}
  end

  test "discovers and updates the same Workpad comment" do
    test_pid = self()
    content = "## Codex Workpad\n\n### Plan\n\n- [x] Done"

    client = fn
      :comment_list, %{task_id: "task-1"}, @tracker_settings ->
        {:ok,
         [
           %{"id" => "comment-other", "taskId" => "task-1", "content" => "Other"},
           %{"id" => "comment-workpad", "taskId" => "task-1", "content" => "## Codex Workpad\nold"}
         ]}

      :comment_update, %{comment_id: "comment-workpad", content: ^content}, @tracker_settings ->
        send(test_pid, :updated_existing_workpad)
        {:ok, %{"id" => "comment-workpad", "taskId" => "task-1", "content" => content}}

      operation, payload, _settings ->
        flunk("unexpected Workpad operation #{inspect(operation)} #{inspect(payload)}")
    end

    response =
      AgentTool.execute(
        "todoist",
        %{"operation" => "workpad_upsert", "task_id" => "task-1", "content" => content},
        tracker_settings: @tracker_settings,
        todoist_client: client
      )

    assert response["success"]
    assert Jason.decode!(response["output"])["result"]["action"] == "updated"
    assert_received :updated_existing_workpad
  end

  test "creates one Workpad when absent and rejects invalid or duplicate Workpads" do
    content = "## Codex Workpad\n\n### Goal\n\nTest"

    create_client = fn
      :comment_list, %{task_id: "task-1"}, @tracker_settings ->
        {:ok, []}

      :comment_create, %{task_id: "task-1", content: ^content}, @tracker_settings ->
        {:ok, %{"id" => "created-workpad", "taskId" => "task-1", "content" => content}}
    end

    created =
      AgentTool.execute(
        "todoist",
        %{"operation" => "workpad_upsert", "task_id" => "task-1", "content" => content},
        tracker_settings: @tracker_settings,
        todoist_client: create_client
      )

    assert created["success"]
    assert Jason.decode!(created["output"])["result"]["action"] == "created"

    invalid =
      AgentTool.execute(
        "todoist",
        %{"operation" => "workpad_upsert", "task_id" => "task-1", "content" => "Not a workpad"},
        tracker_settings: @tracker_settings,
        todoist_client: fn _operation, _payload, _settings -> flunk("invalid Workpad must not call CLI") end
      )

    refute invalid["success"]

    duplicate_client = fn
      :comment_list, %{task_id: "task-1"}, @tracker_settings ->
        {:ok,
         [
           %{"id" => "one", "content" => "## Codex Workpad\n1"},
           %{"id" => "two", "content" => "## Codex Workpad\n2"}
         ]}
    end

    duplicate =
      AgentTool.execute(
        "todoist",
        %{"operation" => "workpad_upsert", "task_id" => "task-1", "content" => content},
        tracker_settings: @tracker_settings,
        todoist_client: duplicate_client
      )

    refute duplicate["success"]
  end

  test "rejects destructive, malformed, and scope-override arguments before execution" do
    client = fn _operation, _payload, _settings -> flunk("invalid operation must not reach Todoist") end

    for arguments <- [
          %{"operation" => "task_complete", "task_id" => "task-1"},
          %{"operation" => "task_move", "task_id" => "task-1"},
          %{"operation" => "task_create", "content" => "Nope", "project_id" => "other"},
          %{"operation" => "comment_update", "comment_id" => "comment-1"},
          "not-an-object"
        ] do
      response =
        AgentTool.execute("todoist", arguments,
          tracker_settings: @tracker_settings,
          todoist_client: client
        )

      refute response["success"]
    end

    unsupported = AgentTool.execute("td", %{}, [])
    refute unsupported["success"]
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["todoist"]
  end

  test "never exposes CLI diagnostics or credentials in tool failures" do
    response =
      AgentTool.execute(
        "todoist",
        %{"operation" => "task_get", "task_id" => "task-1"},
        tracker_settings: @tracker_settings,
        todoist_client: fn _operation, _payload, _settings ->
          {:error, {:todoist_cli_exit, 1, "token=super-secret"}}
        end
      )

    refute response["success"]
    refute response["output"] =~ "super-secret"
    refute response["output"] =~ "token="
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  defp success?(response), do: response["success"] == true
end
