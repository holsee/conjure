defmodule Conjure.Skills.Anthropic do
  @moduledoc """
  Upload and manage skills via Anthropic Skills API.

  This module provides helpers for interacting with Anthropic's
  Skills API to upload custom skills and manage versions.

  All functions accept an `api_callback` for HTTP operations,
  following the library's API-agnostic design.

  ## API Callback Format

  The `api_callback` should be a function that makes HTTP requests:

      api_callback = fn method, path, body, opts ->
        # Make HTTP request to Anthropic API
        # Return {:ok, response_body} or {:error, reason}
      end

  ## Example

      # Define your API callback
      api_callback = fn method, path, body, _opts ->
        headers = [
          {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
          {"anthropic-version", "2023-06-01"}
        ] ++ Conjure.API.Anthropic.beta_headers()

        url = "https://api.anthropic.com" <> path

        case method do
          :get -> Req.get(url, headers: headers)
          :post -> Req.post(url, json: body, headers: headers)
          :delete -> Req.delete(url, headers: headers)
        end
        |> case do
          {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
          {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
          {:error, reason} -> {:error, reason}
        end
      end

      # Upload a skill
      {:ok, result} = Conjure.Skills.Anthropic.upload(
        "priv/skills/csv-helper",
        api_callback,
        display_title: "CSV Helper"
      )

      # Use the skill_id in your requests
      skill_id = result.skill_id

  ## References

  * [Anthropic Skills API Guide](https://platform.claude.com/docs/en/build-with-claude/skills-guide)
  """

  alias Conjure.Error

  @type api_callback :: (method :: atom(),
                         path :: String.t(),
                         body :: map() | nil,
                         opts :: keyword() ->
                           {:ok, map()} | {:error, term()})

  @type upload_result :: %{
          skill_id: String.t(),
          version: String.t(),
          display_title: String.t()
        }

  # 8MB
  @max_skill_size 8 * 1024 * 1024

  @doc """
  Upload a skill to Anthropic.

  Accepts either a skill directory or a `.skill` archive file.
  Packages the skill and uploads it to Anthropic's infrastructure.
  Returns the `skill_id` for use in API requests.

  ## Options

  * `:display_title` - Display name for the skill (default: directory/file name)

  ## Example

      # From directory
      {:ok, result} = Conjure.Skills.Anthropic.upload(
        "priv/skills/csv-helper",
        api_callback,
        display_title: "CSV Helper"
      )

      # From .skill file
      {:ok, result} = Conjure.Skills.Anthropic.upload(
        "priv/skills/csv-helper.skill",
        api_callback,
        display_title: "CSV Helper"
      )

      result.skill_id
      # => "skill_01AbCdEfGhIjKlMnOpQrStUv"
  """
  @spec upload(Path.t(), api_callback(), keyword()) ::
          {:ok, upload_result()} | {:error, Error.t()}
  def upload(skill_path, api_callback, opts \\ []) do
    with {:ok, files} <- package_skill(skill_path),
         {:ok, _} <- validate_size(files),
         display_title = Keyword.get(opts, :display_title, Path.basename(skill_path)),
         {:ok, response} <- do_upload(files, display_title, api_callback) do
      {:ok,
       %{
         skill_id: response["id"],
         version: get_in(response, ["versions", Access.at(0), "version"]) || "latest",
         display_title: response["display_title"]
       }}
    end
  end

  @doc """
  List skills available in your Anthropic workspace.

  ## Options

  * `:source` - Filter by source: `:anthropic`, `:custom`, or `:all` (default: `:all`)
  * `:limit` - Maximum number of results (default: 100)

  ## Example

      {:ok, skills} = Conjure.Skills.Anthropic.list(api_callback, source: :custom)

      for skill <- skills do
        IO.puts("\#{skill["display_title"]} (\#{skill["id"]})")
      end
  """
  @spec list(api_callback(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(api_callback, opts \\ []) do
    source = Keyword.get(opts, :source, :all)
    limit = Keyword.get(opts, :limit, 100)

    path = build_list_path(source, limit)

    case api_callback.(:get, path, nil, opts) do
      {:ok, %{"data" => skills}} ->
        {:ok, skills}

      {:ok, response} when is_list(response) ->
        {:ok, response}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  @doc """
  Get details about a specific skill.

  ## Example

      {:ok, skill} = Conjure.Skills.Anthropic.get("skill_01AbCdEf", api_callback)
      skill["display_title"]
  """
  @spec get(String.t(), api_callback(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(skill_id, api_callback, opts \\ []) do
    path = "/v1/skills/#{skill_id}"

    case api_callback.(:get, path, nil, opts) do
      {:ok, skill} ->
        {:ok, skill}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  @doc """
  Delete a custom skill from Anthropic.

  Note: You must delete all versions first before deleting the skill.

  ## Example

      # Delete all versions first
      {:ok, versions} = list_versions(skill_id, api_callback)
      for v <- versions, do: delete_version(skill_id, v["version"], api_callback)

      # Then delete the skill
      :ok = Conjure.Skills.Anthropic.delete(skill_id, api_callback)
  """
  @spec delete(String.t(), api_callback(), keyword()) :: :ok | {:error, Error.t()}
  def delete(skill_id, api_callback, opts \\ []) do
    path = "/v1/skills/#{skill_id}"

    case api_callback.(:delete, path, nil, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  @doc """
  Create a new version of an existing skill.

  ## Example

      {:ok, result} = Conjure.Skills.Anthropic.create_version(
        "skill_01AbCdEf",
        "priv/skills/csv-helper",
        api_callback
      )

      result.version
      # => "v2"
  """
  @spec create_version(String.t(), Path.t(), api_callback(), keyword()) ::
          {:ok, %{version: String.t()}} | {:error, Error.t()}
  def create_version(skill_id, skill_path, api_callback, opts \\ []) do
    with {:ok, files} <- package_skill(skill_path),
         {:ok, _} <- validate_size(files),
         {:ok, response} <- do_create_version(skill_id, files, api_callback, opts) do
      {:ok, %{version: response["version"]}}
    end
  end

  @doc """
  List versions of a skill.

  ## Example

      {:ok, versions} = Conjure.Skills.Anthropic.list_versions("skill_01AbCdEf", api_callback)

      for v <- versions do
        IO.puts("Version \#{v["version"]} created at \#{v["created_at"]}")
      end
  """
  @spec list_versions(String.t(), api_callback(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def list_versions(skill_id, api_callback, opts \\ []) do
    path = "/v1/skills/#{skill_id}/versions"

    case api_callback.(:get, path, nil, opts) do
      {:ok, %{"data" => versions}} ->
        {:ok, versions}

      {:ok, versions} when is_list(versions) ->
        {:ok, versions}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  @doc """
  Delete a specific version of a skill.

  ## Example

      :ok = Conjure.Skills.Anthropic.delete_version("skill_01AbCdEf", "v1", api_callback)
  """
  @spec delete_version(String.t(), String.t(), api_callback(), keyword()) ::
          :ok | {:error, Error.t()}
  def delete_version(skill_id, version, api_callback, opts \\ []) do
    path = "/v1/skills/#{skill_id}/versions/#{version}"

    case api_callback.(:delete, path, nil, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  @doc """
  Package a skill directory or .skill file for upload.

  Accepts either:
  - A directory path containing SKILL.md and skill files
  - A `.skill` archive file (will be extracted automatically)

  Returns a list of `{relative_path, content}` tuples.

  ## Example

      # From directory
      {:ok, files} = Conjure.Skills.Anthropic.package_skill("priv/skills/csv-helper")

      # From .skill file
      {:ok, files} = Conjure.Skills.Anthropic.package_skill("priv/skills/csv-helper.skill")

      for {path, content} <- files do
        IO.puts("File: \#{path} (\#{byte_size(content)} bytes)")
      end
  """
  @spec package_skill(Path.t()) :: {:ok, [{String.t(), binary()}]} | {:error, Error.t()}
  def package_skill(skill_path) do
    expanded_path = Path.expand(skill_path)

    cond do
      skill_file?(expanded_path) -> package_skill_file(expanded_path)
      File.dir?(expanded_path) -> package_skill_dir(expanded_path, skill_path)
      true -> {:error, Error.file_not_found(skill_path)}
    end
  end

  defp skill_file?(path) do
    String.ends_with?(path, ".skill") and File.regular?(path)
  end

  defp package_skill_file(skill_file) do
    case Conjure.Loader.load_skill_file(skill_file) do
      {:ok, skill} ->
        files = collect_files_with_prefix(skill.path, skill.name)
        {:ok, files}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp package_skill_dir(dir_path, original_path) do
    skill_md = Path.join(dir_path, "SKILL.md")

    if File.exists?(skill_md) do
      root_dir = extract_skill_name(skill_md) || Path.basename(dir_path)
      files = collect_files_with_prefix(dir_path, root_dir)
      {:ok, files}
    else
      {:error, Error.invalid_skill_structure(original_path, "SKILL.md not found")}
    end
  end

  @doc """
  Calculate the total size of packaged skill files.
  """
  @spec package_size([{String.t(), binary()}]) :: non_neg_integer()
  def package_size(files) do
    Enum.reduce(files, 0, fn {_path, content}, acc ->
      acc + byte_size(content)
    end)
  end

  # Private functions

  defp collect_files_with_prefix(base_path, root_dir) do
    base_path
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn file_path ->
      relative_path = Path.relative_to(file_path, base_path)
      # Prefix with root directory as required by Anthropic API
      prefixed_path = Path.join(root_dir, relative_path)
      content = File.read!(file_path)
      {prefixed_path, content}
    end)
  end

  defp extract_skill_name(skill_md_path) do
    # Read the SKILL.md and extract the name from YAML frontmatter
    with {:ok, content} <- File.read(skill_md_path),
         [_, yaml] <- Regex.run(~r/^---\n(.*?)\n---/s, content),
         [_, name] <- Regex.run(~r/^name:\s*(.+)$/m, yaml) do
      String.trim(name)
    else
      _ -> nil
    end
  end

  defp validate_size(files) do
    size = package_size(files)

    if size > @max_skill_size do
      {:error,
       Error.skill_upload_failed("skill", "exceeds maximum size of 8MB (size: #{size} bytes)")}
    else
      {:ok, size}
    end
  end

  defp do_upload(files, display_title, api_callback) do
    # Build multipart body for skill upload
    # The API expects files as multipart form data with files[] field
    multipart =
      [{"display_title", display_title}] ++
        Enum.map(files, fn {path, content} ->
          {"files[]", {path, content}}
        end)

    case api_callback.(:post, "/v1/skills", multipart, multipart: true) do
      {:ok, response} ->
        {:ok, response}

      {:error, {:api_error, status, error}} ->
        message = get_in(error, ["error", "message"]) || inspect(error)
        {:error, Error.anthropic_api_error(status, message, error)}

      {:error, reason} ->
        {:error, Error.skill_upload_failed("skill", reason)}
    end
  end

  defp do_create_version(skill_id, files, api_callback, _opts) do
    # Build multipart body for version creation
    multipart =
      Enum.map(files, fn {path, content} ->
        {"files[]", {path, content}}
      end)

    path = "/v1/skills/#{skill_id}/versions"

    case api_callback.(:post, path, multipart, multipart: true) do
      {:ok, response} ->
        {:ok, response}

      {:error, {:api_error, status, error}} ->
        message = get_in(error, ["error", "message"]) || inspect(error)
        {:error, Error.anthropic_api_error(status, message, error)}

      {:error, reason} ->
        {:error, Error.skill_upload_failed(skill_id, reason)}
    end
  end

  defp build_list_path(:all, limit), do: "/v1/skills?limit=#{limit}"
  defp build_list_path(:anthropic, limit), do: "/v1/skills?source=anthropic&limit=#{limit}"
  defp build_list_path(:custom, limit), do: "/v1/skills?source=custom&limit=#{limit}"
end
