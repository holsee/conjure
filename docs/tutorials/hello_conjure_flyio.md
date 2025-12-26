# Fly.io with Tigris Storage

Build an incident response system on Fly.io where Claude generates structured runbooks and a Native skill safely executes them.

**Time:** 35 minutes

**Prerequisites:**
- Complete [Native Elixir Skills](using_elixir_native_skill.md) tutorial
- [Fly.io CLI](https://fly.io/docs/getting-started/installing-flyctl/) installed
- Fly.io account (free tier works)

## What You'll Build

An incident response service demonstrating a two-phase skill pipeline:

1. **Claude (Anthropic) Skill**: Analyzes incident descriptions and generates structured runbook artifacts
2. **Native Skill**: Validates runbooks against a schema, enforces action allow-lists, and executes safe dry-runs

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            Fly.io Machine                               │
│                                                                         │
│  ┌────────────┐    ┌──────────────────┐    ┌─────────────────────────┐  │
│  │   User     │───▶│  Claude Skill    │───▶│  Runbook Artifact       │  │
│  │  Request   │    │  (Anthropic API) │    │  (JSON in Tigris)       │  │
│  └────────────┘    └──────────────────┘    └───────────┬─────────────┘  │
│                                                        │                │
│                                                        ▼                │
│                                            ┌─────────────────────────┐  │
│                                            │  Native Executor Skill  │  │
│                                            │  - Schema validation    │  │
│                                            │  - Action allow-list    │  │
│                                            │  - Safe dry-run         │  │
│                                            └───────────┬─────────────┘  │
│                                                        │                │
│                                                        ▼                │
│                                            ┌─────────────────────────┐  │
│                                            │  Execution Results      │  │
│                                            │  (auditable output)     │  │
│                                            └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

**Why this pattern?**

| Responsibility | Claude Skill | Native Skill |
|----------------|--------------|--------------|
| Reasoning | ✓ Analyzes problems | |
| Planning | ✓ Generates runbooks | |
| Validation | | ✓ Schema enforcement |
| Safety | | ✓ Action allow-listing |
| Execution | | ✓ Deterministic dry-run |

Claude reasons and plans. Native code executes safely. The runbook artifact is the contract between them.

## Step 1: Create the Fly.io Application

Generate a new Phoenix application:

```bash
mix phx.new incident_response --database postgres
cd incident_response
```

Add Conjure and dependencies to `mix.exs`:

```elixir
defp deps do
  [
    # ... existing deps ...
    {:conjure, "~> 0.1.0"},
    {:req, "~> 0.5"}
  ]
end
```

Get dependencies:

```bash
mix deps.get
```

## Step 2: Set Up Fly.io Infrastructure

Launch the Fly app with Postgres:

```bash
fly launch --name my-incident-response
```

Create a Tigris storage bucket for runbook artifacts:

```bash
fly storage create incident-runbooks
```

This automatically configures environment variables:
- `BUCKET_NAME` - Your Tigris bucket name
- `AWS_ACCESS_KEY_ID` - Tigris access key
- `AWS_SECRET_ACCESS_KEY` - Tigris secret key
- `AWS_ENDPOINT_URL_S3` - Tigris endpoint

Set your Anthropic API key:

```bash
fly secrets set ANTHROPIC_API_KEY=sk-ant-...
```

## Step 3: Define the Runbook Schema

Create `lib/incident_response/runbooks/schema.ex`:

```elixir
defmodule IncidentResponse.Runbooks.Schema do
  @moduledoc """
  Defines the runbook artifact contract between Claude and the executor.

  This schema is the boundary between LLM reasoning and safe execution.
  """

  @type check :: %{
    id: String.t(),
    action: String.t(),
    params: map()
  }

  @type recommended_action :: %{
    id: String.t(),
    action: String.t(),
    safe: boolean(),
    params: map()
  }

  @type runbook :: %{
    incident_type: String.t(),
    affected_system: String.t(),
    confidence: float(),
    hypotheses: [String.t()],
    checks: [check()],
    recommended_actions: [recommended_action()],
    rollback_plan: String.t()
  }

  @required_keys ~w(incident_type affected_system confidence checks recommended_actions)a

  @doc """
  Validates a runbook artifact against the schema.

  Returns `{:ok, runbook}` if valid, `{:error, reasons}` otherwise.
  """
  def validate(runbook) when is_map(runbook) do
    with :ok <- validate_required_keys(runbook),
         :ok <- validate_confidence(runbook),
         :ok <- validate_checks(runbook),
         :ok <- validate_actions(runbook) do
      {:ok, normalize(runbook)}
    end
  end

  def validate(_), do: {:error, ["runbook must be a map"]}

  defp validate_required_keys(runbook) do
    missing = @required_keys -- Map.keys(runbook)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, ["missing required keys: #{inspect(missing)}"]}
    end
  end

  defp validate_confidence(%{confidence: c}) when is_number(c) and c >= 0 and c <= 1, do: :ok
  defp validate_confidence(%{confidence: c}), do: {:error, ["confidence must be 0.0-1.0, got: #{inspect(c)}"]}

  defp validate_checks(%{checks: checks}) when is_list(checks) do
    errors =
      checks
      |> Enum.with_index()
      |> Enum.flat_map(fn {check, i} ->
        validate_check(check, i)
      end)

    if Enum.empty?(errors), do: :ok, else: {:error, errors}
  end

  defp validate_checks(_), do: {:error, ["checks must be a list"]}

  defp validate_check(check, index) do
    required = ~w(id action)

    missing =
      required
      |> Enum.reject(&Map.has_key?(check, &1))

    if Enum.empty?(missing) do
      []
    else
      ["check[#{index}] missing: #{Enum.join(missing, ", ")}"]
    end
  end

  defp validate_actions(%{recommended_actions: actions}) when is_list(actions) do
    errors =
      actions
      |> Enum.with_index()
      |> Enum.flat_map(fn {action, i} ->
        validate_action(action, i)
      end)

    if Enum.empty?(errors), do: :ok, else: {:error, errors}
  end

  defp validate_actions(_), do: {:error, ["recommended_actions must be a list"]}

  defp validate_action(action, index) do
    cond do
      not Map.has_key?(action, "id") and not Map.has_key?(action, :id) ->
        ["action[#{index}] missing: id"]

      not Map.has_key?(action, "action") and not Map.has_key?(action, :action) ->
        ["action[#{index}] missing: action"]

      true ->
        []
    end
  end

  defp normalize(runbook) do
    runbook
    |> Map.put_new(:hypotheses, [])
    |> Map.put_new(:rollback_plan, "No rollback plan specified")
    |> Map.update(:checks, [], &normalize_checks/1)
    |> Map.update(:recommended_actions, [], &normalize_actions/1)
  end

  defp normalize_checks(checks) do
    Enum.map(checks, fn check ->
      check
      |> Map.put_new(:params, %{})
      |> atomize_keys()
    end)
  end

  defp normalize_actions(actions) do
    Enum.map(actions, fn action ->
      action
      |> Map.put_new(:params, %{})
      |> Map.put_new(:safe, false)
      |> atomize_keys()
    end)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end
end
```

## Step 4: Create the Runbook Generator (Claude Skill)

Create `lib/incident_response/skills/runbook_generator.ex`:

```elixir
defmodule IncidentResponse.Skills.RunbookGenerator do
  @moduledoc """
  Claude skill that analyzes incidents and generates structured runbooks.

  This skill does NO execution - it only reasons about the problem
  and produces a machine-readable artifact for the executor skill.
  """

  alias IncidentResponse.Runbooks.Schema
  alias Conjure.Session

  require Logger

  @system_prompt """
  You are an incident response analyst. When given an incident description,
  analyze the problem and generate a structured runbook for investigation.

  IMPORTANT: You must output a valid JSON runbook with this exact structure:

  {
    "incident_type": "performance_degradation|outage|data_issue|security",
    "affected_system": "string - the primary system affected",
    "confidence": 0.0-1.0,
    "hypotheses": ["list of possible root causes"],
    "checks": [
      {
        "id": "unique_check_id",
        "action": "system.operation_name",
        "params": { "key": "value" }
      }
    ],
    "recommended_actions": [
      {
        "id": "unique_action_id",
        "action": "system.operation_name",
        "safe": true/false,
        "params": { "key": "value" }
      }
    ],
    "rollback_plan": "description of how to revert if needed"
  }

  Available check actions:
  - database.slow_queries - params: {lookback_minutes}
  - database.table_stats - params: {table}
  - database.connection_count - params: {}
  - metrics.query - params: {query, range_minutes}
  - logs.search - params: {pattern, service, lookback_minutes}
  - http.health_check - params: {url}

  Available recommended actions:
  - database.analyze_table - params: {table}, safe: true
  - database.kill_query - params: {query_id}, safe: false
  - cache.invalidate - params: {key_pattern}, safe: true
  - service.restart - params: {service}, safe: false
  - alert.notify - params: {channel, message}, safe: true

  Only mark actions as safe:true if they are read-only or easily reversible.
  Output ONLY the JSON, no markdown fences or explanation.
  """

  @doc """
  Generate a runbook from an incident description.

  Returns `{:ok, runbook}` where runbook is a validated map,
  or `{:error, reason}` if generation or validation fails.
  """
  def generate(incident_description, opts \\ []) do
    with {:ok, response} <- call_claude(incident_description, opts),
         {:ok, json} <- extract_json(response),
         {:ok, runbook} <- Schema.validate(json) do
      {:ok, runbook}
    end
  end

  defp call_claude(incident_description, opts) do
    messages = [
      %{"role" => "user", "content" => incident_description}
    ]

    api_callback = Keyword.get(opts, :api_callback, &default_api_callback/1)
    api_callback.(messages)
  end

  defp extract_json(response) do
    text =
      response["content"]
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(&(&1["text"]))
      |> Enum.join()
      |> String.trim()

    # Strip markdown code fences if present
    text =
      text
      |> String.replace(~r/^```json\s*/, "")
      |> String.replace(~r/\s*```$/, "")

    case Jason.decode(text) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, "Failed to parse runbook JSON: #{String.slice(text, 0, 200)}..."}
    end
  end

  defp default_api_callback(messages) do
    url = "https://api.anthropic.com/v1/messages"
    api_key = System.get_env("ANTHROPIC_API_KEY")

    body = %{
      "model" => "claude-sonnet-4-5-20250929",
      "max_tokens" => 4096,
      "system" => @system_prompt,
      "messages" => messages
    }

    headers = [
      {"x-api-key", api_key},
      {"content-type", "application/json"},
      {"anthropic-version", "2023-06-01"}
    ]

    case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: response}} -> {:ok, response}
      {:ok, %{status: status, body: body}} -> {:error, "API error #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end
```

## Step 5: Create the Runbook Executor (Native Skill)

Create `lib/incident_response/skills/runbook_executor.ex`:

```elixir
defmodule IncidentResponse.Skills.RunbookExecutor do
  @moduledoc """
  Native skill that validates and executes runbook checks safely.

  This skill is the trust boundary - it enforces:
  - Schema validation (fail fast if malformed)
  - Action allow-list (only whitelisted operations)
  - Dry-run execution (no destructive actions without approval)
  """

  @behaviour Conjure.NativeSkill

  alias IncidentResponse.Runbooks.Schema

  require Logger

  # Allow-list of executable actions
  @allowed_checks ~w(
    database.slow_queries
    database.table_stats
    database.connection_count
    metrics.query
    logs.search
    http.health_check
  )

  @allowed_actions ~w(
    database.analyze_table
    cache.invalidate
    alert.notify
  )

  @impl true
  def __skill_info__ do
    %{
      name: "runbook-executor",
      description: """
      Safely executes incident runbooks generated by Claude.
      Validates schema, enforces allow-lists, and performs dry-run checks.
      """,
      allowed_tools: [:execute]
    }
  end

  @impl true
  def execute(command, context) do
    case parse_command(command) do
      {:run_checks, runbook_json} ->
        run_checks(runbook_json, context)

      {:run_action, runbook_json, action_id} ->
        run_action(runbook_json, action_id, context)

      {:validate, runbook_json} ->
        validate_only(runbook_json)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Command parsing

  defp parse_command(command) do
    command = String.trim(command)

    cond do
      String.starts_with?(command, "validate ") ->
        {:validate, String.replace_prefix(command, "validate ", "")}

      String.starts_with?(command, "run_checks ") ->
        {:run_checks, String.replace_prefix(command, "run_checks ", "")}

      String.starts_with?(command, "run_action ") ->
        parse_run_action(command)

      true ->
        {:error, "Unknown command. Available: validate <json>, run_checks <json>, run_action <json> <action_id>"}
    end
  end

  defp parse_run_action(command) do
    # Format: run_action <json> <action_id>
    # JSON ends at the last }, action_id follows
    case Regex.run(~r/run_action (.+})\s+(\S+)$/, command) do
      [_, json, action_id] -> {:run_action, json, action_id}
      _ -> {:error, "Invalid run_action format. Use: run_action <json> <action_id>"}
    end
  end

  # Execution

  defp validate_only(runbook_json) do
    with {:ok, json} <- Jason.decode(runbook_json),
         {:ok, runbook} <- Schema.validate(json) do
      {:ok, "Runbook valid. #{length(runbook.checks)} checks, #{length(runbook.recommended_actions)} actions."}
    else
      {:error, reasons} when is_list(reasons) ->
        {:error, "Validation failed:\n" <> Enum.join(reasons, "\n")}

      {:error, reason} ->
        {:error, "Validation failed: #{inspect(reason)}"}
    end
  end

  defp run_checks(runbook_json, context) do
    with {:ok, json} <- Jason.decode(runbook_json),
         {:ok, runbook} <- Schema.validate(json),
         {:ok, results} <- execute_checks(runbook.checks, context) do
      output = format_check_results(runbook, results)
      {:ok, output}
    else
      {:error, reasons} when is_list(reasons) ->
        {:error, "Validation failed:\n" <> Enum.join(reasons, "\n")}

      {:error, reason} ->
        {:error, "Failed: #{inspect(reason)}"}
    end
  end

  defp run_action(runbook_json, action_id, context) do
    with {:ok, json} <- Jason.decode(runbook_json),
         {:ok, runbook} <- Schema.validate(json),
         {:ok, action} <- find_action(runbook, action_id),
         :ok <- verify_action_allowed(action),
         :ok <- verify_action_safe(action),
         {:ok, result} <- execute_action(action, context) do
      {:ok, "Action #{action_id} completed: #{result}"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_checks(checks, context) do
    results =
      Enum.map(checks, fn check ->
        if check.action in @allowed_checks do
          result = execute_check(check, context)
          {check.id, result}
        else
          {check.id, {:blocked, "Action not in allow-list: #{check.action}"}}
        end
      end)

    {:ok, results}
  end

  defp execute_check(%{action: action, params: params} = check, _context) do
    Logger.info("Executing check: #{check.id} (#{action})")

    # Simulate check execution - in production, these would call real services
    case action do
      "database.slow_queries" ->
        lookback = Map.get(params, "lookback_minutes", 60)
        {:ok, "Found 3 slow queries in last #{lookback} minutes (avg 4.2s)"}

      "database.table_stats" ->
        table = Map.get(params, "table", "unknown")
        {:ok, "Table #{table}: 18,432 partitions, last analyzed 3 days ago"}

      "database.connection_count" ->
        {:ok, "Active connections: 47/100 (47% utilized)"}

      "metrics.query" ->
        {:ok, "Query latency p99: 2.3s (up from 0.8s baseline)"}

      "logs.search" ->
        pattern = Map.get(params, "pattern", "*")
        {:ok, "Found 142 matches for '#{pattern}' in last hour"}

      "http.health_check" ->
        url = Map.get(params, "url", "/health")
        {:ok, "#{url} returned 200 OK (latency: 45ms)"}

      _ ->
        {:warning, "Unknown check action: #{action}"}
    end
  end

  defp find_action(runbook, action_id) do
    case Enum.find(runbook.recommended_actions, &(&1.id == action_id)) do
      nil -> {:error, "Action not found: #{action_id}"}
      action -> {:ok, action}
    end
  end

  defp verify_action_allowed(%{action: action}) do
    if action in @allowed_actions do
      :ok
    else
      {:error, "Action not in allow-list: #{action}. Allowed: #{Enum.join(@allowed_actions, ", ")}"}
    end
  end

  defp verify_action_safe(%{safe: true}), do: :ok
  defp verify_action_safe(%{safe: false, id: id}) do
    {:error, "Action #{id} is marked unsafe. Requires manual approval."}
  end
  defp verify_action_safe(_), do: :ok

  defp execute_action(%{action: action, params: params} = act, _context) do
    Logger.info("Executing action: #{act.id} (#{action})")

    case action do
      "database.analyze_table" ->
        table = Map.get(params, "table", "unknown")
        {:ok, "ANALYZE TABLE #{table} completed (updated statistics)"}

      "cache.invalidate" ->
        pattern = Map.get(params, "key_pattern", "*")
        {:ok, "Invalidated cache keys matching '#{pattern}' (23 keys removed)"}

      "alert.notify" ->
        channel = Map.get(params, "channel", "#incidents")
        {:ok, "Notification sent to #{channel}"}

      _ ->
        {:ok, "Action #{action} simulated (dry-run)"}
    end
  end

  # Output formatting

  defp format_check_results(runbook, results) do
    checks_output =
      results
      |> Enum.map(fn {id, result} ->
        status = case result do
          {:ok, _} -> "OK"
          {:warning, _} -> "WARN"
          {:blocked, _} -> "BLOCKED"
          _ -> "ERROR"
        end

        detail = case result do
          {_, msg} -> msg
          msg -> inspect(msg)
        end

        "  [#{status}] #{id}: #{detail}"
      end)
      |> Enum.join("\n")

    recommendations =
      runbook.recommended_actions
      |> Enum.map(fn action ->
        safety = if action.safe, do: "[SAFE]", else: "[UNSAFE - requires approval]"
        "  - #{action.id}: #{action.action} #{safety}"
      end)
      |> Enum.join("\n")

    """
    === Runbook Execution Results ===

    Incident Type: #{runbook.incident_type}
    Affected System: #{runbook.affected_system}
    Confidence: #{Float.round(runbook.confidence * 100, 1)}%

    Hypotheses:
    #{Enum.map_join(runbook.hypotheses, "\n", &"  - #{&1}")}

    Check Results:
    #{checks_output}

    Recommended Actions:
    #{recommendations}

    Rollback Plan: #{runbook.rollback_plan}
    """
  end
end
```

## Step 6: Create the Orchestration Layer

Create `lib/incident_response/agent.ex`:

```elixir
defmodule IncidentResponse.Agent do
  @moduledoc """
  Orchestrates the incident response pipeline:
  1. Claude generates runbook artifact
  2. Artifact stored in Tigris
  3. Native skill executes checks safely
  """

  alias IncidentResponse.Skills.{RunbookGenerator, RunbookExecutor}
  alias Conjure.Session

  require Logger

  @doc """
  Analyze an incident and run diagnostic checks.

  Returns a structured result with the runbook and execution results.
  """
  def analyze(incident_description, opts \\ []) do
    with {:ok, runbook} <- generate_runbook(incident_description, opts),
         {:ok, artifact_ref} <- store_artifact(runbook, opts),
         {:ok, results} <- execute_runbook(runbook, opts) do
      {:ok,
       %{
         runbook: runbook,
         artifact_ref: artifact_ref,
         execution_results: results
       }}
    end
  end

  @doc """
  Generate a runbook without executing it.
  """
  def generate_runbook(incident_description, opts \\ []) do
    Logger.info("Generating runbook for incident...")
    RunbookGenerator.generate(incident_description, opts)
  end

  @doc """
  Execute checks from a previously generated runbook.
  """
  def execute_runbook(runbook, opts \\ []) do
    Logger.info("Executing runbook checks...")

    runbook_json = Jason.encode!(runbook)
    context = Keyword.get(opts, :context, %{})

    RunbookExecutor.execute("run_checks #{runbook_json}", context)
  end

  @doc """
  Execute a specific action from a runbook (safe actions only).
  """
  def execute_action(runbook, action_id, opts \\ []) do
    Logger.info("Executing action: #{action_id}")

    runbook_json = Jason.encode!(runbook)
    context = Keyword.get(opts, :context, %{})

    RunbookExecutor.execute("run_action #{runbook_json} #{action_id}", context)
  end

  # Store artifact in Tigris for audit trail

  defp store_artifact(runbook, opts) do
    if storage = Keyword.get(opts, :storage) do
      artifact_path = "runbooks/#{DateTime.utc_now() |> DateTime.to_iso8601()}.json"
      content = Jason.encode!(runbook, pretty: true)

      case storage.write(storage, artifact_path, content) do
        {:ok, ref} ->
          Logger.info("Runbook stored: #{ref.path}")
          {:ok, ref}

        error ->
          Logger.warning("Failed to store runbook: #{inspect(error)}")
          {:ok, nil}
      end
    else
      {:ok, nil}
    end
  end
end
```

## Step 7: Create a LiveView Interface

Create `lib/incident_response_web/live/incident_live.ex`:

```elixir
defmodule IncidentResponseWeb.IncidentLive do
  use IncidentResponseWeb, :live_view

  alias IncidentResponse.Agent

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:incident, "")
     |> assign(:runbook, nil)
     |> assign(:results, nil)
     |> assign(:loading, false)
     |> assign(:error, nil)}
  end

  def handle_event("analyze", %{"incident" => incident}, socket) do
    socket = assign(socket, loading: true, error: nil)

    # Run analysis in background
    pid = self()

    Task.start(fn ->
      result = Agent.analyze(incident)
      send(pid, {:analysis_complete, result})
    end)

    {:noreply, assign(socket, :incident, incident)}
  end

  def handle_event("execute_action", %{"action_id" => action_id}, socket) do
    runbook = socket.assigns.runbook

    case Agent.execute_action(runbook, action_id) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, result)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, reason)}
    end
  end

  def handle_info({:analysis_complete, {:ok, result}}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:runbook, result.runbook)
     |> assign(:results, result.execution_results)}
  end

  def handle_info({:analysis_complete, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:error, inspect(reason))}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <h1 class="text-3xl font-bold mb-6">Incident Response</h1>

      <!-- Input Form -->
      <form phx-submit="analyze" class="mb-8">
        <label class="block text-sm font-medium mb-2">
          Describe the incident
        </label>
        <textarea
          name="incident"
          rows="4"
          class="w-full border rounded-lg p-3 font-mono text-sm"
          placeholder="Our Athena queries for attendance analytics are timing out since this morning..."
          disabled={@loading}
        ><%= @incident %></textarea>
        <button
          type="submit"
          class="mt-3 bg-blue-600 text-white px-6 py-2 rounded-lg disabled:opacity-50"
          disabled={@loading}
        >
          <%= if @loading, do: "Analyzing...", else: "Analyze Incident" %>
        </button>
      </form>

      <!-- Error Display -->
      <%= if @error do %>
        <div class="bg-red-50 border border-red-200 rounded-lg p-4 mb-6">
          <p class="text-red-800"><%= @error %></p>
        </div>
      <% end %>

      <!-- Runbook Display -->
      <%= if @runbook do %>
        <div class="border rounded-lg p-6 mb-6">
          <h2 class="text-xl font-semibold mb-4">Generated Runbook</h2>

          <div class="grid grid-cols-2 gap-4 mb-4">
            <div>
              <span class="text-gray-500">Type:</span>
              <span class="font-medium ml-2"><%= @runbook.incident_type %></span>
            </div>
            <div>
              <span class="text-gray-500">System:</span>
              <span class="font-medium ml-2"><%= @runbook.affected_system %></span>
            </div>
            <div>
              <span class="text-gray-500">Confidence:</span>
              <span class="font-medium ml-2"><%= Float.round(@runbook.confidence * 100, 1) %>%</span>
            </div>
          </div>

          <div class="mb-4">
            <h3 class="font-medium mb-2">Hypotheses</h3>
            <ul class="list-disc list-inside text-gray-700">
              <%= for h <- @runbook.hypotheses do %>
                <li><%= h %></li>
              <% end %>
            </ul>
          </div>

          <div class="mb-4">
            <h3 class="font-medium mb-2">Recommended Actions</h3>
            <div class="space-y-2">
              <%= for action <- @runbook.recommended_actions do %>
                <div class="flex items-center justify-between bg-gray-50 p-3 rounded">
                  <div>
                    <span class="font-mono text-sm"><%= action.action %></span>
                    <%= if action.safe do %>
                      <span class="ml-2 text-xs bg-green-100 text-green-800 px-2 py-1 rounded">SAFE</span>
                    <% else %>
                      <span class="ml-2 text-xs bg-red-100 text-red-800 px-2 py-1 rounded">UNSAFE</span>
                    <% end %>
                  </div>
                  <%= if action.safe do %>
                    <button
                      phx-click="execute_action"
                      phx-value-action_id={action.id}
                      class="text-sm bg-blue-500 text-white px-3 py-1 rounded"
                    >
                      Execute
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Execution Results -->
      <%= if @results do %>
        <div class="border rounded-lg p-6 bg-gray-900 text-gray-100">
          <h2 class="text-xl font-semibold mb-4">Execution Results</h2>
          <pre class="font-mono text-sm whitespace-pre-wrap"><%= @results %></pre>
        </div>
      <% end %>
    </div>
    """
  end
end
```

Add the route in `lib/incident_response_web/router.ex`:

```elixir
scope "/", IncidentResponseWeb do
  pipe_through :browser

  live "/", IncidentLive
end
```

## Step 8: Deploy to Fly.io

Deploy the application:

```bash
fly deploy
```

Run the database migration:

```bash
fly ssh console -C "/app/bin/migrate"
```

Open the application:

```bash
fly open
```

## Usage Example

Input an incident description:

```
Our Athena queries for attendance analytics are timing out since this morning.
Users report 30+ second waits. No recent deployments.
```

Claude generates a structured runbook:

```json
{
  "incident_type": "performance_degradation",
  "affected_system": "athena",
  "confidence": 0.82,
  "hypotheses": [
    "partition explosion in attendance_facts table",
    "stale table statistics causing poor query plans",
    "unexpected data volume increase"
  ],
  "checks": [
    {
      "id": "check_partitions",
      "action": "database.table_stats",
      "params": {"table": "attendance_facts"}
    },
    {
      "id": "check_slow_queries",
      "action": "database.slow_queries",
      "params": {"lookback_minutes": 180}
    }
  ],
  "recommended_actions": [
    {
      "id": "recompute_stats",
      "action": "database.analyze_table",
      "params": {"table": "attendance_facts"},
      "safe": true
    },
    {
      "id": "notify_team",
      "action": "alert.notify",
      "params": {"channel": "#data-platform", "message": "Athena perf issue under investigation"},
      "safe": true
    }
  ],
  "rollback_plan": "No destructive actions proposed"
}
```

The Native executor validates and runs checks:

```
=== Runbook Execution Results ===

Incident Type: performance_degradation
Affected System: athena
Confidence: 82.0%

Hypotheses:
  - partition explosion in attendance_facts table
  - stale table statistics causing poor query plans
  - unexpected data volume increase

Check Results:
  [OK] check_partitions: Table attendance_facts: 18,432 partitions, last analyzed 3 days ago
  [OK] check_slow_queries: Found 3 slow queries in last 180 minutes (avg 4.2s)

Recommended Actions:
  - recompute_stats: database.analyze_table [SAFE]
  - notify_team: alert.notify [SAFE]

Rollback Plan: No destructive actions proposed
```

## Why This Pattern Works

### Clear Separation of Concerns

| Phase | Owner | Responsibility |
|-------|-------|----------------|
| Reasoning | Claude | Analyze problem, generate hypotheses |
| Planning | Claude | Structure checks and actions |
| Validation | Native | Schema enforcement, fail fast |
| Safety | Native | Action allow-listing |
| Execution | Native | Deterministic, auditable |

### Artifact-Driven

The JSON runbook is:
- **Inspectable**: Review before execution
- **Testable**: Unit test the schema
- **Replayable**: Re-run checks without Claude
- **Auditable**: Store in Tigris for compliance

### Production-Ready

- No LLM executing infrastructure changes
- Native code is the trust boundary
- Safe actions clearly marked
- Unsafe actions require explicit approval

## Testing Locally

For local development without Fly.io:

```bash
# Set API key
export ANTHROPIC_API_KEY=sk-ant-...

# Run the app
mix phx.server
```

Test the agent directly in IEx:

```elixir
iex> IncidentResponse.Agent.analyze("Database queries are slow")
{:ok, %{runbook: %{...}, execution_results: "..."}}
```

## Next Steps

- Add real service integrations (replace simulated checks)
- Implement approval workflow for unsafe actions
- Add runbook versioning and history
- Create Slack/PagerDuty integration for `alert.notify`
- Add telemetry dashboards with [Fly.io Metrics](https://fly.io/docs/reference/metrics/)

## See Also

- [Storage Strategy ADR](../adr/0022-storage-strategy.md)
- [Native Elixir Skills](using_elixir_native_skill.md)
- [Unified Backend Patterns](many_skill_backends_one_agent.md)
- [Tigris Documentation](https://www.tigrisdata.com/docs/)
