defmodule SymphonyElixir.TaskExecutionSettings do
  @moduledoc """
  Typed per-task Symphony overrides parsed from Todoist description front matter.
  """

  @allowed_keys MapSet.new(["repo", "model", "task_id", "thinking"])

  defstruct [:repo, :model, :task_id, :thinking]

  @type t :: %__MODULE__{
          repo: String.t() | nil,
          model: String.t() | nil,
          task_id: String.t() | nil,
          thinking: String.t() | nil
        }

  @spec parse(String.t() | nil) ::
          {:ok, t(), String.t() | nil} | {:error, {:invalid_task_execution_settings, term()}}
  def parse(nil), do: {:ok, %__MODULE__{}, nil}

  def parse(description) when is_binary(description) do
    case split_front_matter(description) do
      :none ->
        {:ok, %__MODULE__{}, description}

      {:error, reason} ->
        invalid(reason)

      {:ok, yaml, body} ->
        parse_front_matter(yaml, body, description)
    end
  end

  @spec valid_repository_name?(term()) :: boolean()
  def valid_repository_name?(name) when is_binary(name) do
    name != "" and
      String.trim(name) == name and
      Path.type(name) == :relative and
      name
      |> String.split("/", trim: false)
      |> Enum.all?(fn segment ->
        segment not in ["", ".", ".."] and
          String.match?(segment, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
      end)
  end

  def valid_repository_name?(_name), do: false

  defp split_front_matter(description) do
    lines = String.split(description, ~r/\R/u, trim: false)

    case lines do
      ["---" | tail] ->
        split_unfenced_front_matter(tail)

      [opening_fence, "---" | tail] ->
        if code_fence?(opening_fence) do
          split_fenced_front_matter(tail)
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp split_fenced_front_matter(lines) do
    case split_yaml_front_matter(lines) do
      {:ok, yaml, [closing_fence | body]} ->
        if code_fence?(closing_fence) do
          {:ok, yaml, Enum.join(body, "\n")}
        else
          {:error, :unterminated_front_matter}
        end

      {:ok, _yaml, []} ->
        {:error, :unterminated_front_matter}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_unfenced_front_matter(lines) do
    case split_yaml_front_matter(lines) do
      {:ok, yaml, body} -> {:ok, yaml, Enum.join(body, "\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_yaml_front_matter(lines) do
    {front_matter, rest} = Enum.split_while(lines, &(&1 != "---"))

    case rest do
      ["---" | body] -> {:ok, Enum.join(front_matter, "\n"), body}
      _ -> {:error, :unterminated_front_matter}
    end
  end

  defp code_fence?(line), do: String.trim(line) in ["```", "```yaml", "```yml"]

  defp parse_front_matter(yaml, body, original_description) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, front_matter} when is_map(front_matter) ->
        parse_symphony_settings(front_matter, body, original_description)

      {:ok, _other} ->
        invalid(:front_matter_not_a_map)

      {:error, _reason} ->
        invalid(:malformed_yaml)
    end
  end

  defp parse_symphony_settings(front_matter, body, original_description) do
    case fetch_value(front_matter, "symphony") do
      :missing ->
        {:ok, %__MODULE__{}, original_description}

      {:ok, settings} when is_map(settings) ->
        with :ok <- validate_keys(settings),
             {:ok, repo} <- optional_value(settings, "repo", &valid_repository_name?/1),
             {:ok, model} <- optional_value(settings, "model", &present_string?/1),
             {:ok, task_id} <- optional_task_id(settings),
             {:ok, thinking} <- optional_value(settings, "thinking", &present_string?/1) do
          {:ok, %__MODULE__{repo: repo, model: model, task_id: task_id, thinking: thinking}, String.trim(body)}
        end

      {:ok, _other} ->
        invalid(:symphony_not_a_map)
    end
  end

  defp validate_keys(settings) do
    unknown_keys =
      settings
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(@allowed_keys, &1))

    if unknown_keys == [], do: :ok, else: invalid({:unknown_keys, Enum.sort(unknown_keys)})
  end

  defp optional_value(settings, key, validator) do
    case fetch_value(settings, key) do
      :missing ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if validator.(value), do: {:ok, value}, else: invalid({:invalid_value, key})

      {:ok, _value} ->
        invalid({:invalid_value, key})
    end
  end

  defp optional_task_id(settings) do
    case fetch_value(settings, "task_id") do
      :missing ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, Integer.to_string(value)}

      {:ok, value} when is_binary(value) ->
        if valid_task_id?(value), do: {:ok, value}, else: invalid({:invalid_value, "task_id"})

      {:ok, _value} ->
        invalid({:invalid_value, "task_id"})
    end
  end

  defp fetch_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:ok, Map.fetch!(map, String.to_atom(key))}
      true -> :missing
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""

  defp valid_task_id?(value), do: String.match?(value, ~r/\A[1-9][0-9]*\z/)

  defp invalid(reason), do: {:error, {:invalid_task_execution_settings, reason}}
end
