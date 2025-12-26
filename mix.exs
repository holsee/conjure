defmodule Conjure.MixProject do
  use Mix.Project

  @version "0.1.0-alpha"
  @source_url "https://github.com/holsee/conjure"

  def project do
    [
      app: :conjure,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Hex
      description: "Elixir library for Anthropic Agent Skills with Claude models",
      package: package(),

      # Docs
      name: "Conjure",
      source_url: @source_url,
      docs: docs(),

      # Dialyzer
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Conjure.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # YAML parsing for SKILL.md frontmatter
      {:yaml_elixir, "~> 2.9"},

      # JSON encoding/decoding
      {:jason, "~> 1.4"},

      # Telemetry for observability
      {:telemetry, "~> 1.2"},

      # HTTP client for S3/Tigris storage (optional)
      {:req, "~> 0.5", optional: true},

      # Development and test dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Steven Holdsworth"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "conjure-alt.png",
      extras: [
        {"README.md", [filename: "readme"]},
        "LICENSE",
        "docs/getting-started.md": [title: "Getting Started Tutorial"],
        "conjure_specification.md": [title: "Technical Specification"],
        "docs/adr/README.md": [title: "Architecture Decision Records", filename: "adr-index"],
        "docs/adr/0001-adr-format.md": [title: "ADR-0001: ADR Format"],
        "docs/adr/0002-pluggable-executor-architecture.md": [
          title: "ADR-0002: Pluggable Executor"
        ],
        "docs/adr/0003-zip-format-for-skill-packages.md": [title: "ADR-0003: ZIP Skill Packages"],
        "docs/adr/0004-api-client-agnostic-design.md": [title: "ADR-0004: API-Client Agnostic"],
        "docs/adr/0005-progressive-disclosure.md": [title: "ADR-0005: Progressive Disclosure"],
        "docs/adr/0006-xml-system-prompt-format.md": [title: "ADR-0006: XML System Prompt"],
        "docs/adr/0007-yaml-frontmatter.md": [title: "ADR-0007: YAML Frontmatter"],
        "docs/adr/0008-genserver-registry.md": [title: "ADR-0008: GenServer Registry"],
        "docs/adr/0009-local-executor-no-sandbox.md": [title: "ADR-0009: Local Executor"],
        "docs/adr/0010-docker-production-executor.md": [title: "ADR-0010: Docker Executor"],
        "docs/adr/0011-anthropic-executor.md": [title: "ADR-0011: Anthropic Skills API"],
        "docs/adr/0012-mix-tasks.md": [title: "ADR-0012: Mix Tasks"],
        "docs/adr/0013-docker-infrastructure.md": [title: "ADR-0013: Docker Infrastructure"],
        "docs/adr/0014-security-module.md": [title: "ADR-0014: Security Module"],
        "docs/adr/0015-configuration-driven-loading.md": [
          title: "ADR-0015: Config-Driven Loading"
        ],
        "docs/adr/0016-test-strategy-external-deps.md": [title: "ADR-0016: Test Strategy"],
        "docs/adr/0017-skill-caching-hot-reload.md": [title: "ADR-0017: Caching & Hot-Reload"],
        "docs/adr/0018-artifact-references.md": [title: "ADR-0018: Artifact References"],
        "docs/adr/0019-unified-execution-model.md": [title: "ADR-0019: Unified Execution Model"],
        "docs/adr/0020-backend-behaviour.md": [title: "ADR-0020: Backend Behaviour"],
        "docs/adr/0021-hybrid-multi-backend-sessions.md": [
          title: "ADR-0021: Hybrid Multi-Backend Sessions"
        ],
        "docs/adr/0022-storage-strategy.md": [title: "ADR-0022: Storage Strategy"],
        "docs/tutorials/README.md": [title: "Tutorials", filename: "tutorials-index"],
        "docs/tutorials/hello_world.md": [title: "Tutorial: Hello World"],
        "docs/tutorials/using_local_skills_via_claude_api.md": [title: "Tutorial: Local Skills"],
        "docs/tutorials/using_claude_skill_with_elixir_host.md": [
          title: "Tutorial: Anthropic Skills API"
        ],
        "docs/tutorials/using_elixir_native_skill.md": [title: "Tutorial: Native Elixir Skills"],
        "docs/tutorials/many_skill_backends_one_agent.md": [title: "Tutorial: Unified Backends"],
        "docs/tutorials/hello_conjure_flyio.md": [title: "Tutorial: Fly.io with Tigris"]
      ],
      groups_for_extras: [
        Guides: [
          "docs/getting-started.md",
          "conjure_specification.md"
        ],
        Tutorials: ~r/docs\/tutorials\/.+/,
        "Architecture Decision Records": ~r/docs\/adr\/.+/
      ],
      groups_for_modules: [
        Core: [
          Conjure,
          Conjure.Skill,
          Conjure.Loader,
          Conjure.Registry
        ],
        "Prompt Generation": [
          Conjure.Prompt,
          Conjure.Tools
        ],
        Execution: [
          Conjure.Executor,
          Conjure.Executor.Local,
          Conjure.Executor.Docker
        ],
        Storage: [
          Conjure.Storage,
          Conjure.Storage.Local,
          Conjure.Storage.S3,
          Conjure.Storage.Tigris,
          Conjure.Storage.AwsSigV4
        ],
        Conversation: [
          Conjure.Conversation,
          Conjure.API
        ],
        "Data Structures": [
          Conjure.Frontmatter,
          Conjure.ToolCall,
          Conjure.ToolResult,
          Conjure.ExecutionContext
        ],
        Errors: [
          Conjure.Error
        ]
      ]
    ]
  end
end
