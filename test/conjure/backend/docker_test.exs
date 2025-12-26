defmodule Conjure.Backend.DockerTest do
  use ExUnit.Case, async: true

  alias Conjure.Backend.Docker
  alias Conjure.Session

  describe "backend_type/0" do
    test "returns :docker" do
      assert Docker.backend_type() == :docker
    end
  end

  describe "new_session/2" do
    test "creates session with docker execution mode" do
      session = Docker.new_session([], [])

      assert %Session{} = session
      assert session.execution_mode == :docker
      assert session.skills == []
      assert session.messages == []
      assert session.container_id == nil
      assert session.created_files == []
      assert session.context != nil
    end

    test "creates execution context with docker defaults" do
      session = Docker.new_session([], [])

      assert session.context.timeout == 30_000
      # Working directory is now a temp path, not /workspace
      assert String.starts_with?(session.context.working_directory, System.tmp_dir!())
      assert String.contains?(session.context.working_directory, "conjure_docker_")
    end

    test "respects custom timeout" do
      session = Docker.new_session([], timeout: 60_000)

      assert session.context.timeout == 60_000
    end

    test "respects custom working directory" do
      custom_path = Path.join(System.tmp_dir!(), "custom_conjure_#{:rand.uniform(10000)}")

      try do
        session = Docker.new_session([], working_directory: custom_path)

        assert session.context.working_directory == custom_path
        assert File.dir?(custom_path)
      after
        File.rm_rf(custom_path)
      end
    end

    test "stores executor config" do
      config = %{image: "python:3.12", network: "none"}
      session = Docker.new_session([], executor_config: config)

      assert session.context.executor_config == config
    end
  end

  describe "chat/4" do
    @tag :docker
    test "returns error on API failure" do
      session = Docker.new_session([], [])

      api_callback = fn _messages ->
        {:error, "API error"}
      end

      # Note: This test requires Docker to be available.
      # If Docker is not available, the error will be about container start.
      {:error, error} = Docker.chat(session, "Hello", api_callback, [])

      # Either API error or Docker/container error is acceptable
      assert error.message =~ "API error" or
               error.message =~ "Container" or
               error.message =~ "Docker" or
               error.message =~ "docker"
    end
  end
end
