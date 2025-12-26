#!/usr/bin/env elixir
#
# Example: Conjure.Session.chat with Native execution
#
# Demonstrates using native Elixir skills that run directly in the BEAM.
# No external processes, no Python, no Docker - pure Elixir.
#
# Usage:
#   mix run examples/.scripts/timestamp-echo-native/run_skill_session.exs
#   mix run examples/.scripts/timestamp-echo-native/run_skill_session.exs "Hello!"
#

# Load the skill module
Code.require_file("timestamp_echo.ex", __DIR__)

defmodule MockClaudeAPI do
  @moduledoc """
  Simulates Claude API responses for native skill execution.
  """

  def create_callback(skill_module) do
    info = skill_module.__skill_info__()
    tool_name = String.replace(info.name, "-", "_") <> "_execute"

    fn messages ->
      if has_tool_result?(messages) do
        final_response(messages)
      else
        tool_use_response(tool_name, messages)
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

  defp tool_use_response(tool_name, messages) do
    user_message = extract_user_message(messages)

    IO.puts("\n[Mock Claude] User asked: \"#{user_message}\"")
    IO.puts("[Mock Claude] I'll use the timestamp-echo skill (native).")

    {:ok, %{
      "id" => "msg_#{:erlang.unique_integer([:positive])}",
      "role" => "assistant",
      "content" => [
        %{"type" => "text", "text" => "I'll echo your message with a timestamp."},
        %{
          "type" => "tool_use",
          "id" => "toolu_#{:erlang.unique_integer([:positive])}",
          "name" => tool_name,
          "input" => %{"command" => user_message}
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
  [] -> "Hello from Native!"
end

skill_module = Examples.Skills.TimestampEcho
info = skill_module.__skill_info__()

IO.puts("=== Conjure Native Session Example ===")
IO.puts("Message: #{message}")
IO.puts("Skill: #{info.name} (Elixir module)\n")

session = Session.new_native([skill_module], timeout: 30_000)

case Session.chat(session, message, MockClaudeAPI.create_callback(skill_module)) do
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
