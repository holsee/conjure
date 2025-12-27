# Hello World: Your First Conjure Agent

Get Conjure running in 10 minutes with a simple Echo skill.

**Time:** 10 minutes

## What You'll Build

A minimal agent that:
1. Loads an Echo skill
2. Connects to Claude API
3. Runs a conversation where Claude uses the skill

## Prerequisites

- **Elixir 1.14+** and **Erlang/OTP 25+**
- **Anthropic API key** from [console.anthropic.com](https://console.anthropic.com)
- **Python 3.8+** (for the Echo skill script)

Verify your setup:

```bash
elixir --version
# Elixir 1.16.0 (compiled with Erlang/OTP 26)

python3 --version
# Python 3.11.0
```

## Step 1: Create a New Project

```bash
mix new hello_conjure --sup
cd hello_conjure
```

## Step 2: Add Dependencies

Edit `mix.exs`:

```elixir
defp deps do
  [
    {:conjure, "~> 0.1.0"},
    {:req, "~> 0.4"}
  ]
end
```

Fetch dependencies:

```bash
mix deps.get
```

## Step 3: Configure Your API Key

Create `config/config.exs`:

```elixir
import Config

config :hello_conjure,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")
```

Set your API key:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

## Step 4: Create the Echo Skill

Create the skill directory:

```bash
mkdir -p priv/skills/echo/scripts
```

Create `priv/skills/echo/SKILL.md`:

```markdown
---
name: echo
description: |
  A simple echo skill for testing. Use this when asked to echo or repeat messages.
license: MIT
compatibility: python3
allowed-tools: Bash(python3:*) Read
---

# Echo Skill

To echo a message, run:

\`\`\`bash
python3 scripts/echo.py "Your message here"
\`\`\`
```

Create `priv/skills/echo/scripts/echo.py`:

```python
#!/usr/bin/env python3
import sys
from datetime import datetime

def main():
    if len(sys.argv) < 2:
        print("Usage: echo.py <message>")
        sys.exit(1)

    message = " ".join(sys.argv[1:])
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] Echo: {message}")

if __name__ == "__main__":
    main()
```

Make it executable:

```bash
chmod +x priv/skills/echo/scripts/echo.py
```

Test the skill manually:

```bash
python3 priv/skills/echo/scripts/echo.py "Hello, World!"
# [2024-01-15 10:30:00] Echo: Hello, World!
```

## Step 5: Create the Agent Module

Create `lib/hello_conjure/agent.ex`:

```elixir
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
      System.get_env("ANTHROPIC_API_KEY") ||
      raise "ANTHROPIC_API_KEY not set"
  end
end
```

## Step 6: Run Your First Conversation

Start IEx:

```bash
iex -S mix
```

Chat with your agent:

```elixir
HelloConjure.Agent.chat("Please echo 'Hello from Conjure!'")
```

You should see output like:

```
Loaded 1 skill(s)

Claude: I'll use the echo skill to echo your message.

[Tool call: bash_tool with command: python3 scripts/echo.py "Hello from Conjure!"]

The echo skill returned:
[2024-01-15 10:35:00] Echo: Hello from Conjure!
```

## What Just Happened?

1. **Skill Loading**: Conjure loaded the Echo skill from `priv/skills/`
2. **System Prompt**: The skills section was added to Claude's system prompt
3. **Skill Discovery**: Claude read the SKILL.md to understand capabilities
4. **Tool Execution**: Claude used `bash_tool` to run the echo script
5. **Response**: Claude formatted and returned the result

## Next Steps

You've built your first Conjure agent! Continue learning:

- **[Local Skills with Claude](using_local_skills_via_claude_api.md)** - Build a production log analyzer
- **[Anthropic Skills API](using_claude_skill_with_elixir_host.md)** - Generate documents with hosted execution
- **[Native Elixir Skills](using_elixir_native_skill.md)** - Build type-safe skills in pure Elixir

## Troubleshooting

### "ANTHROPIC_API_KEY not set"

Ensure your API key is exported:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### "Skill not found"

Check the skill directory exists:

```bash
ls priv/skills/echo/SKILL.md
```

### Python script errors

Ensure Python 3 is installed and the script is executable:

```bash
python3 --version
chmod +x priv/skills/echo/scripts/echo.py
```

### Tool execution fails

Try running the script manually:

```bash
cd priv/skills/echo
python3 scripts/echo.py "test"
```
