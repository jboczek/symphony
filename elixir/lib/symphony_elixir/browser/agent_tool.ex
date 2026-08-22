defmodule SymphonyElixir.Browser.AgentTool do
  @moduledoc """
  A host-side browser tool backed by Playwright CLI.

  The browser process starts on the first `open` action and is reused for the
  lifetime of the Codex app-server session. Web applications and browser-xterm
  instances use the same URL-based interface. When a remote endpoint is
  configured, the local CLI daemon connects to a Playwright browser server
  instead of launching a browser on the Symphony host.
  """

  alias SymphonyElixir.SSH

  @playwright_package "@playwright/cli@0.1.18"
  @tool_name "browser"
  @actions ~w(open navigate snapshot click fill type press resize screenshot console close)

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "type" => "function",
        "name" => @tool_name,
        "description" =>
          "Control a lazily started browser for local web UI verification. " <>
            "Use the same tool for browser-xterm after starting browser-xterm through the shell. " <>
            "Call snapshot before interactions to obtain stable element references. " <>
            "Actions: open(url), navigate(url), snapshot(target?), click(target), " <>
            "fill(target,text), type(text), press(key), resize(width,height), " <>
            "screenshot(target?,full_page?), console(min_level?), close().",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["action"],
          "additionalProperties" => false,
          "properties" => %{
            "action" => %{"type" => "string", "enum" => @actions},
            "url" => %{"type" => "string", "description" => "HTTP(S) URL to open."},
            "target" => %{
              "type" => "string",
              "description" => "Element reference from the latest snapshot or a unique selector."
            },
            "text" => %{"type" => "string"},
            "key" => %{"type" => "string", "description" => "Keyboard key such as Enter or ArrowDown."},
            "width" => %{"type" => "integer", "minimum" => 1},
            "height" => %{"type" => "integer", "minimum" => 1},
            "full_page" => %{"type" => "boolean", "default" => false},
            "min_level" => %{
              "type" => "string",
              "enum" => ~w(error warning info debug),
              "description" => "Minimum console message level."
            }
          }
        }
      }
    ]
  end

  @spec bind(keyword()) :: map()
  def bind(opts \\ []) do
    opened = :atomics.new(1, signed: false)

    if Keyword.get(opts, :opened, false), do: :atomics.put(opened, 1, 1)

    %{
      session: Keyword.get_lazy(opts, :session, &new_session_name/0),
      endpoint: normalize_optional_string(Keyword.get(opts, :endpoint)),
      expose_network: Keyword.get(opts, :expose_network, "<loopback>"),
      opened: opened,
      tool_specs: tool_specs()
    }
  end

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    cond do
      tool != @tool_name ->
        failure_response("Unsupported browser tool: #{inspect(tool)}.")

      not is_map(arguments) ->
        failure_response("`browser` requires an object argument.")

      true ->
        :global.trans({__MODULE__, binding.session}, fn ->
          execute_action(arguments, binding, opts)
        end)
    end
  end

  @spec close(map(), keyword()) :: :ok
  def close(binding, opts \\ []) do
    :global.trans({__MODULE__, binding.session}, fn ->
      _ = close_unlocked(binding, opts)
      :ok
    end)
  end

  defp execute_action(%{"action" => "open"} = arguments, binding, opts) do
    with {:ok, url} <- required_url(arguments),
         {:ok, output} <- run_cli([if(opened?(binding), do: "goto", else: "open"), url], binding, opts),
         :ok <- mark_opened(binding, true),
         {:ok, resize_output} <- maybe_resize(arguments, binding, opts) do
      success_response(join_output(output, resize_output))
    else
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_action(%{"action" => "navigate"} = arguments, binding, opts) do
    with :ok <- require_opened(binding),
         {:ok, url} <- required_url(arguments),
         {:ok, output} <- run_cli(["goto", url], binding, opts) do
      success_response(output)
    else
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_action(%{"action" => "snapshot"} = arguments, binding, opts) do
    execute_opened_command(["snapshot"] ++ optional_string(arguments, "target"), binding, opts)
  end

  defp execute_action(%{"action" => "click"} = arguments, binding, opts) do
    case required_string(arguments, "target") do
      {:ok, target} -> execute_opened_command(["click", target], binding, opts)
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_action(%{"action" => "fill"} = arguments, binding, opts) do
    with {:ok, target} <- required_string(arguments, "target"),
         {:ok, text} <- required_string(arguments, "text", allow_empty: true) do
      execute_opened_command(["fill", target, text], binding, opts)
    else
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_action(%{"action" => "type"} = arguments, binding, opts) do
    case required_string(arguments, "text", allow_empty: true) do
      {:ok, text} -> execute_opened_command(["type", text], binding, opts)
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_action(%{"action" => "press"} = arguments, binding, opts) do
    case required_string(arguments, "key") do
      {:ok, key} -> execute_opened_command(["press", key], binding, opts)
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_action(%{"action" => "resize"} = arguments, binding, opts) do
    case dimensions(arguments) do
      {:ok, width, height} ->
        execute_opened_command(["resize", to_string(width), to_string(height)], binding, opts)

      {:error, reason} ->
        failure_response(reason)
    end
  end

  defp execute_action(%{"action" => "console"} = arguments, binding, opts) do
    execute_opened_command(["console"] ++ optional_string(arguments, "min_level"), binding, opts)
  end

  defp execute_action(%{"action" => "screenshot"} = arguments, binding, opts) do
    with :ok <- require_opened(binding),
         {:ok, command} <- screenshot_command(arguments, binding, opts),
         {:ok, output} <- run_cli(command, binding, opts),
         {:ok, image} <- read_screenshot(binding, opts) do
      success_response(output, image)
    else
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_action(%{"action" => "close"}, binding, opts) do
    case close_unlocked(binding, opts) do
      :ok -> success_response("Browser session closed.")
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_action(%{"action" => action}, _binding, _opts) do
    failure_response("Unsupported browser action: #{inspect(action)}.")
  end

  defp execute_action(_arguments, _binding, _opts) do
    failure_response("`browser` requires an `action` string.")
  end

  defp execute_opened_command(command, binding, opts) do
    with :ok <- require_opened(binding),
         {:ok, output} <- run_cli(command, binding, opts) do
      success_response(output)
    else
      {:error, reason} -> failure_response(reason)
    end
  end

  defp close_unlocked(binding, opts) do
    if opened?(binding) do
      result = run_cli(["close"], binding, opts)
      mark_opened(binding, false)
      cleanup_runtime(binding, opts)
      normalize_close_result(result)
    else
      :ok
    end
  end

  defp normalize_close_result({:ok, _output}), do: :ok
  defp normalize_close_result({:error, reason}), do: {:error, reason}

  defp maybe_resize(arguments, binding, opts) do
    case {Map.get(arguments, "width"), Map.get(arguments, "height")} do
      {nil, nil} ->
        {:ok, nil}

      _ ->
        with {:ok, width, height} <- dimensions(arguments) do
          run_cli(["resize", to_string(width), to_string(height)], binding, opts)
        end
    end
  end

  defp screenshot_command(arguments, binding, opts) do
    path = screenshot_path(binding, opts)

    command =
      ["screenshot"] ++
        optional_string(arguments, "target") ++
        ["--filename", path] ++
        if(Map.get(arguments, "full_page", false), do: ["--full-page"], else: [])

    {:ok, command}
  end

  defp run_cli(command, binding, opts) do
    runner = Keyword.get(opts, :browser_cli_runner, &default_cli_runner/2)
    context = command_context(binding, opts)
    args = ["-s=#{binding.session}"] ++ command ++ remote_config_args(command, context) ++ ["--json"]
    runner.(args, context)
  end

  defp default_cli_runner(args, %{worker_host: nil} = context) do
    with :ok <- prepare_runtime(context),
         {:ok, executable, prefix_args} <- local_cli_command() do
      {output, status} =
        System.cmd(executable, prefix_args ++ args,
          cd: context.runtime_dir,
          env: [{"PWTEST_DAEMON_SESSION_DIR", Path.join(context.runtime_dir, "daemon")}],
          stderr_to_stdout: true
        )

      command_result(output, status)
    end
  end

  defp default_cli_runner(args, %{worker_host: worker_host} = context) do
    command = remote_cli_command(args, context.runtime_dir)

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, status}} -> command_result(output, status)
      {:error, reason} -> {:error, "Failed starting browser command over SSH: #{inspect(reason)}"}
    end
  end

  defp local_cli_command do
    cond do
      executable = System.find_executable("playwright-cli") ->
        {:ok, executable, []}

      executable = System.find_executable("npx") ->
        {:ok, executable, ["--yes", "--package", @playwright_package, "playwright-cli"]}

      true ->
        {:error, missing_cli_message()}
    end
  end

  defp remote_cli_command(args, runtime_dir) do
    escaped_args = Enum.map_join(args, " ", &shell_escape/1)
    escaped_runtime = shell_escape(runtime_dir)
    daemon_dir = shell_escape(Path.join(runtime_dir, "daemon"))

    "mkdir -p #{escaped_runtime} && cd #{escaped_runtime} && " <>
      "export PWTEST_DAEMON_SESSION_DIR=#{daemon_dir} && " <>
      "if command -v playwright-cli >/dev/null 2>&1; then " <>
      "playwright-cli #{escaped_args}; " <>
      "elif command -v npx >/dev/null 2>&1; then " <>
      "npx --yes --package #{shell_escape(@playwright_package)} playwright-cli #{escaped_args}; " <>
      "else echo #{shell_escape(missing_cli_message())} >&2; exit 127; fi"
  end

  defp command_result(output, 0), do: {:ok, String.trim(output)}

  defp command_result(output, _status) do
    detail = output |> String.trim() |> truncate(4_000)
    {:error, "Browser command failed. #{detail}"}
  end

  defp read_screenshot(binding, opts) do
    reader = Keyword.get(opts, :browser_file_reader, &default_file_reader/2)
    reader.(screenshot_path(binding, opts), command_context(binding, opts))
  end

  defp default_file_reader(path, %{worker_host: nil}), do: File.read(path)

  defp default_file_reader(path, %{worker_host: worker_host}) do
    case SSH.run(worker_host, "base64 < #{shell_escape(path)}", stderr_to_stdout: true) do
      {:ok, {encoded, 0}} ->
        encoded
        |> String.replace(~r/\s+/, "")
        |> Base.decode64()

      {:ok, {output, _status}} ->
        {:error, "Failed reading browser screenshot. #{String.trim(output)}"}

      {:error, reason} ->
        {:error, "Failed reading browser screenshot over SSH: #{inspect(reason)}"}
    end
  end

  defp command_context(binding, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    %{
      runtime_dir: runtime_dir(binding, worker_host),
      remote_endpoint: if(is_nil(worker_host), do: binding.endpoint),
      expose_network: binding.expose_network,
      worker_host: worker_host,
      workspace: Keyword.get(opts, :workspace)
    }
  end

  defp prepare_runtime(context) do
    with :ok <- File.mkdir_p(context.runtime_dir) do
      write_remote_config(context)
    end
  end

  defp write_remote_config(%{remote_endpoint: nil}), do: :ok

  defp write_remote_config(context) do
    config = %{
      "browser" => %{
        "browserName" => "chromium",
        "remoteEndpoint" => %{
          "browserName" => "chromium",
          "endpoint" => context.remote_endpoint,
          "exposeNetwork" => context.expose_network
        }
      }
    }

    File.write(remote_config_path(context), Jason.encode!(config))
  end

  defp remote_config_args(["open" | _], %{remote_endpoint: endpoint} = context)
       when is_binary(endpoint),
       do: ["--config", remote_config_path(context)]

  defp remote_config_args(_command, _context), do: []

  defp remote_config_path(context), do: Path.join(context.runtime_dir, "playwright-cli.json")

  defp runtime_dir(binding, nil),
    do: Path.join(System.tmp_dir!(), "symphony-browser-#{binding.session}")

  defp runtime_dir(binding, _worker_host), do: "/tmp/symphony-browser-#{binding.session}"

  defp screenshot_path(binding, opts) do
    binding
    |> command_context(opts)
    |> Map.fetch!(:runtime_dir)
    |> Path.join("screenshot.png")
  end

  defp cleanup_runtime(binding, opts) do
    context = command_context(binding, opts)

    case context.worker_host do
      nil ->
        File.rm_rf(context.runtime_dir)
        :ok

      worker_host ->
        _ = SSH.run(worker_host, "rm -rf -- #{shell_escape(context.runtime_dir)}", stderr_to_stdout: true)
        :ok
    end
  end

  defp required_url(arguments) do
    with {:ok, url} <- required_string(arguments, "url"),
         %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url) do
      {:ok, url}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "`browser` requires an HTTP(S) `url`."}
    end
  end

  defp required_string(arguments, key, opts \\ []) do
    allow_empty? = Keyword.get(opts, :allow_empty, false)

    case Map.get(arguments, key) do
      value when is_binary(value) ->
        if allow_empty? or String.trim(value) != "" do
          {:ok, value}
        else
          {:error, "`browser` requires a non-empty `#{key}` string for this action."}
        end

      _ ->
        {:error, "`browser` requires a `#{key}` string for this action."}
    end
  end

  defp optional_string(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) and value != "" -> [value]
      _ -> []
    end
  end

  defp dimensions(%{"width" => width, "height" => height})
       when is_integer(width) and width > 0 and is_integer(height) and height > 0,
       do: {:ok, width, height}

  defp dimensions(_arguments),
    do: {:error, "`browser` requires positive integer `width` and `height` values."}

  defp require_opened(binding) do
    if opened?(binding),
      do: :ok,
      else: {:error, "Browser session is closed; call the `open` action first."}
  end

  defp opened?(binding), do: :atomics.get(binding.opened, 1) == 1

  defp mark_opened(binding, opened?) do
    :atomics.put(binding.opened, 1, if(opened?, do: 1, else: 0))
    :ok
  end

  defp success_response(output, image \\ nil) do
    text = if is_binary(output) and output != "", do: output, else: "Browser command completed."

    content_items =
      [%{"type" => "inputText", "text" => text}] ++
        if(is_binary(image),
          do: [%{"type" => "inputImage", "imageUrl" => "data:image/png;base64,#{Base.encode64(image)}"}],
          else: []
        )

    %{"success" => true, "output" => text, "contentItems" => content_items}
  end

  defp failure_response(reason) do
    output = Jason.encode!(%{"error" => %{"message" => to_string(reason)}})

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp new_session_name do
    "symphony-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp join_output(output, nil), do: output
  defp join_output(output, resize_output), do: Enum.join([output, resize_output], "\n")

  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value
  defp truncate(value, max_bytes), do: binary_part(value, 0, max_bytes) <> "…"

  defp missing_cli_message do
    "Playwright CLI is unavailable; install Node.js/npm or place playwright-cli on PATH."
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
