defmodule Conjure.Backend.Anthropic do
  @moduledoc """
  Backend for Anthropic-hosted skill execution.

  Executes skills using the Anthropic Skills API, where Anthropic manages
  the execution environment in their cloud. Uses `Conjure.Conversation.Anthropic`
  for the pause_turn loop handling.

  ## Usage

      session = Conjure.Backend.Anthropic.new_session([
        {:anthropic, "xlsx", "latest"},
        {:anthropic, "pdf", "latest"}
      ], [])

      {:ok, response, session} = Conjure.Backend.Anthropic.chat(
        session,
        "Create a budget spreadsheet",
        &api_callback/1,
        []
      )

  ## Skill Specifications

  Skills are specified as tuples: `{:anthropic, name, version}`

  * `:anthropic` - Source identifier
  * `name` - Skill name (e.g., "xlsx", "pdf", "pptx")
  * `version` - Skill version (e.g., "latest", "v1")

  ## Options

  * `:max_iterations` - Maximum pause_turn iterations (default: 10)
  * `:on_pause` - Callback when pause_turn received

  ## Container Reuse

  The session automatically tracks and reuses container IDs across
  conversation turns for efficiency.

  ## File Handling

  Files created during execution are tracked in `session.created_files`.
  Use `Conjure.Files.Anthropic` to download them.

  ## See Also

  * `Conjure.Backend.Local` - Local execution
  * `Conjure.Conversation.Anthropic` - Pause-turn loop
  * `Conjure.Files.Anthropic` - File downloads
  """

  @behaviour Conjure.Backend

  alias Conjure.API.Anthropic, as: API
  alias Conjure.Conversation.Anthropic, as: AnthropicConversation
  alias Conjure.{Error, Session}

  @impl true
  def backend_type, do: :anthropic

  @impl true
  def new_session(skill_specs, opts) do
    %Session{
      execution_mode: :anthropic,
      skills: skill_specs,
      messages: [],
      container_id: nil,
      created_files: [],
      context: nil,
      opts: opts,
      uploaded_skills: [],
      api_callback: nil
    }
  end

  @impl true
  def chat(session, message, api_callback, opts) do
    user_msg = %{"role" => "user", "content" => message}
    messages = session.messages ++ [user_msg]

    with {:ok, container_config} <- API.container_config(session.skills),
         container_config <- maybe_add_container_id(container_config, session.container_id),
         conversation_opts <- build_conversation_opts(session.opts, opts),
         {:ok, result} <-
           AnthropicConversation.run(messages, container_config, api_callback, conversation_opts) do
      new_files = build_file_infos(result.file_ids)

      updated_session = %{
        session
        | messages: result.messages,
          container_id: result.container_id,
          created_files: session.created_files ++ new_files
      }

      {:ok, result.response, updated_session}
    end
  end

  defp maybe_add_container_id(config, nil), do: config

  defp maybe_add_container_id(config, container_id),
    do: API.with_container_id(config, container_id)

  defp build_conversation_opts(session_opts, call_opts) do
    [
      max_iterations: Keyword.get(session_opts, :max_iterations, 10),
      on_pause: Keyword.get(session_opts, :on_pause)
    ] ++ Keyword.take(call_opts, [:on_pause, :on_response])
  end

  defp build_file_infos(file_ids) do
    Enum.map(file_ids, fn file_id ->
      %{id: file_id, filename: nil, size: nil, source: :anthropic}
    end)
  end

  @doc """
  Validate skill specifications.

  Returns `{:ok, specs}` if all specs are valid, or `{:error, error}` otherwise.

  ## Example

      Conjure.Backend.Anthropic.validate_skills([
        {:anthropic, "xlsx", "latest"},
        {:anthropic, "pdf", "latest"}
      ])
      # => {:ok, [{:anthropic, "xlsx", "latest"}, {:anthropic, "pdf", "latest"}]}
  """
  @spec validate_skills([Session.skill_spec()]) ::
          {:ok, [Session.skill_spec()]} | {:error, Error.t()}
  def validate_skills(skill_specs) when is_list(skill_specs) do
    invalid = Enum.reject(skill_specs, &valid_skill_spec?/1)

    if Enum.empty?(invalid) do
      {:ok, skill_specs}
    else
      {:error, Error.invalid_skill_spec(inspect(invalid))}
    end
  end

  defp valid_skill_spec?({:anthropic, name, version})
       when is_binary(name) and is_binary(version), do: true

  defp valid_skill_spec?(_), do: false
end
