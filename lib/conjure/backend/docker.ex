defmodule Conjure.Backend.Docker do
  @moduledoc """
  Backend for Docker-based execution of skills.

  Executes skill tool calls inside Docker containers for isolation and security.
  Uses `Conjure.Executor.Docker` for command execution and `Conjure.Conversation`
  for the tool-use loop.

  ## Recommended Usage

  For new code, use `Conjure.Session.new_docker/2` which provides proper storage
  integration and working directory management:

      {:ok, skills} = Conjure.load("priv/skills")
      {:ok, session} = Conjure.Session.new_docker(skills)

      {:ok, response, session} = Conjure.Session.chat(
        session,
        "Run the analysis",
        &api_callback/1
      )

      # Cleanup when done
      {:ok, _} = Conjure.Session.cleanup(session)

  ## Direct Backend Usage

  For lower-level control, you can use this backend directly:

      {:ok, skills} = Conjure.load("priv/skills")
      session = Conjure.Backend.Docker.new_session(skills, [])

      {:ok, response, session} = Conjure.Backend.Docker.chat(
        session,
        "Run the analysis",
        &api_callback/1,
        []
      )

  ## Options

  * `:working_directory` - Working directory on host (mounted to `/workspace` in container)
  * `:timeout` - Execution timeout in milliseconds (default: 30_000)
  * `:max_iterations` - Maximum tool-use iterations (default: 25)
  * `:executor_config` - Docker-specific configuration:
    * `:image` - Docker image to use
    * `:volumes` - Volume mounts
    * `:network` - Network mode

  ## See Also

  * `Conjure.Session` - Recommended high-level API with storage support
  * `Conjure.Backend.Local` - Local execution
  * `Conjure.Executor.Docker` - Low-level Docker executor
  """

  @behaviour Conjure.Backend

  alias Conjure.{Conversation, ExecutionContext, Session, Skill}

  @impl true
  def backend_type, do: :docker

  @impl true
  def new_session(skills, opts) do
    context = create_context(skills, opts)

    %Session{
      execution_mode: :docker,
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
      |> Keyword.put(:executor, Conjure.Executor.Docker)

    case Conversation.run_loop(messages, session.skills, api_callback, loop_opts) do
      {:ok, final_messages} ->
        response = build_response(final_messages)
        new_files = extract_created_files(session.context)

        updated_session = %{
          session
          | messages: final_messages,
            created_files: session.created_files ++ new_files,
            container_id: session.context.container_id
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

    # Generate a unique working directory if not provided.
    # Note: For proper storage integration, use Session.new_docker/2 instead.
    default_work_dir =
      Path.join(System.tmp_dir!(), "conjure_docker_#{:rand.uniform(1_000_000)}")

    work_dir = Keyword.get(opts, :working_directory, default_work_dir)

    # Ensure the working directory exists on the host
    File.mkdir_p!(work_dir)

    ExecutionContext.new(
      skills_root: skills_root,
      working_directory: work_dir,
      timeout: Keyword.get(opts, :timeout, 30_000),
      executor_config: Keyword.get(opts, :executor_config, %{})
    )
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
    # Docker file tracking could be implemented based on
    # container volume mounts and tracking
    []
  end
end
