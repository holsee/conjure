defmodule Conjure.NativeSkillTest do
  use ExUnit.Case, async: true

  alias Conjure.NativeSkill

  # Test skill module that implements the behaviour
  defmodule TestSkill do
    @behaviour NativeSkill

    @impl true
    def __skill_info__ do
      %{
        name: "test-skill",
        description: "A test skill for unit tests",
        allowed_tools: [:execute, :read]
      }
    end

    @impl true
    def execute("echo " <> text, _context) do
      {:ok, text}
    end

    def execute("fail", _context) do
      {:error, "Intentional failure"}
    end

    def execute(_, _context) do
      {:ok, "Unknown command"}
    end

    @impl true
    def read("data", _context, _opts) do
      {:ok, "test data"}
    end

    def read(path, _context, opts) do
      {:ok, "Read #{path} with opts #{inspect(opts)}"}
    end
  end

  # Skill with all callbacks
  defmodule FullSkill do
    @behaviour NativeSkill

    @impl true
    def __skill_info__ do
      %{
        name: "full-skill",
        description: "Skill with all callbacks",
        allowed_tools: [:execute, :read, :write, :modify]
      }
    end

    @impl true
    def execute(cmd, _ctx), do: {:ok, "Executed: #{cmd}"}

    @impl true
    def read(path, _ctx, _opts), do: {:ok, "Read: #{path}"}

    @impl true
    def write(path, content, _ctx), do: {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}

    @impl true
    def modify(path, old, new, _ctx), do: {:ok, "Modified #{path}: #{old} -> #{new}"}
  end

  # Not a skill - doesn't implement behaviour
  defmodule NotASkill do
    def some_function, do: :ok
  end

  describe "implements?/1" do
    test "returns true for module implementing behaviour" do
      assert NativeSkill.implements?(TestSkill)
    end

    test "returns true for full skill" do
      assert NativeSkill.implements?(FullSkill)
    end

    test "returns false for module not implementing behaviour" do
      refute NativeSkill.implements?(NotASkill)
    end

    test "returns false for standard library modules" do
      refute NativeSkill.implements?(String)
      refute NativeSkill.implements?(Enum)
    end
  end

  describe "get_info/1" do
    test "returns skill info for implementing module" do
      {:ok, info} = NativeSkill.get_info(TestSkill)

      assert info.name == "test-skill"
      assert info.description == "A test skill for unit tests"
      assert info.allowed_tools == [:execute, :read]
    end

    test "returns error for non-skill module" do
      assert {:error, :not_a_skill} = NativeSkill.get_info(NotASkill)
    end
  end

  describe "tool_definitions/1" do
    test "generates tool definitions for allowed tools" do
      definitions = NativeSkill.tool_definitions(TestSkill)

      assert length(definitions) == 2

      names = Enum.map(definitions, & &1["name"])
      assert "test_skill_execute" in names
      assert "test_skill_read" in names
    end

    test "generates all tool types for full skill" do
      definitions = NativeSkill.tool_definitions(FullSkill)

      assert length(definitions) == 4

      names = Enum.map(definitions, & &1["name"])
      assert "full_skill_execute" in names
      assert "full_skill_read" in names
      assert "full_skill_write" in names
      assert "full_skill_modify" in names
    end

    test "execute tool has correct schema" do
      definitions = NativeSkill.tool_definitions(TestSkill)
      execute_def = Enum.find(definitions, &(&1["name"] == "test_skill_execute"))

      assert execute_def["description"] =~ "Execute a command"
      assert execute_def["input_schema"]["type"] == "object"
      assert execute_def["input_schema"]["properties"]["command"]["type"] == "string"
      assert "command" in execute_def["input_schema"]["required"]
    end

    test "read tool has correct schema" do
      definitions = NativeSkill.tool_definitions(TestSkill)
      read_def = Enum.find(definitions, &(&1["name"] == "test_skill_read"))

      assert read_def["description"] =~ "Read a resource"
      assert read_def["input_schema"]["properties"]["path"]["type"] == "string"
      assert read_def["input_schema"]["properties"]["offset"]["type"] == "integer"
      assert read_def["input_schema"]["properties"]["limit"]["type"] == "integer"
      assert "path" in read_def["input_schema"]["required"]
    end

    test "write tool has correct schema" do
      definitions = NativeSkill.tool_definitions(FullSkill)
      write_def = Enum.find(definitions, &(&1["name"] == "full_skill_write"))

      assert write_def["description"] =~ "Create/write"
      assert write_def["input_schema"]["properties"]["path"]["type"] == "string"
      assert write_def["input_schema"]["properties"]["content"]["type"] == "string"
      assert "path" in write_def["input_schema"]["required"]
      assert "content" in write_def["input_schema"]["required"]
    end

    test "modify tool has correct schema" do
      definitions = NativeSkill.tool_definitions(FullSkill)
      modify_def = Enum.find(definitions, &(&1["name"] == "full_skill_modify"))

      assert modify_def["description"] =~ "Modify"
      assert modify_def["input_schema"]["properties"]["path"]["type"] == "string"
      assert modify_def["input_schema"]["properties"]["old_content"]["type"] == "string"
      assert modify_def["input_schema"]["properties"]["new_content"]["type"] == "string"
    end

    test "returns empty list for non-skill module" do
      assert NativeSkill.tool_definitions(NotASkill) == []
    end
  end
end
