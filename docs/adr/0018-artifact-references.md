# ADR-0018: Artifact References

## Status

Proposed

## Context

Skills and conversations often need to work with external data:

1. **Skill-bundled assets** - Sample files, templates, or reference data packaged within a skill's `assets/` directory
2. **User-provided files** - Files the user wants to process, stored on the local filesystem
3. **Remote resources** - Data accessible via HTTP/HTTPS URLs

Currently, Conjure has no unified way to reference these resources. Users must:

- Know the exact filesystem paths to skill assets
- Manually manage working directories for user files
- Handle URL fetching themselves before passing content to skills

This creates several problems:

- **Path coupling** - Prompts contain system-specific paths that break across environments
- **Security concerns** - Arbitrary path access enables path traversal attacks
- **No abstraction** - Each source type requires different handling
- **Poor discoverability** - Claude doesn't know what artifacts are available

The Anthropic Agent Skills specification mentions assets but doesn't define a runtime reference mechanism.

## Decision

We will implement a unified artifact reference system using URI schemes to abstract resource access.

### 1. Artifact URI Schemes

Three URI schemes for different artifact sources:

| Scheme | Format | Description |
|--------|--------|-------------|
| `skill://` | `skill://{skill-name}/assets/{path}` | Skill-bundled assets |
| `file://` | `file://{name}` | Registered user files |
| `https://` | `https://{url}` | Remote resources |

**Examples:**

```
skill://csv-helper/assets/sample_data.csv
skill://pdf-generator/assets/templates/invoice.docx
file://sales_report
file://user_upload_123
https://example.com/api/data.json
```

### 2. Artifact Registry

Session-scoped registry for user-provided artifacts:

```elixir
defmodule Conjure.Artifacts do
  @moduledoc """
  Manages artifact references for chat sessions.

  Artifacts provide a secure, abstract way to reference files
  without exposing filesystem paths to the LLM.
  """

  use GenServer

  @type source ::
    {:file, Path.t()} |
    {:url, String.t()} |
    {:content, binary(), content_type :: String.t()}

  @type artifact :: %{
    name: String.t(),
    source: source(),
    content_type: String.t(),
    size: non_neg_integer() | nil,
    metadata: map()
  }

  @doc """
  Start an artifact registry for a session.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc """
  Register a file as a named artifact.

  ## Examples

      # Register a local file
      Artifacts.register(session, "report", {:file, "/uploads/abc123.csv"})

      # Register with URL (will be fetched on access)
      Artifacts.register(session, "api_data", {:url, "https://api.example.com/data.json"})

      # Register inline content
      Artifacts.register(session, "config", {:content, json_string, "application/json"})

  """
  @spec register(session_id(), String.t(), source(), keyword()) ::
    {:ok, artifact()} | {:error, term()}
  def register(session_id, name, source, opts \\ [])

  @doc """
  Resolve an artifact URI to accessible content.

  Returns the content or a local path that can be accessed by the executor.

  ## Examples

      {:ok, content} = Artifacts.resolve(session, "file://report")
      {:ok, path} = Artifacts.resolve(session, "skill://csv-helper/assets/sample.csv")
      {:ok, content} = Artifacts.resolve(session, "https://example.com/data.json")

  """
  @spec resolve(session_id(), String.t()) ::
    {:ok, binary() | Path.t()} | {:error, term()}
  def resolve(session_id, uri)

  @doc """
  List all artifacts registered for a session.
  """
  @spec list(session_id()) :: [artifact()]
  def list(session_id)

  @doc """
  Get artifact metadata without fetching content.
  """
  @spec info(session_id(), String.t()) :: {:ok, artifact()} | {:error, :not_found}
  def info(session_id, name)

  @doc """
  Remove an artifact from the session.
  """
  @spec unregister(session_id(), String.t()) :: :ok
  def unregister(session_id, name)

  @doc """
  Clean up all artifacts for a session.
  """
  @spec cleanup(session_id()) :: :ok
  def cleanup(session_id)
end
```

### 3. URI Resolution

Centralized resolver handles all URI schemes:

