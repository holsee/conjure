defmodule Conjure.Storage.Tigris do
  @moduledoc """
  Fly.io Tigris object storage backend.

  Tigris is Fly.io's globally-distributed, S3-compatible object storage.
  It automatically replicates data to regions close to your Fly Machines,
  providing low-latency access worldwide.

  ## Fly.io Setup

      # Create a Tigris bucket for your Fly app
      fly storage create conjure-sessions

      # Credentials are automatically injected as env vars:
      # - AWS_ACCESS_KEY_ID
      # - AWS_SECRET_ACCESS_KEY
      # - AWS_ENDPOINT_URL_S3
      # - BUCKET_NAME

  ## Options

  * `:bucket` - Bucket name (default: `BUCKET_NAME` env var)
  * `:endpoint` - Tigris endpoint (default: `AWS_ENDPOINT_URL_S3` env var)
  * `:access_key_id` - Access key (default: `AWS_ACCESS_KEY_ID` env var)
  * `:secret_access_key` - Secret key (default: `AWS_SECRET_ACCESS_KEY` env var)
  * `:cache_path` - Local cache directory (default: `FLY_VOLUME_PATH` or tmp_dir)
  * `:region` - Region hint for read affinity (default: `FLY_REGION` env var)
  * `:prefix` - Key prefix for objects (default: `"sessions/"`)
  * `:async_upload` - Upload asynchronously (default: `false`)

  ## Usage

      # On Fly.io - zero config needed
      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: Conjure.Storage.Tigris
      )

      # Local development with Tigris credentials
      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: {Conjure.Storage.Tigris,
          bucket: "dev-sessions",
          endpoint: "https://fly.storage.tigris.dev"
        }
      )

  ## Multi-Region Session Affinity

  Tigris automatically serves data from the nearest region. For debugging
  or session routing, you can include region in the session prefix:

      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: {Conjure.Storage.Tigris,
          prefix: "sessions/\#{System.get_env("FLY_REGION")}/"
        }
      )

  ## See Also

  * `Conjure.Storage` - Storage behaviour
  * `Conjure.Storage.S3` - Generic S3 storage
  * [Tigris Object Storage](https://www.tigrisdata.com/)
  * [Fly.io Tigris Integration](https://fly.io/docs/reference/tigris/)
  """

  @behaviour Conjure.Storage

  alias Conjure.Storage.S3

  defstruct [:s3_state]

  @type t :: %__MODULE__{
          s3_state: S3.t()
        }

  @default_endpoint "https://fly.storage.tigris.dev"

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl Conjure.Storage
  def init(session_id, opts) do
    # Apply Fly.io/Tigris defaults from environment
    tigris_opts = build_tigris_opts(opts)

    case S3.init(session_id, tigris_opts) do
      {:ok, s3_state} ->
        {:ok, %__MODULE__{s3_state: s3_state}}

      error ->
        error
    end
  end

  @impl Conjure.Storage
  def cleanup(%__MODULE__{s3_state: s3}), do: S3.cleanup(s3)

  # ===========================================================================
  # Docker Integration
  # ===========================================================================

  @impl Conjure.Storage
  def local_path(%__MODULE__{s3_state: s3}), do: S3.local_path(s3)

  # ===========================================================================
  # File Operations
  # ===========================================================================

  @impl Conjure.Storage
  def write(%__MODULE__{s3_state: s3}, path, content), do: S3.write(s3, path, content)

  @impl Conjure.Storage
  def read(%__MODULE__{s3_state: s3}, path), do: S3.read(s3, path)

  @impl Conjure.Storage
  def exists?(%__MODULE__{s3_state: s3}, path), do: S3.exists?(s3, path)

  @impl Conjure.Storage
  def delete(%__MODULE__{s3_state: s3}, path), do: S3.delete(s3, path)

  @impl Conjure.Storage
  def list(%__MODULE__{s3_state: s3}), do: S3.list(s3)

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp build_tigris_opts(opts) do
    [
      bucket: get_bucket(opts),
      endpoint: get_endpoint(opts),
      access_key_id: get_access_key(opts),
      secret_access_key: get_secret_key(opts),
      region: get_region(opts),
      cache_path: get_cache_path(opts),
      prefix: Keyword.get(opts, :prefix, "sessions/"),
      async_upload: Keyword.get(opts, :async_upload, false)
    ]
  end

  defp get_bucket(opts) do
    Keyword.get_lazy(opts, :bucket, fn ->
      System.get_env("BUCKET_NAME") ||
        raise """
        BUCKET_NAME not set.

        On Fly.io, run: fly storage create
        For local development, set BUCKET_NAME or pass bucket: option.
        """
    end)
  end

  defp get_endpoint(opts) do
    Keyword.get(opts, :endpoint) ||
      System.get_env("AWS_ENDPOINT_URL_S3") ||
      @default_endpoint
  end

  defp get_access_key(opts) do
    Keyword.get(opts, :access_key_id) ||
      System.get_env("AWS_ACCESS_KEY_ID")
  end

  defp get_secret_key(opts) do
    Keyword.get(opts, :secret_access_key) ||
      System.get_env("AWS_SECRET_ACCESS_KEY")
  end

  defp get_region(opts) do
    Keyword.get(opts, :region) ||
      System.get_env("FLY_REGION") ||
      "auto"
  end

  defp get_cache_path(opts) do
    Keyword.get(opts, :cache_path) ||
      get_fly_volume_path() ||
      System.tmp_dir!()
  end

  defp get_fly_volume_path do
    case System.get_env("FLY_VOLUME_PATH") do
      nil -> nil
      path -> Path.join(path, "conjure_sessions")
    end
  end
end
