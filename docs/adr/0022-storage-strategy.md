# ADR-0022: Pluggable Storage Strategy

## Status

Accepted

## Context

Currently, the Docker backend uses a hardcoded working directory pattern with a default of `/workspace`, which is invalid as a host path and causes test failures on macOS/Linux. More broadly, different deployment scenarios require different storage backends:

1. **Local Development**: Ephemeral tmp directories, fast, no external dependencies
2. **Multi-Node Clusters**: Shared storage (S3, Tigris) for session state across nodes
3. **Fly.io Deployments**: Tigris Object Storage for persistent, low-latency storage
4. **Session Resume**: Persistent storage enabling conversation continuation after restarts
5. **Compliance/Audit**: Durable storage of session artifacts for record-keeping

Additionally, the Anthropic backend creates files server-side that need to be synchronized to client storage. Consumers of this library need callbacks to capture file references for their own persistence needs (e.g., associating files with users in a database).

### Forces

- Docker requires a **local mount path** - remote storage must be synced locally
- Anthropic backend creates files remotely that may need client-side persistence
- Native backend operates in-memory but may want to persist results
- Library consumers need hooks to store file metadata in their own systems
- Storage lifecycle must align with session lifecycle
- Cleanup must be reliable, even on crashes

## Decision

We will introduce a `Conjure.Storage` behaviour that abstracts storage operations, with implementations for Local, S3, and Tigris. All backends will use this abstraction for session working directories and file operations.

### Storage Behaviour

```elixir
defmodule Conjure.Storage do
  @moduledoc "Behaviour for session storage backends"

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

  # Lifecycle
  @callback init(session_id, opts :: keyword()) :: {:ok, state} | {:error, term()}
  @callback cleanup(state) :: :ok | {:error, term()}

  # File operations
  @callback write(state, path, content) :: {:ok, file_ref} | {:error, term()}
  @callback read(state, path) :: {:ok, content} | {:error, term()}
  @callback exists?(state, path) :: boolean()
  @callback delete(state, path) :: :ok | {:error, term()}
  @callback list(state) :: {:ok, [file_ref]} | {:error, term()}

  # For Docker mounting - returns a local filesystem path
  @callback local_path(state) :: {:ok, path} | {:error, :not_supported}

  # For syncing remote files (Anthropic backend)
  @callback sync_from_remote(state, remote_files :: [map()]) :: {:ok, [file_ref]} | {:error, term()}
  @callback sync_to_remote(state) :: {:ok, [file_ref]} | {:error, term()}

  # Optional callbacks
  @optional_callbacks [sync_from_remote: 2, sync_to_remote: 1]
end
```

### Implementations

#### Local Storage (Default)

```elixir
defmodule Conjure.Storage.Local do
  @behaviour Conjure.Storage

  @impl true
  def init(session_id, opts) do
    base = Keyword.get(opts, :base_path, System.tmp_dir!())
    prefix = Keyword.get(opts, :prefix, "conjure")
    path = Path.join(base, "#{prefix}_#{session_id}")

    File.mkdir_p!(path)
    {:ok, %{path: path, session_id: session_id}}
  end

  @impl true
  def local_path(%{path: path}), do: {:ok, path}

  @impl true
  def cleanup(%{path: path}) do
    File.rm_rf!(path)
    :ok
  end

  # ... other callbacks operate directly on filesystem
end
```

#### S3 Storage

```elixir
defmodule Conjure.Storage.S3 do
  @behaviour Conjure.Storage

  @impl true
  def init(session_id, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = Keyword.get(opts, :prefix, "sessions/")
    region = Keyword.get(opts, :region, "us-east-1")

    # Local cache for Docker mounting
    cache_path = Path.join(System.tmp_dir!(), "conjure_s3_#{session_id}")
    File.mkdir_p!(cache_path)

    {:ok, %{
      bucket: bucket,
      prefix: "#{prefix}#{session_id}/",
      region: region,
      cache_path: cache_path,
      session_id: session_id
    }}
  end

  @impl true
  def local_path(%{cache_path: path}), do: {:ok, path}

  @impl true
  def write(state, path, content) do
    # Write to local cache
    local_file = Path.join(state.cache_path, path)
    File.mkdir_p!(Path.dirname(local_file))
    File.write!(local_file, content)

    # Async upload to S3
    s3_key = "#{state.prefix}#{path}"
    :ok = upload_to_s3(state.bucket, s3_key, content, state.region)

    {:ok, build_file_ref(path, content, s3_url(state, path))}
  end

  @impl true
  def cleanup(state) do
    # Delete from S3
    delete_prefix(state.bucket, state.prefix, state.region)
    # Cleanup local cache
    File.rm_rf!(state.cache_path)
    :ok
  end

  # ... other callbacks
end
```

#### Tigris Storage (Fly.io)

Tigris is Fly.io's globally-distributed, S3-compatible object storage. It automatically replicates data to regions close to your Fly Machines, providing low-latency access worldwide.

**Fly.io Setup:**

