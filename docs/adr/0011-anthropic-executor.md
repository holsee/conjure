# ADR-0011: Anthropic Skills API Integration

## Status

Proposed

## Context

> **Note:** This ADR replaces an earlier incorrect design that assumed a "pass-through executor" pattern. The original design was based on a misunderstanding of how Anthropic's code execution capabilities work. This revision accurately describes the actual Anthropic Skills API.

Anthropic provides a Skills API (beta) that allows:

1. **Uploading custom skills** to Anthropic's infrastructure
2. **Using pre-built Anthropic skills** (xlsx, pptx, docx, pdf)
3. **Executing skills in Anthropic-managed containers** with code execution

This provides an alternative to local/Docker execution for users who:

- Cannot run Docker in their environment
- Want Anthropic to manage sandbox security
- Need access to Anthropic's pre-built document skills
- Prefer hosted execution without local infrastructure

### How the Skills API Actually Works

```
1. Upload skill files → POST /v1/skills → receive skill_id
2. Include skill_id in container.skills parameter
3. Enable code_execution_20250825 tool in the request
4. Anthropic's container loads skills at /skills/{directory}/
5. Claude uses code execution to run code with skill files available
6. Download created files via Files API
```

### Key Differences from Original Design

| Original (Incorrect) | Actual API |
|---------------------|------------|
| Pass-through for bash commands | Skills uploaded first, get skill_id |
| `{:passthrough, config}` return | Uses `container.skills` parameter |
| Executor behaviour implementation | Not an executor—API integration helpers |
| Local skill files | Skills must be uploaded to Anthropic |

### Beta Requirements

The Skills API requires beta headers:

- `code-execution-2025-08-25` - Enables code execution
- `skills-2025-10-02` - Enables Skills API
- `files-api-2025-04-14` - For uploading/downloading files

### Skill Types

| Type | Description | ID Format |
|------|-------------|-----------|
| `anthropic` | Pre-built by Anthropic | Short names: `xlsx`, `pptx`, `docx`, `pdf` |
| `custom` | User-uploaded | Generated: `skill_01AbCdEfGhIjKlMnOpQrStUv` |

## Decision

We will provide **optional** Anthropic Skills API integration as helper modules, NOT as an executor implementation. This is fundamentally different from local/Docker execution because:

1. Conjure does NOT execute tools—Anthropic's container does
2. Skills must be uploaded to Anthropic first
3. The integration is at the API request level, not execution level

> **Note:** While this ADR describes the Anthropic-specific modules, [ADR-0019: Unified Execution Model](0019-unified-execution-model.md) describes how these modules are surfaced through a unified `Conjure.Session` API that provides identical interaction patterns for both local/Docker and Anthropic execution.

### Module Design

```elixir
defmodule Conjure.Skills.Anthropic do
  @moduledoc """
  Upload and manage skills via Anthropic Skills API.

  This module provides helpers for interacting with Anthropic's
  Skills API to upload custom skills and manage versions.

  Note: This is NOT an executor. Skills uploaded here are executed
  by Anthropic's infrastructure, not by Conjure.
  """

  @doc """
  Upload a skill directory to Anthropic.

  Returns the skill_id for use in API requests.

  ## Example

      {:ok, skill_id} = Conjure.Skills.Anthropic.upload(
        "priv/skills/csv-helper",
        display_title: "CSV Helper",
        api_key: System.get_env("ANTHROPIC_API_KEY")
      )

  """
  @spec upload(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def upload(skill_path, opts \\ [])

  @doc """
  List skills available in your Anthropic workspace.

  ## Options

    * `:source` - Filter by "anthropic" or "custom"
    * `:api_key` - Anthropic API key

  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ [])

  @doc """
  Delete a custom skill from Anthropic.

  Note: All versions must be deleted first.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(skill_id, opts \\ [])

  @doc """
  Create a new version of an existing skill.
  """
  @spec create_version(String.t(), Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_version(skill_id, skill_path, opts \\ [])
end
```

### API Request Helpers