```elixir
defmodule Conjure.Artifacts.Resolver do
  @moduledoc """
  Resolves artifact URIs to accessible content or paths.
  """

  alias Conjure.Artifacts

  @doc """
  Resolve any supported artifact URI.
  """
  @spec resolve(session_id(), String.t(), keyword()) ::
    {:ok, content_or_path()} | {:error, term()}
  def resolve(session_id, uri, opts \\ []) do
    case parse_uri(uri) do
      {:skill, skill_name, asset_path} ->
        resolve_skill_asset(skill_name, asset_path, opts)

      {:file, name} ->
        resolve_registered_file(session_id, name, opts)

      {:url, url} ->
        resolve_url(url, opts)

      {:error, reason} ->
        {:error, {:invalid_uri, reason}}
    end
  end

  defp parse_uri("skill://" <> rest) do
    case String.split(rest, "/assets/", parts: 2) do
      [skill_name, path] -> {:skill, skill_name, path}
      _ -> {:error, "invalid skill URI format"}
    end
  end

  defp parse_uri("file://" <> name), do: {:file, name}

  defp parse_uri("https://" <> _ = url), do: {:url, url}
  defp parse_uri("http://" <> _ = url), do: {:url, url}

  defp parse_uri(other), do: {:error, "unsupported URI scheme: #{other}"}

  defp resolve_skill_asset(skill_name, asset_path, opts) do
    skills = Keyword.get(opts, :skills, [])

    case Enum.find(skills, &(&1.name == skill_name)) do
      nil ->
        {:error, {:skill_not_found, skill_name}}

      skill ->
        full_path = Path.join([skill.path, "assets", asset_path])

        # Security: verify path is within skill assets
        if path_within?(full_path, Path.join(skill.path, "assets")) do
          if File.exists?(full_path) do
            {:ok, {:path, full_path}}
          else
            {:error, {:asset_not_found, asset_path}}
          end
        else
          {:error, :path_traversal_blocked}
        end
    end
  end

  defp resolve_registered_file(session_id, name, _opts) do
    case Artifacts.info(session_id, name) do
      {:ok, %{source: {:file, path}}} ->
        if File.exists?(path) do
          {:ok, {:path, path}}
        else
          {:error, {:file_not_found, path}}
        end

      {:ok, %{source: {:content, content, _type}}} ->
        {:ok, {:content, content}}

      {:ok, %{source: {:url, url}}} ->
        # Fetch and cache
        fetch_and_cache(session_id, name, url)

      {:error, :not_found} ->
        {:error, {:artifact_not_found, name}}
    end
  end

  defp resolve_url(url, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_size = Keyword.get(opts, :max_size, 10 * 1024 * 1024)  # 10MB

    case fetch_url(url, timeout: timeout, max_size: max_size) do
      {:ok, content, content_type} ->
        {:ok, {:content, content, content_type}}

      {:error, reason} ->
        {:error, {:fetch_failed, url, reason}}
    end
  end

  defp path_within?(path, base) do
    normalized_path = Path.expand(path)
    normalized_base = Path.expand(base)
    String.starts_with?(normalized_path, normalized_base <> "/")
  end
end
```

### 4. System Prompt Integration

Artifacts section added to the generated system prompt:

```elixir
defmodule Conjure.Prompt do
  # Existing code...

  @doc """
  Generate the artifacts section for the system prompt.
  """
  def artifacts_prompt(session_id, skills) do
    user_artifacts = Conjure.Artifacts.list(session_id)
    skill_assets = collect_skill_assets(skills)

    """
    <artifacts>
    <artifacts_description>
    Artifacts are files and data available for this conversation.
    Reference them using their URI in tool calls.
    </artifacts_description>

    #{format_user_artifacts(user_artifacts)}
    #{format_skill_assets(skill_assets)}

    <artifact_usage>
    Use artifact URIs with the view tool or in bash commands:
    - view tool: {"path": "skill://csv-helper/assets/sample.csv"}
    - bash: process file at resolved path

    URI schemes:
    - skill://{skill}/assets/{path} - Files bundled with skills
    - file://{name} - User-provided files
    - https://{url} - Remote resources (fetched on access)
    </artifact_usage>
    </artifacts>
    """
  end

  defp format_user_artifacts([]), do: ""
  defp format_user_artifacts(artifacts) do
    items = Enum.map_join(artifacts, "\n", fn artifact ->
      """
      <artifact name="#{artifact.name}" type="#{artifact.content_type}" \
      size="#{format_size(artifact.size)}" uri="file://#{artifact.name}"/>
      """
    end)

    """
    <user_artifacts>
    #{items}
    </user_artifacts>
    """
  end

  defp format_skill_assets(assets) do
    items = Enum.map_join(assets, "\n", fn {skill_name, asset_path, type} ->
      uri = "skill://#{skill_name}/assets/#{asset_path}"
      "<asset skill=\"#{skill_name}\" path=\"#{asset_path}\" type=\"#{type}\" uri=\"#{uri}\"/>"
    end)

    """
    <skill_assets>
    #{items}
    </skill_assets>
    """
  end
end
```

