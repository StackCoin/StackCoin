defmodule StackCoin.Scheduler do
  @moduledoc """
  Periodic maintenance tasks.

  Runs cleanup jobs on a timer using `Process.send_after/3`.
  Currently handles:

  - Idempotency key expiry (every 6 hours, deletes keys older than 7 days)
  """
  use GenServer
  require Logger

  @cleanup_interval :timer.hours(6)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @cleanup_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    count = StackCoin.Core.Idempotency.delete_expired()

    if count > 0 do
      Logger.info("Scheduler: deleted #{count} expired idempotency key(s)")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end
