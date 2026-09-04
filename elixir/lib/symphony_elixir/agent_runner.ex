defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, ContextManager, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil
  @configuration_blocker_tags [
    :invalid_task_execution_settings,
    :invalid_repository_name,
    :repository_outside_root,
    :repository_not_found,
    :not_a_git_repository,
    :repository_worktrees_require_local_worker,
    :git_branch_migration_failed,
    :workspace_path_conflict,
    :workspace_is_primary_repository,
    :workspace_branch_mismatch,
    :workspace_identity_mismatch,
    :workspace_repository_mismatch,
    :workspace_outside_root,
    :invalid_workspace_cwd
  ]
  @checkpoint_skill_path Path.expand("../../../.codex/skills/checkpoint/SKILL.md", __DIR__)

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")

        if configuration_blocker?(reason) do
          send_agent_blocked(codex_update_recipient, issue, reason)
          :ok
        else
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(
          codex_update_recipient,
          issue,
          worker_host,
          workspace,
          Workspace.runtime_info(issue, workspace)
        )

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue, context_key) do
    fn message ->
      send_codex_update(recipient, issue, message)
      observe_context(context_key, recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, details)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       Map.merge(details, %{
         worker_host: worker_host,
         workspace_path: workspace
       })}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _details), do: :ok

  defp send_session_runtime_info(recipient, %Issue{id: issue_id}, session)
       when is_binary(issue_id) and is_pid(recipient) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         thread_id: session.thread_id,
         model: session.effective_model,
         reasoning_effort: session.effective_reasoning_effort
       }}
    )

    :ok
  end

  defp send_session_runtime_info(_recipient, _issue, _session), do: :ok

  defp send_context_runtime_info(recipient, %Issue{id: issue_id}, %ContextManager{} = context)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:worker_runtime_info, issue_id, ContextManager.runtime_info(context)})
    :ok
  end

  defp send_context_runtime_info(_recipient, _issue, _context), do: :ok

  defp observe_context(context_key, recipient, issue, message) do
    context = Process.get(context_key)
    updated_context = ContextManager.observe(context, message)
    Process.put(context_key, updated_context)
    send_context_runtime_info(recipient, issue, updated_context)
  end

  defp transition_context(context_key, recipient, issue, transition) do
    context = Process.get(context_key)
    updated_context = transition.(context)
    Process.put(context_key, updated_context)
    send_context_runtime_info(recipient, issue, updated_context)
    updated_context
  end

  defp send_agent_blocked(recipient, %Issue{id: issue_id}, reason)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_blocked, issue_id, reason})
    :ok
  end

  defp send_agent_blocked(_recipient, _issue, _reason), do: :ok

  defp configuration_blocker?(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: elem(reason, 0) in @configuration_blocker_tags

  defp configuration_blocker?(:git_not_found), do: true
  defp configuration_blocker?(_reason), do: false

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    settings = Config.settings!()
    max_turns = Keyword.get(opts, :max_turns, settings.agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    context_key = {:symphony_context_manager, make_ref()}

    context_config = %{
      enabled: settings.context_management.enabled and settings.tracker.kind == "todoist",
      checkpoint_threshold: settings.context_management.checkpoint_threshold
    }

    Process.put(context_key, ContextManager.new(context_config))

    with {:ok, session} <-
           AppServer.start_session(workspace,
             worker_host: worker_host,
             execution_settings: issue.execution_settings
           ) do
      send_session_runtime_info(codex_update_recipient, issue, session)
      send_context_runtime_info(codex_update_recipient, issue, Process.get(context_key))

      run_state = %{
        session: session,
        workspace: workspace,
        recipient: codex_update_recipient,
        opts: opts,
        issue_state_fetcher: issue_state_fetcher,
        context_key: context_key,
        max_turns: max_turns
      }

      try do
        do_run_codex_turns(run_state, issue, 1, :normal)
      after
        AppServer.stop_session(session)
        Process.delete(context_key)
      end
    end
  end

  defp do_run_codex_turns(run_state, issue, turn_number, turn_kind) do
    prompt =
      build_turn_prompt(issue, run_state.opts, turn_number, run_state.max_turns, turn_kind)

    send_prompt_trace(run_state.recipient, issue, prompt, turn_number, turn_kind)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             run_state.session,
             prompt,
             issue,
             on_message: codex_message_handler(run_state.recipient, issue, run_state.context_key)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{run_state.workspace} turn=#{turn_number}/#{run_state.max_turns}")

      if turn_kind == :resume do
        transition_context(
          run_state.context_key,
          run_state.recipient,
          issue,
          &ContextManager.resume_completed/1
        )
      end

      case continue_with_issue?(issue, run_state.issue_state_fetcher) do
        {:continue, refreshed_issue} ->
          continue_after_turn(run_state, refreshed_issue, turn_number)

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp send_prompt_trace(recipient, %Issue{id: issue_id}, prompt, turn_number, turn_kind)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(prompt) do
    send(recipient, {
      :codex_worker_update,
      issue_id,
      %{
        event: :prompt_sent,
        payload: %{prompt: prompt, turn: turn_number, kind: turn_kind},
        timestamp: DateTime.utc_now()
      }
    })

    :ok
  end

  defp send_prompt_trace(_recipient, _issue, _prompt, _turn_number, _turn_kind), do: :ok

  defp continue_after_turn(run_state, issue, turn_number) do
    context = Process.get(run_state.context_key)

    cond do
      ContextManager.checkpoint_pending?(context) ->
        with :ok <- run_checkpoint_cycle(run_state, issue) do
          do_run_codex_turns(run_state, issue, turn_number + 1, :resume)
        end

      turn_number < run_state.max_turns ->
        Logger.info("Continuing agent run for #{issue_context(issue)} after normal turn completion turn=#{turn_number}/#{run_state.max_turns}")

        do_run_codex_turns(run_state, issue, turn_number + 1, :normal)

      true ->
        Logger.info("Reached agent.max_turns for #{issue_context(issue)} with issue still active; returning control to orchestrator")
        :ok
    end
  end

  defp run_checkpoint_cycle(run_state, issue) do
    skill_path = checkpoint_skill_path(run_state.session, run_state.workspace)

    with {:ok, previous_checkpoint} <- Tracker.latest_checkpoint_comment(issue),
         _context <-
           transition_context(
             run_state.context_key,
             run_state.recipient,
             issue,
             &ContextManager.checkpoint_started/1
           ),
         {:ok, _turn} <-
           AppServer.run_turn(
             run_state.session,
             "Checkpoint before context compaction",
             issue,
             input: checkpoint_input(skill_path, issue.id),
             on_message: codex_message_handler(run_state.recipient, issue, run_state.context_key)
           ),
         {:ok, checkpoint} <- Tracker.latest_checkpoint_comment(issue),
         :ok <- verify_new_checkpoint(previous_checkpoint, checkpoint),
         _context <- checkpoint_completed(run_state, issue),
         :ok <-
           AppServer.compact_thread(run_state.session,
             on_message: codex_message_handler(run_state.recipient, issue, run_state.context_key)
           ) do
      transition_context(
        run_state.context_key,
        run_state.recipient,
        issue,
        &ContextManager.compaction_completed/1
      )

      :ok
    end
  end

  defp checkpoint_completed(run_state, issue) do
    transition_context(run_state.context_key, run_state.recipient, issue, fn context ->
      ContextManager.checkpoint_completed(context, DateTime.utc_now())
    end)
  end

  defp checkpoint_skill_path(%{worker_host: nil}, _workspace), do: @checkpoint_skill_path

  defp checkpoint_skill_path(%{worker_host: worker_host}, workspace) when is_binary(worker_host),
    do: Path.join(workspace, ".codex/skills/checkpoint/SKILL.md")

  defp checkpoint_input(skill_path, issue_id) do
    [
      %{"type" => "skill", "name" => "checkpoint", "path" => skill_path},
      %{
        "type" => "text",
        "text" =>
          "Create the durable pre-compaction checkpoint for Todoist task #{issue_id}. " <>
            "Follow the checkpoint skill exactly and ensure the new comment starts with [SYMPHONY_CHECKPOINT_V1]."
      }
    ]
  end

  defp verify_new_checkpoint(previous_checkpoint, %{"id" => checkpoint_id, "content" => content})
       when is_binary(checkpoint_id) and is_binary(content) do
    previous_id = previous_checkpoint && previous_checkpoint["id"]

    if checkpoint_id != previous_id and checkpoint_marker?(content) do
      :ok
    else
      {:error, :checkpoint_not_persisted}
    end
  end

  defp verify_new_checkpoint(_previous_checkpoint, _checkpoint),
    do: {:error, :checkpoint_not_persisted}

  defp checkpoint_marker?(content) do
    content
    |> String.split(~r/\R/u, parts: 2)
    |> List.first()
    |> Kernel.==("[SYMPHONY_CHECKPOINT_V1]")
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, :normal),
    do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, _turn_number, _max_turns, :resume) do
    """
    Read the latest Todoist comment for this task whose first line is
    [SYMPHONY_CHECKPOINT_V1].

    Treat it as the durable checkpoint from before context compaction. Reconcile it with the current
    repository/worktree state and git status. Continue from the recorded next action. Do not redo
    completed work unless the current workspace state contradicts the checkpoint.
    """
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, :normal) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) and
             not session_boundary_reached?(issue.state, refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp session_boundary_reached?(previous_state, current_state)
       when is_binary(previous_state) and is_binary(current_state) do
    previous_state = normalize_issue_state(previous_state)
    current_state = normalize_issue_state(current_state)

    Enum.any?(Config.settings!().agent.session_boundary_states, fn boundary_state ->
      normalized_boundary = normalize_issue_state(boundary_state)

      normalized_boundary == current_state or
        (previous_state != current_state and normalized_boundary == previous_state)
    end)
  end

  defp session_boundary_reached?(_previous_state, _current_state), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
