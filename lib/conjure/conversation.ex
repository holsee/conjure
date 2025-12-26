defmodule Conjure.Conversation do
  @moduledoc """
  Manages the tool-use conversation loop.

  The conversation module orchestrates the back-and-forth between Claude
  and tool execution. When Claude responds with tool_use blocks, this
  module executes the tools and formats the results to send back.

  ## Conversation Flow

      User Message
           │
           ▼
      Call Claude API ◄────────────────┐
           │                           │
           ▼                           │
      Parse Response                   │
           │                           │
           ▼                           │
      ┌──────────┐     Yes    ┌─────────────────┐
      │Tool Uses?│───────────►│ Execute Tools   │
      └──────────┘            └────────┬────────┘
           │ No                        │
           ▼                           ▼
      Return Final            Format Results
       Response               Add to Messages ──┘

  ## Example

      {:ok, skills} = Conjure.load("/path/to/skills")

      messages = [%{role: "user", content: "Read the PDF skill"}]

      {:ok, final_messages} = Conjure.Conversation.run_loop(
        messages,
        skills,
        &call_claude/1,
        max_iterations: 10
      )

  ## Manual Processing

  For more control, use `process_response/3` directly:

      response = call_claude(messages)

      case Conjure.Conversation.process_response(response, skills) do
        {:done, text} ->
          IO.puts(text)

        {:continue, tool_results} ->
          # Send results back to Claude
          next_response = call_claude(add_tool_results(messages, response, tool_results))
      end
  """

  alias Conjure.{Error, ExecutionContext, Executor, Skill, ToolCall, ToolResult, Tools}

  require Logger

  @default_max_iterations 25
  @default_executor Conjure.Executor.Local

  @type message :: %{String.t() => term()}
  @type api_response :: %{String.t() => term()}

  @doc """
  Run a complete conversation loop until completion or max iterations.

  Takes a callback function that makes Claude API calls. The callback
  receives the current messages list and should return `{:ok, response}`
  or `{:error, reason}`.

  ## Options

  * `:max_iterations` - Maximum tool-use loops (default: 25)
  * `:executor` - Executor module to use (default: Conjure.Executor.Local)
  * `:context` - ExecutionContext to use (created if not provided)
  * `:on_tool_call` - Callback for each tool call `fn tool_call -> :ok end`
  * `:on_tool_result` - Callback for each tool result `fn result -> :ok end`
  """
  @spec run_loop(
          messages :: [message()],
          skills :: [Skill.t()],
          api_callback :: ([message()] -> {:ok, api_response()} | {:error, term()}),
          opts :: keyword()
        ) :: {:ok, [message()]} | {:error, Error.t()}
  def run_loop(messages, skills, api_callback, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    executor = Keyword.get(opts, :executor, @default_executor)
    context = Keyword.get(opts, :context) || create_default_context(skills, opts)

    # Initialize executor
    case maybe_init_executor(executor, context) do
      {:ok, context} ->
        result =
          do_loop(messages, skills, api_callback, executor, context, 0, max_iterations, opts)

        maybe_cleanup_executor(executor, context)
        result

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Process Claude's response, executing any tool calls.

  Returns:
  - `{:done, text}` - No tool calls, conversation complete
  - `{:continue, tool_results}` - Tool calls executed, send results back
  - `{:error, reason}` - Processing failed
  """
  @spec process_response(api_response(), [Skill.t()], keyword()) ::
          {:done, String.t()} | {:continue, [ToolResult.t()]} | {:error, term()}
  def process_response(response, skills, opts \\ []) do
    tool_uses = extract_tool_uses(response)

    if Enum.empty?(tool_uses) do
      text = extract_text(response)
      {:done, text}
    else
      executor = Keyword.get(opts, :executor, @default_executor)
      context = Keyword.get(opts, :context) || create_default_context(skills, opts)

      results = execute_tool_calls(tool_uses, skills, executor, context, opts)
      {:continue, results}
    end
  end

  @doc """
  Extract tool_use blocks from Claude's response.
  """
  @spec extract_tool_uses(api_response()) :: [ToolCall.t()]
  def extract_tool_uses(%{"content" => content}) when is_list(content) do
    Tools.parse_tool_uses(content)
  end

  def extract_tool_uses(_), do: []

  @doc """
  Execute multiple tool calls.

  Executes in parallel using Task.async_stream for efficiency.
  """
  @spec execute_tool_calls([ToolCall.t()], [Skill.t()], module(), ExecutionContext.t(), keyword()) ::
          [ToolResult.t()]
  def execute_tool_calls(tool_calls, _skills, executor, context, opts \\ []) do
    on_tool_call = Keyword.get(opts, :on_tool_call, fn _ -> :ok end)
    on_tool_result = Keyword.get(opts, :on_tool_result, fn _ -> :ok end)

    tool_calls
    |> Task.async_stream(
      fn call ->
        on_tool_call.(call)
        result = execute_single(call, executor, context)
        on_tool_result.(result)
        result
      end,
      timeout: context.timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, :timeout} ->
        # Find the corresponding tool call for error reporting
        %ToolResult{
          tool_use_id: "unknown",
          content: "Execution timed out",
          is_error: true
        }
    end)
  end

  @doc """
  Format tool results for sending back to Claude.

  Returns a message with role "user" containing tool_result blocks.
  """
  @spec format_tool_results_message([ToolResult.t()]) :: message()
  def format_tool_results_message(results) do
    content = Enum.map(results, &ToolResult.to_api_format/1)
    %{"role" => "user", "content" => content}
  end

  @doc """
  Check if the response indicates conversation is complete.

  Returns true if there are no tool_use blocks.
  """
  @spec conversation_complete?(api_response()) :: boolean()
  def conversation_complete?(response) do
    extract_tool_uses(response) == []
  end

  @doc """
  Extract text content from Claude's response.
  """
  @spec extract_text(api_response()) :: String.t()
  def extract_text(%{"content" => content}) when is_list(content) do
    texts = for %{"type" => "text", "text" => text} <- content, do: text
    Enum.join(texts, "\n")
  end

  def extract_text(_), do: ""

  # Private functions

  defp do_loop(_messages, _skills, _api_callback, _executor, _ctx, iteration, max, _opts)
       when iteration >= max do
    {:error, Error.max_iterations_reached(max)}
  end

  defp do_loop(messages, skills, api_callback, executor, context, iteration, max, opts) do
    :telemetry.execute(
      [:conjure, :conversation, :iteration],
      %{iteration: iteration},
      %{}
    )

    case api_callback.(messages) do
      {:ok, response} ->
        case process_response(
               response,
               skills,
               Keyword.put(opts, :executor, executor) |> Keyword.put(:context, context)
             ) do
          {:done, _text} ->
            # Add final assistant message
            assistant_msg = %{"role" => "assistant", "content" => response["content"]}
            {:ok, messages ++ [assistant_msg]}

          {:continue, tool_results} ->
            # Add assistant message with tool_use blocks
            assistant_msg = %{"role" => "assistant", "content" => response["content"]}
            # Add user message with tool_result blocks
            user_msg = format_tool_results_message(tool_results)

            new_messages = messages ++ [assistant_msg, user_msg]

            do_loop(
              new_messages,
              skills,
              api_callback,
              executor,
              context,
              iteration + 1,
              max,
              opts
            )
        end

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp execute_single(%ToolCall{} = call, executor, context) do
    start_time = System.monotonic_time()

    result = Executor.execute(call, context, executor)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conjure, :conversation, :tool_call],
      %{duration: duration},
      %{tool: call.name, success: match?({:ok, _}, result)}
    )

    case result do
      {:ok, output} ->
        ToolResult.success(call.id, output)

      {:ok, output, _files} ->
        ToolResult.success(call.id, output)

      {:error, %Error{message: message}} ->
        ToolResult.error(call.id, message)

      {:error, reason} ->
        ToolResult.error(call.id, inspect(reason))
    end
  end

  defp create_default_context(skills, opts) do
    skills_root =
      case skills do
        [%Skill{path: path} | _] -> Path.dirname(path)
        _ -> System.tmp_dir!()
      end

    ExecutionContext.new(
      skills_root: skills_root,
      working_directory:
        Keyword.get(opts, :working_directory, Path.join(System.tmp_dir!(), "conjure_work")),
      timeout: Keyword.get(opts, :timeout, 30_000),
      executor_config: Keyword.get(opts, :executor_config, %{})
    )
  end

  defp maybe_init_executor(executor, context) do
    Code.ensure_loaded(executor)

    if function_exported?(executor, :init, 1) do
      executor.init(context)
    else
      {:ok, context}
    end
  end

  defp maybe_cleanup_executor(executor, context) do
    Code.ensure_loaded(executor)

    if function_exported?(executor, :cleanup, 1) do
      executor.cleanup(context)
    else
      :ok
    end
  end
end
