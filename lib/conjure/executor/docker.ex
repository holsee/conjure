defmodule Conjure.Executor.Docker do
  @moduledoc """
  Docker-based sandboxed execution backend.

  This executor runs all commands and file operations inside a Docker
  container, providing strong isolation from the host system.

  ## Features

  - **Filesystem Isolation**: Only mounted directories are accessible
  - **Network Isolation**: Network disabled by default
  - **Resource Limits**: Configurable memory and CPU limits
  - **Security Hardening**: No new privileges, read-only root filesystem

  ## Requirements

  - Docker Engine 20.10+
  - Docker socket accessible to the BEAM process
  - conjure/sandbox image (or custom image)

  ## Configuration

      config :conjure, :executor_config,
        docker: %{
          image: "conjure/sandbox:latest",
          memory_limit: "512m",
          cpu_limit: "1.0",
          network: :none,
          tmpfs_size: "100M"
        }

  ## Usage

      context = Conjure.ExecutionContext.new(
        skills_root: "/opt/skills",
        working_directory: "/tmp/session-123",
        executor_config: %{
          image: "conjure/sandbox:latest"
        }
      )

      {:ok, context} = Conjure.Executor.Docker.init(context)
      {:ok, output} = Conjure.Executor.Docker.bash("python3 --version", context)
      :ok = Conjure.Executor.Docker.cleanup(context)
  """

  @behaviour Conjure.Executor

  alias Conjure.{Error, ExecutionContext}

  require Logger

  @default_image "conjure/sandbox:latest"
  @default_memory "512m"
  @default_cpu "1.0"
  @default_tmpfs "100M"

  @impl true
  def init(%ExecutionContext{} = context) do
    with :ok <- check_docker_available(),
         {:ok, container_id} <- start_container(context) do
      :telemetry.execute(
        [:conjure, :executor, :init],
        %{system_time: System.system_time()},
        %{executor: __MODULE__, container_id: container_id}
      )

      {:ok, %{context | container_id: container_id}}
    end
  end

  @impl true
  def bash(command, %ExecutionContext{container_id: container_id} = context)
      when is_binary(container_id) do
    start_time = System.monotonic_time()

    args = [
      "exec",
      "-w",
      "/mnt/skills",
      container_id,
      "bash",
      "-c",
      command
    ]

    timeout = context.timeout || 30_000

    task =
      Task.async(fn ->
        System.cmd("docker", args, stderr_to_stdout: true)
      end)

    result = Task.yield(task, timeout)
    duration = System.monotonic_time() - start_time

    case result do
      {:ok, {output, 0}} ->
        emit_telemetry(:bash, :ok, duration, context)
        {:ok, output}

      {:ok, {output, exit_code}} ->
        emit_telemetry(:bash, :error, duration, context)
        {:error, Error.execution_failed(command, exit_code, output)}

      nil ->
        Task.shutdown(task, :brutal_kill)
        emit_telemetry(:bash, :timeout, duration, context)
        {:error, Error.execution_timeout(command, timeout)}
    end
  end

  def bash(_command, %ExecutionContext{container_id: nil}) do
    {:error, Error.container_error("exec", "container not initialized")}
  end

  @impl true
  def view(path, context, opts \\ [])

  def view(path, %ExecutionContext{container_id: container_id} = context, opts)
      when is_binary(container_id) do
    start_time = System.monotonic_time()

    # Use cat for files, ls for directories
    # First check if it's a directory
    check_cmd = "test -d '#{escape_path(path)}' && echo 'dir' || echo 'file'"

    case docker_exec(container_id, check_cmd) do
      {:ok, "dir\n"} ->
        result = docker_exec(container_id, "ls -la '#{escape_path(path)}'")
        emit_telemetry(:view, :ok, System.monotonic_time() - start_time, context)
        result

      {:ok, "file\n"} ->
        cmd = build_view_command(path, opts)
        result = docker_exec(container_id, cmd)
        emit_telemetry(:view, :ok, System.monotonic_time() - start_time, context)
        result

      {:error, _} = error ->
        emit_telemetry(:view, :error, System.monotonic_time() - start_time, context)
        error
    end
  end

  def view(_path, %ExecutionContext{container_id: nil}, _opts) do
    {:error, Error.container_error("view", "container not initialized")}
  end

  @impl true
  def create_file(path, content, %ExecutionContext{container_id: container_id} = context)
      when is_binary(container_id) do
    start_time = System.monotonic_time()

    # Create parent directory and write file
    dir = Path.dirname(path)
    escaped_content = escape_content(content)

    cmd = """
    mkdir -p '#{escape_path(dir)}' && cat > '#{escape_path(path)}' << 'SKILLEX_EOF'
    #{escaped_content}
    SKILLEX_EOF
    """

    case docker_exec(container_id, cmd) do
      {:ok, _} ->
        emit_telemetry(:create_file, :ok, System.monotonic_time() - start_time, context)
        {:ok, "Created file: #{path}"}

      {:error, _} = error ->
        emit_telemetry(:create_file, :error, System.monotonic_time() - start_time, context)
        error
    end
  end

  def create_file(_path, _content, %ExecutionContext{container_id: nil}) do
    {:error, Error.container_error("create_file", "container not initialized")}
  end

  @impl true
  def str_replace(path, old_str, new_str, %ExecutionContext{container_id: container_id} = context)
      when is_binary(container_id) do
    start_time = System.monotonic_time()

    # Read file, replace, write back
    # Using Python for reliable string replacement
    python_script = """
    import sys
    path = '#{escape_python_string(path)}'
    old_str = '''#{escape_python_multiline(old_str)}'''
    new_str = '''#{escape_python_multiline(new_str)}'''

    with open(path, 'r') as f:
        content = f.read()

    count = content.count(old_str)
    if count == 0:
        print("ERROR: String not found", file=sys.stderr)
        sys.exit(1)
    elif count > 1:
        print(f"ERROR: String appears {count} times, must be unique", file=sys.stderr)
        sys.exit(1)

    new_content = content.replace(old_str, new_str, 1)
    with open(path, 'w') as f:
        f.write(new_content)

    print("OK")
    """

    cmd = "python3 -c #{escape_shell_arg(python_script)}"

    case docker_exec(container_id, cmd) do
      {:ok, _} ->
        emit_telemetry(:str_replace, :ok, System.monotonic_time() - start_time, context)
        {:ok, "Replaced in file: #{path}"}

      {:error, _} = error ->
        emit_telemetry(:str_replace, :error, System.monotonic_time() - start_time, context)
        error
    end
  end

  def str_replace(_path, _old_str, _new_str, %ExecutionContext{container_id: nil}) do
    {:error, Error.container_error("str_replace", "container not initialized")}
  end

  @impl true
  def cleanup(%ExecutionContext{container_id: nil}), do: :ok

  def cleanup(%ExecutionContext{container_id: container_id}) do
    System.cmd("docker", ["rm", "-f", container_id], stderr_to_stdout: true)

    :telemetry.execute(
      [:conjure, :executor, :cleanup],
      %{system_time: System.system_time()},
      %{executor: __MODULE__, container_id: container_id}
    )

    :ok
  end

  @doc """
  Build the default sandbox Docker image.
  """
  @spec build_image(keyword()) :: :ok | {:error, term()}
  def build_image(opts \\ []) do
    dockerfile = Keyword.get(opts, :dockerfile, default_dockerfile())
    tag = Keyword.get(opts, :tag, @default_image)

    # Write Dockerfile to temp location
    temp_dir = Path.join(System.tmp_dir!(), "conjure_docker_build")
    File.mkdir_p!(temp_dir)
    dockerfile_path = Path.join(temp_dir, "Dockerfile")
    File.write!(dockerfile_path, dockerfile)

    case System.cmd("docker", ["build", "-t", tag, "-f", dockerfile_path, temp_dir],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        File.rm_rf!(temp_dir)
        :ok

      {output, _code} ->
        File.rm_rf!(temp_dir)
        {:error, {:build_failed, output}}
    end
  end

  @doc """
  Check if Docker is available and the image exists.
  """
  @spec check_environment(keyword()) :: :ok | {:error, term()}
  def check_environment(opts \\ []) do
    image = Keyword.get(opts, :image, @default_image)

    with :ok <- check_docker_available() do
      check_image_exists(image)
    end
  end

  @doc """
  Returns the default Dockerfile for the sandbox image.
  """
  @spec default_dockerfile() :: String.t()
  def default_dockerfile do
    """
    FROM ubuntu:24.04

    # System packages
    RUN apt-get update && apt-get install -y \\
        python3.12 python3-pip python3-venv \\
        nodejs npm \\
        bash git curl wget jq \\
        poppler-utils qpdf \\
        && rm -rf /var/lib/apt/lists/*

    # Python packages (matching Anthropic's skill environment)
    RUN pip3 install --break-system-packages \\
        pyarrow openpyxl xlsxwriter xlrd pillow \\
        python-pptx python-docx pypdf pdfplumber \\
        pypdfium2 pdf2image pdfkit \\
        reportlab img2pdf pandas numpy matplotlib \\
        pyyaml requests beautifulsoup4

    # Non-root user
    RUN useradd -m -s /bin/bash -u 1001 sandbox
    USER sandbox
    WORKDIR /workspace

    # Default environment
    ENV PYTHONUNBUFFERED=1
    ENV NODE_ENV=production
    """
  end

  # Private functions

  defp check_docker_available do
    case System.cmd("docker", ["version"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _} -> {:error, Error.docker_unavailable(output)}
    end
  rescue
    e -> {:error, Error.docker_unavailable(Exception.message(e))}
  end

  defp check_image_exists(image) do
    case System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _} -> {:error, Error.docker_unavailable("Image #{image} not found")}
    end
  end

  defp start_container(%ExecutionContext{} = context) do
    config = context.executor_config || %{}

    image = Map.get(config, :image, @default_image)
    memory = Map.get(config, :memory_limit, @default_memory)
    cpu = Map.get(config, :cpu_limit, @default_cpu)
    network = Map.get(config, :network, :none)
    tmpfs_size = Map.get(config, :tmpfs_size, @default_tmpfs)

    # Ensure directories exist
    File.mkdir_p!(context.skills_root)
    File.mkdir_p!(context.working_directory)

    args =
      [
        "run",
        "-d",
        "--rm",
        "--network=#{network}",
        "--memory=#{memory}",
        "--cpus=#{cpu}",
        "--security-opt=no-new-privileges",
        "--read-only",
        "--tmpfs=/tmp:size=#{tmpfs_size}",
        "-v",
        "#{context.skills_root}:/mnt/skills:ro",
        "-v",
        "#{context.working_directory}:/workspace:rw",
        image,
        "tail",
        "-f",
        "/dev/null"
      ]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} ->
        {:ok, String.trim(container_id)}

      {output, _code} ->
        {:error, Error.container_error("start", output)}
    end
  end

  defp docker_exec(container_id, command) do
    args = ["exec", container_id, "bash", "-c", command]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error, Error.execution_failed(command, code, output)}
    end
  end

  defp build_view_command(path, opts) do
    case Keyword.get(opts, :view_range) do
      nil ->
        "cat '#{escape_path(path)}'"

      {start_line, -1} ->
        "tail -n +#{start_line} '#{escape_path(path)}' | cat -n"

      {start_line, end_line} ->
        "sed -n '#{start_line},#{end_line}p' '#{escape_path(path)}' | cat -n"
    end
  end

  defp escape_path(path) do
    String.replace(path, "'", "'\\''")
  end

  defp escape_content(content) do
    # Escape the heredoc delimiter if it appears in content
    String.replace(content, "SKILLEX_EOF", "SKILLEX_EOF' 'SKILLEX_EOF")
  end

  defp escape_python_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  defp escape_python_multiline(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("'''", "\\'''")
  end

  defp escape_shell_arg(arg) do
    "'#{String.replace(arg, "'", "'\\''")}'"
  end

  defp emit_telemetry(operation, status, duration, context) do
    :telemetry.execute(
      [:conjure, :executor, operation],
      %{duration: duration},
      %{executor: __MODULE__, status: status, container_id: context.container_id}
    )
  end
end
