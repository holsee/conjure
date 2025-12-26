# ADR-0017: Skill caching and hot-reload

## Status

Proposed

## Context

Current skill loading behavior:

1. **Cold loading** - Skills are loaded from disk on every `Conjure.load/1` call
2. **No caching** - Full body and resources re-read each time
3. **No change detection** - Registry doesn't know when skills change
4. **Manual reload** - Users must call `Conjure.Registry.reload/1` explicitly

For production deployments with many skills or frequent access patterns, this creates:

- **Latency** - Disk I/O on every skill access
- **Inconsistency** - Skills may change during a conversation
- **Operational burden** - Must restart or manually reload after updates

The specification mentions caching as a potential enhancement but doesn't specify the approach.

## Decision

We will implement optional skill caching and hot-reload as separate, composable features:

### 1. Skill Caching

Add caching layer for loaded skills and resources:

```elixir
defmodule Conjure.Cache do
  @moduledoc """
  ETS-based cache for loaded skills and resources.
  """

  use GenServer

  @table :conjure_cache
  @default_ttl :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached skill or load and cache it.
  """
  @spec get_or_load(Path.t(), keyword()) :: {:ok, Skill.t()} | {:error, term()}
  def get_or_load(path, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)

    case lookup(path) do
      {:ok, skill, inserted_at} when not expired?(inserted_at, ttl) ->
        {:ok, skill}
      _ ->
        with {:ok, skill} <- Conjure.Loader.load_skill(path) do
          insert(path, skill)
          {:ok, skill}
        end
    end
  end

  @doc """
  Get a cached resource or load and cache it.
  """
  @spec get_or_load_resource(Skill.t(), Path.t()) :: {:ok, binary()} | {:error, term()}
  def get_or_load_resource(skill, resource_path)

  @doc """
  Invalidate cached skill(s).
  """
  @spec invalidate(Path.t() | :all) :: :ok
  def invalidate(path_or_all)

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      size: :ets.info(@table, :size),
      memory: :ets.info(@table, :memory),
      hits: get_counter(:hits),
      misses: get_counter(:misses)
    }
  end

  # GenServer implementation...
end
```

**Cache Configuration:**

```elixir
config :conjure,
  cache: [
    enabled: true,
    ttl: :timer.minutes(5),
    max_size: 100,  # Maximum cached skills
    max_memory: :timer.megabytes(50)  # Memory limit
  ]
```

### 2. Hot-Reload via File Watching

Optional file system watcher for automatic reload:

```elixir
defmodule Conjure.Watcher do
  @moduledoc """
  File system watcher for skill hot-reload.

  Watches configured skill paths and triggers reload when
  SKILL.md or resource files change.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    paths = Keyword.get(opts, :paths, Conjure.Config.skill_paths())

    {:ok, watcher_pid} = FileSystem.start_link(dirs: paths)
    FileSystem.subscribe(watcher_pid)

    {:ok, %{watcher: watcher_pid, paths: paths, debounce: %{}}}
  end

  @impl true
  def handle_info({:file_event, watcher, {path, events}}, state) do
    if skill_file?(path) and relevant_event?(events) do
      # Debounce rapid changes
      skill_path = find_skill_root(path)
      schedule_reload(skill_path, state)
    else
      {:noreply, state}
    end
  end

  defp skill_file?(path) do
    Path.basename(path) == "SKILL.md" or
    String.contains?(path, "/scripts/") or
    String.contains?(path, "/references/")
  end

  defp schedule_reload(skill_path, state) do
    # Cancel existing timer if any
    if timer = Map.get(state.debounce, skill_path) do
      Process.cancel_timer(timer)
    end

    # Schedule reload after debounce period
    timer = Process.send_after(self(), {:reload, skill_path}, 500)
    {:noreply, put_in(state.debounce[skill_path], timer)}
  end

  @impl true
  def handle_info({:reload, skill_path}, state) do
    Logger.info("Hot-reloading skill: #{skill_path}")

    # Invalidate cache
    Conjure.Cache.invalidate(skill_path)

    # Reload in registry if registered
    if Conjure.Registry.registered?(skill_path) do
      Conjure.Registry.reload_skill(skill_path)
    end

    # Emit telemetry
    :telemetry.execute(
      [:conjure, :skill, :reloaded],
      %{},
      %{path: skill_path}
    )

    {:noreply, Map.delete(state.debounce, skill_path)}
  end
end
```

