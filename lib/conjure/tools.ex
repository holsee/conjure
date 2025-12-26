defmodule Conjure.Tools do
  @moduledoc """
  Defines tool schemas for the Claude API.

  This module provides the tool definitions that should be passed to the
  Claude API to enable skill execution. The tools include:

  - `view` - Read file contents or directory listings
  - `bash_tool` - Execute bash commands
  - `create_file` - Create new files with content
  - `str_replace` - Replace strings in files

  ## Example

      tools = Conjure.Tools.definitions()
      # Pass to Claude API request body under "tools" key
  """

  alias Conjure.ToolCall

  @doc """
  Returns all tool definitions for skills support.

  ## Options

  * `:only` - List of tool names to include (default: all)
  * `:except` - List of tool names to exclude
  """
  @spec definitions(keyword()) :: [map()]
  def definitions(opts \\ []) do
    all_tools = [
      view_tool(),
      bash_tool(),
      create_file_tool(),
      str_replace_tool()
    ]

    filter_tools(all_tools, opts)
  end

  @doc """
  The 'view' tool for reading files and directories.
  """
  @spec view_tool() :: map()
  def view_tool do
    %{
      "name" => "view",
      "description" =>
        "View file contents or directory listings. For text files, returns the content. For directories, returns a listing up to 2 levels deep. Supports an optional view_range parameter to read specific lines from a file.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Absolute path to file or directory to view"
          },
          "view_range" => %{
            "type" => "array",
            "items" => %{"type" => "integer"},
            "minItems" => 2,
            "maxItems" => 2,
            "description" =>
              "Optional [start_line, end_line] for text files. Lines are 1-indexed. Use -1 for end_line to read to end of file."
          }
        },
        "required" => ["path"]
      }
    }
  end

  @doc """
  The 'bash_tool' for executing bash commands.
  """
  @spec bash_tool() :: map()
  def bash_tool do
    %{
      "name" => "bash_tool",
      "description" =>
        "Execute a bash command in the execution environment. Use this to run scripts, install packages, or perform system operations. Commands run in the working directory.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The bash command to execute"
          },
          "description" => %{
            "type" => "string",
            "description" => "A brief description of why this command is being run"
          }
        },
        "required" => ["command", "description"]
      }
    }
  end

  @doc """
  The 'create_file' tool for creating new files.
  """
  @spec create_file_tool() :: map()
  def create_file_tool do
    %{
      "name" => "create_file",
      "description" =>
        "Create a new file with the specified content. The file will be created at the given path. Parent directories will be created if they don't exist.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path where the file should be created"
          },
          "file_text" => %{
            "type" => "string",
            "description" => "Content to write to the file"
          },
          "description" => %{
            "type" => "string",
            "description" => "A brief description of why this file is being created"
          }
        },
        "required" => ["path", "file_text", "description"]
      }
    }
  end

  @doc """
  The 'str_replace' tool for editing files.
  """
  @spec str_replace_tool() :: map()
  def str_replace_tool do
    %{
      "name" => "str_replace",
      "description" =>
        "Replace a unique string in a file with another string. The old_str must appear exactly once in the file. Use this for precise edits to existing files.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file to edit"
          },
          "old_str" => %{
            "type" => "string",
            "description" => "String to replace (must appear exactly once in the file)"
          },
          "new_str" => %{
            "type" => "string",
            "description" => "Replacement string (can be empty to delete old_str)"
          },
          "description" => %{
            "type" => "string",
            "description" => "A brief description of why this edit is being made"
          }
        },
        "required" => ["path", "old_str", "description"]
      }
    }
  end

  @doc """
  Parses a tool_use block from Claude's response into a ToolCall.
  """
  @spec parse_tool_use(map()) :: {:ok, ToolCall.t()} | {:error, term()}
  def parse_tool_use(block), do: ToolCall.from_content_block(block)

  @doc """
  Parses multiple tool_use blocks from a response.
  """
  @spec parse_tool_uses([map()]) :: [ToolCall.t()]
  def parse_tool_uses(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(&parse_tool_use/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, tool_call} -> tool_call end)
  end

  @doc """
  Returns the tool names that are available.
  """
  @spec available_tool_names() :: [String.t()]
  def available_tool_names do
    ["view", "bash_tool", "create_file", "str_replace"]
  end

  @doc """
  Checks if a tool name is valid.
  """
  @spec valid_tool?(String.t()) :: boolean()
  def valid_tool?(name), do: name in available_tool_names()

  # Private helpers

  defp filter_tools(tools, opts) do
    tools
    |> apply_only_filter(opts)
    |> apply_except_filter(opts)
  end

  defp apply_only_filter(tools, opts) do
    case Keyword.get(opts, :only) do
      nil -> tools
      only -> Enum.filter(tools, &(&1["name"] in only))
    end
  end

  defp apply_except_filter(tools, opts) do
    case Keyword.get(opts, :except) do
      nil -> tools
      except -> Enum.reject(tools, &(&1["name"] in except))
    end
  end
end