```bash
# Create a Tigris bucket for your Fly app
fly storage create

# Or with a specific name
fly storage create conjure-sessions

# Credentials are automatically injected into your Fly Machines as:
# - AWS_ACCESS_KEY_ID
# - AWS_SECRET_ACCESS_KEY
# - AWS_ENDPOINT_URL_S3
# - BUCKET_NAME
```

**fly.toml configuration:**

```toml
[env]
  SKILLEX_STORAGE = "tigris"

# Tigris bucket is attached automatically after `fly storage create`
```

```elixir
defmodule Conjure.Storage.Tigris do
  @moduledoc """
  Fly.io Tigris object storage backend.

  Tigris provides:
  - Global distribution with automatic replication
  - S3-compatible API
  - Zero-config when running on Fly.io Machines
  - Low-latency access from any Fly.io region

  Credentials are automatically available when running on Fly.io.
  For local development, use `fly storage` credentials or set env vars.
  """

  @behaviour Conjure.Storage

  @impl true
  def init(session_id, opts) do
    # Fly.io injects these automatically into Machines
    bucket = Keyword.get_lazy(opts, :bucket, fn ->
      System.get_env("BUCKET_NAME") || raise "BUCKET_NAME not set"
    end)

    endpoint = Keyword.get(opts, :endpoint, System.get_env("AWS_ENDPOINT_URL_S3"))
    access_key = Keyword.get(opts, :access_key, System.get_env("AWS_ACCESS_KEY_ID"))
    secret_key = Keyword.get(opts, :secret_key, System.get_env("AWS_SECRET_ACCESS_KEY"))

    # Optional: specify region hint for read affinity
    # Fly.io sets FLY_REGION automatically
    region = Keyword.get(opts, :region, System.get_env("FLY_REGION", "auto"))

    # Local cache for Docker mounting (uses Fly volume if available)
    cache_base = Keyword.get(opts, :cache_path,
      System.get_env("FLY_VOLUME_PATH") || System.tmp_dir!()
    )
    cache_path = Path.join(cache_base, "conjure_sessions/#{session_id}")
    File.mkdir_p!(cache_path)

    {:ok, %{
      bucket: bucket,
      prefix: "sessions/#{session_id}/",
      endpoint: endpoint,
      access_key: access_key,
      secret_key: secret_key,
      region: region,
      cache_path: cache_path,
      session_id: session_id
    }}
  end

  @impl true
  def local_path(%{cache_path: path}), do: {:ok, path}

  @impl true
  def write(state, path, content) do
    # Write to local cache first (fast, synchronous)
    local_file = Path.join(state.cache_path, path)
    File.mkdir_p!(Path.dirname(local_file))
    File.write!(local_file, content)

    # Upload to Tigris (replicated globally automatically)
    s3_key = "#{state.prefix}#{path}"
    :ok = put_object(state, s3_key, content)

    {:ok, build_file_ref(path, content, public_url(state, path))}
  end

  @impl true
  def cleanup(state) do
    # Delete from Tigris
    delete_prefix(state, state.prefix)
    # Cleanup local cache
    File.rm_rf!(state.cache_path)
    :ok
  end

  # Uses ex_aws or req for S3-compatible API calls
  defp put_object(state, key, content) do
    # Implementation using S3-compatible API against state.endpoint
  end

  defp delete_prefix(state, prefix) do
    # List and delete all objects with prefix
  end

  defp public_url(state, path) do
    "#{state.endpoint}/#{state.bucket}/#{state.prefix}#{path}"
  end
end
```

**Local Development with Tigris:**

```bash
# Get credentials for local dev
fly storage auth

# Or proxy through Fly
fly proxy 4566:443 -a <your-tigris-app>
```

```elixir
# config/dev.exs
config :conjure, :storage,
  strategy: Conjure.Storage.Tigris,
  endpoint: "http://localhost:4566",  # Local proxy
  bucket: "conjure-dev"
```

**Multi-Region Session Affinity:**

Tigris automatically serves data from the nearest region. For session locality:

```elixir
# Include region in session_id for debugging/routing
session_id = "#{System.get_env("FLY_REGION")}_#{UUID.uuid4()}"
```

### Consumer Callbacks

To allow library consumers to capture file references for their own persistence:

```elixir
defmodule Conjure.Storage.Callbacks do
  @type file_event :: :created | :modified | :deleted | :synced
  @type callback :: (file_event, Conjure.Storage.file_ref(), session_id :: String.t() -> :ok)

  @callback on_file_event(callback) :: :ok
end
```

Callbacks are configured per-session:

```elixir
session = Conjure.Session.new_docker(skills,
  storage: {Conjure.Storage.S3, bucket: "my-bucket"},
  on_file_created: fn file_ref, session_id ->
    # Store reference in your database
    MyApp.Repo.insert!(%MyApp.SessionFile{
      user_id: current_user.id,
      session_id: session_id,
      path: file_ref.path,
      storage_url: file_ref.storage_url,
      size: file_ref.size
    })
  end,
  on_file_deleted: fn file_ref, session_id ->
    MyApp.Repo.delete_all(
      from f in MyApp.SessionFile,
      where: f.session_id == ^session_id and f.path == ^file_ref.path
    )
  end
)
```

