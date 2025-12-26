# Timestamp Echo - Anthropic Hosted Execution

Example demonstrating the Anthropic Skills API workflow with Conjure.

Unlike local/Docker/native execution, this example:
1. **Uploads** the skill to Anthropic (handled automatically by `Session.new_anthropic/2`)
2. **Anthropic's cloud** executes the skill (not your machine)
3. **Cleans up** uploaded skills automatically via `Session.cleanup/1`

## Prerequisites

1. Set the `ANTHROPIC_API_KEY` environment variable
2. Ensure Req HTTP client is available

```bash
mix deps.get
```

## Usage

```bash
ANTHROPIC_API_KEY=sk-... mix run examples/.scripts/timestamp-echo-api/run_skill_session.exs
ANTHROPIC_API_KEY=sk-... mix run examples/.scripts/timestamp-echo-api/run_skill_session.exs "Hello!"
```

## Simplified Workflow

```
┌─────────────────────────────────────────────────────────────┐
│  1. Load & Create Session (auto-uploads)                    │
│     {:ok, skill} = Conjure.Loader.load_skill_file(path)     │
│     {:ok, session} = Session.new_anthropic([skill],         │
│       api_callback: my_callback)                            │
├─────────────────────────────────────────────────────────────┤
│  2. Chat                                                    │
│     Session.chat(session, message, messages_callback)       │
│     → Claude uses skill, Anthropic executes it              │
├─────────────────────────────────────────────────────────────┤
│  3. Cleanup (auto-deletes uploaded skills)                  │
│     Session.cleanup(session)                                │
└─────────────────────────────────────────────────────────────┘
```

## Key Difference from Local/Docker

| Aspect | Local/Docker | Anthropic |
|--------|--------------|-----------|
| Execution | Your machine | Anthropic's cloud |
| Skill source | .skill file | Uploaded to Anthropic |
| Session | `new_local` / `new_docker` | `new_anthropic` |
| Skill input | `Skill.t()` | `Skill.t()` or `skill_spec` |
| Upload | N/A | Automatic on session create |
| Cleanup | N/A | Automatic skill deletion |

## API Callbacks

The example shows two different callback patterns:

```elixir
# For session creation (skill upload/management)
skill_callback = fn method, path, body, opts ->
  # HTTP client call to /v1/skills endpoints
end

# For chat/messages API
messages_callback = fn messages ->
  # Build request with Conjure.API.Anthropic.build_request
  # POST to /v1/messages
end
```

## Notes

- Skills are uploaded when creating the session
- `Session.cleanup/1` deletes all uploaded skills
- For production, consider uploading once and reusing `skill_id` with skill specs
- Handles `pause_turn` responses automatically via Session
