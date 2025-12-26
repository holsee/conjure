defmodule Conjure.LoaderTest do
  use ExUnit.Case

  alias Conjure.{Loader, Skill}

  @fixtures_path Path.expand("../fixtures/skills", __DIR__)

  describe "scan_and_load/1" do
    test "scans directory and loads skills" do
      {:ok, skills} = Loader.scan_and_load(@fixtures_path)

      assert length(skills) == 2
      assert Enum.all?(skills, &is_struct(&1, Skill))
    end

    test "loads skill metadata correctly" do
      {:ok, skills} = Loader.scan_and_load(@fixtures_path)
      pdf = Enum.find(skills, &(&1.name == "pdf"))

      assert pdf.name == "pdf"
      assert pdf.description =~ "PDF manipulation"
      assert pdf.license == "MIT"
      assert pdf.version == "1.0.0"
      assert pdf.allowed_tools == ["bash", "view", "create_file"]
    end

    test "scans resource directories" do
      {:ok, skills} = Loader.scan_and_load(@fixtures_path)
      pdf = Enum.find(skills, &(&1.name == "pdf"))

      assert "scripts/extract_text.py" in pdf.resources.scripts
    end
  end

  describe "parse_frontmatter/1" do
    test "parses valid frontmatter" do
      content = """
      ---
      name: test-skill
      description: A test skill
      license: MIT
      ---
      # Body content
      """

      {:ok, frontmatter, body} = Loader.parse_frontmatter(content)

      assert frontmatter.name == "test-skill"
      assert frontmatter.description == "A test skill"
      assert frontmatter.license == "MIT"
      assert body =~ "# Body content"
    end

    test "returns error for missing frontmatter" do
      content = "# Just a markdown file"

      {:error, error} = Loader.parse_frontmatter(content)
      assert error.type == :invalid_frontmatter
    end

    test "returns error for missing required fields" do
      content = """
      ---
      name: test-skill
      ---
      Body
      """

      {:error, error} = Loader.parse_frontmatter(content)
      assert error.type == :invalid_frontmatter
    end

    test "validates name format" do
      content = """
      ---
      name: Invalid Name
      description: A test
      ---
      Body
      """

      {:error, error} = Loader.parse_frontmatter(content)
      assert error.type == :invalid_frontmatter
      assert error.message =~ "lowercase alphanumeric"
    end
  end

  describe "load_body/1" do
    test "loads skill body content" do
      {:ok, skills} = Loader.scan_and_load(@fixtures_path)
      skill = Enum.find(skills, &(&1.name == "pdf"))

      assert skill.body_loaded == false

      {:ok, loaded} = Loader.load_body(skill)

      assert loaded.body_loaded == true
      assert loaded.body =~ "# PDF Skill"
    end

    test "returns already loaded skill unchanged" do
      {:ok, skills} = Loader.scan_and_load(@fixtures_path)
      skill = Enum.find(skills, &(&1.name == "pdf"))

      {:ok, loaded} = Loader.load_body(skill)
      {:ok, reloaded} = Loader.load_body(loaded)

      assert loaded == reloaded
    end
  end

  describe "validate/1" do
    test "validates a valid skill" do
      {:ok, skills} = Loader.scan_and_load(@fixtures_path)
      skill = hd(skills)

      assert :ok == Loader.validate(skill)
    end

    test "returns errors for invalid skill" do
      invalid_skill = %Skill{
        name: "",
        description: "",
        path: "/non/existent"
      }

      {:error, errors} = Loader.validate(invalid_skill)
      assert is_list(errors)
      assert not Enum.empty?(errors)
    end
  end
end
