#!/usr/bin/env elixir
#
# Example: Upload skill to Anthropic and use hosted execution
#
# Demonstrates the simplified Anthropic Skills API workflow:
# 1. Load a .skill file and create session (uploads automatically)
# 2. Chat with Claude (Anthropic's cloud executes the skill)
# 3. Cleanup (deletes uploaded skills automatically)
#
# Prerequisites:
#   - ANTHROPIC_API_KEY environment variable set
#   - Req HTTP client (optional dependency)
#
# Usage:
#   ANTHROPIC_API_KEY=sk-... mix run examples/.scripts/timestamp-echo-api/run_skill_session.exs
#   ANTHROPIC_API_KEY=sk-... mix run examples/.scripts/timestamp-echo-api/run_skill_session.exs "Hello!"
#

defmodule AnthropicClient do
  @moduledoc """
  HTTP client for Anthropic API calls.
  """

  @base_url "https://api.anthropic.com"

  def new(api_key) do
    %{api_key: api_key}
  end

  @doc """
  API callback for skill upload/management and session creation.
  """
  def skill_callback(%{api_key: api_key}) do
    fn method, path, body, opts ->
      url = @base_url <> path

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ] ++ Conjure.API.Anthropic.beta_headers()

      result = case {method, Keyword.get(opts, :multipart, false)} do
        {:get, _} ->
          Req.get(url, headers: headers)

        {:post, true} ->
          # Multipart upload for skills
          form_multipart = Enum.map(body, fn
            {"files[]", {filename, content}} ->
              {"files[]", {content, filename: filename}}
            {key, value} ->
              {key, value}
          end)
          Req.post(url, headers: headers, form_multipart: form_multipart)

        {:post, false} ->
          Req.post(url, headers: headers, json: body)

        {:delete, _} ->
          Req.delete(url, headers: headers)
      end

      case result do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}
        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  API callback for Conjure.Session.chat (messages API).
  """
  def messages_callback(%{api_key: api_key}, container_config) do
    fn messages ->
      url = @base_url <> "/v1/messages"

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ] ++ Conjure.API.Anthropic.beta_headers()

      body = Conjure.API.Anthropic.build_request(
        messages,
        container_config,
        model: "claude-sonnet-4-20250514",
        max_tokens: 4096
      )

      IO.puts("[API] Calling Claude (stop_reason pending)...")

      case Req.post(url, json: body, headers: headers) do
        {:ok, %{status: 200, body: response}} ->
          IO.puts("[API] Response: stop_reason=#{response["stop_reason"]}")
          {:ok, response}

        {:ok, %{status: status, body: body}} ->
          IO.puts("[API] Error: HTTP #{status}")
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          IO.puts("[API] Error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end

# =============================================================================
# Main
# =============================================================================

alias Conjure.Session

# Check for API key
api_key = System.get_env("ANTHROPIC_API_KEY")

unless api_key do
  IO.puts("Error: ANTHROPIC_API_KEY environment variable not set")
  IO.puts("")
  IO.puts("Usage:")
  IO.puts("  ANTHROPIC_API_KEY=sk-... mix run examples/.scripts/timestamp-echo-api/run_skill_session.exs")
  System.halt(1)
end

# Check for Req
unless Code.ensure_loaded?(Req) do
  IO.puts("Error: Req HTTP client not available")
  IO.puts("Add {:req, \"~> 0.5\"} to your deps and run mix deps.get")
  System.halt(1)
end

message = case System.argv() do
  [msg | _] -> msg
  [] -> "Hello from Anthropic hosted execution!"
end

script_dir = Path.dirname(__ENV__.file)
project_root = Path.join(script_dir, "../../..") |> Path.expand()
skill_file = Path.join(project_root, "examples/skills/timestamp-echo.skill")

IO.puts("=== Conjure Anthropic Hosted Execution ===")
IO.puts("Message: #{message}\n")

client = AnthropicClient.new(api_key)
skill_api = AnthropicClient.skill_callback(client)

# Step 1: Load skill and create session (uploads automatically)
IO.puts("Step 1: Loading skill and creating session...")

{:ok, skill} = Conjure.Loader.load_skill_file(skill_file)
IO.puts("  Loaded: #{skill.name}")

case Session.new_anthropic([skill], api_callback: skill_api) do
  {:ok, session} ->
    IO.puts("  Session created (mode: #{session.execution_mode})")
    IO.puts("  Uploaded #{length(session.uploaded_skills)} skill(s)\n")

    # Step 2: Chat with Claude
    IO.puts("Step 2: Sending message to Claude...")

    {:ok, container_config} = Conjure.API.Anthropic.container_config(session.skills)
    messages_api = AnthropicClient.messages_callback(client, container_config)

    case Session.chat(session, message, messages_api) do
      {:ok, response, session} ->
        text = response["content"]
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("\n", & &1["text"])

        IO.puts("\n=== Claude's Response ===")
        IO.puts(text)

        # Show any files created
        if session.created_files != [] do
          IO.puts("\nFiles created:")
          for file <- session.created_files do
            IO.puts("  - #{file.id}")
          end
        end

        # Step 3: Cleanup (deletes uploaded skills automatically)
        IO.puts("\nStep 3: Cleaning up...")
        :ok = Session.cleanup(session)
        IO.puts("  Deleted uploaded skills")

      {:error, e} ->
        IO.puts("\nChat error: #{inspect(e)}")
        Session.cleanup(session)
        System.halt(1)
    end

  {:error, e} ->
    IO.puts("Session creation error: #{inspect(e)}")
    System.halt(1)
end

IO.puts("\nDone!")
