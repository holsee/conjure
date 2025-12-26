defmodule Conjure.Executor.LocalTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Conjure.{ExecutionContext, Executor.Local}

  setup do
    # Create a temporary working directory
    work_dir = Path.join(System.tmp_dir!(), "conjure_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(work_dir)

    context =
      ExecutionContext.new(
        working_directory: work_dir,
        allowed_paths: [work_dir],
        timeout: 5_000
      )

    on_exit(fn ->
      File.rm_rf!(work_dir)
    end)

    {:ok, context: context, work_dir: work_dir}
  end

  describe "init/1" do
    test "initializes the context and logs warning", %{context: context} do
      log =
        capture_log(fn ->
          {:ok, ctx} = Local.init(context)
          assert ctx == context
        end)

      assert log =~ "Using Local executor - NO SANDBOXING"
    end
  end

  describe "bash/2" do
    test "executes a simple command", %{context: context} do
      capture_log(fn -> Local.init(context) end)
      {:ok, output} = Local.bash("echo hello", context)

      assert output =~ "hello"
    end

    test "returns error for failed commands", %{context: context} do
      capture_log(fn -> Local.init(context) end)
      {:error, error} = Local.bash("exit 1", context)

      assert error.type == :execution_failed
      assert error.details.exit_code == 1
    end

    test "respects working directory", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)
      {:ok, output} = Local.bash("pwd", context)

      assert String.trim(output) == work_dir
    end
  end

  describe "view/3" do
    test "reads a file", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      test_file = Path.join(work_dir, "test.txt")
      File.write!(test_file, "Hello, World!")

      {:ok, content} = Local.view(test_file, context, [])
      assert content == "Hello, World!"
    end

    test "lists a directory", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      File.write!(Path.join(work_dir, "file1.txt"), "")
      File.write!(Path.join(work_dir, "file2.txt"), "")

      {:ok, listing} = Local.view(work_dir, context, [])

      assert listing =~ "file1.txt"
      assert listing =~ "file2.txt"
    end

    test "supports view_range for partial file reads", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      test_file = Path.join(work_dir, "lines.txt")
      File.write!(test_file, "line1\nline2\nline3\nline4\nline5")

      {:ok, content} = Local.view(test_file, context, view_range: {2, 4})

      assert content =~ "line2"
      assert content =~ "line3"
      assert content =~ "line4"
      refute content =~ "line1"
      refute content =~ "line5"
    end

    test "returns error for non-existent file", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      {:error, error} = Local.view(Path.join(work_dir, "nope.txt"), context, [])
      assert error.type == :file_not_found
    end
  end

  describe "create_file/3" do
    test "creates a file", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      file_path = Path.join(work_dir, "new_file.txt")
      {:ok, _} = Local.create_file(file_path, "New content", context)

      assert File.read!(file_path) == "New content"
    end

    test "creates parent directories", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      file_path = Path.join([work_dir, "nested", "dir", "file.txt"])
      {:ok, _} = Local.create_file(file_path, "Nested content", context)

      assert File.read!(file_path) == "Nested content"
    end
  end

  describe "str_replace/4" do
    test "replaces a unique string", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      file_path = Path.join(work_dir, "replace.txt")
      File.write!(file_path, "Hello, World!")

      {:ok, _} = Local.str_replace(file_path, "World", "Elixir", context)

      assert File.read!(file_path) == "Hello, Elixir!"
    end

    test "returns error if string not found", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      file_path = Path.join(work_dir, "replace.txt")
      File.write!(file_path, "Hello, World!")

      {:error, _} = Local.str_replace(file_path, "NotFound", "Replacement", context)
    end

    test "returns error if string appears multiple times", %{context: context, work_dir: work_dir} do
      capture_log(fn -> Local.init(context) end)

      file_path = Path.join(work_dir, "replace.txt")
      File.write!(file_path, "foo bar foo")

      {:error, _} = Local.str_replace(file_path, "foo", "baz", context)
    end
  end

  describe "path validation" do
    test "blocks access outside allowed paths", %{context: context} do
      capture_log(fn -> Local.init(context) end)

      {:error, error} = Local.view("/etc/passwd", context, [])
      assert error.type == :path_not_allowed
    end
  end
end
