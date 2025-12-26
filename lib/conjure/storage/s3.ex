defmodule Conjure.Storage.S3 do
  @moduledoc """
  AWS S3 storage backend.

  Provides durable storage with a local cache for Docker mounting.
  Requires the optional `req` dependency.

  ## Options

  * `:bucket` - S3 bucket name (required)
  * `:region` - AWS region (default: `"us-east-1"`)
  * `:prefix` - Key prefix for all objects (default: `"sessions/"`)
  * `:access_key_id` - AWS access key (default: from `AWS_ACCESS_KEY_ID` env)
  * `:secret_access_key` - AWS secret key (default: from `AWS_SECRET_ACCESS_KEY` env)
  * `:endpoint` - Custom S3 endpoint URL (for S3-compatible services)
  * `:cache_path` - Local cache directory (default: `System.tmp_dir!()`)
  * `:async_upload` - Upload to S3 asynchronously (default: `false`)

  ## Example

      # AWS S3
      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: {Conjure.Storage.S3,
          bucket: "my-sessions",
          region: "us-west-2"
        }
      )

      # S3-compatible service (MinIO, LocalStack)
      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: {Conjure.Storage.S3,
          bucket: "test-bucket",
          endpoint: "http://localhost:9000",
          access_key_id: "minioadmin",
          secret_access_key: "minioadmin"
        }
      )

  ## See Also

  * `Conjure.Storage` - Storage behaviour
  * `Conjure.Storage.Tigris` - Fly.io Tigris storage
  * `Conjure.Storage.AwsSigV4` - AWS Signature V4 signing
  """

  @behaviour Conjure.Storage

  alias Conjure.Storage.AwsSigV4

  require Logger

  defstruct [
    :bucket,
    :prefix,
    :region,
    :endpoint,
    :host,
    :access_key_id,
    :secret_access_key,
    :cache_path,
    :session_id,
    :async_upload
  ]

  @type t :: %__MODULE__{
          bucket: String.t(),
          prefix: String.t(),
          region: String.t(),
          endpoint: String.t(),
          host: String.t(),
          access_key_id: String.t(),
          secret_access_key: String.t(),
          cache_path: Path.t(),
          session_id: String.t(),
          async_upload: boolean()
        }

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl Conjure.Storage
  def init(session_id, opts) do
    with :ok <- ensure_req_available() do
      bucket = Keyword.fetch!(opts, :bucket)
      region = Keyword.get(opts, :region, "us-east-1")
      prefix = Keyword.get(opts, :prefix, "sessions/")

      access_key_id =
        Keyword.get(opts, :access_key_id) ||
          System.get_env("AWS_ACCESS_KEY_ID") ||
          raise "AWS_ACCESS_KEY_ID not configured"

      secret_access_key =
        Keyword.get(opts, :secret_access_key) ||
          System.get_env("AWS_SECRET_ACCESS_KEY") ||
          raise "AWS_SECRET_ACCESS_KEY not configured"

      default_endpoint = "https://s3.#{region}.amazonaws.com"
      endpoint = Keyword.get(opts, :endpoint, default_endpoint)
      host = URI.parse(endpoint).host

      # Local cache for Docker mounting
      cache_base = Keyword.get(opts, :cache_path, System.tmp_dir!())
      cache_path = Path.join(cache_base, "conjure_s3_#{session_id}")

      case File.mkdir_p(cache_path) do
        :ok ->
          state = %__MODULE__{
            bucket: bucket,
            prefix: "#{prefix}#{session_id}/",
            region: region,
            endpoint: endpoint,
            host: host,
            access_key_id: access_key_id,
            secret_access_key: secret_access_key,
            cache_path: cache_path,
            session_id: session_id,
            async_upload: Keyword.get(opts, :async_upload, false)
          }

          emit_telemetry(:init, session_id)
          {:ok, state}

        {:error, reason} ->
          {:error, {:cache_mkdir_failed, cache_path, reason}}
      end
    end
  end

  @impl Conjure.Storage
  def cleanup(%__MODULE__{} = state) do
    # Delete all objects with prefix from S3
    case delete_prefix(state) do
      {:ok, count} ->
        # Cleanup local cache
        File.rm_rf!(state.cache_path)
        emit_telemetry(:cleanup, state.session_id, count)
        :ok

      {:error, reason} ->
        {:error, {:s3_cleanup_failed, reason}}
    end
  end

  # ===========================================================================
  # Docker Integration
  # ===========================================================================

  @impl Conjure.Storage
  def local_path(%__MODULE__{cache_path: path}), do: {:ok, path}

  # ===========================================================================
  # File Operations
  # ===========================================================================

  @impl Conjure.Storage
  def write(%__MODULE__{} = state, path, content) do
    start_time = System.monotonic_time()

    # Write to local cache first (sync)
    local_file = Path.join(state.cache_path, path)

    with :ok <- File.mkdir_p(Path.dirname(local_file)),
         :ok <- File.write(local_file, content) do
      # Upload to S3
      s3_key = "#{state.prefix}#{path}"

      upload_fn = fn -> put_object(state, s3_key, content) end

      if state.async_upload do
        Task.start(upload_fn)
        file_ref = build_file_ref(state, path, content)
        emit_telemetry(:write, state, path, byte_size(content), start_time)
        {:ok, file_ref}
      else
        case upload_fn.() do
          :ok ->
            file_ref = build_file_ref(state, path, content)
            emit_telemetry(:write, state, path, byte_size(content), start_time)
            {:ok, file_ref}

          {:error, reason} ->
            {:error, {:s3_upload_failed, path, reason}}
        end
      end
    else
      {:error, reason} ->
        {:error, {:cache_write_failed, path, reason}}
    end
  end

  @impl Conjure.Storage
  def read(%__MODULE__{} = state, path) do
    start_time = System.monotonic_time()
    local_file = Path.join(state.cache_path, path)

    # Try local cache first
    case File.read(local_file) do
      {:ok, content} ->
        emit_telemetry(:read, state, path, byte_size(content), start_time)
        {:ok, content}

      {:error, :enoent} ->
        # Fetch from S3
        s3_key = "#{state.prefix}#{path}"

        case get_object(state, s3_key) do
          {:ok, content} ->
            # Cache locally
            File.mkdir_p!(Path.dirname(local_file))
            File.write!(local_file, content)
            emit_telemetry(:read, state, path, byte_size(content), start_time)
            {:ok, content}

          {:error, :not_found} ->
            {:error, {:file_not_found, path}}

          {:error, reason} ->
            {:error, {:s3_read_failed, path, reason}}
        end

      {:error, reason} ->
        {:error, {:cache_read_failed, path, reason}}
    end
  end

  @impl Conjure.Storage
  def exists?(%__MODULE__{} = state, path) do
    local_file = Path.join(state.cache_path, path)

    if File.exists?(local_file) do
      true
    else
      s3_key = "#{state.prefix}#{path}"

      case head_object(state, s3_key) do
        :ok -> true
        _ -> false
      end
    end
  end

  @impl Conjure.Storage
  def delete(%__MODULE__{} = state, path) do
    start_time = System.monotonic_time()

    # Delete from local cache
    local_file = Path.join(state.cache_path, path)
    File.rm(local_file)

    # Delete from S3
    s3_key = "#{state.prefix}#{path}"

    case delete_object(state, s3_key) do
      :ok ->
        emit_telemetry(:delete, state, path, start_time)
        :ok

      {:error, reason} ->
        {:error, {:s3_delete_failed, path, reason}}
    end
  end

  @impl Conjure.Storage
  def list(%__MODULE__{} = state) do
    case list_objects(state) do
      {:ok, objects} ->
        file_refs =
          Enum.map(objects, fn obj ->
            rel_path = String.replace_prefix(obj.key, state.prefix, "")

            %{
              path: rel_path,
              size: obj.size,
              content_type: Conjure.Storage.guess_content_type(rel_path),
              checksum: obj.etag,
              storage_url: s3_url(state, rel_path),
              created_at: obj.last_modified || DateTime.utc_now()
            }
          end)

        {:ok, file_refs}

      {:error, reason} ->
        {:error, {:s3_list_failed, reason}}
    end
  end

  # ===========================================================================
  # S3 API Operations
  # ===========================================================================

  defp put_object(state, key, content) do
    url = "#{state.endpoint}/#{state.bucket}/#{key}"

    headers =
      AwsSigV4.sign(
        method: :put,
        host: state.host,
        path: "/#{state.bucket}/#{key}",
        payload: content,
        region: state.region,
        access_key: state.access_key_id,
        secret_key: state.secret_access_key
      )

    case Req.put(url, body: content, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:s3_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_object(state, key) do
    url = "#{state.endpoint}/#{state.bucket}/#{key}"

    headers =
      AwsSigV4.sign(
        method: :get,
        host: state.host,
        path: "/#{state.bucket}/#{key}",
        region: state.region,
        access_key: state.access_key_id,
        secret_key: state.secret_access_key
      )

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:s3_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp head_object(state, key) do
    url = "#{state.endpoint}/#{state.bucket}/#{key}"

    headers =
      AwsSigV4.sign(
        method: :head,
        host: state.host,
        path: "/#{state.bucket}/#{key}",
        region: state.region,
        access_key: state.access_key_id,
        secret_key: state.secret_access_key
      )

    case Req.head(url, headers: headers) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:s3_error, status, nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_object(state, key) do
    url = "#{state.endpoint}/#{state.bucket}/#{key}"

    headers =
      AwsSigV4.sign(
        method: :delete,
        host: state.host,
        path: "/#{state.bucket}/#{key}",
        region: state.region,
        access_key: state.access_key_id,
        secret_key: state.secret_access_key
      )

    case Req.delete(url, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:s3_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_objects(state) do
    query = "list-type=2&prefix=#{URI.encode(state.prefix)}"
    url = "#{state.endpoint}/#{state.bucket}?#{query}"

    headers =
      AwsSigV4.sign(
        method: :get,
        host: state.host,
        path: "/#{state.bucket}",
        query: query,
        region: state.region,
        access_key: state.access_key_id,
        secret_key: state.secret_access_key
      )

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        objects = parse_list_objects_response(body)
        {:ok, objects}

      {:ok, %{status: status, body: body}} ->
        {:error, {:s3_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_prefix(state) do
    case list_objects(state) do
      {:ok, objects} ->
        Enum.each(objects, fn obj ->
          delete_object(state, obj.key)
        end)

        {:ok, length(objects)}

      error ->
        error
    end
  end

  defp parse_list_objects_response(xml_body) when is_binary(xml_body) do
    # Simple XML parsing for S3 ListObjectsV2 response
    # Extract <Key>, <Size> from each <Contents>
    Regex.scan(
      ~r/<Contents>.*?<Key>(.*?)<\/Key>.*?<Size>(\d+)<\/Size>.*?<\/Contents>/s,
      xml_body
    )
    |> Enum.map(fn [_, key, size] ->
      %{
        key: key,
        size: String.to_integer(size),
        etag: nil,
        last_modified: nil
      }
    end)
  end

  defp parse_list_objects_response(_), do: []

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp ensure_req_available do
    if Code.ensure_loaded?(Req) do
      :ok
    else
      {:error,
       "Conjure.Storage.S3 requires the :req dependency. Add {:req, \"~> 0.5\"} to your mix.exs"}
    end
  end

  defp build_file_ref(state, path, content) do
    Conjure.Storage.build_file_ref(path, content, storage_url: s3_url(state, path))
  end

  defp s3_url(state, path) do
    "#{state.endpoint}/#{state.bucket}/#{state.prefix}#{path}"
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

  defp emit_telemetry(:write, state, path, size, start_time) do
    :telemetry.execute(
      [:conjure, :storage, :write],
      %{duration: System.monotonic_time() - start_time, size: size},
      %{strategy: __MODULE__, session_id: state.session_id, path: path}
    )
  end

  defp emit_telemetry(:read, state, path, size, start_time) do
    :telemetry.execute(
      [:conjure, :storage, :read],
      %{duration: System.monotonic_time() - start_time, size: size},
      %{strategy: __MODULE__, session_id: state.session_id, path: path}
    )
  end

  defp emit_telemetry(:delete, state, path, start_time) do
    :telemetry.execute(
      [:conjure, :storage, :delete],
      %{duration: System.monotonic_time() - start_time},
      %{strategy: __MODULE__, session_id: state.session_id, path: path}
    )
  end
end
