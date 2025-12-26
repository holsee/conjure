# Conjure Technical Specification

**Version:** 1.0.0-draft  
**Status:** Draft  
**Date:** December 2025

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Goals and Non-Goals](#2-goals-and-non-goals)
3. [Architecture Overview](#3-architecture-overview)
4. [Core Data Structures](#4-core-data-structures)
5. [Module Specifications](#5-module-specifications)
6. [Skill Loading and Discovery](#6-skill-loading-and-discovery)
7. [System Prompt Integration](#7-system-prompt-integration)
8. [Tool Definitions](#8-tool-definitions)
9. [Execution Environment](#9-execution-environment)
10. [Claude API Integration](#10-claude-api-integration)
11. [Conversation Loop](#11-conversation-loop)
12. [Error Handling](#12-error-handling)
13. [Configuration](#13-configuration)
14. [Testing Strategy](#14-testing-strategy)
15. [Security Considerations](#15-security-considerations)
16. [Dependencies](#16-dependencies)
17. [Example Usage](#17-example-usage)
18. [Appendices](#appendices)

---

## 1. Executive Summary

Conjure is an Elixir library that enables applications to leverage Anthropic Agent Skills with Claude models. It provides a complete implementation of the Agent Skills specification, allowing Elixir applications to:

- Load and parse skills from the filesystem
- Generate system prompt fragments for skill discovery
- Provide tool definitions compatible with Claude's tool use API
- Execute skill-related tool calls (file reads, script execution)
- Manage the conversation loop between Claude and tools

The library is designed to be **composable**, **pluggable**, and **API-client agnostic**, allowing integration with any Claude API client implementation.

---

## 2. Goals and Non-Goals

### 2.1 Goals

1. **Full Agent Skills Compatibility**: Support the complete Anthropic Agent Skills specification including:
   - SKILL.md parsing with YAML frontmatter
   - Progressive disclosure (metadata → body → resources)
   - Bundled resources (scripts/, references/, assets/)
   - .skill file packaging format (ZIP with .skill extension)

2. **Composability**: Provide discrete, composable components that can be used independently:
   - Skill loading without execution
   - Prompt generation without API integration
   - Execution without conversation management

3. **Pluggable Execution**: Support multiple execution backends:
   - Simple local execution (System.cmd)
   - Docker/Podman container isolation
   - Custom executor implementations
   - Optional: Anthropic Skills API integration (beta) for hosted execution

4. **API Client Agnostic**: Work with any Claude API client (official SDK, custom implementations, or third-party libraries)

5. **OTP Compliance**: Follow OTP design principles with proper supervision trees, GenServers where appropriate, and fault tolerance

6. **Developer Experience**: Provide clear APIs, comprehensive documentation, and helpful error messages

### 2.2 Non-Goals

1. **Full Claude API Client**: Conjure does not implement a Claude API client; it integrates with existing clients
2. **Skill Authoring Tools**: Creating/editing skills is out of scope (use Anthropic's skill-creator)
3. **GUI/Web Interface**: This is a library, not an application
4. **Multi-Model Support**: Initially focused on Claude; other models may be added later
5. **Skill Marketplace Integration**: Downloading skills from marketplaces is out of scope

---

## 3. Architecture Overview

### 3.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Application Layer                          │
│                   (Your Elixir Application)                     │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Conjure                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Loader    │  │   Prompt    │  │      Conversation       │  │
│  │             │  │  Generator  │  │        Manager          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
│         │                │                      │               │
│         ▼                ▼                      ▼               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │  Registry   │  │    Tools    │  │       Executor          │  │
│  │             │  │  Definitions│  │      (Behaviour)        │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
              ┌─────────┐             ┌─────────┐
              │  Local  │             │ Docker  │
              │Executor │             │Executor │
              └─────────┘             └─────────┘

Note: Anthropic Skills API (see Section 5.9) provides an alternative
hosted execution model but uses a different integration pattern.
```

### 3.2 Component Responsibilities

| Component | Responsibility |
|-----------|----------------|
| **Loader** | Parse SKILL.md files, extract frontmatter, load skill directories |
| **Registry** | Store and index loaded skills, provide lookup by name/trigger |
| **Prompt Generator** | Generate system prompt fragments for skill discovery |
| **Tools** | Define tool schemas compatible with Claude's tool use API |
| **Executor** | Execute tool calls (file reads, bash commands, scripts) |
| **Conversation Manager** | Orchestrate the tool-use loop between Claude and executors |

---

## 4. Core Data Structures

### 4.1 Skill Struct

```elixir
defmodule Conjure.Skill do
  @moduledoc """
  Represents a loaded Agent Skill.
  """

  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    path: Path.t(),
    license: String.t() | nil,
    compatibility: map() | nil,
    metadata: map(),
    body: String.t() | nil,
    body_loaded: boolean(),
    resources: resources()
  }

  @type resources :: %{
    scripts: [Path.t()],
    references: [Path.t()],
    assets: [Path.t()],
    other: [Path.t()]
  }

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
end
```

### 4.2 Skill Frontmatter

```elixir
defmodule Conjure.Frontmatter do
  @moduledoc """
  Parsed YAML frontmatter from SKILL.md
  """

  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    license: String.t() | nil,
    compatibility: map() | nil,
    allowed_tools: [String.t()] | nil,
    extra: map()
  }

  defstruct [
    :name,
    :description,
    :license,
    :compatibility,
    :allowed_tools,
    extra: %{}
  ]
end
```

### 4.3 Tool Call

```elixir
defmodule Conjure.ToolCall do
  @moduledoc """
  Represents a tool call from Claude's response.
  """

  @type t :: %__MODULE__{
    id: String.t(),
    name: String.t(),
    input: map()
  }

  defstruct [:id, :name, :input]
end
```

### 4.4 Tool Result

```elixir
defmodule Conjure.ToolResult do
  @moduledoc """
  Result of executing a tool call.
  """

  @type t :: %__MODULE__{
    tool_use_id: String.t(),
    type: :tool_result,
    content: content(),
    is_error: boolean()
  }

  @type content :: String.t() | [content_block()]
  @type content_block :: %{type: :text, text: String.t()} 
                       | %{type: :image, source: map()}

  defstruct [
    :tool_use_id,
    type: :tool_result,
    content: "",
    is_error: false
  ]
end
```

### 4.5 Execution Context

```elixir
defmodule Conjure.ExecutionContext do
  @moduledoc """
  Context passed to executors containing skill and environment information.
  """

  @type t :: %__MODULE__{
    skill: Conjure.Skill.t() | nil,
    skills_root: Path.t(),
    working_directory: Path.t(),
    environment: map(),
    timeout: pos_integer(),
    allowed_paths: [Path.t()],
    network_access: :none | :limited | :full
  }

  defstruct [
    :skill,
    :skills_root,
    working_directory: "/tmp/conjure",
    environment: %{},
    timeout: 30_000,
    allowed_paths: [],
    network_access: :none
  ]
end
```

---

## 5. Module Specifications

### 5.1 Conjure (Main API)

```elixir
defmodule Conjure do
  @moduledoc """
  Main entry point for the Conjure library.
  """

  @doc """
  Load skills from a directory path.
  Returns a list of parsed Skill structs with metadata only (body not loaded).
  """
  @spec load(Path.t()) :: {:ok, [Skill.t()]} | {:error, term()}
  def load(path)

  @doc """
  Load skills from multiple directories.
  """
  @spec load_all([Path.t()]) :: {:ok, [Skill.t()]} | {:error, term()}
  def load_all(paths)

  @doc """
  Load a single .skill file (ZIP format).
  """
  @spec load_skill_file(Path.t()) :: {:ok, Skill.t()} | {:error, term()}
  def load_skill_file(path)

  @doc """
  Generate the system prompt fragment for skill discovery.
  This should be appended to your system prompt.
  """
  @spec system_prompt([Skill.t()], keyword()) :: String.t()
  def system_prompt(skills, opts \\ [])

  @doc """
  Get tool definitions for the Claude API.
  """
  @spec tool_definitions(keyword()) :: [map()]
  def tool_definitions(opts \\ [])

  @doc """
  Execute a tool call and return the result.
  """
  @spec execute(ToolCall.t(), [Skill.t()], keyword()) :: 
    {:ok, ToolResult.t()} | {:error, term()}
  def execute(tool_call, skills, opts \\ [])

  @doc """
  Load the full body of a skill (for progressive disclosure).
  """
  @spec load_body(Skill.t()) :: {:ok, Skill.t()} | {:error, term()}
  def load_body(skill)

  @doc """
  Read a resource file from a skill.
  """
  @spec read_resource(Skill.t(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def read_resource(skill, relative_path)
end
```

### 5.2 Conjure.Loader

```elixir
defmodule Conjure.Loader do
  @moduledoc """
  Handles loading and parsing of skills from the filesystem.
  """

  @doc """
  Parse a SKILL.md file and return metadata (frontmatter only).
  """
  @spec parse_skill_md(Path.t()) :: {:ok, Skill.t()} | {:error, term()}
  def parse_skill_md(path)

  @doc """
  Parse YAML frontmatter from SKILL.md content.
  """
  @spec parse_frontmatter(String.t()) :: {:ok, Frontmatter.t(), String.t()} | {:error, term()}
  def parse_frontmatter(content)

  @doc """
  Scan a directory for skills (looks for SKILL.md files).
  """
  @spec scan_directory(Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def scan_directory(path)

  @doc """
  Load resources listing from a skill directory.
  """
  @spec load_resources(Path.t()) :: resources()
  def load_resources(skill_path)

  @doc """
  Extract a .skill file (ZIP) to a temporary directory.
  """
  @spec extract_skill_file(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def extract_skill_file(skill_file_path)

  @doc """
  Validate a skill's structure and metadata.
  """
  @spec validate(Skill.t()) :: :ok | {:error, [String.t()]}
  def validate(skill)
end
```

### 5.3 Conjure.Registry

```elixir
defmodule Conjure.Registry do
  @moduledoc """
  In-memory registry of loaded skills.
  Can be used as a GenServer for stateful applications or as pure functions.
  """

  use GenServer

  # Client API (Stateful)

  @doc """
  Start the registry as a GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ [])

  @doc """
  Register skills with the registry.
  """
  @spec register(GenServer.server(), [Skill.t()]) :: :ok
  def register(server \\ __MODULE__, skills)

  @doc """
  Get all registered skills.
  """
  @spec list(GenServer.server()) :: [Skill.t()]
  def list(server \\ __MODULE__)

  @doc """
  Find a skill by name.
  """
  @spec get(GenServer.server(), String.t()) :: Skill.t() | nil
  def get(server \\ __MODULE__, name)

  @doc """
  Reload skills from configured paths.
  """
  @spec reload(GenServer.server()) :: :ok | {:error, term()}
  def reload(server \\ __MODULE__)

  # Pure Functions (Stateless)

  @doc """
  Create an index from a list of skills.
  """
  @spec index([Skill.t()]) :: %{String.t() => Skill.t()}
  def index(skills)

  @doc """
  Find skill by name in an index.
  """
  @spec find(%{String.t() => Skill.t()}, String.t()) :: Skill.t() | nil
  def find(index, name)
end
```

### 5.4 Conjure.Prompt

```elixir
defmodule Conjure.Prompt do
  @moduledoc """
  Generates system prompt fragments for skill discovery.
  """

  @doc """
  Generate the <available_skills> XML block for the system prompt.
  """
  @spec available_skills_block([Skill.t()]) :: String.t()
  def available_skills_block(skills)

  @doc """
  Generate skill discovery instructions.
  """
  @spec discovery_instructions(keyword()) :: String.t()
  def discovery_instructions(opts \\ [])

  @doc """
  Generate the complete skills system prompt fragment.
  Combines available_skills_block with discovery_instructions.
  """
  @spec generate([Skill.t()], keyword()) :: String.t()
  def generate(skills, opts \\ [])

  @doc """
  Format a single skill for the available_skills block.
  """
  @spec format_skill(Skill.t()) :: String.t()
  def format_skill(skill)
end
```

### 5.5 Conjure.Tools

```elixir
defmodule Conjure.Tools do
  @moduledoc """
  Defines tool schemas for the Claude API.
  """

  @doc """
  Get all tool definitions for skills support.
  """
  @spec definitions(keyword()) :: [map()]
  def definitions(opts \\ [])

  @doc """
  The 'view' tool for reading files and directories.
  """
  @spec view_tool() :: map()
  def view_tool()

  @doc """
  The 'bash_tool' for executing bash commands.
  """
  @spec bash_tool() :: map()
  def bash_tool()

  @doc """
  The 'str_replace' tool for editing files.
  """
  @spec str_replace_tool() :: map()
  def str_replace_tool()

  @doc """
  The 'create_file' tool for creating new files.
  """
  @spec create_file_tool() :: map()
  def create_file_tool()

  @doc """
  Parse a tool_use block from Claude's response.
  """
  @spec parse_tool_use(map()) :: {:ok, ToolCall.t()} | {:error, term()}
  def parse_tool_use(tool_use_block)
end
```

### 5.6 Conjure.Executor (Behaviour)

```elixir
defmodule Conjure.Executor do
  @moduledoc """
  Behaviour for tool execution backends.
  """

  @type result :: {:ok, String.t()} | {:ok, String.t(), [file_output()]} | {:error, term()}
  @type file_output :: %{path: Path.t(), content: binary()}

  @doc """
  Execute a bash command.
  """
  @callback bash(command :: String.t(), context :: ExecutionContext.t()) :: result()

  @doc """
  Read a file or directory listing.
  """
  @callback view(path :: Path.t(), context :: ExecutionContext.t(), opts :: keyword()) :: result()

  @doc """
  Create a new file with content.
  """
  @callback create_file(path :: Path.t(), content :: String.t(), context :: ExecutionContext.t()) :: result()

  @doc """
  Replace a string in a file.
  """
  @callback str_replace(path :: Path.t(), old_str :: String.t(), new_str :: String.t(), context :: ExecutionContext.t()) :: result()

  @doc """
  Initialize the execution environment (called once per session).
  """
  @callback init(context :: ExecutionContext.t()) :: {:ok, ExecutionContext.t()} | {:error, term()}

  @doc """
  Cleanup the execution environment.
  """
  @callback cleanup(context :: ExecutionContext.t()) :: :ok

  @optional_callbacks [init: 1, cleanup: 1]
end
```

### 5.7 Conjure.Executor.Local

```elixir
defmodule Conjure.Executor.Local do
  @moduledoc """
  Local execution backend using System.cmd.
  WARNING: No sandboxing. Use only in trusted environments.
  """

  @behaviour Conjure.Executor

  @impl true
  def bash(command, context)

  @impl true
  def view(path, context, opts \\ [])

  @impl true
  def create_file(path, content, context)

  @impl true
  def str_replace(path, old_str, new_str, context)

  @impl true
  def init(context)

  @impl true
  def cleanup(context)
end
```

### 5.8 Conjure.Executor.Docker

```elixir
defmodule Conjure.Executor.Docker do
  @moduledoc """
  Docker-based sandboxed execution backend.
  """

  @behaviour Conjure.Executor

  @type docker_opts :: [
    image: String.t(),
    memory_limit: String.t(),
    cpu_limit: String.t(),
    network: :none | :bridge | :host,
    volumes: [{Path.t(), Path.t(), :ro | :rw}],
    user: String.t()
  ]

  @default_image "conjure/sandbox:latest"

  @impl true
  def bash(command, context)

  @impl true
  def view(path, context, opts \\ [])

  @impl true
  def create_file(path, content, context)

  @impl true
  def str_replace(path, old_str, new_str, context)

  @impl true
  def init(context)

  @impl true
  def cleanup(context)

  @doc """
  Build the default sandbox Docker image.
  """
  @spec build_image(keyword()) :: :ok | {:error, term()}
  def build_image(opts \\ [])

  @doc """
  Check if Docker is available and the image exists.
  """
  @spec check_environment() :: :ok | {:error, term()}
  def check_environment()
end
```

### 5.9 Anthropic Skills API Integration (Optional)

> **Note:** This is NOT an executor implementation. Anthropic's Skills API uses a different integration pattern where skills are uploaded to Anthropic and executed in their managed containers. See [ADR-0011](docs/adr/0011-anthropic-executor.md) for full details.

```elixir
defmodule Conjure.Skills.Anthropic do
  @moduledoc """
  Upload and manage skills via Anthropic Skills API (beta).

  This module provides helpers for interacting with Anthropic's
  Skills API. Skills uploaded here are executed by Anthropic's
  infrastructure, not by Conjure executors.

  Requires beta headers: code-execution-2025-08-25, skills-2025-10-02
  """

  @doc """
  Upload a skill directory to Anthropic.
  Returns the skill_id for use in API requests.
  """
  @spec upload(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def upload(skill_path, opts \\ [])

  @doc """
  List skills available in your Anthropic workspace.
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ [])

  @doc """
  Delete a custom skill from Anthropic.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(skill_id, opts \\ [])

  @doc """
  Create a new version of an existing skill.
  """
  @spec create_version(String.t(), Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_version(skill_id, skill_path, opts \\ [])
end

defmodule Conjure.API.Anthropic do
  @moduledoc """
  Helpers for building Anthropic API requests with Skills.
  """

  @type skill_spec ::
    {:anthropic, String.t(), String.t()} |
    {:custom, String.t(), String.t()}

  @doc """
  Build the container parameter for skills (up to 8 skills per request).
  """
  @spec container_config([skill_spec()]) :: map()
  def container_config(skills)

  @doc """
  Get the required beta headers for Skills API.
  """
  @spec beta_headers() :: [{String.t(), String.t()}]
  def beta_headers()

  @doc """
  Get the code execution tool definition.
  """
  @spec code_execution_tool() :: map()
  def code_execution_tool()
end

defmodule Conjure.Conversation.Anthropic do
  @moduledoc """
  Conversation loop for Anthropic Skills API with pause_turn handling.

  Unlike local/Docker execution, Anthropic executes code in their container.
  However, long-running operations return pause_turn and require continuation.
  """

  @doc """
  Run a conversation with Anthropic-hosted skills, handling pause_turn.
  """
  @spec run(list(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(messages, container_config, opts \\ [])
end

defmodule Conjure.Session.Anthropic do
  @moduledoc """
  Manage multi-turn sessions with Anthropic Skills API.
  Preserves container ID across messages for stateful conversations.
  """

  defstruct [:container_id, :skills, :messages]

  @spec new([Conjure.API.Anthropic.skill_spec()]) :: t()
  def new(skills)

  @spec chat(t(), String.t(), keyword()) :: {:ok, map(), t()} | {:error, term()}
  def chat(session, user_message, opts \\ [])
end

defmodule Conjure.Files.Anthropic do
  @moduledoc """
  Download files created by Anthropic Skills via the Files API.
  """

  @spec extract_file_ids(map()) :: [String.t()]
  def extract_file_ids(response)

  @spec download(String.t(), keyword()) :: {:ok, binary(), String.t()} | {:error, term()}
  def download(file_id, opts \\ [])

  @spec metadata(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def metadata(file_id, opts \\ [])
end
```

### 5.10 Conjure.Conversation

```elixir
defmodule Conjure.Conversation do
  @moduledoc """
  Manages the tool-use conversation loop.
  """

  @type message :: %{role: String.t(), content: term()}
  @type api_response :: %{content: [content_block()], stop_reason: String.t()}
  @type content_block :: map()

  @doc """
  Process Claude's response, executing any tool calls.
  Returns tool results to be sent back to Claude.
  """
  @spec process_response(api_response(), [Skill.t()], keyword()) ::
    {:continue, [ToolResult.t()]} | {:done, String.t()} | {:error, term()}
  def process_response(response, skills, opts \\ [])

  @doc """
  Extract tool_use blocks from Claude's response.
  """
  @spec extract_tool_uses(api_response()) :: [ToolCall.t()]
  def extract_tool_uses(response)

  @doc """
  Execute multiple tool calls in parallel.
  """
  @spec execute_tool_calls([ToolCall.t()], [Skill.t()], keyword()) :: [ToolResult.t()]
  def execute_tool_calls(tool_calls, skills, opts \\ [])

  @doc """
  Format tool results for sending back to Claude.
  """
  @spec format_tool_results([ToolResult.t()]) :: [message()]
  def format_tool_results(results)

  @doc """
  Check if the response indicates conversation is complete.
  """
  @spec conversation_complete?(api_response()) :: boolean()
  def conversation_complete?(response)

  @doc """
  Run a complete conversation loop until completion or max iterations.
  Requires a callback function to call the Claude API.
  """
  @spec run_loop(
    messages :: [message()],
    skills :: [Skill.t()],
    api_callback :: (([message()]) -> {:ok, api_response()} | {:error, term()}),
    opts :: keyword()
  ) :: {:ok, [message()]} | {:error, term()}
  def run_loop(messages, skills, api_callback, opts \\ [])
end
```

---

## 6. Skill Loading and Discovery

### 6.1 Loading Process

```
┌─────────────────────────────────────────────────────────────┐
│                      Skill Loading Flow                     │
└─────────────────────────────────────────────────────────────┘

1. Scan Directory
   ├── Find all SKILL.md files
   ├── Find all .skill files
   └── Return list of paths

2. For each skill path:
   ├── Read SKILL.md file
   ├── Parse YAML frontmatter
   │   ├── Extract: name, description (required)
   │   └── Extract: license, compatibility, allowed_tools (optional)
   ├── Store body separately (not loaded into memory yet)
   ├── Scan for resources
   │   ├── scripts/
   │   ├── references/
   │   ├── assets/
   │   └── other files
   └── Create Skill struct

3. Validate each skill
   ├── Required fields present
   ├── Name format valid
   └── Path exists

4. Return list of Skill structs
```

### 6.2 Frontmatter Parsing

The YAML frontmatter is delimited by `---` markers:

```yaml
---
name: my-skill
description: A description of what this skill does and when to use it.
license: MIT
compatibility:
  products: [claude.ai, claude-code, api]
  packages: [python3, nodejs]
allowed_tools: [bash, view, create_file]
---
```

**Required fields:**
- `name`: String, lowercase alphanumeric with hyphens
- `description`: String, comprehensive description including triggers

**Optional fields:**
- `license`: String, license identifier or reference
- `compatibility`: Map of environment requirements
- `allowed_tools`: List of tools this skill can use

### 6.3 .skill File Format

A `.skill` file is a ZIP archive containing the skill directory:

```
my-skill.skill (ZIP)
├── SKILL.md
├── scripts/
│   └── helper.py
├── references/
│   └── api_docs.md
└── assets/
    └── template.xlsx
```

Extraction process:
1. Validate ZIP file integrity
2. Extract to temporary directory
3. Locate SKILL.md in root
4. Parse as normal skill directory
5. Clean up on completion (or keep if caching enabled)

---

## 7. System Prompt Integration

### 7.1 Prompt Structure

The generated system prompt fragment follows this structure:

```xml
<skills>
<skills_description>
Claude has access to a set of skills that extend its capabilities for specialized tasks.
Skills are loaded automatically when relevant to the task at hand.
To use a skill, Claude should first read the SKILL.md file using the view tool.
</skills_description>

<available_skills>
<skill>
<name>pdf</name>
<description>Comprehensive PDF manipulation toolkit for extracting text and tables, creating new PDFs, merging/splitting documents, and handling forms. When Claude needs to fill in a PDF form or programmatically process, generate, or analyze PDF documents at scale.</description>
<location>/path/to/skills/pdf/SKILL.md</location>
</skill>

<skill>
<name>docx</name>
<description>Comprehensive document creation, editing, and analysis with support for tracked changes, comments, formatting preservation, and text extraction. When Claude needs to work with professional documents (.docx files).</description>
<location>/path/to/skills/docx/SKILL.md</location>
</skill>
</available_skills>

<skill_usage_instructions>
When a task matches a skill's description:
1. Use the view tool to read the skill's SKILL.md file
2. Follow the instructions in the skill
3. Use additional resources (scripts/, references/) as directed by the skill
</skill_usage_instructions>
</skills>
```

### 7.2 Token Efficiency

The prompt is designed for token efficiency:
- Only name, description, and location are included per skill
- Full instructions are loaded on-demand via progressive disclosure
- Typical overhead: ~100 tokens per skill

---

## 8. Tool Definitions

### 8.1 View Tool

```json
{
  "name": "view",
  "description": "View file contents or directory listings. Supports text files, images (base64), and directories (up to 2 levels deep).",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Absolute path to file or directory"
      },
      "view_range": {
        "type": "array",
        "items": {"type": "integer"},
        "minItems": 2,
        "maxItems": 2,
        "description": "Optional [start_line, end_line] for text files. Use -1 for end_line to read to end."
      }
    },
    "required": ["path"]
  }
}
```

### 8.2 Bash Tool

```json
{
  "name": "bash_tool",
  "description": "Execute a bash command in the container environment.",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "description": "The bash command to execute"
      },
      "description": {
        "type": "string",
        "description": "Why this command is being run"
      }
    },
    "required": ["command", "description"]
  }
}
```

### 8.3 Create File Tool

```json
{
  "name": "create_file",
  "description": "Create a new file with the specified content.",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Path where the file should be created"
      },
      "file_text": {
        "type": "string",
        "description": "Content to write to the file"
      },
      "description": {
        "type": "string",
        "description": "Why this file is being created"
      }
    },
    "required": ["path", "file_text", "description"]
  }
}
```

### 8.4 String Replace Tool

```json
{
  "name": "str_replace",
  "description": "Replace a unique string in a file with another string.",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Path to the file to edit"
      },
      "old_str": {
        "type": "string",
        "description": "String to replace (must be unique in file)"
      },
      "new_str": {
        "type": "string",
        "description": "Replacement string"
      },
      "description": {
        "type": "string",
        "description": "Why this edit is being made"
      }
    },
    "required": ["path", "old_str", "description"]
  }
}
```

---

## 9. Execution Environment

### 9.1 Local Executor

The local executor runs commands directly on the host system:

```elixir
defmodule Conjure.Executor.Local do
  @behaviour Conjure.Executor

  @impl true
  def bash(command, %ExecutionContext{} = ctx) do
    opts = [
      cd: ctx.working_directory,
      env: Map.to_list(ctx.environment),
      stderr_to_stdout: true
    ]

    case System.cmd("bash", ["-c", command], opts) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:exit_code, code, output}}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  @impl true
  def view(path, ctx, opts) do
    full_path = resolve_path(path, ctx)
    
    cond do
      File.dir?(full_path) -> list_directory(full_path, opts)
      File.regular?(full_path) -> read_file(full_path, opts)
      true -> {:error, :not_found}
    end
  end
  
  # ... other implementations
end
```

**Security Warning**: The local executor provides NO sandboxing. Use only for trusted skills in controlled environments.

### 9.2 Docker Executor

The Docker executor runs commands in an isolated container:

```elixir
defmodule Conjure.Executor.Docker do
  @behaviour Conjure.Executor
  
  @default_image "conjure/sandbox:latest"

  defstruct [
    :container_id,
    :image,
    :volumes,
    :network,
    :memory_limit,
    :cpu_limit
  ]

  @impl true
  def init(%ExecutionContext{} = ctx) do
    config = ctx.executor_config || %{}
    
    volumes = [
      {ctx.skills_root, "/mnt/skills", :ro},
      {ctx.working_directory, "/workspace", :rw}
    ]
    
    args = build_docker_args(config, volumes)
    
    case System.cmd("docker", ["run", "-d" | args]) do
      {container_id, 0} ->
        {:ok, %{ctx | container_id: String.trim(container_id)}}
      {error, _} ->
        {:error, {:docker_start_failed, error}}
    end
  end

  @impl true
  def bash(command, ctx) do
    args = ["exec", ctx.container_id, "bash", "-c", command]
    
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:exit_code, code, output}}
    end
  end

  @impl true
  def cleanup(ctx) do
    System.cmd("docker", ["rm", "-f", ctx.container_id])
    :ok
  end
  
  # ... other implementations
end
```

### 9.3 Docker Image Specification

The default sandbox image (`conjure/sandbox`) should include:

```dockerfile
FROM ubuntu:24.04

# System packages
RUN apt-get update && apt-get install -y \
    python3.12 python3-pip python3-venv \
    nodejs npm \
    bash git curl wget jq \
    poppler-utils qpdf \
    && rm -rf /var/lib/apt/lists/*

# Python packages (matching Anthropic's environment)
RUN pip3 install --break-system-packages \
    pyarrow openpyxl xlsxwriter xlrd pillow \
    python-pptx python-docx pypdf pdfplumber \
    pypdfium2 pdf2image pdfkit tabula-py \
    reportlab img2pdf pandas numpy matplotlib \
    pyyaml requests beautifulsoup4

# Non-root user
RUN useradd -m -s /bin/bash -u 1000 sandbox
USER sandbox
WORKDIR /workspace

# Default environment
ENV PYTHONUNBUFFERED=1
ENV NODE_ENV=production
```

### 9.4 Execution Context Initialization

```elixir
def create_context(skills, opts \\ []) do
  %ExecutionContext{
    skills_root: Keyword.get(opts, :skills_root, "/tmp/conjure/skills"),
    working_directory: Keyword.get(opts, :working_dir, "/tmp/conjure/work"),
    environment: Keyword.get(opts, :env, %{}),
    timeout: Keyword.get(opts, :timeout, 30_000),
    allowed_paths: compute_allowed_paths(skills, opts),
    network_access: Keyword.get(opts, :network, :none),
    executor_config: Keyword.get(opts, :executor_config, %{})
  }
end
```

---

## 10. Claude API Integration

### 10.1 API Client Interface

Conjure does not implement an API client but provides helpers for integration:

```elixir
defmodule Conjure.API do
  @moduledoc """
  Helpers for Claude API integration.
  """

  @doc """
  Build the tools array for the API request.
  """
  @spec build_tools_param([Skill.t()], keyword()) :: [map()]
  def build_tools_param(skills, opts \\ [])

  @doc """
  Build the system prompt with skills fragment.
  """
  @spec build_system_prompt(String.t(), [Skill.t()], keyword()) :: String.t()
  def build_system_prompt(base_prompt, skills, opts \\ [])

  @doc """
  Parse content blocks from API response.
  """
  @spec parse_response(map()) :: {:ok, parsed_response()} | {:error, term()}
  def parse_response(api_response)

  @type parsed_response :: %{
    text_blocks: [String.t()],
    tool_uses: [ToolCall.t()],
    stop_reason: String.t()
  }

  @doc """
  Format tool results for the next API request.
  """
  @spec format_tool_results_message([ToolResult.t()]) :: map()
  def format_tool_results_message(results)
end
```

### 10.2 Example Integration with HTTPoison

```elixir
defmodule MyApp.Claude do
  @api_url "https://api.anthropic.com/v1/messages"
  
  def chat_with_skills(user_message, skills) do
    system_prompt = Conjure.API.build_system_prompt(
      "You are a helpful assistant.",
      skills
    )
    
    tools = Conjure.API.build_tools_param(skills)
    
    messages = [%{role: "user", content: user_message}]
    
    Conjure.Conversation.run_loop(
      messages,
      skills,
      &call_api(&1, system_prompt, tools),
      max_iterations: 10
    )
  end
  
  defp call_api(messages, system_prompt, tools) do
    body = %{
      model: "claude-sonnet-4-5-20250929",
      max_tokens: 4096,
      system: system_prompt,
      messages: messages,
      tools: tools
    }
    
    headers = [
      {"x-api-key", api_key()},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
    
    case HTTPoison.post(@api_url, Jason.encode!(body), headers) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)}
      {:ok, %{status_code: code, body: body}} ->
        {:error, {:api_error, code, body}}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

---

## 11. Conversation Loop

### 11.1 Loop Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Conversation Loop                         │
└─────────────────────────────────────────────────────────────┘

┌──────────────────┐
│  User Message    │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Call Claude API │◄────────────────────────────┐
└────────┬─────────┘                             │
         │                                        │
         ▼                                        │
┌──────────────────┐                             │
│ Parse Response   │                             │
└────────┬─────────┘                             │
         │                                        │
         ▼                                        │
    ┌────────────┐     Yes    ┌──────────────┐   │
    │ Tool Uses? │──────────► │ Execute Tools│   │
    └────────────┘            └──────┬───────┘   │
         │ No                        │           │
         ▼                           ▼           │
┌──────────────────┐        ┌──────────────────┐ │
│  Return Final    │        │ Format Results   │ │
│    Response      │        │ Add to Messages  │─┘
└──────────────────┘        └──────────────────┘
```

### 11.2 Implementation

```elixir
defmodule Conjure.Conversation do
  @default_max_iterations 25
  
  def run_loop(messages, skills, api_callback, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    executor = Keyword.get(opts, :executor, Conjure.Executor.Local)
    
    context = Conjure.create_context(skills, opts)
    
    do_loop(messages, skills, api_callback, executor, context, 0, max_iterations)
  end
  
  defp do_loop(messages, skills, api_callback, executor, ctx, iteration, max) 
       when iteration >= max do
    {:error, :max_iterations_reached}
  end
  
  defp do_loop(messages, skills, api_callback, executor, ctx, iteration, max) do
    case api_callback.(messages) do
      {:ok, response} ->
        case process_response(response, skills, executor: executor, context: ctx) do
          {:done, final_text} ->
            {:ok, messages ++ [%{role: "assistant", content: final_text}]}
          
          {:continue, tool_results} ->
            # Add assistant message with tool_use blocks
            assistant_msg = %{role: "assistant", content: response["content"]}
            # Add user message with tool_result blocks
            user_msg = format_tool_results_message(tool_results)
            
            new_messages = messages ++ [assistant_msg, user_msg]
            do_loop(new_messages, skills, api_callback, executor, ctx, iteration + 1, max)
          
          {:error, reason} ->
            {:error, reason}
        end
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  def process_response(response, skills, opts) do
    tool_uses = extract_tool_uses(response)
    
    if Enum.empty?(tool_uses) do
      text = extract_text(response)
      {:done, text}
    else
      executor = Keyword.get(opts, :executor, Conjure.Executor.Local)
      context = Keyword.get(opts, :context, %ExecutionContext{})
      
      results = execute_tool_calls(tool_uses, skills, executor, context)
      {:continue, results}
    end
  end
  
  def extract_tool_uses(%{"content" => content}) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(&parse_tool_use/1)
  end
  
  defp parse_tool_use(%{"id" => id, "name" => name, "input" => input}) do
    %ToolCall{id: id, name: name, input: input}
  end
  
  def execute_tool_calls(tool_calls, skills, executor, context) do
    # Execute in parallel with Task.async_stream
    tool_calls
    |> Task.async_stream(
      fn call -> execute_single(call, skills, executor, context) end,
      timeout: context.timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> %ToolResult{is_error: true, content: "Execution timeout"}
    end)
  end
  
  defp execute_single(%ToolCall{} = call, skills, executor, context) do
    result = case call.name do
      "view" -> 
        executor.view(call.input["path"], context, call.input)
      "bash_tool" -> 
        executor.bash(call.input["command"], context)
      "create_file" -> 
        executor.create_file(call.input["path"], call.input["file_text"], context)
      "str_replace" -> 
        executor.str_replace(
          call.input["path"], 
          call.input["old_str"], 
          call.input["new_str"] || "",
          context
        )
      _ -> 
        {:error, {:unknown_tool, call.name}}
    end
    
    case result do
      {:ok, output} ->
        %ToolResult{tool_use_id: call.id, content: output, is_error: false}
      {:error, reason} ->
        %ToolResult{tool_use_id: call.id, content: inspect(reason), is_error: true}
    end
  end
end
```

---

## 12. Error Handling

### 12.1 Error Types

```elixir
defmodule Conjure.Error do
  @moduledoc """
  Error types for Conjure operations.
  """

  defexception [:type, :message, :details]

  @type t :: %__MODULE__{
    type: error_type(),
    message: String.t(),
    details: term()
  }

  @type error_type ::
    :skill_not_found
    | :invalid_frontmatter
    | :invalid_skill_structure
    | :file_not_found
    | :permission_denied
    | :execution_failed
    | :execution_timeout
    | :docker_unavailable
    | :container_error
    | :api_error
    | :max_iterations_reached

  def skill_not_found(name) do
    %__MODULE__{
      type: :skill_not_found,
      message: "Skill '#{name}' not found",
      details: %{name: name}
    }
  end

  def invalid_frontmatter(path, reason) do
    %__MODULE__{
      type: :invalid_frontmatter,
      message: "Invalid YAML frontmatter in #{path}: #{inspect(reason)}",
      details: %{path: path, reason: reason}
    }
  end

  def execution_failed(command, exit_code, output) do
    %__MODULE__{
      type: :execution_failed,
      message: "Command failed with exit code #{exit_code}",
      details: %{command: command, exit_code: exit_code, output: output}
    }
  end

  # ... additional error constructors
end
```

### 12.2 Error Handling Strategy

1. **Loading Errors**: Return `{:error, reason}` tuples; log warnings for recoverable issues
2. **Execution Errors**: Capture and return as `ToolResult` with `is_error: true`
3. **API Errors**: Propagate to caller for handling
4. **Timeout Errors**: Kill task, return error result to Claude

---

## 13. Configuration

### 13.1 Application Configuration

```elixir
# config/config.exs
config :conjure,
  # Default paths to load skills from
  skill_paths: [
    "/path/to/skills",
    "~/.conjure/skills"
  ],
  
  # Default executor
  executor: Conjure.Executor.Local,
  
  # Executor-specific config
  executor_config: %{
    # Docker executor options
    docker: %{
      image: "conjure/sandbox:latest",
      memory_limit: "512m",
      cpu_limit: "1.0",
      network: :none
    }
  },
  
  # Execution defaults
  timeout: 30_000,
  max_iterations: 25,
  
  # Security
  allow_network: false,
  allowed_paths: []
```

### 13.2 Runtime Configuration

```elixir
# Override at runtime
Conjure.load("/custom/path", executor: Conjure.Executor.Docker)

# Create custom context
context = Conjure.create_context(skills,
  working_dir: "/tmp/my-project",
  timeout: 60_000,
  env: %{"API_KEY" => "..."}
)
```

---

## 14. Testing Strategy

### 14.1 Unit Tests

```elixir
defmodule Conjure.LoaderTest do
  use ExUnit.Case
  
  describe "parse_frontmatter/1" do
    test "parses valid frontmatter" do
      content = """
      ---
      name: test-skill
      description: A test skill
      ---
      # Body content
      """
      
      assert {:ok, frontmatter, body} = Conjure.Loader.parse_frontmatter(content)
      assert frontmatter.name == "test-skill"
      assert frontmatter.description == "A test skill"
      assert body =~ "# Body content"
    end
    
    test "returns error for missing required fields" do
      content = """
      ---
      name: test-skill
      ---
      """
      
      assert {:error, {:missing_field, :description}} = 
        Conjure.Loader.parse_frontmatter(content)
    end
  end
end
```

### 14.2 Integration Tests

```elixir
defmodule Conjure.IntegrationTest do
  use ExUnit.Case
  
  @test_skills_path "test/fixtures/skills"
  
  setup do
    {:ok, skills} = Conjure.load(@test_skills_path)
    {:ok, skills: skills}
  end
  
  test "complete conversation flow", %{skills: skills} do
    # Mock API callback
    api_callback = fn messages ->
      # Return mock response based on messages
      {:ok, mock_response(messages)}
    end
    
    messages = [%{role: "user", content: "Read the test skill"}]
    
    assert {:ok, final_messages} = 
      Conjure.Conversation.run_loop(messages, skills, api_callback)
  end
end
```

### 14.3 Test Fixtures

```
test/fixtures/skills/
├── test-skill/
│   ├── SKILL.md
│   ├── scripts/
│   │   └── helper.py
│   └── references/
│       └── docs.md
└── minimal-skill/
    └── SKILL.md
```

---

## 15. Security Considerations

### 15.1 Threat Model

| Threat | Mitigation |
|--------|------------|
| Malicious skill code | Docker isolation, path restrictions |
| File system escape | Whitelist allowed paths, container volumes |
| Network exfiltration | Default network disabled, allowlist for limited access |
| Resource exhaustion | Memory/CPU limits, timeouts |
| Command injection | Input sanitization, avoid shell interpolation |
| Prompt injection via skill | Skills loaded from trusted sources only |

### 15.2 Security Recommendations

1. **Always use Docker executor in production** - Local executor is for development only
2. **Audit skills before loading** - Review SKILL.md and all bundled scripts
3. **Restrict network access** - Default to `:none`, use `:limited` with allowlist
4. **Set resource limits** - Configure memory, CPU, and timeout limits
5. **Use read-only skill mounts** - Skills directory mounted as read-only
6. **Separate working directory** - Per-session working directories
7. **Log all executions** - Audit trail for compliance

### 15.3 Path Validation

```elixir
defmodule Conjure.Security do
  @doc """
  Validate that a path is within allowed boundaries.
  """
  def validate_path(path, allowed_paths) do
    normalized = Path.expand(path)
    
    if Enum.any?(allowed_paths, &path_under?(&1, normalized)) do
      {:ok, normalized}
    else
      {:error, :path_not_allowed}
    end
  end
  
  defp path_under?(base, path) do
    normalized_base = Path.expand(base)
    String.starts_with?(path, normalized_base)
  end
end
```

---

## 16. Dependencies

### 16.1 Required Dependencies

```elixir
# mix.exs
defp deps do
  [
    # YAML parsing
    {:yaml_elixir, "~> 2.9"},
    
    # JSON encoding (likely already present)
    {:jason, "~> 1.4"},
    
    # ZIP file handling for .skill files
    # (using Erlang's :zip module, no external dep needed)
  ]
end
```

### 16.2 Optional Dependencies

```elixir
defp deps do
  [
    # For Docker executor health checks
    {:briefly, "~> 0.5", optional: true},
    
    # For advanced file type detection
    {:file_info, "~> 0.0.4", optional: true},
    
    # For telemetry/metrics
    {:telemetry, "~> 1.2", optional: true}
  ]
end
```

### 16.3 System Requirements

**For Local Executor:**
- Erlang/OTP 25+
- Elixir 1.14+

**For Docker Executor:**
- Docker 20.10+ or Podman 4.0+
- Docker socket accessible

**For Anthropic Skills API (Optional, Beta):**
- Network access to Anthropic API
- Valid API key with Skills API access
- Beta headers enabled: `code-execution-2025-08-25`, `skills-2025-10-02`

---

## 17. Example Usage

### 17.1 Basic Usage

```elixir
# Load skills
{:ok, skills} = Conjure.load("/path/to/skills")

# Generate system prompt
system_prompt = """
You are a helpful assistant.

#{Conjure.system_prompt(skills)}
"""

# Get tool definitions
tools = Conjure.tool_definitions()

# Make API call (using your preferred client)
response = MyApp.Claude.call(system_prompt, user_message, tools)

# Process response and execute tools
case Conjure.Conversation.process_response(response, skills) do
  {:done, text} ->
    IO.puts(text)
  
  {:continue, tool_results} ->
    # Send results back to Claude
    next_response = MyApp.Claude.continue(tool_results)
    # ... continue loop
end
```

### 17.2 With Conversation Manager

```elixir
defmodule MyApp.SkillChat do
  def chat(user_message) do
    {:ok, skills} = Conjure.load(skill_paths())
    
    system_prompt = build_system_prompt(skills)
    tools = Conjure.tool_definitions()
    
    messages = [%{role: "user", content: user_message}]
    
    Conjure.Conversation.run_loop(
      messages,
      skills,
      &call_claude(&1, system_prompt, tools),
      executor: Conjure.Executor.Docker,
      max_iterations: 15,
      timeout: 60_000
    )
  end
  
  defp call_claude(messages, system, tools) do
    # Your Claude API implementation
  end
end
```

### 17.3 With GenServer Registry

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Conjure.Registry, name: MyApp.Skills, paths: ["/path/to/skills"]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

# Usage
skills = Conjure.Registry.list(MyApp.Skills)
skill = Conjure.Registry.get(MyApp.Skills, "pdf")
```

### 17.4 Custom Executor

```elixir
defmodule MyApp.FirecrackerExecutor do
  @behaviour Conjure.Executor
  
  @impl true
  def bash(command, context) do
    # Custom Firecracker microVM implementation
  end
  
  @impl true
  def view(path, context, opts) do
    # Custom implementation
  end
  
  # ... other callbacks
end

# Usage
Conjure.execute(tool_call, skills, executor: MyApp.FirecrackerExecutor)
```

---

## Appendices

### Appendix A: Anthropic Agent Skills Specification Reference

The Anthropic Agent Skills specification defines:

1. **Skill Structure**
   - Required: `SKILL.md` with YAML frontmatter
   - Optional: `scripts/`, `references/`, `assets/` directories

2. **Frontmatter Fields**
   - `name` (required): Skill identifier
   - `description` (required): Comprehensive description with triggers
   - `license` (optional): License information
   - `compatibility` (optional): Environment requirements
   - `allowed_tools` (optional): Tool restrictions

3. **Progressive Disclosure**
   - Level 1: Metadata only (name + description)
   - Level 2: Full SKILL.md body
   - Level 3: Referenced resources

4. **Distribution Format**
   - `.skill` files are ZIP archives
   - Contains skill directory structure

### Appendix B: Tool Schema Reference

Full JSON Schema definitions for all tools are available in the `Conjure.Tools` module documentation.

### Appendix C: Docker Image Build

```bash
# Build the default sandbox image
mix conjure.docker.build

# Or manually
docker build -t conjure/sandbox:latest -f priv/docker/Dockerfile .
```

### Appendix D: Migration Guide

For applications migrating from other skill implementations:

1. Ensure skills follow Anthropic's SKILL.md format
2. Update frontmatter to include required `name` and `description` fields
3. Move triggering information from body to `description` field
4. Test skill loading with `Conjure.Loader.validate/1`

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0-draft | Dec 2025 | Initial specification |

---

*End of Specification*
