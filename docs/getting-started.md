# Getting Started with Conjure

Conjure is an Elixir library for building AI agents with Claude and specialized skills.

## Choose Your Path

| If you want to... | Start here |
|-------------------|------------|
| Get running quickly | [Hello World](tutorials/hello_world.md) |
| Build production skills | [Local Skills with Claude](tutorials/using_local_skills_via_claude_api.md) |
| Generate documents | [Anthropic Skills API](tutorials/using_claude_skill_with_elixir_host.md) |
| Use pure Elixir | [Native Elixir Skills](tutorials/using_elixir_native_skill.md) |
| Combine everything | [Unified Backend Patterns](tutorials/many_skill_backends_one_agent.md) |
| Build skill pipelines | [Fly.io with Tigris Storage](tutorials/hello_conjure_flyio.md) |

## Quick Overview

### What is Conjure?

Conjure enables Claude to use specialized skills - packaged instructions and tools that extend its capabilities. Skills can:

- Execute shell commands and scripts
- Read and write files
- Generate documents (spreadsheets, PDFs)
- Access your Elixir application directly

### Execution Backends

Conjure supports 4 execution backends with a unified Session API:

```elixir
# Local: Shell execution (development)
session = Conjure.Session.new_local(skills)

# Docker: Sandboxed execution (production)
session = Conjure.Session.new_local(skills, executor: Conjure.Executor.Docker)

# Anthropic: Hosted document generation
session = Conjure.Session.new_anthropic([{:anthropic, "xlsx", "latest"}])

# Native: Pure Elixir modules
session = Conjure.Session.new_native([MyApp.Skills.Database])

# Same API for all backends
{:ok, response, session} = Conjure.Session.chat(session, message, &api_callback/1)
```

### Storage Backends

Conjure supports pluggable storage for session working directories:

```elixir
# Local storage (default) - ephemeral temp directories
{:ok, session} = Conjure.Session.new_docker(skills)

# S3 storage - for multi-node clusters
{:ok, session} = Conjure.Session.new_docker(skills,
  storage: {Conjure.Storage.S3, bucket: "my-bucket"}
)

# Tigris storage - zero-config on Fly.io
{:ok, session} = Conjure.Session.new_docker(skills,
  storage: Conjure.Storage.Tigris
)

# File callbacks - integrate with your application
{:ok, session} = Conjure.Session.new_docker(skills,
  on_file_created: fn file_ref, session_id ->
    MyApp.Repo.insert!(%SessionFile{path: file_ref.path})
  end
)

# Cleanup when done
{:ok, _} = Conjure.Session.cleanup(session)
```

### API-Agnostic Design

Conjure makes no HTTP calls - you provide the API callback:

```elixir
api_callback = fn messages ->
  Req.post("https://api.anthropic.com/v1/messages",
    json: %{model: "claude-sonnet-4-5-20250929", messages: messages, ...},
    headers: [{"x-api-key", api_key}, ...]
  )
end
```

## Prerequisites

- **Elixir 1.14+** and **Erlang/OTP 25+**
- **Anthropic API key** from [console.anthropic.com](https://console.anthropic.com)
- **Docker 20.10+** (optional, for sandboxed execution)

## Installation

```elixir
# mix.exs
def deps do
  [{:conjure, "~> 0.1.0"}]
end
```

## Tutorials

Step-by-step guides for every use case:

1. **[Hello World](tutorials/hello_world.md)** (10 min)
   Install Conjure, create an Echo skill, run your first conversation

2. **[Local Skills with Claude](tutorials/using_local_skills_via_claude_api.md)** (30 min)
   Build a production log analyzer skill

3. **[Anthropic Skills API](tutorials/using_claude_skill_with_elixir_host.md)** (20 min)
   Generate spreadsheets and PDFs with hosted execution

4. **[Native Elixir Skills](tutorials/using_elixir_native_skill.md)** (25 min)
   Build type-safe skills as Elixir modules

5. **[Unified Backend Patterns](tutorials/many_skill_backends_one_agent.md)** (30 min)
   Combine all backends for a complete monitoring solution

6. **[Fly.io with Tigris Storage](tutorials/hello_conjure_flyio.md)** (35 min)
   Two-phase skill pipeline: Claude generates runbooks, Native executes safely

## Additional Resources

- **[README](../README.md)** - Full feature overview and API reference
- **[Technical Specification](../conjure_specification.md)** - Detailed architecture
- **[Architecture Decision Records](adr/README.md)** - Design rationale

## Getting Help

- **Issues**: [github.com/holsee/conjure/issues](https://github.com/holsee/conjure/issues)
- **API Reference**: Run `mix docs` locally
