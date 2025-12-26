defmodule Conjure.Storage.Local do
  @moduledoc """
  Local filesystem storage backend.

  Creates ephemeral directories in the system temp directory by default.
  Suitable for development and single-node deployments.

  ## Options

  * `:base_path` - Base directory for session directories (default: `System.tmp_dir!()`)
  * `:prefix` - Prefix for directory names (default: `"conjure"`)
  * `:cleanup_on_exit` - Whether to delete files on cleanup (default: `true`)

  ## Example

      # Default configuration
      {:ok, storage} = Conjure.Storage.Local.init("session_123", [])

      # Custom base path
      {:ok, storage} = Conjure.Storage.Local.init("session_123",
        base_path: "/var/lib/conjure",
        prefix: "session"
      )

      # Persist after cleanup (for debugging)
      {:ok, storage} = Conjure.Storage.Local.init("session_123",
        cleanup_on_exit: false
      )

  ## Directory Structure

  Files are stored in a flat structure under the session directory:

      /tmp/conjure_session_123/
      ├── output.xlsx
      ├── report.pdf
      └── data/
          └── processed.json

  ## See Also

  * `Conjure.Storage` - Storage behaviour
  * `Conjure.Session` - Session management
  """

  @behaviour Conjure.Storage

  require Logger

  defstruct [:path, :session_id, :cleanup_on_exit]

  @type t :: %__MODULE__{
          path: Path.t(),
          session_id: String.t(),
          cleanup_on_exit: boolean()
        }

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl Conjure.Storage
  def init(session_id, opts) do
    base = Keyword.get(opts, :base_path, System.tmp_dir!())
    prefix = Keyword.get(opts, :prefix, "conjure")
    cleanup_on_exit = Keyword.get(opts, :cleanup_on_exit, true)

    path = Path.join(base, "#{prefix}_#{session_id}")

    case File.mkdir_p(path) do
      :ok ->
        emit_telemetry(:init, session_id)

        {:ok,
         %__MODULE__{
           path: path,
           session_id: session_id,
           cleanup_on_exit: cleanup_on_exit
         }}

      {:error, reason} ->
        {:error, {:mkdir_failed, path, reason}}
    end
  end

  @impl Conjure.Storage
  def cleanup(%__MODULE__{cleanup_on_exit: false} = state) do
    emit_telemetry(:cleanup, state.session_id, 0)
    :ok
  end

  def cleanup(%__MODULE__{path: path, session_id: session_id}) do
    file_count = count_files(path)

    case File.rm_rf(path) do
      {:ok, _} ->
        emit_telemetry(:cleanup, session_id, file_count)
        :ok

      {:error, reason, _} ->
        {:error, {:cleanup_failed, reason}}
    end
  end

  # ===========================================================================
  # Docker Integration
  # ===========================================================================

  @impl Conjure.Storage
  def local_path(%__MODULE__{path: path}), do: {:ok, path}

  # ===========================================================================
  # File Operations
  # ===========================================================================

  @impl Conjure.Storage
  def write(%__MODULE__{} = state, path, content) do
    start_time = System.monotonic_time()
    full_path = Path.join(state.path, path)

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, content) do
      file_ref = Conjure.Storage.build_file_ref(path, content)
      emit_telemetry(:write, state.session_id, path, byte_size(content), start_time)
      {:ok, file_ref}
    else
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  @impl Conjure.Storage
  def read(%__MODULE__{} = state, path) do
    start_time = System.monotonic_time()
    full_path = Path.join(state.path, path)

    case File.read(full_path) do
      {:ok, content} ->
        emit_telemetry(:read, state.session_id, path, byte_size(content), start_time)
        {:ok, content}

      {:error, :enoent} ->
        {:error, {:file_not_found, path}}

      {:error, reason} ->
        {:error, {:read_failed, path, reason}}
    end
  end

  @impl Conjure.Storage
  def exists?(%__MODULE__{path: base_path}, path) do
    full_path = Path.join(base_path, path)
    File.exists?(full_path)
  end

  @impl Conjure.Storage
  def delete(%__MODULE__{} = state, path) do
    start_time = System.monotonic_time()
    full_path = Path.join(state.path, path)

    case File.rm(full_path) do
      :ok ->
        emit_telemetry(:delete, state.session_id, path, start_time)
        :ok

      {:error, :enoent} ->
        # Already deleted
        :ok

      {:error, reason} ->
        {:error, {:delete_failed, path, reason}}
    end
  end

  @impl Conjure.Storage
  def list(%__MODULE__{path: base_path}) do
    case list_files_recursive(base_path, base_path) do
      {:ok, files} ->
        file_refs =
          Enum.map(files, fn {rel_path, stat} ->
            %{
              path: rel_path,
              size: stat.size,
              content_type: Conjure.Storage.guess_content_type(rel_path),
              checksum: nil,
              storage_url: nil,
              created_at: datetime_from_stat(stat)
            }
          end)

        {:ok, file_refs}

      {:error, reason} ->
        {:error, {:list_failed, reason}}
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp list_files_recursive(base_path, current_path) do
    case File.ls(current_path) do
      {:ok, entries} ->
        results = Enum.flat_map(entries, &process_entry(base_path, current_path, &1))
        {:ok, results}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_entry(base_path, current_path, entry) do
    full_path = Path.join(current_path, entry)

    if File.dir?(full_path) do
      case list_files_recursive(base_path, full_path) do
        {:ok, nested} -> nested
        _ -> []
      end
    else
      file_entry(base_path, full_path)
    end
  end

  defp file_entry(base_path, full_path) do
    rel_path = Path.relative_to(full_path, base_path)

    case File.stat(full_path) do
      {:ok, stat} -> [{rel_path, stat}]
      _ -> []
    end
  end

  defp count_files(path) do
    case list_files_recursive(path, path) do
      {:ok, files} -> length(files)
      _ -> 0
    end
  end

  defp datetime_from_stat(%File.Stat{ctime: ctime}) do
    case NaiveDateTime.from_erl(ctime) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> DateTime.utc_now()
    end
  end

  # ===========================================================================
  # Telemetry
  # ===========================================================================

  defp emit_telemetry(:init, session_id) do
    :telemetry.execute(
      [:conjure, :storage, :init],
      %{system_time: System.system_time()},
      %{strategy: __MODULE__, session_id: session_id}
    )
  end

  defp emit_telemetry(:cleanup, session_id, file_count) do
    :telemetry.execute(
      [:conjure, :storage, :cleanup],
      %{system_time: System.system_time(), file_count: file_count},
      %{strategy: __MODULE__, session_id: session_id}
    )
  end

  defp emit_telemetry(:write, session_id, path, size, start_time) do
    :telemetry.execute(
      [:conjure, :storage, :write],
      %{duration: System.monotonic_time() - start_time, size: size},
      %{strategy: __MODULE__, session_id: session_id, path: path}
    )
  end

  defp emit_telemetry(:read, session_id, path, size, start_time) do
    :telemetry.execute(
      [:conjure, :storage, :read],
      %{duration: System.monotonic_time() - start_time, size: size},
      %{strategy: __MODULE__, session_id: session_id, path: path}
    )
  end

  defp emit_telemetry(:delete, session_id, path, start_time) do
    :telemetry.execute(
      [:conjure, :storage, :delete],
      %{duration: System.monotonic_time() - start_time},
      %{strategy: __MODULE__, session_id: session_id, path: path}
    )
  end
end
