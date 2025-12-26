defmodule HelloConjure.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello_conjure,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {HelloConjure.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:conjure, path: "../.."},
      {:req, "~> 0.4"}
    ]
  end
end
