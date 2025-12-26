defmodule Conjure.Files.Anthropic do
  @moduledoc """
  Download files created by Anthropic Skills via the Files API.

  Skills that create documents (xlsx, pptx, pdf) include file references
  in the response. This module provides functions to download and manage
  those files.

  ## API Callback Format

  All functions accept an `api_callback` for HTTP operations:

      api_callback = fn method, path, body, opts ->
        # Make HTTP request to Anthropic API
        # Return {:ok, response_body} or {:error, reason}
      end

  ## Example

      # Extract file IDs from response
      file_ids = Conjure.API.Anthropic.extract_file_ids(response)

      # Download each file
      for file_id <- file_ids do
        {:ok, content, filename} = Conjure.Files.Anthropic.download(
          file_id,
          api_callback
        )

        File.write!(filename, content)
      end

  ## References

  * [Files API Documentation](https://docs.anthropic.com/en/api/files-content)
  """

  alias Conjure.API.Anthropic, as: API
  alias Conjure.Error

  @type api_callback :: (method :: atom(),
                         path :: String.t(),
                         body :: map() | nil,
                         opts :: keyword() ->
                           {:ok, map() | binary()} | {:error, term()})

  @type file_metadata :: %{
          id: String.t(),
          filename: String.t(),
          size_bytes: non_neg_integer(),
          created_at: String.t(),
          purpose: String.t()
        }

  @doc """
  Extract file IDs from an API response.

  Delegates to `Conjure.API.Anthropic.extract_file_ids/1`.

  ## Example

      file_ids = Conjure.Files.Anthropic.extract_file_ids(response)
      # => ["file_abc123", "file_def456"]
  """
  @spec extract_file_ids(map()) :: [String.t()]
  defdelegate extract_file_ids(response), to: API

  @doc """
  Get metadata about a file.

  Returns file information including filename, size, and creation time.

  ## Example

      {:ok, metadata} = Conjure.Files.Anthropic.metadata("file_abc123", api_callback)

      metadata.filename
      # => "budget_2024.xlsx"

      metadata.size_bytes
      # => 15234
  """
  @spec metadata(String.t(), api_callback(), keyword()) ::
          {:ok, file_metadata()} | {:error, Error.t()}
  def metadata(file_id, api_callback, opts \\ []) do
    path = "/v1/files/#{file_id}"

    case api_callback.(:get, path, nil, opts) do
      {:ok, response} when is_map(response) ->
        {:ok,
         %{
           id: response["id"],
           filename: response["filename"],
           size_bytes: response["size_bytes"],
           created_at: response["created_at"],
           purpose: response["purpose"]
         }}

      {:error, {:api_error, 404, _}} ->
        {:error, Error.file_download_failed(file_id, "file not found")}

      {:error, reason} ->
        {:error, Error.file_download_failed(file_id, reason)}
    end
  end

  @doc """
  Download file content.

  Returns the file content as binary data along with the filename.

  ## Example

      {:ok, content, filename} = Conjure.Files.Anthropic.download(
        "file_abc123",
        api_callback
      )

      File.write!(filename, content)
  """
  @spec download(String.t(), api_callback(), keyword()) ::
          {:ok, binary(), String.t()} | {:error, Error.t()}
  def download(file_id, api_callback, opts \\ []) do
    # First get metadata to get the filename
    with {:ok, meta} <- metadata(file_id, api_callback, opts),
         {:ok, content} <- download_content(file_id, api_callback, opts) do
      {:ok, content, meta.filename}
    end
  end

  @doc """
  Download file content only (without metadata).

  Use this if you already know the filename or don't need it.

  ## Example

      {:ok, content} = Conjure.Files.Anthropic.download_content(
        "file_abc123",
        api_callback
      )
  """
  @spec download_content(String.t(), api_callback(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def download_content(file_id, api_callback, opts \\ []) do
    path = "/v1/files/#{file_id}/content"

    case api_callback.(:get, path, nil, opts) do
      {:ok, content} when is_binary(content) ->
        {:ok, content}

      {:ok, %{"content" => content}} when is_binary(content) ->
        # Some responses might wrap content
        {:ok, content}

      {:error, {:api_error, 404, _}} ->
        {:error, Error.file_download_failed(file_id, "file not found")}

      {:error, reason} ->
        {:error, Error.file_download_failed(file_id, reason)}
    end
  end

  @doc """
  Download a file and save it to disk.

  ## Options

  * `:overwrite` - Overwrite existing file (default: false)

  ## Example

      {:ok, path} = Conjure.Files.Anthropic.download_to_file(
        "file_abc123",
        "/tmp/downloads",
        api_callback
      )

      # path => "/tmp/downloads/budget_2024.xlsx"
  """
  @spec download_to_file(String.t(), Path.t(), api_callback(), keyword()) ::
          {:ok, Path.t()} | {:error, Error.t()}
  def download_to_file(file_id, directory, api_callback, opts \\ []) do
    with {:ok, content, filename} <- download(file_id, api_callback, opts),
         :ok <- ensure_directory(directory),
         file_path = Path.join(directory, filename),
         :ok <- maybe_check_exists(file_path, opts),
         :ok <- File.write(file_path, content) do
      {:ok, file_path}
    else
      {:error, :exists} ->
        {:error, Error.file_download_failed(file_id, "file already exists")}

      {:error, reason} when is_atom(reason) ->
        {:error, Error.file_download_failed(file_id, reason)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Delete a file from Anthropic.

  ## Example

      :ok = Conjure.Files.Anthropic.delete("file_abc123", api_callback)
  """
  @spec delete(String.t(), api_callback(), keyword()) :: :ok | {:error, Error.t()}
  def delete(file_id, api_callback, opts \\ []) do
    path = "/v1/files/#{file_id}"

    case api_callback.(:delete, path, nil, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, Error.file_download_failed(file_id, reason)}
    end
  end

  @doc """
  List files in your Anthropic account.

  ## Options

  * `:limit` - Maximum number of files to return (default: 100)
  * `:purpose` - Filter by purpose

  ## Example

      {:ok, files} = Conjure.Files.Anthropic.list(api_callback)

      for file <- files do
        IO.puts("\#{file["filename"]} (\#{file["size_bytes"]} bytes)")
      end
  """
  @spec list(api_callback(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(api_callback, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    path = "/v1/files?limit=#{limit}"

    path =
      case Keyword.get(opts, :purpose) do
        nil -> path
        purpose -> path <> "&purpose=#{purpose}"
      end

    case api_callback.(:get, path, nil, opts) do
      {:ok, %{"data" => files}} ->
        {:ok, files}

      {:ok, files} when is_list(files) ->
        {:ok, files}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  @doc """
  Download multiple files to a directory.

  Returns a list of results for each file.

  ## Example

      file_ids = ["file_abc", "file_def"]

      results = Conjure.Files.Anthropic.download_all(
        file_ids,
        "/tmp/downloads",
        api_callback
      )

      for {file_id, result} <- Enum.zip(file_ids, results) do
        case result do
          {:ok, path} -> IO.puts("Downloaded: \#{path}")
          {:error, error} -> IO.puts("Failed \#{file_id}: \#{error.message}")
        end
      end
  """
  @spec download_all([String.t()], Path.t(), api_callback(), keyword()) ::
          [{:ok, Path.t()} | {:error, Error.t()}]
  def download_all(file_ids, directory, api_callback, opts \\ []) do
    Enum.map(file_ids, fn file_id ->
      download_to_file(file_id, directory, api_callback, opts)
    end)
  end

  # Private functions

  defp ensure_directory(directory) do
    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_check_exists(file_path, opts) do
    if Keyword.get(opts, :overwrite, false) do
      :ok
    else
      if File.exists?(file_path) do
        {:error, :exists}
      else
        :ok
      end
    end
  end
end
