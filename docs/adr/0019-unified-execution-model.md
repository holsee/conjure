# ADR-0019: Unified Execution Model

## Status

Proposed

## Context

Conjure supports two fundamentally different execution modes:

1. **Local/Docker execution** - Conjure executes tools in the user's environment
2. **Anthropic execution** - Anthropic executes skills in their managed containers (see ADR-0011)

Initially, these were designed as separate APIs with different modules:
- Local: `Conjure.Conversation.run_loop/4` with `Conjure.Executor` behaviours
- Anthropic: `Conjure.Session.Anthropic` and `Conjure.Conversation.Anthropic`

This creates a fragmented developer experience where switching execution modes requires significant code changes.

### Key Differences Between Modes

| Aspect | Local/Docker | Anthropic Hosted |
|--------|--------------|------------------|
| Who executes | Your application | Anthropic's container |
| Conversation loop | tool_use → execute → tool_result | pause_turn continuation |
| Skills source | Local filesystem | Uploaded to Anthropic |
| Multi-turn state | Message history | Container ID + messages |
| File output | Local filesystem | Files API download |

Despite these differences, users want the **same interaction patterns** regardless of execution backend.

### Reference

- [Anthropic Skills API Guide](https://platform.claude.com/docs/en/build-with-claude/skills-guide)

## Decision

We will provide a **unified execution model** where the same API works for both local/Docker and Anthropic execution. Users can switch execution modes with minimal code changes while getting identical interaction patterns.

### Unified Session API

```elixir
defmodule Conjure.Session do
  @moduledoc """
  Manage multi-turn conversation sessions.

  Works with both local/Docker and Anthropic execution modes.
  """

  defstruct [
    :execution_mode,    # :local | :docker | :anthropic
    :skills,            # Local skills or Anthropic skill specs
    :messages,
    :container_id,      # For Anthropic container reuse
    :created_files,
    :context,           # ExecutionContext for local
    :opts
  ]

  @type t :: %__MODULE__{}

  @doc """
  Create session for local/Docker execution.
  """
  @spec new_local(skills :: [Skill.t()], keyword()) :: t()
  def new_local(skills, opts \\ [])

  @doc """
  Create session for Anthropic execution.
  """
  @spec new_anthropic(skill_specs :: [skill_spec()], keyword()) :: t()
  def new_anthropic(skill_specs, opts \\ [])

  @doc """
  Send a message and get response.

  Works identically for both execution modes.
  The api_callback is passed per-call, following API-agnostic design.
  """
  @spec chat(t(), String.t(), api_callback()) ::
    {:ok, response :: map(), updated_session :: t()} | {:error, term()}
  def chat(session, user_message, api_callback)

  @doc """
  Get files created during the session.

  Returns unified file info regardless of execution mode.
  """
  @spec get_created_files(t()) :: [file_info()]
  def get_created_files(session)
end
```

### Unified Result Types

```elixir
@type conversation_result :: %{
  messages: [message()],
  final_response: map(),
  created_files: [file_info()],
  iterations: pos_integer(),
  execution_mode: :local | :docker | :anthropic
}

@type file_info :: %{
  id: String.t(),           # file_id for Anthropic, path for local
  filename: String.t(),
  size: pos_integer(),
  source: :local | :anthropic
}
```

### API Callback Pattern

All functions accept callbacks for HTTP operations, following the library's API-agnostic design (ADR-0004):

```elixir
# Same callback works for both modes
api_callback = fn messages ->
  MyApp.Claude.call(messages)
end

# Local execution
session = Conjure.Session.new_local(skills, executor: Conjure.Executor.Docker)
{:ok, response, session} = Conjure.Session.chat(session, "Analyze this data", api_callback)

# Anthropic execution - same API!
session = Conjure.Session.new_anthropic([{:anthropic, "xlsx", "latest"}])
{:ok, response, session} = Conjure.Session.chat(session, "Analyze this data", api_callback)
```

### Internal Loop Abstraction

The unified API handles the different conversation loop types internally:

```elixir
# Local/Docker: tool_use → execute → tool_result loop
defp handle_local_conversation(session, messages, api_callback) do
  # Uses existing Conjure.Conversation.run_loop/4
  Conjure.Conversation.run_loop(
    messages,
    session.skills,
    api_callback,
    executor: get_executor(session)
  )
end

# Anthropic: pause_turn continuation loop
defp handle_anthropic_conversation(session, messages, api_callback) do
  # Uses Conjure.Conversation.Anthropic.run/4
  Conjure.Conversation.Anthropic.run(
    messages,
    build_container_config(session),
    api_callback,
    max_iterations: session.opts[:max_pause_iterations] || 10
  )
end
```

### Module Organization

```
lib/conjure/
├── session.ex                    # Unified session (NEW)
├── api/
│   └── anthropic.ex              # API request helpers (ADR-0011)
├── conversation/
│   ├── conversation.ex           # Local loop (existing)
│   └── anthropic.ex              # Anthropic pause_turn loop (ADR-0011)
├── skills/
│   └── anthropic.ex              # Skill upload/management (ADR-0011)
├── files/
│   └── anthropic.ex              # File downloads (ADR-0011)
└── error.ex                      # Extended with new types
```

### Usage Example

```elixir
defmodule MyApp.Chat do
  @moduledoc """
  Unified chat interface - same code works for any backend.
  """

  alias Conjure.Session

  # Configuration determines execution mode
  def chat(user_message, opts \\ []) do
    session = create_session(opts)
    Session.chat(session, user_message, &call_claude/1)
  end

  defp create_session(opts) do
    case Keyword.get(opts, :execution, :local) do
      :local ->
        {:ok, skills} = Conjure.load("priv/skills")
        Session.new_local(skills, executor: Conjure.Executor.Local)

      :docker ->
        {:ok, skills} = Conjure.load("priv/skills")
        Session.new_local(skills, executor: Conjure.Executor.Docker)

      :anthropic ->
        Session.new_anthropic([
          {:anthropic, "xlsx", "latest"},
          {:anthropic, "pdf", "latest"}
        ])
    end
  end

  # Same callback for all modes
  defp call_claude(messages) do
    MyApp.Claude.post("/v1/messages", %{
      model: "claude-sonnet-4-5-20250929",
      max_tokens: 4096,
      messages: messages
    })
  end
end
```

### File Handling

Created files are tracked uniformly with source information:

```elixir
# After conversation
files = Session.get_created_files(session)

# Download based on source
Enum.each(files, fn file_info ->
  case file_info.source do
    :local ->
      # Already a local path
      File.read!(file_info.id)

    :anthropic ->
      # Download via Files API
      {:ok, content, _} = Conjure.Files.Anthropic.download(
        file_info.id,
        &api_callback/4
      )
      content
  end
end)
```

## Consequences

### Positive

- **Single API to learn** - Users learn one interface for all execution modes
- **Easy mode switching** - Change execution backend with configuration, not code rewrites
- **Consistent patterns** - Same callback style, session management, file handling
- **Reduced cognitive load** - No need to understand internal loop differences
- **Future-proof** - New execution backends can be added behind the same API

### Negative

- **Abstraction overhead** - Some mode-specific features may be harder to access
- **Lowest common denominator** - API limited to features available in all modes
- **Internal complexity** - Unified module must handle different loop types

### Neutral

- **Mode-specific modules still exist** - `Conjure.Conversation.Anthropic` etc. are still available for advanced use
- **Configuration-driven** - Execution mode determined at session creation
- **Source tracking** - File results include source for mode-specific handling when needed

## Alternatives Considered

### Separate APIs per Execution Mode

Keep `Conjure.Session.Anthropic` and local execution completely separate. Rejected because:

- Requires significant code changes to switch modes
- Users must learn multiple APIs
- Duplicated patterns and documentation

### Execution Mode as Runtime Parameter

Pass execution mode to each `chat/3` call instead of at session creation. Rejected because:

- Inconsistent state if mode changes mid-session
- More complex API surface
- Session state depends on execution mode

### Wrapper Module Only

Create a thin wrapper that delegates to mode-specific modules. Rejected because:

- Still exposes mode differences in return types
- File handling would remain inconsistent
- Less robust abstraction

## References

- [ADR-0002: Pluggable Executor Architecture](0002-pluggable-executor-architecture.md)
- [ADR-0004: API-Client Agnostic Design](0004-api-client-agnostic-design.md)
- [ADR-0011: Anthropic Skills API Integration](0011-anthropic-executor.md)
- [Anthropic Skills API Guide](https://platform.claude.com/docs/en/build-with-claude/skills-guide)
