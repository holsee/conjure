# ADR-0016: Test strategy for external dependencies

## Status

Proposed

## Context

Conjure has several components that depend on external systems:

| Component | Dependency | Current Testing |
|-----------|------------|-----------------|
| Docker Executor | Docker daemon | Minimal unit tests |
| Telemetry | Event handlers | No handler tests |
| File operations | Filesystem | Fixture-based |
| API integration | Claude API | Not tested |

Current test suite (53 tests) covers core functionality but has gaps:

1. **Docker tests** - Skip if Docker unavailable, limited coverage
2. **Telemetry tests** - Events emitted but handlers not verified
3. **Integration tests** - No end-to-end conversation flow tests
4. **Error path tests** - Happy paths tested, error conditions less so

The challenge: how to test components with external dependencies without:
- Requiring Docker in CI
- Making tests slow or flaky
- Reducing confidence in the code

## Decision

We will implement a layered testing strategy:

### Layer 1: Unit Tests (No External Dependencies)

All modules should have unit tests that mock external dependencies:

```elixir
defmodule Conjure.Executor.DockerTest do
  use ExUnit.Case

  # Mock the System.cmd calls
  import Mox
  setup :verify_on_exit!

  describe "bash/2" do
    test "formats docker exec command correctly" do
      expect(SystemMock, :cmd, fn "docker", args, _opts ->
        assert ["exec", "container123", "bash", "-c", "echo hello"] = args
        {"hello\n", 0}
      end)

      context = %ExecutionContext{container_id: "container123"}
      assert {:ok, "hello\n"} = Docker.bash("echo hello", context)
    end

    test "returns error on non-zero exit" do
      expect(SystemMock, :cmd, fn _, _, _ -> {"error", 1} end)

      context = %ExecutionContext{container_id: "container123"}
      assert {:error, {:exit_code, 1, "error"}} = Docker.bash("false", context)
    end
  end
end
```

**Mox Setup:**

```elixir
# test/support/mocks.ex
Mox.defmock(SystemMock, for: Conjure.SystemBehaviour)

# lib/conjure/system_behaviour.ex
defmodule Conjure.SystemBehaviour do
  @callback cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
end
```

### Layer 2: Integration Tests (Tagged, Optional)

Tests that require external dependencies are tagged and skipped by default:

```elixir
defmodule Conjure.Executor.DockerIntegrationTest do
  use ExUnit.Case

  @moduletag :integration
  @moduletag :docker

  setup do
    # Skip if Docker not available
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:skip, "Docker not available"}
    end
  end

  describe "full Docker lifecycle" do
    @tag timeout: 60_000
    test "init/bash/cleanup cycle" do
      context = ExecutionContext.new(working_directory: "/tmp/test")

      {:ok, ctx} = Docker.init(context)
      assert ctx.container_id != nil

      {:ok, output} = Docker.bash("echo 'hello from container'", ctx)
      assert output =~ "hello from container"

      :ok = Docker.cleanup(ctx)
    end
  end
end
```

**Running integration tests:**

```bash
# Unit tests only (default)
mix test

# Include Docker integration tests
mix test --include docker

# All integration tests
mix test --include integration

# CI with Docker available
mix test --include integration
```

### Layer 3: Telemetry Tests

Verify telemetry events are emitted correctly:

```elixir
defmodule Conjure.TelemetryTest do
  use ExUnit.Case

  setup do
    # Attach test handler
    :telemetry.attach_many(
      "test-handler",
      [
        [:conjure, :execute, :start],
        [:conjure, :execute, :stop],
        [:conjure, :execute, :exception]
      ],
      &__MODULE__.handle_event/4,
      %{test_pid: self()}
    )

    on_exit(fn -> :telemetry.detach("test-handler") end)
  end

  def handle_event(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  test "execute emits start and stop events" do
    # Trigger execution
    Conjure.execute(tool_call, skills, executor: MockExecutor)

    assert_receive {:telemetry, [:conjure, :execute, :start], _, %{tool: "view"}}
    assert_receive {:telemetry, [:conjure, :execute, :stop], %{duration: _}, _}
  end
end
```

