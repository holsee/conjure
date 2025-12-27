# AGENTS.md

Guidance for LLM coding agents working on this repository.

## Project Overview

Conjure is an Elixir library for Anthropic Agent Skills with Claude models. It provides:

- **Unified Session API** - `Conjure.Session.chat/3` works across all backends
- **4 Execution Backends** - Local, Docker, Anthropic (hosted), Native (BEAM)
- **Skill Loading** - Parse SKILL.md files with YAML frontmatter, load `.skill` ZIP packages
- **Pluggable Storage** - Local, S3, Tigris backends for session file management
- **API-Agnostic** - No HTTP client bundled; consumers provide API callbacks

## Build & Development Commands

```bash
# Install dependencies
mix deps.get

# Run tests
mix test
mix test path/to/test.exs           # Specific file
mix test path/to/test.exs:42        # Specific line

# Code quality (all enforced in CI)
mix format                          # Auto-format
mix format --check-formatted        # Check formatting
mix credo --strict                  # Lint
mix dialyzer                        # Type checking
mix compile --warnings-as-errors    # Strict compilation

# Full CI check locally
mix format && mix credo --strict && mix compile --warnings-as-errors && mix test && mix dialyzer

# Generate documentation
mix docs
```

## Architecture

### Module Hierarchy

```
Conjure (Main API)
├── Session (Unified interface)
│   └── Backend (Behaviour)
│       ├── Local (System.cmd execution)
│       ├── Docker (Container execution)
│       ├── Anthropic (Skills API)
│       └── Native (BEAM execution)
├── Loader (SKILL.md parsing)
├── Registry (GenServer skill store)
├── Storage (Behaviour)
│   ├── Local (Temp directories)
│   ├── S3 (AWS)
│   └── Tigris (Fly.io)
└── NativeSkill (Behaviour for Elixir skills)
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `Conjure` | Main public API entry point |
| `Conjure.Session` | Unified session interface, delegates to backends |
| `Conjure.Backend` | Behaviour defining unified interface for all backends |
| `Conjure.NativeSkill` | Behaviour for implementing skills as Elixir modules |
| `Conjure.Storage` | Behaviour for session storage backends |
| `Conjure.Loader` | SKILL.md parsing, ZIP loading, progressive disclosure |
| `Conjure.Registry` | GenServer-based skill registry with hot-reload |
| `Conjure.Conversation` | Tool-use conversation loop (Local/Docker) |
| `Conjure.Prompt` | Generates XML-formatted system prompt fragments |
| `Conjure.Tools` | Claude-compatible tool schemas (view, bash_tool, create_file, str_replace) |

### Directory Structure

```
lib/conjure/
├── backend/        # Backend implementations (local, docker, anthropic, native)
├── executor/       # Low-level tool execution (bash, view, create_file, str_replace)
├── conversation/   # Conversation loops including Anthropic pause-turn handling
├── storage/        # Storage backends (local, s3, tigris)
├── api/            # API helpers including Anthropic-specific beta headers
└── files/          # File operations for Anthropic Skills API
```

## Design Patterns

### Behaviour-Based Architecture

All pluggable components use Elixir behaviours:

```elixir
# Backend behaviour - all execution modes implement this
@callback backend_type() :: atom()
@callback new_session(skills :: term(), opts :: keyword()) :: Session.t()
@callback chat(Session.t(), String.t(), api_callback(), keyword()) :: chat_result()

# Storage behaviour - all storage backends implement this
@callback init(session_id, opts :: keyword()) :: {:ok, state} | {:error, term()}
@callback write(state, path, content) :: {:ok, file_ref} | {:error, term()}
@callback local_path(state) :: {:ok, path} | {:error, :not_supported}

# NativeSkill behaviour - for Elixir-based skills
@callback __skill_info__() :: skill_info()
@callback execute(String.t(), context()) :: result()  # Maps to bash_tool
@callback read(String.t(), context(), keyword()) :: result()  # Maps to view
```

### API-Agnostic Design

Conjure never makes HTTP calls. Consumers provide a callback:

```elixir
# The callback receives messages and returns {:ok, response} | {:error, term()}
{:ok, response, session} = Conjure.Session.chat(session, message, fn messages ->
  # Consumer's HTTP client call here
  Req.post("https://api.anthropic.com/v1/messages", json: build_body(messages))
end)
```

### Progressive Disclosure

Skills load with metadata only by default to save tokens:

```elixir
{:ok, skills} = Conjure.load("/path")  # Metadata only
{:ok, skill_with_body} = Conjure.load_body(skill)  # Load body when needed
{:ok, content} = Conjure.read_resource(skill, "scripts/helper.py")  # Load resources on demand
```

### OTP Compliance

- `Conjure.Registry` is a GenServer with supervision
- All backends handle errors gracefully with `{:ok, _} | {:error, _}` tuples
- Storage cleanup is reliable even on crashes

## Code Style

### General Conventions

- Use descriptive function names over comments
- Prefer pipeline operator (`|>`) for data transformations
- Pattern match in function heads over conditionals when possible
- Use `with` for chains of operations that can fail
- Return tagged tuples: `{:ok, result}` or `{:error, reason}`

### Module Structure

```elixir
defmodule Conjure.Example do
  @moduledoc """
  One-line description.

  Detailed explanation of the module's purpose.
  """

  # Behaviour/use declarations
  @behaviour Conjure.SomeBehaviour
  use GenServer

  # Module attributes
  @default_timeout 30_000

  # Type definitions
  @type t :: %__MODULE__{field: term()}

  # Struct definition
  defstruct [:field]

  # Callbacks (grouped by behaviour)
  @impl true
  def init(args), do: {:ok, args}

  # Public API
  def public_function(arg), do: ...

  # Private helpers
  defp private_helper(arg), do: ...
