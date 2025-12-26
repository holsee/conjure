defmodule Conjure.Backend.NativeTest do
  use ExUnit.Case, async: true

  alias Conjure.Backend.Native
  alias Conjure.{NativeSkill, Session}

  # Test skill modules
  defmodule EchoSkill do
    @behaviour NativeSkill

    @impl true
    def __skill_info__ do
      %{
        name: "echo",
        description: "Echo messages back",
        allowed_tools: [:execute]
      }
    end

    @impl true
    def execute(text, _context) do
      {:ok, "Echo: #{text}"}
    end
  end

  defmodule DataSkill do
    @behaviour NativeSkill

    @impl true
    def __skill_info__ do
      %{
        name: "data-reader",
        description: "Read data",
        allowed_tools: [:read]
      }
    end

    @impl true
    def read("users", _context, _opts) do
      {:ok, "user1, user2, user3"}
    end

    def read(path, _context, opts) do
      {:ok, "Data from #{path}, opts: #{inspect(opts)}"}
    end
  end

  defmodule FailingSkill do
    @behaviour NativeSkill

    @impl true
    def __skill_info__ do
      %{
        name: "failing",
        description: "A skill that fails",
        allowed_tools: [:execute]
      }
    end

    @impl true
    def execute(_cmd, _context) do
      {:error, "Something went wrong"}
    end
  end

  describe "backend_type/0" do
    test "returns :native" do
      assert Native.backend_type() == :native
    end
  end

  describe "new_session/2" do
    test "creates session with native execution mode" do
      session = Native.new_session([EchoSkill], [])

      assert %Session{} = session
      assert session.execution_mode == :native
      assert session.skills == [EchoSkill]
      assert session.messages == []
      assert session.container_id == nil
      assert session.created_files == []
      assert session.context != nil
    end

    test "accepts multiple skill modules" do
      session = Native.new_session([EchoSkill, DataSkill], [])

      assert session.skills == [EchoSkill, DataSkill]
    end

    test "raises for module not implementing behaviour" do
      assert_raise ArgumentError, ~r/does not implement/, fn ->
        Native.new_session([String], [])
      end
    end

    test "creates execution context with defaults" do
      session = Native.new_session([EchoSkill], [])

      assert session.context.timeout == 30_000
      assert session.context.working_directory =~ "conjure_native"
    end

    test "respects custom options" do
      session =
        Native.new_session([EchoSkill],
          timeout: 60_000,
          working_directory: "/custom/path"
        )

      assert session.context.timeout == 60_000
      assert session.context.working_directory == "/custom/path"
    end
  end

  describe "tool_definitions/1" do
    test "generates definitions from multiple skills" do
      definitions = Native.tool_definitions([EchoSkill, DataSkill])

      assert length(definitions) == 2

      names = Enum.map(definitions, & &1["name"])
      assert "echo_execute" in names
      assert "data_reader_read" in names
    end

    test "returns empty list for empty skills" do
      assert Native.tool_definitions([]) == []
    end
  end

  describe "build_tool_map/1" do
    test "maps tool names to modules and callbacks" do
      tool_map = Native.build_tool_map([EchoSkill, DataSkill])

      assert tool_map["echo_execute"] == {EchoSkill, :execute}
      assert tool_map["data_reader_read"] == {DataSkill, :read}
    end

    test "returns empty map for empty skills" do
      assert Native.build_tool_map([]) == %{}
    end
  end

  describe "chat/4" do
    test "handles response without tool calls" do
      session = Native.new_session([EchoSkill], [])

      api_callback = fn _messages ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Hello!"}],
           "stop_reason" => "end_turn"
         }}
      end

      {:ok, response, updated_session} = Native.chat(session, "Hi", api_callback, [])

      assert response["stop_reason"] == "end_turn"
      assert length(updated_session.messages) == 2
    end

    test "executes tool calls and continues" do
      session = Native.new_session([EchoSkill], [])

      call_count = :counters.new(1, [:atomics])

      api_callback = fn _messages ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          # First call - return tool use
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => "Let me echo that"},
               %{
                 "type" => "tool_use",
                 "id" => "tool_1",
                 "name" => "echo_execute",
                 "input" => %{"command" => "Hello world"}
               }
             ]
           }}
        else
          # Second call - return final response
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Done!"}],
             "stop_reason" => "end_turn"
           }}
        end
      end

      {:ok, response, updated_session} = Native.chat(session, "Echo hello", api_callback, [])

      assert response["stop_reason"] == "end_turn"
      # user, assistant (with tool_use), user (with tool_result), assistant (final)
      assert length(updated_session.messages) == 4
    end

    test "handles tool execution errors gracefully" do
      session = Native.new_session([FailingSkill], [])

      call_count = :counters.new(1, [:atomics])

      api_callback = fn messages ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok,
           %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tool_1",
                 "name" => "failing_execute",
                 "input" => %{"command" => "do something"}
               }
             ]
           }}
        else
          # After tool error, check the tool result
          last_msg = List.last(messages)
          tool_result = hd(last_msg["content"])
          assert tool_result["is_error"] == true

          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Tool failed"}],
             "stop_reason" => "end_turn"
           }}
        end
      end

      {:ok, _response, _session} = Native.chat(session, "Try this", api_callback, [])
    end

    test "returns error on max iterations" do
      session = Native.new_session([EchoSkill], max_iterations: 2)

      # Always return tool use to trigger max iterations
      api_callback = fn _messages ->
        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "tool_1",
               "name" => "echo_execute",
               "input" => %{"command" => "loop"}
             }
           ]
         }}
      end

      {:error, error} = Native.chat(session, "Loop forever", api_callback, [])

      assert error.type == :max_iterations_reached
    end

    test "returns error on API failure" do
      session = Native.new_session([EchoSkill], [])

      api_callback = fn _messages ->
        {:error, "Network error"}
      end

      {:error, error} = Native.chat(session, "Hello", api_callback, [])

      assert error.message =~ "Network error"
    end

    test "calls on_tool_call callback" do
      session = Native.new_session([EchoSkill], [])

      tool_calls = :ets.new(:tool_calls, [:bag, :public])

      call_count = :counters.new(1, [:atomics])

      api_callback = fn _messages ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok,
           %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tool_1",
                 "name" => "echo_execute",
                 "input" => %{"command" => "test"}
               }
             ]
           }}
        else
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Done"}],
             "stop_reason" => "end_turn"
           }}
        end
      end

      on_tool_call = fn call ->
        :ets.insert(tool_calls, {:call, call.name})
      end

      {:ok, _response, _session} =
        Native.chat(
          session,
          "Test",
          api_callback,
          on_tool_call: on_tool_call
        )

      assert [{:call, "echo_execute"}] = :ets.lookup(tool_calls, :call)
    end
  end
end
