# ADR-0021: Hybrid Multi-Backend Sessions

## Status

Proposed

## Context

After establishing the unified Session API (ADR-0019) and Backend behaviour (ADR-0020), we identified a usability gap: multi-backend workflows require creating separate sessions for each backend, manually orchestrating data flow, and managing multiple conversation histories.

Common patterns like "fetch with Native → analyze with Local → report with Anthropic" require significant boilerplate:

```elixir
# Current approach - separate sessions, manual orchestration
{:ok, logs} = fetch_logs_native(url)           # Session 1
{:ok, analysis} = analyze_logs_local(logs)      # Session 2
{:ok, report} = generate_report_anthropic(analysis)  # Session 3
```

This creates friction for developers building multi-capability agents.

## Decision

We will introduce a **Hybrid Session** mode that manages multiple backend sub-sessions internally, providing:

1. Single session creation with multiple backends
2. Automatic tool routing based on skill registration
3. Unified conversation history
4. Aggregated file tracking across backends
5. Lazy cross-backend file resolution

### Public API

```elixir
# Create hybrid session with multiple backends
session = Conjure.Session.new_hybrid([
  {:native, [MyApp.Skills.LogFetcher]},
  {:local, local_skills},
  {:docker, docker_skills, executor: Conjure.Executor.Docker},
  {:anthropic, [{:anthropic, "xlsx", "latest"}]}
])

# Single chat call - tools route automatically
{:ok, response, session} = Conjure.Session.chat(
  session,
  "Fetch logs from the API, analyze them, and create an Excel report",
  &api_callback/1
)

# Access unified file list
files = Conjure.Session.get_created_files(session)
# => [%{id: "...", source: :native}, %{id: "file_abc", source: :anthropic}]
```

### Session Structure

Extended Session struct with hybrid-specific fields:

```elixir
defstruct [
  :execution_mode,    # :hybrid for this mode
  :skills,            # Merged list of all skills (for reference)
  :messages,          # Unified conversation history
  :container_id,      # nil (Anthropic container tracked in sub-session)
  :created_files,     # Aggregated from all backends
  :context,           # nil (each sub-session has own context)
  :opts,
  # New fields for hybrid:
  :sub_sessions,      # %{backend_type => Session.t()}
  :routing_table      # %{prefixed_tool_name => {backend_type, skill_ref}}
]
```

### Tool Naming (Skill Prefix Strategy)

To prevent collisions when multiple skills expose same tool types:

```elixir
# Original tool definitions:
# Native skill "log-fetcher" → "execute" tool
# Local skill "analyzer" → "bash_tool" tool

# After prefixing:
# "log-fetcher_execute"
# "analyzer_bash_tool"

# Routing table:
%{
  "log-fetcher_execute" => {:native, MyApp.Skills.LogFetcher},
  "analyzer_bash_tool" => {:local, "analyzer"},
  "xlsx_code_execution" => {:anthropic, {:anthropic, "xlsx", "latest"}}
}
```

### Implementation

#### 1. Session Creation (`lib/conjure/session.ex`)

```elixir
@spec new_hybrid([backend_spec()], keyword()) :: t()
def new_hybrid(backend_specs, opts \\ []) do
  # Create sub-session for each backend
  sub_sessions = create_sub_sessions(backend_specs, opts)

  # Build routing table from all tool definitions
  routing_table = build_routing_table(sub_sessions)

  # Merge all skills for reference
  all_skills = merge_skills(sub_sessions)

  %__MODULE__{
    execution_mode: :hybrid,
    skills: all_skills,
    messages: [],
    container_id: nil,
    created_files: [],
    context: nil,
    opts: opts,
    sub_sessions: sub_sessions,
    routing_table: routing_table
  }
end

defp create_sub_sessions(backend_specs, opts) do
  Enum.reduce(backend_specs, %{}, fn
    {:native, modules}, acc ->
      Map.put(acc, :native, new_native(modules, opts))

    {:local, skills}, acc ->
      Map.put(acc, :local, new_local(skills, opts))

    {:docker, skills, backend_opts}, acc ->
      merged_opts = Keyword.merge(opts, backend_opts)
      Map.put(acc, :docker, new_local(skills, merged_opts))

    {:anthropic, skill_specs}, acc ->
      Map.put(acc, :anthropic, new_anthropic(skill_specs, opts))
  end)
end
```

#### 2. Hybrid Conversation Loop (`lib/conjure/session/hybrid.ex`)

