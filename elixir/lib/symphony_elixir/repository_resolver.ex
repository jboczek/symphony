defmodule SymphonyElixir.RepositoryResolver do
  @moduledoc """
  Resolves Git repositories beneath the configured repository root.
  """

  alias SymphonyElixir.{PathSafety, TaskExecutionSettings}

  @spec resolve(String.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve(repository_name, repository_root)
      when is_binary(repository_name) and is_binary(repository_root) do
    with :ok <- validate_repository_name(repository_name),
         {:ok, canonical_root} <- PathSafety.canonicalize(Path.expand(repository_root)),
         {:ok, repository} <- resolve_child(canonical_root, repository_name),
         :ok <- validate_git_repository(repository, repository_name) do
      {:ok, repository}
    end
  end

  def resolve(repository_name, _repository_root),
    do: {:error, {:invalid_repository_name, repository_name}}

  defp validate_repository_name(repository_name) do
    if TaskExecutionSettings.valid_repository_name?(repository_name) do
      :ok
    else
      {:error, {:invalid_repository_name, repository_name}}
    end
  end

  defp resolve_child(canonical_root, repository_name) do
    candidate = Path.join(canonical_root, repository_name)

    with {:ok, canonical_candidate} <- PathSafety.canonicalize(candidate) do
      cond do
        not within_root?(canonical_candidate, canonical_root) ->
          {:error, {:repository_outside_root, repository_name}}

        !File.dir?(canonical_candidate) ->
          {:error, {:repository_not_found, repository_name}}

        true ->
          {:ok, canonical_candidate}
      end
    end
  end

  defp within_root?(candidate, root) do
    case Path.split(Path.relative_to(candidate, root)) do
      [".." | _] -> false
      _ -> true
    end
  end

  defp validate_git_repository(repository, repository_name) do
    case System.cmd("git", ["-C", repository, "rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) == "true",
          do: :ok,
          else: {:error, {:not_a_git_repository, repository_name}}

      {_output, _status} ->
        {:error, {:not_a_git_repository, repository_name}}
    end
  rescue
    ErlangError -> {:error, :git_not_found}
  end
end
