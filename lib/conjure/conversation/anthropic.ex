defmodule Conjure.Conversation.Anthropic do
  @moduledoc """
  Conversation loop for Anthropic Skills API with pause_turn handling.

  Unlike local/Docker execution where Conjure manages tool execution,
  here Anthropic executes skills in their container. However, long-running
  operations return `pause_turn` and require continuation.

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
      ┌────────────┐    Yes   ┌────────────────┐
      │pause_turn? │──────────►│ Build Continue │
      └────────────┘          └───────┬────────┘
           │ No                       │
           ▼                          ▼
      Return Final             Update Messages
       Response                Container ID ────┘

  ## Example

      {:ok, container} = Conjure.API.Anthropic.container_config([
        {:anthropic, "xlsx", "latest"}
      ])

      messages = [%{"role" => "user", "content" => "Create a budget spreadsheet"}]

      {:ok, result} = Conjure.Conversation.Anthropic.run(
        messages,
        container,
        &call_claude/1,
        max_iterations: 10,
        on_pause: fn _response, attempt -> IO.puts("Pause \#{attempt}") end
      )

  ## References

  * [Anthropic Skills API Guide](https://platform.claude.com/docs/en/build-with-claude/skills-guide)
  """

  alias Conjure.API.Anthropic, as: API
  alias Conjure.Error

  require Logger

  @default_max_iterations 10

  @type message :: map()
  @type api_callback :: ([message()] -> {:ok, map()} | {:error, term()})

  @type opts :: [
          max_iterations: pos_integer(),
          on_pause: (response :: map(), attempt :: pos_integer() -> any()),
          on_response: (response :: map() -> any())
        ]

  @type result :: %{
          response: map(),
          messages: [message()],
          container_id: String.t() | nil,
          iterations: pos_integer(),
          file_ids: [String.t()]
        }

  @doc """
  Run a conversation with Anthropic-hosted skills, handling pause_turn.

  Takes a callback function that makes Claude API calls. The callback
  receives the current messages list and should return `{:ok, response}`
  or `{:error, reason}`.

  ## Options

  * `:max_iterations` - Maximum pause_turn iterations (default: 10)
  * `:on_pause` - Callback when pause_turn received `fn response, attempt -> :ok end`
  * `:on_response` - Callback for each response `fn response -> :ok end`

  ## Returns

  On success, returns `{:ok, result}` where result contains:

  * `:response` - The final API response
  * `:messages` - Complete conversation history
  * `:container_id` - Container ID for session reuse
  * `:iterations` - Number of iterations taken
  * `:file_ids` - List of file IDs created during execution

  ## Example

      {:ok, container} = Conjure.API.Anthropic.container_config([
        {:anthropic, "xlsx", "latest"}
      ])

      {:ok, result} = Conjure.Conversation.Anthropic.run(
        [%{"role" => "user", "content" => "Create a spreadsheet"}],
        container,
        fn messages ->
          body = Conjure.API.Anthropic.build_request(messages, container)
          MyApp.Claude.post("/v1/messages", body)
        end
      )

      # Access results
      result.file_ids
      # => ["file_abc123"]
  """
  @spec run([message()], map(), api_callback(), opts()) ::
          {:ok, result()} | {:error, Error.t()}
  def run(messages, container_config, api_callback, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    do_run(messages, container_config, api_callback, opts, 0, max_iterations, [])
  end

  @doc """
  Continue from a previous result.

  Use this to resume a conversation that was completed but you want
  to continue with additional user messages.

  ## Example

      # First conversation
      {:ok, result1} = run(messages1, container, callback)

      # Continue with new message, reusing container
      updated_messages = result1.messages ++ [%{"role" => "user", "content" => "Now add headers"}]
      updated_container = Conjure.API.Anthropic.with_container_id(container, result1.container_id)

      {:ok, result2} = run(updated_messages, updated_container, callback)
  """
  @spec continue(result(), [message()], api_callback(), opts()) ::
          {:ok, result()} | {:error, Error.t()}
  def continue(previous_result, additional_messages, api_callback, opts \\ []) do
    messages = previous_result.messages ++ additional_messages

    # Preserve container ID from previous result
    container_config =
      if previous_result.container_id do
        %{"id" => previous_result.container_id}
      else
        %{}
      end

    run(messages, container_config, api_callback, opts)
  end

  @doc """
  Check if a result indicates the conversation is complete.

  Returns false if the result came from a pause_turn that hit max iterations.
  """
  @spec complete?(result()) :: boolean()
  def complete?(%{response: response}) do
    API.end_turn?(response) or not API.pause_turn?(response)
  end

  @doc """
  Extract the final text response from a result.
  """
  @spec extract_text(result()) :: String.t()
  def extract_text(%{response: response}) do
    API.extract_text(response)
  end

  # Private implementation

  defp do_run(_messages, _container, _callback, _opts, iteration, max, _all_file_ids)
       when iteration >= max do
    {:error, Error.pause_turn_max_exceeded(iteration, max)}
  end

  defp do_run(messages, container_config, api_callback, opts, iteration, max, all_file_ids) do
    emit_telemetry(:iteration, %{iteration: iteration})

    case api_callback.(messages) do
      {:ok, response} ->
        maybe_call_on_response(opts, response)

        handle_response(
          response,
          messages,
          container_config,
          api_callback,
          opts,
          iteration,
          max,
          all_file_ids
        )

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp handle_response(
         response,
         messages,
         container_config,
         api_callback,
         opts,
         iteration,
         max,
         all_file_ids
       ) do
    # Extract file IDs from this response
    new_file_ids = API.extract_file_ids(response)
    updated_file_ids = Enum.uniq(all_file_ids ++ new_file_ids)

    # Get container ID from response (for multi-turn reuse)
    container_id = get_in(response, ["container", "id"])

    if API.pause_turn?(response) do
      # Long-running operation paused - continue conversation
      maybe_call_on_pause(opts, response, iteration + 1)

      # Build updated messages with assistant response
      assistant_msg = API.build_assistant_message(response)
      updated_messages = messages ++ [assistant_msg]

      # Update container config with container ID for reuse
      updated_container =
        if container_id do
          API.with_container_id(container_config, container_id)
        else
          container_config
        end

      do_run(
        updated_messages,
        updated_container,
        api_callback,
        opts,
        iteration + 1,
        max,
        updated_file_ids
      )
    else
      # Conversation complete (end_turn or other stop reason)
      assistant_msg = API.build_assistant_message(response)
      final_messages = messages ++ [assistant_msg]

      result = %{
        response: response,
        messages: final_messages,
        container_id: container_id,
        iterations: iteration + 1,
        file_ids: updated_file_ids
      }

      {:ok, result}
    end
  end

  defp maybe_call_on_pause(opts, response, attempt) do
    case Keyword.get(opts, :on_pause) do
      nil -> :ok
      callback when is_function(callback, 2) -> callback.(response, attempt)
    end
  end

  defp maybe_call_on_response(opts, response) do
    case Keyword.get(opts, :on_response) do
      nil -> :ok
      callback when is_function(callback, 1) -> callback.(response)
    end
  end

  defp emit_telemetry(event, measurements) do
    :telemetry.execute(
      [:conjure, :conversation, :anthropic, event],
      measurements,
      %{}
    )
  end
end
