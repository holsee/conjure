# Anthropic Skills API: Hosted Document Generation

Use Anthropic's hosted Skills API to generate documents like spreadsheets, PDFs, and presentations.

**Time:** 20 minutes

**Prerequisites:** Complete [Hello World](hello_world.md) first.

## What You'll Build

An agent that:
- Uses Anthropic's hosted execution for document generation
- Creates incident report spreadsheets from log analysis
- Downloads and saves generated files

## When to Use Anthropic Backend

The Anthropic backend is ideal for:

| Skill | Use Case |
|-------|----------|
| `xlsx` | Spreadsheets, reports, data exports |
| `pdf` | Documents, reports, invoices |
| `pptx` | Presentations, slide decks |
| `docx` | Word documents, letters |

Advantages:
- No local dependencies (Python, Office, etc.)
- Sandboxed execution in Anthropic's cloud
- Handles complex document generation

## Step 1: Understand the API Requirements

The Anthropic Skills API requires:

1. **Beta headers** - Skills are in beta
2. **Container config** - Specifies which skills to use
3. **Code execution tool** - Enables skill execution

## Step 2: Create the API Client

Create `lib/my_app/anthropic_client.ex`:

```elixir
defmodule MyApp.AnthropicClient do
  @moduledoc """
  Anthropic API client with Skills support.
  """

  @api_url "https://api.anthropic.com/v1/messages"

  @doc """
  Make a request to Claude with Skills enabled.
  """
  def chat(messages, container_config, opts \\ []) do
    body = build_request(messages, container_config, opts)
    headers = build_headers()

    case Req.post(@api_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_request(messages, container_config, opts) do
    %{
      "model" => Keyword.get(opts, :model, "claude-sonnet-4-5-20250929"),
      "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
      "messages" => messages,
      "tools" => [Conjure.API.Anthropic.code_execution_tool()],
      "container" => container_config
    }
    |> maybe_add_system(opts)
  end

  defp maybe_add_system(request, opts) do
    case Keyword.get(opts, :system) do
      nil -> request
      system -> Map.put(request, "system", system)
    end
  end

  defp build_headers do
    [
      {"x-api-key", api_key()},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ] ++ Conjure.API.Anthropic.beta_headers()
  end

  defp api_key do
    System.get_env("ANTHROPIC_API_KEY") ||
      raise "ANTHROPIC_API_KEY not set"
  end
end
```

## Step 3: Create a Document Agent

Create `lib/my_app/document_agent.ex`:

```elixir
defmodule MyApp.DocumentAgent do
  @moduledoc """
  Agent for generating documents using Anthropic Skills.
  """

  alias MyApp.AnthropicClient

  @doc """
  Generate a document using Anthropic-hosted skills.

  ## Examples

      DocumentAgent.generate(
        "Create a budget spreadsheet with monthly expenses",
        skills: [{:anthropic, "xlsx", "latest"}]
      )

  """
  def generate(prompt, opts \\ []) do
    skills = Keyword.get(opts, :skills, [{:anthropic, "xlsx", "latest"}])

    # Create session
    session = Conjure.Session.new_anthropic(skills)

    # Build API callback
    api_callback = fn messages ->
      {:ok, container} = Conjure.API.Anthropic.container_config(skills)

      container = if session.container_id do
        Conjure.API.Anthropic.with_container_id(container, session.container_id)
      else
        container
      end

      AnthropicClient.chat(messages, container)
    end

    # Run conversation
    case Conjure.Session.chat(session, prompt, api_callback) do
      {:ok, response, updated_session} ->
        files = Conjure.Session.get_created_files(updated_session)
        {:ok, response, files, updated_session}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Download files created during the session.
  """
  def download_files(files, output_dir \\ ".") do
    File.mkdir_p!(output_dir)

    Enum.map(files, fn %{id: file_id, source: :anthropic} = file ->
      case Conjure.Files.Anthropic.download(file_id, &files_api_callback/1) do
        {:ok, content, filename} ->
          path = Path.join(output_dir, filename)
          File.write!(path, content)
          {:ok, path}

        {:error, reason} ->
          {:error, file_id, reason}
      end
    end)
  end

  defp files_api_callback(file_id) do
    url = "https://api.anthropic.com/v1/files/#{file_id}/content"

    headers = [
      {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
      {"anthropic-version", "2023-06-01"}
    ] ++ Conjure.API.Anthropic.beta_headers()

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        filename = extract_filename(headers) || "#{file_id}.bin"
        {:ok, body, filename}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_filename(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "content-disposition" end)
    |> case do
      {_, value} ->
        case Regex.run(~r/filename="?([^";\s]+)"?/, value) do
          [_, filename] -> filename
          _ -> nil
        end
      _ -> nil
    end
  end
end
```

## Step 4: Generate a Spreadsheet

