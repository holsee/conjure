defmodule Conjure.Backend.AnthropicTest do
  use ExUnit.Case, async: true

  alias Conjure.Backend.Anthropic
  alias Conjure.Session

  describe "backend_type/0" do
    test "returns :anthropic" do
      assert Anthropic.backend_type() == :anthropic
    end
  end

  describe "new_session/2" do
    test "creates session with anthropic execution mode" do
      skill_specs = [{:anthropic, "xlsx", "latest"}]
      session = Anthropic.new_session(skill_specs, [])

      assert %Session{} = session
      assert session.execution_mode == :anthropic
      assert session.skills == skill_specs
      assert session.messages == []
      assert session.container_id == nil
      assert session.created_files == []
      assert session.context == nil
    end

    test "stores multiple skill specs" do
      skill_specs = [
        {:anthropic, "xlsx", "latest"},
        {:anthropic, "pdf", "v1"}
      ]

      session = Anthropic.new_session(skill_specs, [])

      assert session.skills == skill_specs
    end

    test "stores options" do
      opts = [max_iterations: 5, on_pause: fn _, _ -> :ok end]
      session = Anthropic.new_session([], opts)

      assert session.opts[:max_iterations] == 5
      assert is_function(session.opts[:on_pause], 2)
    end
  end

  describe "validate_skills/1" do
    test "accepts valid skill specs" do
      specs = [
        {:anthropic, "xlsx", "latest"},
        {:anthropic, "pdf", "v1"}
      ]

      assert {:ok, ^specs} = Anthropic.validate_skills(specs)
    end

    test "rejects invalid skill specs" do
      specs = [
        {:anthropic, "xlsx", "latest"},
        {"invalid", "spec"},
        :just_an_atom
      ]

      {:error, error} = Anthropic.validate_skills(specs)
      assert error.type == :invalid_skill_spec
    end

    test "accepts empty list" do
      assert {:ok, []} = Anthropic.validate_skills([])
    end
  end

  describe "chat/4" do
    test "returns error on API failure" do
      session = Anthropic.new_session([{:anthropic, "xlsx", "latest"}], [])

      api_callback = fn _messages ->
        {:error, "API error"}
      end

      {:error, error} = Anthropic.chat(session, "Hello", api_callback, [])

      assert error.message =~ "API error"
    end

    test "handles successful response" do
      session = Anthropic.new_session([{:anthropic, "xlsx", "latest"}], [])

      api_callback = fn _messages ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Created spreadsheet"}],
           "stop_reason" => "end_turn",
           "container" => %{"id" => "container_abc"}
         }}
      end

      {:ok, response, updated_session} =
        Anthropic.chat(session, "Create a spreadsheet", api_callback, [])

      assert response["stop_reason"] == "end_turn"
      assert updated_session.container_id == "container_abc"
    end

    test "reuses container_id across turns" do
      session = %{
        Anthropic.new_session([{:anthropic, "xlsx", "latest"}], [])
        | container_id: "existing_container"
      }

      api_callback = fn _messages ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Done"}],
           "stop_reason" => "end_turn",
           "container" => %{"id" => "existing_container"}
         }}
      end

      {:ok, _response, updated_session} = Anthropic.chat(session, "Continue", api_callback, [])

      assert updated_session.container_id == "existing_container"
    end

    test "tracks file IDs from response" do
      session = Anthropic.new_session([{:anthropic, "xlsx", "latest"}], [])

      api_callback = fn _messages ->
        {:ok,
         %{
           "content" => [
             %{"type" => "text", "text" => "Created file"},
             %{
               "type" => "code_execution_result",
               "content" => [
                 %{"type" => "file", "file_id" => "file_123"}
               ]
             }
           ],
           "stop_reason" => "end_turn"
         }}
      end

      {:ok, _response, updated_session} =
        Anthropic.chat(session, "Create a file", api_callback, [])

      assert length(updated_session.created_files) == 1
      assert hd(updated_session.created_files).id == "file_123"
      assert hd(updated_session.created_files).source == :anthropic
    end
  end
end
