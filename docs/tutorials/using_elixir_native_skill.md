# Native Elixir Skills: Type-Safe In-Process Execution

Build skills as Elixir modules that execute directly in the BEAM with full access to your application.

**Time:** 25 minutes

**Prerequisites:** Complete [Hello World](hello_world.md) first.

## What You'll Build

1. A pure Elixir Echo skill (simple)
2. A Log Fetcher skill that calls REST APIs from Elixir (production)
3. Tests for native skills

## Why Native Skills?

| Aspect | Local Skills | Native Skills |
|--------|--------------|---------------|
| Language | Python, Bash, etc. | Elixir |
| Execution | Subprocess/shell | Direct function call |
| Overhead | Process spawn | None |
| Type Safety | Runtime errors | Compile-time checks |
| App Access | None | Full (Ecto, GenServers, etc.) |

Use native skills when you need:
- Direct access to your Elixir application state
- Faster execution without shell overhead
- Type-safe, pattern-matched implementations
- Integration with Ecto, Phoenix, GenServers

## The NativeSkill Behaviour

Native skills implement `Conjure.NativeSkill`:

```elixir
defmodule Conjure.NativeSkill do
  @callback __skill_info__() :: %{
    name: String.t(),
    description: String.t(),
    allowed_tools: [atom()]
  }

  # Optional callbacks based on allowed_tools
  @callback execute(command :: String.t(), context :: map()) ::
    {:ok, String.t()} | {:error, term()}

  @callback read(path :: String.t(), context :: map(), opts :: keyword()) ::
    {:ok, String.t()} | {:error, term()}

  @callback write(path :: String.t(), content :: String.t(), context :: map()) ::
    {:ok, String.t()} | {:error, term()}

  @callback modify(path :: String.t(), old :: String.t(), new :: String.t(), context :: map()) ::
    {:ok, String.t()} | {:error, term()}
end
```

### Callback Mapping

| Claude Tool | Native Callback | Purpose |
|-------------|-----------------|---------|
| `bash_tool` | `execute/2` | Run commands/logic |
| `view` | `read/3` | Read resources |
| `create_file` | `write/3` | Create resources |
| `str_replace` | `modify/4` | Update resources |

## Step 1: Create a Simple Echo Skill

Create `lib/my_app/skills/echo.ex`:

```elixir
defmodule MyApp.Skills.Echo do
  @moduledoc """
  A simple echo skill implemented in pure Elixir.
  """

  @behaviour Conjure.NativeSkill

  @impl true
  def __skill_info__ do
    %{
      name: "echo",
      description: "Echo messages back. Use this to test the native skill system.",
      allowed_tools: [:execute]
    }
  end

  @impl true
  def execute(message, _context) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    {:ok, "[#{timestamp}] Echo: #{message}"}
  end
end
```

## Step 2: Use the Echo Skill

```elixir
# Create a session with native skills
session = Conjure.Session.new_native([MyApp.Skills.Echo])

# Define API callback
api_callback = fn messages ->
  body = %{
    model: "claude-sonnet-4-5-20250929",
    max_tokens: 1024,
    messages: messages,
    tools: Conjure.Backend.Native.tool_definitions([MyApp.Skills.Echo])
  }

  Req.post("https://api.anthropic.com/v1/messages",
    json: body,
    headers: [
      {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
      {"anthropic-version", "2023-06-01"}
    ]
  )
  |> case do
    {:ok, %{status: 200, body: body}} -> {:ok, body}
    {:ok, %{body: body}} -> {:error, body}
    {:error, reason} -> {:error, reason}
  end
end

# Chat
{:ok, response, _session} = Conjure.Session.chat(
  session,
  "Please echo 'Hello from native Elixir!'",
  api_callback
)
```

## Step 3: Create a Log Fetcher Skill

A production skill that fetches logs directly from Elixir:

Create `lib/my_app/skills/log_fetcher.ex`:

