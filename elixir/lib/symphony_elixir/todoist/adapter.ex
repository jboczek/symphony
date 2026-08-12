defmodule SymphonyElixir.Todoist.Adapter do
  @moduledoc """
  Tracker adapter backed by Todoist project sections as issue states.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.TaskExecutionSettings
  alias SymphonyElixir.Todoist.AgentTool
  alias SymphonyElixir.Tracker.Issue

  @impl true
  def validate_config(tracker_settings) do
    with :ok <- validate_states(tracker_settings.active_states, :missing_todoist_active_states),
         :ok <- validate_states(tracker_settings.terminal_states, :missing_todoist_terminal_states) do
      cli_module().validate_settings(tracker_settings)
    end
  end

  @impl true
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(states) when is_list(states) do
    tracker_settings = Config.settings!().tracker

    with {:ok, scope} <- cli_module().current_scope(tracker_settings),
         {:ok, tasks} <- cli_module().list_tasks(tracker_settings),
         :ok <- validate_project_tasks(tasks, scope.project_id) do
      requested_states = states |> Enum.map(&normalize_state/1) |> MapSet.new()
      issues = Enum.map(tasks, &normalize_issue(&1, scope))
      malformed_count = Enum.count(issues, &is_nil/1)

      if malformed_count > 0 do
        Logger.warning("Dropping malformed Todoist task records count=#{malformed_count}")
      end

      {:ok,
       issues
       |> Enum.reject(&is_nil/1)
       |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))}
    end
  end

  @impl true
  def fetch_issues_by_ids([]), do: {:ok, []}

  def fetch_issues_by_ids(ids) when is_list(ids) do
    tracker_settings = Config.settings!().tracker
    requested_ids = ids |> Enum.filter(&is_binary/1) |> MapSet.new()

    with {:ok, scope} <- cli_module().current_scope(tracker_settings),
         {:ok, tasks} <- cli_module().list_tasks(tracker_settings),
         :ok <- validate_project_tasks(tasks, scope.project_id) do
      tasks
      |> Enum.filter(&MapSet.member?(requested_ids, &1["id"]))
      |> normalize_requested_tasks(scope)
    end
  end

  @impl true
  def agent_tool_specs, do: AgentTool.tool_specs()

  @impl true
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @impl true
  def secret_environment_names(tracker_settings) do
    cli_module().secret_environment_names(tracker_settings)
  end

  @doc false
  @spec normalize_issue_for_test(map(), map()) :: Issue.t() | nil
  def normalize_issue_for_test(task, scope) when is_map(task) and is_map(scope) do
    normalize_issue(task, scope)
  end

  defp normalize_requested_tasks(tasks, scope) do
    Enum.reduce_while(tasks, {:ok, []}, fn task, {:ok, issues} ->
      case normalize_issue(task, scope) do
        %Issue{} = issue -> {:cont, {:ok, [issue | issues]}}
        nil -> {:halt, {:error, :todoist_unknown_payload}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp normalize_issue(
         %{
           "id" => id,
           "projectId" => project_id,
           "sectionId" => section_id,
           "content" => content
         } = task,
         %{project_id: project_id, sections_by_id: sections_by_id}
       )
       when is_binary(id) and is_binary(section_id) and is_binary(content) do
    section = Map.get(sections_by_id, section_id)

    if present_string?(id) and present_string?(content) and valid_section?(section, project_id) do
      {description, execution_settings} = normalize_description(task["description"])

      %Issue{
        id: id,
        native_ref: %{
          "project_id" => project_id,
          "task_id" => id,
          "section_id" => section_id
        },
        identifier: "TODOIST-#{id}",
        title: content,
        description: description,
        execution_settings: execution_settings,
        priority: normalize_priority(task["priority"]),
        state: section.name,
        branch_name: nil,
        url: task["webUrl"] || task["url"],
        assignee_id: task["responsibleUid"],
        labels: normalize_labels(task["labels"]),
        blocked_by: [],
        dispatchable: task["checked"] != true and task["isDeleted"] != true,
        created_at: parse_datetime(task["addedAt"]),
        updated_at: parse_datetime(task["updatedAt"])
      }
    end
  end

  defp normalize_issue(_task, _scope), do: nil

  defp validate_project_tasks(tasks, project_id) when is_list(tasks) do
    case Enum.find(tasks, &(not is_map(&1) or &1["projectId"] != project_id)) do
      %{"id" => task_id} -> {:error, {:todoist_cross_project_task, task_id}}
      nil -> :ok
      _ -> {:error, :todoist_unknown_payload}
    end
  end

  defp validate_project_tasks(_tasks, _project_id), do: {:error, :todoist_unknown_payload}

  defp validate_states(states, _missing_error) when is_list(states) do
    if Enum.all?(states, &present_string?/1) do
      :ok
    else
      {:error, :invalid_todoist_states}
    end
  end

  defp validate_states(_states, missing_error), do: {:error, missing_error}

  defp valid_section?(%{name: name, project_id: project_id}, project_id),
    do: present_string?(name)

  defp valid_section?(_section, _project_id), do: false

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_labels(_labels), do: []

  defp normalize_priority(4), do: 1
  defp normalize_priority(3), do: 2
  defp normalize_priority(2), do: 3
  defp normalize_priority(1), do: 4
  defp normalize_priority(_priority), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil

  defp normalize_description(description) do
    case TaskExecutionSettings.parse(description) do
      {:ok, settings, body} -> {blank_to_nil(body), settings}
      {:error, _reason} = error -> {blank_to_nil(description), error}
    end
  end

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""
  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp cli_module do
    Application.get_env(:symphony_elixir, :todoist_cli_module, SymphonyElixir.Todoist.CLI)
  end
end
