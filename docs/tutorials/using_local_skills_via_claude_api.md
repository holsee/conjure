# Local Skills with Claude API

Build a production log analyzer skill and integrate it with Claude for interactive diagnostics.

**Time:** 30 minutes

**Prerequisites:** Complete [Hello World](hello_world.md) first.

## What You'll Build

A log analysis skill that:
- Fetches logs from a REST API
- Parses and filters log entries
- Analyzes patterns and errors
- Provides diagnostic recommendations

## Understanding Skill Structure

Before building, let's understand how skills are organized:

```
log-analyzer/
├── SKILL.md              # Skill definition (required)
├── scripts/              # Executable scripts
│   ├── fetch_logs.py     # Fetch logs from API
│   ├── parse_logs.py     # Parse log formats
│   └── analyze.py        # Analyze patterns
└── references/           # Documentation for Claude
    └── log_formats.md    # Supported formats
```

### SKILL.md Components

The SKILL.md file has two parts:

1. **YAML Frontmatter** - Metadata for skill discovery:

```yaml
---
name: log-analyzer
description: |
  Production log analysis skill. Use when asked to:
  - Fetch and analyze logs
  - Diagnose production issues
license: MIT
compatibility:
  products: [api]
  packages: [python3, requests]
allowed_tools: [bash_tool, view, create_file]
---
```

2. **Markdown Body** - Instructions for Claude:

```markdown
# Log Analyzer Skill

## Available Scripts

### fetch_logs.py
Fetches logs from REST API...

### analyze.py
Analyzes log patterns...
```

## Step 1: Create the Skill Directory

```bash
mkdir -p priv/skills/log-analyzer/{scripts,references}
```

## Step 2: Create SKILL.md

Create `priv/skills/log-analyzer/SKILL.md`:

```markdown
---
name: log-analyzer
description: |
  Production log analysis and diagnostics skill. Use this skill when asked to:
  - Fetch logs from a monitoring API
  - Analyze log patterns and errors
  - Diagnose production issues
  - Generate log summaries
license: MIT
compatibility:
  products: [api]
  packages: [python3]
allowed_tools: [bash_tool, view, create_file]
---

# Log Analyzer Skill

A production monitoring skill for analyzing application logs.

## Available Scripts

### 1. Fetch Logs

\`\`\`bash
python3 scripts/fetch_logs.py --endpoint "http://api.example.com/logs" --limit 100
\`\`\`

Options:
- \`--endpoint\` - REST API URL (required)
- \`--limit\` - Max logs to fetch
- \`--level\` - Filter by level (DEBUG, INFO, WARN, ERROR)
- \`--output\` - Save to file

### 2. Analyze Logs

\`\`\`bash
python3 scripts/analyze.py logs.json --summary
python3 scripts/analyze.py logs.json --errors-only
python3 scripts/analyze.py logs.json --diagnostics
\`\`\`

## Workflow

1. Fetch recent logs
2. Analyze for patterns
3. Generate diagnostics
```

## Step 3: Create the Fetch Script

Create `priv/skills/log-analyzer/scripts/fetch_logs.py`:

```python
#!/usr/bin/env python3
"""Fetch logs from REST API."""

import argparse
import json
import sys
from datetime import datetime


def simulate_logs(limit: int, level: str = None) -> list:
    """Simulate log API response for demo."""
    samples = [
        ("INFO", "Request received: GET /api/users"),
        ("WARN", "Slow query: 2.5s for user lookup"),
        ("ERROR", "Connection timeout to payment service"),
        ("INFO", "Request completed: 200 OK"),
        ("ERROR", "Database connection failed"),
    ]

    logs = []
    for i in range(min(limit, 50)):
        log_level, message = samples[i % len(samples)]
        if level and log_level != level:
            continue

        logs.append({
            "timestamp": datetime.now().isoformat(),
            "level": log_level,
            "service": "api-gateway",
            "message": message,
            "host": f"prod-server-{(i % 3) + 1}",
        })

    return logs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--level", choices=["DEBUG", "INFO", "WARN", "ERROR"])
    parser.add_argument("--output")
    args = parser.parse_args()

    logs = simulate_logs(args.limit, args.level)

    output = json.dumps(logs, indent=2)
    if args.output:
        with open(args.output, "w") as f:
            f.write(output)
        print(f"Saved {len(logs)} logs to {args.output}")
    else:
        print(output)


if __name__ == "__main__":
    main()
```