```elixir
defmodule MyApp.Skills.LogFetcher do
  @moduledoc """
  Fetch logs from REST APIs using native Elixir HTTP client.
  """

  @behaviour Conjure.NativeSkill

  @impl true
  def __skill_info__ do
    %{
      name: "log-fetcher",
      description: """
      Fetch logs from monitoring APIs. Use this skill when you need to:
      - Retrieve logs from a REST endpoint
      - Filter logs by level or time range
      - Get log statistics
      """,
      allowed_tools: [:execute, :read]
    }
  end

  @impl true
  def execute(command, context) do
    case parse_command(command) do
      {:fetch, endpoint, opts} ->
        fetch_logs(endpoint, opts)

      {:stats, endpoint} ->
        get_stats(endpoint)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def read(path, _context, opts) do
    # "read" can list available endpoints or show help
    case path do
      "endpoints" ->
        {:ok, "Available endpoints:\n- /api/logs\n- /api/logs/stats\n- /api/logs/:id"}

      "help" ->
        {:ok, help_text()}

      _ ->
        {:error, "Unknown path: #{path}. Try 'endpoints' or 'help'."}
    end
  end

  # Command parsing

  defp parse_command(command) do
    cond do
      String.starts_with?(command, "fetch ") ->
        parse_fetch_command(command)

      String.starts_with?(command, "stats ") ->
        [_, endpoint] = String.split(command, " ", parts: 2)
        {:stats, String.trim(endpoint)}

      true ->
        {:error, "Unknown command. Use 'fetch <url>' or 'stats <url>'."}
    end
  end

  defp parse_fetch_command(command) do
    parts = String.split(command, " ")
    endpoint = Enum.at(parts, 1)

    opts = parts
    |> Enum.drop(2)
    |> Enum.chunk_every(2)
    |> Enum.reduce([], fn
      ["--limit", n], acc -> [{:limit, String.to_integer(n)} | acc]
      ["--level", level], acc -> [{:level, level} | acc]
      _, acc -> acc
    end)

    {:fetch, endpoint, opts}
  end

  # API calls

  defp fetch_logs(endpoint, opts) do
    limit = Keyword.get(opts, :limit, 100)
    level = Keyword.get(opts, :level)

    query = [limit: limit]
    query = if level, do: [{:level, level} | query], else: query

    case Req.get(endpoint, params: query) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.encode!(body, pretty: true)}

      {:ok, %{status: status, body: body}} ->
        {:error, "API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp get_stats(endpoint) do
    stats_url = endpoint <> "/stats"

    case Req.get(stats_url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.encode!(body, pretty: true)}

      {:ok, %{status: status}} ->
        {:error, "Stats API returned #{status}"}

      {:error, reason} ->
        {:error, "Failed to get stats: #{inspect(reason)}"}
    end
  end

  defp help_text do
    """
    Log Fetcher Commands:

    fetch <url> [--limit N] [--level LEVEL]
      Fetch logs from the specified URL.
      --limit N     Maximum logs to fetch (default: 100)
      --level LEVEL Filter by log level (DEBUG, INFO, WARN, ERROR)

    stats <url>
      Get log statistics from the endpoint.

    Examples:
      fetch http://monitoring.example.com/api/logs --limit 50
      fetch http://monitoring.example.com/api/logs --level ERROR
      stats http://monitoring.example.com/api/logs
    """
  end
end
```

## Step 4: Use the Log Fetcher

```elixir
session = Conjure.Session.new_native([MyApp.Skills.LogFetcher])

{:ok, response, _} = Conjure.Session.chat(
  session,
  "Fetch the last 50 error logs from http://monitoring.example.com/api/logs",
  &api_callback/1
)
```

## Step 5: Test Native Skills

Create `test/my_app/skills/echo_test.exs`:

```elixir
defmodule MyApp.Skills.EchoTest do
  use ExUnit.Case

  alias MyApp.Skills.Echo

  describe "__skill_info__/0" do
    test "returns valid skill info" do
      info = Echo.__skill_info__()

      assert info.name == "echo"
      assert is_binary(info.description)
      assert :execute in info.allowed_tools
    end
  end

  describe "execute/2" do
    test "echoes message with timestamp" do
      {:ok, result} = Echo.execute("Hello", %{})

      assert result =~ "Echo: Hello"
      assert result =~ ~r/\d{4}-\d{2}-\d{2}T/  # ISO timestamp
    end

    test "handles empty message" do
      {:ok, result} = Echo.execute("", %{})

      assert result =~ "Echo: "
    end
  end
end
```

