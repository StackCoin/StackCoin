defmodule StackCoinWeb.BotChannelTest do
  use StackCoinWeb.ConnCase

  import Phoenix.ChannelTest

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Event}

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

  test "rejects join when too many events are missed", %{
    bot: bot,
    bot_token: bot_token
  } do
    # Setup already creates 1 event for bot.user (receiver of funding transfer)
    # Create 100 more to reach 101 total, which exceeds the replay limit of 100
    for _ <- 1..100 do
      Event.create_event("transfer.completed", bot.user.id, %{
        transaction_id: 1,
        from_id: bot.user.id,
        to_id: 999,
        amount: 1,
        role: "sender"
      })
    end

    {:ok, socket} =
      Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    assert {:error, %{reason: "too_many_missed_events"} = error} =
             Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})

    assert error.missed_count == 101
    assert error.replay_limit == 100
  end

  test "allows join when missed events are at the replay limit", %{
    bot: bot,
    bot_token: bot_token
  } do
    # Setup already creates 1 event for bot.user (receiver of funding transfer)
    # Create 99 more to reach exactly 100 total, which is at the replay limit
    for _ <- 1..99 do
      Event.create_event("transfer.completed", bot.user.id, %{
        transaction_id: 1,
        from_id: bot.user.id,
        to_id: 999,
        amount: 1,
        role: "sender"
      })
    end

    {:ok, socket} =
      Phoenix.ChannelTest.connect(StackCoinWeb.BotSocket, %{"token" => bot_token})

    assert {:ok, _reply, _socket} =
             Phoenix.ChannelTest.join(socket, "user:#{bot.user.id}", %{"last_event_id" => 0})
  end
end
