defmodule Conjure.Executor.Local do
  @moduledoc """
  Local execution backend using System.cmd.

  ## Security Warning

  This executor provides **NO SANDBOXING**. Commands and file operations
  execute with the same permissions as the BEAM process.

  **DO NOT USE IN PRODUCTION** unless you fully trust all loaded skills
  and accept the security implications.

  For production deployments, use `Conjure.Executor.Docker` or implement
  a custom executor with appropriate isolation.

  ## Usage

      context = Conjure.ExecutionContext.new(
        working_directory: "/tmp/my-project",
        allowed_paths: ["/tmp/my-project"]
      )

      {:ok, context} = Conjure.Executor.Local.init(context)
      {:ok, output} = Conjure.Executor.Local.bash("ls -la", context)
  """

  @behaviour Conjure.Executor

  alias Conjure.{Error, ExecutionContext}

  require Logger

  @default_timeout 30_000

  @impl true
  def init(%ExecutionContext{} = context) do
    Logger.warning(
      "[Conjure] Using Local executor - NO SANDBOXING. " <>
        "Do not use in production with untrusted skills."
    )

    # Ensure working directory exists
    File.mkdir_p!(context.working_directory)

    :telemetry.execute(
      [:conjure, :executor, :init],
      %{system_time: System.system_time()},
      %{executor: __MODULE__}
    )

    {:ok, context}
  end

  @impl true
  def bash(command, %ExecutionContext{} = context) do
    start_time = System.monotonic_time()

    opts = [
      cd: context.working_directory,
      env: Map.to_list(context.environment),
      stderr_to_stdout: true
    ]

    timeout = context.timeout || @default_timeout

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", command], opts)
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
  rescue
    e ->
      {:error, Error.wrap(e)}
  end

  @impl true
  def view(path, %ExecutionContext{} = context, opts \\ []) do
    start_time = System.monotonic_time()

    with {:ok, resolved_path} <- resolve_path(path, context),
         {:ok, content} <- read_path(resolved_path, opts) do
      emit_telemetry(:view, :ok, System.monotonic_time() - start_time, context)
      {:ok, content}
    else
      {:error, _} = error ->
        emit_telemetry(:view, :error, System.monotonic_time() - start_time, context)
        error
    end
  end

  @impl true
  def create_file(path, content, %ExecutionContext{} = context) do
    start_time = System.monotonic_time()

    with {:ok, resolved_path} <- resolve_path(path, context),
         :ok <- ensure_parent_dir(resolved_path),
         :ok <- File.write(resolved_path, content) do
      emit_telemetry(:create_file, :ok, System.monotonic_time() - start_time, context)
      {:ok, "Created file: #{resolved_path}"}
    else
      {:error, :eacces} ->
        emit_telemetry(:create_file, :error, System.monotonic_time() - start_time, context)
        {:error, Error.permission_denied(path)}

      {:error, reason} ->
        emit_telemetry(:create_file, :error, System.monotonic_time() - start_time, context)
        {:error, Error.wrap(reason)}
    end
  end

  @impl true
  def str_replace(path, old_str, new_str, %ExecutionContext{} = context) do
    start_time = System.monotonic_time()

    with {:ok, resolved_path} <- resolve_path(path, context),
         {:ok, content} <- File.read(resolved_path),
         {:ok, new_content} <- do_replace(content, old_str, new_str),
         :ok <- File.write(resolved_path, new_content) do
      emit_telemetry(:str_replace, :ok, System.monotonic_time() - start_time, context)
      {:ok, "Replaced in file: #{resolved_path}"}
    else
      {:error, :enoent} ->
        emit_telemetry(:str_replace, :error, System.monotonic_time() - start_time, context)
        {:error, Error.file_not_found(path)}

      {:error, :eacces} ->
        emit_telemetry(:str_replace, :error, System.monotonic_time() - start_time, context)
        {:error, Error.permission_denied(path)}

      {:error, _} = error ->
        emit_telemetry(:str_replace, :error, System.monotonic_time() - start_time, context)
        error
    end
  end

  @impl true
  def cleanup(%ExecutionContext{} = _context) do
    :telemetry.execute(
      [:conjure, :executor, :cleanup],
      %{system_time: System.system_time()},
      %{executor: __MODULE__}
    )

    :ok
  end

  # Private helpers

  defp resolve_path(path, context) do
    # If path is absolute, validate against allowed paths
    # If relative, resolve against working directory
    resolved =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, context.working_directory)
      end

    # Check for path traversal attacks
    if safe_path?(resolved, context) do
      {:ok, resolved}
    else
      {:error, Error.path_not_allowed(path, context.allowed_paths)}
    end
  end

  defp safe_path?(path, %ExecutionContext{allowed_paths: allowed_paths}) do
    # If no allowed paths configured, allow all
    if Enum.empty?(allowed_paths) do
      true
    else
      Enum.any?(allowed_paths, fn allowed ->
        expanded_allowed = Path.expand(allowed)
        String.starts_with?(path, expanded_allowed <> "/") or path == expanded_allowed
      end)
    end
  end

  defp read_path(path, opts) do
    cond do
      File.dir?(path) ->
        list_directory(path)

      File.regular?(path) ->
        read_file(path, opts)

      true ->
        {:error, Error.file_not_found(path)}
    end
  end

  defp list_directory(path) do
    case File.ls(path) do
      {:ok, entries} ->
        listing = format_directory_listing(path, entries)
        {:ok, "Directory: #{path}\n\n#{listing}"}

      {:error, :enoent} ->
        {:error, Error.file_not_found(path)}

      {:error, :eacces} ->
        {:error, Error.permission_denied(path)}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp format_directory_listing(path, entries) do
    entries
    |> Enum.sort()
    |> Enum.map_join("\n", fn entry ->
      full_path = Path.join(path, entry)
      type = file_type(full_path)
      "#{type}\t#{entry}"
    end)
  end

  defp file_type(path) do
    cond do
      File.dir?(path) -> "dir"
      File.regular?(path) -> "file"
      true -> "other"
    end
  end

  defp read_file(path, opts) do
    case File.read(path) do
      {:ok, content} ->
        content = apply_view_range(content, opts)
        {:ok, content}

      {:error, :enoent} ->
        {:error, Error.file_not_found(path)}

      {:error, :eacces} ->
        {:error, Error.permission_denied(path)}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp apply_view_range(content, opts) do
    case Keyword.get(opts, :view_range) do
      nil ->
        content

      {start_line, end_line} ->
        lines = String.split(content, "\n")
        total_lines = length(lines)
        start_idx = max(0, start_line - 1)
        end_idx = if end_line == -1, do: total_lines - 1, else: min(end_line - 1, total_lines - 1)

        lines
        |> Enum.slice(start_idx..end_idx)
        |> Enum.with_index(start_line)
        |> Enum.map_join("\n", fn {line, num} -> "#{num}: #{line}" end)
    end
  end

  defp do_replace(content, old_str, new_str) do
    case count_occurrences(content, old_str) do
      0 ->
        {:error, {:string_not_found, old_str}}

      1 ->
        {:ok, String.replace(content, old_str, new_str)}

      n ->
        {:error, {:string_not_unique, "String appears #{n} times, must be unique"}}
    end
  end

  defp count_occurrences(content, substring) do
    content
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end

  defp ensure_parent_dir(path) do
    parent = Path.dirname(path)

    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp emit_telemetry(operation, status, duration, _context) do
    :telemetry.execute(
      [:conjure, :executor, operation],
      %{duration: duration},
      %{executor: __MODULE__, status: status}
    )
  end
end
