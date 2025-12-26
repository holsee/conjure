# Timestamp Echo - Local Execution

Examples demonstrating local skill execution with Conjure.

## Usage

```bash
# Session API (recommended)
mix run examples/.scripts/timestamp-echo-local/run_skill_session.exs
mix run examples/.scripts/timestamp-echo-local/run_skill_session.exs "Hello!"

# Low-level executor API
mix run examples/.scripts/timestamp-echo-local/run_skill.exs
```

## Scripts

| Script | Description |
|--------|-------------|
| `run_skill_session.exs` | Uses `Conjure.Session.chat/3` with automatic tool loop |
| `run_skill.exs` | Uses `Conjure.Executor.Local` directly |

## Notes

- Local execution runs commands directly on the host (no sandboxing)
- Both examples use relative paths as documented in SKILL.md
- The skill is loaded from `examples/skills/timestamp-echo.skill`
