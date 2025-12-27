defmodule Conjure.Frontmatter do
  @moduledoc """
  Parsed YAML frontmatter from SKILL.md files.

  The frontmatter contains structured metadata about a skill per the
  Agent Skills specification (https://agentskills.io/specification).

  ## Required Fields

  * `name` - Max 64 chars, lowercase letters/numbers/hyphens
  * `description` - Max 1024 chars, what the skill does and when to use it

  ## Optional Fields

  * `license` - License name or filename
  * `compatibility` - Max 500 chars, environment requirements
  * `allowed_tools` - List of pre-approved tools (experimental)
  * `metadata` - Additional key-value properties

  ## Example

      ---
      name: pdf
      description: |
        Comprehensive PDF manipulation toolkit for extracting text and tables,
        creating new PDFs, merging/splitting documents, and handling forms.
      license: MIT
      compatibility: python3, poppler-utils
      allowed-tools: Bash(pdftotext:*) Read
      ---
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          license: String.t() | nil,
          compatibility: String.t() | nil,
          allowed_tools: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:name, :description]
  defstruct [
    :name,
    :description,
    :license,
    :compatibility,
    :allowed_tools,
    metadata: %{}
  ]

  # Note: spec uses "allowed-tools" with hyphen, we normalize to underscore
  @known_fields ~w(name description license compatibility allowed-tools metadata)

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
      # Get metadata field if present, or collect unknown fields
      metadata =
        case Map.get(map, "metadata") do
          nil ->
            map
            |> Map.drop(@known_fields)
            |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

          meta when is_map(meta) ->
            Map.new(meta, fn {k, v} -> {String.to_atom(k), v} end)
        end

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         license: Map.get(map, "license"),
         compatibility: Map.get(map, "compatibility"),
         # Spec uses "allowed-tools" with hyphen
         allowed_tools: Map.get(map, "allowed-tools"),
         metadata: metadata
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
