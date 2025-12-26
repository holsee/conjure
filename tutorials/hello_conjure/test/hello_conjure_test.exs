defmodule HelloConjureTest do
  use ExUnit.Case
  doctest HelloConjure

  test "greets the world" do
    assert HelloConjure.hello() == :world
  end
end
