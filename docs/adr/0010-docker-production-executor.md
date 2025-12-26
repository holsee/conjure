# ADR-0010: Docker as recommended production executor

## Status

Accepted

## Context

Production deployments require isolated execution of skill commands. Isolation must protect against:

- **Filesystem access**: Skills should only access designated directories
- **Network access**: Skills should not exfiltrate data or attack internal services
- **Resource consumption**: Skills should not exhaust CPU, memory, or disk
- **Process escape**: Skills should not affect other processes or the host

Available isolation technologies:

| Technology | Isolation Level | Portability | Setup Complexity | Performance |
|------------|----------------|-------------|------------------|-------------|
| Docker | Strong | High | Low | Good |
| Podman | Strong | Medium | Low | Good |
| Firecracker | Very Strong | Low | High | Excellent |
| gVisor | Very Strong | Low | Medium | Fair |
| VM (QEMU) | Complete | High | High | Poor |
| seccomp/Landlock | Partial | Linux only | Medium | Excellent |

Docker provides the best balance of:

- Widespread availability (most servers have it)
- Strong isolation (namespaces, cgroups, seccomp)
- Developer familiarity
- Reasonable performance
- Cross-platform support

## Decision

We will provide `Conjure.Executor.Docker` as the recommended production executor.

### Container Model

Each skill execution session runs in a fresh container:

```elixir
def init(context) do
  volumes = [
    {context.skills_root, "/mnt/skills", :ro},      # Skills read-only
    {context.working_directory, "/workspace", :rw}   # Working dir read-write
  ]

  args = [
    "run", "-d",
    "--rm",
    "--network=none",
    "--memory=#{config.memory_limit}",
    "--cpus=#{config.cpu_limit}",
    "--security-opt=no-new-privileges",
    "--read-only",
    "--tmpfs=/tmp:size=100M",
    volume_args(volumes),
    config.image,
    "tail", "-f", "/dev/null"  # Keep container alive
  ]

  {container_id, 0} = System.cmd("docker", args)
  {:ok, %{context | container_id: String.trim(container_id)}}
end
```

Commands execute in the running container:

```elixir
def bash(command, context) do
  {output, exit_code} = System.cmd("docker", [
    "exec",
    "-w", "/workspace",
    context.container_id,
    "bash", "-c", command
  ], stderr_to_stdout: true)

  case exit_code do
    0 -> {:ok, output}
    _ -> {:error, {:exit_code, exit_code, output}}
  end
end
```

Cleanup removes the container:

```elixir
def cleanup(context) do
  System.cmd("docker", ["rm", "-f", context.container_id])
  :ok
end
```

### Default Image

We will provide a default sandbox image with common tools:

```dockerfile
FROM ubuntu:24.04

# System packages
RUN apt-get update && apt-get install -y \
    python3.12 python3-pip python3-venv \
    nodejs npm \
    bash git curl wget jq \
    poppler-utils qpdf \
    && rm -rf /var/lib/apt/lists/*

# Python packages (matching Anthropic's skill environment)
RUN pip3 install --break-system-packages \
    pyarrow openpyxl xlsxwriter pillow \
    python-pptx python-docx pypdf pdfplumber \
    reportlab pandas numpy matplotlib pyyaml

# Non-root user
RUN useradd -m -s /bin/bash -u 1000 sandbox
USER sandbox
WORKDIR /workspace

ENV PYTHONUNBUFFERED=1
```

Build via Mix task:

```bash
mix conjure.docker.build
```

## Consequences

### Positive

- Strong isolation with well-understood security model
- Resource limits enforced (memory, CPU)
- Network isolation by default
- Works with existing Docker infrastructure
- Familiar to operations teams
- Container images are immutable and auditable
- Easy to customize image for specific needs

### Negative

- Docker daemon required on host
- Container startup latency (~100-500ms per session)
- Disk space for images
- Docker socket access may be restricted in some environments
- Windows requires Docker Desktop or WSL2

### Neutral

- Container per session (not per command) balances isolation and performance
- Read-only root filesystem with tmpfs for temp files
- Skills mounted read-only, working directory read-write

## Configuration Options

```elixir
config :conjure, :executor_config,
  docker: %{
    image: "conjure/sandbox:latest",
    memory_limit: "512m",
    cpu_limit: "1.0",
    network: :none,          # :none | :bridge | :host
    read_only: true,
    tmpfs_size: "100M",
    user: "sandbox",
    security_opts: ["no-new-privileges"]
  }
```

## Security Hardening

### 1. No New Privileges

```bash
--security-opt=no-new-privileges
```

Prevents privilege escalation via setuid binaries.

### 2. Read-Only Root

```bash
--read-only --tmpfs=/tmp:size=100M
```

Container filesystem is immutable; only /tmp and mounted volumes are writable.

### 3. Dropped Capabilities

```bash
--cap-drop=ALL
```

Remove all Linux capabilities (optional, may break some tools).

### 4. Seccomp Profile

```bash
--security-opt=seccomp=/path/to/profile.json
```

Restrict available system calls (custom profile can be provided).

### 5. Network Isolation

```bash
--network=none
```

No network access by default. Skills requiring network must explicitly configure.

## Performance Considerations

### Container Reuse

For high-throughput scenarios, containers can be pooled:

```elixir
defmodule Conjure.Executor.Docker.Pool do
  use GenServer

  def checkout(config) do
    # Return existing container or create new one
  end

  def checkin(container_id) do
    # Return container to pool (or destroy if limit reached)
  end
end
```

### Warm Containers

Pre-start containers during low-load periods:

```elixir
def warm(count, config) do
  for _ <- 1..count do
    {:ok, ctx} = Docker.init(%ExecutionContext{})
    Pool.add(ctx.container_id)
  end
end
```

## Alternatives Considered

### Podman

Daemonless container runtime. Considered as alternative because:

- Rootless by default
- Docker-compatible CLI
- No daemon required

Not chosen as primary because:

- Less widespread than Docker
- Some compatibility issues with Docker images
- Will be supported as alternative (same executor, different binary)

### Firecracker

MicroVM technology from AWS. Rejected as default because:

- Requires KVM (not available everywhere)
- Complex setup
- Overkill for typical skill workloads

Recommended for high-security deployments; custom executor can be implemented.

### Kubernetes Jobs

Run each execution as a K8s Job. Rejected because:

- Requires Kubernetes cluster
- High latency (job scheduling)
- Over-engineered for single-node deployments

Suitable for large-scale deployments; custom executor can be implemented.

## References

- [Docker Security Documentation](https://docs.docker.com/engine/security/)
- [Docker Run Reference](https://docs.docker.com/reference/cli/docker/container/run/)
- [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker)
- [Anthropic Code Execution](https://docs.anthropic.com/en/docs/agents-and-tools/code-execution)
