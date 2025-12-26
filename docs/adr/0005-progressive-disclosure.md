# ADR-0005: Progressive disclosure for token efficiency

## Status

Accepted

## Context

Claude models have context window limits (currently 200K tokens). System prompts consume tokens on every API call. When loading many skills, the full content of all skills could consume significant context:

- A skill's SKILL.md body may be 1,000-5,000 tokens
- Scripts and references add more
- Loading 20 skills with full content = 20,000-100,000+ tokens

However, in any given conversation, Claude typically uses 0-3 skills. Loading all skill content upfront wastes tokens.

Anthropic's Agent Skills specification addresses this with progressive disclosure:

1. **Level 1**: Metadata only (name + description) - ~50-100 tokens per skill
2. **Level 2**: Full SKILL.md body - loaded on demand
3. **Level 3**: Resources (scripts, references) - loaded on demand

## Decision

We will implement progressive disclosure with lazy loading semantics.

Initial load captures metadata only:

```elixir
{:ok, skills} = Conjure.load("/path/to/skills")

# Each skill has:
# - name, description, path (loaded)
# - body_loaded: false
# - body: nil
```

System prompt includes only metadata:

```xml
<skill>
  <name>pdf</name>
  <description>PDF manipulation toolkit...</description>
  <location>/path/to/skills/pdf/SKILL.md</location>
</skill>
```

Claude reads full content via the `view` tool when needed:

```elixir
# Claude calls: view(path: "/path/to/skills/pdf/SKILL.md")
# Executor returns full SKILL.md content
```

Conjure provides explicit loading for programmatic access:

```elixir
# Load body into struct (optional, for introspection)
{:ok, skill_with_body} = Conjure.load_body(skill)

# Read a resource file
{:ok, content} = Conjure.read_resource(skill, "scripts/helper.py")
```

## Consequences

### Positive

- Minimal token usage for skill discovery (~100 tokens per skill)
- Scales to large skill libraries without context exhaustion
- Claude decides which skills to fully load based on task
- Aligns with Anthropic's specification
- Reduces API costs (fewer input tokens)

### Negative

- Additional tool calls required to load skill content
- Slightly higher latency for skill usage (view call overhead)
- Claude may fail to load skill content in edge cases
- Debugging requires understanding lazy loading

### Neutral

- `body_loaded` flag tracks loading state
- Resources are always lazy-loaded (no bulk loading)
- Skill location must be a valid, accessible path

## Implementation Details

### Skill Struct

```elixir
defstruct [
  :name,
  :description,
  :path,
  :license,
  :compatibility,
  metadata: %{},
  body: nil,
  body_loaded: false,
  resources: %{scripts: [], references: [], assets: [], other: []}
]
```

### Loading Flow

```
Conjure.load("/skills")
    │
    ├── Scan for SKILL.md files
    │
    ├── For each SKILL.md:
    │   ├── Read file
    │   ├── Parse YAML frontmatter (name, description, etc.)
    │   ├── Store body separately (NOT in struct)
    │   ├── Scan resource directories
    │   └── Return Skill struct with body_loaded: false
    │
    └── Return list of Skill structs
```

### Token Budget Example

| Scenario | Skills | Tokens (Full Load) | Tokens (Progressive) |
|----------|--------|-------------------|---------------------|
| Small | 5 | 15,000 | 500 |
| Medium | 20 | 60,000 | 2,000 |
| Large | 50 | 150,000 | 5,000 |

## Alternatives Considered

### Always load full content

Simple but wasteful. Rejected because:

- Doesn't scale beyond a handful of skills
- Wastes tokens on unused skills
- May exceed context limits

### Hybrid loading with heuristics

Pre-load "likely needed" skills based on user query. Rejected because:

- Prediction is unreliable
- Adds complexity without guaranteed benefit
- Claude is better at determining relevance

### Streaming skill content

Return skill content in chunks. Rejected because:

- Over-engineered for text files
- Claude needs full context for instructions
- Complicates tool response handling

## References

- [Anthropic Agent Skills Specification](https://docs.anthropic.com/en/docs/agents-and-tools/agent-skills)
- [Claude Context Window](https://docs.anthropic.com/en/docs/about-claude/models)
