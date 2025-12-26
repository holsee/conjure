# Timestamp Echo - Docker Execution

Examples demonstrating Docker-sandboxed skill execution with Conjure.

## Prerequisites

```bash
# Build the sandbox image
mix conjure.docker.build
```

## Usage

```bash
# Session API (recommended)
mix run examples/.scripts/timestamp-echo-docker/run_skill_session.exs
mix run examples/.scripts/timestamp-echo-docker/run_skill_session.exs "Hello!"

# Low-level executor API
mix run examples/.scripts/timestamp-echo-docker/run_skill.exs
```

## Scripts

| Script | Description |
|--------|-------------|
| `run_skill_session.exs` | Uses `Conjure.Session.chat/3` with Docker backend |
| `run_skill.exs` | Uses `Conjure.Executor.Docker` directly |

## Notes

- Docker execution runs commands in an isolated container
- Both examples use relative paths as documented in SKILL.md
- The skill is loaded from `examples/skills/timestamp-echo.skill`
- The executor handles path translation automatically
- `Session.new_docker/2` initializes storage; call `Session.cleanup/1` when done
