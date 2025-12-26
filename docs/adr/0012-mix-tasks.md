# ADR-0012: Mix tasks for developer experience

## Status

Proposed

## Context

Conjure currently provides only programmatic APIs. Common developer workflows require writing boilerplate code:

```elixir
# To validate a skill
{:ok, skills} = Conjure.load("/path/to/skills")
Enum.each(skills, fn skill ->
  case Conjure.Loader.validate(skill) do
    :ok -> IO.puts("#{skill.name}: valid")
    {:error, errors} -> IO.puts("#{skill.name}: #{inspect(errors)}")
  end
end)

# To list available skills
{:ok, skills} = Conjure.load("/path/to/skills")
Enum.each(skills, &IO.puts(&1.name))

# To build Docker image
# Must manually construct docker build command...
```

Mix tasks are the standard Elixir mechanism for CLI tooling, providing:

- Consistent interface (`mix conjure.xxx`)
- Argument parsing via `OptionParser`
- Integration with Mix project context
- Discoverability via `mix help`

The `lib/conjure/mix/tasks/` directory exists but is empty, indicating this was planned but not implemented.

## Decision

We will implement the following Mix tasks:

### `mix conjure.validate`

Validates skill structure and metadata.

```bash
# Validate skills in default paths
$ mix conjure.validate

# Validate specific directory
$ mix conjure.validate --path /path/to/skills

# Validate single skill
$ mix conjure.validate --path /path/to/skills/pdf

# Strict mode (warnings as errors)
$ mix conjure.validate --strict
```

Output:
```
Validating skills...
✓ pdf - valid
✓ docx - valid
✗ broken-skill - missing required field: description

Found 3 skills: 2 valid, 1 invalid
```

### `mix conjure.list`

Lists available skills with metadata.

```bash
# List all skills
$ mix conjure.list

# JSON output for scripting
$ mix conjure.list --format json

# Show full details
$ mix conjure.list --verbose
```

Output:
```
Available Skills:
  pdf          Comprehensive PDF manipulation toolkit...
  docx         Document creation and editing...

2 skills found
```

### `mix conjure.docker.build`

Builds the sandbox Docker image.

```bash
# Build default image
$ mix conjure.docker.build

# Custom tag
$ mix conjure.docker.build --tag myorg/conjure-sandbox:v1

# No cache
$ mix conjure.docker.build --no-cache
```

### `mix conjure.info`

Shows information about a specific skill.

```bash
$ mix conjure.info pdf

Name: pdf
Description: Comprehensive PDF manipulation toolkit...
License: MIT
Location: /path/to/skills/pdf
Resources:
  - scripts/pdf_utils.py
  - references/api.md
Allowed Tools: bash_tool, view, create_file
```

### Implementation Structure

```
lib/conjure/mix/tasks/
├── conjure.validate.ex
├── conjure.list.ex
├── conjure.info.ex
└── conjure.docker.build.ex
```

Each task follows the standard Mix.Task pattern:

```elixir
defmodule Mix.Tasks.Conjure.Validate do
  @shortdoc "Validates skill structure and metadata"
  @moduledoc """
  Validates skills in the specified path.

  ## Usage

      $ mix conjure.validate [--path PATH] [--strict]

  ## Options

    * `--path` - Path to skills directory (default: configured paths)
    * `--strict` - Treat warnings as errors

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      strict: [path: :string, strict: :boolean]
    )

    # Implementation...
  end
end
```

## Consequences

### Positive

- Standard Elixir developer experience
- Discoverable via `mix help conjure`
- Scriptable for CI/CD pipelines
- Reduces boilerplate for common operations
- Consistent with ecosystem conventions

### Negative

- Additional code to maintain
- Must handle edge cases in CLI context (no supervision tree, etc.)
- Mix tasks are not available in releases (escript alternative needed)

### Neutral

- Tasks depend on Conjure being compiled
- Output formatting may need iteration based on user feedback
- JSON output enables integration with other tools

## Alternatives Considered

### Escript Binary

A standalone `conjure` binary would work in releases. Rejected for initial implementation because:

- Mix tasks are simpler to implement
- Most users interact during development, not production
- Can add escript later if needed

### IEx Helpers

Could provide `Conjure.CLI` module for IEx usage. Rejected because:

- Non-standard interface
- Mix tasks are more discoverable
- Can still use the module functions in IEx

## References

- [Mix.Task documentation](https://hexdocs.pm/mix/Mix.Task.html)
- [Creating Mix Tasks guide](https://hexdocs.pm/mix/Mix.html#module-creating-custom-tasks)
