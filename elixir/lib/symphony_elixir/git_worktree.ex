defmodule SymphonyElixir.GitWorktree do
  @moduledoc """
  Creates and removes Symphony-owned Git worktrees with durable ownership metadata.
  """

  alias SymphonyElixir.{Config, PathSafety}

  @metadata_directory ".symphony-worktrees"
  @metadata_version 1

  @type metadata :: %{
          branch: String.t(),
          repository: Path.t(),
          task_identity: String.t(),
          workspace: Path.t()
        }

  @spec lookup(String.t()) :: {:ok, metadata() | nil} | {:error, term()}
  def lookup(task_identity) when is_binary(task_identity) do
    task_identity
    |> metadata_path()
    |> read_metadata()
  end

  @spec ensure(Path.t(), Path.t(), String.t(), String.t()) ::
          {:ok, metadata(), boolean()} | {:error, term()}
  def ensure(repository, workspace, task_identity, branch)
      when is_binary(repository) and is_binary(workspace) and is_binary(task_identity) and
             is_binary(branch) do
    with {:ok, repository} <- PathSafety.canonicalize(repository),
         {:ok, workspace} <- PathSafety.canonicalize(workspace),
         :ok <- validate_workspace_location(repository, workspace),
         {:ok, existing_metadata} <- lookup(task_identity),
         :ok <- validate_metadata(existing_metadata, repository, workspace),
         {:ok, created?} <- ensure_linked_worktree(repository, workspace, branch),
         {:ok, actual_branch} <- current_branch(workspace),
         {:ok, effective_branch} <-
           reconcile_branch(workspace, actual_branch, branch, created?),
         metadata = %{
           branch: effective_branch,
           repository: repository,
           task_identity: task_identity,
           workspace: workspace
         },
         :ok <- persist_metadata(metadata, created?) do
      {:ok, metadata, created?}
    end
  end

  @spec remove_for_identity(String.t(), Path.t() | nil) ::
          {:ok, [String.t()]} | :not_owned | {:error, term(), String.t()}
  def remove_for_identity(task_identity, expected_repository \\ nil) when is_binary(task_identity) do
    case lookup(task_identity) do
      {:ok, nil} ->
        :not_owned

      {:ok, metadata} ->
        case validate_expected_repository(metadata, expected_repository) do
          :ok -> remove_metadata_worktree(metadata)
          {:error, reason} -> {:error, reason, ""}
        end

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_recorded(Path.t()) ::
          {:ok, [String.t()]} | :not_owned | {:error, term(), String.t()}
  def remove_recorded(workspace) when is_binary(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, metadata} <- metadata_for_workspace(canonical_workspace) do
      case metadata do
        nil -> :not_owned
        metadata -> remove_metadata_worktree(metadata)
      end
    else
      {:error, reason} -> {:error, reason, ""}
    end
  end

  @spec linked_worktree?(Path.t()) :: boolean()
  def linked_worktree?(workspace) when is_binary(workspace) do
    File.regular?(Path.join(workspace, ".git"))
  end

  def linked_worktree?(_workspace), do: false

  @spec owned_worktree_writable_roots(Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def owned_worktree_writable_roots(workspace) when is_binary(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, metadata} <- metadata_for_workspace(canonical_workspace) do
      writable_roots_for_metadata(metadata, canonical_workspace)
    end
  end

  defp ensure_linked_worktree(repository, workspace, branch) do
    cond do
      File.dir?(workspace) ->
        with :ok <- verify_repository_association(repository, workspace) do
          {:ok, false}
        end

      File.exists?(workspace) ->
        {:error, {:workspace_path_conflict, workspace}}

      true ->
        with :ok <- prune_stale_metadata(repository),
             :ok <- File.mkdir_p(Path.dirname(workspace)),
             :ok <- add_worktree(repository, workspace, branch) do
          {:ok, true}
        end
    end
  end

  defp add_worktree(repository, workspace, branch) do
    args =
      if local_branch_exists?(repository, branch) do
        ["worktree", "add", workspace, branch]
      else
        ["worktree", "add", "-b", branch, workspace, default_base_ref(repository)]
      end

    case git(repository, args) do
      {:ok, _output} -> :ok
      {:error, status, output} -> {:error, {:git_worktree_add_failed, status, bounded(output)}}
    end
  end

  defp local_branch_exists?(repository, branch) do
    match?({:ok, _}, git(repository, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  defp default_base_ref(repository) do
    case git(repository, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) do
      {:ok, ref} when ref != "" -> String.trim(ref)
      _ -> current_head_ref(repository)
    end
  end

  defp current_head_ref(repository) do
    case git(repository, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, ref} when ref != "" -> String.trim(ref)
      _ -> "HEAD"
    end
  end

  defp current_branch(workspace) do
    case git(workspace, ["branch", "--show-current"]) do
      {:ok, branch} when branch != "" -> {:ok, String.trim(branch)}
      {:ok, _branch} -> {:error, {:git_worktree_detached, workspace}}
      {:error, status, output} -> {:error, {:git_worktree_inspection_failed, status, bounded(output)}}
    end
  end

  defp validate_branch(branch, branch), do: :ok

  defp validate_branch(actual, expected),
    do: {:error, {:workspace_branch_mismatch, actual, expected}}

  defp reconcile_branch(_workspace, actual, expected, true) do
    with :ok <- validate_branch(actual, expected), do: {:ok, actual}
  end

  defp reconcile_branch(workspace, "symphony/" <> _, "feature/" <> _ = expected, false) do
    case git(workspace, ["branch", "-m", expected]) do
      {:ok, _output} -> {:ok, expected}
      {:error, status, output} -> {:error, {:git_branch_migration_failed, status, bounded(output)}}
    end
  end

  defp reconcile_branch(_workspace, "feature/" <> _ = actual, "feature/" <> _ = expected, false) do
    if same_task_feature_branch?(actual, expected) do
      {:ok, actual}
    else
      {:error, {:workspace_branch_mismatch, actual, expected}}
    end
  end

  defp reconcile_branch(_workspace, actual, expected, false),
    do: {:error, {:workspace_branch_mismatch, actual, expected}}

  defp same_task_feature_branch?(actual, expected) do
    case String.split(String.trim_leading(expected, "feature/"), "-", parts: 2) do
      [task_id, _slug] -> String.starts_with?(actual, "feature/#{task_id}-")
      _ -> false
    end
  end

  defp validate_workspace_location(repository, workspace) do
    root = Config.local_workspace_root()

    with {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      cond do
        repository == workspace ->
          {:error, {:workspace_is_primary_repository, workspace}}

        String.starts_with?(workspace <> "/", canonical_root <> "/") ->
          :ok

        true ->
          {:error, {:workspace_outside_root, workspace, canonical_root}}
      end
    end
  end

  defp validate_metadata(nil, _repository, _workspace), do: :ok

  defp validate_metadata(%{repository: repository, workspace: workspace}, repository, workspace), do: :ok

  defp validate_metadata(%{repository: actual, workspace: workspace}, expected, workspace) do
    {:error, {:workspace_repository_mismatch, workspace, actual, expected}}
  end

  defp validate_metadata(%{workspace: actual}, _repository, expected) do
    {:error, {:workspace_identity_mismatch, actual, expected}}
  end

  defp validate_expected_repository(_metadata, nil), do: :ok

  defp validate_expected_repository(%{repository: repository}, expected_repository) do
    with {:ok, expected_repository} <- PathSafety.canonicalize(expected_repository) do
      if repository == expected_repository do
        :ok
      else
        {:error, {:workspace_repository_mismatch, repository, expected_repository}}
      end
    end
  end

  defp verify_repository_association(repository, workspace) do
    with {:ok, expected_common_dir} <- git_common_dir(repository),
         {:ok, actual_common_dir} <- git_common_dir(workspace) do
      if actual_common_dir == expected_common_dir do
        :ok
      else
        {:error, {:workspace_repository_mismatch, workspace, actual_common_dir, expected_common_dir}}
      end
    end
  end

  defp git_common_dir(repository) do
    case git(repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {:ok, path} -> PathSafety.canonicalize(String.trim(path))
      {:error, status, output} -> {:error, {:git_repository_inspection_failed, status, bounded(output)}}
    end
  end

  defp prune_stale_metadata(repository) do
    case git(repository, ["worktree", "prune", "--expire", "now"]) do
      {:ok, _output} -> :ok
      {:error, status, output} -> {:error, {:git_worktree_prune_failed, status, bounded(output)}}
    end
  end

  defp remove_metadata_worktree(metadata) do
    with :ok <- validate_workspace_location(metadata.repository, metadata.workspace),
         :ok <- remove_linked_worktree(metadata),
         :ok <- remove_metadata_file(metadata.task_identity) do
      {:ok, [metadata.workspace]}
    else
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_linked_worktree(metadata) do
    if File.exists?(metadata.workspace) do
      remove_existing_linked_worktree(metadata)
    else
      prune_stale_metadata(metadata.repository)
    end
  end

  defp remove_existing_linked_worktree(metadata) do
    with :ok <- verify_repository_association(metadata.repository, metadata.workspace) do
      case git(metadata.repository, ["worktree", "remove", "--force", metadata.workspace]) do
        {:ok, _output} -> :ok
        {:error, status, output} -> {:error, {:git_worktree_remove_failed, status, bounded(output)}}
      end
    end
  end

  defp writable_roots_for_metadata(nil, _workspace), do: {:ok, []}

  defp writable_roots_for_metadata(%{repository: repository} = metadata, workspace) do
    with {:ok, canonical_repository} <- PathSafety.canonicalize(repository),
         :ok <- validate_metadata(metadata, canonical_repository, workspace),
         :ok <- validate_workspace_location(canonical_repository, workspace),
         :ok <- verify_repository_association(canonical_repository, workspace),
         {:ok, common_dir} <- git_common_dir(workspace) do
      {:ok, [workspace, common_dir]}
    end
  end

  defp metadata_for_workspace(workspace) do
    directory = metadata_directory()

    case File.ls(directory) do
      {:ok, entries} ->
        find_workspace_metadata(entries, directory, workspace)

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:workspace_metadata_unreadable, directory, reason}}
    end
  end

  defp find_workspace_metadata(entries, directory, workspace) do
    entries
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reduce_while({:ok, nil}, &match_workspace_metadata(&1, &2, directory, workspace))
  end

  defp match_workspace_metadata(entry, _acc, directory, workspace) do
    case read_metadata(Path.join(directory, entry)) do
      {:ok, %{workspace: ^workspace} = metadata} -> {:halt, {:ok, metadata}}
      {:ok, _metadata} -> {:cont, {:ok, nil}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp read_metadata(path) do
    case File.read(path) do
      {:ok, json} -> decode_metadata(path, json)
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:workspace_metadata_unreadable, path, reason}}
    end
  end

  defp decode_metadata(path, json) do
    case Jason.decode(json) do
      {:ok,
       %{
         "version" => @metadata_version,
         "branch" => branch,
         "repository" => repository,
         "taskIdentity" => task_identity,
         "workspace" => workspace
       }}
      when is_binary(branch) and is_binary(repository) and is_binary(task_identity) and
             is_binary(workspace) ->
        {:ok,
         %{
           branch: branch,
           repository: repository,
           task_identity: task_identity,
           workspace: workspace
         }}

      _ ->
        {:error, {:invalid_workspace_metadata, path}}
    end
  end

  defp write_metadata(metadata) do
    path = metadata_path(metadata.task_identity)

    payload = %{
      "version" => @metadata_version,
      "branch" => metadata.branch,
      "repository" => metadata.repository,
      "taskIdentity" => metadata.task_identity,
      "workspace" => metadata.workspace
    }

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(payload),
         :ok <- File.write(path, json <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, {:workspace_metadata_write_failed, path, reason}}
    end
  end

  defp persist_metadata(metadata, created?) do
    case write_metadata(metadata) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        if created?, do: remove_linked_worktree(metadata)
        error
    end
  end

  defp remove_metadata_file(task_identity) do
    case File.rm(metadata_path(task_identity)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:workspace_metadata_remove_failed, task_identity, reason}}
    end
  end

  defp metadata_path(task_identity), do: Path.join(metadata_directory(), task_identity <> ".json")
  defp metadata_directory, do: Path.join(Config.local_workspace_root(), @metadata_directory)

  defp git(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, status, output}
    end
  rescue
    ErlangError -> {:error, 127, "git executable not found"}
  end

  defp bounded(output) when is_binary(output), do: String.slice(output, 0, 2_048)
  defp bounded(output), do: inspect(output)
end
