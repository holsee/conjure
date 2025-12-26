#!/usr/bin/env elixir
#
# Example: Conjure.Session.chat with local execution
#
# Demonstrates using Conjure.Session API with local execution.
# The mock Claude uses relative paths as documented in SKILL.md.
#
# Usage:
#   mix run examples/.scripts/timestamp-echo-local/run_skill_session.exs
#   mix run examples/.scripts/timestamp-echo-local/run_skill_session.exs "Hello!"
#

defmodule MockClaudeAPI do
  @moduledoc """
  Simulates Claude API responses.

  A real Claude would read SKILL.md via the view tool, understand the skill,
  and generate appropriate bash commands using relative paths as documented.
  """

  def create_callback(_skill) do
    fn messages ->
      if has_tool_result?(messages) do
        final_response(messages)
      else
        tool_use_response(messages)
      end
    end
  end

  defp has_tool_result?(messages) do
    Enum.any?(messages, fn
      %{"role" => "user", "content" => content} when is_list(content) ->
        Enum.any?(content, &(is_map(&1) and &1["type"] == "tool_result"))
      _ -> false
    end)
  end

  defp tool_use_response(messages) do
    user_message = extract_user_message(messages)

    IO.puts("\n[Mock Claude] User asked: \"#{user_message}\"")
    IO.puts("[Mock Claude] I'll use the timestamp-echo skill.")

    # Claude uses relative path as documented in SKILL.md
    {:ok, %{
      "id" => "msg_#{:erlang.unique_integer([:positive])}",
      "role" => "assistant",
      "content" => [
        %{"type" => "text", "text" => "I'll echo your message with a timestamp."},
        %{
          "type" => "tool_use",
          "id" => "toolu_#{:erlang.unique_integer([:positive])}",
          "name" => "bash_tool",
          "input" => %{
            "command" => "python3 scripts/timestamp_echo.py '#{user_message}'"
          }
        }
      ],
      "stop_reason" => "tool_use"
    }}
  end

  defp final_response(messages) do
    tool_output = extract_tool_output(messages)

    IO.puts("[Mock Claude] Got result, responding to user.")

    {:ok, %{
      "id" => "msg_#{:erlang.unique_integer([:positive])}",
      "role" => "assistant",
      "content" => [
        %{"type" => "text", "text" => "Here's your message with timestamp:\n\n#{tool_output}"}
      ],
      "stop_reason" => "end_turn"
    }}
  end

  defp extract_user_message(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> get_in(["content"])
    |> case do
      text when is_binary(text) -> text
      blocks when is_list(blocks) ->
        blocks
        |> Enum.find(&(is_map(&1) and &1["type"] == "text"))
        |> case do
          %{"text" => text} -> text
          _ -> ""
        end
      _ -> ""
    end
  end

  defp extract_tool_output(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> get_in(["content"])
    |> Enum.find(&(is_map(&1) and &1["type"] == "tool_result"))
    |> Map.get("content", "")
    |> String.trim()
  end
end

# =============================================================================
# Main
# =============================================================================

alias Conjure.Session

message = case System.argv() do
  [msg | _] -> msg
  [] -> "Hello from Local!"
end

script_dir = Path.dirname(__ENV__.file)
project_root = Path.join(script_dir, "../../..") |> Path.expand()
skill_file = Path.join(project_root, "examples/skills/timestamp-echo.skill")

IO.puts("=== Conjure Local Session Example ===")
IO.puts("Message: #{message}\n")

case Conjure.Loader.load_skill_file(skill_file) do
  {:ok, skill} ->
    IO.puts("Skill: #{skill.name}\n")

    session = Session.new_local([skill],
      working_directory: skill.path,
      timeout: 30_000
    )

    case Session.chat(session, message, MockClaudeAPI.create_callback(skill)) do
      {:ok, response, _session} ->
        text = response["content"]
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("\n", & &1["text"])

        IO.puts("\n=== Response ===")
        IO.puts(text)

      {:error, e} ->
        IO.puts("Error: #{inspect(e)}")
        System.halt(1)
    end

  {:error, e} ->
    IO.puts("Failed to load skill: #{inspect(e)}")
    System.halt(1)
end
