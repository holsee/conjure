defmodule Conjure.Skill do
  @moduledoc """
  Represents a loaded Agent Skill.

  A skill contains metadata parsed from SKILL.md frontmatter, along with
  information about available resources (scripts, references, assets).

  ## Fields

  * `:name` - Unique identifier for the skill (lowercase, alphanumeric with hyphens)
  * `:description` - Comprehensive description including usage triggers
  * `:path` - Absolute path to the skill directory
  * `:license` - License identifier (e.g., "MIT", "Apache-2.0")
  * `:version` - Semantic version string
  * `:compatibility` - Map of environment requirements
  * `:allowed_tools` - List of tools this skill may use
  * `:metadata` - Additional frontmatter fields
  * `:body` - Full SKILL.md body content (nil until loaded)
  * `:body_loaded` - Whether the body has been loaded
  * `:resources` - Map of available resource files by category

  ## Progressive Disclosure

  Skills are loaded with metadata only by default. The body is loaded
  on-demand via `Conjure.load_body/1` or when Claude reads the SKILL.md
  file using the view tool.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: Path.t(),
          license: String.t() | nil,
          version: String.t() | nil,
          compatibility: map() | nil,
          allowed_tools: [String.t()] | nil,
          metadata: map(),
          body: String.t() | nil,
          body_loaded: boolean(),
          resources: resources()
        }

  @type resources :: %{
          scripts: [Path.t()],
          references: [Path.t()],
          assets: [Path.t()],
          other: [Path.t()]
        }

  @enforce_keys [:name, :description, :path]
  defstruct [
    :name,
    :description,
    :path,
    :license,
    :version,
    :compatibility,
    :allowed_tools,
    metadata: %{},
    body: nil,
    body_loaded: false,
    resources: %{scripts: [], references: [], assets: [], other: []}
  ]

  @doc """
  Returns the path to the SKILL.md file for this skill.
  """
  @spec skill_md_path(t()) :: Path.t()
  def skill_md_path(%__MODULE__{path: path}) do
    Path.join(path, "SKILL.md")
  end

  @doc """
  Returns the path to a resource file within the skill.
  """
  @spec resource_path(t(), Path.t()) :: Path.t()
  def resource_path(%__MODULE__{path: path}, relative_path) do
    Path.join(path, relative_path)
  end

  @doc """
  Checks if a skill has a specific resource file.
  """
  @spec has_resource?(t(), Path.t()) :: boolean()
  def has_resource?(%__MODULE__{resources: resources}, relative_path) do
    all_resources =
      resources.scripts ++ resources.references ++ resources.assets ++ resources.other

    relative_path in all_resources
  end
end
