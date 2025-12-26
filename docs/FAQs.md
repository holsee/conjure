# Frequently Asked Questions

This document captures common questions and answers about the Conjure project.

---

## How are skills selected to be used?

Conjure uses **Claude-driven selection** rather than programmatic matching. The selection flow works as follows:

1. **Loading**: Skills are scanned from the filesystem via `Conjure.Loader.scan_and_load/1`
2. **Discovery**: All skill metadata (name, description) is injected into the system prompt via `Conjure.Prompt.generate/2` in XML format
3. **Selection**: Claude reads the available skills and intelligently decides which to use based on the task
4. **Invocation**: Claude invokes tools by name in its response
5. **Dispatch**: `Conjure.Executor.execute/3` routes tool calls via pattern matching on tool name
6. **Execution**: The selected executor backend (Local or Docker) runs the tool

**Key files:**
- `lib/conjure/prompt.ex:34-58` - Generates available skills block for system prompt
- `lib/conjure/executor.ex:126-152` - Tool dispatch routing
- `lib/conjure/tools.ex:29-39` - Tool definitions with optional filtering

**Optional tool filtering:**
```elixir
# Only include specific tools
Conjure.Tools.definitions(only: ["view", "bash_tool"])

# Exclude specific tools
Conjure.Tools.definitions(except: ["create_file"])
```

---

