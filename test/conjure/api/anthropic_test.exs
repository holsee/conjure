defmodule Conjure.API.AnthropicTest do
  use ExUnit.Case, async: true

  alias Conjure.API.Anthropic
  alias Conjure.Error

  describe "beta_headers/0" do
    test "returns required beta headers" do
      headers = Anthropic.beta_headers()

      assert is_list(headers)
      assert length(headers) == 1

      {key, value} = hd(headers)
      assert key == "anthropic-beta"
      assert value =~ "code-execution"
      assert value =~ "skills"
      assert value =~ "files-api"
    end
  end

  describe "code_execution_tool/0" do
    test "returns code execution tool definition" do
      tool = Anthropic.code_execution_tool()

      assert tool["type"] == "code_execution_20250825"
      assert tool["name"] == "code_execution"
    end
  end

  describe "container_config/1" do
    test "builds valid container config for anthropic skills" do
      {:ok, config} =
        Anthropic.container_config([
          {:anthropic, "xlsx", "latest"},
          {:anthropic, "pdf", "latest"}
        ])

      assert Map.has_key?(config, "skills")
      assert length(config["skills"]) == 2

      [first, second] = config["skills"]
      assert first["type"] == "anthropic"
      assert first["skill_id"] == "xlsx"
      assert first["version"] == "latest"

      assert second["type"] == "anthropic"
      assert second["skill_id"] == "pdf"
    end

    test "builds valid container config for custom skills" do
      {:ok, config} =
        Anthropic.container_config([
          {:custom, "skill_01AbCdEfGhIjKlMnOpQrStUv", "v1"}
        ])

      [skill] = config["skills"]
      assert skill["type"] == "custom"
      assert skill["skill_id"] == "skill_01AbCdEfGhIjKlMnOpQrStUv"
      assert skill["version"] == "v1"
    end

    test "supports mixed anthropic and custom skills" do
      {:ok, config} =
        Anthropic.container_config([
          {:anthropic, "xlsx", "latest"},
          {:custom, "skill_01AbCdEfGhIjKlMnOpQrStUv", "latest"}
        ])

      assert length(config["skills"]) == 2
      types = Enum.map(config["skills"], & &1["type"])
      assert "anthropic" in types
      assert "custom" in types
    end

    test "returns error when exceeding max skills limit" do
      skills = for i <- 1..9, do: {:anthropic, "skill_#{i}", "latest"}

      {:error, %Error{type: :skills_limit_exceeded} = error} =
        Anthropic.container_config(skills)

      assert error.details.count == 9
      assert error.details.max == 8
    end

    test "returns error for invalid skill spec" do
      {:error, %Error{type: :invalid_skill_spec}} =
        Anthropic.container_config([{:invalid, "xlsx", "latest"}])
    end

    test "returns error for missing fields in skill spec" do
      {:error, %Error{type: :invalid_skill_spec}} =
        Anthropic.container_config([{:anthropic, "xlsx"}])
    end

    test "allows up to 8 skills" do
      skills = for i <- 1..8, do: {:anthropic, "skill_#{i}", "latest"}

      {:ok, config} = Anthropic.container_config(skills)
      assert length(config["skills"]) == 8
    end
  end

  describe "container_config!/1" do
    test "returns config on success" do
      config = Anthropic.container_config!([{:anthropic, "xlsx", "latest"}])
      assert Map.has_key?(config, "skills")
    end

    test "raises on error" do
      skills = for i <- 1..9, do: {:anthropic, "skill_#{i}", "latest"}

      assert_raise Error, fn ->
        Anthropic.container_config!(skills)
      end
    end
  end

  describe "with_container_id/2" do
    test "adds container id to config" do
      {:ok, config} = Anthropic.container_config([{:anthropic, "xlsx", "latest"}])
      container_id = "container_abc123"

      updated = Anthropic.with_container_id(config, container_id)

      assert updated["id"] == container_id
      assert updated["skills"] == config["skills"]
    end
  end

  describe "build_request/3" do
    test "builds complete request with defaults" do
      {:ok, container} = Anthropic.container_config([{:anthropic, "xlsx", "latest"}])
      messages = [%{"role" => "user", "content" => "Create a spreadsheet"}]

      request = Anthropic.build_request(messages, container)

      assert request["model"] == "claude-sonnet-4-5-20250929"
      assert request["max_tokens"] == 4096
      assert request["messages"] == messages
      assert request["container"] == container
      assert is_list(request["tools"])
      assert hd(request["tools"])["type"] == "code_execution_20250825"
    end

    test "allows custom model and max_tokens" do
      {:ok, container} = Anthropic.container_config([{:anthropic, "xlsx", "latest"}])
      messages = [%{"role" => "user", "content" => "Test"}]

      request =
        Anthropic.build_request(messages, container,
          model: "claude-opus-4-20250514",
          max_tokens: 8192
        )

      assert request["model"] == "claude-opus-4-20250514"
      assert request["max_tokens"] == 8192
    end

    test "includes system prompt when provided" do
      {:ok, container} = Anthropic.container_config([{:anthropic, "xlsx", "latest"}])
      messages = [%{"role" => "user", "content" => "Test"}]

      request =
        Anthropic.build_request(messages, container, system: "You are a helpful assistant.")

      assert request["system"] == "You are a helpful assistant."
    end

    test "normalizes messages with atom keys" do
      {:ok, container} = Anthropic.container_config([{:anthropic, "xlsx", "latest"}])
      messages = [%{role: :user, content: "Test"}]

      request = Anthropic.build_request(messages, container)

      assert [%{"role" => "user", "content" => "Test"}] = request["messages"]
    end
  end

  describe "parse_response/1" do
    test "parses successful response" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Here's your spreadsheet"}
        ],
        "stop_reason" => "end_turn",
        "container" => %{"id" => "container_xyz"},
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
      }

      {:ok, parsed} = Anthropic.parse_response(response)

      assert parsed.content == response["content"]
      assert parsed.stop_reason == "end_turn"
      assert parsed.container_id == "container_xyz"
      assert parsed.file_ids == []
      assert parsed.usage == response["usage"]
    end

    test "extracts file ids from code execution results" do
      response = %{
        "content" => [
          %{
            "type" => "code_execution_result",
            "content" => [
              %{"type" => "file", "file_id" => "file_abc123"},
              %{"type" => "text", "text" => "Created spreadsheet"}
            ]
          }
        ],
        "stop_reason" => "end_turn"
      }

      {:ok, parsed} = Anthropic.parse_response(response)

      assert parsed.file_ids == ["file_abc123"]
    end

    test "handles response without container" do
      response = %{
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "stop_reason" => "end_turn"
      }

      {:ok, parsed} = Anthropic.parse_response(response)

      assert parsed.container_id == nil
    end

    test "returns error for API error response" do
      response = %{"error" => %{"type" => "invalid_request", "message" => "Bad request"}}

      {:error, {:api_error, error}} = Anthropic.parse_response(response)
      assert error["type"] == "invalid_request"
    end

    test "returns error for invalid response" do
      {:error, {:invalid_response, _}} = Anthropic.parse_response(%{})
    end
  end

  describe "pause_turn?/1" do
    test "returns true for pause_turn stop reason" do
      assert Anthropic.pause_turn?(%{stop_reason: "pause_turn"})
      assert Anthropic.pause_turn?(%{"stop_reason" => "pause_turn"})
    end

    test "returns false for other stop reasons" do
      refute Anthropic.pause_turn?(%{stop_reason: "end_turn"})
      refute Anthropic.pause_turn?(%{"stop_reason" => "end_turn"})
      refute Anthropic.pause_turn?(%{})
    end
  end

  describe "end_turn?/1" do
    test "returns true for end_turn stop reason" do
      assert Anthropic.end_turn?(%{stop_reason: "end_turn"})
      assert Anthropic.end_turn?(%{"stop_reason" => "end_turn"})
    end

    test "returns false for other stop reasons" do
      refute Anthropic.end_turn?(%{stop_reason: "pause_turn"})
      refute Anthropic.end_turn?(%{"stop_reason" => "pause_turn"})
      refute Anthropic.end_turn?(%{})
    end
  end

  describe "extract_file_ids/1" do
    test "extracts file ids from code execution results" do
      response = %{
        "content" => [
          %{
            "type" => "code_execution_result",
            "content" => [
              %{"type" => "file", "file_id" => "file_001"},
              %{"type" => "file", "file_id" => "file_002"}
            ]
          },
          %{
            "type" => "code_execution_result",
            "content" => [
              %{"type" => "file", "file_id" => "file_003"}
            ]
          }
        ]
      }

      file_ids = Anthropic.extract_file_ids(response)

      assert length(file_ids) == 3
      assert "file_001" in file_ids
      assert "file_002" in file_ids
      assert "file_003" in file_ids
    end

    test "removes duplicate file ids" do
      response = %{
        "content" => [
          %{
            "type" => "code_execution_result",
            "content" => [
              %{"type" => "file", "file_id" => "file_001"},
              %{"type" => "file", "file_id" => "file_001"}
            ]
          }
        ]
      }

      file_ids = Anthropic.extract_file_ids(response)
      assert file_ids == ["file_001"]
    end

    test "returns empty list when no files" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Hello"}
        ]
      }

      assert Anthropic.extract_file_ids(response) == []
    end

    test "handles empty content" do
      assert Anthropic.extract_file_ids(%{"content" => []}) == []
      assert Anthropic.extract_file_ids(%{}) == []
    end
  end

  describe "extract_text/1" do
    test "extracts text from content blocks" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Hello "},
          %{"type" => "code_execution_result", "content" => []},
          %{"type" => "text", "text" => "World"}
        ]
      }

      text = Anthropic.extract_text(response)
      assert text == "Hello \nWorld"
    end

    test "returns empty string when no text" do
      response = %{"content" => [%{"type" => "code_execution_result", "content" => []}]}
      assert Anthropic.extract_text(response) == ""
    end
  end

  describe "build_assistant_message/1" do
    test "builds assistant message from response" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Working on it..."},
          %{"type" => "code_execution_result", "content" => []}
        ]
      }

      message = Anthropic.build_assistant_message(response)

      assert message["role"] == "assistant"
      assert message["content"] == response["content"]
    end
  end
end
