defmodule SymphonyElixir.Todoist.AgentToolTest do
  use ExUnit.Case

  alias SymphonyElixir.Todoist.{Adapter, AgentTool}

  defmodule FakeCLI do
    @spec get_task(map(), String.t()) :: {:ok, map()}
    def get_task(settings, task_id), do: result(:get_task, [settings, task_id])

    @spec move_task(map(), String.t(), String.t()) :: {:ok, map()}
    def move_task(settings, task_id, section), do: result(:move_task, [settings, task_id, section])

    @spec update_task(map(), String.t(), map()) :: {:ok, map()}
    def update_task(settings, task_id, changes), do: result(:update_task, [settings, task_id, changes])

    @spec create_task(map(), String.t(), map()) :: {:ok, map()}
    def create_task(settings, content, attributes), do: result(:create_task, [settings, content, attributes])

    @spec list_comments(map(), String.t()) :: {:ok, [map()]}
    def list_comments(settings, task_id), do: result(:list_comments, [settings, task_id])

    @spec create_comment(map(), String.t(), String.t()) :: {:ok, map()}
    def create_comment(settings, task_id, content), do: result(:create_comment, [settings, task_id, content])

    @spec create_comment(map(), String.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def create_comment(settings, task_id, content, attachment, opts),
      do: result(:create_comment_with_attachment, [settings, task_id, content, attachment, opts])

    @spec update_comment(map(), String.t(), String.t()) :: {:ok, map()}
    def update_comment(settings, comment_id, content),
      do: result(:update_comment, [settings, comment_id, content])

    defp result(operation, arguments) do
      send(Application.fetch_env!(:symphony_elixir, :todoist_tool_test_pid), {operation, arguments})
      {:ok, if(operation == :list_comments, do: [], else: %{"operation" => Atom.to_string(operation)})}
    end
  end

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

    [tool_spec] = AgentTool.tool_specs()
    assert "Blocked" in get_in(tool_spec, ["inputSchema", "properties", "section", "enum"])
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

    assert success?(
             AgentTool.execute(
               "todoist",
               %{"operation" => "task_update", "task_id" => "task-1", "description" => "Updated"},
               tracker_settings: @tracker_settings,
               todoist_client: client
             )
           )

    assert_received {:todoist_client, :task_update, %{task_id: "task-1", changes: %{"description" => "Updated"}}, @tracker_settings}

    assert success?(
             AgentTool.execute(
               "todoist",
               %{"operation" => "comment_list", "task_id" => "task-1"},
               tracker_settings: @tracker_settings,
               todoist_client: client
             )
           )

    assert_received {:todoist_client, :comment_list, %{task_id: "task-1"}, @tracker_settings}
  end

  test "creates a comment with a workspace-relative attachment" do
    test_pid = self()

    client = fn :comment_create, %{task_id: "task-1", content: "Screenshot", file_path: "artifacts/list.png", file_name: "list.png"}, @tracker_settings = settings ->
      send(test_pid, {:attached_comment, settings})
      {:ok, %{"id" => "comment-1", "taskId" => "task-1", "attachment" => "list.png"}}
    end

    response =
      AgentTool.execute(
        "todoist",
        %{
          "operation" => "comment_create",
          "task_id" => "task-1",
          "content" => "Screenshot",
          "file_path" => "artifacts/list.png",
          "file_name" => "list.png"
        },
        tracker_settings: @tracker_settings,
        todoist_client: client
      )

    assert response["success"]
    assert_received {:attached_comment, @tracker_settings}
  end

  test "default client dispatches every allowlisted operation through the typed CLI module" do
    previous_cli = Application.get_env(:symphony_elixir, :todoist_cli_module)
    previous_pid = Application.get_env(:symphony_elixir, :todoist_tool_test_pid)
    Application.put_env(:symphony_elixir, :todoist_cli_module, FakeCLI)
    Application.put_env(:symphony_elixir, :todoist_tool_test_pid, self())

    on_exit(fn ->
      restore_app_env(:todoist_cli_module, previous_cli)
      restore_app_env(:todoist_tool_test_pid, previous_pid)
    end)

    operations = [
      %{"operation" => "task_get", "task_id" => "task-1"},
      %{"operation" => "task_move", "task_id" => "task-1", "section" => "InProgress"},
      %{"operation" => "task_update", "task_id" => "task-1", "content" => "Updated"},
      %{"operation" => "task_create", "content" => "Created"},
      %{"operation" => "comment_list", "task_id" => "task-1"},
      %{"operation" => "comment_create", "task_id" => "task-1", "content" => "Created"},
      %{"operation" => "comment_update", "comment_id" => "comment-1", "content" => "Updated"}
    ]

    assert Enum.all?(operations, fn arguments ->
             AgentTool.execute("todoist", arguments, tracker_settings: @tracker_settings)["success"]
           end)

    assert_received {:get_task, [@tracker_settings, "task-1"]}
    assert_received {:move_task, [@tracker_settings, "task-1", "InProgress"]}
    assert_received {:update_task, [@tracker_settings, "task-1", %{"content" => "Updated"}]}
    assert_received {:create_task, [@tracker_settings, "Created", %{}]}
    assert_received {:list_comments, [@tracker_settings, "task-1"]}
    assert_received {:create_comment, [@tracker_settings, "task-1", "Created"]}
    assert_received {:update_comment, [@tracker_settings, "comment-1", "Updated"]}
  end

  test "passes the Codex workspace to Todoist attachment creation" do
    previous_cli = Application.get_env(:symphony_elixir, :todoist_cli_module)
    previous_pid = Application.get_env(:symphony_elixir, :todoist_tool_test_pid)
    Application.put_env(:symphony_elixir, :todoist_cli_module, FakeCLI)
    Application.put_env(:symphony_elixir, :todoist_tool_test_pid, self())

    on_exit(fn ->
      restore_app_env(:todoist_cli_module, previous_cli)
      restore_app_env(:todoist_tool_test_pid, previous_pid)
    end)

    assert AgentTool.execute(
             "todoist",
             %{
               "operation" => "comment_create",
               "task_id" => "task-1",
               "content" => "Screenshot",
               "file_path" => "docs/temp/tui-list.png",
               "file_name" => "tui-list.png"
             },
             tracker_settings: @tracker_settings,
             workspace: "/tmp/task-workspace"
           )["success"]

    assert_received {:create_comment_with_attachment,
                     [
                       @tracker_settings,
                       "task-1",
                       "Screenshot",
                       %{path: "docs/temp/tui-list.png", file_name: "tui-list.png"},
                       [cwd: "/tmp/task-workspace"]
                     ]}
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

    for comments <- [
          [%{"content" => "## Codex Workpad\nmissing id"}],
          "not-a-list"
        ] do
      invalid_payload =
        AgentTool.execute(
          "todoist",
          %{"operation" => "workpad_upsert", "task_id" => "task-1", "content" => content},
          tracker_settings: @tracker_settings,
          todoist_client: fn :comment_list, %{task_id: "task-1"}, @tracker_settings ->
            {:ok, comments}
          end
        )

      refute invalid_payload["success"]
    end

    non_string_comment_client = fn
      :comment_list, %{task_id: "task-1"}, @tracker_settings ->
        {:ok, [%{"id" => "other", "content" => nil}]}

      :comment_create, %{task_id: "task-1", content: ^content}, @tracker_settings ->
        {:ok, %{"id" => "created-workpad", "content" => content}}
    end

    assert AgentTool.execute(
             "todoist",
             %{"operation" => "workpad_upsert", "task_id" => "task-1", "content" => content},
             tracker_settings: @tracker_settings,
             todoist_client: non_string_comment_client
           )["success"]
  end

  test "rejects destructive, malformed, and scope-override arguments before execution" do
    client = fn _operation, _payload, _settings -> flunk("invalid operation must not reach Todoist") end

    for arguments <- [
          %{"operation" => "task_complete", "task_id" => "task-1"},
          %{"operation" => "task_move", "task_id" => "task-1"},
          %{"operation" => "task_update", "task_id" => "task-1"},
          %{"operation" => "task_update", "task_id" => "task-1", "labels" => [1]},
          %{"operation" => "task_update", "task_id" => "task-1", "priority" => 1},
          %{"operation" => "task_create", "content" => "Nope", "project_id" => "other"},
          %{"operation" => "comment_update", "comment_id" => "comment-1"},
          %{
            "operation" => "comment_create",
            "task_id" => "task-1",
            "content" => "Nope",
            "file_path" => "/tmp/list.png"
          },
          %{
            "operation" => "comment_create",
            "task_id" => "task-1",
            "content" => "Nope",
            "file_path" => "../list.png"
          },
          %{
            "operation" => "comment_create",
            "task_id" => "task-1",
            "content" => "Nope",
            "file_name" => "list.png"
          },
          %{"operation" => "workpad_upsert", "task_id" => "task-1"},
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

    for reason <- [{:transport, "details"}, "opaque failure"] do
      failure =
        AgentTool.execute(
          "todoist",
          %{"operation" => "task_get", "task_id" => "task-1"},
          tracker_settings: @tracker_settings,
          todoist_client: fn _operation, _payload, _settings -> {:error, reason} end
        )

      refute failure["success"]
    end

    json_unsafe =
      AgentTool.execute(
        "todoist",
        %{"operation" => "task_get", "task_id" => "task-1"},
        tracker_settings: @tracker_settings,
        todoist_client: fn _operation, _payload, _settings -> {:ok, self()} end
      )

    assert json_unsafe["output"] =~ "Todoist result was not JSON-safe"
  end

  defp success?(response), do: response["success"] == true

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
