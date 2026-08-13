defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, GitWorktree, PathSafety, RepositoryResolver, SSH, TaskExecutionSettings}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @codex_directory Path.expand("../../../.codex", __DIR__)

  @type worker_host :: String.t() | nil

  @spec runtime_info(map(), Path.t()) :: %{repository: String.t() | nil, branch: String.t() | nil}
  def runtime_info(%{execution_settings: %TaskExecutionSettings{repo: repository}} = issue, _workspace)
      when is_binary(repository) do
    %{repository: repository, branch: "symphony/#{workspace_identity(issue)}"}
  end

  def runtime_info(_issue, _workspace), do: %{repository: nil, branch: nil}

  @spec validate_issue_configuration(map(), worker_host()) :: :ok | {:error, term()}
  def validate_issue_configuration(issue, worker_host \\ nil) do
    case requested_repository(issue) do
      {:ok, nil} ->
        :ok

      {:ok, repository_name} when is_nil(worker_host) ->
        with {:ok, _repository} <-
               RepositoryResolver.resolve(repository_name, Config.local_repository_root()) do
          :ok
        end

      {:ok, _repository_name} ->
        {:error, {:repository_worktrees_require_local_worker, worker_host}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      with {:ok, workspace} <- workspace_path_for_issue(issue_or_identifier, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?, workspace_type} <-
             ensure_issue_workspace(workspace, issue_or_identifier, worker_host) do
        case maybe_run_after_create_hook(
               workspace,
               issue_context,
               created?,
               workspace_type,
               worker_host
             ) do
          :ok ->
            {:ok, workspace}

          {:error, _reason} = error ->
            cleanup_failed_new_workspace(workspace, created?, workspace_type, worker_host)
            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_issue_workspace(workspace, issue, nil) do
    case requested_repository(issue) do
      {:ok, nil} ->
        with {:ok, workspace, created?} <- ensure_workspace(workspace, nil) do
          {:ok, workspace, created?, :directory}
        end

      {:ok, repository_name} ->
        with {:ok, repository} <-
               RepositoryResolver.resolve(repository_name, Config.local_repository_root()),
             task_identity <- workspace_identity(issue),
             branch <- "symphony/#{task_identity}",
             {:ok, _metadata, created?} <-
               GitWorktree.ensure(repository, workspace, task_identity, branch) do
          {:ok, workspace, created?, :git_worktree}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_issue_workspace(workspace, issue, worker_host) when is_binary(worker_host) do
    case requested_repository(issue) do
      {:ok, nil} ->
        with {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
          {:ok, workspace, created?, :directory}
        end

      {:ok, _repository_name} ->
        {:error, {:repository_worktrees_require_local_worker, worker_host}}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    if File.exists?(workspace) do
      case validate_workspace_path(workspace, nil) do
        :ok -> remove_local_workspace(workspace)
        {:error, reason} -> {:error, reason, ""}
      end
    else
      case GitWorktree.remove_recorded(workspace) do
        {:ok, _removed} = result -> result
        :not_owned -> File.rm_rf(workspace)
        {:error, _reason, _path} = error -> error
      end
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_recorded_workspace_path(workspace) do
        :ok ->
          remove_local_workspace(workspace)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    remove(workspace, worker_host)
  end

  def remove_recorded(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  defp remove_local_workspace(workspace) do
    maybe_run_before_remove_hook(workspace, nil)

    case GitWorktree.remove_recorded(workspace) do
      {:ok, _removed} = result ->
        result

      :not_owned ->
        if GitWorktree.linked_worktree?(workspace) do
          {:error, {:unowned_git_worktree, workspace}, ""}
        else
          File.rm_rf(workspace)
        end

      {:error, _reason, _path} = error ->
        error
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        remove_local_issue_workspace(issue)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(identifier, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  defp remove_local_issue_workspace(issue) do
    with {:ok, repository_name} when is_binary(repository_name) <- requested_repository(issue),
         {:ok, repository} <-
           RepositoryResolver.resolve(repository_name, Config.local_repository_root()) do
      maybe_run_owned_worktree_remove_hook(workspace_identity(issue))

      case GitWorktree.remove_for_identity(workspace_identity(issue), repository) do
        {:ok, _removed} -> :ok
        :not_owned -> remove_discovered_issue_workspace(issue)
        {:error, reason, path} -> log_workspace_cleanup_failure(issue, reason, path)
      end
    else
      {:ok, nil} -> remove_discovered_issue_workspace(issue)
      {:error, reason} -> log_workspace_cleanup_failure(issue, reason, "")
    end
  end

  defp maybe_run_owned_worktree_remove_hook(task_identity) do
    case GitWorktree.lookup(task_identity) do
      {:ok, %{workspace: workspace}} -> maybe_run_before_remove_hook(workspace, nil)
      _ -> :ok
    end
  end

  defp remove_discovered_issue_workspace(issue) do
    case workspace_path_for_issue(issue, nil) do
      {:ok, workspace} -> remove(workspace, nil)
      {:error, _reason} -> :ok
    end
  end

  defp log_workspace_cleanup_failure(issue, reason, path) do
    Logger.warning("Failed to remove issue workspace #{issue_log_context(issue_context(issue))} reason=#{inspect(reason)} path=#{path}")

    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(%{id: id, title: title} = issue, nil)
       when is_binary(id) and is_binary(title) do
    with {:ok, existing_workspace} <- discover_existing_workspace(issue) do
      workspace = existing_workspace || Path.join(Config.local_workspace_root(), workspace_key(issue))
      PathSafety.canonicalize(workspace)
    end
  end

  defp workspace_path_for_issue(%{identifier: identifier}, nil) when is_binary(identifier) do
    workspace_path_for_issue(identifier, nil)
  end

  defp workspace_path_for_issue(identifier, nil) when is_binary(identifier) do
    Config.local_workspace_root()
    |> Path.join(workspace_key(identifier))
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(issue_or_identifier, worker_host) when is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, workspace_key(issue_or_identifier))}
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{id: id, identifier: identifier, title: title})
      when is_binary(id) and is_binary(title) do
    identity = workspace_identity(%{id: id, identifier: identifier})
    "#{identity}-#{title_slug(title)}"
  end

  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp discover_existing_workspace(issue) do
    identity = workspace_identity(issue)

    case GitWorktree.lookup(identity) do
      {:ok, %{workspace: workspace}} ->
        {:ok, workspace}

      {:ok, nil} ->
        discover_workspace_directory(issue, identity)

      {:error, _reason} = error ->
        error
    end
  end

  defp discover_workspace_directory(issue, identity) do
    root = Config.local_workspace_root()
    legacy_name = workspace_key(issue.identifier)

    case File.ls(root) do
      {:ok, entries} ->
        matches =
          entries
          |> Enum.filter(fn entry ->
            entry == legacy_name or entry == identity or String.starts_with?(entry, identity <> "-")
          end)
          |> Enum.map(&Path.join(root, &1))
          |> Enum.filter(&File.dir?/1)

        case matches do
          [] -> {:ok, nil}
          [workspace] -> {:ok, workspace}
          _ -> {:error, {:ambiguous_issue_workspaces, identity, Enum.sort(matches)}}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:workspace_root_unreadable, root, reason}}
    end
  end

  defp workspace_identity(%{id: id, identifier: identifier}) when is_binary(id) do
    source = source_component(identifier)
    stable_id = safe_component(id, "task")
    "#{source}-#{stable_id}"
  end

  defp workspace_identity(%{identifier: identifier}) when is_binary(identifier),
    do: safe_component(identifier, "issue")

  defp workspace_identity(identifier) when is_binary(identifier),
    do: safe_component(identifier, "issue")

  defp workspace_identity(_issue), do: "task-issue"

  defp source_component(identifier) when is_binary(identifier) do
    identifier
    |> String.split("-", parts: 2)
    |> List.first()
    |> safe_component("task")
  end

  defp source_component(_identifier), do: "task"

  defp safe_component(value, fallback) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-._")
    |> case do
      "" -> fallback
      component -> component
    end
  end

  defp title_slug(title) when is_binary(title) do
    title
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.graphemes()
    |> Enum.take(64)
    |> Enum.join()
    |> String.trim("-")
    |> case do
      "" -> "task"
      slug -> slug
    end
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, _workspace_type, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false, _workspace_type, _worker_host), do: :ok

  defp cleanup_failed_new_workspace(workspace, true, :git_worktree, nil) do
    case GitWorktree.remove_recorded(workspace) do
      {:ok, _removed} ->
        :ok

      :not_owned ->
        Logger.warning("Failed to remove newly created Git worktree path=#{workspace} reason=not_owned")

      {:error, reason, path} ->
        Logger.warning("Failed to remove newly created Git worktree path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, :directory, nil) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, _workspace_type, worker_host)
       when is_binary(worker_host) do
    script = [remote_shell_assign("workspace", workspace), "rm -rf \"$workspace\""] |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("Failed to remove partial workspace worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(result)}")
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command],
          cd: workspace,
          env: [{"SYMPHONY_CODEX_DIR", @codex_directory}],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  defp requested_repository(%{execution_settings: %TaskExecutionSettings{repo: repository}}),
    do: {:ok, repository}

  defp requested_repository(%{execution_settings: {:error, reason}}), do: {:error, reason}
  defp requested_repository(_issue), do: {:ok, nil}
end
