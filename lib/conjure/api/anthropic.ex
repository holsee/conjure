defmodule Conjure.API.Anthropic do
  @moduledoc """
  Helpers for building Anthropic Skills API requests.

  This module provides pure functions for constructing API parameters
  when using Anthropic's hosted Skills execution. It does NOT make
  HTTP calls - users provide their own HTTP client.

  ## Beta Requirements

  The Skills API requires beta headers. Use `beta_headers/0` to get
  the required headers for your HTTP client:

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ] ++ Conjure.API.Anthropic.beta_headers()

  ## Skill Types

  * `:anthropic` - Pre-built skills: `"xlsx"`, `"pptx"`, `"docx"`, `"pdf"`
  * `:custom` - User-uploaded skills with generated IDs

  ## Example

      # Build container config for skills
      {:ok, container} = Conjure.API.Anthropic.container_config([
        {:anthropic, "xlsx", "latest"},
        {:anthropic, "pptx", "latest"},
        {:custom, "skill_01AbCdEfGhIjKlMnOpQrStUv", "latest"}
      ])

      # Build complete request
      request = Conjure.API.Anthropic.build_request(
        messages,
        container,
        model: "claude-sonnet-4-5-20250929",
        max_tokens: 4096
      )

  ## References

  * [Anthropic Skills API Guide](https://platform.claude.com/docs/en/build-with-claude/skills-guide)
  """

  alias Conjure.Error

  @type skill_type :: :anthropic | :custom
  @type skill_spec :: {skill_type(), skill_id :: String.t(), version :: String.t()}

  @type parsed_response :: %{
          content: list(),
          stop_reason: String.t(),
          container_id: String.t() | nil,
          file_ids: [String.t()],
          usage: map() | nil
        }

  @max_skills 8

  @beta_headers [
    {"anthropic-beta", "code-execution-2025-08-25,skills-2025-10-02,files-api-2025-04-14"}
  ]

  @doc """
  Get the required beta headers for Skills API requests.

  These headers must be included in all API requests that use
  Skills or code execution features.

  ## Example

      headers = Conjure.API.Anthropic.beta_headers()
      # => [{"anthropic-beta", "code-execution-2025-08-25,skills-2025-10-02,files-api-2025-04-14"}]
  """
  @spec beta_headers() :: [{String.t(), String.t()}]
  def beta_headers, do: @beta_headers

  @doc """
  Get the code execution tool definition.

  This tool definition must be included in the `tools` array
  when making API requests with Skills.

  ## Example

      tools = [Conjure.API.Anthropic.code_execution_tool()]
  """
  @spec code_execution_tool() :: map()
  def code_execution_tool do
    %{
      "type" => "code_execution_20250825",
      "name" => "code_execution"
    }
  end

  @doc """
  Build the container configuration for skills.

  Accepts a list of skill specifications and returns the container
  parameter for the API request. Maximum 8 skills per request.

  ## Skill Specification Format

  Each skill is a tuple: `{type, skill_id, version}`

  * `type` - `:anthropic` for pre-built skills, `:custom` for uploaded
  * `skill_id` - Short name ("xlsx") or generated ID ("skill_01...")
  * `version` - Version string or "latest"

  ## Example

      {:ok, container} = Conjure.API.Anthropic.container_config([
        {:anthropic, "xlsx", "latest"},
        {:custom, "skill_01AbCdEfGhIjKlMnOpQrStUv", "v1"}
      ])

      # Returns:
      # %{
      #   "skills" => [
      #     %{"type" => "anthropic", "skill_id" => "xlsx", "version" => "latest"},
      #     %{"type" => "custom", "skill_id" => "skill_01...", "version" => "v1"}
      #   ]
      # }
  """
  @spec container_config([skill_spec()]) :: {:ok, map()} | {:error, Error.t()}
  def container_config(skills) when is_list(skills) do
    cond do
      length(skills) > @max_skills ->
        {:error, Error.skills_limit_exceeded(length(skills), @max_skills)}

      not Enum.all?(skills, &valid_skill_spec?/1) ->
        invalid = Enum.find(skills, &(not valid_skill_spec?(&1)))
        {:error, Error.invalid_skill_spec(invalid)}

      true ->
        skills_config = Enum.map(skills, &format_skill_spec/1)
        {:ok, %{"skills" => skills_config}}
    end
  end

  @doc """
  Build container config, raising on error.
  """
  @spec container_config!([skill_spec()]) :: map()
  def container_config!(skills) do
    case container_config(skills) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  @doc """
  Add a container ID to an existing container config.

  Use this for multi-turn conversations to reuse the same container.

  ## Example

      # First request - no container ID
      {:ok, container} = container_config([{:anthropic, "xlsx", "latest"}])

      # Parse container ID from response
      container_id = get_in(response, ["container", "id"])

      # Subsequent requests - reuse container
      container_with_id = with_container_id(container, container_id)
  """
  @spec with_container_id(map(), String.t()) :: map()
  def with_container_id(container_config, container_id) when is_binary(container_id) do
    Map.put(container_config, "id", container_id)
  end

  @doc """
  Build a complete messages API request body.

  Combines messages, container config, and options into a complete
  request body ready to be JSON-encoded.

  ## Options

  * `:model` - Model to use (default: "claude-sonnet-4-5-20250929")
  * `:max_tokens` - Maximum tokens in response (default: 4096)
  * `:system` - System prompt
  * `:tools` - Additional tools (code_execution is added automatically)
  * `:metadata` - Request metadata

  ## Example

      {:ok, container} = container_config([{:anthropic, "xlsx", "latest"}])

      request = build_request(
        [%{"role" => "user", "content" => "Create a spreadsheet"}],
        container,
        model: "claude-sonnet-4-5-20250929",
        max_tokens: 8192,
        system: "You are a helpful assistant."
      )
  """
  @spec build_request([map()], map(), keyword()) :: map()
  def build_request(messages, container_config, opts \\ []) do
    model = Keyword.get(opts, :model, "claude-sonnet-4-5-20250929")
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    request = %{
      "model" => model,
      "max_tokens" => max_tokens,
      "messages" => normalize_messages(messages),
      "tools" => build_tools(opts),
      "container" => container_config
    }

    request
    |> maybe_add(:system, opts)
    |> maybe_add(:metadata, opts)
  end

  @doc """
  Parse an API response, extracting relevant fields.

  Extracts content, stop_reason, container_id, file_ids, and usage
  from the response.

  ## Example

      {:ok, parsed} = parse_response(api_response)

      if pause_turn?(parsed) do
        # Continue conversation
      end

      file_ids = parsed.file_ids
  """
  @spec parse_response(map()) :: {:ok, parsed_response()} | {:error, term()}
  def parse_response(%{"content" => content, "stop_reason" => stop_reason} = response) do
    parsed = %{
      content: content,
      stop_reason: stop_reason,
      container_id: get_in(response, ["container", "id"]),
      file_ids: extract_file_ids(response),
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
  Check if response indicates a pause_turn (long-running operation).

  When true, the conversation should continue by sending the response
  content back to the API with the same container ID.

  ## Example

      {:ok, parsed} = parse_response(response)

      if pause_turn?(parsed) do
        # Long-running operation in progress, continue conversation
        updated_container = with_container_id(container, parsed.container_id)
        # ... continue loop
      end
  """
  @spec pause_turn?(map() | parsed_response()) :: boolean()
  def pause_turn?(%{stop_reason: "pause_turn"}), do: true
  def pause_turn?(%{"stop_reason" => "pause_turn"}), do: true
  def pause_turn?(_), do: false

  @doc """
  Check if response indicates end_turn (conversation complete).
  """
  @spec end_turn?(map() | parsed_response()) :: boolean()
  def end_turn?(%{stop_reason: "end_turn"}), do: true
  def end_turn?(%{"stop_reason" => "end_turn"}), do: true
  def end_turn?(_), do: false

  @doc """
  Extract file IDs from a response.

  Skills that create files (xlsx, pptx, pdf) include file references
  in the response content. These IDs can be used with the Files API
  to download the created documents.

  ## Example

      file_ids = extract_file_ids(response)
      # => ["file_01AbCdEf...", "file_02GhIjKl..."]

      Enum.each(file_ids, fn file_id ->
        {:ok, content, filename} = Conjure.Files.Anthropic.download(file_id, api_callback)
        File.write!(filename, content)
      end)
  """
  @spec extract_file_ids(map()) :: [String.t()]
  def extract_file_ids(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(&extract_file_ids_from_block/1)
    |> Enum.uniq()
  end

  def extract_file_ids(_), do: []

  @doc """
  Extract text content from a response.
  """
  @spec extract_text(map()) :: String.t()
  def extract_text(%{"content" => content}) when is_list(content) do
    texts = for %{"type" => "text", "text" => text} <- content, do: text
    Enum.join(texts, "\n")
  end

  def extract_text(_), do: ""

  @doc """
  Build the assistant message from a response for continuing conversation.

  Use this when handling pause_turn to build the next messages array.

  ## Example

      # Response came back with pause_turn
      assistant_message = build_assistant_message(response)
      updated_messages = messages ++ [assistant_message]
      # Continue with updated_messages
  """
  @spec build_assistant_message(map()) :: map()
  def build_assistant_message(%{"content" => content}) do
    %{"role" => "assistant", "content" => content}
  end

  # Private functions

  defp valid_skill_spec?({type, skill_id, version})
       when type in [:anthropic, :custom] and
              is_binary(skill_id) and
              is_binary(version) do
    true
  end

  defp valid_skill_spec?(_), do: false

  defp format_skill_spec({type, skill_id, version}) do
    %{
      "type" => Atom.to_string(type),
      "skill_id" => skill_id,
      "version" => version
    }
  end

  defp normalize_messages(messages) do
    Enum.map(messages, fn
      %{"role" => _, "content" => _} = msg -> msg
      %{role: role, content: content} -> %{"role" => to_string(role), "content" => content}
      msg -> msg
    end)
  end

  defp build_tools(opts) do
    additional_tools = Keyword.get(opts, :tools, [])
    [code_execution_tool() | additional_tools]
  end

  defp maybe_add(request, key, opts) do
    case Keyword.get(opts, key) do
      nil -> request
      value -> Map.put(request, to_string(key), value)
    end
  end

  defp extract_file_ids_from_block(%{"type" => "code_execution_result", "content" => content})
       when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "file", "file_id" => file_id} -> [file_id]
      _ -> []
    end)
  end

  defp extract_file_ids_from_block(_), do: []
end
