defmodule Mix.Tasks.Conjure.Docker.Build do
  @moduledoc """
  Builds the Conjure Docker sandbox image.

  ## Usage

      mix conjure.docker.build

  ## Options

      --tag, -t      Image tag (default: conjure/sandbox:latest)
      --no-cache     Build without using cache

  ## Examples

      # Build with default tag
      mix conjure.docker.build

      # Build with custom tag
      mix conjure.docker.build --tag myapp/sandbox:v1

  """

  use Mix.Task

  alias Conjure.Executor.Docker

  @shortdoc "Build the Conjure Docker sandbox image"

  @switches [tag: :string, no_cache: :boolean]
  @aliases [t: :tag]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: @switches, aliases: @aliases)

    tag = Keyword.get(opts, :tag, "conjure/sandbox:latest")
    no_cache = Keyword.get(opts, :no_cache, false)

    Mix.shell().info("Building Conjure sandbox image: #{tag}")

    case check_docker() do
      :ok ->
        build_image(tag, no_cache)

      {:error, reason} ->
        Mix.shell().error("Docker check failed: #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp check_docker do
    case System.cmd("docker", ["version"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _} -> {:error, output}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_image(tag, no_cache) do
    dockerfile = Docker.default_dockerfile()

    # Create temp directory
    temp_dir = Path.join(System.tmp_dir!(), "conjure_build_#{:rand.uniform(100_000)}")
    File.mkdir_p!(temp_dir)
    dockerfile_path = Path.join(temp_dir, "Dockerfile")
    File.write!(dockerfile_path, dockerfile)

    args = ["build", "-t", tag, "-f", dockerfile_path]
    args = if no_cache, do: args ++ ["--no-cache"], else: args
    args = args ++ [temp_dir]

    Mix.shell().info("Running: docker #{Enum.join(args, " ")}")
    Mix.shell().info("")

    case System.cmd("docker", args, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        File.rm_rf!(temp_dir)
        Mix.shell().info("")
        Mix.shell().info("#{IO.ANSI.green()}Successfully built #{tag}#{IO.ANSI.reset()}")

      {_, code} ->
        File.rm_rf!(temp_dir)
        Mix.shell().error("Build failed with exit code #{code}")
        exit({:shutdown, 1})
    end
  end
end
