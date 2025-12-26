defmodule Conjure.Executor do
  @moduledoc """
  Behaviour for tool execution backends.

  Executors are responsible for running tool operations (bash commands,
  file reads/writes) in an execution environment. Different executors
  provide different levels of isolation:

  - `Conjure.Executor.Local` - Direct execution on host (no isolation)
  - `Conjure.Executor.Docker` - Container-isolated execution

  ## Implementing a Custom Executor

  To create a custom executor, implement all required callbacks:

      defmodule MyApp.FirecrackerExecutor do
        @behaviour Conjure.Executor

        @impl true
        def init(context) do
          # Start Firecracker microVM
          {:ok, %{context | vm_id: vm_id}}
        end

        @impl true
        def bash(command, context) do
          # Execute in microVM
          {:ok, output}
        end

        @impl true
        def view(path, context, opts) do
          # Read from microVM
          {:ok, content}
        end

        @impl true
        def create_file(path, content, context) do
          {:ok, "File created"}
        end

        @impl true
        def str_replace(path, old_str, new_str, context) do
          {:ok, "File updated"}
        end

        @impl true
        def cleanup(context) do
          # Shutdown microVM
          :ok
        end
      end

  ## Result Types

  All execution callbacks return:
  - `{:ok, output}` - Successful execution with string output
  - `{:ok, output, files}` - Execution with output and generated files
  - `{:error, reason}` - Execution failed
  """

  alias Conjure.ExecutionContext

  @type result :: {:ok, String.t()} | {:ok, String.t(), [file_output()]} | {:error, term()}
  @type file_output :: %{path: Path.t(), content: binary()}

  @doc """
  Initialize the execution environment.

  Called once per session to set up the execution environment.
  For stateless executors, this can be a no-op that returns the context unchanged.
  For container-based executors, this starts the container.
  """
  @callback init(context :: ExecutionContext.t()) ::
              {:ok, ExecutionContext.t()} | {:error, term()}

  @doc """
  Execute a bash command.
  """
  @callback bash(command :: String.t(), context :: ExecutionContext.t()) :: result()

  @doc """
  Read a file or directory listing.

  ## Options

  * `:view_range` - `[start_line, end_line]` for partial file reads
  """
  @callback view(path :: Path.t(), context :: ExecutionContext.t(), opts :: keyword()) ::
              result()

  @doc """
  Create a new file with content.
  """
  @callback create_file(
              path :: Path.t(),
              content :: String.t(),
              context :: ExecutionContext.t()
            ) :: result()

  @doc """
  Replace a string in a file.
  """
  @callback str_replace(
              path :: Path.t(),
              old_str :: String.t(),
              new_str :: String.t(),
              context :: ExecutionContext.t()
            ) :: result()

  @doc """
  Cleanup the execution environment.

  Called when the session ends to clean up resources.
  """
  @callback cleanup(context :: ExecutionContext.t()) :: :ok

  @optional_callbacks [init: 1, cleanup: 1]

  @doc """
  Executes a tool call using the specified executor.

  This is a convenience function that dispatches to the appropriate
  executor callback based on the tool name.
  """
  @spec execute(Conjure.ToolCall.t(), ExecutionContext.t(), module()) :: result()
  def execute(%Conjure.ToolCall{name: name, input: input}, context, executor) do
    case name do
      "view" ->
        path = Map.get(input, "path")
        opts = build_view_opts(input)
        executor.view(path, context, opts)

      "bash_tool" ->
        command = Map.get(input, "command")
        executor.bash(command, context)

      "create_file" ->
        path = Map.get(input, "path")
        content = Map.get(input, "file_text", "")
        executor.create_file(path, content, context)

      "str_replace" ->
        path = Map.get(input, "path")
        old_str = Map.get(input, "old_str")
        new_str = Map.get(input, "new_str", "")
        executor.str_replace(path, old_str, new_str, context)

      unknown ->
        {:error, {:unknown_tool, unknown}}
    end
  end

  defp build_view_opts(input) do
    case Map.get(input, "view_range") do
      [start_line, end_line] -> [view_range: {start_line, end_line}]
      _ -> []
    end
  end
end