### Anthropic Backend Sync

The Anthropic backend creates files server-side. Storage sync pulls these to client storage:

```elixir
defmodule Conjure.Backend.Anthropic do
  def chat(session, message, api_callback, opts) do
    # ... conversation logic ...

    # After turn completes, sync created files
    case session.storage do
      nil -> {:ok, response, session}
      storage ->
        remote_files = get_created_files_from_response(response)
        {:ok, file_refs} = Conjure.Storage.sync_from_remote(storage, remote_files)
        session = %{session | created_files: session.created_files ++ file_refs}

        # Fire callbacks
        Enum.each(file_refs, fn ref ->
          fire_callback(session, :synced, ref)
        end)

        {:ok, response, session}
    end
  end
end
```

### Session Integration

```elixir
defmodule Conjure.Session do
  defstruct [
    # ... existing fields ...
    :storage,           # Storage state
    :storage_strategy,  # Module implementing Storage behaviour
    :file_callbacks     # Map of event -> callback function
  ]

  def new_docker(skills, opts) do
    {storage_strategy, storage_opts} = resolve_storage(opts)
    session_id = generate_session_id()
    {:ok, storage} = storage_strategy.init(session_id, storage_opts)

    # Get local path for Docker mounting
    {:ok, work_dir} = storage_strategy.local_path(storage)

    %Session{
      execution_mode: :docker,
      storage: storage,
      storage_strategy: storage_strategy,
      context: %ExecutionContext{working_directory: work_dir},
      # ...
    }
  end

  defp resolve_storage(opts) do
    case Keyword.get(opts, :storage) do
      nil -> {Conjure.Storage.Local, []}
      {module, opts} -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end
end
```

### Configuration

```elixir
# config/dev.exs - Local development
config :conjure, :storage,
  strategy: Conjure.Storage.Local,
  base_path: System.tmp_dir!(),
  prefix: "conjure"

# config/prod.exs - Fly.io with Tigris (zero-config)
# Credentials auto-injected by Fly.io Machines
config :conjure, :storage,
  strategy: Conjure.Storage.Tigris
  # bucket, endpoint, credentials all from env vars automatically

# config/prod.exs - AWS S3
config :conjure, :storage,
  strategy: Conjure.Storage.S3,
  bucket: System.get_env("S3_BUCKET"),
  region: System.get_env("AWS_REGION", "us-east-1")

# Per-session override always takes precedence
session = Conjure.Session.new_docker(skills,
  storage: {Conjure.Storage.S3, bucket: "custom-bucket"}
)
```

## Consequences

### Positive

1. **Fixes Docker Bug**: Default storage now creates valid temp directories
2. **Multi-Node Support**: S3/Tigris enable shared state across cluster nodes
3. **Fly.io Ready**: First-class Tigris support for Fly.io deployments
4. **Session Persistence**: Storage backends can persist beyond session lifetime
5. **Consumer Integration**: Callbacks enable tight integration with consumer applications
6. **Anthropic File Sync**: Remote files can be captured and persisted client-side
7. **Unified Interface**: All backends use the same storage abstraction
8. **Testable**: Easy to mock storage in tests

### Negative

1. **Complexity**: Adds new abstraction layer and 3+ modules
2. **S3 Dependency**: S3/Tigris implementations need HTTP client (optional dep)
3. **Sync Latency**: Remote storage adds latency vs local filesystem
4. **Local Cache Management**: S3/Tigris need local cache for Docker, adding cleanup complexity

### Neutral

1. **Backwards Compatible**: Default Local storage maintains current behavior (once fixed)
2. **Optional Feature**: Consumers only pay complexity cost if using cloud storage

## File Structure

```
lib/conjure/
├── storage.ex                    # Storage behaviour
├── storage/
│   ├── local.ex                  # Local filesystem (default)
│   ├── s3.ex                     # AWS S3
│   └── tigris.ex                 # Fly.io Tigris
└── session.ex                    # Updated with storage integration
```

## Alternatives Considered

### 1. Docker Volumes Instead of Mounts

Could use Docker volumes for persistence, but:
- Less portable across storage backends
- Harder to access files from host
- Doesn't solve multi-node problem

### 2. Database Storage (Ecto)

Store files directly in PostgreSQL/etc:
- Adds hard Ecto dependency
- Not suitable for large files
- Tighter coupling than callbacks

### 3. GenStage/Broadway for File Events

Use GenStage for file event streaming:
- Overkill for most use cases
- Adds significant complexity
- Simple callbacks sufficient for MVP

## References

- [Tigris Object Storage](https://www.tigrisdata.com/)
- [Fly.io Tigris Integration](https://fly.io/docs/reference/tigris/)
- [AWS S3 API Reference](https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html)
- ADR-0010: Docker Production Executor
- ADR-0020: Backend Behaviour Architecture
