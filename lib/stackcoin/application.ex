defmodule StackCoin.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      StackcoinWeb.Telemetry,
      StackCoin.Repo,
      StackCoin.Bot.Discord,
      {DNSCluster, query: Application.get_env(:stackcoin, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Stackcoin.PubSub},
      StackcoinWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: StackCoin.Supervisor]

    Supervisor.start_link(children, opts)
  end
end