end
```

### Error Handling

Use structured errors via `Conjure.Error`:

```elixir
# Define error types
{:error, %Conjure.Error{type: :file_not_found, message: "...", details: %{}}}

# Pattern match on error types
case result do
  {:ok, value} -> handle_success(value)
  {:error, %Conjure.Error{type: :file_not_found}} -> handle_not_found()
  {:error, %Conjure.Error{type: :permission_denied}} -> handle_denied()
end
```

## Testing

### Test Structure

Tests mirror the `lib/` structure:

```
test/
├── conjure_test.exs              # Main API tests
├── conjure/
│   ├── session_test.exs
│   ├── backend_test.exs
│   ├── backend/
│   │   ├── local_test.exs
│   │   ├── docker_test.exs
│   │   ├── anthropic_test.exs
│   │   └── native_test.exs
│   ├── storage_test.exs
│   ├── storage/
│   │   └── local_test.exs
│   └── ...
├── fixtures/                     # Test fixtures
│   └── skills/
└── support/                      # Test helpers
```

### Testing Patterns

```elixir
# Use describe blocks for grouping
describe "chat/3" do
  test "executes tool calls and returns response" do
    # Arrange
    session = setup_session()

    # Act
    {:ok, response, session} = Conjure.Session.chat(session, "message", &mock_callback/1)

    # Assert
    assert response["content"] == expected
  end
end

# Mock API callbacks for testing
defp mock_callback(messages) do
  {:ok, %{"content" => [%{"type" => "text", "text" => "response"}]}}
end
```

### External Dependencies

- Docker tests may be skipped if Docker unavailable
- Anthropic API tests use mocked responses
- S3/Tigris tests use mocked HTTP or local fixtures

## Important Considerations

### When Adding New Backends

1. Implement `Conjure.Backend` behaviour
2. Add to `Conjure.Session` constructor pattern match
3. Add corresponding tests in `test/conjure/backend/`
4. Document in `README.md` and relevant ADRs

### When Adding New Storage Backends

1. Implement `Conjure.Storage` behaviour
2. Ensure `local_path/1` returns valid path for Docker mounting
3. Handle cleanup reliably in `cleanup/1`
4. Add tests in `test/conjure/storage/`

### When Modifying Tool Schemas

Tools in `Conjure.Tools` must match Claude's expected format:
- `view` - Read file contents or directory listings
- `bash_tool` - Execute bash commands
- `create_file` - Create new files
- `str_replace` - Replace strings in files

### Security Considerations

- Local executor provides no sandboxing (use Docker in production)
- Validate paths are within allowed boundaries
- Skills can execute arbitrary code - audit before loading
- Docker network defaults to `:none`

## Key Documentation

| Document | Purpose |
|----------|---------|
| `README.md` | User documentation and quick start |
| `conjure_specification.md` | Full technical specification (18 sections) |
| `docs/adr/` | Architecture Decision Records (22 total) |
| `docs/tutorials/` | Step-by-step guides for each backend type |

### Relevant ADRs

- **ADR-0019**: Unified Execution Model
- **ADR-0020**: Backend Behaviour Architecture
- **ADR-0021**: Hybrid Multi-Backend Sessions
- **ADR-0022**: Pluggable Storage Strategy

## Skill File Format

```
my-skill/
├── SKILL.md              # Required - YAML frontmatter + markdown body
├── scripts/              # Optional - executable scripts
├── references/           # Optional - documentation
└── assets/               # Optional - binary files
```

SKILL.md structure:
```markdown
---
name: my-skill
description: What this skill does
license: MIT
compatibility: python3, nodejs
allowed-tools: Bash(python3:*) Read Write
---

# My Skill

Detailed instructions...
```

## Configuration

```elixir
# Application config
config :conjure,
  skill_paths: ["/path/to/skills"],
  executor: Conjure.Executor.Docker,
  timeout: 30_000

# Storage config (for production with Fly.io Tigris)
config :conjure, :storage,
  strategy: Conjure.Storage.Tigris
  # Credentials auto-injected by Fly.io

# Storage config (for AWS S3)
config :conjure, :storage,
  strategy: Conjure.Storage.S3,
  bucket: System.get_env("S3_BUCKET"),
  region: "us-east-1"
```
