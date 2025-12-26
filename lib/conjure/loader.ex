defmodule Conjure.Loader do
  @moduledoc """
  Handles loading and parsing of skills from the filesystem.

  The loader is responsible for:
  - Scanning directories for SKILL.md files
  - Parsing YAML frontmatter from skill files
  - Loading skill metadata without loading full content (progressive disclosure)
  - Extracting and loading .skill packages (ZIP format)
  - Validating skill structure

  ## Progressive Disclosure

  By default, loading only parses the frontmatter (metadata). The body
  content is loaded on-demand when requested or when Claude reads the
  file via the view tool.

  ## Example

      # Scan and load skills from a directory
      {:ok, skills} = Conjure.Loader.scan_and_load("/path/to/skills")

      # Load a single skill
      {:ok, skill} = Conjure.Loader.load_skill("/path/to/my-skill")

      # Load body content for a skill
      {:ok, skill_with_body} = Conjure.Loader.load_body(skill)
  """

  alias Conjure.{Error, Frontmatter, Skill}

  require Logger

  @frontmatter_regex ~r/\A---\r?\n(.+?)\r?\n---\r?\n?(.*)/s
  @skill_md "SKILL.md"

  @doc """
  Scans a directory for skills and loads them.

  Returns a list of loaded skills with metadata only (bodies not loaded).
  """
  @spec scan_and_load(Path.t()) :: {:ok, [Skill.t()]} | {:error, Error.t()}
  def scan_and_load(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      skills =
        expanded
        |> scan_directory()
        |> Enum.map(&load_skill/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, skill} -> skill end)

      {:ok, skills}
    else
      {:error, Error.file_not_found(path)}
    end
  end

  @doc """
  Scans a directory for skill directories (those containing SKILL.md).

  Returns a list of paths to skill directories.
  """
  @spec scan_directory(Path.t()) :: [Path.t()]
  def scan_directory(path) do
    expanded = Path.expand(path)

    # Check if the path itself is a skill
    if skill_directory?(expanded) do
      [expanded]
    else
      # Scan subdirectories for skills
      expanded
      |> File.ls!()
      |> Enum.map(&Path.join(expanded, &1))
      |> Enum.filter(fn path -> File.dir?(path) and skill_directory?(path) end)
    end
  rescue
    _ -> []
  end

  @doc """
  Loads a skill from a directory path.

  Returns the skill with metadata loaded but body not loaded.
  """
  @spec load_skill(Path.t()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def load_skill(path) do
    expanded = Path.expand(path)
    skill_md_path = Path.join(expanded, @skill_md)

    with :ok <- validate_skill_directory(expanded),
         {:ok, content} <- read_file(skill_md_path),
         {:ok, frontmatter, _body} <- parse_frontmatter(content),
         resources <- scan_resources(expanded) do
      skill = %Skill{
        name: frontmatter.name,
        description: frontmatter.description,
        path: expanded,
        license: frontmatter.license,
        version: frontmatter.version,
        compatibility: frontmatter.compatibility,
        allowed_tools: frontmatter.allowed_tools,
        metadata: frontmatter.extra,
        body: nil,
        body_loaded: false,
        resources: resources
      }

      {:ok, skill}
    end
  end

  @doc """
  Loads the body content for a skill.

  Returns a new skill struct with body loaded.
  """
  @spec load_body(Skill.t()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def load_body(%Skill{body_loaded: true} = skill), do: {:ok, skill}

  def load_body(%Skill{path: path} = skill) do
    skill_md_path = Path.join(path, @skill_md)

    with {:ok, content} <- read_file(skill_md_path),
         {:ok, _frontmatter, body} <- parse_frontmatter(content) do
      {:ok, %{skill | body: body, body_loaded: true}}
    end
  end

  @doc """
  Loads a .skill package file (ZIP format).

  Extracts to a temporary directory and loads the skill.
  """
  @spec load_skill_file(Path.t()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def load_skill_file(path) do
    expanded = Path.expand(path)

    with :ok <- validate_file_exists(expanded),
         {:ok, extract_path} <- extract_skill_file(expanded) do
      load_skill(extract_path)
    end
  end

  @doc """
  Extracts a .skill file (ZIP) to a temporary directory.

  Returns the path to the extracted skill directory.
  """
  @spec extract_skill_file(Path.t()) :: {:ok, Path.t()} | {:error, Error.t()}
  def extract_skill_file(path) do
    temp_dir = System.tmp_dir!()
    extract_base = Path.join(temp_dir, "conjure_#{:erlang.phash2(path)}")

    # Clean up any existing extraction
    File.rm_rf(extract_base)
    File.mkdir_p!(extract_base)

    case :zip.unzip(String.to_charlist(path), [{:cwd, String.to_charlist(extract_base)}]) do
      {:ok, _files} ->
        # Ensure files are readable (for Docker execution with different UID)
        fix_permissions(extract_base)
        # Find the skill directory (might be nested)
        find_skill_in_extracted(extract_base)

      {:error, reason} ->
        {:error, Error.zip_error(path, reason)}
    end
  end

  @doc """
  Parses YAML frontmatter from SKILL.md content.

  Returns the parsed frontmatter and the remaining body.
  """
  @spec parse_frontmatter(String.t()) ::
          {:ok, Frontmatter.t(), String.t()} | {:error, Error.t()}
  def parse_frontmatter(content) do
    with [_, yaml, body] <- Regex.run(@frontmatter_regex, content),
         {:ok, map} <- YamlElixir.read_from_string(yaml),
         {:ok, frontmatter} <- Frontmatter.from_map(map) do
      {:ok, frontmatter, String.trim(body)}
    else
      nil -> {:error, Error.invalid_frontmatter("SKILL.md", "no frontmatter found")}
      {:error, reason} -> {:error, Error.invalid_frontmatter("SKILL.md", reason)}
    end
  end

  @doc """
  Validates a skill's structure and metadata.
  """
  @spec validate(Skill.t()) :: :ok | {:error, [String.t()]}
  def validate(%Skill{} = skill) do
    errors =
      []
      |> validate_name(skill)
      |> validate_description(skill)
      |> validate_path(skill)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Reads a resource file from a skill.
  """
  @spec read_resource(Skill.t(), Path.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def read_resource(%Skill{path: skill_path} = skill, relative_path) do
    # Validate the resource exists
    if Skill.has_resource?(skill, relative_path) do
      full_path = Path.join(skill_path, relative_path)
      read_file(full_path)
    else
      {:error, Error.file_not_found(relative_path)}
    end
  end

  # Private functions

  defp skill_directory?(path) do
    File.exists?(Path.join(path, @skill_md))
  end

  defp validate_skill_directory(path) do
    skill_md_path = Path.join(path, @skill_md)

    cond do
      not File.dir?(path) ->
        {:error, Error.file_not_found(path)}

      not File.exists?(skill_md_path) ->
        {:error, Error.invalid_skill_structure(path, "missing SKILL.md")}

      true ->
        :ok
    end
  end

  defp validate_file_exists(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, Error.file_not_found(path)}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, Error.file_not_found(path)}

      {:error, :eacces} ->
        {:error, Error.permission_denied(path)}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp scan_resources(skill_path) do
    %{
      scripts: scan_resource_dir(skill_path, "scripts"),
      references: scan_resource_dir(skill_path, "references"),
      assets: scan_resource_dir(skill_path, "assets"),
      other: scan_other_files(skill_path)
    }
  end

  defp scan_resource_dir(skill_path, subdir) do
    dir_path = Path.join(skill_path, subdir)

    if File.dir?(dir_path) do
      dir_path
      |> File.ls!()
      |> Enum.map(&Path.join(subdir, &1))
    else
      []
    end
  rescue
    _ -> []
  end

  defp scan_other_files(skill_path) do
    known_dirs = [@skill_md, "scripts", "references", "assets"]

    skill_path
    |> File.ls!()
    |> Enum.filter(fn file ->
      file not in known_dirs and File.regular?(Path.join(skill_path, file))
    end)
  rescue
    _ -> []
  end

  defp find_skill_in_extracted(base_path) do
    # First check if SKILL.md is at the root
    if File.exists?(Path.join(base_path, @skill_md)) do
      {:ok, base_path}
    else
      # Check one level deep (common for zipped directories)
      find_nested_skill(base_path)
    end
  end

  defp find_nested_skill(base_path) do
    case File.ls(base_path) do
      {:ok, [single_dir]} ->
        nested_path = Path.join(base_path, single_dir)
        check_nested_skill_path(base_path, nested_path)

      {:ok, _files} ->
        {:error, Error.invalid_skill_structure(base_path, "no SKILL.md found in package")}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp check_nested_skill_path(base_path, nested_path) do
    if File.dir?(nested_path) and File.exists?(Path.join(nested_path, @skill_md)) do
      {:ok, nested_path}
    else
      {:error, Error.invalid_skill_structure(base_path, "no SKILL.md found in package")}
    end
  end

  defp validate_name(errors, %Skill{name: name}) do
    if is_binary(name) and String.length(name) > 0 do
      errors
    else
      ["name is required" | errors]
    end
  end

  defp validate_description(errors, %Skill{description: desc}) do
    if is_binary(desc) and String.length(desc) > 0 do
      errors
    else
      ["description is required" | errors]
    end
  end

  defp validate_path(errors, %Skill{path: path}) do
    if File.dir?(path) do
      errors
    else
      ["skill path does not exist: #{path}" | errors]
    end
  end

  defp fix_permissions(path) do
    # Make all files and directories readable for Docker execution
    # Directories need 755, files need 644
    System.cmd("chmod", ["-R", "a+rX", path], stderr_to_stdout: true)
    :ok
  end
end
