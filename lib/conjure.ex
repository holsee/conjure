defmodule Conjure do
  @moduledoc """
  Elixir library for leveraging Anthropic Agent Skills with Claude models.

  Conjure provides a complete implementation of the Agent Skills specification,
  allowing Elixir applications to:

  - Load and parse skills from the filesystem
  - Generate system prompt fragments for skill discovery
  - Provide tool definitions compatible with Claude's tool use API
  - Execute skill-related tool calls (file reads, script execution)
  - Manage the conversation loop between Claude and tools

  ## Quick Start

      # Load skills from a directory
      {:ok, skills} = Conjure.load("/path/to/skills")

      # Generate system prompt fragment
      system_prompt = \"\"\"
      You are a helpful assistant.

      \#{Conjure.system_prompt(skills)}
      \"\"\"

      # Get tool definitions for API
      tools = Conjure.tool_definitions()

      # Run conversation loop
      {:ok, messages} = Conjure.run_loop(
        [%{role: "user", content: "Use the PDF skill to extract text"}],
        skills,
        &my_claude_api_call/1
      )

  ## Architecture

  Conjure is designed to be:

  - **Composable**: Use individual components independently
  - **Pluggable**: Swap execution backends (Local, Docker, custom)
  - **API-agnostic**: Works with any Claude API client
  - **OTP-compliant**: GenServer registry, supervision trees

  ## Execution Backends

  - `Conjure.Executor.Local` - Direct execution (development only)
  - `Conjure.Executor.Docker` - Sandboxed container execution (production)

  ## Components

  - `Conjure.Loader` - Skill loading and parsing
  - `Conjure.Prompt` - System prompt generation
  - `Conjure.Tools` - Tool schema definitions
  - `Conjure.Conversation` - Conversation loop management
  - `Conjure.Registry` - Skill registry (GenServer)
  """

  alias Conjure.{
    API,
    Conversation,
    Error,
    ExecutionContext,
    Loader,
    Prompt,
    Skill,
    ToolCall,
    ToolResult,
    Tools
  }

  # Re-export key types for convenience
  @type skill :: Skill.t()
  @type tool_call :: ToolCall.t()
  @type tool_result :: ToolResult.t()
  @type context :: ExecutionContext.t()

  # ============================================================================
  # Loading Skills
  # ============================================================================

  @doc """
  Load skills from a directory path.

  Returns a list of parsed Skill structs with metadata only (body not loaded).
  This implements progressive disclosure - full skill content is loaded on demand.

  ## Example

      {:ok, skills} = Conjure.load("/path/to/skills")
      # Returns skills with name, description, path loaded
      # Body content loaded when Claude reads SKILL.md via view tool
  """
  @spec load(Path.t()) :: {:ok, [Skill.t()]} | {:error, Error.t()}
  def load(path) do
    Loader.scan_and_load(path)
  end

  @doc """
  Load skills from multiple directories.

  ## Example

      {:ok, skills} = Conjure.load_all([
        "/path/to/skills",
        "~/.conjure/skills"
      ])
  """
  @spec load_all([Path.t()]) :: {:ok, [Skill.t()]} | {:error, Error.t()}
  def load_all(paths) when is_list(paths) do
    skills =
      paths
      |> Enum.flat_map(fn path ->
        case load(path) do
          {:ok, skills} -> skills
          {:error, _} -> []
        end
      end)

    {:ok, skills}
  end

  @doc """
  Load a single .skill file (ZIP format).

  ## Example

      {:ok, skill} = Conjure.load_skill_file("/path/to/my-skill.skill")
  """
  @spec load_skill_file(Path.t()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def load_skill_file(path) do
    Loader.load_skill_file(path)
  end

  @doc """
  Load the full body of a skill.

  For progressive disclosure, skills are initially loaded with metadata only.
  Use this to explicitly load the body content.

  ## Example

      {:ok, skill} = Conjure.load_skill("/path/to/skill")
      {:ok, skill_with_body} = Conjure.load_body(skill)
      IO.puts(skill_with_body.body)
  """
  @spec load_body(Skill.t()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def load_body(skill) do
    Loader.load_body(skill)
  end

  @doc """
  Read a resource file from a skill.

  ## Example

      {:ok, content} = Conjure.read_resource(skill, "scripts/helper.py")
  """
  @spec read_resource(Skill.t(), Path.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def read_resource(skill, relative_path) do
    Loader.read_resource(skill, relative_path)
  end

  # ============================================================================
  # Prompt Generation
  # ============================================================================

  @doc """
  Generate the system prompt fragment for skill discovery.

  This should be appended to your system prompt to enable Claude
  to discover and use available skills.

  ## Options

  * `:include_instructions` - Include usage instructions (default: true)

  ## Example

      skills = Conjure.load("/skills")

      system_prompt = \"\"\"
      You are a helpful assistant.

      \#{Conjure.system_prompt(skills)}
      \"\"\"
  """
  @spec system_prompt([Skill.t()], keyword()) :: String.t()
  def system_prompt(skills, opts \\ []) do
    Prompt.generate(skills, opts)
  end

  @doc """
  Get tool definitions for the Claude API.

  Returns an array of tool schemas to pass in API requests.

  ## Options

  * `:only` - Only include these tools (e.g., `["view", "bash_tool"]`)
  * `:except` - Exclude these tools

  ## Example

      tools = Conjure.tool_definitions()
      # Pass to Claude API request
  """
  @spec tool_definitions(keyword()) :: [map()]
  def tool_definitions(opts \\ []) do
    Tools.definitions(opts)
  end

  # ============================================================================
  # Execution
  # ============================================================================

  @doc """
  Execute a tool call and return the result.

  ## Options

  * `:executor` - Executor module (default: `Conjure.Executor.Local`)
  * `:context` - ExecutionContext (created if not provided)

  ## Example

      tool_call = %Conjure.ToolCall{
        id: "toolu_123",
        name: "view",
        input: %{"path" => "/path/to/file"}
      }

      {:ok, result} = Conjure.execute(tool_call, skills)
  """
  @spec execute(ToolCall.t(), [Skill.t()], keyword()) ::
          {:ok, ToolResult.t()} | {:error, Error.t()}
  def execute(tool_call, skills, opts \\ []) do
    executor = Keyword.get(opts, :executor, Conjure.Executor.Local)
    context = Keyword.get(opts, :context) || create_context(skills, opts)

    case Conjure.Executor.execute(tool_call, context, executor) do
      {:ok, output} ->
        {:ok, ToolResult.success(tool_call.id, output)}

      {:ok, output, _files} ->
        {:ok, ToolResult.success(tool_call.id, output)}

      {:error, %Error{message: message}} ->
        {:ok, ToolResult.error(tool_call.id, message)}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  @doc """
  Create an execution context for skills.

  ## Options

  * `:skills_root` - Root directory containing skills
  * `:working_directory` - Working directory for operations
  * `:timeout` - Execution timeout in milliseconds
  * `:allowed_paths` - Paths that can be accessed
  * `:network_access` - `:none`, `:limited`, or `:full`
  * `:executor_config` - Executor-specific configuration
  """
  @spec create_context([Skill.t()], keyword()) :: ExecutionContext.t()
  def create_context(skills, opts \\ []) do
    skills_root =
      Keyword.get_lazy(opts, :skills_root, fn ->
        case skills do
          [%Skill{path: path} | _] -> Path.dirname(path)
          _ -> System.tmp_dir!()
        end
      end)

    opts
    |> Keyword.put(:skills_root, skills_root)
    |> ExecutionContext.new()
  end

  # ============================================================================
  # Conversation Management
  # ============================================================================

  @doc """
  Run a complete conversation loop until completion.

  This is the main entry point for managing the tool-use conversation
  with Claude. Provide a callback function that makes API calls.

  ## Options

  * `:max_iterations` - Maximum tool loops (default: 25)
  * `:executor` - Executor module to use
  * `:timeout` - Tool execution timeout
  * `:on_tool_call` - Callback for each tool call
  * `:on_tool_result` - Callback for each result

  ## Example

      messages = [%{role: "user", content: "Extract text from the PDF"}]

      {:ok, final_messages} = Conjure.run_loop(
        messages,
        skills,
        fn msgs -> MyApp.Claude.call(msgs) end,
        max_iterations: 10
      )
  """
  @spec run_loop([map()], [Skill.t()], fun(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def run_loop(messages, skills, api_callback, opts \\ []) do
    Conversation.run_loop(messages, skills, api_callback, opts)
  end

  @doc """
  Process a single Claude response.

  Use this for manual conversation management.

  ## Example

      case Conjure.process_response(response, skills) do
        {:done, text} ->
          IO.puts("Complete: " <> text)

        {:continue, results} ->
          # Send results back to Claude
          next_response = call_claude(results)
      end
  """
  @spec process_response(map(), [Skill.t()], keyword()) ::
          {:done, String.t()} | {:continue, [ToolResult.t()]} | {:error, term()}
  def process_response(response, skills, opts \\ []) do
    Conversation.process_response(response, skills, opts)
  end

  # ============================================================================
  # API Helpers
  # ============================================================================

  @doc """
  Build a complete system prompt with skills.

  ## Example

      prompt = Conjure.build_system_prompt("You are helpful.", skills)
  """
  @spec build_system_prompt(String.t(), [Skill.t()], keyword()) :: String.t()
  def build_system_prompt(base_prompt, skills, opts \\ []) do
    API.build_system_prompt(base_prompt, skills, opts)
  end

  @doc """
  Parse a Claude API response.

  ## Example

      {:ok, parsed} = Conjure.parse_response(response)
      IO.inspect(parsed.tool_uses)
  """
  @spec parse_response(map()) :: {:ok, API.parsed_response()} | {:error, term()}
  def parse_response(response) do
    API.parse_response(response)
  end

  # ============================================================================
  # Utilities
  # ============================================================================

  @doc """
  Validate a skill's structure.

  ## Example

      case Conjure.validate(skill) do
        :ok -> :valid
        {:error, errors} -> IO.inspect(errors)
      end
  """
  @spec validate(Skill.t()) :: :ok | {:error, [String.t()]}
  def validate(skill) do
    Loader.validate(skill)
  end

  @doc """
  Get the library version.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:conjure, :vsn) |> to_string()
  end
end