### 5. Tool Integration

The executor resolves artifact URIs before tool execution:

```elixir
defmodule Conjure.Executor do
  # Existing code...

  @doc """
  Execute a tool call, resolving any artifact URIs in the input.
  """
  def execute(tool_call, context) do
    case resolve_artifacts_in_input(tool_call.input, context) do
      {:ok, resolved_input} ->
        do_execute(%{tool_call | input: resolved_input}, context)

      {:error, reason} ->
        {:error, {:artifact_resolution_failed, reason}}
    end
  end

  defp resolve_artifacts_in_input(input, context) when is_map(input) do
    Enum.reduce_while(input, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_if_artifact_uri(value, context) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
  end

  defp resolve_if_artifact_uri(value, context) when is_binary(value) do
    if artifact_uri?(value) do
      case Conjure.Artifacts.Resolver.resolve(
        context.session_id,
        value,
        skills: context.skills
      ) do
        {:ok, {:path, path}} -> {:ok, path}
        {:ok, {:content, content}} -> {:ok, content}
        {:ok, {:content, content, _type}} -> {:ok, content}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, value}
    end
  end
  defp resolve_if_artifact_uri(value, _context), do: {:ok, value}

  defp artifact_uri?(value) do
    String.starts_with?(value, "skill://") or
    String.starts_with?(value, "file://") or
    String.starts_with?(value, "https://") or
    String.starts_with?(value, "http://")
  end
end
```

### 6. Docker Executor Support

For Docker execution, resolved artifacts are mounted:

```elixir
defmodule Conjure.Executor.Docker do
  # Existing code...

  defp prepare_artifact_mounts(context) do
    artifacts = Conjure.Artifacts.list(context.session_id)

    Enum.flat_map(artifacts, fn artifact ->
      case artifact.source do
        {:file, path} ->
          container_path = "/artifacts/#{artifact.name}"
          [{path, container_path, :ro}]

        _ ->
          []
      end
    end)
  end

  defp artifact_env_vars(context) do
    artifacts = Conjure.Artifacts.list(context.session_id)

    Enum.map(artifacts, fn artifact ->
      {"ARTIFACT_#{String.upcase(artifact.name)}", "/artifacts/#{artifact.name}"}
    end)
  end
end
```

### 7. Usage Examples

```elixir
# Start a session with artifacts
{:ok, session} = Conjure.Session.start_link()

# Register user files
Conjure.Artifacts.register(session, "sales_data", {:file, "/uploads/sales_2024.csv"})
Conjure.Artifacts.register(session, "config", {:url, "https://api.example.com/config.json"})

# Load skills (which have bundled assets)
{:ok, skills} = Conjure.load("priv/skills")

# Generate prompts with artifact awareness
system_prompt = Conjure.system_prompt(skills) <>
                Conjure.Prompt.artifacts_prompt(session, skills)

# User can reference artifacts naturally
user_message = "Analyze file://sales_data using the csv-helper skill"

# Or reference skill assets
user_message = "Use the sample data at skill://csv-helper/assets/example.csv as a template"

# Or fetch remote data
user_message = "Fetch https://api.github.com/users/holsee and show me the profile"
```

### 8. Security Considerations