Make it executable:

```bash
chmod +x priv/skills/log-analyzer/scripts/fetch_logs.py
```

## Step 4: Create the Analyze Script

Create `priv/skills/log-analyzer/scripts/analyze.py`:

```python
#!/usr/bin/env python3
"""Analyze logs for patterns and errors."""

import argparse
import json
from collections import Counter


def load_logs(filepath: str) -> list:
    with open(filepath) as f:
        return json.loads(f.read())


def analyze_summary(logs: list) -> dict:
    levels = Counter(log.get("level", "INFO") for log in logs)
    error_rate = levels.get("ERROR", 0) / len(logs) * 100 if logs else 0

    return {
        "total_logs": len(logs),
        "level_breakdown": dict(levels),
        "error_rate": f"{error_rate:.1f}%",
        "health": "CRITICAL" if error_rate > 10 else "HEALTHY",
    }


def analyze_errors(logs: list) -> dict:
    errors = [l for l in logs if l.get("level") == "ERROR"]
    messages = Counter(e.get("message", "")[:50] for e in errors)

    return {
        "total_errors": len(errors),
        "top_errors": messages.most_common(5),
    }


def generate_diagnostics(logs: list) -> list:
    errors = " ".join(l.get("message", "") for l in logs if l.get("level") == "ERROR")
    diagnostics = []

    if "timeout" in errors.lower():
        diagnostics.append({"issue": "Timeout errors", "priority": "HIGH"})
    if "connection" in errors.lower():
        diagnostics.append({"issue": "Connection failures", "priority": "HIGH"})

    return diagnostics or [{"issue": "No critical issues", "priority": "LOW"}]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("file")
    parser.add_argument("--summary", action="store_true")
    parser.add_argument("--errors-only", action="store_true")
    parser.add_argument("--diagnostics", action="store_true")
    args = parser.parse_args()

    logs = load_logs(args.file)

    if args.summary:
        print(json.dumps(analyze_summary(logs), indent=2))
    elif args.errors_only:
        print(json.dumps(analyze_errors(logs), indent=2))
    elif args.diagnostics:
        print(json.dumps(generate_diagnostics(logs), indent=2))
    else:
        print(json.dumps({
            "summary": analyze_summary(logs),
            "errors": analyze_errors(logs),
            "diagnostics": generate_diagnostics(logs),
        }, indent=2))


if __name__ == "__main__":
    main()
```

Make it executable:

```bash
chmod +x priv/skills/log-analyzer/scripts/analyze.py
```

## Step 5: Test the Skill Manually

```bash
# Fetch logs
python3 priv/skills/log-analyzer/scripts/fetch_logs.py \
  --endpoint "http://localhost/api/logs" \
  --limit 20 \
  --output /tmp/logs.json

# Analyze
python3 priv/skills/log-analyzer/scripts/analyze.py /tmp/logs.json --summary
```

## Step 6: Create the Agent

Create `lib/my_app/log_agent.ex`:

