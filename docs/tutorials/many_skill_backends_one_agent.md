# Unified Backend Patterns: Building a Complete Monitoring Agent

Combine Native, Local, and Anthropic backends into a production-ready monitoring solution.

**Time:** 30 minutes

**Prerequisites:** Complete all previous tutorials.

## What You'll Build

A monitoring agent that uses all three backends:

```
┌────────────────────────────────────────────────────────┐
│                    Monitoring Agent                    │
├────────────────────────────────────────────────────────┤
│                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   Native     │  │    Local     │  │  Anthropic   │  │
│  │   Backend    │  │   Backend    │  │   Backend    │  │
│  ├──────────────┤  ├──────────────┤  ├──────────────┤  │
│  │ Log Fetcher  │  │ Log Analyzer │  │ Report Gen   │  │
│  │ (REST API)   │  │ (Python)     │  │ (xlsx, pdf)  │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                        │
└────────────────────────────────────────────────────────┘
```

1. **Native**: Fast log fetching from REST API (in-process)
2. **Local**: Python-based log analysis (shell execution)
3. **Anthropic**: Generate incident reports (xlsx, pdf)

## The Backend Behaviour

All backends implement `Conjure.Backend`:

```elixir
@callback backend_type() :: atom()
@callback new_session(skills :: term(), opts :: keyword()) :: Session.t()
@callback chat(session, message, api_callback, opts) :: {:ok, response, session} | {:error, term()}
```

Available backends:

| Backend | Module | Use Case |
|---------|--------|----------|
| Local | `Conjure.Backend.Local` | Development, shell scripts |
| Docker | `Conjure.Backend.Docker` | Production, sandboxed |
| Anthropic | `Conjure.Backend.Anthropic` | Document generation |
| Native | `Conjure.Backend.Native` | In-process Elixir |

## Step 1: Create the Native Log Fetcher

Create `lib/my_app/skills/log_fetcher.ex`:

```elixir
defmodule MyApp.Skills.LogFetcher do
  @behaviour Conjure.NativeSkill

  @impl true
  def __skill_info__ do
    %{
      name: "log-fetcher",
      description: "Fetch logs from monitoring API. Fast, in-process execution.",
      allowed_tools: [:execute]
    }
  end

  @impl true
  def execute(command, _context) do
    case parse_command(command) do
      {:fetch, url, opts} ->
        fetch_logs(url, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_command("fetch " <> rest) do
    [url | args] = String.split(rest)
    opts = parse_args(args)
    {:fetch, url, opts}
  end

  defp parse_command(_), do: {:error, "Use: fetch <url> [--limit N] [--level LEVEL]"}

  defp parse_args(args) do
    args
    |> Enum.chunk_every(2)
    |> Enum.reduce([limit: 100], fn
      ["--limit", n], acc -> Keyword.put(acc, :limit, String.to_integer(n))
      ["--level", l], acc -> Keyword.put(acc, :level, l)
      _, acc -> acc
    end)
  end

  defp fetch_logs(url, opts) do
    case Req.get(url, params: opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.encode!(body, pretty: true)}

      {:ok, %{status: status}} ->
        {:error, "API returned #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
```

## Step 2: Set Up Local Log Analyzer

Use the log-analyzer skill from the [Local Skills tutorial](using_local_skills_via_claude_api.md):

```
priv/skills/log-analyzer/
├── SKILL.md
├── scripts/
│   ├── fetch_logs.py
│   ├── parse_logs.py
│   └── analyze.py
└── references/
    └── log_formats.md
```

## Step 3: Create the Unified Agent

Create `lib/my_app/monitoring_agent.ex`:

