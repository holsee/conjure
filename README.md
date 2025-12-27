<p align="center">
  <img src="https://raw.githubusercontent.com/holsee/conjure/main/conjure.png" alt="Conjure Logo" width="200">
</p>

<p align="center">
  <a href="https://github.com/holsee/conjure/actions/workflows/ci.yml"><img src="https://github.com/holsee/conjure/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://hex.pm/packages/conjure"><img src="https://img.shields.io/hexpm/v/conjure.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/conjure"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="Documentation"></a>
  <a href="https://github.com/holsee/conjure/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License"></a>
</p>

# Conjure

An Elixir library for leveraging Anthropic Agent Skills in elixir with a configurable skill execution targets, native elixir skills and artefact storage targets.

Conjure provides a complete implementation of the Agent Skills specification with a **unified Session API** supporting multiple execution backends: local shell, Docker containers, Anthropic's hosted Skills API, and native Elixir modules.

## Documentation

- **[Getting Started](docs/getting-started.md)** - Quick overview and learning path
- **[Tutorials](docs/tutorials/README.md)** - Step-by-step guides:
  - [Hello World](docs/tutorials/hello_world.md) - First steps (10 min)
  - [Local Skills](docs/tutorials/using_local_skills_via_claude_api.md) - Build a log analyzer (30 min)
  - [Anthropic Skills API](docs/tutorials/using_claude_skill_with_elixir_host.md) - Document generation (20 min)
  - [Native Skills](docs/tutorials/using_elixir_native_skill.md) - Pure Elixir skills (25 min)
  - [Unified Backends](docs/tutorials/many_skill_backends_one_agent.md) - Combine all backends (30 min)
- **[Technical Specification](conjure_specification.md)** - Complete API specification
- **[Architecture Decision Records](docs/adr/README.md)** - Design decisions:
  - [ADR-0019: Unified Execution Model](docs/adr/0019-unified-execution-model.md)
  - [ADR-0020: Backend Behaviour Architecture](docs/adr/0020-backend-behaviour.md)

## Features

- **Unified Session API** - Same `chat/3` interface across all execution backends
- **4 Execution Backends** - Local, Docker, Anthropic Skills API, and Native Elixir
- **Skill Loading** - Parse SKILL.md files with YAML frontmatter, load `.skill` packages (ZIP format)
- **Progressive Disclosure** - Efficient token usage with metadata → body → resources loading
- **System Prompt Generation** - Generate XML-formatted skill discovery prompts
- **Tool Definitions** - Claude-compatible tool schemas (view, bash, create_file, str_replace)
- **API-Agnostic** - No HTTP client bundled; you provide the API callback
- **Native Skills** - Implement skills as type-safe Elixir modules
- **OTP Compliant** - GenServer registry, supervision trees, fault tolerance

## Installation

Add `conjure` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:conjure, "~> 0.1.0-alpha"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Quick Start

### Using the Session API

The Session API provides a unified interface for all execution backends:

```elixir
# Load skills from disk
{:ok, skills} = Conjure.load("/path/to/skills")

# Create a session with local execution
session = Conjure.Session.new_local(skills)

# Chat with Claude (you provide the API callback)
{:ok, response, session} = Conjure.Session.chat(
  session,
  "Create a Python script that calculates fibonacci numbers",
  &my_api_callback/1
)

# Continue the conversation (session tracks state)
{:ok, response, session} = Conjure.Session.chat(
  session,
  "Now add memoization to optimize it",
  &my_api_callback/1
)
```

### API Callback

Conjure is API-agnostic - you provide the callback that makes HTTP calls:

```elixir
defmodule MyApp.Claude do
  def api_callback(messages) do
    body = %{
      model: "claude-sonnet-4-5-20250929",
      max_tokens: 4096,
      system: build_system_prompt(),
      messages: messages,
      tools: Conjure.tool_definitions()
    }

    case Req.post("https://api.anthropic.com/v1/messages", json: body, headers: headers()) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Execution Backends

Conjure supports 4 execution backends through the `Conjure.Backend` behaviour:

| Backend | Description | Use Case |
|---------|-------------|----------|
| **Local** | Direct shell execution on host | Development, trusted environments |
| **Docker** | Containerized sandbox execution | Production, untrusted code |
| **Anthropic** | Anthropic's hosted Skills API | Document generation (xlsx, pdf, pptx) |
| **Native** | Elixir modules in BEAM | Type-safe, in-process execution |

### Local Backend

Default backend for development. Skills execute bash commands directly on the host.

```elixir
{:ok, skills} = Conjure.load("/path/to/skills")
session = Conjure.Session.new_local(skills)
```

### Docker Backend

Sandboxed execution in Docker containers. Recommended for production.

```elixir
# Build the sandbox image first
Conjure.Executor.Docker.build_image()

# Create session with Docker executor
session = Conjure.Session.new_local(skills,
  executor: Conjure.Executor.Docker,
  executor_config: %{
    image: "conjure/sandbox:latest",
    memory_limit: "512m",
    cpu_limit: "1.0",
    network: :none
  }
)