```elixir
defmodule Conjure.Artifacts.Security do
  @moduledoc """
  Security validations for artifact access.
  """

  @doc """
  Validate a file path is allowed for registration.
  """
  @spec validate_file_path(Path.t(), keyword()) :: :ok | {:error, term()}
  def validate_file_path(path, opts \\ []) do
    allowed_dirs = Keyword.get(opts, :allowed_dirs, [])

    cond do
      not File.exists?(path) ->
        {:error, :file_not_found}

      path_traversal?(path) ->
        {:error, :path_traversal}

      allowed_dirs != [] and not within_allowed?(path, allowed_dirs) ->
        {:error, :path_not_allowed}

      true ->
        :ok
    end
  end

  @doc """
  Validate a URL is allowed for fetching.
  """
  @spec validate_url(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_url(url, opts \\ []) do
    blocked_hosts = Keyword.get(opts, :blocked_hosts, ["localhost", "127.0.0.1", "169.254.169.254"])
    allowed_schemes = Keyword.get(opts, :allowed_schemes, ["https"])

    uri = URI.parse(url)

    cond do
      uri.scheme not in allowed_schemes ->
        {:error, {:scheme_not_allowed, uri.scheme}}

      uri.host in blocked_hosts ->
        {:error, {:host_blocked, uri.host}}

      private_ip?(uri.host) ->
        {:error, :private_ip_blocked}

      true ->
        :ok
    end
  end
end
```

### 9. Configuration

```elixir
config :conjure,
  artifacts: [
    # File registration settings
    allowed_dirs: ["/uploads", "/workspace"],
    max_file_size: 50 * 1024 * 1024,  # 50MB

    # URL fetching settings
    url_fetch_enabled: true,
    url_timeout: 30_000,
    url_max_size: 10 * 1024 * 1024,  # 10MB
    blocked_hosts: ["localhost", "127.0.0.1", "169.254.169.254"],
    allowed_schemes: ["https"],

    # Caching
    cache_fetched_urls: true,
    cache_ttl: :timer.minutes(15),

    # Cleanup
    session_ttl: :timer.hours(1)
  ]
```

## Consequences

### Positive

- **Unified interface** - Single abstraction for all external data sources
- **Security** - Path traversal prevention, URL validation, sandboxed access
- **Discoverability** - Claude sees available artifacts in system prompt
- **Portability** - URIs work across environments without path changes
- **Lazy loading** - URLs fetched only when accessed
- **Session scoping** - Automatic cleanup when session ends

### Negative

- **Indirection** - Additional layer between Claude and files
- **Complexity** - More code to maintain
- **URL fetching risks** - SSRF concerns require careful validation
- **Memory usage** - Cached URL content consumes memory

### Neutral

- **Learning curve** - Users must learn URI schemes
- **Backward compatibility** - Existing direct paths still work
- **Optional feature** - Can be disabled if not needed

## Alternatives Considered

### Direct Path Injection

Pass resolved paths directly to Claude without URI abstraction. Rejected because:

- Exposes filesystem structure
- Path traversal risks
- Not portable across environments
- Claude can't know what's available

### Content Embedding Only

Always embed content in messages rather than references. Rejected because:

- Large files consume token budget
- Binary files can't be embedded
- Redundant for files accessed multiple times

### Workspace Directory Only

Use a single workspace directory for all user files. Rejected because:

- Doesn't address skill assets
- Doesn't handle URLs
- Less flexible than named artifacts

### Custom Protocol Handler

Implement custom protocol for all resources. Rejected because:

- Over-engineering
- Standard URI schemes are well-understood
- Easier integration with existing tools

## References

- [ADR-0003: Zip Format for Skill Packages](0003-zip-format-for-skill-packages.md)
- [ADR-0009: Local Executor No Sandbox](0009-local-executor-no-sandbox.md)
- [ADR-0010: Docker Production Executor](0010-docker-production-executor.md)
- [URI Scheme RFC 3986](https://datatracker.ietf.org/doc/html/rfc3986)
- [OWASP Path Traversal](https://owasp.org/www-community/attacks/Path_Traversal)
- [OWASP SSRF Prevention](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
