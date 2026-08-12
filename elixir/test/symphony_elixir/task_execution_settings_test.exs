defmodule SymphonyElixir.TaskExecutionSettingsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{RepositoryResolver, TaskExecutionSettings}

  test "preserves descriptions without Symphony front matter" do
    description = "Normal human-readable task description."

    assert {:ok, %TaskExecutionSettings{repo: nil, model: nil, thinking: nil}, ^description} =
             TaskExecutionSettings.parse(description)

    assert {:ok, %TaskExecutionSettings{}, nil} = TaskExecutionSettings.parse(nil)
  end

  test "parses a repository-only override and keeps the following description" do
    description = """
    ---
    symphony:
      repo: cse.tools.prompts
    ---

    Normal human-readable task description continues here.
    """

    assert {:ok, %TaskExecutionSettings{repo: "cse.tools.prompts", model: nil, thinking: nil}, body} =
             TaskExecutionSettings.parse(description)

    assert body == "Normal human-readable task description continues here."
  end

  test "parses exact repository, model, and thinking values" do
    description = """
    ---
    symphony:
      repo: cse.tools.prompts
      model: gpt-5.6-sol
      thinking: high
    ---
    Ship it.
    """

    assert {:ok,
            %TaskExecutionSettings{
              repo: "cse.tools.prompts",
              model: "gpt-5.6-sol",
              thinking: "high"
            }, "Ship it."} = TaskExecutionSettings.parse(description)
  end

  test "rejects malformed or unterminated front matter" do
    assert {:error, {:invalid_task_execution_settings, :malformed_yaml}} =
             TaskExecutionSettings.parse("---\nsymphony: [\n---\nTask")

    assert {:error, {:invalid_task_execution_settings, :unterminated_front_matter}} =
             TaskExecutionSettings.parse("---\nsymphony:\n  repo: example")
  end

  test "rejects invalid shapes, unknown keys, blank values, and traversal repositories" do
    invalid_descriptions = [
      "---\nsymphony: nope\n---\nTask",
      "---\nsymphony:\n  extra: value\n---\nTask",
      "---\nsymphony:\n  model: ' '\n---\nTask",
      "---\nsymphony:\n  repo: ../secrets\n---\nTask",
      "---\nsymphony:\n  repo: nested/repo\n---\nTask",
      "---\nsymphony:\n  repo: .\n---\nTask",
      "---\nsymphony:\n  repo: ..\n---\nTask"
    ]

    assert Enum.all?(invalid_descriptions, fn description ->
             match?({:error, {:invalid_task_execution_settings, _}}, TaskExecutionSettings.parse(description))
           end)
  end

  test "front matter without Symphony settings preserves existing behavior" do
    description = "---\nowner: human\n---\nTask text"

    assert {:ok, %TaskExecutionSettings{}, ^description} = TaskExecutionSettings.parse(description)
  end

  test "resolves only an exact direct-child Git repository" do
    root = tmp_path("repository-resolver")
    repository = Path.join(root, "cse.tools.prompts")
    non_repository = Path.join(root, "notes")

    try do
      File.mkdir_p!(repository)
      File.mkdir_p!(non_repository)
      assert {_output, 0} = System.cmd("git", ["-C", repository, "init", "-b", "main"])

      assert {:ok, resolved} = RepositoryResolver.resolve("cse.tools.prompts", root)
      assert {:ok, expected_repository} = SymphonyElixir.PathSafety.canonicalize(repository)
      assert resolved == expected_repository

      assert {:error, {:repository_not_found, "missing"}} =
               RepositoryResolver.resolve("missing", root)

      assert {:error, {:not_a_git_repository, "notes"}} =
               RepositoryResolver.resolve("notes", root)

      assert {:error, {:invalid_repository_name, "../secrets"}} =
               RepositoryResolver.resolve("../secrets", root)
    after
      File.rm_rf(root)
    end
  end

  defp tmp_path(name) do
    Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
  end
end
