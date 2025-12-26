defmodule Conjure.ToolsTest do
  use ExUnit.Case

  alias Conjure.{ToolCall, Tools}

  describe "definitions/1" do
    test "returns all tool definitions" do
      tools = Tools.definitions()
      assert length(tools) == 4
    end

    test "each tool has required schema fields" do
      for tool <- Tools.definitions() do
        assert Map.has_key?(tool, "name")
        assert Map.has_key?(tool, "description")
        assert Map.has_key?(tool, "input_schema")
      end
    end

    test "view tool has correct schema" do
      view = Tools.view_tool()

      assert view["name"] == "view"
      assert view["input_schema"]["required"] == ["path"]
    end

    test "bash_tool has correct schema" do
      bash = Tools.bash_tool()

      assert bash["name"] == "bash_tool"
      assert "command" in bash["input_schema"]["required"]
    end
  end

  describe "parse_tool_use/1" do
    test "parses a valid tool_use block" do
      block = %{
        "type" => "tool_use",
        "id" => "toolu_123",
        "name" => "view",
        "input" => %{"path" => "/test/path"}
      }

      {:ok, tool_call} = Tools.parse_tool_use(block)

      assert %ToolCall{} = tool_call
      assert tool_call.id == "toolu_123"
      assert tool_call.name == "view"
      assert tool_call.input["path"] == "/test/path"
    end

    test "returns error for non-tool_use block" do
      block = %{"type" => "text", "text" => "Hello"}

      {:error, {:not_tool_use_block, _}} = Tools.parse_tool_use(block)
    end
  end

  describe "parse_tool_uses/1" do
    test "extracts all tool_use blocks from content" do
      content = [
        %{"type" => "text", "text" => "I'll help you with that"},
        %{"type" => "tool_use", "id" => "t1", "name" => "view", "input" => %{"path" => "/a"}},
        %{
          "type" => "tool_use",
          "id" => "t2",
          "name" => "bash_tool",
          "input" => %{"command" => "ls"}
        }
      ]

      tool_calls = Tools.parse_tool_uses(content)

      assert length(tool_calls) == 2
      assert Enum.at(tool_calls, 0).id == "t1"
      assert Enum.at(tool_calls, 1).id == "t2"
    end

    test "returns empty list when no tool_use blocks" do
      content = [%{"type" => "text", "text" => "Just text"}]

      assert Tools.parse_tool_uses(content) == []
    end
  end

  describe "valid_tool?/1" do
    test "returns true for valid tool names" do
      assert Tools.valid_tool?("view")
      assert Tools.valid_tool?("bash_tool")
      assert Tools.valid_tool?("create_file")
      assert Tools.valid_tool?("str_replace")
    end

    test "returns false for invalid tool names" do
      refute Tools.valid_tool?("invalid")
      refute Tools.valid_tool?("")
    end
  end
end
