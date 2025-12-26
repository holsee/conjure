defmodule Conjure.Backend.Local do
  @moduledoc """
  Backend for local execution of skills.

  Executes skill tool calls directly on the host system using bash commands.
  Uses `Conjure.Executor.Local` for command execution and `Conjure.Conversation`
  for the tool-use loop.

  ## Usage

      {:ok, skills} = Conjure.load("priv/skills")
      session = Conjure.Backend.Local.new_session(skills, [])

      {:ok, response, session} = Conjure.Backend.Local.chat(
        session,
        "Read the config file",
        &api_callback/1,
        []
      )

  ## Options

  * `:working_directory` - Working directory for file operations
  * `:timeout` - Execution timeout in milliseconds (default: 30_000)
  * `:max_iterations` - Maximum tool-use iterations (default: 25)
  * `:executor_config` - Additional executor configuration

  ## See Also

  * `Conjure.Backend.Docker` - Docker-based execution
  * `Conjure.Executor.Local` - Low-level executor
  """

  @behaviour Conjure.Backend

  alias Conjure.{Conversation, ExecutionContext, Session, Skill}

  @impl true
  def backend_type, do: :local

  @impl true
  def new_session(skills, opts) do
    context = create_context(skills, opts)

    %Session{
      execution_mode: :local,
      skills: skills,
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

    loop_opts =
      session.opts
      |> Keyword.merge(opts)
      |> Keyword.put(:context, session.context)
      |> Keyword.put(:executor, Conjure.Executor.Local)

    case Conversation.run_loop(messages, session.skills, api_callback, loop_opts) do
      {:ok, final_messages} ->
        response = build_response(final_messages)
        new_files = extract_created_files(session.context)

        updated_session = %{
          session
          | messages: final_messages,
            created_files: session.created_files ++ new_files
        }

        {:ok, response, updated_session}

      {:error, error} ->
        {:error, error}
    end
  end

  # Private functions

  defp create_context(skills, opts) do
    skills_root =
      case skills do
        [%Skill{path: path} | _] -> Path.dirname(path)
        _ -> System.tmp_dir!()
      end

    ExecutionContext.new(
      skills_root: skills_root,
      working_directory: Keyword.get(opts, :working_directory, default_working_dir()),
      timeout: Keyword.get(opts, :timeout, 30_000),
      executor_config: Keyword.get(opts, :executor_config, %{})
    )
  end

  defp default_working_dir do
    Path.join(System.tmp_dir!(), "conjure_local_#{:rand.uniform(100_000)}")
  end

  defp build_response(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg["role"] == "assistant" end)
    |> case do
      nil -> %{"content" => [], "stop_reason" => "end_turn"}
      msg -> Map.put(msg, "stop_reason", "end_turn")
    end
  end

  defp extract_created_files(_context) do
    # Local file tracking could be implemented based on
    # specific executor's file tracking mechanism
    # For now, return empty - files are on local filesystem
    []
  end
end