Create `test/my_app/skills/log_fetcher_test.exs`:

```elixir
defmodule MyApp.Skills.LogFetcherTest do
  use ExUnit.Case

  alias MyApp.Skills.LogFetcher

  describe "__skill_info__/0" do
    test "declares execute and read tools" do
      info = LogFetcher.__skill_info__()

      assert :execute in info.allowed_tools
      assert :read in info.allowed_tools
    end
  end

  describe "read/3" do
    test "returns help text" do
      {:ok, help} = LogFetcher.read("help", %{}, [])

      assert help =~ "Log Fetcher Commands"
      assert help =~ "fetch"
      assert help =~ "stats"
    end

    test "returns error for unknown path" do
      {:error, message} = LogFetcher.read("unknown", %{}, [])

      assert message =~ "Unknown path"
    end
  end
end
```

Run tests:

```bash
mix test test/my_app/skills/
```

## Step 6: Integrate with Ecto

Native skills can access your database directly:

```elixir
defmodule MyApp.Skills.Database do
  @behaviour Conjure.NativeSkill

  @impl true
  def __skill_info__ do
    %{
      name: "database",
      description: "Query the application database for user and order information.",
      allowed_tools: [:execute, :read]
    }
  end

  @impl true
  def execute(query, _context) do
    case parse_query(query) do
      {:users, :count} ->
        count = MyApp.Repo.aggregate(MyApp.User, :count)
        {:ok, "Total users: #{count}"}

      {:users, :recent, limit} ->
        users = MyApp.Repo.all(
          from u in MyApp.User,
          order_by: [desc: u.inserted_at],
          limit: ^limit,
          select: %{id: u.id, email: u.email, created: u.inserted_at}
        )
        {:ok, Jason.encode!(users, pretty: true)}

      {:orders, :stats} ->
        stats = get_order_stats()
        {:ok, Jason.encode!(stats, pretty: true)}

      _ ->
        {:error, "Unknown query. Try 'count users' or 'recent users 10'."}
    end
  end

  @impl true
  def read(table, _context, opts) do
    case table do
      "users" -> {:ok, describe_table(MyApp.User)}
      "orders" -> {:ok, describe_table(MyApp.Order)}
      _ -> {:error, "Unknown table: #{table}"}
    end
  end

  defp describe_table(schema) do
    fields = schema.__schema__(:fields)
    types = Enum.map(fields, &{&1, schema.__schema__(:type, &1)})

    """
    Table: #{schema.__schema__(:source)}
    Fields:
    #{Enum.map_join(types, "\n", fn {f, t} -> "  - #{f}: #{t}" end)}
    """
  end
end
```

## Multiple Native Skills

Combine multiple native skills in one session:

```elixir
session = Conjure.Session.new_native([
  MyApp.Skills.Echo,
  MyApp.Skills.LogFetcher,
  MyApp.Skills.Database
])

# Claude can use any of these skills
{:ok, response, _} = Conjure.Session.chat(
  session,
  "First check how many users we have, then fetch recent error logs",
  &api_callback/1
)
```

## Tool Generation

Conjure automatically generates Claude tool definitions:

```elixir
tools = Conjure.Backend.Native.tool_definitions([MyApp.Skills.LogFetcher])

# Generates:
# [
#   %{
#     "name" => "log_fetcher_execute",
#     "description" => "Execute a command...",
#     "input_schema" => %{...}
#   },
#   %{
#     "name" => "log_fetcher_read",
#     "description" => "Read a resource...",
#     "input_schema" => %{...}
#   }
# ]
```

## Best Practices

1. **Keep skills focused** - One responsibility per skill
2. **Return structured data** - Use JSON for complex outputs
3. **Handle errors gracefully** - Return `{:error, reason}` with helpful messages
4. **Test thoroughly** - Native skills are easy to test with ExUnit
5. **Document commands** - Provide help text via the `read` callback

## Next Steps

- **[Unified Backends](many_skill_backends_one_agent.md)** - Combine Native, Local, and Anthropic backends
- **[README](../../README.md)** - Full API reference
