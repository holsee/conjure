defmodule Conjure.NativeSkill do
  @moduledoc """
  Behaviour for native Elixir skill modules.

  Native skills are Elixir modules that implement this behaviour, allowing
  them to be executed directly in the BEAM without external processes.
  This enables type-safe, in-process skill execution with full access to
  the application's runtime context.

  ## Tool Mapping

  Native skill callbacks map to Claude's tool types:

  | Claude Tool | Native Callback | Purpose |
  |-------------|-----------------|---------|
  | `bash_tool` | `execute/2` | Run commands/logic |
  | `view` | `read/3` | Read resources |
  | `create_file` | `write/3` | Create resources |
  | `str_replace` | `modify/4` | Update resources |

  ## Implementing a Native Skill

      defmodule MyApp.Skills.CacheManager do
        @behaviour Conjure.NativeSkill

        @impl true
        def __skill_info__ do
          %{
            name: "cache-manager",
            description: "Manage application cache",
            allowed_tools: [:execute, :read]
          }
        end

        @impl true
        def execute("clear", _context) do
          :ok = MyApp.Cache.clear()
          {:ok, "Cache cleared successfully"}
        end

        def execute("stats", _context) do
          stats = MyApp.Cache.stats()
          {:ok, format_stats(stats)}
        end

        @impl true
        def read("keys", _context, _opts) do
          keys = MyApp.Cache.keys()
          {:ok, Enum.join(keys, "\\n")}
        end
      end

  ## Usage

      session = Conjure.Session.new_native([MyApp.Skills.CacheManager])

      {:ok, response, session} = Conjure.Session.chat(
        session,
        "Clear the cache and show me the stats",
        &api_callback/1
      )

  ## Tool Definitions

  Native skills automatically generate Claude tool definitions based on
  `__skill_info__/0`. The backend translates tool calls to callback invocations.

  ## Context

  Each callback receives a `Conjure.ExecutionContext` that provides:

  * Working directory for file operations
  * Allowed paths for security boundaries
  * Timeout configuration
  * Custom executor config (can store app-specific data)

  ## Optional Callbacks

  Only `__skill_info__/0` is required. Implement only the callbacks your
  skill needs:

  * `execute/2` - For command/action execution
  * `read/3` - For reading resources
  * `write/3` - For creating resources
  * `modify/4` - For modifying resources

  ## See Also

  * `Conjure.Backend.Native` - Native backend implementation
  * `Conjure.Session.new_native/2` - Creating native sessions
  """

  alias Conjure.ExecutionContext

  @type context :: ExecutionContext.t()
  @type result :: {:ok, String.t()} | {:error, term()}
  @type tool :: :execute | :read | :write | :modify

  @type skill_info :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:allowed_tools) => [tool()]
        }

  @doc """
  Return skill metadata.

  This callback is required and provides information about the skill
  including its name, description, and which tools it implements.

  ## Example

      def __skill_info__ do
        %{
          name: "database-query",
          description: "Execute read-only database queries",
          allowed_tools: [:execute, :read]
        }
      end
  """
  @callback __skill_info__() :: skill_info()

  @doc """
  Execute a command or action.

  This is the primary action callback, replacing bash_tool. Use it for
  performing operations, running queries, triggering actions, etc.

  ## Example

      def execute("query " <> sql, _context) do
        case MyApp.Repo.query(sql) do
          {:ok, result} -> {:ok, format_result(result)}
          {:error, err} -> {:error, err}
        end
      end
  """
  @callback execute(command :: String.t(), context()) :: result()

  @doc """
  Read a resource.

  Replaces the view tool. Use for reading files, fetching data,
  getting resource state, etc.

  ## Options

  * `:offset` - Starting position (for pagination)
  * `:limit` - Maximum amount to return

  ## Example

      def read("schema/" <> table, _context, _opts) do
        schema = MyApp.Repo.get_schema(table)
        {:ok, format_schema(schema)}
      end
  """
  @callback read(path :: String.t(), context(), opts :: keyword()) :: result()

  @doc """
  Write/create a resource.

  Replaces create_file tool. Use for creating new resources,
  storing data, writing files, etc.

  ## Example

      def write(path, content, _context) do
        case File.write(path, content) do
          :ok -> {:ok, "Created \#{path}"}
          {:error, reason} -> {:error, reason}
        end
      end
  """
  @callback write(path :: String.t(), content :: String.t(), context()) :: result()

  @doc """
  Modify an existing resource.

  Replaces str_replace tool. Use for updating existing resources,
  patching data, etc.

  ## Example

      def modify(path, old_content, new_content, _context) do
        content = File.read!(path)
        updated = String.replace(content, old_content, new_content)
        File.write!(path, updated)
        {:ok, "Modified \#{path}"}
      end
  """
  @callback modify(
              path :: String.t(),
              old_content :: String.t(),
              new_content :: String.t(),
              context()
            ) :: result()

  @optional_callbacks [execute: 2, read: 3, write: 3, modify: 4]

  @doc """
  Check if a module implements the NativeSkill behaviour.

  ## Example

      Conjure.NativeSkill.implements?(MyApp.Skills.CacheManager)
      # => true

      Conjure.NativeSkill.implements?(String)
      # => false
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) when is_atom(module) do
    function_exported?(module, :__skill_info__, 0)
  end

  @doc """
  Get skill info from a module.

  Returns `{:ok, info}` if the module implements `__skill_info__/0`,
  or `{:error, :not_a_skill}` otherwise.
  """
  @spec get_info(module()) :: {:ok, skill_info()} | {:error, :not_a_skill}
  def get_info(module) when is_atom(module) do
    if implements?(module) do
      {:ok, module.__skill_info__()}
    else
      {:error, :not_a_skill}
    end
  end

  @doc """
  Build Claude tool definitions from a native skill module.

  Returns a list of tool definitions that can be passed to the Claude API.
  Only includes tools listed in `allowed_tools`.

  ## Example

      Conjure.NativeSkill.tool_definitions(MyApp.Skills.CacheManager)
      # => [
      #   %{
      #     "name" => "cache_manager_execute",
      #     "description" => "Execute a command for cache-manager skill",
      #     "input_schema" => %{...}
      #   },
      #   ...
      # ]
  """
  @spec tool_definitions(module()) :: [map()]
  def tool_definitions(module) when is_atom(module) do
    case get_info(module) do
      {:ok, info} ->
        base_name = info.name |> String.replace("-", "_")

        info.allowed_tools
        |> Enum.map(fn tool ->
          build_tool_definition(base_name, tool, info.description)
        end)

      {:error, _} ->
        []
    end
  end

  defp build_tool_definition(base_name, :execute, description) do
    %{
      "name" => "#{base_name}_execute",
      "description" => "Execute a command for #{description}",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The command to execute"
          }
        },
        "required" => ["command"]
      }
    }
  end

  defp build_tool_definition(base_name, :read, description) do
    %{
      "name" => "#{base_name}_read",
      "description" => "Read a resource for #{description}",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "The resource path to read"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Starting offset for pagination"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum items to return"
          }
        },
        "required" => ["path"]
      }
    }
  end

  defp build_tool_definition(base_name, :write, description) do
    %{
      "name" => "#{base_name}_write",
      "description" => "Create/write a resource for #{description}",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "The resource path to write"
          },
          "content" => %{
            "type" => "string",
            "description" => "The content to write"
          }
        },
        "required" => ["path", "content"]
      }
    }
  end

  defp build_tool_definition(base_name, :modify, description) do
    %{
      "name" => "#{base_name}_modify",
      "description" => "Modify a resource for #{description}",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "The resource path to modify"
          },
          "old_content" => %{
            "type" => "string",
            "description" => "The content to replace"
          },
          "new_content" => %{
            "type" => "string",
            "description" => "The replacement content"
          }
        },
        "required" => ["path", "old_content", "new_content"]
      }
    }
  end
end
