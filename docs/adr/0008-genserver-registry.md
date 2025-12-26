# ADR-0008: GenServer-based skill registry

## Status

Accepted

## Context

Applications using Conjure need to:

1. Load skills at startup
2. Access skills throughout the application lifecycle
3. Optionally reload skills at runtime (config changes, hot updates)
4. Share skills across processes efficiently

Two patterns are possible:

**Functional/Stateless**: Load skills, pass them explicitly everywhere
```elixir
{:ok, skills} = Conjure.load("/path")
Conjure.execute(tool_call, skills, opts)
```

**Stateful/GenServer**: Register skills once, access by name
```elixir
# At startup
{:ok, _} = Conjure.Registry.start_link(paths: ["/path"])

# Anywhere in application
skills = Conjure.Registry.list()
skill = Conjure.Registry.get("pdf")
```

OTP applications commonly use supervision trees with named processes for shared state.

## Decision

We will provide `Conjure.Registry` as an optional GenServer for stateful skill management.

The Registry:

1. Loads skills from configured paths at startup
2. Stores skills in process state (or ETS for concurrent access)
3. Provides lookup by name
4. Supports runtime reloading
5. Integrates with supervision trees

```elixir
defmodule Conjure.Registry do
  use GenServer

  # Client API
  def start_link(opts \\ [])
  def list(server \\ __MODULE__)
  def get(server \\ __MODULE__, name)
  def reload(server \\ __MODULE__)
  def register(server \\ __MODULE__, skills)

  # Also provide pure functional alternatives
  def index(skills)  # Create lookup map
  def find(index, name)  # Find in map
end
```

Usage in supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Conjure.Registry, name: MyApp.Skills, paths: ["/path/to/skills"]}
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

The functional API remains available for users who prefer explicit state:

```elixir
{:ok, skills} = Conjure.load("/path")
index = Conjure.Registry.index(skills)
skill = Conjure.Registry.find(index, "pdf")
```

## Consequences

### Positive

- OTP-compliant design fits Elixir ecosystem conventions
- Supervision ensures skills survive process crashes
- Named process enables global access without passing state
- Runtime reloading for dynamic environments
- ETS-backed storage enables concurrent reads without contention
- Clear separation: Registry for state, other modules for logic

### Negative

- Additional complexity for simple use cases
- Process naming can conflict in umbrella apps
- Global state makes testing slightly harder (must start/stop registry)
- Must handle registry not started errors

### Neutral

- GenServer is optional; functional API always available
- Multiple registries can coexist with different names
- Registry doesn't own execution (just stores skills)

## Implementation Details

### State Structure

```elixir
defmodule State do
  defstruct [
    :paths,
    :skills,
    :index,
    :ets_table
  ]
end
```

### ETS for Concurrent Access

For high-concurrency scenarios, skills are stored in ETS:

```elixir
def init(opts) do
  table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
  paths = Keyword.get(opts, :paths, [])

  {:ok, skills} = load_from_paths(paths)

  Enum.each(skills, fn skill ->
    :ets.insert(table, {skill.name, skill})
  end)

  {:ok, %State{paths: paths, skills: skills, ets_table: table}}
end

def handle_call({:get, name}, _from, state) do
  result = case :ets.lookup(state.ets_table, name) do
    [{^name, skill}] -> skill
    [] -> nil
  end
  {:reply, result, state}
end
```

### Reload Semantics

```elixir
def handle_call(:reload, _from, state) do
  case load_from_paths(state.paths) do
    {:ok, skills} ->
      :ets.delete_all_objects(state.ets_table)
      Enum.each(skills, &:ets.insert(state.ets_table, {&1.name, &1}))
      {:reply, :ok, %{state | skills: skills}}

    {:error, reason} ->
      # Keep old skills on reload failure
      {:reply, {:error, reason}, state}
  end
end
```

## Alternatives Considered

### Application environment only

Store skills in application env. Rejected because:

- Not process-safe for updates
- No lifecycle management
- Awkward for multiple skill sets

### Agent instead of GenServer

Simpler state wrapper. Rejected because:

- Less control over initialization
- No handle_info for future features (file watching)
- GenServer is standard for this pattern

### Persistent term storage

Use `:persistent_term` for near-zero lookup cost. Rejected because:

- Global mutable state is dangerous
- Expensive to update (copies entire term)
- Overkill for typical skill counts

### No registry (functional only)

Only provide functional loading. Rejected because:

- Forces users to solve state management
- Inconsistent with OTP conventions
- Makes runtime reload harder

## Testing Considerations

```elixir
# In tests, start registry in setup
setup do
  start_supervised!({Conjure.Registry, paths: ["test/fixtures/skills"]})
  :ok
end

# Or use functional API for isolation
test "loads skill" do
  {:ok, skills} = Conjure.load("test/fixtures/skills")
  assert length(skills) == 2
end
```

## References

- [Elixir GenServer documentation](https://hexdocs.pm/elixir/GenServer.html)
- [ETS documentation](https://www.erlang.org/doc/man/ets.html)
- [Registry (Elixir stdlib)](https://hexdocs.pm/elixir/Registry.html)
