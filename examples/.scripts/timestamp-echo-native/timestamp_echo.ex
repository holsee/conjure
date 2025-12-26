defmodule Examples.Skills.TimestampEcho do
  @moduledoc """
  Native Elixir implementation of the timestamp-echo skill.

  Same behavior as the Python version - echoes a message with a timestamp.
  Runs directly in the BEAM with no external processes.
  """

  @behaviour Conjure.NativeSkill

  @impl true
  def __skill_info__ do
    %{
      name: "timestamp-echo",
      description: "Echo a message with the current timestamp",
      allowed_tools: [:execute]
    }
  end

  @impl true
  def execute(message, _context) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
    {:ok, "[#{timestamp}] #{message}"}
  end
end
