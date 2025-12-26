defmodule Conjure.Error do
  @moduledoc """
  Error types for Conjure operations.

  Provides structured errors with context for debugging and error handling.
  All Conjure errors include a type, message, and optional details map.

  ## Error Types

  * `:skill_not_found` - Skill with given name not found in registry
  * `:invalid_frontmatter` - SKILL.md frontmatter is malformed or missing required fields
  * `:invalid_skill_structure` - Skill directory structure is invalid
  * `:file_not_found` - Requested file does not exist
  * `:permission_denied` - Access to path is not allowed
  * `:execution_failed` - Tool execution failed
  * `:execution_timeout` - Tool execution timed out
  * `:docker_unavailable` - Docker is not available or not running
  * `:container_error` - Container operation failed
  * `:max_iterations_reached` - Conversation loop exceeded maximum iterations

  ### Anthropic Skills API Errors

  * `:anthropic_api_error` - Anthropic API returned an error response
  * `:skills_limit_exceeded` - More than 8 skills specified (API limit)
  * `:skill_upload_failed` - Failed to upload skill to Anthropic
  * `:pause_turn_max_exceeded` - Too many pause_turn iterations
  * `:container_not_found` - Container ID is invalid or expired
  * `:file_download_failed` - Failed to download file from Files API
  * `:invalid_skill_spec` - Invalid skill specification tuple

  ### Native Execution Errors

  * `:not_a_native_skill` - Module does not implement NativeSkill behaviour
  * `:native_callback_missing` - Required callback not implemented
  * `:native_execution_failed` - Native skill callback returned an error

  ### Storage Errors

  * `:storage_init_failed` - Storage backend initialization failed
  * `:storage_cleanup_failed` - Storage cleanup failed
  * `:storage_write_failed` - Writing to storage failed
  * `:storage_read_failed` - Reading from storage failed

  ## Example

      case Conjure.load_skill("/invalid/path") do
        {:ok, skill} -> skill
        {:error, %Conjure.Error{type: :file_not_found} = error} ->
          Logger.warning("Skill not found: \#{error.message}")
      end
  """

  @type error_type ::
          :skill_not_found
          | :invalid_frontmatter
          | :invalid_skill_structure
          | :file_not_found
          | :permission_denied
          | :path_not_allowed
          | :execution_failed
          | :execution_timeout
          | :docker_unavailable
          | :container_error
          | :api_error
          | :max_iterations_reached
          | :zip_error
          # Anthropic Skills API error types
          | :anthropic_api_error
          | :skills_limit_exceeded
          | :skill_upload_failed
          | :pause_turn_max_exceeded
          | :container_not_found
          | :file_download_failed
          | :invalid_skill_spec
          # Native execution error types
          | :not_a_native_skill
          | :native_callback_missing
          | :native_execution_failed
          # Storage error types
          | :storage_init_failed
          | :storage_cleanup_failed
          | :storage_write_failed
          | :storage_read_failed
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          details: map()
        }

  defexception [:type, :message, :details]

  @impl true
  def message(%__MODULE__{message: message}), do: message

  @doc """
  Creates a skill not found error.
  """
  @spec skill_not_found(String.t()) :: t()
  def skill_not_found(name) do
    %__MODULE__{
      type: :skill_not_found,
      message: "Skill '#{name}' not found",
      details: %{name: name}
    }
  end

  @doc """
  Creates an invalid frontmatter error.
  """
  @spec invalid_frontmatter(Path.t(), term()) :: t()
  def invalid_frontmatter(path, reason) do
    %__MODULE__{
      type: :invalid_frontmatter,
      message: "Invalid YAML frontmatter in #{path}: #{format_reason(reason)}",
      details: %{path: path, reason: reason}
    }
  end

  @doc """
  Creates an invalid skill structure error.
  """
  @spec invalid_skill_structure(Path.t(), String.t()) :: t()
  def invalid_skill_structure(path, reason) do
    %__MODULE__{
      type: :invalid_skill_structure,
      message: "Invalid skill structure at #{path}: #{reason}",
      details: %{path: path, reason: reason}
    }
  end

  @doc """
  Creates a file not found error.
  """
  @spec file_not_found(Path.t()) :: t()
  def file_not_found(path) do
    %__MODULE__{
      type: :file_not_found,
      message: "File not found: #{path}",
      details: %{path: path}
    }
  end

  @doc """
  Creates a permission denied error.
  """
  @spec permission_denied(Path.t()) :: t()
  def permission_denied(path) do
    %__MODULE__{
      type: :permission_denied,
      message: "Permission denied: #{path}",
      details: %{path: path}
    }
  end

  @doc """
  Creates a path not allowed error.
  """
  @spec path_not_allowed(Path.t(), [Path.t()]) :: t()
  def path_not_allowed(path, allowed_paths) do
    %__MODULE__{
      type: :path_not_allowed,
      message: "Path '#{path}' is not within allowed paths",
      details: %{path: path, allowed_paths: allowed_paths}
    }
  end

  @doc """
  Creates an execution failed error.
  """
  @spec execution_failed(String.t(), integer(), String.t()) :: t()
  def execution_failed(command, exit_code, output) do
    %__MODULE__{
      type: :execution_failed,
      message: "Command failed with exit code #{exit_code}",
      details: %{command: command, exit_code: exit_code, output: output}
    }
  end

  @doc """
  Creates an execution timeout error.
  """
  @spec execution_timeout(String.t(), pos_integer()) :: t()
  def execution_timeout(command, timeout_ms) do
    %__MODULE__{
      type: :execution_timeout,
      message: "Command timed out after #{timeout_ms}ms",
      details: %{command: command, timeout_ms: timeout_ms}
    }
  end

  @doc """
  Creates a Docker unavailable error.
  """
  @spec docker_unavailable(String.t()) :: t()
  def docker_unavailable(reason) do
    %__MODULE__{
      type: :docker_unavailable,
      message: "Docker is not available: #{reason}",
      details: %{reason: reason}
    }
  end

  @doc """
  Creates a container error.
  """
  @spec container_error(String.t(), term()) :: t()
  def container_error(operation, reason) do
    %__MODULE__{
      type: :container_error,
      message: "Container #{operation} failed: #{format_reason(reason)}",
      details: %{operation: operation, reason: reason}
    }
  end

  @doc """
  Creates a max iterations reached error.
  """
  @spec max_iterations_reached(pos_integer()) :: t()
  def max_iterations_reached(max) do
    %__MODULE__{
      type: :max_iterations_reached,
      message: "Conversation loop exceeded maximum iterations (#{max})",
      details: %{max_iterations: max}
    }
  end

  @doc """
  Creates a ZIP error.
  """
  @spec zip_error(Path.t(), term()) :: t()
  def zip_error(path, reason) do
    %__MODULE__{
      type: :zip_error,
      message: "Failed to process ZIP file #{path}: #{format_reason(reason)}",
      details: %{path: path, reason: reason}
    }
  end

  # Anthropic Skills API Errors

  @doc """
  Creates an Anthropic API error.

  Used when the Anthropic API returns an error response.
  """
  @spec anthropic_api_error(integer(), String.t(), map()) :: t()
  def anthropic_api_error(status, message, details \\ %{}) do
    %__MODULE__{
      type: :anthropic_api_error,
      message: "Anthropic API error (#{status}): #{message}",
      details: Map.merge(%{status: status, api_message: message}, details)
    }
  end

  @doc """
  Creates a skills limit exceeded error.

  Anthropic Skills API supports a maximum of 8 skills per request.
  """
  @spec skills_limit_exceeded(pos_integer(), pos_integer()) :: t()
  def skills_limit_exceeded(count, max) do
    %__MODULE__{
      type: :skills_limit_exceeded,
      message: "Too many skills: #{count} exceeds maximum of #{max}",
      details: %{count: count, max: max}
    }
  end

  @doc """
  Creates a skill upload failed error.
  """
  @spec skill_upload_failed(Path.t(), term()) :: t()
  def skill_upload_failed(path, reason) do
    %__MODULE__{
      type: :skill_upload_failed,
      message: "Failed to upload skill from #{path}: #{format_reason(reason)}",
      details: %{path: path, reason: reason}
    }
  end

  @doc """
  Creates a pause_turn max exceeded error.

  Returned when the conversation loop exceeds maximum pause_turn iterations.
  """
  @spec pause_turn_max_exceeded(pos_integer(), pos_integer()) :: t()
  def pause_turn_max_exceeded(iterations, max) do
    %__MODULE__{
      type: :pause_turn_max_exceeded,
      message: "Exceeded maximum pause_turn iterations: #{iterations}/#{max}",
      details: %{iterations: iterations, max: max}
    }
  end

  @doc """
  Creates a container not found error.
  """
  @spec container_not_found(String.t()) :: t()
  def container_not_found(container_id) do
    %__MODULE__{
      type: :container_not_found,
      message: "Container not found: #{container_id}",
      details: %{container_id: container_id}
    }
  end

  @doc """
  Creates a file download failed error.
  """
  @spec file_download_failed(String.t(), term()) :: t()
  def file_download_failed(file_id, reason) do
    %__MODULE__{
      type: :file_download_failed,
      message: "Failed to download file #{file_id}: #{format_reason(reason)}",
      details: %{file_id: file_id, reason: reason}
    }
  end

  @doc """
  Creates an invalid skill spec error.
  """
  @spec invalid_skill_spec(term()) :: t()
  def invalid_skill_spec(spec) do
    %__MODULE__{
      type: :invalid_skill_spec,
      message:
        "Invalid skill specification: #{inspect(spec)}. Expected {type, skill_id, version} tuple.",
      details: %{spec: spec}
    }
  end

  # Native Execution Errors

  @doc """
  Creates a not a native skill error.

  Returned when a module does not implement the NativeSkill behaviour.
  """
  @spec not_a_native_skill(module()) :: t()
  def not_a_native_skill(module) do
    %__MODULE__{
      type: :not_a_native_skill,
      message: "Module #{inspect(module)} does not implement Conjure.NativeSkill behaviour",
      details: %{module: module}
    }
  end

  @doc """
  Creates a native callback missing error.

  Returned when a required callback is not implemented by the skill module.
  """
  @spec native_callback_missing(module(), atom()) :: t()
  def native_callback_missing(module, callback) do
    %__MODULE__{
      type: :native_callback_missing,
      message: "Module #{inspect(module)} does not implement #{callback} callback",
      details: %{module: module, callback: callback}
    }
  end

  @doc """
  Creates a native execution failed error.

  Returned when a native skill callback returns an error.
  """
  @spec native_execution_failed(module(), atom(), term()) :: t()
  def native_execution_failed(module, callback, reason) do
    %__MODULE__{
      type: :native_execution_failed,
      message: "Native skill #{inspect(module)}.#{callback} failed: #{format_reason(reason)}",
      details: %{module: module, callback: callback, reason: reason}
    }
  end

  # Storage Errors

  @doc """
  Creates a storage initialization failed error.

  Returned when storage backend initialization fails.
  """
  @spec storage_init_failed(term()) :: t()
  def storage_init_failed(reason) do
    %__MODULE__{
      type: :storage_init_failed,
      message: "Failed to initialize storage: #{format_reason(reason)}",
      details: %{reason: reason}
    }
  end

  @doc """
  Creates a storage cleanup failed error.

  Returned when storage cleanup fails.
  """
  @spec storage_cleanup_failed(term()) :: t()
  def storage_cleanup_failed(reason) do
    %__MODULE__{
      type: :storage_cleanup_failed,
      message: "Failed to cleanup storage: #{format_reason(reason)}",
      details: %{reason: reason}
    }
  end

  @doc """
  Creates a storage write failed error.

  Returned when writing to storage fails.
  """
  @spec storage_write_failed(String.t(), term()) :: t()
  def storage_write_failed(path, reason) do
    %__MODULE__{
      type: :storage_write_failed,
      message: "Failed to write to storage path '#{path}': #{format_reason(reason)}",
      details: %{path: path, reason: reason}
    }
  end

  @doc """
  Creates a storage read failed error.

  Returned when reading from storage fails.
  """
  @spec storage_read_failed(String.t(), term()) :: t()
  def storage_read_failed(path, reason) do
    %__MODULE__{
      type: :storage_read_failed,
      message: "Failed to read from storage path '#{path}': #{format_reason(reason)}",
      details: %{path: path, reason: reason}
    }
  end

  @doc """
  Creates a missing API callback error.

  Returned when an API callback is required but not provided.
  """
  @spec missing_api_callback(String.t()) :: t()
  def missing_api_callback(message) do
    %__MODULE__{
      type: :missing_api_callback,
      message: message,
      details: %{}
    }
  end

  @doc """
  Wraps a raw error into a Conjure.Error.
  """
  @spec wrap(term()) :: t()
  def wrap(%__MODULE__{} = error), do: error

  def wrap({:error, reason}), do: wrap(reason)

  def wrap(reason) do
    %__MODULE__{
      type: :unknown,
      message: format_reason(reason),
      details: %{reason: reason}
    }
  end

  defp format_reason({:missing_field, field}), do: "missing required field '#{field}'"
  defp format_reason({:empty_field, field}), do: "field '#{field}' cannot be empty"
  defp format_reason({:invalid_name, msg}), do: msg
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
