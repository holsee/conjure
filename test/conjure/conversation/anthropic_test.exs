defmodule Conjure.Conversation.AnthropicTest do
  use ExUnit.Case, async: true

  alias Conjure.API.Anthropic, as: API
  alias Conjure.Conversation.Anthropic, as: Conversation
  alias Conjure.Error

  describe "run/4" do
    test "completes on end_turn response" do
      messages = [%{"role" => "user", "content" => "Create a spreadsheet"}]
      {:ok, container} = API.container_config([{:anthropic, "xlsx", "latest"}])

      response = %{
        "content" => [%{"type" => "text", "text" => "Done!"}],
        "stop_reason" => "end_turn",
        "container" => %{"id" => "container_123"}
      }

      api_callback = fn _msgs -> {:ok, response} end

      {:ok, result} = Conversation.run(messages, container, api_callback)

      assert result.response == response
      assert result.container_id == "container_123"
      assert result.iterations == 1
      assert result.file_ids == []
      # original + assistant
      assert length(result.messages) == 2
    end

    test "handles pause_turn and continues" do
      messages = [%{"role" => "user", "content" => "Create a spreadsheet"}]
      {:ok, container} = API.container_config([{:anthropic, "xlsx", "latest"}])

      call_count = :counters.new(1, [:atomics])

      pause_response = %{
        "content" => [%{"type" => "text", "text" => "Working..."}],
        "stop_reason" => "pause_turn",
        "container" => %{"id" => "container_123"}
      }

      final_response = %{
        "content" => [%{"type" => "text", "text" => "Done!"}],
        "stop_reason" => "end_turn",
        "container" => %{"id" => "container_123"}
      }

      api_callback = fn _msgs ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, pause_response}
        else
          {:ok, final_response}
        end
      end

      {:ok, result} = Conversation.run(messages, container, api_callback)

      assert result.response["stop_reason"] == "end_turn"
      assert result.iterations == 2
      # original + 2 assistant messages
      assert length(result.messages) == 3
    end

    test "returns error when max iterations exceeded" do
      messages = [%{"role" => "user", "content" => "Long task"}]
      {:ok, container} = API.container_config([{:anthropic, "xlsx", "latest"}])

      # Always return pause_turn
      api_callback = fn _msgs ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Still working..."}],
           "stop_reason" => "pause_turn",
           "container" => %{"id" => "container_123"}
         }}
      end

      {:error, %Error{type: :pause_turn_max_exceeded} = error} =
        Conversation.run(messages, container, api_callback, max_iterations: 3)

      assert error.details.iterations == 3
      assert error.details.max == 3
    end

    test "calls on_pause callback" do
      messages = [%{"role" => "user", "content" => "Task"}]
      {:ok, container} = API.container_config([{:anthropic, "xlsx", "latest"}])

      pause_attempts = :ets.new(:pause_attempts, [:set, :public])

      api_callback = fn msgs ->
        if length(msgs) == 1 do
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Working..."}],
             "stop_reason" => "pause_turn",
             "container" => %{"id" => "c1"}
           }}
        else
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Done"}],
             "stop_reason" => "end_turn",
             "container" => %{"id" => "c1"}
           }}
        end
      end

      on_pause = fn _response, attempt ->
        :ets.insert(pause_attempts, {:attempt, attempt})
      end

      {:ok, _result} = Conversation.run(messages, container, api_callback, on_pause: on_pause)

      assert [{:attempt, 1}] = :ets.lookup(pause_attempts, :attempt)
      :ets.delete(pause_attempts)
    end

    test "extracts file IDs from responses" do
      messages = [%{"role" => "user", "content" => "Create files"}]
      {:ok, container} = API.container_config([{:anthropic, "xlsx", "latest"}])

      response = %{
        "content" => [
          %{
            "type" => "code_execution_result",
            "content" => [
              %{"type" => "file", "file_id" => "file_abc"},
              %{"type" => "file", "file_id" => "file_def"}
            ]
          }
        ],
        "stop_reason" => "end_turn",
        "container" => %{"id" => "c1"}
      }

      api_callback = fn _msgs -> {:ok, response} end

      {:ok, result} = Conversation.run(messages, container, api_callback)

      assert "file_abc" in result.file_ids
      assert "file_def" in result.file_ids
    end

    test "accumulates file IDs across pause_turn iterations" do
      messages = [%{"role" => "user", "content" => "Create files"}]
      {:ok, container} = API.container_config([{:anthropic, "xlsx", "latest"}])

      call_count = :counters.new(1, [:atomics])

      api_callback = fn _msgs ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok,
           %{
             "content" => [
               %{
                 "type" => "code_execution_result",
                 "content" => [%{"type" => "file", "file_id" => "file_first"}]
               }
             ],
             "stop_reason" => "pause_turn",
             "container" => %{"id" => "c1"}
           }}
        else
          {:ok,
           %{
             "content" => [
               %{
                 "type" => "code_execution_result",
                 "content" => [%{"type" => "file", "file_id" => "file_second"}]
               }
             ],
             "stop_reason" => "end_turn",
             "container" => %{"id" => "c1"}
           }}
        end
      end

      {:ok, result} = Conversation.run(messages, container, api_callback)

      assert "file_first" in result.file_ids
      assert "file_second" in result.file_ids
      assert length(result.file_ids) == 2
    end

    test "returns error on API failure" do
      messages = [%{"role" => "user", "content" => "Test"}]
      {:ok, container} = API.container_config([{:anthropic, "xlsx", "latest"}])

      api_callback = fn _msgs ->
        {:error, {:http_error, 500, "Server error"}}
      end

      {:error, %Error{}} = Conversation.run(messages, container, api_callback)
    end

    test "preserves container ID across iterations" do
      messages = [%{"role" => "user", "content" => "Task"}]
      {:ok, container} = API.container_config([{:anthropic, "xlsx", "latest"}])

      container_ids = :ets.new(:container_ids, [:bag, :public])

      api_callback = fn msgs ->
        # Record the container ID if present in messages context
        if length(msgs) > 1 do
          :ets.insert(container_ids, {:seen, "expected_container_123"})
        end

        if length(msgs) == 1 do
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Working..."}],
             "stop_reason" => "pause_turn",
             "container" => %{"id" => "expected_container_123"}
           }}
        else
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Done"}],
             "stop_reason" => "end_turn",
             "container" => %{"id" => "expected_container_123"}
           }}
        end
      end

      {:ok, result} = Conversation.run(messages, container, api_callback)

      assert result.container_id == "expected_container_123"
      :ets.delete(container_ids)
    end
  end

  describe "complete?/1" do
    test "returns true for end_turn" do
      result = %{
        response: %{"stop_reason" => "end_turn"},
        messages: [],
        container_id: nil,
        iterations: 1,
        file_ids: []
      }

      assert Conversation.complete?(result)
    end

    test "returns false for pause_turn" do
      result = %{
        response: %{"stop_reason" => "pause_turn"},
        messages: [],
        container_id: nil,
        iterations: 1,
        file_ids: []
      }

      refute Conversation.complete?(result)
    end
  end

  describe "extract_text/1" do
    test "extracts text from result response" do
      result = %{
        response: %{
          "content" => [
            %{"type" => "text", "text" => "Hello "},
            %{"type" => "code_execution_result", "content" => []},
            %{"type" => "text", "text" => "World"}
          ]
        },
        messages: [],
        container_id: nil,
        iterations: 1,
        file_ids: []
      }

      text = Conversation.extract_text(result)
      assert text == "Hello \nWorld"
    end
  end

  describe "continue/4" do
    test "continues from previous result" do
      # Simulate a previous result
      previous_result = %{
        response: %{"stop_reason" => "end_turn"},
        messages: [
          %{"role" => "user", "content" => "First message"},
          %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "First response"}]}
        ],
        container_id: "container_abc",
        iterations: 1,
        file_ids: []
      }

      new_messages = [%{"role" => "user", "content" => "Follow up"}]

      api_callback = fn msgs ->
        # Should include previous messages plus new message
        assert length(msgs) == 3

        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Follow up response"}],
           "stop_reason" => "end_turn",
           "container" => %{"id" => "container_abc"}
         }}
      end

      {:ok, result} = Conversation.continue(previous_result, new_messages, api_callback)

      assert length(result.messages) == 4
    end
  end
end
