# ADR-0014: Centralized security module

## Status

Proposed

## Context

Security validation logic is currently distributed across multiple modules:

- `Conjure.Executor.Local` - Path validation in `validate_path/2`
- `Conjure.Executor.Docker` - Path escaping in `escape_for_shell/1`, `escape_for_python/1`
- `Conjure.ExecutionContext` - `allowed_paths` field definition
- Various inline checks throughout the codebase

The specification (section 15.3) defines a `Conjure.Security` module that was not implemented:

```elixir
defmodule Conjure.Security do
  def validate_path(path, allowed_paths)
  defp path_under?(base, path)
end
```

This distributed approach has drawbacks:

1. **Inconsistent validation** - Each executor implements its own checks
2. **Duplicated logic** - Path validation repeated across modules
3. **Harder to audit** - Security code spread throughout codebase
4. **Testing gaps** - Security functions tested indirectly

## Decision

We will implement a centralized `Conjure.Security` module that consolidates all security-related functionality:

```elixir
defmodule Conjure.Security do
  @moduledoc """
  Centralized security utilities for Conjure.

  This module provides path validation, input sanitization, and
  security policy enforcement used by executors and other components.
  """

  # ============================================================
  # Path Validation
  # ============================================================

  @doc """
  Validates that a path is within allowed boundaries.

  Returns `{:ok, normalized_path}` if the path is allowed,
  or `{:error, :path_not_allowed}` if it's outside allowed paths.

  ## Examples

      iex> validate_path("/workspace/file.txt", ["/workspace"])
      {:ok, "/workspace/file.txt"}

      iex> validate_path("/etc/passwd", ["/workspace"])
      {:error, :path_not_allowed}

      iex> validate_path("../../../etc/passwd", ["/workspace"])
      {:error, :path_not_allowed}
  """
  @spec validate_path(Path.t(), [Path.t()]) :: {:ok, Path.t()} | {:error, :path_not_allowed}
  def validate_path(path, allowed_paths)

  @doc """
  Checks if a path is under a base directory.
  Handles path traversal attempts (../).
  """
  @spec path_under?(Path.t(), Path.t()) :: boolean()
  def path_under?(base, path)

  @doc """
  Normalizes and expands a path, resolving symlinks.
  """
  @spec normalize_path(Path.t()) :: Path.t()
  def normalize_path(path)

  # ============================================================
  # Input Sanitization
  # ============================================================

  @doc """
  Escapes a string for safe use in shell commands.
  Uses single-quote wrapping with proper escape sequences.
  """
  @spec escape_shell(String.t()) :: String.t()
  def escape_shell(input)

  @doc """
  Escapes a string for safe use in Python string literals.
  Handles unicode and special characters.
  """
  @spec escape_python(String.t()) :: String.t()
  def escape_python(input)

  @doc """
  Validates that a command doesn't contain dangerous patterns.
  Returns {:ok, command} or {:error, :dangerous_command}.
  """
  @spec validate_command(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def validate_command(command, opts \\ [])

  # ============================================================
  # Policy Enforcement
  # ============================================================

  @doc """
  Checks if an operation is allowed by the execution context.
  """
  @spec allowed?(atom(), ExecutionContext.t()) :: boolean()
  def allowed?(operation, context)

  @doc """
  Returns the effective allowed paths for a context,
  combining global config with context-specific paths.
  """
  @spec effective_allowed_paths(ExecutionContext.t()) :: [Path.t()]
  def effective_allowed_paths(context)

  # ============================================================
  # Audit Logging
  # ============================================================

  @doc """
  Logs a security-relevant event via telemetry.
  """
  @spec audit(atom(), map()) :: :ok
  def audit(event, metadata)
end
```

### Migration Plan

1. Create `Conjure.Security` module with all functions
2. Update `Conjure.Executor.Local` to delegate to Security module
3. Update `Conjure.Executor.Docker` to delegate to Security module
4. Add comprehensive tests for Security module
5. Deprecate inline security functions (if any exposed)

### Usage in Executors

```elixir
defmodule Conjure.Executor.Local do
  alias Conjure.Security

  def view(path, context, _opts) do
    with {:ok, safe_path} <- Security.validate_path(path, context.allowed_paths),
         {:ok, normalized} <- Security.normalize_path(safe_path) do
      # Proceed with file read
    end
  end

  def bash(command, context) do
    with {:ok, _} <- Security.validate_command(command),
         :ok <- Security.audit(:bash_execution, %{command: command}) do
      # Proceed with execution
    end
  end
end
```

## Consequences

### Positive

- **Single source of truth** for security logic
- **Easier auditing** - all security code in one place
- **Consistent behavior** across executors
- **Better testing** - security functions tested in isolation
- **Reusable** - custom executors can use the same utilities

### Negative

- Migration effort to consolidate existing code
- Additional module to maintain
- Potential performance overhead from extra function calls (minimal)

### Neutral

- Executors remain responsible for calling security functions
- Doesn't change the fundamental security model
- Custom executors can bypass if they choose (their responsibility)

## Alternatives Considered

### Middleware/Pipeline Approach

Wrap all executor calls in security middleware. Rejected because:

- Adds complexity to the executor behaviour
- Less flexibility for custom security policies
- Harder to understand call flow

### Leave Distributed

Keep security logic in individual executors. Rejected because:

- Current state leads to inconsistencies
- Harder to audit and maintain
- Duplicated code

### Security Behaviour

Define a `Conjure.Security` behaviour that executors must implement. Rejected because:

- Over-engineering for the use case
- Security policy is orthogonal to execution strategy
- Module with functions is simpler

## References

- [ADR-0009: Local executor without sandboxing](0009-local-executor-no-sandbox.md)
- [ADR-0010: Docker as production executor](0010-docker-production-executor.md)
- [OWASP Path Traversal](https://owasp.org/www-community/attacks/Path_Traversal)
- [Elixir Security Best Practices](https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/)