**Watcher Configuration:**

```elixir
config :conjure,
  hot_reload: [
    enabled: true,  # false in production by default
    debounce_ms: 500,
    paths: []  # Additional paths beyond skill_paths
  ]
```

### 3. Registry Integration

Update Registry to work with cache and watcher:

```elixir
defmodule Conjure.Registry do
  # Existing code...

  @doc """
  Check if a skill path is registered.
  """
  @spec registered?(Path.t()) :: boolean()
  def registered?(path)

  @doc """
  Reload a specific skill by path.
  """
  @spec reload_skill(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def reload_skill(server \\ __MODULE__, path) do
    # Invalidate cache
    Conjure.Cache.invalidate(path)

    # Reload from disk
    case Conjure.Loader.load_skill(path) do
      {:ok, skill} ->
        GenServer.call(server, {:update_skill, skill})
      {:error, reason} ->
        Logger.warning("Failed to reload skill #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Subscribe to skill change notifications.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Registry.register(Conjure.PubSub, :skill_changes, [])
  end
end
```

### 4. Application Supervision Tree

```elixir
defmodule Conjure.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Always start cache if enabled
      cache_child_spec(),

      # Start watcher in dev/configured environments
      watcher_child_spec(),

      # Registry (existing)
      registry_child_spec(),

      # PubSub for notifications
      {Registry, keys: :duplicate, name: Conjure.PubSub}
    ]
    |> Enum.reject(&is_nil/1)

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp cache_child_spec do
    if Conjure.Config.get([:cache, :enabled], false) do
      {Conjure.Cache, Conjure.Config.get(:cache, [])}
    end
  end

  defp watcher_child_spec do
    if Conjure.Config.get([:hot_reload, :enabled], false) do
      {Conjure.Watcher, Conjure.Config.get(:hot_reload, [])}
    end
  end
end
```

### 5. Usage Examples

```elixir
# Production: caching enabled, hot-reload disabled
config :conjure,
  cache: [enabled: true, ttl: :timer.hours(1)],
  hot_reload: [enabled: false]

# Development: both enabled
config :conjure,
  cache: [enabled: true, ttl: :timer.seconds(30)],
  hot_reload: [enabled: true]

# Subscribe to changes in application code
Conjure.Registry.subscribe()
receive do
  {:skill_changed, skill_name} ->
    Logger.info("Skill #{skill_name} was updated")
end
```

## Consequences

### Positive

- **Improved performance** - Reduced disk I/O for frequently accessed skills
- **Developer experience** - Automatic reload during development
- **Observable** - Telemetry events for cache hits/misses and reloads
- **Configurable** - Fine-grained control over caching behavior
- **Composable** - Cache and watcher are independent features

### Negative

- **Memory usage** - Cached skills consume memory
- **Complexity** - More moving parts in the system
- **Dependencies** - FileSystem library for watching (optional)
- **Staleness risk** - Cached data may be stale if TTL too long

### Neutral

- **Optional features** - Both can be disabled entirely
- **ETS-based** - Uses proven Erlang technology
- **Debouncing** - Prevents reload storms during rapid edits

## Alternatives Considered

### Mnesia Instead of ETS

Use Mnesia for distributed caching. Rejected because:

- Over-engineering for single-node use case
- ETS is simpler and sufficient
- Can add distributed cache later if needed

### Polling Instead of Watching

Periodically check for file changes. Rejected because:

- Less responsive than inotify-based watching
- Wastes CPU cycles
- FileSystem library is well-maintained

### Always-On Caching

Make caching mandatory. Rejected because:

- Complicates testing
- Some deployments may prefer fresh reads
- Optional is more flexible

### In-Process Caching Only

Cache in Registry GenServer state. Rejected because:

- Would complicate Registry
- ETS provides better concurrent read access
- Separation of concerns

## References

- [ETS documentation](https://www.erlang.org/doc/man/ets.html)
- [FileSystem library](https://hexdocs.pm/file_system/)
- [ADR-0008: GenServer Registry](0008-genserver-registry.md)
- [Caching strategies in Elixir](https://elixirschool.com/en/lessons/storage/cachex)
