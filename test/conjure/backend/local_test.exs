defmodule Conjure.Backend.LocalTest do
  use ExUnit.Case, async: true

  alias Conjure.Backend.Local
  alias Conjure.Session

  describe "backend_type/0" do
    test "returns :local" do
      assert Local.backend_type() == :local
    end
  end

  describe "new_session/2" do
    test "creates session with local execution mode" do
      session = Local.new_session([], [])

      assert %Session{} = session
      assert session.execution_mode == :local
      assert session.skills == []
      assert session.messages == []
      assert session.container_id == nil
      assert session.created_files == []
      assert session.context != nil
    end

    test "creates execution context with defaults" do
      session = Local.new_session([], [])

      assert session.context.timeout == 30_000
      assert session.context.working_directory =~ "conjure_local"
    end

    test "respects custom timeout" do
      session = Local.new_session([], timeout: 60_000)

      assert session.context.timeout == 60_000
    end

    test "respects custom working directory" do
      session = Local.new_session([], working_directory: "/custom/path")

      assert session.context.working_directory == "/custom/path"
    end

    test "stores skills" do
      skills = [:skill1, :skill2]
      session = Local.new_session(skills, [])

      assert session.skills == skills
    end

    test "stores options" do
      opts = [max_iterations: 10, custom: :option]
      session = Local.new_session([], opts)

      assert session.opts == opts
    end
  end

  describe "chat/4" do
    test "returns error on API failure" do
      session = Local.new_session([], [])

      api_callback = fn _messages ->
        {:error, "API error"}
      end

      {:error, error} = Local.chat(session, "Hello", api_callback, [])

      assert error.message =~ "API error"
    end

    test "processes successful response without tool calls" do
      session = Local.new_session([], [])

      api_callback = fn _messages ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Hello back!"}],
           "stop_reason" => "end_turn"
         }}
      end

      {:ok, response, updated_session} = Local.chat(session, "Hello", api_callback, [])

      assert response["stop_reason"] == "end_turn"
      assert length(updated_session.messages) == 2
    end
  end
end
