#!/usr/bin/env elixir
#
# Example: Low-level local executor usage
#
# Demonstrates using Conjure.Executor.Local directly.
# Uses relative paths as documented in SKILL.md.
#
# Usage:
#   mix run examples/.scripts/timestamp-echo-local/run_skill.exs
#   mix run examples/.scripts/timestamp-echo-local/run_skill.exs "Hello!"
#

alias Conjure.{ExecutionContext, Executor.Local, ToolCall}

message = case System.argv() do
  [msg | _] -> msg
  [] -> "Hello from Local!"
end

script_dir = Path.dirname(__ENV__.file)
project_root = Path.join(script_dir, "../../..") |> Path.expand()
skill_file = Path.join(project_root, "examples/skills/timestamp-echo.skill")

IO.puts("=== Conjure Local Executor Example ===")
IO.puts("Message: #{message}\n")

# Load skill
{:ok, skill} = Conjure.Loader.load_skill_file(skill_file)
IO.puts("Skill: #{skill.name}\n")

# Create context - working directory is the skill path for relative paths
context = ExecutionContext.new(
  skill: skill,
  skills_root: skill.path,
  working_directory: skill.path
)

# Mock Claude generates command using relative path from SKILL.md
tool_call = %ToolCall{
  id: "toolu_#{:erlang.unique_integer([:positive])}",
  name: "bash_tool",
  input: %{"command" => "python3 scripts/timestamp_echo.py '#{message}'"}
}

IO.puts("[Mock Claude] Running: #{tool_call.input["command"]}\n")

# Execute locally
{:ok, context} = Local.init(context)

result = Conjure.Executor.execute(tool_call, context, Local)

Local.cleanup(context)

case result do
  {:ok, output} ->
    IO.puts("=== Result ===")
    IO.puts(String.trim(output))

  {:error, e} ->
    IO.puts("Error: #{inspect(e)}")
    System.halt(1)
end
