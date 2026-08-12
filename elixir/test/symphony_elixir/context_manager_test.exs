defmodule SymphonyElixir.ContextManagerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ContextManager

  test "uses current context rather than cumulative token totals and schedules once at threshold" do
    context = ContextManager.new(%{enabled: true, checkpoint_threshold: 0.70})

    below = ContextManager.observe(context, usage_message(69, 100, 100_000))
    assert below.phase == :normal
    assert below.context_usage_percent == 0.69

    pending = ContextManager.observe(below, usage_message(70, 100, 200_000))
    assert pending.phase == :checkpoint_pending
    assert pending.current_context_tokens == 70
    assert pending.model_context_window == 100

    repeated = ContextManager.observe(pending, usage_message(90, 100, 300_000))
    assert repeated.phase == :checkpoint_pending
  end

  test "checkpoint and compaction phases reset after resume for a later crossing" do
    checkpoint_time = DateTime.utc_now()

    context =
      %{enabled: true, checkpoint_threshold: 0.70}
      |> ContextManager.new()
      |> ContextManager.observe(usage_message(75, 100, 75))
      |> ContextManager.checkpoint_started()
      |> ContextManager.checkpoint_completed(checkpoint_time)
      |> ContextManager.compaction_completed()

    assert ContextManager.runtime_info(context) == %{
             current_context_tokens: 75,
             model_context_window: 100,
             context_usage_percent: 0.75,
             checkpoint_pending: false,
             checkpoint_state: "completed",
             last_checkpoint_at: checkpoint_time,
             compaction_state: "completed"
           }

    reset = ContextManager.resume_completed(context)
    assert reset.phase == :normal

    future_crossing = ContextManager.observe(reset, usage_message(80, 100, 80))
    assert future_crossing.phase == :checkpoint_pending
  end

  test "disabled context management records usage without scheduling" do
    context = ContextManager.new(%{enabled: false, checkpoint_threshold: 0.70})
    observed = ContextManager.observe(context, usage_message(99, 100, 99))

    assert observed.phase == :normal
    assert observed.context_usage_percent == 0.99
  end

  test "ignores unrelated and incomplete usage payloads and no-op resume transitions" do
    context = ContextManager.new(%{enabled: true, checkpoint_threshold: 0.70})

    assert ContextManager.observe(context, %{payload: %{"method" => "item/started"}}) == context

    assert ContextManager.observe(context, %{
             payload: %{
               "method" => "thread/tokenUsage/updated",
               "params" => %{"tokenUsage" => nil}
             }
           }) == context

    assert ContextManager.resume_completed(context) == context
    refute ContextManager.checkpoint_pending?(context)
  end

  test "configuration defaults to enabled at seventy percent and validates bounds" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.context_management.enabled
    assert defaults.context_management.checkpoint_threshold == 0.70

    assert {:error, {:invalid_workflow_config, error}} =
             Schema.parse(%{
               "context_management" => %{"checkpoint_threshold" => 1.1}
             })

    assert error =~ "checkpoint_threshold"
  end

  defp usage_message(current_tokens, context_window, cumulative_tokens) do
    %{
      event: :notification,
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "last" => %{"totalTokens" => current_tokens},
            "total" => %{"totalTokens" => cumulative_tokens},
            "modelContextWindow" => context_window
          }
        }
      }
    }
  end
end
