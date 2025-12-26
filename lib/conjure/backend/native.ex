defmodule Conjure.Backend.Native do
  @moduledoc """
  Backend for native Elixir module execution.

  Executes skills implemented as Elixir modules directly in the BEAM,
  providing type-safe, in-process execution with full access to the
  application's runtime context.

  ## Usage

      defmodule MyApp.Skills.Database do
        @behaviour Conjure.NativeSkill

        def __skill_info__ do
          %{
            name: "database",
            description: "Query the database",
            allowed_tools: [:execute, :read]
          }
        end

        def execute(query, _context), do: {:ok, run_query(query)}
        def read(table, _context, _opts), do: {:ok, get_schema(table)}
      end

      session = Conjure.Backend.Native.new_session([MyApp.Skills.Database], [])

      {:ok, response, session} = Conjure.Backend.Native.chat(
        session,
        "What tables do we have?",
        &api_callback/1,
        []
      )

  ## How It Works

  1. Native skill modules implement `Conjure.NativeSkill` behaviour
  2. This backend generates Claude tool definitions from skill info
  3. When Claude returns tool_use blocks, this backend:
     - Maps tool names back to skill modules
     - Invokes the appropriate callback (execute/read/write/modify)
     - Returns results to Claude

  ## Advantages Over Local Backend

  * No subprocess/shell overhead
  * Type-safe with compile-time checks
  * Direct access to application state (Ecto repos, caches, GenServers)
  * Better error handling with pattern matching

  ## Options

  * `:working_directory` - Working directory for file operations
  * `:timeout` - Execution timeout in milliseconds (default: 30_000)
  * `:max_iterations` - Maximum tool-use iterations (default: 25)

  ## See Also

  * `Conjure.NativeSkill` - Behaviour for skill modules
  * `Conjure.Backend.Local` - Shell-based execution
  """

  @behaviour Conjure.Backend

  alias Conjure.{Error, ExecutionContext, NativeSkill, Session, ToolCall, ToolResult}

  require Logger

  @default_max_iterations 25

  @impl true
  def backend_type, do: :native

  @impl true
  def new_session(skill_modules, opts) when is_list(skill_modules) do
    context = create_context(opts)

    # Validate all modules implement the behaviour
    Enum.each(skill_modules, fn module ->
      unless NativeSkill.implements?(module) do
        raise ArgumentError,
              "#{inspect(module)} does not implement Conjure.NativeSkill behaviour"
      end
    end)

    %Session{
      execution_mode: :native,
      skills: skill_modules,
      messages: [],
      container_id: nil,
      created_files: [],
      context: context,
      opts: opts,
      uploaded_skills: [],
      api_callback: nil
    }
  end

  @impl true
  def chat(session, message, api_callback, opts) do
    user_msg = %{"role" => "user", "content" => message}
    messages = session.messages ++ [user_msg]

    max_iterations = Keyword.get(session.opts, :max_iterations, @default_max_iterations)
    merged_opts = Keyword.merge(session.opts, opts)

    state =
      loop_state(
        messages,
        session.skills,
        session.context,
        api_callback,
        merged_opts,
        session,
        max_iterations
      )

    run_loop(state, 0, max_iterations)
  end

  @doc """
  Get all tool definitions for a list of native skill modules.

  Returns a list of tool definitions suitable for passing to the Claude API.
  """
  @spec tool_definitions([module()]) :: [map()]
  def tool_definitions(skill_modules) when is_list(skill_modules) do
    Enum.flat_map(skill_modules, &NativeSkill.tool_definitions/1)
  end

  @doc """
  Build a tool name to module mapping for dispatching.

  Returns a map from tool name to `{module, callback_type}`.
  """
  @spec build_tool_map([module()]) :: %{String.t() => {module(), atom()}}
  def build_tool_map(skill_modules) when is_list(skill_modules) do
    for module <- skill_modules,
        {:ok, info} <- [NativeSkill.get_info(module)],
        tool_type <- info.allowed_tools,
        into: %{} do
      base_name = info.name |> String.replace("-", "_")
      tool_name = "#{base_name}_#{tool_type}"
      {tool_name, {module, tool_type}}
    end
  end

  # Private implementation

  # Loop state to reduce function arity
  defp loop_state(messages, skills, context, api_callback, opts, session, max) do
    %{
      messages: messages,
      skills: skills,
      context: context,
      api_callback: api_callback,
      opts: opts,
      session: session,
      max: max
    }
  end

  defp run_loop(_state, iteration, max) when iteration >= max do
    {:error, Error.max_iterations_reached(max)}
  end

  defp run_loop(state, iteration, max) do
    emit_telemetry(:iteration, %{iteration: iteration})

    case state.api_callback.(state.messages) do
      {:ok, response} ->
        handle_response(response, state, iteration, max)

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp handle_response(response, state, iteration, max) do
    tool_uses = extract_tool_uses(response)

    if Enum.empty?(tool_uses) do
      # Conversation complete
      assistant_msg = %{"role" => "assistant", "content" => response["content"]}
      final_messages = state.messages ++ [assistant_msg]

      updated_session = %{state.session | messages: final_messages}

      response_with_stop = Map.put(response, "stop_reason", "end_turn")
      {:ok, response_with_stop, updated_session}
    else
      # Execute tool calls
      tool_map = build_tool_map(state.skills)
      results = execute_tools(tool_uses, tool_map, state.context, state.opts)

      # Build messages
      assistant_msg = %{"role" => "assistant", "content" => response["content"]}
      user_msg = format_tool_results_message(results)
      new_messages = state.messages ++ [assistant_msg, user_msg]

      # Continue loop
      run_loop(%{state | messages: new_messages}, iteration + 1, max)
    end
  end

  defp extract_tool_uses(%{"content" => content}) when is_list(content) do
    for %{"type" => "tool_use"} = block <- content do
      %ToolCall{
        id: block["id"],
        name: block["name"],
        input: block["input"] || %{}
      }
    end
  end

  defp extract_tool_uses(_), do: []

  defp execute_tools(tool_calls, tool_map, context, opts) do
    on_tool_call = Keyword.get(opts, :on_tool_call, fn _ -> :ok end)
    on_tool_result = Keyword.get(opts, :on_tool_result, fn _ -> :ok end)

    Enum.map(tool_calls, fn call ->
      on_tool_call.(call)
      result = execute_single(call, tool_map, context)
      on_tool_result.(result)
      result
    end)
  end

  defp execute_single(%ToolCall{} = call, tool_map, context) do
    start_time = System.monotonic_time()

    result =
      case Map.get(tool_map, call.name) do
        nil ->
          {:error, "Unknown tool: #{call.name}"}

        {module, callback_type} ->
          execute_callback(module, callback_type, call.input, context)
      end

    duration = System.monotonic_time() - start_time

    emit_telemetry(:tool_call, %{duration: duration}, %{
      tool: call.name,
      success: match?({:ok, _}, result)
    })

    case result do
      {:ok, output} ->
        ToolResult.success(call.id, output)

      {:error, reason} when is_binary(reason) ->
        ToolResult.error(call.id, reason)

      {:error, reason} ->
        ToolResult.error(call.id, inspect(reason))
    end
  end

  defp execute_callback(module, :execute, %{"command" => command}, context) do
    if function_exported?(module, :execute, 2) do
      module.execute(command, context)
    else
      {:error, "Module #{inspect(module)} does not implement execute/2"}
    end
  end

  defp execute_callback(module, :read, input, context) do
    if function_exported?(module, :read, 3) do
      path = input["path"] || ""

      opts =
        [
          offset: input["offset"],
          limit: input["limit"]
        ]
        |> Enum.reject(fn {_, v} -> is_nil(v) end)

      module.read(path, context, opts)
    else
      {:error, "Module #{inspect(module)} does not implement read/3"}
    end
  end

  defp execute_callback(module, :write, input, context) do
    if function_exported?(module, :write, 3) do
      path = input["path"] || ""
      content = input["content"] || ""

      module.write(path, content, context)
    else
      {:error, "Module #{inspect(module)} does not implement write/3"}
    end
  end

  defp execute_callback(module, :modify, input, context) do
    if function_exported?(module, :modify, 4) do
      path = input["path"] || ""
      old_content = input["old_content"] || ""
      new_content = input["new_content"] || ""

      module.modify(path, old_content, new_content, context)
    else
      {:error, "Module #{inspect(module)} does not implement modify/4"}
    end
  end

  defp execute_callback(_module, callback_type, _input, _context) do
    {:error, "Unknown callback type: #{callback_type}"}
  end

  defp format_tool_results_message(results) do
    content = Enum.map(results, &ToolResult.to_api_format/1)
    %{"role" => "user", "content" => content}
  end

  defp create_context(opts) do
    ExecutionContext.new(
      skills_root: System.tmp_dir!(),
      working_directory: Keyword.get(opts, :working_directory, default_working_dir()),
      timeout: Keyword.get(opts, :timeout, 30_000),
      executor_config: Keyword.get(opts, :executor_config, %{})
    )
  end

  defp default_working_dir do
    Path.join(System.tmp_dir!(), "conjure_native_#{:rand.uniform(100_000)}")
  end

  defp emit_telemetry(event, measurements, metadata \\ %{}) do
    :telemetry.execute(
      [:conjure, :backend, :native, event],
      measurements,
      metadata
    )
  end
end