```elixir
defmodule Conjure.API.Anthropic do
  @moduledoc """
  Helpers for building Anthropic API requests with Skills.
  """

  @doc """
  Build the container parameter for skills.

  ## Example

      container = Conjure.API.Anthropic.container_config([
        {:anthropic, "xlsx", "latest"},
        {:anthropic, "pptx", "latest"},
        {:custom, "skill_01AbCdEfGhIjKlMnOpQrStUv", "latest"}
      ])

      # Returns:
      # %{
      #   "skills" => [
      #     %{"type" => "anthropic", "skill_id" => "xlsx", "version" => "latest"},
      #     %{"type" => "anthropic", "skill_id" => "pptx", "version" => "latest"},
      #     %{"type" => "custom", "skill_id" => "skill_01...", "version" => "latest"}
      #   ]
      # }

  """
  @spec container_config([skill_spec()]) :: map()
  def container_config(skills)

  @type skill_spec ::
    {:anthropic, String.t(), String.t()} |
    {:custom, String.t(), String.t()}

  @doc """
  Get the required beta headers for Skills API.
  """
  @spec beta_headers() :: [{String.t(), String.t()}]
  def beta_headers do
    [
      {"anthropic-beta", "code-execution-2025-08-25,skills-2025-10-02,files-api-2025-04-14"}
    ]
  end

  @doc """
  Get the code execution tool definition.
  """
  @spec code_execution_tool() :: map()
  def code_execution_tool do
    %{
      "type" => "code_execution_20250825",
      "name" => "code_execution"
    }
  end
end
```

### Multi-Skill Support

The Skills API supports **up to 8 skills per request**. Skills can be combined for complex workflows (e.g., analyze data with Excel skill, create presentation with PowerPoint skill):

```elixir
container = Conjure.API.Anthropic.container_config([
  {:anthropic, "xlsx", "latest"},
  {:anthropic, "pptx", "latest"},
  {:anthropic, "pdf", "latest"},
  {:custom, "skill_01AbCdEfGhIjKlMnOpQrStUv", "latest"}
])
```

### Long-Running Operations

Skills may perform operations that require multiple turns. The API returns a `pause_turn` stop reason when an operation is paused, requiring the client to continue the conversation:

```elixir
defmodule Conjure.Conversation.Anthropic do
  @moduledoc """
  Conversation loop for Anthropic Skills API with pause_turn handling.
  """

  @doc """
  Run a conversation with Anthropic-hosted skills, handling pause_turn.

  Unlike local/Docker execution where Conjure manages tool execution,
  here Anthropic executes in their container. However, long-running
  operations still require a conversation loop to handle pause_turn.

  ## Options

    * `:max_retries` - Maximum pause_turn iterations (default: 10)
    * `:on_pause` - Callback when pause_turn received

  """
  @spec run(list(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(messages, container_config, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 10)
    do_run(messages, container_config, opts, 0, max_retries)
  end

  defp do_run(messages, container_config, opts, attempt, max_retries)
       when attempt < max_retries do
    case call_api(messages, container_config, opts) do
      {:ok, %{"stop_reason" => "pause_turn", "content" => content} = response} ->
        # Long-running operation paused - continue with same container
        container_id = get_in(response, ["container", "id"])
        updated_messages = messages ++ [%{role: "assistant", content: content}]
        updated_container = Map.put(container_config, "id", container_id)

        if callback = opts[:on_pause] do
          callback.(response, attempt + 1)
        end

        do_run(updated_messages, updated_container, opts, attempt + 1, max_retries)

      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run(_messages, _container, _opts, attempt, max_retries) do
    {:error, {:max_retries_exceeded, attempt, max_retries}}
  end
end
```

### Multi-Turn Conversations

Reuse the same container across multiple user messages by preserving the container ID:

```elixir
defmodule Conjure.Session.Anthropic do
  @moduledoc """
  Manage multi-turn sessions with Anthropic Skills API.
  """

  defstruct [:container_id, :skills, :messages]

  @doc """
  Start a new session with specified skills.
  """
  def new(skills) do
    %__MODULE__{
      container_id: nil,
      skills: skills,
      messages: []
    }
  end

  @doc """
  Send a message and get response, preserving container state.
  """
  def chat(session, user_message, opts \\ []) do
    messages = session.messages ++ [%{role: "user", content: user_message}]

    container_config = build_container(session)

    case Conjure.Conversation.Anthropic.run(messages, container_config, opts) do
      {:ok, response} ->
        updated_session = %{session |
          container_id: get_in(response, ["container", "id"]),
          messages: messages ++ [%{role: "assistant", content: response["content"]}]
        }
        {:ok, response, updated_session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_container(%{container_id: nil, skills: skills}) do
    Conjure.API.Anthropic.container_config(skills)
  end

  defp build_container(%{container_id: id, skills: skills}) do
    Conjure.API.Anthropic.container_config(skills)
    |> Map.put("id", id)
  end
end
```

### File Handling

Skills that create documents return `file_id` values. Use the Files API to download:

```elixir
defmodule Conjure.Files.Anthropic do
  @moduledoc """
  Download files created by Anthropic Skills.
  """

  @doc """
  Extract file IDs from a response.
  """
  @spec extract_file_ids(map()) :: [String.t()]
  def extract_file_ids(response)

  @doc """
  Download a file by ID.
  """
  @spec download(String.t(), keyword()) :: {:ok, binary(), String.t()} | {:error, term()}
  def download(file_id, opts \\ [])

  @doc """
  Get file metadata.
  """
  @spec metadata(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def metadata(file_id, opts \\ [])
end
```

