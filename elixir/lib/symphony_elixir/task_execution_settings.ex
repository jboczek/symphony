defmodule SymphonyElixir.TaskExecutionSettings do
  @moduledoc """
  Typed per-task Symphony overrides parsed from Todoist description front matter.
  """

  @allowed_keys MapSet.new(["repo", "model", "thinking"])

  defstruct [:repo, :model, :thinking]

  @type t :: %__MODULE__{
          repo: String.t() | nil,
          model: String.t() | nil,
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
    name not in ["", ".", ".."] and
      String.trim(name) == name and
      String.match?(name, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
  end

  def valid_repository_name?(_name), do: false

  defp split_front_matter(description) do
    lines = String.split(description, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front_matter, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | body] -> {:ok, Enum.join(front_matter, "\n"), Enum.join(body, "\n")}
          _ -> {:error, :unterminated_front_matter}
        end

      _ ->
        :none
    end
  end

  defp parse_front_matter(yaml, body, original_description) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, front_matter} when is_map(front_matter) ->
        parse_symphony_settings(front_matter, body, original_description)

      {:ok, _other} ->
        invalid(:front_matter_not_a_map)

      {:error, _reason} ->
        invalid(:malformed_yaml)
    end
  rescue
    _error -> invalid(:malformed_yaml)
  end

  defp parse_symphony_settings(front_matter, body, original_description) do
    case fetch_value(front_matter, "symphony") do
      :missing ->
        {:ok, %__MODULE__{}, original_description}

      {:ok, settings} when is_map(settings) ->
        with :ok <- validate_keys(settings),
             {:ok, repo} <- optional_value(settings, "repo", &valid_repository_name?/1),
             {:ok, model} <- optional_value(settings, "model", &present_string?/1),
             {:ok, thinking} <- optional_value(settings, "thinking", &present_string?/1) do
          {:ok, %__MODULE__{repo: repo, model: model, thinking: thinking}, String.trim(body)}
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

  defp fetch_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:ok, Map.fetch!(map, String.to_atom(key))}
      true -> :missing
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp invalid(reason), do: {:error, {:invalid_task_execution_settings, reason}}
end
