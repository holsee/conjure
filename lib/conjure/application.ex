defmodule Conjure.Application do
  @moduledoc """
  OTP Application for Conjure.

  This module starts the Conjure supervision tree. The default configuration
  starts with no children - the Registry must be explicitly added to your
  application's supervision tree if needed.

  ## Usage with Registry

  To use the built-in Registry, add it to your application's supervisor:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {Conjure.Registry, name: MyApp.Skills, paths: ["/path/to/skills"]}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Configuration

  Configure Conjure in your config:

      config :conjure,
        skill_paths: ["/path/to/skills"],
        executor: Conjure.Executor.Docker,
        timeout: 30_000
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Conjure doesn't start any processes by default
      # Users add Conjure.Registry to their own supervision tree
    ]

    opts = [strategy: :one_for_one, name: Conjure.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Get configuration value.
  """
  @spec config(atom(), term()) :: term()
  def config(key, default \\ nil) do
    Application.get_env(:conjure, key, default)
  end

  @doc """
  Get the configured executor.
  """
  @spec executor() :: module()
  def executor do
    config(:executor, Conjure.Executor.Local)
  end

  @doc """
  Get the default timeout.
  """
  @spec timeout() :: pos_integer()
  def timeout do
    config(:timeout, 30_000)
  end

  @doc """
  Get configured skill paths.
  """
  @spec skill_paths() :: [Path.t()]
  def skill_paths do
    config(:skill_paths, [])
  end
end
