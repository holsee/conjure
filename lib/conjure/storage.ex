defmodule Conjure.Storage do
  @moduledoc """
  Behaviour for session storage backends.

  Storage backends manage the working directory and file operations for sessions.
  All backends must provide a local filesystem path for Docker mounting.

  ## Available Backends

  | Backend | Module | Description |
  |---------|--------|-------------|
  | Local | `Conjure.Storage.Local` | Ephemeral temp directories (default) |
  | S3 | `Conjure.Storage.S3` | AWS S3 with local cache |
  | Tigris | `Conjure.Storage.Tigris` | Fly.io Tigris storage |

  ## Usage

      # Default local storage
      {:ok, session} = Conjure.Session.new_docker(skills)

      # S3 storage
      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: {Conjure.Storage.S3, bucket: "my-bucket"}
      )

      # Tigris (Fly.io) - zero config on Fly Machines
      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: Conjure.Storage.Tigris
      )

  ## Implementing a Custom Storage Backend

  Any module can implement this behaviour for custom storage needs:

      defmodule MyApp.Storage.Azure do
        @behaviour Conjure.Storage

        @impl true
        def init(session_id, opts) do
          # Initialize Azure Blob storage
          {:ok, state}
        end

        # ... implement all callbacks
      end

      # Use it:
      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: {MyApp.Storage.Azure, container: "sessions"}
      )

  ## File Callbacks

  Sessions can be configured with callbacks for file events:

      {:ok, session} = Conjure.Session.new_docker(skills,
        on_file_created: fn file_ref, session_id ->
          MyApp.Repo.insert!(%SessionFile{
            session_id: session_id,
            path: file_ref.path
          })
        end
      )

  ## See Also

  * `Conjure.Session` - Session management
  * `Conjure.Storage.Local` - Local filesystem storage
  * `Conjure.Storage.S3` - AWS S3 storage
  * `Conjure.Storage.Tigris` - Fly.io Tigris storage
  * [ADR-0022: Storage Strategy](docs/adr/0022-storage-strategy.md)
  """

  @type session_id :: String.t()
  @type path :: String.t()
  @type content :: binary()
  @type state :: term()

  @type file_ref :: %{
          path: path(),
          size: non_neg_integer(),
          content_type: String.t() | nil,
          checksum: String.t() | nil,
          storage_url: String.t() | nil,
          created_at: DateTime.t()
        }

  @type callback_event :: :created | :modified | :deleted | :synced
  @type file_callback :: (file_ref(), session_id() -> :ok | {:error, term()})

  # ===========================================================================
  # Lifecycle Callbacks
  # ===========================================================================

  @doc """
  Initialize storage for a session.

  Creates the storage state for the given session ID. For local storage,
  this creates the working directory. For remote storage, this sets up
  credentials and local cache.

  ## Parameters

  * `session_id` - Unique identifier for the session
  * `opts` - Backend-specific options

  ## Returns

  * `{:ok, state}` - Successfully initialized storage
  * `{:error, term()}` - Initialization failed
  """
  @callback init(session_id, opts :: keyword()) :: {:ok, state} | {:error, term()}

  @doc """
  Cleanup storage for a session.

  Removes all files and releases resources. For remote storage,
  this also deletes objects from the remote store.

  ## Parameters

  * `state` - Storage state from `init/2`

  ## Returns

  * `:ok` - Cleanup successful
  * `{:error, term()}` - Cleanup failed
  """
  @callback cleanup(state) :: :ok | {:error, term()}

  # ===========================================================================
  # File Operations
  # ===========================================================================

  @doc """
  Write a file to storage.

  ## Parameters

  * `state` - Storage state
  * `path` - Relative path within the session
  * `content` - File content as binary

  ## Returns

  * `{:ok, file_ref}` - File written successfully
  * `{:error, term()}` - Write failed
  """
  @callback write(state, path, content) :: {:ok, file_ref} | {:error, term()}

  @doc """
  Read a file from storage.

  ## Parameters

  * `state` - Storage state
  * `path` - Relative path within the session

  ## Returns

  * `{:ok, content}` - File content
  * `{:error, {:file_not_found, path}}` - File does not exist
  * `{:error, term()}` - Read failed
  """
  @callback read(state, path) :: {:ok, content} | {:error, term()}

  @doc """
  Check if a file exists in storage.

  ## Parameters

  * `state` - Storage state
  * `path` - Relative path within the session

  ## Returns

  * `true` - File exists
  * `false` - File does not exist
  """
  @callback exists?(state, path) :: boolean()

  @doc """
  Delete a file from storage.

  ## Parameters

  * `state` - Storage state
  * `path` - Relative path within the session

  ## Returns

  * `:ok` - File deleted (or didn't exist)
  * `{:error, term()}` - Delete failed
  """
  @callback delete(state, path) :: :ok | {:error, term()}

  @doc """
  List all files in storage.

  ## Parameters

  * `state` - Storage state

  ## Returns

  * `{:ok, [file_ref]}` - List of file references
  * `{:error, term()}` - List failed
  """
  @callback list(state) :: {:ok, [file_ref]} | {:error, term()}

  # ===========================================================================
  # Docker Integration
  # ===========================================================================

  @doc """
  Get the local filesystem path for Docker mounting.

  Docker containers require a local path to mount as a volume.
  For local storage, this is the storage directory.
  For remote storage, this is the local cache directory.

  ## Parameters

  * `state` - Storage state

  ## Returns

  * `{:ok, path}` - Local filesystem path
  * `{:error, :not_supported}` - This storage doesn't support local paths
  """
  @callback local_path(state) :: {:ok, path} | {:error, :not_supported}

  # ===========================================================================
  # Remote Sync (Optional)
  # ===========================================================================

  @doc """
  Sync files from a remote source.

  Used by the Anthropic backend to download files created server-side.

  ## Parameters

  * `state` - Storage state
  * `remote_files` - List of remote file descriptors

  ## Returns

  * `{:ok, [file_ref]}` - Synced file references
  * `{:error, term()}` - Sync failed
  """
  @callback sync_from_remote(state, remote_files :: [map()]) ::
              {:ok, [file_ref]} | {:error, term()}

  @doc """
  Sync local files to remote storage.

  Forces upload of any pending local files to remote storage.

  ## Parameters

  * `state` - Storage state

  ## Returns

  * `{:ok, [file_ref]}` - Synced file references
  * `{:error, term()}` - Sync failed
  """
  @callback sync_to_remote(state) :: {:ok, [file_ref]} | {:error, term()}

  @optional_callbacks [sync_from_remote: 2, sync_to_remote: 1]

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  @doc """
  Generate a unique session ID.

  Uses cryptographically secure random bytes encoded as URL-safe base64.

  ## Example

      iex> session_id = Conjure.Storage.generate_session_id()
      "Xt7kB9mP2Qw5nL3j"
  """
  @spec generate_session_id() :: session_id()
  def generate_session_id do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Build a file reference from path and content.

  ## Parameters

  * `path` - Relative file path
  * `content` - File content as binary
  * `opts` - Optional overrides:
    * `:content_type` - MIME type (auto-detected if not provided)
    * `:checksum` - SHA256 checksum (computed if not provided)
    * `:storage_url` - Remote storage URL

  ## Example

      iex> Conjure.Storage.build_file_ref("output.xlsx", content)
      %{
        path: "output.xlsx",
        size: 1234,
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        checksum: "abc123...",
        storage_url: nil,
        created_at: ~U[2024-01-15 10:30:00Z]
      }
  """
  @spec build_file_ref(path(), content(), keyword()) :: file_ref()
  def build_file_ref(path, content, opts \\ []) do
    %{
      path: path,
      size: byte_size(content),
      content_type: Keyword.get(opts, :content_type, guess_content_type(path)),
      checksum: Keyword.get_lazy(opts, :checksum, fn -> compute_checksum(content) end),
      storage_url: Keyword.get(opts, :storage_url),
      created_at: DateTime.utc_now()
    }
  end

  @doc """
  Guess MIME content type from file extension.

  ## Example

      iex> Conjure.Storage.guess_content_type("report.pdf")
      "application/pdf"
  """
  @content_types %{
    ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".xls" => "application/vnd.ms-excel",
    ".pdf" => "application/pdf",
    ".json" => "application/json",
    ".txt" => "text/plain",
    ".csv" => "text/csv",
    ".html" => "text/html",
    ".xml" => "application/xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".zip" => "application/zip",
    ".tar" => "application/x-tar",
    ".gz" => "application/gzip"
  }

  @spec guess_content_type(path()) :: String.t()
  def guess_content_type(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end

  @doc """
  Compute SHA256 checksum of content.

  ## Example

      iex> Conjure.Storage.compute_checksum("hello")
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  """
  @spec compute_checksum(content()) :: String.t()
  def compute_checksum(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