```elixir
defmodule MyApp.MonitoringAgent do
  @moduledoc """
  A monitoring agent that uses multiple backends for different tasks.
  """

  alias Conjure.Session

  @doc """
  Analyze logs using the most appropriate backend for each step.
  """
  def analyze(log_api_url, opts \\ []) do
    # Step 1: Fetch logs using Native backend (fast, in-process)
    {:ok, logs} = fetch_logs_native(log_api_url, opts)

    # Step 2: Analyze using Local backend (Python scripts)
    {:ok, analysis} = analyze_logs_local(logs)

    # Step 3: Generate report using Anthropic backend (xlsx)
    if Keyword.get(opts, :generate_report, false) do
      {:ok, report_files} = generate_report_anthropic(analysis)
      {:ok, %{logs: logs, analysis: analysis, report_files: report_files}}
    else
      {:ok, %{logs: logs, analysis: analysis}}
    end
  end

  @doc """
  Interactive monitoring session with backend selection.
  """
  def start_session(backend_type, skills_or_modules) do
    case backend_type do
      :native ->
        Session.new_native(skills_or_modules)

      :local ->
        {:ok, skills} = Conjure.load("priv/skills")
        Session.new_local(skills)

      :docker ->
        {:ok, skills} = Conjure.load("priv/skills")
        Session.new_local(skills, executor: Conjure.Executor.Docker)

      :anthropic ->
        Session.new_anthropic(skills_or_modules)
    end
  end

  # Private implementation

  defp fetch_logs_native(url, opts) do
    session = Session.new_native([MyApp.Skills.LogFetcher])
    limit = Keyword.get(opts, :limit, 100)

    Session.chat(
      session,
      "fetch #{url} --limit #{limit}",
      &native_api_callback/1
    )
  end

  defp analyze_logs_local(logs) do
    {:ok, skills} = Conjure.load("priv/skills")
    session = Session.new_local(skills)

    # Save logs to temp file for Python analysis
    log_file = Path.join(System.tmp_dir!(), "logs_#{:rand.uniform(10000)}.json")
    File.write!(log_file, logs)

    result = Session.chat(
      session,
      "Analyze the logs in #{log_file} and provide a summary with diagnostics",
      &local_api_callback/1
    )

    File.rm(log_file)
    result
  end

  defp generate_report_anthropic(analysis) do
    session = Session.new_anthropic([{:anthropic, "xlsx", "latest"}])

    {:ok, response, session} = Session.chat(
      session,
      """
      Create an incident report spreadsheet with:
      1. Executive Summary sheet with key metrics
      2. Error Details sheet with error breakdown
      3. Recommendations sheet with action items

      Analysis data:
      #{analysis}
      """,
      &anthropic_api_callback/1
    )

    {:ok, Session.get_created_files(session)}
  end

  # API callbacks for each backend

  defp native_api_callback(messages) do
    tools = Conjure.Backend.Native.tool_definitions([MyApp.Skills.LogFetcher])
    make_api_call(messages, tools: tools)
  end

  defp local_api_callback(messages) do
    {:ok, skills} = Conjure.load("priv/skills")
    system = "You are a log analysis assistant.\n\n" <> Conjure.system_prompt(skills)
    make_api_call(messages, system: system, tools: Conjure.tool_definitions())
  end

  defp anthropic_api_callback(messages) do
    {:ok, container} = Conjure.API.Anthropic.container_config([{:anthropic, "xlsx", "latest"}])

    body = %{
      "model" => "claude-sonnet-4-5-20250929",
      "max_tokens" => 4096,
      "messages" => messages,
      "tools" => [Conjure.API.Anthropic.code_execution_tool()],
      "container" => container
    }

    headers = base_headers() ++ Conjure.API.Anthropic.beta_headers()

    case Req.post("https://api.anthropic.com/v1/messages", json: body, headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp make_api_call(messages, opts) do
    body = %{
      "model" => "claude-sonnet-4-5-20250929",
      "max_tokens" => 4096,
      "messages" => messages
    }

    body = if tools = opts[:tools], do: Map.put(body, "tools", tools), else: body
    body = if system = opts[:system], do: Map.put(body, "system", system), else: body

    case Req.post("https://api.anthropic.com/v1/messages", json: body, headers: base_headers()) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_headers do
    [
      {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end
end
```

## Step 4: Use the Unified Agent

```elixir
# Quick analysis (Native + Local)
{:ok, result} = MyApp.MonitoringAgent.analyze(
  "http://monitoring.example.com/api/logs",
  limit: 200
)

IO.puts(result.analysis)

# Full analysis with report (Native + Local + Anthropic)
{:ok, result} = MyApp.MonitoringAgent.analyze(
  "http://monitoring.example.com/api/logs",
  limit: 500,
  generate_report: true
)

# Download the report
MyApp.DocumentAgent.download_files(result.report_files, "/tmp/reports")
```

## Step 5: Dynamic Backend Selection

Create a flexible agent that selects backends at runtime:

