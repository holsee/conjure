defmodule Conjure.API do
  @moduledoc """
  Helpers for Claude API integration.

  This module provides utilities for building API requests and parsing
  responses. It does not make HTTP calls - use your preferred HTTP client.

  ## Example

      # Build request components
      system_prompt = Conjure.API.build_system_prompt("You are helpful.", skills)
      tools = Conjure.API.build_tools_param(skills)

      # Make API call with your client
      response = MyApp.Claude.call(%{
        model: "claude-sonnet-4-5-20250929",
        system: system_prompt,
        messages: messages,
        tools: tools
      })

      # Parse response
      {:ok, parsed} = Conjure.API.parse_response(response)
  """

  alias Conjure.{Prompt, Skill, ToolCall, Tools}

  @type parsed_response :: %{
          text_blocks: [String.t()],
          tool_uses: [ToolCall.t()],
          stop_reason: String.t() | nil,
          usage: map() | nil
        }

  @doc """
  Build the system prompt with skills fragment appended.

  ## Options

  * `:include_instructions` - Include skill usage instructions (default: true)
  """
  @spec build_system_prompt(String.t(), [Skill.t()], keyword()) :: String.t()
  def build_system_prompt(base_prompt, skills, opts \\ []) do
    skills_fragment = Prompt.generate(skills, opts)

    """
    #{base_prompt}

    #{skills_fragment}
    """
    |> String.trim()
  end

  @doc """
  Build the tools array for the API request.

  ## Options

  * `:only` - Only include these tool names
  * `:except` - Exclude these tool names
  """
  @spec build_tools_param([Skill.t()], keyword()) :: [map()]
  def build_tools_param(_skills, opts \\ []) do
    Tools.definitions(opts)
  end

  @doc """
  Parse content blocks from an API response.

  Extracts text blocks, tool uses, and metadata from the response.
  """
  @spec parse_response(map()) :: {:ok, parsed_response()} | {:error, term()}
  def parse_response(%{"content" => content} = response) when is_list(content) do
    text_blocks =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])

    tool_uses = Tools.parse_tool_uses(content)

    parsed = %{
      text_blocks: text_blocks,
      tool_uses: tool_uses,
      stop_reason: Map.get(response, "stop_reason"),
      usage: Map.get(response, "usage")
    }

    {:ok, parsed}
  end

  def parse_response(%{"error" => error}) do
    {:error, {:api_error, error}}
  end

  def parse_response(response) do
    {:error, {:invalid_response, response}}
  end

  @doc """
  Format tool results for the next API request.

  Returns a message map with role "user" and tool_result content blocks.
  """
  @spec format_tool_results_message([Conjure.ToolResult.t()]) :: map()
  def format_tool_results_message(results) do
    Conjure.Conversation.format_tool_results_message(results)
  end

  @doc """
  Check if a response requires tool execution.
  """
  @spec requires_tool_execution?(map()) :: boolean()
  def requires_tool_execution?(%{"content" => content}) when is_list(content) do
    Enum.any?(content, &(&1["type"] == "tool_use"))
  end

  def requires_tool_execution?(_), do: false

  @doc """
  Check if the response is an end_turn (conversation complete).
  """
  @spec end_turn?(map()) :: boolean()
  def end_turn?(%{"stop_reason" => "end_turn"}), do: true
  def end_turn?(_), do: false

  @doc """
  Extract the full text content from a response.
  """
  @spec extract_text(map()) :: String.t()
  def extract_text(response) do
    Conjure.Conversation.extract_text(response)
  end

  @doc """
  Build a complete messages array for an API request.

  Handles the conversation history format expected by Claude.
  """
  @spec build_messages([map()]) :: [map()]
  def build_messages(history) do
    Enum.map(history, &normalize_message/1)
  end

  defp normalize_message(%{"role" => _, "content" => _} = msg), do: msg

  defp normalize_message(%{role: role, content: content}),
    do: %{"role" => role, "content" => content}

  defp normalize_message(msg), do: msg

  @doc """
  Estimate token count for a request.

  This is a rough estimate assuming ~4 characters per token.
  """
  @spec estimate_tokens(String.t() | map()) :: pos_integer()
  def estimate_tokens(content) when is_binary(content) do
    div(String.length(content), 4)
  end

  def estimate_tokens(%{} = request) do
    request
    |> Jason.encode!()
    |> String.length()
    |> div(4)
  end
end
