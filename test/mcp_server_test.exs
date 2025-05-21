defmodule McpServerTest do
  use ExUnit.Case
  doctest McpServer

  test "greets the world" do
    assert McpServer.hello() == :world
  end
end
