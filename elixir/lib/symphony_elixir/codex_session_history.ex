defmodule SymphonyElixir.CodexSessionHistory do
  @moduledoc """
  Reads completed Symphony-run session logs written by the local Codex client.
  """

  @default_limit 10

  @spec recent_sessions(Path.t(), pos_integer()) :: [map()]
  def recent_sessions(root \\ sessions_root(), limit \\ @default_limit)
      when is_binary(root) and is_integer(limit) and limit > 0 do
    root
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
    |> Enum.sort_by(&modified_at/1, :desc)
    |> Enum.reduce_while([], fn path, sessions ->
      if length(sessions) == limit do
        {:halt, sessions}
      else
        case read_session(path) do
          {:ok, session} -> {:cont, [session | sessions]}
          :ignore -> {:cont, sessions}
        end
      end
    end)
  end

  @spec raw_events(Path.t()) :: [map()]
  def raw_events(path) when is_binary(path) do
    if String.starts_with?(Path.expand(path), Path.expand(sessions_root())) do
      read_entries(path)
    else
      []
    end
  end

  @spec sessions_root() :: Path.t()
  def sessions_root, do: Path.join(System.user_home!(), ".codex/sessions")

  defp read_session(path) do
    entries = read_entries(path)
    meta = Enum.find(entries, &(&1["type"] == "session_meta"))

    if get_in(meta || %{}, ["payload", "originator"]) == "symphony-orchestrator" do
      prompt = Enum.find_value(entries, &user_prompt/1)
      messages = Enum.flat_map(entries, &agent_message/1)
      commands = Enum.flat_map(entries, &command/1)
      payload = meta["payload"]

      {:ok,
       %{
         session_id: payload["session_id"],
         issue_identifier: prompt_value(prompt, ~r/Todoist task `([^`]+)`/) || "Symphony run",
         title: prompt_value(prompt, ~r/- Title: (.+)/) || "Untitled task",
         status: session_status(messages),
         started_at: payload["timestamp"] || meta["timestamp"],
         completed_at: entries |> List.last() |> then(&(&1 && &1["timestamp"])),
         prompt: prompt,
         messages: messages,
         commands: commands,
         log_path: path
       }}
    else
      :ignore
    end
  end

  defp read_entries(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, entry} -> [entry]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp user_prompt(%{"type" => "event_msg", "payload" => %{"type" => "user_message", "message" => message}}), do: message
  defp user_prompt(_entry), do: nil

  defp agent_message(%{"type" => "event_msg", "timestamp" => at, "payload" => %{"type" => "agent_message", "message" => text}}) when is_binary(text), do: [%{at: at, text: text}]
  defp agent_message(_entry), do: []

  defp command(%{"type" => "response_item", "timestamp" => at, "payload" => %{"type" => "custom_tool_call", "name" => name, "input" => input}}), do: [%{at: at, name: name, input: input}]
  defp command(_entry), do: []

  defp prompt_value(prompt, regex) when is_binary(prompt) do
    case Regex.run(regex, prompt) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp prompt_value(_prompt, _regex), do: nil

  defp session_status(messages) do
    content = messages |> Enum.map_join("\n", & &1.text)

    cond do
      String.contains?(content, "Verdict: Fail") -> "failed"
      String.contains?(content, "Verdict: Pass") -> "completed"
      true -> "completed"
    end
  end

  defp modified_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat.mtime
      _ -> 0
    end
  end
end