```elixir
defmodule MyApp.LogAgent do
  @moduledoc """
  An agent that uses the log-analyzer skill for production diagnostics.
  """

  @api_url "https://api.anthropic.com/v1/messages"

  def diagnose(question) do
    {:ok, skills} = Conjure.load("priv/skills")
    session = Conjure.Session.new_local(skills)

    case Conjure.Session.chat(session, question, &api_callback/1) do
      {:ok, response, _session} ->
        {:ok, extract_text(response)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp api_callback(messages) do
    {:ok, skills} = Conjure.load("priv/skills")

    body = %{
      model: "claude-sonnet-4-5-20250929",
      max_tokens: 4096,
      system: system_prompt(skills),
      messages: messages,
      tools: Conjure.tool_definitions()
    }

    case Req.post(@api_url, json: body, headers: headers()) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp system_prompt(skills) do
    """
    You are a production support engineer with access to log analysis tools.
    When diagnosing issues:
    1. First fetch recent logs
    2. Analyze for patterns
    3. Provide clear diagnostics

    #{Conjure.system_prompt(skills)}
    """
  end

  defp headers do
    [
      {"x-api-key", api_key()},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  defp extract_text(%{"content" => content}) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp api_key do
    System.get_env("ANTHROPIC_API_KEY") ||
      raise "ANTHROPIC_API_KEY not set"
  end
end
```

## Step 7: Run a Diagnostic Session

```elixir
# In IEx
MyApp.LogAgent.diagnose("""
We're seeing slow response times in production.
Please fetch the last 50 logs from http://monitoring.example.com/api/logs
and analyze them for issues.
""")
```

Expected interaction:

```
[Claude reads SKILL.md]
[Claude calls: fetch_logs.py --endpoint "..." --limit 50 --output /tmp/logs.json]
[Claude calls: analyze.py /tmp/logs.json --summary]
[Claude calls: analyze.py /tmp/logs.json --diagnostics]

Based on my analysis of the last 50 logs:

**Summary:**
- Total logs: 50
- Error rate: 20%
- Health status: CRITICAL

**Issues Found:**
1. Connection timeout errors to payment service (HIGH priority)
2. Database connection failures (HIGH priority)

**Recommendations:**
1. Check payment service connectivity
2. Review database connection pool settings
3. Consider increasing connection timeouts
```

## Multi-Turn Conversations

The Session API maintains conversation state:

```elixir
{:ok, skills} = Conjure.load("priv/skills")
session = Conjure.Session.new_local(skills)

# First turn
{:ok, response1, session} = Conjure.Session.chat(
  session,
  "Fetch the last 100 logs from http://api.example.com/logs",
  &api_callback/1
)

# Second turn (continues the conversation)
{:ok, response2, session} = Conjure.Session.chat(
  session,
  "Now show me only the errors",
  &api_callback/1
)

# Third turn
{:ok, response3, _session} = Conjure.Session.chat(
  session,
  "What's causing these errors?",
  &api_callback/1
)
```

## Adding Callbacks for Visibility

Monitor tool calls in real-time:

```elixir
opts = [
  on_tool_call: fn call ->
    IO.puts("Tool: #{call.name}")
    IO.puts("Input: #{inspect(call.input)}")
  end,
  on_tool_result: fn result ->
    IO.puts("Result: #{String.slice(result.content, 0, 100)}...")
  end
]

Conjure.Conversation.run_loop(messages, skills, &api_callback/1, opts)
```

## Troubleshooting

### "Skill not found"

Verify the skill structure:

```bash
ls -la priv/skills/log-analyzer/
# Should show: SKILL.md, scripts/, references/
```

### Script execution fails

Test scripts manually:

```bash
python3 priv/skills/log-analyzer/scripts/fetch_logs.py --help
```

### "No module named requests"

For production, install dependencies:

```bash
pip install requests
```

The demo scripts simulate API responses, so `requests` isn't required for learning.

## Next Steps

- **[Anthropic Skills API](using_claude_skill_with_elixir_host.md)** - Generate incident reports as spreadsheets
- **[Native Elixir Skills](using_elixir_native_skill.md)** - Fetch logs directly from Elixir
- **[Unified Backends](many_skill_backends_one_agent.md)** - Combine all approaches
