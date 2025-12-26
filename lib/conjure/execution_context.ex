defmodule Conjure.ExecutionContext do
  @moduledoc """
  Context passed to executors containing skill and environment information.

  The execution context encapsulates all the configuration needed to safely
  execute tool calls, including:

  - Working directory for file operations
  - Path restrictions for security
  - Environment variables to set
  - Timeout limits
  - Network access policy
  - Executor-specific configuration

  ## Security

  The context enforces boundaries on what the executor can access. Use
  `allowed_paths` to restrict file operations to specific directories.

  ## Example

      context = %Conjure.ExecutionContext{
        skills_root: "/opt/skills",
        working_directory: "/tmp/conjure/session-123",
        allowed_paths: ["/tmp/conjure/session-123", "/opt/skills"],
        timeout: 30_000,
        network_access: :none
      }
  """

  @type t :: %__MODULE__{
          skill: Conjure.Skill.t() | nil,
          skills_root: Path.t(),
          working_directory: Path.t(),
          environment: map(),
          timeout: pos_integer(),
          allowed_paths: [Path.t()],
          network_access: :none | :limited | :full,
          executor_config: map(),
          container_id: String.t() | nil
        }

  defstruct skill: nil,
            skills_root: "/tmp/conjure/skills",
            working_directory: "/tmp/conjure/work",
            environment: %{},
            timeout: 30_000,
            allowed_paths: [],
            network_access: :none,
            executor_config: %{},
            container_id: nil

  @doc """
  Creates a new execution context with the given options.

  ## Options

  * `:skills_root` - Root directory containing skills (default: "/tmp/conjure/skills")
  * `:working_directory` - Working directory for operations (default: "/tmp/conjure/work")
  * `:environment` - Environment variables to set
  * `:timeout` - Execution timeout in milliseconds (default: 30_000)
  * `:allowed_paths` - List of paths that can be accessed
  * `:network_access` - Network policy: `:none`, `:limited`, or `:full`
  * `:executor_config` - Executor-specific configuration
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
    |> compute_allowed_paths()
  end

  @doc """
  Creates a context for a specific skill.
  """
  @spec for_skill(Conjure.Skill.t(), keyword()) :: t()
  def for_skill(skill, opts \\ []) do
    opts
    |> Keyword.put(:skill, skill)
    |> new()
  end

  @doc """
  Validates that a path is within allowed boundaries.

  Returns `{:ok, normalized_path}` if the path is allowed, or
  `{:error, :path_not_allowed}` otherwise.
  """
  @spec validate_path(t(), Path.t()) :: {:ok, Path.t()} | {:error, :path_not_allowed}
  def validate_path(%__MODULE__{allowed_paths: allowed_paths}, path) do
    normalized = Path.expand(path)

    if Enum.empty?(allowed_paths) or path_allowed?(normalized, allowed_paths) do
      {:ok, normalized}
    else
      {:error, :path_not_allowed}
    end
  end

  defp path_allowed?(path, allowed_paths) do
    Enum.any?(allowed_paths, fn allowed ->
      normalized_allowed = Path.expand(allowed)
      String.starts_with?(path, normalized_allowed <> "/") or path == normalized_allowed
    end)
  end

  defp compute_allowed_paths(%__MODULE__{allowed_paths: []} = ctx) do
    # If no paths specified, allow skills root and working directory
    %{ctx | allowed_paths: [ctx.skills_root, ctx.working_directory]}
  end

  defp compute_allowed_paths(ctx), do: ctx
end
