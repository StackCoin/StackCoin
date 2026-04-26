defmodule StackCoin.Core.BankHistoryTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Bank, User, Bot}

  setup do
    {:ok, owner} = User.create_user_account("900", "HistoryOwner", balance: 0)
    {:ok, bot} = Bot.create_bot_user("900", "HistoryBot")
    {:ok, _} = StackCoin.Core.Reserve.pump_reserve(owner.id, 1000, "test funding")
    {:ok, _} = Bank.transfer_between_users(1, bot.user.id, 500, "bot funding")

    {:ok, user1} = User.create_user_account("901", "HistoryUser1", balance: 0)
    {:ok, _} = Bank.transfer_between_users(bot.user.id, user1.id, 100, "tx1")
    {:ok, _} = Bank.transfer_between_users(bot.user.id, user1.id, 50, "tx2")

    %{user1: user1, bot: bot}
  end

  test "get_user_balance_history/1 returns full history", %{user1: user1} do
    {:ok, history} = Bank.get_user_balance_history(user1.id)
    # 2 transactions + 1 current-balance point = 3 entries
    assert length(history) == 3
  end

  test "get_user_balance_history/2 with since filters to recent", %{user1: user1} do
    since = ~N[2000-01-01 00:00:00]
    {:ok, history} = Bank.get_user_balance_history(user1.id, since: since)
    assert length(history) >= 3

    future = NaiveDateTime.add(NaiveDateTime.utc_now(), 3600, :second)
    {:ok, history_future} = Bank.get_user_balance_history(user1.id, since: future)
    assert length(history_future) == 2
    {_ts, balance} = hd(history_future)
    assert balance == user1.balance + 150
  end
end
