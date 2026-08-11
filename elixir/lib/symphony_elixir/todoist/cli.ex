defmodule SymphonyElixir.Todoist.CLI do
  @moduledoc """
  Typed, project-scoped boundary around the official Todoist `td` CLI.

  The configured project and its workflow sections are resolved during tracker
  validation. Only canonical `id:<id>` references are used after that point.
  """

  @default_project "_agents"
  @default_timeout_ms 30_000
  @max_diagnostic_bytes 1_000
  @scope_key {__MODULE__, :scope}
  @required_sections ["Backlog", "Todo", "InProgress", "HumanReview", "Rework", "Merging", "Done"]

  @type section :: %{id: String.t(), name: String.t(), project_id: String.t()}
  @type scope :: %{
          project_id: String.t(),
          project_name: String.t(),
          sections_by_name: %{String.t() => section()},
          sections_by_id: %{String.t() => section()}
        }
  @type runner :: ([String.t()] -> {:ok, String.t()} | {:error, term()})

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, scope} <- resolve_scope(tracker_settings, &run/1) do
      :persistent_term.put(@scope_key, scope)
      :ok
    end
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  @spec current_scope(map()) :: {:ok, scope()} | {:error, term()}
  def current_scope(tracker_settings) do
    with {:ok, project_name} <- configured_project_name(tracker_settings) do
      case :persistent_term.get(@scope_key, nil) do
        %{project_name: ^project_name} = scope ->
          {:ok, scope}

        _ ->
          with {:ok, scope} <- resolve_scope(tracker_settings, &run/1) do
            :persistent_term.put(@scope_key, scope)
            {:ok, scope}
          end
      end
    end
  end

  @spec list_tasks(map()) :: {:ok, [map()]} | {:error, term()}
  def list_tasks(tracker_settings) do
    with {:ok, scope} <- current_scope(tracker_settings) do
      list_tasks(scope, &run/1)
    end
  end

  @spec get_task(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_task(tracker_settings, task_id) do
    with {:ok, scope} <- current_scope(tracker_settings) do
      get_task(scope, task_id, &run/1)
    end
  end

  @spec move_task(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def move_task(tracker_settings, task_id, section_name) do
    with {:ok, scope} <- current_scope(tracker_settings) do
      move_task(scope, task_id, section_name, &run/1)
    end
  end

  @spec update_task(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_task(tracker_settings, task_id, changes) do
    with {:ok, scope} <- current_scope(tracker_settings) do
      update_task(scope, task_id, changes, &run/1)
    end
  end

  @spec list_comments(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(tracker_settings, task_id) do
    with {:ok, scope} <- current_scope(tracker_settings) do
      list_comments(scope, task_id, &run/1)
    end
  end

  @spec create_comment(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_comment(tracker_settings, task_id, content) do
    with {:ok, scope} <- current_scope(tracker_settings) do
      create_comment(scope, task_id, content, &run/1)
    end
  end

  @spec update_comment(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_comment(tracker_settings, comment_id, content) do
    with {:ok, scope} <- current_scope(tracker_settings) do
      update_comment(scope, comment_id, content, &run/1)
    end
  end

  @spec create_task(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_task(tracker_settings, content, attributes) do
    with {:ok, scope} <- current_scope(tracker_settings) do
      create_task(scope, content, attributes, &run/1)
    end
  end

  @doc false
  @spec resolve_scope_for_test(map(), runner()) :: {:ok, scope()} | {:error, term()}
  def resolve_scope_for_test(tracker_settings, runner), do: resolve_scope(tracker_settings, runner)

  @doc false
  @spec list_tasks_for_test(scope(), runner()) :: {:ok, [map()]} | {:error, term()}
  def list_tasks_for_test(scope, runner), do: list_tasks(scope, runner)

  @doc false
  @spec move_task_for_test(scope(), String.t(), String.t(), runner()) ::
          {:ok, map()} | {:error, term()}
  def move_task_for_test(scope, task_id, section_name, runner) do
    move_task(scope, task_id, section_name, runner)
  end

  @doc false
  @spec update_comment_for_test(scope(), String.t(), String.t(), runner()) ::
          {:ok, map()} | {:error, term()}
  def update_comment_for_test(scope, comment_id, content, runner) do
    update_comment(scope, comment_id, content, runner)
  end

  @doc false
  @spec create_task_for_test(scope(), String.t(), map(), runner()) ::
          {:ok, map()} | {:error, term()}
  def create_task_for_test(scope, content, attributes, runner) do
    create_task(scope, content, attributes, runner)
  end

  @doc false
  @spec decode_output_for_test(String.t(), :json | :ndjson) :: {:ok, term()} | {:error, term()}
  def decode_output_for_test(output, format), do: decode_output(output, format)

  @doc false
  @spec run_for_test([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_for_test(args, opts), do: run(args, opts)

  @doc false
  @spec clear_scope_for_test() :: :ok
  def clear_scope_for_test do
    :persistent_term.erase(@scope_key)
    :ok
  end

  defp resolve_scope(tracker_settings, runner) when is_function(runner, 1) do
    with {:ok, project_name} <- configured_project_name(tracker_settings),
         :ok <- verify_authentication(runner),
         {:ok, projects} <-
           run_decoded(
             runner,
             [
               "--no-spinner",
               "project",
               "list",
               "--search",
               project_name,
               "--all",
               "--ndjson",
               "--full"
             ],
             :ndjson
           ),
         {:ok, project_id} <- unique_project_id(projects, project_name),
         {:ok, sections} <-
           run_decoded(
             runner,
             [
               "--no-spinner",
               "section",
               "list",
               "--project",
               id_ref(project_id),
               "--all",
               "--ndjson",
               "--full"
             ],
             :ndjson
           ),
         {:ok, sections_by_name, sections_by_id} <- validate_sections(sections, project_id) do
      {:ok,
       %{
         project_id: project_id,
         project_name: project_name,
         sections_by_name: sections_by_name,
         sections_by_id: sections_by_id
       }}
    end
  end

  defp configured_project_name(%{provider: provider}) when is_map(provider) do
    normalize_project_name(Map.get(provider, "project", @default_project))
  end

  defp configured_project_name(_tracker_settings), do: {:ok, @default_project}

  defp normalize_project_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_todoist_project}
      project -> {:ok, project}
    end
  end

  defp normalize_project_name(_value), do: {:error, :invalid_todoist_project}

  defp verify_authentication(runner) do
    case runner.(["--no-spinner", "auth", "status"]) do
      {:ok, _output} -> :ok
      {:error, _reason} -> {:error, :todoist_cli_unauthenticated}
    end
  end

  defp unique_project_id(projects, project_name) when is_list(projects) do
    matches =
      Enum.filter(projects, fn project ->
        is_map(project) and project["name"] == project_name and project["isArchived"] != true and
          project["isDeleted"] != true and present_id?(project["id"])
      end)

    case matches do
      [%{"id" => project_id}] -> {:ok, project_id}
      [] -> {:error, :missing_todoist_project}
      _ -> {:error, :ambiguous_todoist_project}
    end
  end

  defp unique_project_id(_projects, _project_name), do: {:error, :todoist_invalid_project_payload}

  defp validate_sections(sections, project_id) when is_list(sections) do
    active_sections =
      Enum.filter(sections, fn section ->
        is_map(section) and section["isArchived"] != true and section["isDeleted"] != true
      end)

    with :ok <- reject_cross_project_sections(active_sections, project_id),
         :ok <- reject_ambiguous_sections(active_sections),
         :ok <- reject_missing_sections(active_sections) do
      normalized =
        Enum.map(active_sections, fn section ->
          %{
            id: section["id"],
            name: section["name"],
            project_id: section["projectId"]
          }
        end)

      {:ok, Map.new(normalized, &{&1.name, &1}), Map.new(normalized, &{&1.id, &1})}
    end
  end

  defp validate_sections(_sections, _project_id), do: {:error, :todoist_invalid_section_payload}

  defp reject_cross_project_sections(sections, project_id) do
    case Enum.find(sections, &(&1["projectId"] != project_id)) do
      %{"id" => section_id} -> {:error, {:todoist_cross_project_section, section_id}}
      nil -> :ok
      _ -> {:error, :todoist_invalid_section_payload}
    end
  end

  defp reject_ambiguous_sections(sections) do
    duplicate =
      sections
      |> Enum.group_by(& &1["name"])
      |> Enum.find(fn {name, matches} -> name in @required_sections and length(matches) > 1 end)

    case duplicate do
      {name, _matches} -> {:error, {:ambiguous_todoist_section, name}}
      nil -> :ok
    end
  end

  defp reject_missing_sections(sections) do
    names = MapSet.new(sections, & &1["name"])
    missing = Enum.reject(@required_sections, &MapSet.member?(names, &1))
    if missing == [], do: :ok, else: {:error, {:missing_todoist_sections, missing}}
  end

  defp list_tasks(scope, runner) do
    with {:ok, tasks} <-
           run_decoded(
             runner,
             [
               "--no-spinner",
               "task",
               "list",
               "--project",
               id_ref(scope.project_id),
               "--all",
               "--ndjson",
               "--full",
               "--show-urls"
             ],
             :ndjson
           ),
         :ok <- validate_project_tasks(tasks, scope.project_id) do
      {:ok, tasks}
    end
  end

  defp validate_project_tasks(tasks, project_id) when is_list(tasks) do
    case Enum.find(tasks, &(not is_map(&1) or &1["projectId"] != project_id)) do
      %{"id" => task_id} -> {:error, {:todoist_cross_project_task, task_id}}
      nil -> :ok
      _ -> {:error, :todoist_invalid_task_payload}
    end
  end

  defp validate_project_tasks(_tasks, _project_id), do: {:error, :todoist_invalid_task_payload}

  defp get_task(scope, task_id, runner) do
    with {:ok, task_ref} <- safe_id_ref(task_id),
         {:ok, task} <-
           run_decoded(
             runner,
             ["--no-spinner", "task", "view", task_ref, "--json", "--full"],
             :json
           ),
         :ok <- validate_task(task, task_id, scope.project_id) do
      {:ok, task}
    end
  end

  defp validate_task(%{"id" => task_id, "projectId" => project_id}, expected_id, project_id)
       when task_id == expected_id,
       do: :ok

  defp validate_task(%{"id" => task_id}, _expected_id, _project_id) when is_binary(task_id),
    do: {:error, {:todoist_cross_project_task, task_id}}

  defp validate_task(_task, _expected_id, _project_id), do: {:error, :todoist_invalid_task_payload}

  defp move_task(scope, task_id, section_name, runner) do
    with {:ok, section} <- find_section(scope, section_name),
         {:ok, task_ref} <- safe_id_ref(task_id),
         {:ok, _task} <- get_task(scope, task_id, runner),
         {:ok, _output} <-
           runner.([
             "--no-spinner",
             "task",
             "move",
             task_ref,
             "--project",
             id_ref(scope.project_id),
             "--section",
             id_ref(section.id)
           ]),
         {:ok, moved_task} <- get_task(scope, task_id, runner),
         :ok <- verify_task_section(moved_task, section.id) do
      {:ok, moved_task}
    end
  end

  defp find_section(scope, section_name) when is_binary(section_name) do
    case Map.get(scope.sections_by_name, String.trim(section_name)) do
      %{project_id: project_id} = section when project_id == scope.project_id -> {:ok, section}
      %{id: section_id} -> {:error, {:todoist_cross_project_section, section_id}}
      nil -> {:error, {:unknown_todoist_section, String.trim(section_name)}}
    end
  end

  defp find_section(_scope, section_name), do: {:error, {:unknown_todoist_section, section_name}}

  defp verify_task_section(%{"sectionId" => section_id}, section_id), do: :ok
  defp verify_task_section(_task, _section_id), do: {:error, :todoist_task_move_not_applied}

  defp update_task(scope, task_id, changes, runner) when is_map(changes) do
    with {:ok, task_ref} <- safe_id_ref(task_id),
         {:ok, _task} <- get_task(scope, task_id, runner),
         {:ok, change_args} <- task_change_args(changes),
         {:ok, updated_task} <-
           run_decoded(
             runner,
             ["--no-spinner", "task", "update", task_ref] ++ change_args ++ ["--json"],
             :json
           ),
         :ok <- validate_task(updated_task, task_id, scope.project_id) do
      {:ok, updated_task}
    end
  end

  defp update_task(_scope, _task_id, _changes, _runner), do: {:error, :invalid_todoist_task_changes}

  defp task_change_args(changes) do
    allowed = Map.take(changes, ["content", "description", "labels", "priority"])

    with :ok <- reject_unknown_change_keys(changes, allowed),
         {:ok, args} <- append_optional_text([], "--content", allowed["content"]),
         {:ok, args} <- append_optional_text(args, "--description", allowed["description"]),
         {:ok, args} <- append_optional_labels(args, allowed["labels"]),
         {:ok, args} <- append_optional_priority(args, allowed["priority"]) do
      if args == [], do: {:error, :empty_todoist_task_changes}, else: {:ok, args}
    end
  end

  defp reject_unknown_change_keys(changes, allowed) do
    if map_size(changes) == map_size(allowed), do: :ok, else: {:error, :invalid_todoist_task_changes}
  end

  defp list_comments(scope, task_id, runner) do
    with {:ok, task_ref} <- safe_id_ref(task_id),
         {:ok, _task} <- get_task(scope, task_id, runner),
         {:ok, comments} <-
           run_decoded(
             runner,
             ["--no-spinner", "comment", "list", task_ref, "--all", "--ndjson", "--full"],
             :ndjson
           ),
         :ok <- validate_comments(comments, task_id) do
      {:ok, comments}
    end
  end

  defp validate_comments(comments, task_id) when is_list(comments) do
    if Enum.all?(comments, &(is_map(&1) and &1["taskId"] == task_id)) do
      :ok
    else
      {:error, :todoist_invalid_comment_parent}
    end
  end

  defp validate_comments(_comments, _task_id), do: {:error, :todoist_invalid_comment_payload}

  defp create_comment(scope, task_id, content, runner) when is_binary(content) do
    with {:ok, task_ref} <- safe_id_ref(task_id),
         {:ok, _task} <- get_task(scope, task_id, runner),
         {:ok, comment} <-
           run_decoded(
             runner,
             ["--no-spinner", "comment", "add", task_ref, "--content", content, "--json"],
             :json
           ),
         :ok <- validate_comment(comment, task_id) do
      {:ok, comment}
    end
  end

  defp create_comment(_scope, _task_id, _content, _runner), do: {:error, :invalid_todoist_comment_content}

  defp update_comment(scope, comment_id, content, runner) when is_binary(content) do
    with {:ok, comment_ref} <- safe_id_ref(comment_id),
         {:ok, comment} <-
           run_decoded(
             runner,
             ["--no-spinner", "comment", "view", comment_ref, "--json", "--full"],
             :json
           ),
         {:ok, task_id} <- comment_task_id(comment),
         {:ok, _task} <- get_task(scope, task_id, runner),
         {:ok, updated_comment} <-
           run_decoded(
             runner,
             ["--no-spinner", "comment", "update", comment_ref, "--content", content, "--json"],
             :json
           ),
         :ok <- validate_comment(updated_comment, task_id) do
      {:ok, updated_comment}
    end
  end

  defp update_comment(_scope, _comment_id, _content, _runner),
    do: {:error, :invalid_todoist_comment_content}

  defp validate_comment(%{"id" => id, "taskId" => task_id}, task_id) when is_binary(id), do: :ok
  defp validate_comment(_comment, _task_id), do: {:error, :todoist_invalid_comment_parent}

  defp comment_task_id(%{"taskId" => task_id}) when is_binary(task_id) and task_id != "",
    do: {:ok, task_id}

  defp comment_task_id(_comment), do: {:error, :todoist_invalid_comment_parent}

  defp create_task(scope, content, attributes, runner) when is_binary(content) and is_map(attributes) do
    with {:ok, backlog} <- find_section(scope, "Backlog"),
         {:ok, content} <- nonblank_text(content, :invalid_todoist_task_content),
         {:ok, attribute_args} <- task_create_args(attributes),
         {:ok, task} <-
           run_decoded(
             runner,
             [
               "--no-spinner",
               "task",
               "add",
               content,
               "--project",
               id_ref(scope.project_id),
               "--section",
               id_ref(backlog.id)
             ] ++ attribute_args ++ ["--json"],
             :json
           ),
         :ok <- validate_created_task(task, scope.project_id, backlog.id) do
      {:ok, task}
    end
  end

  defp create_task(_scope, _content, _attributes, _runner), do: {:error, :invalid_todoist_task_content}

  defp task_create_args(attributes) do
    allowed = Map.take(attributes, ["description", "labels", "priority"])

    with :ok <- reject_unknown_change_keys(attributes, allowed),
         {:ok, args} <- append_optional_text([], "--description", allowed["description"]),
         {:ok, args} <- append_optional_labels(args, allowed["labels"]),
         {:ok, args} <- append_optional_priority(args, allowed["priority"]) do
      {:ok, args}
    end
  end

  defp validate_created_task(%{"id" => id, "projectId" => project_id, "sectionId" => section_id}, project_id, section_id)
       when is_binary(id),
       do: :ok

  defp validate_created_task(%{"id" => id}, _project_id, _section_id) when is_binary(id),
    do: {:error, {:todoist_cross_project_task, id}}

  defp validate_created_task(_task, _project_id, _section_id),
    do: {:error, :todoist_invalid_task_payload}

  defp append_optional_text(args, _flag, nil), do: {:ok, args}

  defp append_optional_text(args, flag, value) when is_binary(value),
    do: {:ok, args ++ [flag, value]}

  defp append_optional_text(_args, _flag, _value), do: {:error, :invalid_todoist_task_changes}

  defp append_optional_labels(args, nil), do: {:ok, args}

  defp append_optional_labels(args, labels) when is_list(labels) do
    if Enum.all?(labels, &(is_binary(&1) and String.trim(&1) != "" and not String.contains?(&1, ","))) do
      {:ok, args ++ ["--labels", Enum.join(labels, ",")]}
    else
      {:error, :invalid_todoist_task_changes}
    end
  end

  defp append_optional_labels(_args, _labels), do: {:error, :invalid_todoist_task_changes}

  defp append_optional_priority(args, nil), do: {:ok, args}

  defp append_optional_priority(args, priority) when priority in ["p1", "p2", "p3", "p4"],
    do: {:ok, args ++ ["--priority", priority]}

  defp append_optional_priority(_args, _priority), do: {:error, :invalid_todoist_task_changes}

  defp nonblank_text(value, error) when is_binary(value) do
    if String.trim(value) == "", do: {:error, error}, else: {:ok, value}
  end

  defp run_decoded(runner, args, format) do
    with {:ok, output} <- runner.(args), do: decode_output(output, format)
  end

  defp decode_output(output, :json) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :todoist_invalid_json}
    end
  end

  defp decode_output(output, :ndjson) when is_binary(output) do
    output
    |> String.split(~r/\R/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, decoded} ->
      case Jason.decode(line) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, _reason} -> {:halt, {:error, :todoist_invalid_ndjson}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_output(_output, :json), do: {:error, :todoist_invalid_json}
  defp decode_output(_output, :ndjson), do: {:error, :todoist_invalid_ndjson}

  defp run(args), do: run(args, [])

  defp run(args, opts) do
    executable_finder = Keyword.get(opts, :executable_finder, &System.find_executable/1)
    system_runner = Keyword.get(opts, :system_runner, &System.cmd/3)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case executable_finder.("td") do
      executable when is_binary(executable) ->
        run_executable(executable, args, timeout_ms, system_runner)

      _ ->
        {:error, :todoist_cli_missing}
    end
  end

  defp run_executable(executable, args, timeout_ms, system_runner) do
    task =
      Task.async(fn ->
        system_runner.(executable, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, 0}} when is_binary(output) ->
        {:ok, output}

      {:ok, {output, status}} when is_binary(output) and is_integer(status) ->
        {:error, {:todoist_cli_exit, status, diagnostic(output)}}

      {:exit, reason} ->
        {:error, {:todoist_cli_request, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :todoist_cli_timeout}
    end
  end

  defp diagnostic(output) do
    output
    |> String.trim()
    |> String.slice(0, @max_diagnostic_bytes)
  end

  defp safe_id_ref(id) when is_binary(id) do
    if String.match?(id, ~r/^[A-Za-z0-9_-]+$/) do
      {:ok, id_ref(id)}
    else
      {:error, :invalid_todoist_id}
    end
  end

  defp safe_id_ref(_id), do: {:error, :invalid_todoist_id}
  defp id_ref(id), do: "id:" <> id
  defp present_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp present_id?(_id), do: false
end
