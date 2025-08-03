defmodule StackCoin.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      StackCoinWeb.Telemetry,
      StackCoin.Repo,
      StackCoin.Bot.Discord,
      {DNSCluster, query: Application.get_env(:stackcoin, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: StackCoin.PubSub},
      StackCoinWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: StackCoin.Supervisor]

    Supervisor.start_link(children, opts)
  end
end
