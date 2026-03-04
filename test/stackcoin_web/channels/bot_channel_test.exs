defmodule StackCoinWeb.BotChannelTest do
  use StackCoinWeb.ConnCase

  import Phoenix.ChannelTest

  alias StackCoin.Core.{User, Bot, Bank, Reserve}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{bot: bot, recipient: recipient, bot_token: bot.token}
  end

  test "can connect with valid bot token", %{bot_token: bot_token} do
    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    assert socket.assigns.bot.token == bot_token
  end

  test "rejects connection with invalid token" do
    assert :error = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => "invalid"})
  end

  test "rejects connection without token" do
    assert :error = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{})
  end

  test "can join user channel matching own user_id", %{bot: bot, bot_token: bot_token} do
    {:ok, socket} = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    assert {:ok, _reply, _socket} =
             Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})
  end

  test "cannot join another user's channel", %{bot_token: bot_token} do
    {:ok, socket} = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    assert {:error, %{reason: "unauthorized"}} =
             Phoenix.ChannelTest.join(socket, "user:99999", %{"last_event_id" => 0})
  end

  test "receives events in real-time after joining", %{
    bot: bot,
    bot_token: bot_token,
    recipient: recipient
  } do
    {:ok, socket} = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    {:ok, _reply, _socket} =
      Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})

    # Perform a transfer that should generate an event
    {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 10, "ws test")

    # Should receive the event via the channel
    assert_push("event", %{type: "transfer.completed", data: %{"amount" => 10}})
  end

  test "replays missed events on join", %{bot: bot, bot_token: bot_token, recipient: recipient} do
    # Create some events BEFORE connecting
    {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 5, "before connect")

    {:ok, socket} = Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    {:ok, _reply, _socket} =
      Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})

    # Should receive replayed events
    assert_push("event", %{type: "transfer.completed"})
  end
end
