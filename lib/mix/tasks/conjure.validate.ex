defmodule Mix.Tasks.Conjure.Validate do
  @moduledoc """
  Validates skill structure and metadata.

  ## Usage

      mix conjure.validate path/to/skill
      mix conjure.validate path/to/skills/directory

  ## Options

      --verbose, -v   Show detailed validation information

  ## Examples

      # Validate a single skill
      mix conjure.validate ./my-skill

      # Validate all skills in a directory
      mix conjure.validate ./skills

  """

  use Mix.Task

  @shortdoc "Validate skill structure and metadata"

  @switches [verbose: :boolean]
  @aliases [v: :verbose]

  @impl Mix.Task
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, switches: @switches, aliases: @aliases)

    if paths == [] do
      Mix.shell().error("Usage: mix conjure.validate <path>")
      exit({:shutdown, 1})
    end

    Application.ensure_all_started(:yaml_elixir)

    results =
      paths
      |> Enum.flat_map(&expand_path/1)
      |> Enum.map(&validate_skill(&1, opts))

    successes = Enum.count(results, &match?({:ok, _}, &1))
    failures = Enum.count(results, &match?({:error, _, _}, &1))

    Mix.shell().info("")

    Mix.shell().info(
      "Validated #{successes + failures} skill(s): #{successes} passed, #{failures} failed"
    )

    if failures > 0 do
      exit({:shutdown, 1})
    end
  end

  defp expand_path(path) do
    expanded = Path.expand(path)

    cond do
      File.exists?(Path.join(expanded, "SKILL.md")) ->
        [expanded]

      File.dir?(expanded) ->
        expanded
        |> File.ls!()
        |> Enum.map(&Path.join(expanded, &1))
        |> Enum.filter(fn path ->
          File.dir?(path) and File.exists?(Path.join(path, "SKILL.md"))
        end)

      true ->
        Mix.shell().error("Path not found: #{path}")
        []
    end
  end

  defp validate_skill(path, opts) do
    case Conjure.Loader.load_skill(path) do
      {:ok, skill} ->
        handle_loaded_skill(skill, path, opts)

      {:error, error} ->
        print_load_error(path, error)
        {:error, path, [error.message]}
    end
  end

  defp handle_loaded_skill(skill, path, opts) do
    case Conjure.Loader.validate(skill) do
      :ok ->
        print_success(skill, opts)
        {:ok, skill}

      {:error, errors} ->
        print_validation_errors(path, errors)
        {:error, path, errors}
    end
  end

  defp print_success(skill, opts) do
    Mix.shell().info("#{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{skill.name}")

    if Keyword.get(opts, :verbose, false) do
      print_verbose_info(skill)
    end
  end

  defp print_verbose_info(skill) do
    Mix.shell().info("  Path: #{skill.path}")
    Mix.shell().info("  Description: #{String.slice(skill.description, 0, 60)}...")

    if skill.resources.scripts != [] do
      Mix.shell().info("  Scripts: #{Enum.join(skill.resources.scripts, ", ")}")
    end
  end

  defp print_validation_errors(path, errors) do
    Mix.shell().error("#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{Path.basename(path)}")

    for error <- errors do
      Mix.shell().error("  - #{error}")
    end
  end

  defp print_load_error(path, error) do
    Mix.shell().error("#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{Path.basename(path)}")
    Mix.shell().error("  - #{error.message}")
  end
end
