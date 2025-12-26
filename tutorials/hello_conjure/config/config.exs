import Config

config :hello_conjure,
  anthropic_api_key: System.get_env("CLAUDE_API_KEY")
