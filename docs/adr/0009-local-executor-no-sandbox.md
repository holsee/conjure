# ADR-0009: Local executor without sandboxing

## Status

Accepted

## Context

Conjure must execute commands and file operations from skill instructions. The simplest implementation uses Elixir's `System.cmd/3` to run commands directly on the host:

```elixir
System.cmd("bash", ["-c", command], opts)
```

This provides no isolation between skill execution and the host system. A malicious or buggy skill could:

- Read/write any file accessible to the BEAM process
- Execute arbitrary commands
- Access network resources
- Consume unlimited resources
- Access environment variables and secrets

For production deployments, this is unacceptable. However, sandboxing adds complexity:

- Docker requires daemon installation and permissions
- Firecracker/gVisor require specialized setup
- seccomp/AppArmor require Linux-specific configuration
- All isolation mechanisms add latency

During development and testing, developers often:

- Run trusted skills they wrote themselves
- Need fast iteration without container overhead
- Work on systems without Docker (Windows without WSL, restricted environments)
- Debug skill behavior with direct filesystem access

## Decision

We will provide `Conjure.Executor.Local` as an unsandboxed executor for development use only.

The module will:

1. Execute commands directly via `System.cmd/3`
2. Perform file operations via Elixir's `File` module
3. Include prominent documentation warnings
4. Log warnings when used
5. Be explicitly named to indicate its nature

```elixir
defmodule Conjure.Executor.Local do
  @moduledoc """
  Local execution backend using System.cmd.

  ## Security Warning

  This executor provides NO SANDBOXING. Commands and file operations
  execute with the same permissions as the BEAM process.

  **DO NOT USE IN PRODUCTION** unless you fully trust all loaded skills
  and accept the security implications.

  For production deployments, use `Conjure.Executor.Docker` or implement
  a custom executor with appropriate isolation.
  """

  require Logger

  @behaviour Conjure.Executor

  @impl true
  def init(context) do
    Logger.warning(
      "[Conjure] Using Local executor - NO SANDBOXING. " <>
      "Do not use in production with untrusted skills."
    )
    {:ok, context}
  end

  @impl true
  def bash(command, context) do
    System.cmd("bash", ["-c", command],
      cd: context.working_directory,
      stderr_to_stdout: true
    )
    |> handle_result()
  end

  # ... other implementations
end
```

The Local executor will be the default only if no other executor is configured, ensuring users make an explicit choice for production.

## Consequences

### Positive

- Zero setup required for development
- Fast execution (no container overhead)
- Works on any platform with Elixir
- Simple debugging (direct filesystem access)
- No external dependencies
- Enables rapid skill development iteration

### Negative

- Security risk if misused in production
- No resource limits (memory, CPU, time)
- No filesystem isolation
- No network isolation
- Users may forget to switch executors for production

### Neutral

- Warnings logged on every initialization
- Documentation emphasizes security implications
- Production configuration should explicitly set Docker executor

## Mitigations

While we accept the security tradeoffs for development, we implement some basic protections:

### 1. Path Validation

```elixir
def view(path, context, _opts) do
  with {:ok, safe_path} <- validate_path(path, context.allowed_paths) do
    File.read(safe_path)
  end
end

defp validate_path(path, allowed_paths) do
  normalized = Path.expand(path)

  if Enum.any?(allowed_paths, &String.starts_with?(normalized, Path.expand(&1))) do
    {:ok, normalized}
  else
    {:error, :path_not_allowed}
  end
end
```

### 2. Timeout Enforcement

```elixir
def bash(command, context) do
  task = Task.async(fn ->
    System.cmd("bash", ["-c", command], opts)
  end)

  case Task.yield(task, context.timeout) || Task.shutdown(task) do
    {:ok, result} -> handle_result(result)
    nil -> {:error, :timeout}
  end
end
```

### 3. Configuration Warnings

```elixir
# In production config
config :conjure, executor: Conjure.Executor.Docker

# If Local is used in prod, log error on startup
def check_executor_safety do
  if Mix.env() == :prod and executor() == Conjure.Executor.Local do
    Logger.error(
      "[Conjure] Local executor used in production! " <>
      "This is a security risk. Set `config :conjure, executor: Conjure.Executor.Docker`"
    )
  end
end
```

## Alternatives Considered

### No local executor

Require Docker or other sandbox for all execution. Rejected because:

- Blocks development on systems without Docker
- Adds friction for getting started
- Hurts adoption

### Local with seccomp/Landlock

Use Linux security modules for some isolation. Rejected because:

- Linux-only
- Complex configuration
- Partial protection gives false confidence

### Local with user namespaces

Run as unprivileged user. Rejected because:

- Linux-only
- Still allows network access
- Complex setup

### Warn once only

Only log warning on first use. Rejected because:

- Easy to miss in logs
- Subsequent sessions won't see warning
- Per-init warning is minimal overhead

## References

- [System.cmd/3 documentation](https://hexdocs.pm/elixir/System.html#cmd/3)
- [OWASP Command Injection](https://owasp.org/www-community/attacks/Command_Injection)
- [Docker security best practices](https://docs.docker.com/engine/security/)
