defmodule Conjure.Storage.LocalTest do
  use ExUnit.Case, async: true

  alias Conjure.Storage
  alias Conjure.Storage.Local

  setup do
    session_id = Storage.generate_session_id()
    {:ok, storage} = Local.init(session_id, [])

    on_exit(fn ->
      # Clean up even if test fails
      try do
        Local.cleanup(storage)
      rescue
        _ -> :ok
      end
    end)

    {:ok, storage: storage, session_id: session_id}
  end

  describe "init/2" do
    test "creates directory", %{storage: storage} do
      {:ok, path} = Local.local_path(storage)
      assert File.dir?(path)
    end

    test "respects base_path option" do
      base = Path.join(System.tmp_dir!(), "custom_base_#{:rand.uniform(10000)}")
      session_id = Storage.generate_session_id()
      {:ok, storage} = Local.init(session_id, base_path: base)

      {:ok, path} = Local.local_path(storage)
      assert String.starts_with?(path, base)

      Local.cleanup(storage)
      File.rm_rf!(base)
    end

    test "respects prefix option" do
      session_id = Storage.generate_session_id()
      {:ok, storage} = Local.init(session_id, prefix: "custom_prefix")

      {:ok, path} = Local.local_path(storage)
      assert String.contains?(path, "custom_prefix_#{session_id}")

      Local.cleanup(storage)
    end

    test "returns error for invalid base_path" do
      session_id = Storage.generate_session_id()
      # Use a path that can't be created (file exists where dir expected)
      temp_file = Path.join(System.tmp_dir!(), "test_file_#{:rand.uniform(10000)}")
      File.write!(temp_file, "content")

      result = Local.init(session_id, base_path: temp_file)
      assert {:error, {:mkdir_failed, _, _}} = result

      File.rm!(temp_file)
    end
  end

  describe "local_path/1" do
    test "returns the storage directory path", %{storage: storage} do
      {:ok, path} = Local.local_path(storage)

      assert is_binary(path)
      assert File.dir?(path)
    end
  end

  describe "write/3 and read/2" do
    test "writes and reads file", %{storage: storage} do
      content = "hello world"
      {:ok, file_ref} = Local.write(storage, "test.txt", content)

      assert file_ref.path == "test.txt"
      assert file_ref.size == byte_size(content)

      {:ok, read_content} = Local.read(storage, "test.txt")
      assert read_content == content
    end

    test "creates nested directories", %{storage: storage} do
      content = "nested content"
      {:ok, _ref} = Local.write(storage, "a/b/c/deep.txt", content)

      {:ok, read_content} = Local.read(storage, "a/b/c/deep.txt")
      assert read_content == content
    end

    test "writes binary content", %{storage: storage} do
      content = <<0, 1, 2, 255, 128>>
      {:ok, _ref} = Local.write(storage, "binary.bin", content)

      {:ok, read_content} = Local.read(storage, "binary.bin")
      assert read_content == content
    end

    test "returns file_ref with correct metadata", %{storage: storage} do
      content = "test content"
      {:ok, file_ref} = Local.write(storage, "file.json", content)

      assert file_ref.path == "file.json"
      assert file_ref.size == byte_size(content)
      assert file_ref.content_type == "application/json"
      assert file_ref.checksum != nil
      assert %DateTime{} = file_ref.created_at
    end

    test "read returns error for non-existent file", %{storage: storage} do
      assert {:error, {:file_not_found, "nope.txt"}} = Local.read(storage, "nope.txt")
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{storage: storage} do
      Local.write(storage, "exists.txt", "yes")
      assert Local.exists?(storage, "exists.txt")
    end

    test "returns false for non-existing file", %{storage: storage} do
      refute Local.exists?(storage, "nope.txt")
    end

    test "returns true for nested file", %{storage: storage} do
      Local.write(storage, "dir/nested.txt", "content")
      assert Local.exists?(storage, "dir/nested.txt")
    end
  end

  describe "delete/2" do
    test "deletes existing file", %{storage: storage} do
      Local.write(storage, "to_delete.txt", "bye")
      assert Local.exists?(storage, "to_delete.txt")

      :ok = Local.delete(storage, "to_delete.txt")
      refute Local.exists?(storage, "to_delete.txt")
    end

    test "returns ok for non-existing file", %{storage: storage} do
      :ok = Local.delete(storage, "already_gone.txt")
    end

    test "deletes nested files", %{storage: storage} do
      Local.write(storage, "dir/file.txt", "content")
      assert Local.exists?(storage, "dir/file.txt")

      :ok = Local.delete(storage, "dir/file.txt")
      refute Local.exists?(storage, "dir/file.txt")
    end
  end

  describe "list/1" do
    test "returns empty list for empty storage", %{storage: storage} do
      {:ok, files} = Local.list(storage)
      assert files == []
    end

    test "lists all files", %{storage: storage} do
      Local.write(storage, "a.txt", "a")
      Local.write(storage, "b.txt", "b")
      Local.write(storage, "dir/c.txt", "c")

      {:ok, files} = Local.list(storage)

      paths = Enum.map(files, & &1.path) |> Enum.sort()
      assert paths == ["a.txt", "b.txt", "dir/c.txt"]
    end

    test "returns file_refs with metadata", %{storage: storage} do
      Local.write(storage, "test.json", "{}")

      {:ok, [file_ref]} = Local.list(storage)

      assert file_ref.path == "test.json"
      assert file_ref.size == 2
      assert file_ref.content_type == "application/json"
      assert %DateTime{} = file_ref.created_at
    end
  end

  describe "cleanup/1" do
    test "removes all files and directory" do
      session_id = Storage.generate_session_id()
      {:ok, storage} = Local.init(session_id, [])

      Local.write(storage, "file.txt", "data")
      {:ok, path} = Local.local_path(storage)

      assert File.dir?(path)

      :ok = Local.cleanup(storage)

      refute File.dir?(path)
    end

    test "respects cleanup_on_exit: false" do
      session_id = Storage.generate_session_id()
      {:ok, storage} = Local.init(session_id, cleanup_on_exit: false)

      Local.write(storage, "keep.txt", "data")
      {:ok, path} = Local.local_path(storage)

      :ok = Local.cleanup(storage)

      assert File.dir?(path)
      File.rm_rf!(path)
    end
  end
end
