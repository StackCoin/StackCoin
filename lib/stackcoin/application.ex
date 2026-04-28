defmodule StackCoin.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        StackCoinWeb.Telemetry,
        StackCoin.Repo,
        StackCoin.Scheduler
      ] ++
        discord_children() ++
        [
          {DNSCluster, query: Application.get_env(:stackcoin, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: StackCoin.PubSub},
          StackCoinWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: StackCoin.Supervisor]

    Supervisor.start_link(children, opts)
  end

  defp discord_children do
    if Application.get_env(:stackcoin, :start_discord, true) do
      token = Application.get_env(:stackcoin, :discord_token)

      bot_options = %{
        consumer: StackCoin.Bot.Discord,
        intents: [:guilds, :guild_messages, :message_content],
        wrapped_token: fn -> token end
      }

      [{Nostrum.Bot, bot_options}]
    else
      []
    end
  end
end
