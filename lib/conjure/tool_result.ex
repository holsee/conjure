defmodule Conjure.ToolResult do
  @moduledoc """
  Result of executing a tool call.

  Tool results are sent back to Claude in the conversation to report
  the outcome of tool executions. They include the original tool call ID,
  the result content, and an error flag.

  ## Content Types

  The content can be:
  - A simple string for text output
  - A list of content blocks for complex responses (text, images)

  ## Example

  A successful file read:

      %Conjure.ToolResult{
        tool_use_id: "toolu_01ABC123",
        content: "File contents here...",
        is_error: false
      }

  A failed command:

      %Conjure.ToolResult{
        tool_use_id: "toolu_01ABC123",
        content: "Command failed with exit code 1: No such file",
        is_error: true
      }
  """

  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          type: :tool_result,
          content: content(),
          is_error: boolean()
        }

  @type content :: String.t() | [content_block()]

  @type content_block ::
          %{type: :text, text: String.t()}
          | %{type: :image, source: map()}

  @enforce_keys [:tool_use_id]
  defstruct [
    :tool_use_id,
    type: :tool_result,
    content: "",
    is_error: false
  ]

  @doc """
  Creates a successful tool result.
  """
  @spec success(String.t(), content()) :: t()
  def success(tool_use_id, content) do
    %__MODULE__{
      tool_use_id: tool_use_id,
      content: content,
      is_error: false
    }
  end

  @doc """
  Creates an error tool result.
  """
  @spec error(String.t(), content()) :: t()
  def error(tool_use_id, content) do
    %__MODULE__{
      tool_use_id: tool_use_id,
      content: content,
      is_error: true
    }
  end

  @doc """
  Converts the tool result to the format expected by the Claude API.
  """
  @spec to_api_format(t()) :: map()
  def to_api_format(%__MODULE__{} = result) do
    base = %{
      "type" => "tool_result",
      "tool_use_id" => result.tool_use_id,
      "content" => format_content(result.content)
    }

    if result.is_error do
      Map.put(base, "is_error", true)
    else
      base
    end
  end

  defp format_content(content) when is_binary(content), do: content

  defp format_content(blocks) when is_list(blocks) do
    Enum.map(blocks, &format_content_block/1)
  end

  defp format_content_block(%{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_content_block(%{type: :image, source: source}) do
    %{"type" => "image", "source" => source}
  end
end
