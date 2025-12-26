# ADR-0002: Pluggable executor architecture via behaviours

## Status

Accepted

## Context

Conjure must execute tool calls (bash commands, file operations) in various environments:

1. **Local development**: Fast iteration, no isolation needed
2. **Production**: Strong isolation via containers
3. **Custom environments**: Firecracker microVMs, Kubernetes pods, remote VMs

> **Note:** Anthropic's Skills API provides an alternative hosted execution model, but it is NOT an executor implementation. See [ADR-0011](0011-anthropic-executor.md) for details on Skills API integration.

A single execution strategy cannot satisfy all use cases. Different deployments have different:

- Security requirements
- Performance characteristics
- Available infrastructure
- Compliance constraints

Elixir provides behaviours as a first-class abstraction for defining pluggable interfaces with compile-time guarantees.

## Decision

We will define a `Conjure.Executor` behaviour that all execution backends must implement.

```elixir
defmodule Conjure.Executor do
  @callback bash(command :: String.t(), context :: ExecutionContext.t()) :: result()
  @callback view(path :: Path.t(), context :: ExecutionContext.t(), opts :: keyword()) :: result()
  @callback create_file(path :: Path.t(), content :: String.t(), context :: ExecutionContext.t()) :: result()
  @callback str_replace(path :: Path.t(), old_str :: String.t(), new_str :: String.t(), context :: ExecutionContext.t()) :: result()
  @callback init(context :: ExecutionContext.t()) :: {:ok, ExecutionContext.t()} | {:error, term()}
  @callback cleanup(context :: ExecutionContext.t()) :: :ok

  @optional_callbacks [init: 1, cleanup: 1]
end
```

Executor selection is explicit at the call site:

```elixir
Conjure.execute(tool_call, skills, executor: Conjure.Executor.Docker)
```

We will provide two built-in executors:

1. `Conjure.Executor.Local` - Direct execution via `System.cmd`
2. `Conjure.Executor.Docker` - Container-isolated execution

> **Note:** Anthropic's Skills API (see [ADR-0011](0011-anthropic-executor.md)) provides hosted execution but uses a different integration pattern—it is not an executor implementation.

## Consequences

### Positive

- Users can implement custom executors for their infrastructure
- Behaviour provides compile-time contract verification
- Clear separation between execution strategy and business logic
- Easy to test with mock executors
- No runtime overhead from abstraction (direct function calls)

### Negative

- Users must explicitly choose an executor (no "smart" default)
- Each executor must implement all callbacks, even if some are no-ops
- Executor bugs can be hard to diagnose across abstraction boundary

### Neutral

- `init/1` and `cleanup/1` are optional for stateless executors
- Context is threaded through all calls for consistency

## Alternatives Considered

### Protocol-based dispatch

Using Elixir protocols would allow executor selection based on the execution context type. Rejected because:

- Protocols dispatch on data type, but executor choice is a deployment decision
- Would require wrapper structs for each executor
- Less explicit than module-based selection

### GenServer-based executors

Each executor could be a GenServer managing its own state. Rejected because:

- Adds process overhead for simple local execution
- Complicates the API with async patterns
- State management is better handled at the session level

### Configuration-only selection

Executor could be set globally via application config. Rejected because:

- Prevents per-request executor selection
- Makes testing harder
- Reduces flexibility for mixed environments

## References

- [Elixir Behaviours documentation](https://hexdocs.pm/elixir/behaviours.html)
- [Designing for Testability in Elixir](https://blog.appsignal.com/2023/04/11/testing-with-mocks-and-stubs-in-elixir.html)
