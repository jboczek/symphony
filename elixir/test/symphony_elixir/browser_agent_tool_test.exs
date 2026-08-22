defmodule SymphonyElixir.Browser.AgentToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Browser.AgentTool

  test "advertises one browser tool" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{"action" => %{"enum" => actions}},
                 "required" => ["action"],
                 "type" => "object"
               },
               "name" => "browser",
               "type" => "function"
             }
           ] = AgentTool.tool_specs()

    assert description =~ "browser-xterm"
    assert "open" in actions
    assert "screenshot" in actions
    assert "close" in actions
  end

  test "starts the browser lazily and reuses its named session" do
    binding = AgentTool.bind(session: "browser-test")
    test_pid = self()

    runner = fn args, context ->
      send(test_pid, {:browser_cli, args, context})
      {:ok, ~s({"result":"ok"})}
    end

    assert :ok = AgentTool.close(binding, browser_cli_runner: runner)
    refute_received {:browser_cli, _, _}

    assert %{"success" => true} =
             AgentTool.execute(
               "browser",
               %{"action" => "open", "url" => "http://127.0.0.1:4000"},
               binding,
               browser_cli_runner: runner,
               workspace: "/tmp/workspace"
             )

    assert_received {:browser_cli, ["-s=browser-test", "open", "http://127.0.0.1:4000", "--json"], %{workspace: "/tmp/workspace"}}

    assert %{"success" => true} =
             AgentTool.execute(
               "browser",
               %{"action" => "navigate", "url" => "http://127.0.0.1:4000/next"},
               binding,
               browser_cli_runner: runner
             )

    assert_received {:browser_cli, ["-s=browser-test", "goto", "http://127.0.0.1:4000/next", "--json"], _}

    assert :ok = AgentTool.close(binding, browser_cli_runner: runner)
    assert_received {:browser_cli, ["-s=browser-test", "close", "--json"], _}
  end

  test "configures the local cli to connect to a remote browser server" do
    binding =
      AgentTool.bind(
        session: "remote-browser-test",
        endpoint: "ws://127.0.0.1:3000/",
        expose_network: "<loopback>"
      )

    test_pid = self()

    runner = fn args, context ->
      send(test_pid, {:browser_cli, args, context})
      {:ok, "ok"}
    end

    assert %{"success" => true} =
             AgentTool.execute(
               "browser",
               %{"action" => "open", "url" => "http://127.0.0.1:4000"},
               binding,
               browser_cli_runner: runner
             )

    assert_received {:browser_cli,
                     [
                       "-s=remote-browser-test",
                       "open",
                       "http://127.0.0.1:4000",
                       "--config",
                       config_path,
                       "--json"
                     ],
                     %{
                       remote_endpoint: "ws://127.0.0.1:3000/",
                       expose_network: "<loopback>"
                     }}

    assert Path.basename(config_path) == "playwright-cli.json"
  end

  test "keeps SSH workers on their own browser host" do
    binding = AgentTool.bind(session: "remote-worker-test", endpoint: "ws://127.0.0.1:3000/")
    test_pid = self()

    runner = fn args, context ->
      send(test_pid, {:browser_cli, args, context})
      {:ok, "ok"}
    end

    assert %{"success" => true} =
             AgentTool.execute(
               "browser",
               %{"action" => "open", "url" => "http://127.0.0.1:4000"},
               binding,
               browser_cli_runner: runner,
               worker_host: "worker.example"
             )

    assert_received {:browser_cli, ["-s=remote-worker-test", "open", "http://127.0.0.1:4000", "--json"], %{remote_endpoint: nil, worker_host: "worker.example"}}
  end

  test "maps interaction actions to playwright cli commands" do
    binding = AgentTool.bind(session: "interaction-test", opened: true)
    test_pid = self()

    runner = fn args, _context ->
      send(test_pid, {:browser_cli, args})
      {:ok, "ok"}
    end

    cases = [
      {%{"action" => "snapshot"}, ["snapshot"]},
      {%{"action" => "click", "target" => "e12"}, ["click", "e12"]},
      {%{"action" => "fill", "target" => "e5", "text" => "hello"}, ["fill", "e5", "hello"]},
      {%{"action" => "type", "text" => "world"}, ["type", "world"]},
      {%{"action" => "press", "key" => "ArrowDown"}, ["press", "ArrowDown"]},
      {%{"action" => "resize", "width" => 1200, "height" => 800}, ["resize", "1200", "800"]},
      {%{"action" => "console", "min_level" => "warning"}, ["console", "warning"]}
    ]

    Enum.each(cases, fn {arguments, expected} ->
      assert %{"success" => true} =
               AgentTool.execute("browser", arguments, binding, browser_cli_runner: runner)

      assert_received {:browser_cli, ["-s=interaction-test" | actual]}
      assert actual == expected ++ ["--json"]
    end)
  end

  test "returns screenshots directly as image input" do
    binding = AgentTool.bind(session: "screenshot-test", opened: true)
    test_pid = self()

    runner = fn args, context ->
      send(test_pid, {:browser_cli, args, context})
      {:ok, "saved"}
    end

    reader = fn path, context ->
      send(test_pid, {:read_screenshot, path, context})
      {:ok, <<137, 80, 78, 71>>}
    end

    response =
      AgentTool.execute(
        "browser",
        %{"action" => "screenshot", "full_page" => true},
        binding,
        browser_cli_runner: runner,
        browser_file_reader: reader,
        worker_host: "worker.example"
      )

    assert response["success"] == true
    assert [%{"type" => "inputText"}, image] = response["contentItems"]
    assert image == %{"type" => "inputImage", "imageUrl" => "data:image/png;base64,iVBORw=="}

    assert_received {:browser_cli,
                     [
                       "-s=screenshot-test",
                       "screenshot",
                       "--filename",
                       screenshot_path,
                       "--full-page",
                       "--json"
                     ], %{worker_host: "worker.example"}}

    assert_received {:read_screenshot, ^screenshot_path, %{worker_host: "worker.example"}}
  end

  test "rejects invalid actions and arguments before running the cli" do
    binding = AgentTool.bind(session: "validation-test")

    runner = fn _args, _context -> flunk("browser cli should not be called") end

    for arguments <- [
          %{"action" => "open"},
          %{"action" => "open", "url" => "file:///etc/passwd"},
          %{"action" => "click", "target" => ""},
          %{"action" => "resize", "width" => 0, "height" => 800},
          %{"action" => "unknown"}
        ] do
      response =
        AgentTool.execute("browser", arguments, binding, browser_cli_runner: runner)

      assert response["success"] == false
      assert %{"error" => %{"message" => message}} = Jason.decode!(response["output"])
      assert is_binary(message)
    end
  end

  test "rejects calls made before opening a browser session" do
    binding = AgentTool.bind(session: "closed-test")
    runner = fn _args, _context -> flunk("browser cli should not be called") end

    response =
      AgentTool.execute(
        "browser",
        %{"action" => "snapshot"},
        binding,
        browser_cli_runner: runner
      )

    assert response["success"] == false
    assert response["output"] =~ "open"
  end

  test "reports an explicit close failure without retrying during lifecycle cleanup" do
    binding = AgentTool.bind(session: "close-failure-test", opened: true)
    test_pid = self()

    runner = fn args, _context ->
      send(test_pid, {:browser_cli, args})
      {:error, "close failed"}
    end

    response =
      AgentTool.execute(
        "browser",
        %{"action" => "close"},
        binding,
        browser_cli_runner: runner
      )

    assert response["success"] == false
    assert response["output"] =~ "close failed"
    assert_received {:browser_cli, ["-s=close-failure-test", "close", "--json"]}

    assert :ok = AgentTool.close(binding, browser_cli_runner: runner)
    refute_received {:browser_cli, _}
  end
end
