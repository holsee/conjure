defmodule Conjure.Backend do
  @moduledoc """
  Behaviour for execution backends.

  This behaviour defines the unified interface that all execution backends
  must implement, enabling pluggable execution strategies.

  ## Available Backends

  | Backend | Module | Description |
  |---------|--------|-------------|
  | Local | `Conjure.Backend.Local` | Bash commands on host |
  | Docker | `Conjure.Backend.Docker` | Bash commands in container |
  | Anthropic | `Conjure.Backend.Anthropic` | Hosted execution via Skills API |
  | Native | `Conjure.Backend.Native` | Elixir modules in BEAM |

  ## Example

      # Using a backend directly
      session = Conjure.Backend.Local.new_session(skills, [])
      {:ok, response, session} = Conjure.Backend.Local.chat(
        session,
        "Hello",
        &api_callback/1,
        []
      )

  ## Implementing a Custom Backend

      defmodule MyApp.Backend.Custom do
        @behaviour Conjure.Backend

        @impl true
        def backend_type, do: :custom

        @impl true
        def new_session(skills, opts) do
          # Create session state
        end

        @impl true
        def chat(session, message, api_callback, opts) do
          # Execute chat turn
        end
      end

  ## See Also

  * `Conjure.Session` - Unified session API
  * `Conjure.NativeSkill` - Behaviour for native skill modules
  """

  alias Conjure.Session

  @type session :: Session.t()
  @type api_callback :: ([map()] -> {:ok, map()} | {:error, term()})
  @type chat_result :: {:ok, response :: map(), session()} | {:error, term()}

  @doc """
  Get the backend type identifier.

  Returns an atom identifying this backend (e.g., :local, :docker, :anthropic, :native).
  """
  @callback backend_type() :: atom()

  @doc """
  Create a new session for this backend.

  ## Parameters

  * `skills` - Skills to use (format depends on backend)
  * `opts` - Backend-specific options

  ## Returns

  A new session struct configured for this backend.
  """
  @callback new_session(skills :: term(), opts :: keyword()) :: session()

  @doc """
  Execute a chat turn.

  Sends a message and returns the response along with updated session state.

  ## Parameters

  * `session` - Current session state
  * `message` - User message to send
  * `api_callback` - Function to call the LLM API
  * `opts` - Additional options for this turn

  ## Returns

  * `{:ok, response, updated_session}` - On success
  * `{:error, error}` - On failure
  """
  @callback chat(session(), message :: String.t(), api_callback(), opts :: keyword()) ::
              chat_result()

  @doc """
  Get the backend module for a given type.

  ## Example

      Conjure.Backend.get(:local)
      # => Conjure.Backend.Local

      Conjure.Backend.get(:native)
      # => Conjure.Backend.Native
  """
  @spec get(atom()) :: module() | nil
  def get(:local), do: Conjure.Backend.Local
  def get(:docker), do: Conjure.Backend.Docker
  def get(:anthropic), do: Conjure.Backend.Anthropic
  def get(:native), do: Conjure.Backend.Native
  def get(_), do: nil

  @doc """
  List all available backend types.
  """
  @spec available() :: [atom()]
  def available, do: [:local, :docker, :anthropic, :native]
end
