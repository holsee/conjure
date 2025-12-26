# ADR-0006: XML format for system prompt fragments

## Status

Accepted

## Context

Conjure generates a fragment to append to the user's system prompt, containing:

1. Available skills (name, description, location)
2. Instructions for skill usage
3. Tool discovery guidance

This content must be:

- Clearly delimited from other system prompt content
- Parseable by Claude for skill identification
- Human-readable for debugging
- Consistent with Claude's training and expectations

Claude models are trained to recognize and follow structured formats in prompts. The choice of format affects:

- How reliably Claude identifies and uses skills
- Token efficiency
- Maintainability and debugging

## Decision

We will use XML format for system prompt skill fragments.

```xml
<skills>
<skills_description>
Claude has access to a set of skills that extend its capabilities.
To use a skill, read its SKILL.md file using the view tool.
</skills_description>

<available_skills>
<skill>
<name>pdf</name>
<description>PDF manipulation toolkit for extraction, creation, and editing.</description>
<location>/path/to/skills/pdf/SKILL.md</location>
</skill>

<skill>
<name>docx</name>
<description>Word document processing with formatting preservation.</description>
<location>/path/to/skills/docx/SKILL.md</location>
</skill>
</available_skills>

<skill_usage_instructions>
When a task matches a skill's description:
1. Use the view tool to read the skill's SKILL.md file
2. Follow the instructions in the skill
3. Use additional resources as directed
</skill_usage_instructions>
</skills>
```

## Consequences

### Positive

- Claude reliably recognizes XML-structured content
- Clear semantic boundaries (`<skill>`, `<name>`, etc.)
- Consistent with Anthropic's own prompt engineering patterns
- Human-readable and debuggable
- Easy to parse programmatically if needed
- Self-documenting structure

### Negative

- Slightly more tokens than minimal formats (tags add overhead)
- XML escaping required for special characters in descriptions
- Verbose compared to JSON or YAML

### Neutral

- No schema validation (informal structure)
- Whitespace handling is lenient
- Nested content is rare (mostly leaf elements)

## Token Analysis

For a typical skill entry:

```xml
<skill>
<name>pdf</name>
<description>PDF manipulation toolkit for extracting text and tables, creating new PDFs, merging/splitting documents, and handling forms.</description>
<location>/path/to/skills/pdf/SKILL.md</location>
</skill>
```

- XML tags: ~20 tokens
- Content: ~40 tokens
- Total: ~60 tokens per skill

Wrapper and instructions: ~100 tokens fixed overhead

**Total for 10 skills**: ~700 tokens (acceptable)

## Alternatives Considered

### JSON format

```json
{"skills": [{"name": "pdf", "description": "..."}]}
```

Rejected because:

- Less natural for Claude to parse in prose context
- Quotes and escaping add visual noise
- Not self-describing (requires schema knowledge)

### YAML format

```yaml
skills:
  - name: pdf
    description: ...
```

Rejected because:

- Indentation-sensitive (fragile in prompts)
- Less common in Claude's training data for system prompts
- Harder to visually scan

### Markdown format

```markdown
## Available Skills

### pdf
PDF manipulation toolkit...
```

Rejected because:

- Ambiguous parsing (where does one skill end?)
- No clear semantic structure
- Conflicts with user's own markdown content

### Plain text with delimiters

```
--- SKILLS ---
pdf: PDF manipulation toolkit...
--- END SKILLS ---
```

Rejected because:

- No standard structure
- Hard to add metadata (location, etc.)
- Fragile delimiter matching

## Alignment with Anthropic Patterns

Anthropic's documentation and examples frequently use XML for structured prompt content:

- `<example>` tags for few-shot examples
- `<context>` for background information
- `<instructions>` for behavioral guidance

Using XML for skills aligns with these established patterns.

## References

- [Anthropic Prompt Engineering Guide](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering)
- [Claude's XML Understanding](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/use-xml-tags)
