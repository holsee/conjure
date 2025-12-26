defmodule Mix.Tasks.Conjure.Init do
  @moduledoc """
  Initializes a new skill directory with SKILL.md template.

  ## Usage

      mix conjure.init path/to/new-skill

  ## Options

      --name, -n      Skill name (default: directory name)
      --description   Skill description

  ## Examples

      # Create a new skill
      mix conjure.init ./skills/my-new-skill

      # Create with options
      mix conjure.init ./skills/pdf-tools --name pdf --description "PDF utilities"

  """

  use Mix.Task

  @shortdoc "Initialize a new skill directory"

  @switches [name: :string, description: :string]
  @aliases [n: :name]

  @impl Mix.Task
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, switches: @switches, aliases: @aliases)

    if paths == [] do
      Mix.shell().error("Usage: mix conjure.init <path>")
      exit({:shutdown, 1})
    end

    path = hd(paths) |> Path.expand()
    name = Keyword.get(opts, :name, Path.basename(path))
    description = Keyword.get(opts, :description, "A skill for #{name}.")

    if File.exists?(path) do
      Mix.shell().error("Path already exists: #{path}")
      exit({:shutdown, 1})
    end

    # Validate name
    unless Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) do
      Mix.shell().error("Invalid skill name: #{name}")
      Mix.shell().error("Name must be lowercase alphanumeric with hyphens")
      exit({:shutdown, 1})
    end

    create_skill(path, name, description)

    Mix.shell().info("#{IO.ANSI.green()}Created skill: #{name}#{IO.ANSI.reset()}")
    Mix.shell().info("")
    Mix.shell().info("Directory structure:")
    Mix.shell().info("  #{path}/")
    Mix.shell().info("  ├── SKILL.md")
    Mix.shell().info("  ├── scripts/")
    Mix.shell().info("  ├── references/")
    Mix.shell().info("  └── assets/")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Edit #{path}/SKILL.md with your skill instructions")
    Mix.shell().info("  2. Add scripts to scripts/")
    Mix.shell().info("  3. Validate with: mix conjure.validate #{path}")
  end

  defp create_skill(path, name, description) do
    # Create directories
    File.mkdir_p!(path)
    File.mkdir_p!(Path.join(path, "scripts"))
    File.mkdir_p!(Path.join(path, "references"))
    File.mkdir_p!(Path.join(path, "assets"))

    # Create SKILL.md
    skill_md = """
    ---
    name: #{name}
    description: |
      #{description}
    license: MIT
    version: "0.1.0"
    compatibility:
      products: [claude.ai, claude-code, api]
      packages: []
    allowed_tools: [bash, view, create_file, str_replace]
    ---

    # #{String.capitalize(name)} Skill

    ## Overview

    Describe what this skill does and when it should be used.

    ## Usage

    Provide instructions for using this skill.

    ### Example

    ```bash
    # Example command
    ```

    ## Available Scripts

    - `scripts/example.py` - Description of what it does

    ## Notes

    Any additional information or caveats.
    """

    File.write!(Path.join(path, "SKILL.md"), skill_md)

    # Create example script
    example_script = """
    #!/usr/bin/env python3
    \"\"\"Example script for #{name} skill.\"\"\"

    import sys

    def main():
        print("Hello from #{name} skill!")

    if __name__ == "__main__":
        main()
    """

    script_path = Path.join(path, "scripts/example.py")
    File.write!(script_path, example_script)
    File.chmod!(script_path, 0o755)
  end
end
