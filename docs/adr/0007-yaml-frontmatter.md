# ADR-0007: YAML frontmatter in SKILL.md

## Status

Accepted

## Context

Each skill requires structured metadata:

- **Required**: name, description
- **Optional**: license, compatibility, allowed_tools, version

This metadata must be:

1. Co-located with skill instructions (single file)
2. Human-readable and editable
3. Machine-parseable
4. Familiar to developers

The SKILL.md file serves dual purposes:

1. **For Claude**: Instructions on how to use the skill
2. **For Conjure**: Metadata for loading and prompt generation

These concerns must be cleanly separated within a single file.

## Decision

We will use YAML frontmatter delimited by `---` markers at the start of SKILL.md files.

```markdown
---
name: pdf
description: >
  Comprehensive PDF manipulation toolkit for extracting text and tables,
  creating new PDFs, merging/splitting documents, and handling forms.
license: MIT
compatibility: python3, poppler-utils
allowed-tools: Bash(pdftotext:*) Read Write
---

# PDF Skill

Detailed instructions for Claude on using this skill...
```

Parsing extracts frontmatter and body separately:

```elixir
def parse_frontmatter(content) do
  case Regex.run(~r/\A---\n(.+?)\n---\n(.*)/s, content) do
    [_, yaml, body] ->
      {:ok, frontmatter} = YamlElixir.read_from_string(yaml)
      {:ok, frontmatter, body}
    nil ->
      {:error, :no_frontmatter}
  end
end
```

## Consequences

### Positive

- Standard format used by Jekyll, Hugo, Docusaurus, etc.
- Developers already familiar with the pattern
- YAML is human-friendly (no quotes for simple strings)
- Clean separation of metadata from content
- Markdown body renders correctly (frontmatter hidden in viewers)
- Multi-line descriptions via YAML block scalars (`>`, `|`)

### Negative

- YAML parsing edge cases (indentation, special characters)
- Requires YAML library dependency (yaml_elixir)
- Frontmatter must be at file start (no flexibility)
- Limited validation (no schema enforcement by default)

### Neutral

- `---` delimiter is conventional but arbitrary
- YAML version/spec is implicit (1.1 vs 1.2)
- Empty frontmatter (`---\n---\n`) is valid

## Schema Definition

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Skill identifier (lowercase, alphanumeric, hyphens) |
| `description` | string | Comprehensive description including usage triggers |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `license` | string | SPDX identifier or license reference |
| `version` | string | Semantic version (e.g., "1.2.0") |
| `compatibility.products` | list | Supported products (claude.ai, claude-code, api) |
| `compatibility.packages` | list | Required system packages |
| `allowed_tools` | list | Tools this skill may use |

### Validation Rules

```elixir
def validate_frontmatter(fm) do
  with :ok <- require_field(fm, "name"),
       :ok <- require_field(fm, "description"),
       :ok <- validate_name_format(fm["name"]) do
    :ok
  end
end

defp validate_name_format(name) do
  if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) do
    :ok
  else
    {:error, {:invalid_name, "must be lowercase alphanumeric with hyphens"}}
  end
end
```

## Alternatives Considered

### TOML frontmatter

```toml
+++
name = "pdf"
description = "..."
+++
```

Rejected because:

- Less common than YAML frontmatter
- TOML syntax less familiar to most developers
- Would require different delimiter (`+++`)

### JSON frontmatter

```json
{
  "name": "pdf",
  "description": "..."
}
```

Rejected because:

- Requires quotes for all strings (verbose)
- No multi-line string support without escaping
- Less readable for humans

### Separate metadata file

```
my-skill/
├── SKILL.md
└── skill.yaml
```

Rejected because:

- Two files to manage
- Harder to share/review
- Metadata can drift from content

### Inline metadata markers

```markdown
<!-- skill:name=pdf -->
<!-- skill:description=... -->

# PDF Skill
```

Rejected because:

- Verbose for complex metadata
- No standard parsing
- Hard to read and maintain

## Dependencies

This decision requires adding `yaml_elixir` to dependencies:

```elixir
{:yaml_elixir, "~> 2.9"}
```

## References

- [YAML Frontmatter convention](https://jekyllrb.com/docs/front-matter/)
- [yaml_elixir library](https://hexdocs.pm/yaml_elixir)
- [YAML 1.2 Specification](https://yaml.org/spec/1.2.2/)