{:ok, response, session} = Conjure.Session.chat(session, message, &api_callback/1)
```

### Anthropic Backend

Use Anthropic's hosted Skills API for document generation skills (xlsx, pdf, pptx, docx).

```elixir
# Specify Anthropic-hosted skills
session = Conjure.Session.new_anthropic([
  {:anthropic, "xlsx", "latest"},
  {:anthropic, "pdf", "latest"}
])

# The API callback must include beta headers
{:ok, response, session} = Conjure.Session.chat(
  session,
  "Create a budget spreadsheet with monthly expenses",
  &anthropic_api_callback/1
)

# Access created files
files = Conjure.Session.get_created_files(session)
# => [%{id: "file_01...", source: :anthropic, ...}]
```

See [Anthropic Skills API](#anthropic-skills-api) section for details.

### Native Backend

Execute skills as compiled Elixir modules with direct BEAM access.

```elixir
# Define a native skill module
defmodule MyApp.Skills.Database do
  @behaviour Conjure.NativeSkill

  @impl true
  def __skill_info__ do
    %{
      name: "database",
      description: "Query the application database",
      allowed_tools: [:execute, :read]
    }
  end

  @impl true
  def execute(query, _context) do
    case MyApp.Repo.query(query) do
      {:ok, result} -> {:ok, format_result(result)}
      {:error, err} -> {:error, inspect(err)}
    end
  end

  @impl true
  def read(table, _context, _opts) do
    {:ok, get_table_schema(table)}
  end
end

# Create session with native skills
session = Conjure.Session.new_native([MyApp.Skills.Database])

{:ok, response, session} = Conjure.Session.chat(
  session,
  "What tables do we have?",
  &api_callback/1
)
```

## Native Skills

Native skills are Elixir modules that implement the `Conjure.NativeSkill` behaviour. They execute directly in the BEAM with full access to your application's runtime context.

### Behaviour Callbacks

| Callback | Maps To | Purpose |
|----------|---------|---------|
| `execute/2` | `bash_tool` | Run commands/logic |
| `read/3` | `view` | Read resources |
| `write/3` | `create_file` | Create resources |
| `modify/4` | `str_replace` | Update resources |

### Example: Cache Manager

```elixir
defmodule MyApp.Skills.CacheManager do
  @behaviour Conjure.NativeSkill

  @impl true
  def __skill_info__ do
    %{
      name: "cache-manager",
      description: "Manage application cache (clear, stats, list keys)",
      allowed_tools: [:execute, :read]
    }
  end

  @impl true
  def execute("clear", _context) do
    Cachex.clear(:my_cache)
    {:ok, "Cache cleared successfully"}
  end

  def execute("stats", _context) do
    {:ok, stats} = Cachex.stats(:my_cache)
    {:ok, inspect(stats, pretty: true)}
  end

  @impl true
  def read("keys", _context, _opts) do
    {:ok, keys} = Cachex.keys(:my_cache)
    {:ok, Enum.join(keys, "\n")}
  end
end
```

### Advantages Over Local Backend

- No subprocess/shell overhead
- Type-safe with compile-time checks
- Direct access to application state (Ecto repos, caches, GenServers)
- Better error handling with pattern matching

## Anthropic Skills API

For document generation (xlsx, pdf, pptx, docx), use Anthropic's hosted Skills API.

### Beta Headers

The Skills API requires beta headers:

```elixir
def anthropic_headers do
  [
    {"x-api-key", api_key()},
    {"anthropic-version", "2023-06-01"}
  ] ++ Conjure.API.Anthropic.beta_headers()
end
```

### Container Reuse

Sessions automatically track container IDs for multi-turn conversations:

```elixir
session = Conjure.Session.new_anthropic([{:anthropic, "xlsx", "latest"}])

# First turn - creates container
{:ok, _, session} = Conjure.Session.chat(session, "Create a spreadsheet", &callback/1)

# Subsequent turns reuse the same container
{:ok, _, session} = Conjure.Session.chat(session, "Add a chart", &callback/1)
```

### File Downloads

Files created during Anthropic execution can be downloaded:

```elixir
files = Conjure.Session.get_created_files(session)

for %{id: file_id, source: :anthropic} <- files do
  {:ok, content, filename} = Conjure.Files.Anthropic.download(file_id, &files_api_callback/1)
  File.write!(filename, content)
end
```

### Skill Types

- `:anthropic` - Pre-built skills: `"xlsx"`, `"pptx"`, `"docx"`, `"pdf"`
- `:custom` - User-uploaded skills with generated IDs

## Usage Examples

### Multi-Turn Conversation

```elixir
defmodule MyApp.Agent do
  def run(initial_message) do
    {:ok, skills} = Conjure.load("priv/skills")
    session = Conjure.Session.new_local(skills)

    conversation_loop(session, initial_message)
  end

  defp conversation_loop(session, message) do
    case Conjure.Session.chat(session, message, &api_callback/1) do
      {:ok, response, session} ->
        IO.puts(extract_text(response))

        case IO.gets("You: ") do
          :eof -> :ok
          input -> conversation_loop(session, String.trim(input))
        end

      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
    end
  end
