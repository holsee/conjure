defmodule Conjure.Registry do
  @moduledoc """
  In-memory registry of loaded skills.

  The Registry provides both a stateful GenServer for OTP applications
  and pure functions for stateless usage.

  ## GenServer Usage

  Add to your supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {Conjure.Registry, name: MyApp.Skills, paths: ["/path/to/skills"]}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  Then access skills anywhere:

      skills = Conjure.Registry.list(MyApp.Skills)
      skill = Conjure.Registry.get(MyApp.Skills, "pdf")

  ## Stateless Usage

  For simpler use cases without a GenServer:

      {:ok, skills} = Conjure.load("/path/to/skills")
      index = Conjure.Registry.index(skills)
      skill = Conjure.Registry.find(index, "pdf")

  ## Options

  * `:name` - Required. The name to register the GenServer under.
  * `:paths` - List of paths to load skills from.
  * `:reload_interval` - Optional. Interval in ms to auto-reload skills.
  """

  use GenServer

  alias Conjure.{Loader, Skill}

  require Logger

  defstruct [:name, :paths, :reload_interval, :skills, :index, :ets_table]

  @type t :: %__MODULE__{
          name: atom(),
          paths: [Path.t()],
          reload_interval: pos_integer() | nil,
          skills: [Skill.t()],
          index: %{String.t() => Skill.t()},
          ets_table: :ets.tid() | nil
        }

  # Client API (Stateful)

  @doc """
  Start the registry as a GenServer.

  ## Options

  * `:name` - Required. Name to register under.
  * `:paths` - List of paths to load skills from (default: [])
  * `:reload_interval` - Auto-reload interval in ms (optional)
  * `:use_ets` - Store skills in ETS for concurrent reads (default: true)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get all registered skills.
  """
  @spec list(GenServer.server()) :: [Skill.t()]
  def list(server) do
    GenServer.call(server, :list)
  end

  @doc """
  Find a skill by name.
  """
  @spec get(GenServer.server(), String.t()) :: Skill.t() | nil
  def get(server, name) do
    GenServer.call(server, {:get, name})
  end

  @doc """
  Register additional skills with the registry.
  """
  @spec register(GenServer.server(), [Skill.t()]) :: :ok
  def register(server, skills) do
    GenServer.call(server, {:register, skills})
  end

  @doc """
  Reload skills from configured paths.
  """
  @spec reload(GenServer.server()) :: :ok | {:error, term()}
  def reload(server) do
    GenServer.call(server, :reload)
  end

  @doc """
  Get the count of registered skills.
  """
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server) do
    GenServer.call(server, :count)
  end

  # Pure Functions (Stateless)

  @doc """
  Create an index from a list of skills.

  Returns a map from skill name to skill struct for O(1) lookups.
  """
  @spec index([Skill.t()]) :: %{String.t() => Skill.t()}
  def index(skills) do
    Map.new(skills, fn skill -> {skill.name, skill} end)
  end

  @doc """
  Find a skill by name in an index.
  """
  @spec find(%{String.t() => Skill.t()}, String.t()) :: Skill.t() | nil
  def find(skill_index, name) do
    Map.get(skill_index, name)
  end

  @doc """
  Find skills matching a pattern.

  The pattern can include wildcards (*).
  """
  @spec find_matching([Skill.t()], String.t()) :: [Skill.t()]
  def find_matching(skills, pattern) do
    regex =
      pattern
      |> String.replace("*", ".*")
      |> Regex.compile!()

    Enum.filter(skills, fn skill ->
      Regex.match?(regex, skill.name)
    end)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    paths = Keyword.get(opts, :paths, [])
    name = Keyword.fetch!(opts, :name)
    reload_interval = Keyword.get(opts, :reload_interval)
    use_ets = Keyword.get(opts, :use_ets, true)

    ets_table =
      if use_ets do
        :ets.new(name, [:set, :protected, read_concurrency: true])
      else
        nil
      end

    state = %__MODULE__{
      name: name,
      paths: paths,
      reload_interval: reload_interval,
      skills: [],
      index: %{},
      ets_table: ets_table
    }

    # Load initial skills
    state = do_reload(state)

    # Schedule auto-reload if configured
    if reload_interval do
      Process.send_after(self(), :auto_reload, reload_interval)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:list, _from, %{skills: skills} = state) do
    {:reply, skills, state}
  end

  def handle_call({:get, name}, _from, %{ets_table: nil, index: skill_index} = state) do
    {:reply, Map.get(skill_index, name), state}
  end

  def handle_call({:get, name}, _from, %{ets_table: table} = state) do
    result =
      case :ets.lookup(table, name) do
        [{^name, skill}] -> skill
        [] -> nil
      end

    {:reply, result, state}
  end

  def handle_call({:register, new_skills}, _from, state) do
    state = add_skills(state, new_skills)
    {:reply, :ok, state}
  end

  def handle_call(:reload, _from, state) do
    state = do_reload(state)
    {:reply, :ok, state}
  end

  def handle_call(:count, _from, %{skills: skills} = state) do
    {:reply, length(skills), state}
  end

  @impl true
  def handle_info(:auto_reload, %{reload_interval: interval} = state) do
    state = do_reload(state)

    if interval do
      Process.send_after(self(), :auto_reload, interval)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{ets_table: nil}), do: :ok

  def terminate(_reason, %{ets_table: table}) do
    :ets.delete(table)
    :ok
  end

  # Private functions

  defp do_reload(%{paths: paths} = state) do
    skills =
      paths
      |> Enum.flat_map(fn path ->
        case Loader.scan_and_load(path) do
          {:ok, skills} -> skills
          {:error, _} -> []
        end
      end)

    update_skills(state, skills)
  end

  defp add_skills(state, new_skills) do
    all_skills = state.skills ++ new_skills
    update_skills(state, all_skills)
  end

  defp update_skills(%{ets_table: nil} = state, skills) do
    %{state | skills: skills, index: index(skills)}
  end

  defp update_skills(%{ets_table: table} = state, skills) do
    :ets.delete_all_objects(table)

    Enum.each(skills, fn skill ->
      :ets.insert(table, {skill.name, skill})
    end)

    %{state | skills: skills, index: index(skills)}
  end
end
