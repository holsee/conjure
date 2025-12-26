defmodule HelloConjure.Agent do
  @moduledoc """
  A simple agent that uses the Echo skill.
  """

  @api_url "https://api.anthropic.com/v1/messages"

  def chat(message) do
    # Load skills
    {:ok, skills} = Conjure.load("priv/skills")
    IO.puts("Loaded #{length(skills)} skill(s)")

    # Create a session
    session = Conjure.Session.new_local(skills)

    # Chat with Claude
    case Conjure.Session.chat(session, message, &api_callback/1) do
      {:ok, response, _session} ->
        text = extract_text(response)
        IO.puts("\nClaude: #{text}")
        {:ok, text}

      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
        {:error, error}
    end
  end

  defp api_callback(messages) do
    body = %{
      model: "claude-sonnet-4-5-20250929",
      max_tokens: 1024,
      system: system_prompt(),
      messages: messages,
      tools: Conjure.tool_definitions()
    }

    headers = [
      {"x-api-key", api_key()},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    case Req.post(@api_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: response}} -> {:ok, response}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp system_prompt do
    {:ok, skills} = Conjure.load("priv/skills")

    """
    You are a helpful assistant with access to skills.

    #{Conjure.system_prompt(skills)}
    """
  end

  defp extract_text(%{"content" => content}) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp api_key do
    Application.get_env(:hello_conjure, :anthropic_api_key) ||
      System.get_env("CLAUDE_API_KEY") ||
      raise "CLAUDE_API_KEY not set"
  end
end
