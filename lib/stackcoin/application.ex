defmodule StackCoin.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      StackCoin.Repo,
      StackCoin.Bot.Discord
    ]

    opts = [strategy: :one_for_one, name: StackCoin.Supervisor]

    Supervisor.start_link(children, opts)
  end
end
