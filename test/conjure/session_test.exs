defmodule Conjure.SessionTest do
  use ExUnit.Case, async: true

  alias Conjure.Session

  describe "new_local/2" do
    test "creates session with local execution mode" do
      skills = []
      session = Session.new_local(skills)

      assert session.execution_mode == :local
      assert session.skills == []
      assert session.messages == []
      assert session.container_id == nil
      assert session.created_files == []
    end

    test "uses docker execution mode when docker executor specified" do
      session = Session.new_local([], executor: Conjure.Executor.Docker)

      assert session.execution_mode == :docker
    end

    test "creates execution context" do
      session = Session.new_local([], timeout: 60_000)

      assert session.context != nil
      assert session.context.timeout == 60_000
    end
  end

  describe "new_anthropic/2" do
    test "creates session with anthropic execution mode" do
      skills = [{:anthropic, "xlsx", "latest"}]
      {:ok, session} = Session.new_anthropic(skills)

      assert session.execution_mode == :anthropic
      assert session.skills == skills
      assert session.messages == []
      assert session.container_id == nil
      assert session.created_files == []
      # No context for Anthropic
      assert session.context == nil
    end

    test "stores options" do
      {:ok, session} = Session.new_anthropic([], max_iterations: 5)

      assert session.opts[:max_iterations] == 5
    end

    test "returns error when Skill.t() passed without api_callback" do
      skill = %Conjure.Skill{name: "test", description: "Test", path: "/tmp"}

      {:error, %Conjure.Error{type: :missing_api_callback}} =
        Session.new_anthropic([skill])
    end
  end

  describe "add_message/2" do
    test "adds message to session" do
      session = Session.new_local([])
      message = %{"role" => "user", "content" => "Hello"}

      updated = Session.add_message(session, message)

      assert length(updated.messages) == 1
      assert hd(updated.messages) == message
    end

    test "appends to existing messages" do
      session = Session.new_local([])
      msg1 = %{"role" => "user", "content" => "First"}
      msg2 = %{"role" => "assistant", "content" => "Second"}

      updated =
        session
        |> Session.add_message(msg1)
        |> Session.add_message(msg2)

      assert length(updated.messages) == 2
    end
  end

  describe "get_messages/1" do
    test "returns all messages" do
      session =
        Session.new_local([])
        |> Session.add_message(%{"role" => "user", "content" => "Hi"})

      messages = Session.get_messages(session)

      assert length(messages) == 1
    end

    test "returns empty list for new session" do
      session = Session.new_local([])

      assert Session.get_messages(session) == []
    end
  end

  describe "reset_messages/1" do
    test "clears messages" do
      session =
        Session.new_local([])
        |> Session.add_message(%{"role" => "user", "content" => "Hi"})
        |> Session.reset_messages()

      assert session.messages == []
    end

    test "clears container_id" do
      {:ok, base_session} = Session.new_anthropic([])

      session =
        %{base_session | container_id: "test_123"}
        |> Session.reset_messages()

      assert session.container_id == nil
    end
  end

  describe "get_created_files/1" do
    test "returns created files" do
      session = %{
        Session.new_local([])
        | created_files: [
            %{id: "file_1", filename: "test.xlsx", source: :anthropic}
          ]
      }

      files = Session.get_created_files(session)

      assert length(files) == 1
      assert hd(files).id == "file_1"
    end
  end

  describe "execution_mode/1" do
    test "returns local for local session" do
      session = Session.new_local([])
      assert Session.execution_mode(session) == :local
    end

    test "returns anthropic for anthropic session" do
      {:ok, session} = Session.new_anthropic([])
      assert Session.execution_mode(session) == :anthropic
    end
  end

  describe "container_id/1" do
    test "returns nil for new session" do
      {:ok, session} = Session.new_anthropic([])
      assert Session.container_id(session) == nil
    end

    test "returns container_id when set" do
      {:ok, base_session} = Session.new_anthropic([])
      session = %{base_session | container_id: "container_abc"}
      assert Session.container_id(session) == "container_abc"
    end
  end

  describe "context/1" do
    test "returns context for local session" do
      session = Session.new_local([])
      assert Session.context(session) != nil
    end

    test "returns nil for anthropic session" do
      {:ok, session} = Session.new_anthropic([])
      assert Session.context(session) == nil
    end
  end

  describe "skills/1" do
    test "returns skills for local session" do
      skills = []
      session = Session.new_local(skills)
      assert Session.skills(session) == skills
    end

    test "returns skill specs for anthropic session" do
      specs = [{:anthropic, "xlsx", "latest"}]
      {:ok, session} = Session.new_anthropic(specs)
      assert Session.skills(session) == specs
    end
  end
end
