defmodule Conjure.Session do
  @moduledoc """
  Manage multi-turn conversation sessions.

  This module provides a unified API for managing conversation sessions
  that works with all execution backends: local, Docker, Anthropic, and native.

  ## Unified API

  The same interface works regardless of execution backend:

      # Local execution
      session = Conjure.Session.new_local(skills)
      {:ok, response, session} = Conjure.Session.chat(session, "Hello", api_callback)

      # Docker execution
      session = Conjure.Session.new_local(skills, executor: Conjure.Executor.Docker)
      {:ok, response, session} = Conjure.Session.chat(session, "Hello", api_callback)

      # Anthropic execution
      session = Conjure.Session.new_anthropic([{:anthropic, "xlsx", "latest"}])
      {:ok, response, session} = Conjure.Session.chat(session, "Hello", api_callback)

      # Native execution (Elixir modules)
      session = Conjure.Session.new_native([MyApp.Skills.Database])
      {:ok, response, session} = Conjure.Session.chat(session, "Hello", api_callback)

  ## Session State

  Sessions track:
  - Execution mode (:local, :docker, :anthropic, :native)
  - Message history
  - Created files (with source tracking)
  - Container ID (for Anthropic)
  - Execution context (for local/Docker/native)

  ## File Handling

  Files created during conversations are tracked with their source:

      files = Conjure.Session.get_created_files(session)

      for file <- files do
        case file.source do
          :local -> File.read!(file.id)
          :native -> File.read!(file.id)
          :anthropic -> download_from_anthropic(file.id)
        end
      end

  ## See Also

  * `Conjure.Backend` - Backend behaviour and available backends
  * `Conjure.NativeSkill` - Behaviour for native skill modules
  * `Conjure.Conversation` - Local/Docker conversation loop
  * `Conjure.Conversation.Anthropic` - Anthropic pause_turn loop
  * [ADR-0019: Unified Execution Model](docs/adr/0019-unified-execution-model.md)
  * [ADR-0020: Backend Behaviour Architecture](docs/adr/0020-backend-behaviour.md)
  """

  alias Conjure.API.Anthropic, as: AnthropicAPI
  alias Conjure.Backend
  alias Conjure.{Conversation, Error, ExecutionContext, Skill}
  alias Conjure.Conversation.Anthropic, as: AnthropicConversation

  @type execution_mode :: :local | :docker | :anthropic | :native
  @type skill_spec :: {atom(), String.t(), String.t()}

  @type file_info :: %{
          id: String.t(),
          filename: String.t() | nil,
          size: non_neg_integer() | nil,
          source: :local | :anthropic | :native
        }

  @type uploaded_skill :: %{
          skill_id: String.t(),
          version: String.t(),
          display_title: String.t()
        }

  @type t :: %__MODULE__{
          execution_mode: execution_mode(),
          skills: [Skill.t()] | [skill_spec()] | [module()],
          messages: [map()],
          container_id: String.t() | nil,
          created_files: [file_info()],
          context: ExecutionContext.t() | nil,
          opts: keyword(),
          storage: term() | nil,
          storage_strategy: module() | nil,
          file_callbacks:
            %{Conjure.Storage.callback_event() => Conjure.Storage.file_callback()} | nil,
          uploaded_skills: [uploaded_skill()],
          api_callback: function() | nil
        }

  defstruct [
    :execution_mode,
    :skills,
    :messages,
    :container_id,
    :created_files,
    :context,
    :opts,
    :storage,
    :storage_strategy,
    :file_callbacks,
    :uploaded_skills,
    :api_callback
  ]

  # ============================================================================
  # Session Creation
  # ============================================================================

  @doc """
  Create a session for local/Docker execution.

  ## Options

  * `:executor` - Executor module (default: `Conjure.Executor.Local`)
  * `:working_directory` - Working directory for execution
  * `:timeout` - Execution timeout in ms (default: 30000)
  * `:max_iterations` - Maximum tool-use iterations (default: 25)

  ## Example

      {:ok, skills} = Conjure.load("priv/skills")

      session = Conjure.Session.new_local(skills,
        executor: Conjure.Executor.Docker,
        timeout: 60_000
      )
  """
  @spec new_local([Skill.t()], keyword()) :: t()
  def new_local(skills, opts \\ []) do
    executor = Keyword.get(opts, :executor, Conjure.Executor.Local)
    execution_mode = if executor == Conjure.Executor.Docker, do: :docker, else: :local

    context = create_context(skills, opts)

    %__MODULE__{
      execution_mode: execution_mode,
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

  @doc """
  Create a session for Docker execution with storage.

  This is the recommended way to create Docker sessions as it properly
  initializes storage and fixes the working directory issue.

  ## Options

  * `:storage` - Storage strategy: module or `{module, opts}` (default: `Conjure.Storage.Local`)
  * `:on_file_created` - Callback when file is created: `fn file_ref, session_id -> :ok end`
  * `:on_file_deleted` - Callback when file is deleted
  * `:on_file_synced` - Callback when file is synced from remote
  * `:timeout` - Execution timeout in ms (default: 30000)
  * `:max_iterations` - Maximum tool-use iterations (default: 25)

  ## Example

      # Default local storage
      {:ok, session} = Conjure.Session.new_docker(skills)

      # S3 storage
      {:ok, session} = Conjure.Session.new_docker(skills,
        storage: {Conjure.Storage.S3, bucket: "my-bucket"}
      )

      # With file callbacks
      {:ok, session} = Conjure.Session.new_docker(skills,
        on_file_created: fn file_ref, session_id ->
          IO.puts("File created: \#{file_ref.path}")
        end
      )

      # Cleanup when done
      {:ok, _} = Conjure.Session.cleanup(session)
  """
  @spec new_docker([Skill.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new_docker(skills, opts \\ []) do
    session_id = Conjure.Storage.generate_session_id()

    with {:ok, {strategy, storage_opts}} <- resolve_storage(opts),
         {:ok, storage} <- strategy.init(session_id, storage_opts),
         {:ok, work_dir} <- strategy.local_path(storage) do
      context = create_context_with_storage(skills, work_dir, opts)
      file_callbacks = extract_file_callbacks(opts)

      session = %__MODULE__{
        execution_mode: :docker,
        skills: skills,
        messages: [],
        container_id: nil,
        created_files: [],
        context: context,
        opts: Keyword.put(opts, :executor, Conjure.Executor.Docker),
        storage: storage,
        storage_strategy: strategy,
        file_callbacks: file_callbacks,
        uploaded_skills: [],
        api_callback: nil
      }

      {:ok, session}
    else
      {:error, reason} ->
        {:error, Error.storage_init_failed(reason)}
    end
  end

  @doc """
  Create a session for Docker execution, raising on error.

  Same as `new_docker/2` but raises on failure.

  ## Example

      session = Conjure.Session.new_docker!(skills)
  """
  @spec new_docker!([Skill.t()], keyword()) :: t()
  def new_docker!(skills, opts \\ []) do
    case new_docker(skills, opts) do
      {:ok, session} -> session
      {:error, error} -> raise error
    end
  end

  @doc """
  Create a session for Anthropic execution.

  Accepts either:
  - Skill specs for pre-uploaded or Anthropic-provided skills
  - `Skill.t()` structs (or `.skill` file paths) which will be uploaded automatically

  ## Options

  * `:api_callback` - Required when passing `Skill.t()` structs for upload
  * `:max_iterations` - Maximum pause_turn iterations (default: 10)
  * `:on_pause` - Callback when pause_turn received

  ## Example

      # Using pre-uploaded or Anthropic skills (no upload needed)
      {:ok, session} = Conjure.Session.new_anthropic([
        {:anthropic, "xlsx", "latest"},
        {:anthropic, "pdf", "latest"}
      ])

      # Using local skills (will be uploaded automatically)
      {:ok, skill} = Conjure.Loader.load_skill_file("my-skill.skill")
      {:ok, session} = Conjure.Session.new_anthropic([skill],
        api_callback: my_api_callback
      )

      # Cleanup deletes uploaded skills
      :ok = Conjure.Session.cleanup(session)
  """
  @spec new_anthropic([skill_spec()] | [Skill.t()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new_anthropic(skills, opts \\ []) do
    case classify_skills(skills) do
      :skill_specs ->
        # Pre-uploaded or Anthropic-provided skills - no upload needed
        session = %__MODULE__{
          execution_mode: :anthropic,
          skills: skills,
          messages: [],
          container_id: nil,
          created_files: [],
          context: nil,
          opts: opts,
          uploaded_skills: [],
          api_callback: nil
        }

        {:ok, session}

      :skill_structs ->
        # Local skills that need to be uploaded
        api_callback = Keyword.get(opts, :api_callback)

        if api_callback do
          upload_and_create_session(skills, api_callback, opts)
        else
          {:error,
           Error.missing_api_callback(
             "new_anthropic requires :api_callback option when passing Skill.t() structs"
           )}
        end
    end
  end

  @doc """
  Create a session for Anthropic execution, raising on error.

  Same as `new_anthropic/2` but raises on failure.

  ## Example

      session = Conjure.Session.new_anthropic!([skill], api_callback: my_callback)
  """
  @spec new_anthropic!([skill_spec()] | [Skill.t()], keyword()) :: t()
  def new_anthropic!(skills, opts \\ []) do
    case new_anthropic(skills, opts) do
      {:ok, session} -> session
      {:error, error} -> raise error
    end
  end

  @doc """
  Create a session for native Elixir module execution.

  Native skills are Elixir modules that implement the `Conjure.NativeSkill`
  behaviour. They execute directly in the BEAM with full access to the
  application's runtime context.

  ## Options

  * `:working_directory` - Working directory for file operations
  * `:timeout` - Execution timeout in ms (default: 30000)
  * `:max_iterations` - Maximum tool-use iterations (default: 25)

  ## Example

      defmodule MyApp.Skills.Cache do
        @behaviour Conjure.NativeSkill

        def __skill_info__ do
          %{name: "cache", description: "Cache manager", allowed_tools: [:execute]}
        end

        def execute("clear", _ctx), do: {:ok, "Cache cleared"}
      end

      session = Conjure.Session.new_native([MyApp.Skills.Cache])
  """
  @spec new_native([module()], keyword()) :: t()
  def new_native(skill_modules, opts \\ []) do
    Backend.Native.new_session(skill_modules, opts)
  end

  # ============================================================================
  # Conversation
  # ============================================================================

  @doc """
  Send a message and get a response.

  Works identically for both local/Docker and Anthropic execution modes.
  The `api_callback` is passed per-call, following API-agnostic design.

  ## API Callback

  For local/Docker execution:

      api_callback = fn messages ->
        # Your HTTP client call
        MyApp.Claude.post("/v1/messages", %{messages: messages})
      end

  For Anthropic execution, the callback should handle the container config:

      api_callback = fn messages ->
        # Container config is built by the session
        MyApp.Claude.post("/v1/messages", %{messages: messages})
      end

  ## Returns

  Returns `{:ok, response, updated_session}` on success.

  ## Example

      {:ok, response, session} = Conjure.Session.chat(
        session,
        "Create a spreadsheet",
        &my_api_callback/1
      )

      # Continue conversation
      {:ok, response2, session} = Conjure.Session.chat(
        session,
        "Add headers to it",
        &my_api_callback/1
      )
  """
  @spec chat(t(), String.t(), (list() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map(), t()} | {:error, Error.t()}
  def chat(%__MODULE__{execution_mode: :anthropic} = session, user_message, api_callback) do
    chat_anthropic(session, user_message, api_callback)
  end

  def chat(%__MODULE__{execution_mode: :native} = session, user_message, api_callback) do
    Backend.Native.chat(session, user_message, api_callback, [])
  end

  def chat(%__MODULE__{} = session, user_message, api_callback) do
    chat_local(session, user_message, api_callback)
  end

  # ============================================================================
  # Message Management
  # ============================================================================

  @doc """
  Add a message to the session history.
  """
  @spec add_message(t(), map()) :: t()
  def add_message(%__MODULE__{messages: messages} = session, message) do
    %{session | messages: messages ++ [message]}
  end

  @doc """
  Get all messages in the session.
  """
  @spec get_messages(t()) :: [map()]
  def get_messages(%__MODULE__{messages: messages}), do: messages

  @doc """
  Reset messages to empty (keeps session configuration).
  """
  @spec reset_messages(t()) :: t()
  def reset_messages(%__MODULE__{} = session) do
    %{session | messages: [], container_id: nil}
  end

  # ============================================================================
  # File Management
  # ============================================================================

  @doc """
  Get all files created during the session.

  Returns a list of file info maps with source tracking.
  """
  @spec get_created_files(t()) :: [file_info()]
  def get_created_files(%__MODULE__{created_files: files}), do: files

  # ============================================================================
  # State Accessors
  # ============================================================================

  @doc """
  Get the execution mode of the session.
  """
  @spec execution_mode(t()) :: execution_mode()
  def execution_mode(%__MODULE__{execution_mode: mode}), do: mode

  @doc """
  Get the container ID (Anthropic sessions only).
  """
  @spec container_id(t()) :: String.t() | nil
  def container_id(%__MODULE__{container_id: id}), do: id

  @doc """
  Get the execution context (local/Docker sessions only).
  """
  @spec context(t()) :: ExecutionContext.t() | nil
  def context(%__MODULE__{context: ctx}), do: ctx

  @doc """
  Get the skills associated with the session.
  """
  @spec skills(t()) :: [Skill.t()] | [skill_spec()]
  def skills(%__MODULE__{skills: skills}), do: skills

  # ============================================================================
  # Storage Management
  # ============================================================================

  @doc """
  Cleanup session resources including storage and uploaded skills.

  Should be called when done with a session to release resources.
  - For Docker sessions: removes the working directory and any remote storage
  - For Anthropic sessions: deletes uploaded skills from Anthropic

  ## Example

      {:ok, session} = Conjure.Session.new_docker(skills)
      # ... use session ...
      {:ok, _} = Conjure.Session.cleanup(session)

      {:ok, session} = Conjure.Session.new_anthropic([skill], api_callback: cb)
      # ... use session ...
      :ok = Conjure.Session.cleanup(session)
  """
  @spec cleanup(t()) :: :ok | {:ok, t()} | {:error, Error.t()}
  def cleanup(%__MODULE__{
        execution_mode: :anthropic,
        uploaded_skills: uploaded,
        api_callback: api_callback
      })
      when uploaded != [] and api_callback != nil do
    cleanup_uploaded_skills(uploaded, api_callback)
    :ok
  end

  def cleanup(%__MODULE__{storage: nil} = session), do: {:ok, session}

  def cleanup(%__MODULE__{storage: storage, storage_strategy: strategy} = session) do
    case strategy.cleanup(storage) do
      :ok ->
        {:ok, %{session | storage: nil, storage_strategy: nil}}

      {:error, reason} ->
        {:error, Error.storage_cleanup_failed(reason)}
    end
  end

  def cleanup(%__MODULE__{}), do: :ok

  @doc """
  Get the storage state for this session.
  """
  @spec storage(t()) :: term() | nil
  def storage(%__MODULE__{storage: storage}), do: storage

  @doc """
  Get the storage strategy module for this session.
  """
  @spec storage_strategy(t()) :: module() | nil
  def storage_strategy(%__MODULE__{storage_strategy: strategy}), do: strategy

  @doc """
  Get the session ID from storage.

  Returns `nil` if no storage is configured.
  """
  @spec session_id(t()) :: String.t() | nil
  def session_id(%__MODULE__{storage: nil}), do: nil
  def session_id(%__MODULE__{storage: %{session_id: id}}), do: id

  def session_id(%__MODULE__{storage: storage}) when is_map(storage),
    do: Map.get(storage, :session_id)

  def session_id(_), do: nil

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp chat_local(session, user_message, api_callback) do
    user_msg = %{"role" => "user", "content" => user_message}
    messages = session.messages ++ [user_msg]

    opts =
      session.opts
      |> Keyword.put(:context, session.context)
      |> Keyword.put(:executor, get_executor(session))

    case Conversation.run_loop(messages, session.skills, api_callback, opts) do
      {:ok, final_messages} ->
        # Extract the last assistant message as response
        response = build_local_response(final_messages)

        # Track any created files
        new_files = extract_local_files(session.context)

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

  defp chat_anthropic(session, user_message, api_callback) do
    user_msg = %{"role" => "user", "content" => user_message}
    messages = session.messages ++ [user_msg]

    # Build container config
    {:ok, container_config} = AnthropicAPI.container_config(session.skills)

    container_config =
      if session.container_id do
        AnthropicAPI.with_container_id(container_config, session.container_id)
      else
        container_config
      end

    opts = [
      max_iterations: Keyword.get(session.opts, :max_iterations, 10),
      on_pause: Keyword.get(session.opts, :on_pause)
    ]

    case AnthropicConversation.run(messages, container_config, api_callback, opts) do
      {:ok, result} ->
        # Build file info from file_ids
        new_files =
          Enum.map(result.file_ids, fn file_id ->
            %{
              id: file_id,
              filename: nil,
              size: nil,
              source: :anthropic
            }
          end)

        updated_session = %{
          session
          | messages: result.messages,
            container_id: result.container_id,
            created_files: session.created_files ++ new_files
        }

        {:ok, result.response, updated_session}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_executor(%{execution_mode: :docker}), do: Conjure.Executor.Docker
  defp get_executor(_), do: Conjure.Executor.Local

  defp create_context(skills, opts) do
    skills_root =
      case skills do
        [%Skill{path: path} | _] -> Path.dirname(path)
        _ -> System.tmp_dir!()
      end

    ExecutionContext.new(
      skills_root: skills_root,
      working_directory:
        Keyword.get(opts, :working_directory, Path.join(System.tmp_dir!(), "conjure_session")),
      timeout: Keyword.get(opts, :timeout, 30_000),
      executor_config: Keyword.get(opts, :executor_config, %{})
    )
  end

  defp build_local_response(messages) do
    # Get the last assistant message
    messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg["role"] == "assistant" end)
    |> case do
      nil -> %{"content" => [], "stop_reason" => "end_turn"}
      msg -> Map.put(msg, "stop_reason", "end_turn")
    end
  end

  defp extract_local_files(_context) do
    # Local file tracking would need to be implemented based on
    # the specific executor's file tracking mechanism
    # For now, return empty list - files are on local filesystem
    []
  end

  # ===========================================================================
  # Storage Helpers
  # ===========================================================================

  defp resolve_storage(opts) do
    case Keyword.get(opts, :storage) do
      nil ->
        {:ok, {Conjure.Storage.Local, []}}

      {module, storage_opts} when is_atom(module) ->
        {:ok, {module, storage_opts}}

      module when is_atom(module) ->
        {:ok, {module, []}}

      other ->
        {:error, {:invalid_storage_config, other}}
    end
  end

  defp extract_file_callbacks(opts) do
    callbacks = %{}

    callbacks =
      case Keyword.get(opts, :on_file_created) do
        nil -> callbacks
        cb -> Map.put(callbacks, :created, cb)
      end

    callbacks =
      case Keyword.get(opts, :on_file_deleted) do
        nil -> callbacks
        cb -> Map.put(callbacks, :deleted, cb)
      end

    case Keyword.get(opts, :on_file_synced) do
      nil -> callbacks
      cb -> Map.put(callbacks, :synced, cb)
    end
  end

  defp create_context_with_storage(skills, work_dir, opts) do
    # For Docker, use the skill's path directly so relative paths work
    # When mounting skill.path as /mnt/skills, scripts/ is at /mnt/skills/scripts/
    skills_root =
      case skills do
        [%Skill{path: path} | _] -> path
        _ -> System.tmp_dir!()
      end

    ExecutionContext.new(
      skills_root: skills_root,
      working_directory: work_dir,
      timeout: Keyword.get(opts, :timeout, 30_000),
      executor_config: Keyword.get(opts, :executor_config, %{})
    )
  end

  # ===========================================================================
  # Anthropic Upload Helpers
  # ===========================================================================

  defp classify_skills([]), do: :skill_specs

  defp classify_skills([first | _]) do
    case first do
      %Skill{} -> :skill_structs
      {_, _, _} -> :skill_specs
      _ -> :skill_specs
    end
  end

  defp upload_and_create_session(skills, api_callback, opts) do
    # Upload each skill and collect results
    results =
      Enum.reduce_while(skills, {:ok, []}, fn skill, {:ok, acc} ->
        display_title = Keyword.get(opts, :display_title, skill.name)

        case Conjure.Skills.Anthropic.upload(skill.path, api_callback,
               display_title: display_title
             ) do
          {:ok, result} ->
            {:cont, {:ok, [result | acc]}}

          {:error, error} ->
            # Cleanup any skills we already uploaded
            cleanup_uploaded_skills(acc, api_callback)
            {:halt, {:error, error}}
        end
      end)

    case results do
      {:ok, uploaded} ->
        uploaded = Enum.reverse(uploaded)

        # Build skill specs from uploaded results
        skill_specs =
          Enum.map(uploaded, fn %{skill_id: id, version: version} ->
            {:custom, id, version}
          end)

        session = %__MODULE__{
          execution_mode: :anthropic,
          skills: skill_specs,
          messages: [],
          container_id: nil,
          created_files: [],
          context: nil,
          opts: opts,
          uploaded_skills: uploaded,
          api_callback: api_callback
        }

        {:ok, session}

      {:error, error} ->
        {:error, error}
    end
  end

  defp cleanup_uploaded_skills(uploaded_skills, api_callback) do
    for %{skill_id: skill_id} <- uploaded_skills do
      # Delete all versions first
      case Conjure.Skills.Anthropic.list_versions(skill_id, api_callback) do
        {:ok, versions} ->
          for v <- versions do
            Conjure.Skills.Anthropic.delete_version(skill_id, v["version"], api_callback)
          end

        _ ->
          :ok
      end

      # Then delete the skill
      Conjure.Skills.Anthropic.delete(skill_id, api_callback)
    end

    :ok
  end
end
