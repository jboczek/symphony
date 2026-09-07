defmodule SymphonyElixir.ContextManager do
  @moduledoc """
  Tracks current Codex context-window usage and one checkpoint/compaction cycle.
  """

  defstruct enabled: true,
            threshold: 0.70,
            phase: :normal,
            current_context_tokens: nil,
            model_context_window: nil,
            context_usage_percent: nil,
            last_checkpoint_at: nil

  @type phase :: :normal | :checkpoint_pending | :checkpointing | :compacting | :resuming
  @type t :: %__MODULE__{
          enabled: boolean(),
          threshold: float(),
          phase: phase(),
          current_context_tokens: non_neg_integer() | nil,
          model_context_window: pos_integer() | nil,
          context_usage_percent: float() | nil,
          last_checkpoint_at: DateTime.t() | nil
        }

  @spec new(map()) :: t()
  def new(%{enabled: enabled, checkpoint_threshold: threshold}) do
    %__MODULE__{enabled: enabled, threshold: threshold}
  end

  @spec observe(t(), map()) :: t()
  def observe(%__MODULE__{} = state, message) when is_map(message) do
    case current_context_usage(message) do
      {:ok, current_tokens, context_window} ->
        usage_percent = current_tokens / context_window

        state
        |> Map.put(:current_context_tokens, current_tokens)
        |> Map.put(:model_context_window, context_window)
        |> Map.put(:context_usage_percent, usage_percent)
        |> maybe_schedule_checkpoint(usage_percent)

      :ignore ->
        state
    end
  end

  @spec checkpoint_started(t()) :: t()
  def checkpoint_started(%__MODULE__{phase: :checkpoint_pending} = state),
    do: %{state | phase: :checkpointing}

  @spec checkpoint_completed(t(), DateTime.t()) :: t()
  def checkpoint_completed(%__MODULE__{phase: :checkpointing} = state, %DateTime{} = completed_at),
    do: %{state | phase: :compacting, last_checkpoint_at: completed_at}

  @spec compaction_completed(t()) :: t()
  def compaction_completed(%__MODULE__{phase: :compacting} = state),
    do: %{state | phase: :resuming}

  @spec resume_started(t()) :: t()
  def resume_started(%__MODULE__{phase: :resuming} = state),
    do: %{state | phase: :normal}

  def resume_started(%__MODULE__{} = state), do: state

  @spec checkpoint_pending?(t()) :: boolean()
  def checkpoint_pending?(%__MODULE__{phase: :checkpoint_pending}), do: true
  def checkpoint_pending?(%__MODULE__{}), do: false

  @spec runtime_info(t()) :: map()
  def runtime_info(%__MODULE__{} = state) do
    %{
      current_context_tokens: state.current_context_tokens,
      model_context_window: state.model_context_window,
      context_usage_percent: state.context_usage_percent,
      checkpoint_pending: state.phase == :checkpoint_pending,
      checkpoint_state: checkpoint_state(state.phase),
      last_checkpoint_at: state.last_checkpoint_at,
      compaction_state: compaction_state(state.phase)
    }
  end

  defp current_context_usage(message) do
    payload = Map.get(message, :payload) || Map.get(message, "payload") || message

    if payload_get(payload, "method") == "thread/tokenUsage/updated" do
      token_usage = payload_at(payload, ["params", "tokenUsage"])
      current_tokens = payload_at(token_usage, ["last", "totalTokens"])
      context_window = payload_get(token_usage, "modelContextWindow")

      if valid_current_usage?(current_tokens, context_window) do
        {:ok, current_tokens, context_window}
      else
        :ignore
      end
    else
      :ignore
    end
  end

  defp valid_current_usage?(current_tokens, context_window) do
    is_integer(current_tokens) and current_tokens >= 0 and is_integer(context_window) and
      context_window > 0
  end

  defp maybe_schedule_checkpoint(
         %__MODULE__{enabled: true, phase: :normal, threshold: threshold} = state,
         usage_percent
       )
       when usage_percent >= threshold,
       do: %{state | phase: :checkpoint_pending}

  defp maybe_schedule_checkpoint(state, _usage_percent), do: state

  defp checkpoint_state(:checkpoint_pending), do: "pending"
  defp checkpoint_state(:checkpointing), do: "in_progress"
  defp checkpoint_state(phase) when phase in [:compacting, :resuming], do: "completed"
  defp checkpoint_state(:normal), do: "idle"

  defp compaction_state(:compacting), do: "in_progress"
  defp compaction_state(:resuming), do: "completed"
  defp compaction_state(_phase), do: "idle"

  defp payload_at(payload, []), do: payload

  defp payload_at(payload, [key | rest]) when is_map(payload) do
    payload
    |> payload_get(key)
    |> payload_at(rest)
  end

  defp payload_at(_payload, _path), do: nil

  defp payload_get(payload, key) when is_map(payload) do
    Map.get(payload, key)
  end

  defp payload_get(_payload, _key), do: nil
end