```elixir
# In IEx
{:ok, response, files, _session} = MyApp.DocumentAgent.generate(
  "Create a spreadsheet with the following incident data:
   - Date: 2024-01-15
   - Severity: High
   - Error count: 47
   - Affected services: api-gateway, payment-service
   - Resolution time: 2 hours",
  skills: [{:anthropic, "xlsx", "latest"}]
)

# Check created files
IO.inspect(files)
# [%{id: "file_01abc...", source: :anthropic, filename: nil, size: nil}]

# Download files
MyApp.DocumentAgent.download_files(files, "/tmp/reports")
# [{:ok, "/tmp/reports/incident_report.xlsx"}]
```

## Step 5: Multi-Turn Document Editing

Sessions track container IDs for multi-turn conversations:

```elixir
# Start with a spreadsheet
session = Conjure.Session.new_anthropic([{:anthropic, "xlsx", "latest"}])

# First turn - create the document
{:ok, _, session} = Conjure.Session.chat(
  session,
  "Create a monthly expenses spreadsheet with columns: Date, Category, Amount, Description",
  &api_callback/1
)

# Second turn - add data (same container, same document)
{:ok, _, session} = Conjure.Session.chat(
  session,
  "Add these expenses:
   - Jan 15, Office Supplies, $150, Printer paper
   - Jan 16, Software, $299, IDE license
   - Jan 18, Travel, $450, Client meeting",
  &api_callback/1
)

# Third turn - add formatting
{:ok, _, session} = Conjure.Session.chat(
  session,
  "Add a total row at the bottom and format the Amount column as currency",
  &api_callback/1
)

# Get all created files
files = Conjure.Session.get_created_files(session)
```

## Step 6: Combine with Log Analysis

Generate incident reports from log analysis:

```elixir
defmodule MyApp.IncidentReporter do
  @doc """
  Analyze logs and generate an incident report spreadsheet.
  """
  def generate_report(log_api_endpoint) do
    # Step 1: Fetch and analyze logs locally
    {:ok, analysis} = analyze_logs(log_api_endpoint)

    # Step 2: Generate spreadsheet with Anthropic
    prompt = """
    Create an incident report spreadsheet based on this analysis:

    Summary:
    - Total logs analyzed: #{analysis.total}
    - Error rate: #{analysis.error_rate}
    - Time period: Last 24 hours

    Top Errors:
    #{format_errors(analysis.top_errors)}

    Diagnostics:
    #{format_diagnostics(analysis.diagnostics)}

    Include sheets for:
    1. Executive Summary
    2. Error Details
    3. Recommendations
    """

    MyApp.DocumentAgent.generate(prompt, skills: [{:anthropic, "xlsx", "latest"}])
  end

  defp analyze_logs(endpoint) do
    # Use local skill for analysis
    {:ok, skills} = Conjure.load("priv/skills")
    session = Conjure.Session.new_local(skills)

    Conjure.Session.chat(
      session,
      "Fetch logs from #{endpoint} and analyze them. Return JSON with: total, error_rate, top_errors, diagnostics",
      &local_api_callback/1
    )
  end
end
```

## Understanding pause_turn

Long-running operations use `pause_turn`:

```elixir
# Conjure handles this automatically, but here's what happens:

# 1. Initial request
response = api_call(messages, container)

# 2. If stop_reason is "pause_turn", Claude is still working
if response["stop_reason"] == "pause_turn" do
  # Wait and continue with the response content
  assistant_msg = %{"role" => "assistant", "content" => response["content"]}
  messages = messages ++ [assistant_msg]

  # Container ID is reused
  container = Conjure.API.Anthropic.with_container_id(container, response["container"]["id"])

  # Continue polling
  response = api_call(messages, container)
end

# 3. When stop_reason is "end_turn", the document is ready
```

The Session API handles this loop automatically.

## Available Anthropic Skills

| Skill ID | Description | Output |
|----------|-------------|--------|
| `xlsx` | Excel spreadsheets | .xlsx files |
| `pdf` | PDF documents | .pdf files |
| `pptx` | PowerPoint presentations | .pptx files |
| `docx` | Word documents | .docx files |

## Custom Skills

You can also use custom-uploaded skills:

```elixir
session = Conjure.Session.new_anthropic([
  {:anthropic, "xlsx", "latest"},
  {:custom, "skill_01AbCdEfGhIjKlMnOpQrStUv", "v1"}
])
```

## Error Handling

```elixir
case MyApp.DocumentAgent.generate(prompt) do
  {:ok, response, files, session} ->
    IO.puts("Generated #{length(files)} file(s)")

  {:error, {:api_error, 429, _}} ->
    IO.puts("Rate limited - try again later")

  {:error, {:api_error, 400, body}} ->
    IO.puts("Bad request: #{inspect(body)}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
```

## Next Steps

- **[Native Elixir Skills](using_elixir_native_skill.md)** - Fetch logs faster with in-process execution
- **[Unified Backends](many_skill_backends_one_agent.md)** - Combine Local, Native, and Anthropic backends