```elixir
defmodule MyApp.FlexibleAgent do
  @doc """
  Chat with dynamic backend selection.
  """
  def chat(message, backend, skills) do
    session = case backend do
      :native -> Conjure.Session.new_native(skills)
      :local -> Conjure.Session.new_local(skills)
      :docker -> Conjure.Session.new_local(skills, executor: Conjure.Executor.Docker)
      :anthropic -> Conjure.Session.new_anthropic(skills)
    end

    Conjure.Session.chat(session, message, &api_callback(backend)/1)
  end

  defp api_callback(:anthropic) do
    fn messages -> anthropic_callback(messages) end
  end

  defp api_callback(_backend) do
    fn messages -> standard_callback(messages) end
  end
end
```

## Step 6: Production Patterns

### Environment-Based Backend Selection

```elixir
defmodule MyApp.Config do
  def default_executor do
    case Mix.env() do
      :dev -> Conjure.Executor.Local
      :test -> Conjure.Executor.Local
      :prod -> Conjure.Executor.Docker
    end
  end
end

# Usage
session = Conjure.Session.new_local(skills, executor: MyApp.Config.default_executor())
```

### Use the GenServer Registry

```elixir
# In application.ex
children = [
  {Conjure.Registry, name: MyApp.Skills, paths: ["priv/skills"]}
]

# In your agent
def analyze(message) do
  skills = Conjure.Registry.list(MyApp.Skills)
  session = Conjure.Session.new_local(skills)
  Conjure.Session.chat(session, message, &api_callback/1)
end

# Reload skills at runtime
Conjure.Registry.reload(MyApp.Skills)
```

### Telemetry Integration

```elixir
# Attach telemetry handlers
:telemetry.attach_many(
  "monitoring-agent",
  [
    [:conjure, :backend, :native, :tool_call],
    [:conjure, :execute, :start],
    [:conjure, :execute, :stop]
  ],
  &handle_event/4,
  nil
)

defp handle_event(event, measurements, metadata, _config) do
  Logger.info("#{inspect(event)}: #{inspect(measurements)}")
end
```

## Backend Comparison

| Aspect | Native | Local | Docker | Anthropic |
|--------|--------|-------|--------|-----------|
| Speed | Fastest | Fast | Slower | Network |
| Safety | Full access | Shell access | Sandboxed | Cloud sandbox |
| Dependencies | Elixir only | Any | Any (containerized) | None |
| Use Case | App integration | Scripts | Production | Documents |

## When to Use Each Backend

### Native Backend
- Accessing Ecto repositories
- Reading from GenServers/ETS
- High-frequency operations
- Type-safe implementations

### Local Backend
- Python/Node.js scripts
- Complex data processing
- Development/testing
- Quick prototyping

### Docker Backend
- Production execution
- Untrusted code
- Isolated environments
- Reproducible builds

### Anthropic Backend
- Document generation
- Spreadsheet creation
- PDF reports
- No local dependencies

## Complete Example

```elixir
defmodule MyApp.ProductionAgent do
  @moduledoc """
  Production-ready agent combining all backends.
  """

  def diagnose_and_report(log_url) do
    with {:ok, logs} <- fetch_logs(log_url),
         {:ok, analysis} <- analyze_logs(logs),
         {:ok, files} <- generate_report(analysis) do
      {:ok, %{
        logs_fetched: count_logs(logs),
        health_status: analysis.health,
        report_files: files
      }}
    end
  end

  # Fast log fetching with Native
  defp fetch_logs(url) do
    session = Conjure.Session.new_native([MyApp.Skills.LogFetcher])
    Conjure.Session.chat(session, "fetch #{url} --limit 500", &native_callback/1)
  end

  # Python analysis with Docker (production safe)
  defp analyze_logs(logs) do
    {:ok, skills} = Conjure.load("priv/skills")
    session = Conjure.Session.new_local(skills, executor: Conjure.Executor.Docker)
    Conjure.Session.chat(session, "Analyze these logs: #{logs}", &local_callback/1)
  end

  # Document generation with Anthropic
  defp generate_report(analysis) do
    session = Conjure.Session.new_anthropic([{:anthropic, "xlsx", "latest"}])
    {:ok, _, session} = Conjure.Session.chat(session, report_prompt(analysis), &anthropic_callback/1)
    {:ok, Conjure.Session.get_created_files(session)}
  end
end
```

## Summary

You've learned to:

1. Use the unified Session API across all backends
2. Select backends based on task requirements
3. Combine backends for complex workflows
4. Apply production patterns (Registry, Telemetry, Docker)

## Next Steps

- Review [Architecture Decision Records](adr-index.html) for design rationale
- Explore the API Reference (module documentation) for advanced options
- Build your own production monitoring solution!
