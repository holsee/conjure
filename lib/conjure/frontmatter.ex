defmodule Conjure.Frontmatter do
  @moduledoc """
  Parsed YAML frontmatter from SKILL.md files.

  The frontmatter contains structured metadata about a skill, including
  required fields (name, description) and optional fields (license,
  compatibility, allowed_tools).

  ## Example

      ---
      name: pdf
      description: |
        Comprehensive PDF manipulation toolkit for extracting text and tables,
        creating new PDFs, merging/splitting documents, and handling forms.
      license: MIT
      version: "1.0.0"
      compatibility:
        products: [claude.ai, claude-code, api]
        packages: [python3, poppler-utils]
      allowed_tools: [bash, view, create_file]
      ---
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          license: String.t() | nil,
          version: String.t() | nil,
          compatibility: map() | nil,
          allowed_tools: [String.t()] | nil,
          extra: map()
        }

  @enforce_keys [:name, :description]
  defstruct [
    :name,
    :description,
    :license,
    :version,
    :compatibility,
    :allowed_tools,
    extra: %{}
  ]

  @known_fields ~w(name description license version compatibility allowed_tools)

  @doc """
  Creates a Frontmatter struct from a parsed YAML map.

  Returns `{:ok, frontmatter}` on success, or `{:error, reason}` if
  required fields are missing or validation fails.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, name} <- require_field(map, "name"),
         {:ok, description} <- require_field(map, "description"),
         :ok <- validate_name(name) do
      extra =
        map
        |> Map.drop(@known_fields)
        |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         license: Map.get(map, "license"),
         version: Map.get(map, "version"),
         compatibility: Map.get(map, "compatibility"),
         allowed_tools: Map.get(map, "allowed_tools"),
         extra: extra
       }}
    end
  end

  defp require_field(map, field) do
    case Map.get(map, field) do
      nil -> {:error, {:missing_field, String.to_atom(field)}}
      "" -> {:error, {:empty_field, String.to_atom(field)}}
      value -> {:ok, value}
    end
  end

  defp validate_name(name) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) do
      :ok
    else
      {:error,
       {:invalid_name, "must be lowercase alphanumeric with hyphens, got: #{inspect(name)}"}}
    end
  end
end
