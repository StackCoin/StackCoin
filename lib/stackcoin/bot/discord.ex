defmodule StackCoin.Bot.Discord do
  use Nostrum.Consumer

  alias Nostrum.Api.Message

  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    case msg.content do
      "!hello" ->
        {:ok, _message} = Message.create(msg.channel_id, "Hello, world!")

      _ ->
        :ignore
    end
  end

  def handle_event(_), do: :ok
end
