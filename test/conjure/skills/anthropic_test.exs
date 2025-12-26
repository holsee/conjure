defmodule Conjure.Skills.AnthropicTest do
  use ExUnit.Case, async: true

  alias Conjure.Error
  alias Conjure.Skills.Anthropic, as: Skills

  @fixtures_path "test/fixtures/skills"

  describe "package_skill/1" do
    test "packages skill directory with all files" do
      skill_path = Path.join(@fixtures_path, "pdf")

      {:ok, files} = Skills.package_skill(skill_path)

      assert is_list(files)
      assert length(files) >= 2

      # Paths are prefixed with directory name as required by Anthropic API
      paths = Enum.map(files, fn {path, _} -> path end)
      assert "pdf/SKILL.md" in paths
      assert "pdf/scripts/extract_text.py" in paths
    end

    test "returns error for non-existent directory" do
      {:error, %Error{type: :file_not_found}} =
        Skills.package_skill("/non/existent/path")
    end

    test "returns error for directory without SKILL.md" do
      # Create temp dir without SKILL.md
      tmp_dir = Path.join(System.tmp_dir!(), "conjure_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      try do
        {:error, %Error{type: :invalid_skill_structure}} =
          Skills.package_skill(tmp_dir)
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "packages .skill file by extracting it first" do
      skill_file = "examples/skills/timestamp-echo.skill"

      {:ok, files} = Skills.package_skill(skill_file)

      assert is_list(files)
      # Paths are prefixed with skill name as required by Anthropic API
      paths = Enum.map(files, fn {path, _} -> path end)
      assert "timestamp-echo/SKILL.md" in paths
      assert "timestamp-echo/scripts/timestamp_echo.py" in paths
    end

    test "returns error for non-existent .skill file" do
      {:error, %Error{}} = Skills.package_skill("/non/existent/file.skill")
    end

    test "includes binary content of files" do
      skill_path = Path.join(@fixtures_path, "minimal")

      {:ok, files} = Skills.package_skill(skill_path)

      # Path is prefixed with directory name
      {_, skill_md_content} = Enum.find(files, fn {path, _} -> path == "minimal/SKILL.md" end)
      assert is_binary(skill_md_content)
      # YAML frontmatter
      assert skill_md_content =~ "---"
    end
  end

  describe "package_size/1" do
    test "calculates total size of packaged files" do
      files = [
        {"file1.txt", "hello"},
        {"file2.txt", "world"}
      ]

      assert Skills.package_size(files) == 10
    end

    test "returns 0 for empty list" do
      assert Skills.package_size([]) == 0
    end
  end

  describe "upload/3" do
    test "uploads skill and returns skill_id" do
      skill_path = Path.join(@fixtures_path, "minimal")

      api_callback = fn :post, "/v1/skills", multipart, opts ->
        assert Keyword.get(opts, :multipart) == true
        assert is_list(multipart)

        # Check display_title is present
        assert {"display_title", "minimal"} in multipart

        # Check files are present
        files = for {"files[]", file} <- multipart, do: file
        refute Enum.empty?(files)

        {:ok,
         %{
           "id" => "skill_test123",
           "display_title" => "minimal",
           "versions" => [%{"version" => "v1"}]
         }}
      end

      {:ok, result} = Skills.upload(skill_path, api_callback)

      assert result.skill_id == "skill_test123"
      assert result.version == "v1"
      assert result.display_title == "minimal"
    end

    test "uses custom display_title when provided" do
      skill_path = Path.join(@fixtures_path, "minimal")

      api_callback = fn :post, "/v1/skills", multipart, opts ->
        assert Keyword.get(opts, :multipart) == true
        assert {"display_title", "Custom Title"} in multipart

        {:ok,
         %{
           "id" => "skill_test123",
           "display_title" => "Custom Title",
           "versions" => [%{"version" => "v1"}]
         }}
      end

      {:ok, result} = Skills.upload(skill_path, api_callback, display_title: "Custom Title")

      assert result.display_title == "Custom Title"
    end

    test "returns error on API failure" do
      skill_path = Path.join(@fixtures_path, "minimal")

      api_callback = fn :post, "/v1/skills", _multipart, _opts ->
        {:error, {:api_error, 400, %{"error" => %{"message" => "Bad request"}}}}
      end

      {:error, %Error{type: :anthropic_api_error}} =
        Skills.upload(skill_path, api_callback)
    end

    test "uploads .skill file directly" do
      skill_file = "examples/skills/timestamp-echo.skill"

      api_callback = fn :post, "/v1/skills", multipart, opts ->
        assert Keyword.get(opts, :multipart) == true
        assert {"display_title", "Timestamp Echo"} in multipart

        # Verify skill contents were extracted with proper prefix
        files = for {"files[]", {path, _content}} <- multipart, do: path
        assert "timestamp-echo/SKILL.md" in files

        {:ok,
         %{
           "id" => "skill_test456",
           "display_title" => "Timestamp Echo",
           "versions" => [%{"version" => "v1"}]
         }}
      end

      {:ok, result} = Skills.upload(skill_file, api_callback, display_title: "Timestamp Echo")

      assert result.skill_id == "skill_test456"
      assert result.version == "v1"
    end
  end

  describe "list/2" do
    test "lists all skills" do
      api_callback = fn :get, "/v1/skills?limit=100", nil, _opts ->
        {:ok,
         %{
           "data" => [
             %{"id" => "skill_1", "display_title" => "Skill 1"},
             %{"id" => "skill_2", "display_title" => "Skill 2"}
           ]
         }}
      end

      {:ok, skills} = Skills.list(api_callback)

      assert length(skills) == 2
    end

    test "filters by source" do
      api_callback = fn :get, path, nil, _opts ->
        assert path =~ "source=custom"
        {:ok, %{"data" => [%{"id" => "custom_skill"}]}}
      end

      {:ok, _} = Skills.list(api_callback, source: :custom)
    end

    test "respects limit option" do
      api_callback = fn :get, path, nil, _opts ->
        assert path =~ "limit=10"
        {:ok, %{"data" => []}}
      end

      {:ok, _} = Skills.list(api_callback, limit: 10)
    end
  end

  describe "get/3" do
    test "gets skill details" do
      api_callback = fn :get, "/v1/skills/skill_123", nil, _opts ->
        {:ok,
         %{
           "id" => "skill_123",
           "display_title" => "Test Skill",
           "source" => "custom"
         }}
      end

      {:ok, skill} = Skills.get("skill_123", api_callback)

      assert skill["id"] == "skill_123"
      assert skill["display_title"] == "Test Skill"
    end
  end

  describe "delete/3" do
    test "deletes skill" do
      api_callback = fn :delete, "/v1/skills/skill_123", nil, _opts ->
        {:ok, %{}}
      end

      assert :ok = Skills.delete("skill_123", api_callback)
    end

    test "returns error on failure" do
      api_callback = fn :delete, _path, nil, _opts ->
        {:error, {:api_error, 404, "Not found"}}
      end

      {:error, %Error{}} = Skills.delete("skill_123", api_callback)
    end
  end

  describe "create_version/4" do
    test "creates new version" do
      skill_path = Path.join(@fixtures_path, "minimal")

      api_callback = fn :post, "/v1/skills/skill_123/versions", multipart, opts ->
        assert Keyword.get(opts, :multipart) == true
        files = for {"files[]", file} <- multipart, do: file
        refute Enum.empty?(files)

        {:ok, %{"version" => "v2"}}
      end

      {:ok, result} = Skills.create_version("skill_123", skill_path, api_callback)

      assert result.version == "v2"
    end
  end

  describe "list_versions/3" do
    test "lists skill versions" do
      api_callback = fn :get, "/v1/skills/skill_123/versions", nil, _opts ->
        {:ok,
         %{
           "data" => [
             %{"version" => "v1", "created_at" => "2024-01-01"},
             %{"version" => "v2", "created_at" => "2024-02-01"}
           ]
         }}
      end

      {:ok, versions} = Skills.list_versions("skill_123", api_callback)

      assert length(versions) == 2
    end
  end

  describe "delete_version/4" do
    test "deletes specific version" do
      api_callback = fn :delete, "/v1/skills/skill_123/versions/v1", nil, _opts ->
        {:ok, %{}}
      end

      assert :ok = Skills.delete_version("skill_123", "v1", api_callback)
    end
  end
end
