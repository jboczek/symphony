defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to Symphony-owned and tracker-owned tools.
  """

  alias SymphonyElixir.Browser.AgentTool, as: BrowserTool
  alias SymphonyElixir.Tracker

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    if tool == "browser" do
      BrowserTool.execute(tool, arguments, binding.browser, opts)
    else
      Tracker.execute_bound_agent_tool(binding.tracker, tool, arguments, opts)
    end
  end

  @spec bind() :: map()
  def bind do
    tracker = Tracker.bind_agent_tools()
    browser = BrowserTool.bind()

    %{
      tracker: tracker,
      browser: browser,
      tool_specs: tracker.tool_specs ++ browser.tool_specs,
      secret_environment_names: tracker.secret_environment_names
    }
  end

  @spec close(map(), keyword()) :: :ok
  def close(binding, opts \\ []) do
    BrowserTool.close(binding.browser, opts)
  end
end
