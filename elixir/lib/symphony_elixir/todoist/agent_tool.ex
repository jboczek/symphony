defmodule SymphonyElixir.Todoist.AgentTool do
  @moduledoc """
  Allowlisted, project-scoped Todoist operations exposed to Codex turns.

  This tool intentionally has no arbitrary CLI, completion, deletion, project,
  section, archive, or account operation.
  """

  alias SymphonyElixir.{Config, Todoist.CLI}

  @tool_name "todoist"
  @workpad_marker "## Codex Workpad"
  @operations [
    "task_get",
    "task_move",
    "task_update",
    "task_create",
    "comment_list",
    "comment_create",
    "comment_update",
    "workpad_upsert"
  ]
  @operation_keys %{
    "task_get" => ["operation", "task_id"],
    "task_move" => ["operation", "task_id", "section"],
    "task_update" => ["operation", "task_id", "content", "description", "labels", "priority"],
    "task_create" => ["operation", "content", "description", "labels", "priority"],
    "comment_list" => ["operation", "task_id"],
    "comment_create" => ["operation", "task_id", "content"],
    "comment_update" => ["operation", "comment_id", "content"],
    "workpad_upsert" => ["operation", "task_id", "content"]
  }
  @tool_description """
  Read or update the current Symphony Todoist project through scoped, non-destructive operations.
  Use workpad_upsert for the single persistent `## Codex Workpad` comment.
  """
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["operation"],
    "properties" => %{
      "operation" => %{"type" => "string", "enum" => @operations},
      "task_id" => %{"type" => "string", "description" => "Canonical Todoist task ID."},
      "comment_id" => %{"type" => "string", "description" => "Canonical Todoist comment ID."},
      "section" => %{
        "type" => "string",
        "enum" => ["Backlog", "Todo", "InProgress", "HumanReview", "Rework", "Merging", "Done"]
      },
      "content" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "labels" => %{"type" => "array", "items" => %{"type" => "string"}},
      "priority" => %{"type" => "string", "enum" => ["p1", "p2", "p3", "p4"]}
    }
  }

  @type client :: (atom(), map(), map() -> {:ok, term()} | {:error, term()})

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @tool_name,
        "description" => @tool_description,
        "inputSchema" => @input_schema
      }
    ]
  end

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@tool_name, arguments, opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    client = Keyword.get(opts, :todoist_client, &call_cli/3)

    with {:ok, operation, payload} <- normalize_arguments(arguments),
         {:ok, result} <- execute_operation(operation, payload, tracker_settings, client) do
      success_response(%{"operation" => Atom.to_string(operation), "result" => result})
    else
      {:error, reason} -> failure_response(reason)
    end
  end

  def execute(tool, _arguments, _opts), do: unsupported_tool_response(tool)

  defp normalize_arguments(%{"operation" => operation} = arguments) when operation in @operations do
    operation_atom = String.to_existing_atom(operation)

    with :ok <- validate_argument_keys(operation, arguments),
         {:ok, payload} <- operation_payload(operation, arguments) do
      {:ok, operation_atom, payload}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_todoist_arguments}

  defp validate_argument_keys(operation, arguments) do
    allowed = Map.fetch!(@operation_keys, operation)

    if Enum.all?(Map.keys(arguments), &(&1 in allowed)) do
      :ok
    else
      {:error, :invalid_todoist_arguments}
    end
  end

  defp operation_payload("task_get", arguments) do
    with {:ok, task_id} <- required_string(arguments, "task_id") do
      {:ok, %{task_id: task_id}}
    end
  end

  defp operation_payload("task_move", arguments) do
    with {:ok, task_id} <- required_string(arguments, "task_id"),
         {:ok, section} <- required_string(arguments, "section") do
      {:ok, %{task_id: task_id, section: section}}
    end
  end

  defp operation_payload("task_update", arguments) do
    with {:ok, task_id} <- required_string(arguments, "task_id"),
         {:ok, changes} <- task_attributes(arguments, ["content", "description", "labels", "priority"]),
         true <- map_size(changes) > 0 do
      {:ok, %{task_id: task_id, changes: changes}}
    else
      false -> {:error, :invalid_todoist_arguments}
      error -> error
    end
  end

  defp operation_payload("task_create", arguments) do
    with {:ok, content} <- required_string(arguments, "content"),
         {:ok, attributes} <- task_attributes(arguments, ["description", "labels", "priority"]) do
      {:ok, %{content: content, attributes: attributes}}
    end
  end

  defp operation_payload("comment_list", arguments) do
    with {:ok, task_id} <- required_string(arguments, "task_id") do
      {:ok, %{task_id: task_id}}
    end
  end

  defp operation_payload("comment_create", arguments) do
    with {:ok, task_id} <- required_string(arguments, "task_id"),
         {:ok, content} <- required_string(arguments, "content") do
      {:ok, %{task_id: task_id, content: content}}
    end
  end

  defp operation_payload("comment_update", arguments) do
    with {:ok, comment_id} <- required_string(arguments, "comment_id"),
         {:ok, content} <- required_string(arguments, "content") do
      {:ok, %{comment_id: comment_id, content: content}}
    end
  end

  defp operation_payload("workpad_upsert", arguments) do
    with {:ok, task_id} <- required_string(arguments, "task_id"),
         {:ok, content} <- required_string(arguments, "content"),
         true <- workpad_content?(content) do
      {:ok, %{task_id: task_id, content: content}}
    else
      false -> {:error, :invalid_todoist_workpad}
      error -> error
    end
  end

  defp task_attributes(arguments, keys) do
    attributes = Map.take(arguments, keys)

    if Enum.all?(attributes, &valid_attribute?/1) do
      {:ok, attributes}
    else
      {:error, :invalid_todoist_arguments}
    end
  end

  defp valid_attribute?({_key, value}) when is_binary(value), do: true
  defp valid_attribute?({"labels", labels}) when is_list(labels), do: Enum.all?(labels, &is_binary/1)
  defp valid_attribute?(_attribute), do: false

  defp required_string(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, :invalid_todoist_arguments}, else: {:ok, value}

      _ ->
        {:error, :invalid_todoist_arguments}
    end
  end

  defp execute_operation(:workpad_upsert, payload, tracker_settings, client) do
    upsert_workpad(payload, tracker_settings, client)
  end

  defp execute_operation(operation, payload, tracker_settings, client) do
    client.(operation, payload, tracker_settings)
  end

  defp upsert_workpad(%{task_id: task_id, content: content}, tracker_settings, client) do
    with {:ok, comments} <- client.(:comment_list, %{task_id: task_id}, tracker_settings),
         {:ok, workpad} <- find_workpad(comments) do
      persist_workpad(workpad, task_id, content, tracker_settings, client)
    end
  end

  defp persist_workpad(nil, task_id, content, tracker_settings, client) do
    with {:ok, comment} <-
           client.(:comment_create, %{task_id: task_id, content: content}, tracker_settings) do
      {:ok, %{"action" => "created", "comment" => comment}}
    end
  end

  defp persist_workpad(%{"id" => comment_id}, _task_id, content, tracker_settings, client) do
    with {:ok, comment} <-
           client.(:comment_update, %{comment_id: comment_id, content: content}, tracker_settings) do
      {:ok, %{"action" => "updated", "comment" => comment}}
    end
  end

  defp find_workpad(comments) when is_list(comments) do
    matches = Enum.filter(comments, &(is_map(&1) and workpad_content?(&1["content"])))

    case matches do
      [] -> {:ok, nil}
      [%{"id" => id} = comment] when is_binary(id) -> {:ok, comment}
      [_single] -> {:error, :invalid_todoist_comment_payload}
      _multiple -> {:error, :multiple_todoist_workpads}
    end
  end

  defp find_workpad(_comments), do: {:error, :invalid_todoist_comment_payload}

  defp workpad_content?(content) when is_binary(content) do
    content == @workpad_marker or String.starts_with?(content, @workpad_marker <> "\n")
  end

  defp workpad_content?(_content), do: false

  defp call_cli(:task_get, %{task_id: task_id}, settings), do: CLI.get_task(settings, task_id)

  defp call_cli(:task_move, %{task_id: task_id, section: section}, settings),
    do: CLI.move_task(settings, task_id, section)

  defp call_cli(:task_update, %{task_id: task_id, changes: changes}, settings),
    do: CLI.update_task(settings, task_id, changes)

  defp call_cli(:task_create, %{content: content, attributes: attributes}, settings),
    do: CLI.create_task(settings, content, attributes)

  defp call_cli(:comment_list, %{task_id: task_id}, settings),
    do: CLI.list_comments(settings, task_id)

  defp call_cli(:comment_create, %{task_id: task_id, content: content}, settings),
    do: CLI.create_comment(settings, task_id, content)

  defp call_cli(:comment_update, %{comment_id: comment_id, content: content}, settings),
    do: CLI.update_comment(settings, comment_id, content)

  defp success_response(payload), do: dynamic_tool_response(true, encode_payload(payload))

  defp failure_response(reason) do
    payload = %{
      "error" => %{
        "code" => error_code(reason),
        "message" => error_message(reason)
      }
    }

    dynamic_tool_response(false, encode_payload(payload))
  end

  defp unsupported_tool_response(tool) do
    dynamic_tool_response(
      false,
      encode_payload(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => [@tool_name]
        }
      })
    )
  end

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> Jason.encode!(%{"error" => %{"message" => "Todoist result was not JSON-safe."}})
    end
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail, _more}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "todoist_operation_failed"

  defp error_message(:invalid_todoist_arguments), do: "Invalid arguments for the selected Todoist operation."
  defp error_message(:invalid_todoist_workpad), do: "Workpad content must begin with `## Codex Workpad`."
  defp error_message(:multiple_todoist_workpads), do: "Multiple Codex Workpad comments exist; refusing to choose one."
  defp error_message(_reason), do: "Todoist operation failed without exposing CLI diagnostics."
end
