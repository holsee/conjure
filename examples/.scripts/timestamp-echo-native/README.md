# Timestamp Echo - Native Execution

Examples demonstrating native Elixir skill execution with Conjure.

Native skills run directly in the BEAM - no external processes, no Python, no Docker.

## Usage

```bash
mix run examples/.scripts/timestamp-echo-native/run_skill_session.exs
mix run examples/.scripts/timestamp-echo-native/run_skill_session.exs "Hello!"
```

## Files

| File | Description |
|------|-------------|
| `timestamp_echo.ex` | Native skill module implementing `Conjure.NativeSkill` |
| `run_skill_session.exs` | Example using `Conjure.Session.new_native/2` |

## Native Skill Pattern

```elixir
defmodule Examples.Skills.TimestampEcho do
  @behaviour Conjure.NativeSkill

  @impl true
  def __skill_info__ do
    %{
      name: "timestamp-echo",
      description: "Echo a message with the current timestamp",
      allowed_tools: [:execute]
    }
  end

  @impl true
  def execute(message, _context) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
    {:ok, "[#{timestamp}] #{message}"}
  end
end
```

## Advantages

- No subprocess overhead
- Type-safe with compile-time checks
- Direct access to application state (Ecto, caches, GenServers)
- Pattern matching for command handling