### Layer 4: Contract Tests

Verify all executors implement the behaviour correctly:

```elixir
defmodule Conjure.ExecutorContractTest do
  use ExUnit.Case

  # Test each executor against the contract
  for executor <- [Conjure.Executor.Local, Conjure.Executor.Docker] do
    @executor executor

    describe "#{@executor} contract" do
      test "implements all required callbacks" do
        behaviours = @executor.__info__(:attributes)[:behaviour] || []
        assert Conjure.Executor in behaviours
      end

      test "bash/2 returns expected format" do
        # Use mock context appropriate for executor
        context = build_context_for(@executor)
        result = @executor.bash("echo test", context)

        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end
end
```

### Layer 5: Property-Based Tests

For security-critical functions:

```elixir
defmodule Conjure.SecurityPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  describe "escape_shell/1" do
    property "never produces unbalanced quotes" do
      check all input <- string(:printable) do
        escaped = Security.escape_shell(input)
        # Count quotes should be balanced
        assert balanced_quotes?(escaped)
      end
    end

    property "escaped output is safe for shell" do
      check all input <- string(:printable) do
        escaped = Security.escape_shell(input)
        # Should be able to round-trip through shell
        {output, 0} = System.cmd("bash", ["-c", "echo #{escaped}"])
        assert String.trim(output) == input
      end
    end
  end
end
```

### CI Configuration

```yaml
# .github/workflows/test.yml
name: Tests

on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.16'
          otp-version: '26'
      - run: mix deps.get
      - run: mix test

  integration-tests:
    runs-on: ubuntu-latest
    services:
      docker:
        image: docker:dind
        options: --privileged
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
      - run: mix deps.get
      - run: mix test --include integration
```

### Test Organization

```
test/
├── conjure_test.exs              # Main API tests
├── conjure/
│   ├── loader_test.exs           # Unit tests
│   ├── registry_test.exs
│   ├── security_test.exs
│   ├── executor/
│   │   ├── local_test.exs        # Unit tests
│   │   ├── docker_test.exs       # Unit tests (mocked)
│   │   └── docker_integration_test.exs  # @tag :docker
│   └── telemetry_test.exs
├── integration/
│   ├── conversation_test.exs     # @tag :integration
│   └── end_to_end_test.exs       # @tag :integration
├── property/
│   └── security_property_test.exs
├── support/
│   ├── mocks.ex
│   ├── fixtures.ex
│   └── test_helpers.ex
└── fixtures/
    └── skills/
```

## Consequences

### Positive

- **Fast default tests** - Unit tests run without Docker
- **Comprehensive coverage** - Integration tests catch real issues
- **CI flexibility** - Can run different test suites
- **Documented testing patterns** - Clear examples for contributors
- **Property tests** - Catch edge cases in security code

### Negative

- More complex test setup
- Mox dependency added
- Integration tests may be flaky
- StreamData dependency for property tests

### Neutral

- Tests mirror production architecture
- Contributors must understand test layers
- CI time increases with integration tests

## Alternatives Considered

### Always Require Docker

Make Docker a hard requirement for tests. Rejected because:

- Increases contributor friction
- Slows down test cycle
- Not always available (some CI environments)

### No Integration Tests

Only unit test with mocks. Rejected because:

- Misses real integration issues
- Docker executor bugs would slip through
- Reduces confidence in production behavior

### Testcontainers

Use testcontainers-elixir for Docker management. Deferred because:

- Adds significant dependency
- May be overkill for current needs
- Can add later if needed

## References

- [Mox - Mocks and explicit contracts](https://hexdocs.pm/mox/Mox.html)
- [ExUnit Tags](https://hexdocs.pm/ex_unit/ExUnit.Case.html#module-tags)
- [StreamData for property testing](https://hexdocs.pm/stream_data/StreamData.html)
- [Testing Elixir book](https://pragprog.com/titles/lmelixir/testing-elixir/)
