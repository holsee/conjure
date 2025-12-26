defmodule Conjure.ToolCall do
  @moduledoc """
  Represents a tool call from Claude's response.

  When Claude uses a tool, the API response includes a `tool_use` content
  block with an ID, tool name, and input parameters. This struct captures
  that information for processing.

  ## Example

  A tool call from Claude's response:

      %{
        "type" => "tool_use",
        "id" => "toolu_01ABC123",
        "name" => "view",
        "input" => %{"path" => "/path/to/file.txt"}
      }

  Becomes:

      %Conjure.ToolCall{
        id: "toolu_01ABC123",
        name: "view",
        input: %{"path" => "/path/to/file.txt"}
      }
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map()
        }

  @enforce_keys [:id, :name, :input]
  defstruct [:id, :name, :input]

  @doc """
  Creates a ToolCall from a tool_use content block.

  Returns `{:ok, tool_call}` on success, or `{:error, reason}` if the
  block is malformed.
  """
  @spec from_content_block(map()) :: {:ok, t()} | {:error, term()}
  def from_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input})
      when is_binary(id) and is_binary(name) and is_map(input) do
    {:ok, %__MODULE__{id: id, name: name, input: input}}
  end

  def from_content_block(%{"type" => "tool_use"} = block) do
    {:error, {:invalid_tool_use_block, block}}
  end

  def from_content_block(block) do
    {:error, {:not_tool_use_block, block}}
  end

  @doc """
  Extracts the tool call ID.
  """
  @spec id(t()) :: String.t()
  def id(%__MODULE__{id: id}), do: id

  @doc """
  Gets an input parameter value.
  """
  @spec get_input(t(), String.t(), term()) :: term()
  def get_input(%__MODULE__{input: input}, key, default \\ nil) do
    Map.get(input, key, default)
  end
end
