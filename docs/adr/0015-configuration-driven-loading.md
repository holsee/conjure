# ADR-0015: Configuration-driven skill loading

## Status

Proposed

## Context

The specification (section 13.1) defines application configuration options that are not fully implemented:

```elixir
# Specified but not wired up
config :conjure,
  skill_paths: ["/path/to/skills", "~/.conjure/skills"],
  executor: Conjure.Executor.Local,
  timeout: 30_000,
  max_iterations: 25,
  allow_network: false,
  allowed_paths: []
```

Currently, users must explicitly pass paths and options to every function call:

```elixir
# Current: explicit everywhere
{:ok, skills} = Conjure.load("/path/to/skills")
context = Conjure.create_context(skills, timeout: 60_000, allowed_paths: [...])
result = Conjure.execute(tool_call, skills, executor: Conjure.Executor.Docker)
```

This is verbose and error-prone. Configuration should provide sensible defaults while allowing runtime overrides.

## Decision

We will implement configuration-driven defaults with the following structure:

### 1. Configuration Schema

```elixir
# config/config.exs
config :conjure,
  # Paths to scan for skills on startup (supports ~ expansion)
  skill_paths: [],

  # Default executor module
  executor: Conjure.Executor.Local,

  # Executor-specific configuration
  executor_config: %{
    docker: %{
      image: "ghcr.io/holsee/conjure-sandbox:latest",
      memory_limit: "512m",
      cpu_limit: "1.0",
      network: :none
    }
  },

  # Execution defaults
  timeout: 30_000,
  max_iterations: 25,

  # Security defaults
  network_access: :none,
  allowed_paths: [],

  # Registry options
  auto_start_registry: true,
  registry_name: Conjure.Registry
```

### 2. Configuration Module

```elixir
defmodule Conjure.Config do
  @moduledoc """
  Configuration management for Conjure.

  Provides access to application configuration with runtime overrides.
  """

  @doc """
  Get a configuration value with optional default.
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) do
    Application.get_env(:conjure, key, default)
  end

  @doc """
  Get all skill paths, expanding ~ to home directory.
  """
  @spec skill_paths() :: [Path.t()]
  def skill_paths do
    get(:skill_paths, [])
    |> Enum.map(&expand_path/1)
    |> Enum.filter(&File.dir?/1)
  end

  @doc """
  Get the default executor module.
  """
  @spec executor() :: module()
  def executor, do: get(:executor, Conjure.Executor.Local)

  @doc """
  Get executor-specific configuration.
  """
  @spec executor_config(atom()) :: map()
  def executor_config(executor_type) do
    get(:executor_config, %{})
    |> Map.get(executor_type, %{})
  end

  @doc """
  Build an ExecutionContext from configuration with overrides.
  """
  @spec build_context(keyword()) :: ExecutionContext.t()
  def build_context(overrides \\ []) do
    %ExecutionContext{
      timeout: Keyword.get(overrides, :timeout, get(:timeout, 30_000)),
      network_access: Keyword.get(overrides, :network_access, get(:network_access, :none)),
      allowed_paths: Keyword.get(overrides, :allowed_paths, get(:allowed_paths, [])),
      # ... other fields
    }
  end

  defp expand_path(path) do
    path
    |> String.replace_leading("~", System.user_home() || "")
    |> Path.expand()
  end
end
```

### 3. Updated API with Defaults

```elixir
defmodule Conjure do
  alias Conjure.Config

  @doc """
  Load skills from configured paths or specified path.
  """
  def load(path \\ nil) do
    paths = if path, do: [path], else: Config.skill_paths()
    Loader.load_all(paths)
  end

  @doc """
  Execute with configured defaults.
  """
  def execute(tool_call, skills, opts \\ []) do
    executor = Keyword.get(opts, :executor, Config.executor())
    context = Keyword.get_lazy(opts, :context, fn -> Config.build_context(opts) end)

    do_execute(tool_call, skills, executor, context)
  end
end
```

### 4. Application Startup

When `auto_start_registry: true`, the application supervisor starts the registry and pre-loads skills:

```elixir
defmodule Conjure.Application do
  use Application

  def start(_type, _args) do
    children = build_children()

    opts = [strategy: :one_for_one, name: Conjure.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp build_children do
    if Conjure.Config.get(:auto_start_registry, true) do
      [{Conjure.Registry, name: Conjure.Config.get(:registry_name, Conjure.Registry),
                          paths: Conjure.Config.skill_paths()}]
    else
      []
    end
  end
end
```

### 5. Environment-Specific Configuration

```elixir
# config/dev.exs
config :conjure,
  executor: Conjure.Executor.Local,
  skill_paths: ["priv/skills", "~/.conjure/skills"]

# config/prod.exs
config :conjure,
  executor: Conjure.Executor.Docker,
  skill_paths: ["/opt/conjure/skills"],
  executor_config: %{
    docker: %{
      image: "ghcr.io/holsee/conjure-sandbox:0.1.0",
      memory_limit: "1g",
      network: :none
    }
  }

# config/test.exs
config :conjure,
  executor: Conjure.Executor.Local,
  skill_paths: ["test/fixtures/skills"],
  auto_start_registry: false
```

## Consequences

### Positive

- **Less boilerplate** - sensible defaults reduce code
- **Environment-aware** - different configs for dev/prod/test
- **Discoverable** - configuration options documented in one place
- **Override-friendly** - runtime options still take precedence
- **OTP-compliant** - follows standard Application config patterns

### Negative

- Configuration must be set before application start
- More "magic" - behavior depends on config file
- Testing requires config awareness

### Neutral

- Existing explicit API still works unchanged
- Configuration is optional—library works without it
- Runtime reconfiguration limited to restart

## Alternatives Considered

### No Configuration

Keep everything explicit. Rejected because:

- Too verbose for common use cases
- No sensible defaults
- Harder for new users

### Module Attributes

Use module attributes for defaults. Rejected because:

- Compile-time only
- Can't vary by environment
- Not standard Elixir pattern

### Environment Variables Only

Use OS environment variables. Rejected because:

- Less flexible than Elixir config
- Harder to document
- Poor fit for complex structures (executor_config)

## References

- [Elixir Application Configuration](https://hexdocs.pm/elixir/Application.html#module-application-environment)
- [Config and Releases](https://hexdocs.pm/elixir/Config.html)
- [Twelve-Factor App: Config](https://12factor.net/config)
