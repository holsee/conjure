#!/usr/bin/env elixir
#
# Example: Low-level Docker executor usage
#
# Demonstrates using Conjure.Executor.Docker directly.
# Uses relative paths as documented in SKILL.md.
#
# Prerequisites:
#   - Docker installed and running
#   - Conjure sandbox image built: mix conjure.docker.build
#
# Usage:
#   mix run examples/.scripts/timestamp-echo-docker/run_skill.exs
#   mix run examples/.scripts/timestamp-echo-docker/run_skill.exs "Hello!"
#

alias Conjure.{ExecutionContext, Executor.Docker, ToolCall}

message = case System.argv() do
  [msg | _] -> msg
  [] -> "Hello from Docker!"
end

script_dir = Path.dirname(__ENV__.file)
project_root = Path.join(script_dir, "../../..") |> Path.expand()
skill_file = Path.join(project_root, "examples/skills/timestamp-echo.skill")

IO.puts("=== Conjure Docker Executor Example ===")
IO.puts("Message: #{message}\n")

# Check Docker
case Docker.check_environment() do
  :ok -> IO.puts("Docker: OK")
  {:error, e} ->
    IO.puts("Docker check failed: #{inspect(e)}")
    IO.puts("Run: mix conjure.docker.build")
    System.halt(1)
end

# Load skill
{:ok, skill} = Conjure.Loader.load_skill_file(skill_file)
IO.puts("Skill: #{skill.name}\n")

# Create context and tool call
work_dir = Path.join(System.tmp_dir!(), "conjure_#{:erlang.unique_integer([:positive])}")
File.mkdir_p!(work_dir)

context = ExecutionContext.new(
  skill: skill,
  skills_root: skill.path,
  working_directory: work_dir
)

# Mock Claude generates command using relative path from SKILL.md
tool_call = %ToolCall{
  id: "toolu_#{:erlang.unique_integer([:positive])}",
  name: "bash_tool",
  input: %{"command" => "python3 scripts/timestamp_echo.py '#{message}'"}
}

IO.puts("[Mock Claude] Running: #{tool_call.input["command"]}\n")

# Execute in Docker
{:ok, context} = Docker.init(context)
IO.puts("Container: #{context.container_id}")

result = Conjure.Executor.execute(tool_call, context, Docker)

Docker.cleanup(context)
File.rm_rf!(work_dir)

case result do
  {:ok, output} ->
    IO.puts("\n=== Result ===")
    IO.puts(String.trim(output))

  {:error, e} ->
    IO.puts("Error: #{inspect(e)}")
    System.halt(1)
end
