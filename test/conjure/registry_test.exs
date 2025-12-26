defmodule Conjure.RegistryTest do
  use ExUnit.Case

  alias Conjure.{Registry, Skill}

  @fixtures_path Path.expand("../fixtures/skills", __DIR__)

  describe "GenServer" do
    setup do
      name = :"test_registry_#{:rand.uniform(100_000)}"
      {:ok, _pid} = Registry.start_link(name: name, paths: [@fixtures_path])
      {:ok, registry: name}
    end

    test "lists all skills", %{registry: registry} do
      skills = Registry.list(registry)
      assert length(skills) == 2
    end

    test "gets a skill by name", %{registry: registry} do
      skill = Registry.get(registry, "pdf")
      assert skill.name == "pdf"
    end

    test "returns nil for unknown skill", %{registry: registry} do
      skill = Registry.get(registry, "unknown")
      assert skill == nil
    end

    test "counts skills", %{registry: registry} do
      count = Registry.count(registry)
      assert count == 2
    end

    test "registers new skills", %{registry: registry} do
      new_skill = %Skill{
        name: "test-skill",
        description: "A test skill",
        path: "/tmp/test"
      }

      :ok = Registry.register(registry, [new_skill])
      assert Registry.count(registry) == 3
      assert Registry.get(registry, "test-skill") != nil
    end

    test "reloads skills", %{registry: registry} do
      :ok = Registry.reload(registry)
      # Should still have the same skills after reload
      assert Registry.count(registry) == 2
    end
  end

  describe "pure functions" do
    test "index/1 creates a lookup map" do
      skills = [
        %Skill{name: "a", description: "A", path: "/a"},
        %Skill{name: "b", description: "B", path: "/b"}
      ]

      index = Registry.index(skills)

      assert Map.has_key?(index, "a")
      assert Map.has_key?(index, "b")
    end

    test "find/2 looks up a skill" do
      skills = [
        %Skill{name: "a", description: "A", path: "/a"},
        %Skill{name: "b", description: "B", path: "/b"}
      ]

      index = Registry.index(skills)

      assert Registry.find(index, "a").name == "a"
      assert Registry.find(index, "unknown") == nil
    end

    test "find_matching/2 finds skills by pattern" do
      skills = [
        %Skill{name: "pdf-extract", description: "A", path: "/a"},
        %Skill{name: "pdf-create", description: "B", path: "/b"},
        %Skill{name: "docx", description: "C", path: "/c"}
      ]

      matches = Registry.find_matching(skills, "pdf-*")

      assert length(matches) == 2
      assert Enum.all?(matches, &String.starts_with?(&1.name, "pdf-"))
    end
  end
end
