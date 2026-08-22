defmodule SymphonyElixir.WorkspaceWorktreeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TaskExecutionSettings

  test "workspace names contain source, stable task ID, and a safe readable title" do
    cases = [
      {"Fix retry logic", "todoist-9123456789-fix-retry-logic"},
      {"  --Fix... retry / logic--  ", "todoist-9123456789-fix-retry-logic"},
      {"Zażółć gęślą jaźń", "todoist-9123456789-zażółć-gęślą-jaźń"},
      {"../escape\\nested", "todoist-9123456789-escape-nested"},
      {"---Leading and trailing---", "todoist-9123456789-leading-and-trailing"}
    ]

    Enum.each(cases, fn {title, expected} ->
      assert Workspace.workspace_key(issue("9123456789", title)) == expected
    end)

    long_title = String.duplicate("recognizable-title-", 20)
    key = Workspace.workspace_key(issue("9123456789", long_title))
    assert String.starts_with?(key, "todoist-9123456789-recognizable-title-")
    assert String.length(key) <= String.length("todoist-9123456789-") + 64
    refute String.contains?(key, ["/", "\\", ".."])

    refute Workspace.workspace_key(issue("one", "Same title")) ==
             Workspace.workspace_key(issue("two", "Same title"))
  end

  test "renaming a task reuses the workspace selected by stable identity" do
    workspace_root = tmp_path("renamed-workspace")

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue(issue("42", "Fix retry logic"))
      File.write!(Path.join(workspace, "progress.txt"), "keep")

      assert {:ok, ^workspace} =
               Workspace.create_for_issue(issue("42", "Fix retry and timeout logic"))

      assert File.read!(Path.join(workspace, "progress.txt")) == "keep"
      assert {:ok, entries} = File.ls(workspace_root)
      assert Enum.count(entries, &String.starts_with?(&1, "todoist-42-")) == 1
    after
      File.rm_rf(workspace_root)
    end
  end

  test "repository-backed tasks create and resume independent Git worktrees" do
    test_root = tmp_path("worktrees")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    source = create_git_repository(repository_root, "example.repo")
    first = issue("101", "First task", "example.repo")
    second = issue("102", "First task", "example.repo")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root,
        hook_after_create: todoist_after_create_hook()
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue(first)
      assert {:ok, second_workspace} = Workspace.create_for_issue(second)

      assert first_workspace != second_workspace
      assert File.regular?(Path.join(first_workspace, ".git"))
      assert File.regular?(Path.join(second_workspace, ".git"))
      assert File.regular?(Path.join(first_workspace, ".codex/skills/checkpoint/SKILL.md"))
      assert git(first_workspace, ["status", "--short", "--untracked-files=all"]) == ""
      assert File.read!(Path.join(first_workspace, "README.md")) == "source\n"

      assert git(first_workspace, ["branch", "--show-current"]) == "feature/101-first-task"
      assert git(second_workspace, ["branch", "--show-current"]) == "feature/102-first-task"

      File.write!(Path.join(first_workspace, "progress.txt"), "keep")

      renamed = %{first | title: "Renamed first task"}
      assert {:ok, ^first_workspace} = Workspace.create_for_issue(renamed)
      assert File.read!(Path.join(first_workspace, "progress.txt")) == "keep"

      porcelain = git(source, ["worktree", "list", "--porcelain"])
      assert porcelain =~ first_workspace
      assert porcelain =~ second_workspace
    after
      Workspace.remove_issue_workspaces(first)
      Workspace.remove_issue_workspaces(second)
      File.rm_rf(test_root)
    end
  end

  test "task IDs create and resume feature branches" do
    test_root = tmp_path("task-id-worktree")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    source = create_git_repository(repository_root, "example.repo")
    task = issue("104", "Add basket attribution", "example.repo", "135550")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue(task)
      assert git(workspace, ["branch", "--show-current"]) == "feature/135550-add-basket-attribution"

      renamed = %{task | title: "Add basket attribution to promotions"}
      assert {:ok, ^workspace} = Workspace.create_for_issue(renamed)
      assert git(workspace, ["branch", "--show-current"]) == "feature/135550-add-basket-attribution"
      assert Workspace.runtime_info(renamed, workspace).branch == "feature/135550-add-basket-attribution"
      assert git(source, ["worktree", "list", "--porcelain"]) =~ workspace
    after
      Workspace.remove_issue_workspaces(task)
      File.rm_rf(test_root)
    end
  end

  test "resume adopts a branch changed inside an owned worktree" do
    test_root = tmp_path("changed-worktree-branch")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    _source = create_git_repository(repository_root, "example.repo")
    task = issue("105", "Prepare README", "example.repo")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue(task)
      assert git(workspace, ["branch", "-m", "feature/105-readme-prep"]) == ""

      assert {:ok, ^workspace} = Workspace.create_for_issue(task)
      assert Workspace.runtime_info(task, workspace).branch == "feature/105-readme-prep"
    after
      Workspace.remove_issue_workspaces(task)
      File.rm_rf(test_root)
    end
  end

  test "resume migrates a legacy Symphony branch to the feature convention" do
    test_root = tmp_path("legacy-worktree-branch")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    _source = create_git_repository(repository_root, "example.repo")
    task = issue("106", "Update repository", "example.repo")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue(task)
      assert git(workspace, ["branch", "-m", "symphony/todoist-106"]) == ""

      metadata_path = Path.join(workspace_root, ".symphony-worktrees/todoist-106.json")
      metadata = metadata_path |> File.read!() |> Jason.decode!()
      File.write!(metadata_path, Jason.encode!(%{metadata | "branch" => "symphony/todoist-106"}))

      assert {:ok, ^workspace} = Workspace.create_for_issue(task)

      assert git(workspace, ["branch", "--show-current"]) ==
               "feature/106-update-repository"

      assert Workspace.runtime_info(task, workspace).branch ==
               "feature/106-update-repository"
    after
      Workspace.remove_issue_workspaces(task)
      File.rm_rf(test_root)
    end
  end

  test "resume rejects a feature branch owned by another task" do
    test_root = tmp_path("unrelated-worktree-branch")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    _source = create_git_repository(repository_root, "example.repo")
    task = issue("107", "Update repository", "example.repo")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue(task)
      assert git(workspace, ["branch", "-m", "feature/999-other-task"]) == ""

      assert {:error, {:workspace_branch_mismatch, "feature/999-other-task", "feature/107-update-repository"}} = Workspace.create_for_issue(task)
    after
      Workspace.remove_issue_workspaces(task)
      File.rm_rf(test_root)
    end
  end

  test "owned linked worktrees use a scoped Codex permission profile for Git metadata" do
    test_root = tmp_path("worktree-sandbox")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    extra_root = Path.join(test_root, "cache")
    codex_binary = Path.join(test_root, "fake-codex")
    argv_trace = Path.join(test_root, "argv")
    json_trace = Path.join(test_root, "json")
    source = create_git_repository(repository_root, "example.repo")
    task = issue("103", "Commit from sandbox", "example.repo")

    try do
      File.write!(codex_binary, """
      #!/bin/sh
      printf '%s\n' "$@" > #{argv_trace}
      count=0
      while IFS= read -r line; do
        printf '%s\n' "$line" >> #{json_trace}
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-worktree"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-worktree"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-worktree"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [extra_root],
          networkAccess: true
        }
      )

      assert {:ok, workspace} = Workspace.create_for_issue(task)
      assert {:ok, session} = AppServer.start_session(workspace)

      assert {:ok, common_git_dir} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(source, ".git"))

      try do
        assert session.permissions_profile == "symphony-worktree"
        assert {:ok, _result} = AppServer.run_turn(session, "Commit changes", task)

        argv = File.read!(argv_trace)
        assert argv =~ ~s(default_permissions="symphony-worktree")
        assert argv =~ ~s("#{workspace}"="write")
        assert argv =~ ~s("#{common_git_dir}"="write")
        assert argv =~ ~s("#{Path.join(workspace, ".git")}"="read")
        assert argv =~ ~s("#{extra_root}"="write")
        assert argv =~ "network.enabled=true"

        json = File.read!(json_trace)
        assert length(Regex.scan(~r/"permissions":"symphony-worktree"/, json)) == 2
        refute json =~ "sandboxPolicy"
      after
        AppServer.stop_session(session)
      end
    after
      Workspace.remove_issue_workspaces(task)
      File.rm_rf(test_root)
    end
  end

  test "failed after_create removes a newly created Git worktree" do
    test_root = tmp_path("worktree-hook-failure")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    source = create_git_repository(repository_root, "example.repo")
    task = issue("111", "Hook failure", "example.repo")
    workspace = Path.join(workspace_root, Workspace.workspace_key(task))

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root,
        hook_after_create: "exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue(task)

      refute File.exists?(workspace)
      refute git(source, ["worktree", "list", "--porcelain"]) =~ workspace
    after
      Workspace.remove_issue_workspaces(task)
      File.rm_rf(test_root)
    end
  end

  test "workspace repository association changes fail safely" do
    test_root = tmp_path("worktree-mismatch")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    _first_source = create_git_repository(repository_root, "first.repo")
    _second_source = create_git_repository(repository_root, "second.repo")
    original = issue("201", "Task", "first.repo")
    changed = issue("201", "Task renamed", "second.repo")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue(original)

      assert {:error, {:workspace_repository_mismatch, ^workspace, _first, _second}} =
               Workspace.create_for_issue(changed)

      assert File.dir?(workspace)
      assert git(workspace, ["branch", "--show-current"]) == "feature/201-task"
    after
      Workspace.remove_issue_workspaces(original)
      File.rm_rf(test_root)
    end
  end

  test "cleanup removes only the owned linked worktree and preserves source and peers" do
    test_root = tmp_path("worktree-cleanup")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    source = create_git_repository(repository_root, "example.repo")
    removed_issue = issue("301", "Remove me", "example.repo")
    kept_issue = issue("302", "Keep me", "example.repo")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root
      )

      assert {:ok, removed_workspace} = Workspace.create_for_issue(removed_issue)
      assert {:ok, kept_workspace} = Workspace.create_for_issue(kept_issue)
      unowned = Path.join(workspace_root, "todoist-301-unowned")
      File.mkdir_p!(unowned)
      File.write!(Path.join(removed_workspace, "dirty.txt"), "discard on terminal cleanup")

      assert :ok = Workspace.remove_issue_workspaces(removed_issue)

      refute File.exists?(removed_workspace)
      assert File.dir?(kept_workspace)
      assert File.dir?(unowned)
      assert File.dir?(source)
      refute git(source, ["worktree", "list", "--porcelain"]) =~ removed_workspace
    after
      Workspace.remove_issue_workspaces(kept_issue)
      File.rm_rf(test_root)
    end
  end

  test "stale Git worktree metadata is pruned before recreating the owned workspace" do
    test_root = tmp_path("worktree-stale")
    repository_root = Path.join(test_root, "repositories")
    workspace_root = Path.join(test_root, "workspaces")
    source = create_git_repository(repository_root, "example.repo")
    task = issue("401", "Recover stale worktree", "example.repo")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_root: repository_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue(task)
      assert {:ok, _removed} = File.rm_rf(workspace)

      assert {:ok, ^workspace} = Workspace.create_for_issue(task)
      assert File.dir?(workspace)

      assert git(workspace, ["branch", "--show-current"]) ==
               "feature/401-recover-stale-worktree"

      assert git(source, ["worktree", "list", "--porcelain"]) =~ workspace
    after
      Workspace.remove_issue_workspaces(task)
      File.rm_rf(test_root)
    end
  end

  defp issue(id, title, repository \\ nil, task_id \\ nil) do
    %Issue{
      id: id,
      identifier: "TODOIST-#{id}",
      title: title,
      execution_settings: %TaskExecutionSettings{repo: repository, task_id: task_id},
      dispatchable: true
    }
  end

  defp create_git_repository(root, name) do
    repository = Path.join(root, name)
    File.mkdir_p!(repository)
    assert {_output, 0} = System.cmd("git", ["-C", repository, "init", "-b", "main"])
    assert {_output, 0} = System.cmd("git", ["-C", repository, "config", "user.name", "Test User"])
    assert {_output, 0} = System.cmd("git", ["-C", repository, "config", "user.email", "test@example.com"])
    File.write!(Path.join(repository, "README.md"), "source\n")
    assert {_output, 0} = System.cmd("git", ["-C", repository, "add", "README.md"])
    assert {_output, 0} = System.cmd("git", ["-C", repository, "commit", "-m", "initial"])
    repository
  end

  defp git(repository, args) do
    {output, 0} = System.cmd("git", ["-C", repository | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp todoist_after_create_hook do
    workflow_path = Path.expand("../../WORKFLOW.todoist.md", __DIR__)
    {:ok, %{config: config}} = Workflow.load(workflow_path)
    get_in(config, ["hooks", "after_create"])
  end

  defp tmp_path(name) do
    Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
  end
end
