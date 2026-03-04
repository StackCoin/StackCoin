defmodule StackCoinWeb.BotSocket do
  use Phoenix.Socket

  channel("user:*", StackCoinWeb.BotChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case StackCoin.Core.Bot.get_bot_by_token(token) do
      {:ok, bot} ->
        {:ok, socket |> assign(:bot, bot) |> assign(:user, bot.user)}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user.id}"
end
