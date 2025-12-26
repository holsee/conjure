defmodule Conjure.BackendTest do
  use ExUnit.Case, async: true

  alias Conjure.Backend

  describe "get/1" do
    test "returns Local backend for :local" do
      assert Backend.get(:local) == Conjure.Backend.Local
    end

    test "returns Docker backend for :docker" do
      assert Backend.get(:docker) == Conjure.Backend.Docker
    end

    test "returns Anthropic backend for :anthropic" do
      assert Backend.get(:anthropic) == Conjure.Backend.Anthropic
    end

    test "returns Native backend for :native" do
      assert Backend.get(:native) == Conjure.Backend.Native
    end

    test "returns nil for unknown type" do
      assert Backend.get(:unknown) == nil
    end
  end

  describe "available/0" do
    test "returns all available backend types" do
      assert Backend.available() == [:local, :docker, :anthropic, :native]
    end
  end
end
