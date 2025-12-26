defmodule ConjureTest do
  use ExUnit.Case
  doctest Conjure

  @fixtures_path Path.expand("fixtures/skills", __DIR__)

  describe "load/1" do
    test "loads skills from a directory" do
      {:ok, skills} = Conjure.load(@fixtures_path)

      assert length(skills) == 2
      names = Enum.map(skills, & &1.name)
      assert "pdf" in names
      assert "minimal" in names
    end

    test "returns error for non-existent path" do
      {:error, error} = Conjure.load("/non/existent/path")
      assert error.type == :file_not_found
    end
  end

  describe "load_body/1" do
    test "loads the body content of a skill" do
      {:ok, [skill | _]} = Conjure.load(@fixtures_path)
      assert skill.body_loaded == false
      assert skill.body == nil

      {:ok, loaded} = Conjure.load_body(skill)
      assert loaded.body_loaded == true
      assert loaded.body =~ "# PDF Skill" or loaded.body =~ "# Minimal Skill"
    end
  end

  describe "system_prompt/2" do
    test "generates XML-formatted skill listing" do
      {:ok, skills} = Conjure.load(@fixtures_path)
      prompt = Conjure.system_prompt(skills)

      assert prompt =~ "<skills>"
      assert prompt =~ "</skills>"
      assert prompt =~ "<available_skills>"
      assert prompt =~ "<name>pdf</name>"
      assert prompt =~ "<name>minimal</name>"
    end

    test "includes skill descriptions" do
      {:ok, skills} = Conjure.load(@fixtures_path)
      prompt = Conjure.system_prompt(skills)

      assert prompt =~ "PDF manipulation"
    end
  end

  describe "tool_definitions/1" do
    test "returns all tool definitions by default" do
      tools = Conjure.tool_definitions()

      assert length(tools) == 4
      names = Enum.map(tools, & &1["name"])
      assert "view" in names
      assert "bash_tool" in names
      assert "create_file" in names
      assert "str_replace" in names
    end

    test "filters tools with :only option" do
      tools = Conjure.tool_definitions(only: ["view", "bash_tool"])

      assert length(tools) == 2
      names = Enum.map(tools, & &1["name"])
      assert "view" in names
      assert "bash_tool" in names
    end

    test "filters tools with :except option" do
      tools = Conjure.tool_definitions(except: ["str_replace"])

      assert length(tools) == 3
      names = Enum.map(tools, & &1["name"])
      refute "str_replace" in names
    end
  end

  describe "validate/1" do
    test "validates a valid skill" do
      {:ok, [skill | _]} = Conjure.load(@fixtures_path)
      assert :ok == Conjure.validate(skill)
    end
  end
end