### Usage Example

```elixir
defmodule MyApp.AnthropicSkillChat do
  @moduledoc """
  Example: Using Anthropic's hosted skills with full conversation support.
  """

  alias Conjure.Session.Anthropic, as: Session
  alias Conjure.Conversation.Anthropic, as: Conversation

  def chat_with_hosted_skills(user_message) do
    # Configure skills (up to 8)
    skills = [
      {:anthropic, "xlsx", "latest"},
      {:anthropic, "pptx", "latest"}
    ]

    # Start session
    session = Session.new(skills)

    # Chat with pause_turn handling for long-running operations
    case Session.chat(session, user_message, on_pause: &log_pause/2) do
      {:ok, response, updated_session} ->
        # Download any created files
        file_ids = Conjure.Files.Anthropic.extract_file_ids(response)
        files = Enum.map(file_ids, &download_file/1)

        {:ok, response, files, updated_session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_pause(response, attempt) do
    IO.puts("Operation paused (attempt #{attempt}), continuing...")
  end

  defp download_file(file_id) do
    {:ok, content, filename} = Conjure.Files.Anthropic.download(file_id)
    File.write!(filename, content)
    filename
  end
end
```

### Comparison: Local/Docker vs Anthropic Hosted

| Aspect | Local/Docker | Anthropic Hosted |
|--------|--------------|------------------|
| Who executes | Your application | Anthropic's container |
| Skill location | Local filesystem | Uploaded to Anthropic |
| Conversation loop | Tool call/result loop | pause_turn handling loop |
| Multi-turn state | Message history | Container ID + messages |
| Skills per request | Unlimited | Up to 8 |
| Network from sandbox | Configurable | Never (isolated) |
| Pre-built skills | N/A | xlsx, pptx, docx, pdf |
| File output | Local filesystem | Files API download |
| Cost | Your infrastructure | Anthropic API pricing |

## Consequences

### Positive

- **No local Docker required** - Anthropic manages containers
- **Pre-built document skills** - Access xlsx, pptx, docx, pdf without custom implementation
- **Multi-skill workflows** - Combine up to 8 skills per request
- **Long-running support** - pause_turn handling for complex operations
- **Persistent sessions** - Container ID reuse for multi-turn conversations
- **Anthropic-managed security** - Sandbox isolation handled by Anthropic
- **Consistent environment** - Same execution environment for all users
- **File output support** - Files API for downloading created documents

### Negative

- **Beta feature** - API may change, requires beta headers
- **Skills must be uploaded** - Cannot use local skill files directly
- **Network dependency** - Requires connectivity to Anthropic API
- **No network from container** - Skills cannot make external API calls
- **No runtime package installation** - Only pre-installed packages available
- **Upload size limit** - 8MB maximum per skill
- **Skills limit** - Maximum 8 skills per request
- **Conversation loop required** - Must handle pause_turn for long operations

### Neutral

- **Different architecture** - Not an executor, but API integration
- **Complementary to local** - Can use both approaches in same application
- **Version management** - Skills have versions, can pin for stability
- **Two loop types** - Local uses tool call/result loop, hosted uses pause_turn loop

## Alternatives Considered

### Executor Behaviour Implementation (Original Design)

The original ADR proposed implementing `Conjure.Executor.Anthropic` as a behaviour that returns `{:passthrough, config}`. This was rejected because:

- Based on incorrect understanding of the API
- Anthropic doesn't accept arbitrary bash commands
- Skills must be uploaded first, not passed through
- The conversation loop model doesn't apply—it's a single request

### Transparent Upload on Execute

Automatically upload skills when first used. Rejected because:

- Requires API key in executor context
- Upload is a separate concern from execution
- Better to make upload explicit for version control
- Skills have IDs that should be managed explicitly

### Skip Anthropic Integration Entirely

Only support local/Docker execution. Rejected because:

- Users may want hosted execution without Docker
- Pre-built document skills are valuable
- Anthropic's security expertise for sandboxing
- Useful for environments where Docker isn't available

## References

- [Anthropic Skills API Guide](https://platform.claude.com/docs/en/build-with-claude/skills-guide)
- [Code Execution Tool Documentation](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/code-execution-tool)
- [Files API Documentation](https://docs.anthropic.com/en/api/files-content)
- [ADR-0002: Pluggable Executor Architecture](0002-pluggable-executor-architecture.md)
- [ADR-0004: API-Client Agnostic Design](0004-api-client-agnostic-design.md)
- [ADR-0019: Unified Execution Model](0019-unified-execution-model.md)
