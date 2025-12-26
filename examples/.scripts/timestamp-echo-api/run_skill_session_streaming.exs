#!/usr/bin/env elixir
#
# Example: Streaming skill execution with Anthropic API
#
# Same as run_skill_session.exs but with streaming output to console.
#
# Usage:
#   ANTHROPIC_API_KEY=sk-... mix run examples/.scripts/timestamp-echo-api/run_skill_session_streaming.exs
#   ANTHROPIC_API_KEY=sk-... mix run examples/.scripts/timestamp-echo-api/run_skill_session_streaming.exs "Hello!"
#

defmodule StreamingClient do
  @base_url "https://api.anthropic.com"

  def base_headers(api_key) do
    [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}]
    ++ Conjure.API.Anthropic.beta_headers()
  end

  def skill_callback(api_key) do
    fn method, path, body, opts ->
      url = @base_url <> path
      headers = base_headers(api_key)

      result = case {method, Keyword.get(opts, :multipart, false)} do
        {:get, _} -> Req.get(url, headers: headers)
        {:post, true} ->
          form = Enum.map(body, fn
            {"files[]", {filename, content}} -> {"files[]", {content, filename: filename}}
            {k, v} -> {k, v}
          end)
          Req.post(url, headers: headers, form_multipart: form)
        {:post, false} -> Req.post(url, headers: headers ++ [{"content-type", "application/json"}], json: body)
        {:delete, _} -> Req.delete(url, headers: headers)
      end

      case result do
        {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, b}
        {:ok, %{status: s, body: b}} -> {:error, {:api_error, s, b}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def stream_chat(api_key, messages, container_config) do
    url = @base_url <> "/v1/messages"

    body = Conjure.API.Anthropic.build_request(
      messages,
      container_config,
      model: "claude-sonnet-4-20250514",
      max_tokens: 4096
    ) |> Map.put("stream", true)

    IO.puts("[Stream] Connecting...")

    stream_fn = fn {:data, data}, {req, resp} ->
      handle_sse_data(data)
      {:cont, {req, resp}}
    end

    case Req.post(url, json: body, headers: base_headers(api_key), into: stream_fn, receive_timeout: 120_000) do
      {:ok, %{status: 200}} -> IO.puts(""); {:ok, %{}, []}
      {:ok, %{status: s, body: b}} -> {:error, {:http_error, s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_sse_data(data) do
    for line <- String.split(data, "\n"), String.starts_with?(line, "data: ") do
      json = String.trim_leading(line, "data: ")
      if json != "[DONE]" do
        case Jason.decode(json) do
          {:ok, %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}} ->
            IO.write(text)
          {:ok, %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}}} ->
            IO.puts("\n[stop_reason=#{reason}]")
          _ -> :ok
        end
      end
    end
  end
end

# =============================================================================
# Main
# =============================================================================

alias Conjure.Session

api_key = System.get_env("ANTHROPIC_API_KEY") || (
  IO.puts("Error: ANTHROPIC_API_KEY not set")
  System.halt(1)
)

unless Code.ensure_loaded?(Req) do
  IO.puts("Error: Req not available. Add {:req, \"~> 0.5\"} to deps.")
  System.halt(1)
end

message = List.first(System.argv()) || "Hello from streaming execution!"
script_dir = Path.dirname(__ENV__.file)
skill_file = Path.join([script_dir, "../../..", "examples/skills/timestamp-echo.skill"]) |> Path.expand()

IO.puts("=== Conjure Streaming Example ===")
IO.puts("Message: #{message}\n")

skill_api = StreamingClient.skill_callback(api_key)

IO.puts("Step 1: Loading skill and creating session...")
{:ok, skill} = Conjure.Loader.load_skill_file(skill_file)
IO.puts("  Loaded: #{skill.name}")

case Session.new_anthropic([skill], api_callback: skill_api) do
  {:ok, session} ->
    IO.puts("  Session created (mode: #{session.execution_mode})")
    IO.puts("  Uploaded #{length(session.uploaded_skills)} skill(s)\n")

    IO.puts("Step 2: Streaming response from Claude...")
    {:ok, container_config} = Conjure.API.Anthropic.container_config(session.skills)
    messages = [%{"role" => "user", "content" => message}]

    case StreamingClient.stream_chat(api_key, messages, container_config) do
      {:ok, _response, file_ids} ->
        if file_ids != [] do
          IO.puts("\nFiles created: #{inspect(file_ids)}")
        end

        IO.puts("\nStep 3: Cleaning up...")
        :ok = Session.cleanup(session)
        IO.puts("  Deleted uploaded skills")

      {:error, e} ->
        IO.puts("\nStream error: #{inspect(e)}")
        Session.cleanup(session)
        System.halt(1)
    end

  {:error, e} ->
    IO.puts("Session creation error: #{inspect(e)}")
    System.halt(1)
end

IO.puts("\nDone!")