```elixir
defmodule Conjure.Session.Hybrid do
  @moduledoc "Hybrid session conversation loop with multi-backend routing."

  alias Conjure.Session

  def chat(session, user_message, api_callback) do
    user_msg = %{"role" => "user", "content" => user_message}
    messages = session.messages ++ [user_msg]

    # Merge tool definitions from all backends with skill prefixes
    tools = merged_tool_definitions(session)

    run_loop(messages, tools, session, api_callback)
  end

  defp run_loop(messages, tools, session, api_callback, iteration \\ 0) do
    max_iterations = Keyword.get(session.opts, :max_iterations, 25)

    if iteration >= max_iterations do
      {:error, %Conjure.Error{type: :max_iterations}}
    else
      case api_callback.(messages, tools) do
        {:ok, response} ->
          handle_response(response, messages, tools, session, api_callback, iteration)

        {:error, _} = error ->
          error
      end
    end
  end

  defp handle_response(response, messages, tools, session, api_callback, iteration) do
    tool_uses = extract_tool_uses(response)

    if Enum.empty?(tool_uses) do
      # End of conversation
      finalize(response, messages, session)
    else
      # Route and execute tools
      case execute_tools(tool_uses, session) do
        {:ok, results, updated_session} ->
          # Build next messages
          assistant_msg = %{"role" => "assistant", "content" => response["content"]}
          tool_results_msg = format_tool_results(results)
          new_messages = messages ++ [assistant_msg, tool_results_msg]

          run_loop(new_messages, tools, updated_session, api_callback, iteration + 1)

        {:error, _} = error ->
          error
      end
    end
  end

  defp execute_tools(tool_uses, session) do
    # Group tool calls by backend
    grouped = group_by_backend(tool_uses, session.routing_table)

    # Execute in parallel across backends
    results =
      grouped
      |> Task.async_stream(fn {backend_type, calls} ->
        execute_on_backend(backend_type, calls, session)
      end, timeout: 60_000)
      |> Enum.reduce({:ok, [], session}, &aggregate_result/2)

    results
  end

  defp execute_on_backend(backend_type, tool_calls, session) do
    sub_session = session.sub_sessions[backend_type]

    # Restore original tool names for backend execution
    restored_calls = restore_tool_names(tool_calls)

    # Execute via the appropriate backend
    case backend_type do
      :native -> execute_native(restored_calls, sub_session)
      :local -> execute_local(restored_calls, sub_session)
      :docker -> execute_local(restored_calls, sub_session)
      :anthropic -> execute_anthropic(restored_calls, sub_session)
    end
  end
end
```

#### 3. Cross-Backend File Resolution (`lib/conjure/session/hybrid/file_resolver.ex`)

```elixir
defmodule Conjure.Session.Hybrid.FileResolver do
  @moduledoc "Lazy file resolution across backends."

  def resolve(file_ref, session) do
    case find_file_source(file_ref, session.created_files) do
      {:local, path} -> {:ok, path}
      {:native, path} -> {:ok, path}
      {:docker, path} -> {:ok, path}
      {:anthropic, file_id} -> lazy_download(file_id, session)
      :not_found -> {:error, :file_not_found}
    end
  end

  defp lazy_download(file_id, session) do
    working_dir = Keyword.get(session.opts, :working_directory, System.tmp_dir!())
    cache_path = Path.join([working_dir, "anthropic_cache", file_id])

    if File.exists?(cache_path) do
      {:ok, cache_path}
    else
      File.mkdir_p!(Path.dirname(cache_path))

      case Conjure.API.Anthropic.download_file(file_id, cache_path) do
        :ok ->
          # Update file tracking with cached path
          {:ok, cache_path}

        {:error, reason} ->
          {:error, {:download_failed, file_id, reason}}
      end
    end
  end
end
```

### File Structure

```
lib/conjure/
├── session.ex                    # Add new_hybrid/2, :hybrid mode
├── session/
│   ├── hybrid.ex                 # Hybrid conversation loop
│   └── hybrid/
│       └── file_resolver.ex      # Cross-backend file access
└── backend.ex                    # Add Hybrid to available backends

docs/adr/
└── 0021-hybrid-multi-backend-sessions.md

test/conjure/
└── session/
    └── hybrid_test.exs           # Hybrid session tests
```

## Consequences

### Positive

1. **Simplified Multi-Backend Workflows**: Single session for complex agents
2. **Unified Conversation**: One message history, one file list
3. **Automatic Routing**: No manual backend selection per operation
4. **Backwards Compatible**: New opt-in feature, existing code unchanged
5. **Parallel Execution**: Tool calls to different backends run concurrently
6. **Lazy File Resolution**: Anthropic files downloaded only when needed

### Negative

1. **Increased Complexity**: New session mode with sub-session management
2. **Memory Overhead**: Sub-sessions and routing table add state
3. **Error Attribution**: Need clear error context for multi-backend failures

### Neutral

1. **No Backend Changes**: Existing backends work unmodified
2. **Opt-In**: Developers choose when to use hybrid mode
3. **Tool Name Prefixing**: Changes visible tool names (may affect prompts)

## Alternatives Considered

### A. Skill-Level Backend Affinity

Skills declare their backend in metadata. Session routes based on skill.

Rejected: Couples skills to backends, reduces portability, requires Skill struct changes.

### B. Tool-Level Configuration

External config maps tool names to backends.

Rejected: Too granular, configuration burden, less discoverable.

### C. Workflow Composition Helpers

Better utilities for chaining single-backend sessions.

Rejected: Doesn't solve core UX issue of multiple sessions/histories.

## References

- [ADR-0019: Unified Execution Model](0019-unified-execution-model.md)
- [ADR-0020: Backend Behaviour Architecture](0020-backend-behaviour.md)
- [Tutorial: Many Skill Backends, One Agent](../tutorials/many_skill_backends_one_agent.md)