end
```

### Unified Backend Selection

```elixir
defmodule MyApp.Agent do
  def chat(message, backend_type, skills) do
    session = case backend_type do
      :local -> Conjure.Session.new_local(skills)
      :docker -> Conjure.Session.new_local(skills, executor: Conjure.Executor.Docker)
      :anthropic -> Conjure.Session.new_anthropic(skills)
      :native -> Conjure.Session.new_native(skills)
    end

    # Same API regardless of backend
    Conjure.Session.chat(session, message, &api_callback/1)
  end
end
```

### GenServer Registry

```elixir
# In your application supervisor
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Conjure.Registry, name: MyApp.Skills, paths: ["/path/to/skills"]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

# Later in your application
skills = Conjure.Registry.list(MyApp.Skills)
pdf_skill = Conjure.Registry.get(MyApp.Skills, "pdf")

# Reload skills at runtime
Conjure.Registry.reload(MyApp.Skills)
```

### Low-Level Conversation API

For more control, use the conversation loop directly:

```elixir
{:ok, skills} = Conjure.load("/path/to/skills")

system_prompt = """
You are a helpful assistant.

#{Conjure.system_prompt(skills)}
"""

tools = Conjure.tool_definitions()
messages = [%{role: "user", content: "Create a Python script"}]

Conjure.Conversation.run_loop(
  messages,
  skills,
  &call_claude(&1, system_prompt, tools),
  max_iterations: 15
)
```

## Progressive Disclosure

Skills are loaded with metadata only by default for token efficiency:

```elixir
# Initial load - metadata only
{:ok, skills} = Conjure.load("/path/to/skills")

# Load full body when needed
{:ok, skill_with_body} = Conjure.load_body(skill)

# Read a specific resource
{:ok, content} = Conjure.read_resource(skill, "scripts/helper.py")
```

## Skill Format

Skills follow the Anthropic Agent Skills specification:

```
my-skill/
├── SKILL.md           # Required - skill definition
├── scripts/           # Optional - executable scripts
│   └── helper.py
├── references/        # Optional - reference documentation
│   └── api_docs.md
└── assets/            # Optional - binary assets
    └── template.xlsx
```

### SKILL.md Format

```yaml
---
name: my-skill
description: A comprehensive description of what this skill does and when to use it.
license: MIT
compatibility:
  products: [claude.ai, claude-code, api]
  packages: [python3, nodejs]
allowed_tools: [bash, view, create_file]
---

# My Skill

Detailed instructions for using this skill...
```

### .skill Package Format

A `.skill` file is a ZIP archive containing the skill directory:

```bash
# Create a .skill package
zip -r my-skill.skill my-skill/

# Conjure can load it directly
{:ok, skill} = Conjure.load_skill_file("my-skill.skill")
```

## Tool Definitions

Conjure provides these tools for Claude:

| Tool | Description |
|------|-------------|
| `view` | Read file contents or directory listings |
| `bash_tool` | Execute bash commands |
| `create_file` | Create new files with content |
| `str_replace` | Replace strings in files |

## Custom Executor

Implement the `Conjure.Executor` behaviour to create custom execution backends:

```elixir
defmodule MyApp.FirecrackerExecutor do
  @behaviour Conjure.Executor

  @impl true
  def init(context), do: {:ok, context}

  @impl true
  def bash(command, context) do
    # Execute in Firecracker microVM
    {:ok, output}
  end

  @impl true
  def view(path, context, opts), do: {:ok, content}

  @impl true
  def create_file(path, content, context), do: {:ok, "File created"}

  @impl true
  def str_replace(path, old_str, new_str, context), do: {:ok, "File updated"}

  @impl true
  def cleanup(context), do: :ok
end

# Use your custom executor
session = Conjure.Session.new_local(skills, executor: MyApp.FirecrackerExecutor)
```

## Security

### Recommendations

1. **Use Docker executor in production** - Local executor provides no sandboxing
2. **Audit skills before loading** - Review SKILL.md and bundled scripts
3. **Restrict network access** - Default to `:none`, use allowlists for `:limited`
4. **Set resource limits** - Configure memory, CPU, and timeout limits
5. **Use read-only skill mounts** - Skills directory mounted as read-only in Docker
6. **Separate working directories** - Use per-session working directories

### Path Validation

```elixir
# Conjure validates paths are within allowed boundaries
context = Conjure.create_context(skills,
  allowed_paths: ["/tmp/conjure", "/home/user/projects"]
)
```

## Requirements

- Elixir 1.14+
- Erlang/OTP 25+
- Docker 20.10+ (for Docker executor)

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Links

- [Anthropic Agent Skills Specification](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview)
- [Claude API Documentation](https://docs.anthropic.com/en/api)
- [Anthropic Skills API Guide](https://platform.claude.com/docs/en/build-with-claude/skills-guide)
