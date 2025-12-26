defmodule Conjure.Files.AnthropicTest do
  use ExUnit.Case, async: true

  alias Conjure.Error
  alias Conjure.Files.Anthropic, as: Files

  describe "extract_file_ids/1" do
    test "extracts file IDs from response" do
      response = %{
        "content" => [
          %{
            "type" => "code_execution_result",
            "content" => [
              %{"type" => "file", "file_id" => "file_abc"},
              %{"type" => "file", "file_id" => "file_def"}
            ]
          }
        ]
      }

      file_ids = Files.extract_file_ids(response)

      assert "file_abc" in file_ids
      assert "file_def" in file_ids
    end

    test "returns empty list when no files" do
      response = %{"content" => [%{"type" => "text", "text" => "Hello"}]}

      assert Files.extract_file_ids(response) == []
    end
  end

  describe "metadata/3" do
    test "returns file metadata" do
      api_callback = fn :get, "/v1/files/file_123", nil, _opts ->
        {:ok,
         %{
           "id" => "file_123",
           "filename" => "report.xlsx",
           "size_bytes" => 15_234,
           "created_at" => "2024-01-15T10:30:00Z",
           "purpose" => "skill_output"
         }}
      end

      {:ok, metadata} = Files.metadata("file_123", api_callback)

      assert metadata.id == "file_123"
      assert metadata.filename == "report.xlsx"
      assert metadata.size_bytes == 15_234
      assert metadata.created_at == "2024-01-15T10:30:00Z"
      assert metadata.purpose == "skill_output"
    end

    test "returns error for not found" do
      api_callback = fn :get, _path, nil, _opts ->
        {:error, {:api_error, 404, %{"error" => "Not found"}}}
      end

      {:error, %Error{type: :file_download_failed}} =
        Files.metadata("file_notfound", api_callback)
    end
  end

  describe "download_content/3" do
    test "downloads binary content" do
      content = "binary file content"

      api_callback = fn :get, "/v1/files/file_123/content", nil, _opts ->
        {:ok, content}
      end

      {:ok, downloaded} = Files.download_content("file_123", api_callback)

      assert downloaded == content
    end

    test "handles wrapped content response" do
      content = "wrapped content"

      api_callback = fn :get, _path, nil, _opts ->
        {:ok, %{"content" => content}}
      end

      {:ok, downloaded} = Files.download_content("file_123", api_callback)

      assert downloaded == content
    end
  end

  describe "download/3" do
    test "returns content and filename" do
      api_callback = fn :get, path, nil, _opts ->
        cond do
          path == "/v1/files/file_123" ->
            {:ok,
             %{
               "id" => "file_123",
               "filename" => "report.xlsx",
               "size_bytes" => 100,
               "created_at" => "2024-01-01",
               "purpose" => "output"
             }}

          path == "/v1/files/file_123/content" ->
            {:ok, "file content"}
        end
      end

      {:ok, content, filename} = Files.download("file_123", api_callback)

      assert content == "file content"
      assert filename == "report.xlsx"
    end
  end

  describe "download_to_file/4" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "conjure_files_test_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "downloads and saves file", %{tmp_dir: tmp_dir} do
      content = "test content"

      api_callback = fn :get, path, nil, _opts ->
        cond do
          path == "/v1/files/file_123" ->
            {:ok,
             %{
               "id" => "file_123",
               "filename" => "test.txt",
               "size_bytes" => byte_size(content),
               "created_at" => "2024-01-01",
               "purpose" => "output"
             }}

          path == "/v1/files/file_123/content" ->
            {:ok, content}
        end
      end

      {:ok, file_path} = Files.download_to_file("file_123", tmp_dir, api_callback)

      assert file_path == Path.join(tmp_dir, "test.txt")
      assert File.read!(file_path) == content
    end

    test "fails if file exists without overwrite", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(tmp_dir)
      existing_file = Path.join(tmp_dir, "existing.txt")
      File.write!(existing_file, "existing content")

      api_callback = fn :get, path, nil, _opts ->
        if path =~ ~r/\/content$/ do
          {:ok, "new content"}
        else
          {:ok,
           %{
             "id" => "file_123",
             "filename" => "existing.txt",
             "size_bytes" => 11,
             "created_at" => "2024-01-01",
             "purpose" => "output"
           }}
        end
      end

      {:error, %Error{type: :file_download_failed}} =
        Files.download_to_file("file_123", tmp_dir, api_callback)
    end

    test "overwrites when option set", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(tmp_dir)
      existing_file = Path.join(tmp_dir, "existing.txt")
      File.write!(existing_file, "old content")

      api_callback = fn :get, path, nil, _opts ->
        if path =~ ~r/\/content$/ do
          {:ok, "new content"}
        else
          {:ok,
           %{
             "id" => "file_123",
             "filename" => "existing.txt",
             "size_bytes" => 11,
             "created_at" => "2024-01-01",
             "purpose" => "output"
           }}
        end
      end

      {:ok, file_path} =
        Files.download_to_file(
          "file_123",
          tmp_dir,
          api_callback,
          overwrite: true
        )

      assert File.read!(file_path) == "new content"
    end
  end

  describe "delete/3" do
    test "deletes file" do
      api_callback = fn :delete, "/v1/files/file_123", nil, _opts ->
        {:ok, %{}}
      end

      assert :ok = Files.delete("file_123", api_callback)
    end

    test "returns error on failure" do
      api_callback = fn :delete, _path, nil, _opts ->
        {:error, {:api_error, 404, "Not found"}}
      end

      {:error, %Error{type: :file_download_failed}} =
        Files.delete("file_notfound", api_callback)
    end
  end

  describe "list/2" do
    test "lists files" do
      api_callback = fn :get, path, nil, _opts ->
        assert path =~ "/v1/files"

        {:ok,
         %{
           "data" => [
             %{"id" => "file_1", "filename" => "a.xlsx"},
             %{"id" => "file_2", "filename" => "b.pdf"}
           ]
         }}
      end

      {:ok, files} = Files.list(api_callback)

      assert length(files) == 2
    end

    test "respects limit option" do
      api_callback = fn :get, path, nil, _opts ->
        assert path =~ "limit=10"
        {:ok, %{"data" => []}}
      end

      {:ok, _} = Files.list(api_callback, limit: 10)
    end

    test "filters by purpose" do
      api_callback = fn :get, path, nil, _opts ->
        assert path =~ "purpose=skill_output"
        {:ok, %{"data" => []}}
      end

      {:ok, _} = Files.list(api_callback, purpose: "skill_output")
    end
  end

  describe "download_all/4" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "conjure_files_all_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "downloads multiple files", %{tmp_dir: tmp_dir} do
      api_callback = fn :get, path, nil, _opts ->
        cond do
          path == "/v1/files/file_1" ->
            {:ok,
             %{
               "id" => "file_1",
               "filename" => "a.txt",
               "size_bytes" => 1,
               "created_at" => "2024-01-01",
               "purpose" => "output"
             }}

          path == "/v1/files/file_2" ->
            {:ok,
             %{
               "id" => "file_2",
               "filename" => "b.txt",
               "size_bytes" => 1,
               "created_at" => "2024-01-01",
               "purpose" => "output"
             }}

          path =~ ~r/\/content$/ ->
            {:ok, "content"}
        end
      end

      results = Files.download_all(["file_1", "file_2"], tmp_dir, api_callback)

      assert length(results) == 2
      assert Enum.all?(results, fn {status, _} -> status == :ok end)
    end
  end
end
