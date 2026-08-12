defmodule SymphonyElixir.Todoist.CLITest do
  use ExUnit.Case

  alias SymphonyElixir.Todoist.CLI

  @project %{
    "id" => "project-1",
    "name" => "_agents",
    "isArchived" => false,
    "isDeleted" => false
  }
  @section_names ["Backlog", "Todo", "InProgress", "Blocked", "HumanReview", "Rework", "Merging", "Done"]

  setup do
    CLI.clear_scope_for_test()
    on_exit(&CLI.clear_scope_for_test/0)
    :ok
  end

  test "resolves the default project and exact required sections through structured td calls" do
    test_pid = self()

    runner = fn args ->
      send(test_pid, {:td_args, args})
      scope_response(args, [@project], sections())
    end

    assert {:ok, scope} = CLI.resolve_scope_for_test(%{provider: %{}}, runner)
    assert scope.project_id == "project-1"
    assert scope.project_name == "_agents"
    assert scope.sections_by_name["Todo"].id == "section-todo"
    assert scope.sections_by_name["Blocked"].id == "section-blocked"
    assert scope.sections_by_name["HumanReview"].project_id == "project-1"

    assert_received {:td_args, ["--no-spinner", "auth", "status"]}

    assert_received {:td_args,
                     [
                       "--no-spinner",
                       "project",
                       "list",
                       "--search",
                       "_agents",
                       "--all",
                       "--ndjson",
                       "--full"
                     ]}

    assert_received {:td_args,
                     [
                       "--no-spinner",
                       "section",
                       "list",
                       "--project",
                       "id:project-1",
                       "--all",
                       "--ndjson",
                       "--full"
                     ]}
  end

  test "rejects invalid, missing, ambiguous, incomplete, and cross-project scope" do
    assert {:error, :invalid_todoist_project} =
             CLI.resolve_scope_for_test(%{provider: %{"project" => 42}}, scope_runner())

    assert {:error, :missing_todoist_project} =
             CLI.resolve_scope_for_test(%{provider: %{"project" => "_agents"}}, scope_runner([]))

    duplicate = Map.put(@project, "id", "project-2")

    assert {:error, :ambiguous_todoist_project} =
             CLI.resolve_scope_for_test(
               %{provider: %{"project" => "_agents"}},
               scope_runner([@project, duplicate])
             )

    assert {:error, {:missing_todoist_sections, ["Done"]}} =
             CLI.resolve_scope_for_test(
               %{provider: %{"project" => "_agents"}},
               scope_runner([@project], Enum.reject(sections(), &(&1["name"] == "Done")))
             )

    foreign = Map.put(List.first(sections()), "projectId", "other-project")

    assert {:error, {:todoist_cross_project_section, "section-backlog"}} =
             CLI.resolve_scope_for_test(
               %{provider: %{"project" => "_agents"}},
               scope_runner([@project], [foreign | tl(sections())])
             )
  end

  test "maps authentication, executable, exit, timeout, and malformed output errors" do
    assert {:error, :todoist_cli_missing} =
             CLI.run_for_test(["task", "list"], executable_finder: fn "td" -> nil end)

    assert {:error, {:todoist_cli_exit, 7, "failed"}} =
             CLI.run_for_test(
               ["task", "list"],
               executable_finder: fn "td" -> "/usr/local/bin/td" end,
               system_runner: fn "/usr/local/bin/td", ["task", "list"], _opts -> {"failed\n", 7} end
             )

    assert {:error, :todoist_cli_timeout} =
             CLI.run_for_test(
               ["task", "list"],
               timeout_ms: 1,
               executable_finder: fn "td" -> "/usr/local/bin/td" end,
               system_runner: fn _executable, _args, _opts ->
                 Process.sleep(50)
                 {"", 0}
               end
             )

    unauthenticated = fn
      ["--no-spinner", "auth", "status"] ->
        {:error, {:todoist_cli_exit, 1, "not authenticated"}}

      _args ->
        flunk("scope discovery must stop after failed authentication")
    end

    assert {:error, :todoist_cli_unauthenticated} =
             CLI.resolve_scope_for_test(%{provider: %{}}, unauthenticated)

    assert {:error, :todoist_invalid_json} = CLI.decode_output_for_test("{", :json)
    assert {:error, :todoist_invalid_ndjson} = CLI.decode_output_for_test("{}\n{", :ndjson)
    assert {:ok, []} = CLI.decode_output_for_test("\n", :ndjson)

    assert {:ok, [%{"id" => "1"}, %{"id" => "2"}]} =
             CLI.decode_output_for_test(~s({"id":"1"}\n{"id":"2"}\n), :ndjson)

    polish = Jason.encode!(%{"id" => "3", "description" => "agregujemy codziennie jakąś funkcją"})

    assert {:ok, [%{"id" => "3", "description" => "agregujemy codziennie jakąś funkcją"}]} =
             CLI.decode_output_for_test(polish <> "\r\n", :ndjson)
  end

  test "lists tasks by canonical project id and rejects foreign results" do
    scope = scope()
    test_pid = self()

    runner = fn args ->
      send(test_pid, {:td_args, args})
      {:ok, ndjson([task("task-1")])}
    end

    assert {:ok, [%{"id" => "task-1"}]} = CLI.list_tasks_for_test(scope, runner)

    assert_received {:td_args,
                     [
                       "--no-spinner",
                       "task",
                       "list",
                       "--project",
                       "id:project-1",
                       "--all",
                       "--ndjson",
                       "--full",
                       "--show-urls"
                     ]}

    assert {:error, {:todoist_cross_project_task, "foreign"}} =
             CLI.list_tasks_for_test(
               scope,
               fn _args -> {:ok, ndjson([task("foreign", "other-project")])} end
             )
  end

  test "task and comment writes use only verified canonical ids" do
    scope = scope()
    test_pid = self()
    Process.put(:moved, false)

    runner = fn args ->
      send(test_pid, {:td_args, args})

      case args do
        ["--no-spinner", "task", "view", "id:task-1", "--json", "--full"] ->
          section_id = if Process.get(:moved), do: "section-inprogress", else: "section-todo"
          {:ok, Jason.encode!(task("task-1") |> Map.put("sectionId", section_id))}

        [
          "--no-spinner",
          "task",
          "move",
          "id:task-1",
          "--project",
          "id:project-1",
          "--section",
          "id:section-inprogress"
        ] ->
          Process.put(:moved, true)
          {:ok, "moved"}

        ["--no-spinner", "comment", "view", "id:comment-1", "--json", "--full"] ->
          {:ok, Jason.encode!(%{"id" => "comment-1", "taskId" => "task-1", "content" => "old"})}

        [
          "--no-spinner",
          "comment",
          "update",
          "id:comment-1",
          "--content",
          "new",
          "--json"
        ] ->
          {:ok, Jason.encode!(%{"id" => "comment-1", "taskId" => "task-1", "content" => "new"})}

        [
          "--no-spinner",
          "task",
          "add",
          "Follow-up",
          "--project",
          "id:project-1",
          "--section",
          "id:section-backlog",
          "--description",
          "Details",
          "--json"
        ] ->
          {:ok,
           Jason.encode!(
             task("created")
             |> Map.put("sectionId", "section-backlog")
             |> Map.put("content", "Follow-up")
           )}

        other ->
          flunk("unexpected td args: #{inspect(other)}")
      end
    end

    assert {:ok, %{"sectionId" => "section-inprogress"}} =
             CLI.move_task_for_test(scope, "task-1", "InProgress", runner)

    assert {:ok, %{"content" => "new"}} =
             CLI.update_comment_for_test(scope, "comment-1", "new", runner)

    assert {:ok, %{"id" => "created", "projectId" => "project-1"}} =
             CLI.create_task_for_test(scope, "Follow-up", %{"description" => "Details"}, runner)
  end

  test "rejects cross-project tasks and comment parents before mutation" do
    scope = scope()

    assert {:error, {:todoist_cross_project_task, "task-1"}} =
             CLI.move_task_for_test(scope, "task-1", "InProgress", fn
               ["--no-spinner", "task", "view", "id:task-1", "--json", "--full"] ->
                 {:ok, Jason.encode!(task("task-1", "other-project"))}

               _args ->
                 flunk("foreign task must not be moved")
             end)

    assert {:error, {:todoist_cross_project_task, "foreign"}} =
             CLI.update_comment_for_test(scope, "comment-1", "new", fn
               ["--no-spinner", "comment", "view", "id:comment-1", "--json", "--full"] ->
                 {:ok, Jason.encode!(%{"id" => "comment-1", "taskId" => "foreign"})}

               ["--no-spinner", "task", "view", "id:foreign", "--json", "--full"] ->
                 {:ok, Jason.encode!(task("foreign", "other-project"))}

               _args ->
                 flunk("foreign comment must not be updated")
             end)

    assert {:error, {:unknown_todoist_section, "Elsewhere"}} =
             CLI.move_task_for_test(scope, "task-1", "Elsewhere", fn _args ->
               flunk("unknown section must fail before task lookup")
             end)
  end

  defp scope_runner(projects \\ [@project], project_sections \\ sections()) do
    fn args -> scope_response(args, projects, project_sections) end
  end

  defp scope_response(["--no-spinner", "auth", "status"], _projects, _sections), do: {:ok, "ok"}

  defp scope_response(
         ["--no-spinner", "project", "list", "--search", "_agents", "--all", "--ndjson", "--full"],
         projects,
         _sections
       ),
       do: {:ok, ndjson(projects)}

  defp scope_response(
         [
           "--no-spinner",
           "section",
           "list",
           "--project",
           "id:project-1",
           "--all",
           "--ndjson",
           "--full"
         ],
         _projects,
         project_sections
       ),
       do: {:ok, ndjson(project_sections)}

  defp scope_response(args, _projects, _sections), do: flunk("unexpected td args: #{inspect(args)}")

  defp sections do
    Enum.map(@section_names, fn name ->
      %{
        "id" => "section-#{name |> String.downcase() |> String.replace(" ", "-")}",
        "name" => name,
        "projectId" => "project-1",
        "isArchived" => false,
        "isDeleted" => false
      }
    end)
  end

  defp scope do
    sections_by_name =
      Map.new(sections(), fn section ->
        {section["name"], %{id: section["id"], name: section["name"], project_id: section["projectId"]}}
      end)

    %{
      project_id: "project-1",
      project_name: "_agents",
      sections_by_name: sections_by_name,
      sections_by_id: Map.new(sections_by_name, fn {_name, section} -> {section.id, section} end)
    }
  end

  defp task(id, project_id \\ "project-1") do
    %{
      "id" => id,
      "projectId" => project_id,
      "sectionId" => "section-todo",
      "content" => "Task #{id}",
      "description" => "Description",
      "checked" => false,
      "isDeleted" => false,
      "labels" => [],
      "priority" => 1
    }
  end

  defp ndjson(items), do: Enum.map_join(items, "\n", &Jason.encode!/1)
end
