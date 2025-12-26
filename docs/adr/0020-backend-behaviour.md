# ADR-0020: Backend Behaviour Architecture

## Status

Accepted

## Context

After implementing the unified execution model (ADR-0019) with support for local, Docker, and Anthropic execution modes, we identified an asymmetry in the codebase:

- Local/Docker used `Conjure.Executor` behaviour + `Conjure.Conversation`
- Anthropic used `Conjure.Conversation.Anthropic` (different pattern)
- Session dispatched to different code paths based on execution mode

Additionally, we needed to support a new execution mode: **Native** - Elixir modules that implement a behaviour and execute directly in the BEAM, enabling type-safe, in-process skill execution with full access to application runtime context.

## Decision

We will introduce a formal `Conjure.Backend` behaviour that all execution backends implement, providing a clean, pluggable interface for different execution strategies.

### Backend Behaviour

```elixir
defmodule Conjure.Backend do
  @callback backend_type() :: atom()
  @callback new_session(skills :: term(), opts :: keyword()) :: Session.t()
  @callback chat(Session.t(), String.t(), api_callback(), keyword()) :: chat_result()
end
```

### Available Backends

| Backend | Module | Description | Execution |
|---------|--------|-------------|-----------|
| Local | `Conjure.Backend.Local` | Bash commands on host | `System.cmd` |
| Docker | `Conjure.Backend.Docker` | Bash in container | `docker exec` |
| Anthropic | `Conjure.Backend.Anthropic` | Hosted execution | Skills API |
| Native | `Conjure.Backend.Native` | Elixir modules | Direct calls |

### Native Skill Behaviour

For the Native backend, skills are implemented as Elixir modules:

```elixir
defmodule Conjure.NativeSkill do
  @callback __skill_info__() :: skill_info()
  @callback execute(String.t(), context()) :: result()
  @callback read(String.t(), context(), keyword()) :: result()
  @callback write(String.t(), String.t(), context()) :: result()
  @callback modify(String.t(), String.t(), String.t(), context()) :: result()

  @optional_callbacks [execute: 2, read: 3, write: 3, modify: 4]
end
```

### Tool Mapping

Native callbacks map to Claude's tool types:

| Claude Tool | Native Callback | Purpose |
|-------------|-----------------|---------|
| `bash_tool` | `execute/2` | Run commands/logic |
| `view` | `read/3` | Read resources |
| `create_file` | `write/3` | Create resources |
| `str_replace` | `modify/4` | Update resources |

## Consequences

### Positive

1. **Unified Interface**: All backends implement the same behaviour, making them interchangeable
2. **Type Safety**: Native skills benefit from compile-time checks and Elixir's type system
3. **No Shell Overhead**: Native execution has no subprocess/shell overhead
4. **Application Integration**: Native skills can directly access Ecto repos, caches, GenServers
5. **Pluggable Architecture**: Easy to add new backends (e.g., WASM, remote execution)
6. **Clean Separation**: Each backend encapsulates its own conversation loop logic

### Negative

1. **More Modules**: Added 6 new modules for the backend abstraction
2. **Slight Indirection**: Session now dispatches through backend modules
3. **Native Skill Learning Curve**: Developers need to learn the NativeSkill behaviour

### Neutral

1. **Existing Code Preserved**: Executor behaviour still works for Local/Docker
2. **Backwards Compatible**: Session API unchanged for existing users

## File Structure

```
lib/conjure/
├── backend.ex                    # Backend behaviour
├── backend/
│   ├── local.ex                  # Wraps Executor.Local
│   ├── docker.ex                 # Wraps Executor.Docker
│   ├── anthropic.ex              # Wraps Conversation.Anthropic
│   └── native.ex                 # Native execution
├── native_skill.ex               # Native skill behaviour
└── session.ex                    # Updated with new_native
```

## Usage Examples

### Native Backend

```elixir
defmodule MyApp.Skills.CacheManager do
  @behaviour Conjure.NativeSkill

  def __skill_info__ do
    %{
      name: "cache-manager",
      description: "Manage application cache",
      allowed_tools: [:execute, :read]
    }
  end

  def execute("clear", _ctx) do
    :ok = MyApp.Cache.clear()
    {:ok, "Cache cleared"}
  end

  def read("stats", _ctx, _opts) do
    {:ok, inspect(MyApp.Cache.stats())}
  end
end

# Usage
session = Conjure.Session.new_native([MyApp.Skills.CacheManager])
{:ok, response, session} = Conjure.Session.chat(session, "Clear the cache", &api_callback/1)
```

### Unified API Across Backends

```elixir
defmodule MyApp.Agent do
  def chat(message, backend_type, skills) do
    session = case backend_type do
      :local -> Conjure.Session.new_local(skills)
      :docker -> Conjure.Session.new_local(skills, executor: Conjure.Executor.Docker)
      :anthropic -> Conjure.Session.new_anthropic(skills)
      :native -> Conjure.Session.new_native(skills)
    end

    Conjure.Session.chat(session, message, &call_claude/1)
  end
end
```

## Related

- ADR-0019: Unified Execution Model
- ADR-0011: Anthropic Executor (Skills API)
