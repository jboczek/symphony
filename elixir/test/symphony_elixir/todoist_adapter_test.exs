defmodule SymphonyElixir.Todoist.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Todoist.Adapter

  defmodule FakeCLI do
    alias SymphonyElixir.Todoist.AdapterTest

    @spec validate_settings(map()) :: :ok
    def validate_settings(settings) do
      send(Application.fetch_env!(:symphony_elixir, :todoist_test_pid), {:todoist_validate_settings, settings})
      :ok
    end

    @spec list_tasks(map()) :: {:ok, [map()]}
    def list_tasks(_settings), do: {:ok, Application.get_env(:symphony_elixir, :todoist_test_tasks, [])}

    @spec current_scope(map()) :: {:ok, map()}
    def current_scope(_settings), do: {:ok, AdapterTest.scope()}

    @spec secret_environment_names(map()) :: [String.t()]
    def secret_environment_names(_settings), do: []
  end

  setup do
    previous_cli = Application.get_env(:symphony_elixir, :todoist_cli_module)
    previous_tasks = Application.get_env(:symphony_elixir, :todoist_test_tasks)
    previous_test_pid = Application.get_env(:symphony_elixir, :todoist_test_pid)

    Application.put_env(:symphony_elixir, :todoist_cli_module, FakeCLI)
    Application.put_env(:symphony_elixir, :todoist_test_pid, self())

    on_exit(fn ->
      restore_app_env(:todoist_cli_module, previous_cli)
      restore_app_env(:todoist_test_tasks, previous_tasks)
      restore_app_env(:todoist_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "registers todoist and validates state plus CLI configuration" do
    settings = tracker_settings()

    assert {:ok, Adapter} = Tracker.adapter_for_kind("todoist")
    assert :ok = Adapter.validate_config(settings)
    assert_received {:todoist_validate_settings, ^settings}

    assert {:error, :missing_todoist_active_states} =
             Adapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_todoist_terminal_states} =
             Adapter.validate_config(%{settings | terminal_states: nil})

    assert {:error, :invalid_todoist_states} =
             Adapter.validate_config(%{settings | active_states: [""]})

    assert {:error, :invalid_todoist_states} =
             Adapter.validate_config(%{settings | terminal_states: [42]})

    assert Adapter.secret_environment_names(settings) == []
  end

  test "normalizes project tasks into current Issue fields" do
    issue = Adapter.normalize_issue_for_test(task("42"), scope())

    assert issue.id == "42"
    assert issue.identifier == "TODOIST-42"
    assert issue.title == "Task 42"
    assert issue.description == "Description 42"
    assert issue.priority == 1
    assert issue.state == "Todo"
    assert issue.branch_name == nil
    assert issue.url == "https://app.todoist.test/task/42"
    assert issue.assignee_id == "user-1"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    assert issue.native_ref == %{
             "project_id" => "project-1",
             "task_id" => "42",
             "section_id" => "section-todo"
           }

    assert Adapter.normalize_issue_for_test(Map.put(task("43"), "priority", 3), scope()).priority == 2
    assert Adapter.normalize_issue_for_test(Map.put(task("44"), "priority", 2), scope()).priority == 3
    assert Adapter.normalize_issue_for_test(Map.put(task("45"), "priority", 1), scope()).priority == 4
    assert Adapter.normalize_issue_for_test(Map.put(task("46"), "priority", 9), scope()).priority == nil
    refute Adapter.normalize_issue_for_test(Map.put(task("47"), "checked", true), scope()).dispatchable
    refute Adapter.normalize_issue_for_test(Map.put(task("48"), "isDeleted", true), scope()).dispatchable
    assert Adapter.normalize_issue_for_test(Map.put(task("49"), "parentId", "42"), scope()).blocked_by == []
    assert Adapter.normalize_issue_for_test(Map.put(task("50"), "sectionId", "unknown"), scope()) == nil
    assert Adapter.normalize_issue_for_test(task("51", "other-project"), scope()) == nil
  end

  test "fetches requested states and IDs while dropping or rejecting malformed records" do
    Application.put_env(:symphony_elixir, :todoist_test_tasks, [
      task("todo"),
      task("review") |> Map.put("sectionId", "section-humanreview"),
      task("rework") |> Map.put("sectionId", "section-rework"),
      task("done") |> Map.put("sectionId", "section-done"),
      Map.put(task("malformed"), "content", "")
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "todoist",
      tracker_active_states: ["Todo", "InProgress", "Rework", "Merging"],
      tracker_terminal_states: ["Done"]
    )

    assert {:ok, issues} = Adapter.fetch_issues_by_states([" todo ", "Rework"])
    assert Enum.map(issues, & &1.id) == ["todo", "rework"]

    assert {:ok, refreshed} = Adapter.fetch_issues_by_ids(["done", "review", "done", "missing"])
    assert Enum.map(refreshed, & &1.id) == ["review", "done"]

    assert {:ok, []} = Adapter.fetch_issues_by_states([])
    assert {:ok, []} = Adapter.fetch_issues_by_ids([])

    assert {:error, :todoist_unknown_payload} = Adapter.fetch_issues_by_ids(["malformed"])
  end

  test "rejects foreign task payloads even if a CLI implementation returns them" do
    Application.put_env(:symphony_elixir, :todoist_test_tasks, [task("foreign", "other-project")])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "todoist",
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"]
    )

    assert {:error, {:todoist_cross_project_task, "foreign"}} =
             Adapter.fetch_issues_by_states(["Todo"])

    assert {:error, {:todoist_cross_project_task, "foreign"}} =
             Adapter.fetch_issues_by_ids(["foreign"])
  end

  @spec scope() :: map()
  def scope do
    section_names = ["Backlog", "Todo", "InProgress", "HumanReview", "Rework", "Merging", "Done"]

    sections_by_name =
      Map.new(section_names, fn name ->
        id = "section-#{name |> String.downcase() |> String.replace(" ", "-")}"
        {name, %{id: id, name: name, project_id: "project-1"}}
      end)

    %{
      project_id: "project-1",
      project_name: "_agents",
      sections_by_name: sections_by_name,
      sections_by_id: Map.new(sections_by_name, fn {_name, section} -> {section.id, section} end)
    }
  end

  defp tracker_settings do
    %{
      kind: "todoist",
      provider: %{"project" => "_agents"},
      active_states: ["Todo", "InProgress", "Rework", "Merging"],
      terminal_states: ["Done"]
    }
  end

  defp task(id, project_id \\ "project-1") do
    %{
      "id" => id,
      "projectId" => project_id,
      "sectionId" => "section-todo",
      "parentId" => nil,
      "content" => "Task #{id}",
      "description" => " Description #{id} ",
      "checked" => false,
      "isDeleted" => false,
      "labels" => [" Bug ", "bug", "Platform", " "],
      "priority" => 4,
      "responsibleUid" => "user-1",
      "addedAt" => "2026-08-10T12:00:00.000Z",
      "updatedAt" => "2026-08-11T12:00:00.000Z",
      "webUrl" => "https://app.todoist.test/task/#{id}"
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
