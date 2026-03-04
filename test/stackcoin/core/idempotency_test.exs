defmodule StackCoin.Core.IdempotencyTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Idempotency, User, Bot}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, _owner} = User.create_user_account("owner1", "Owner1")
    {:ok, bot1} = Bot.create_bot_user("owner1", "Bot1")
    {:ok, _owner2} = User.create_user_account("owner2", "Owner2")
    {:ok, bot2} = Bot.create_bot_user("owner2", "Bot2")

    %{bot1: bot1, bot2: bot2}
  end

  test "stores and retrieves a response", %{bot1: bot1} do
    assert :miss = Idempotency.check(bot1.id, "key-1")

    :ok = Idempotency.store(bot1.id, "key-1", 200, ~s({"success": true}))

    assert {:hit, 200, ~s({"success": true})} = Idempotency.check(bot1.id, "key-1")
  end

  test "different bots can use the same key", %{bot1: bot1, bot2: bot2} do
    :ok = Idempotency.store(bot1.id, "shared-key", 200, ~s({"bot": 1}))
    assert :miss = Idempotency.check(bot2.id, "shared-key")
  end

  test "returns miss for unknown key", %{bot1: bot1} do
    assert :miss = Idempotency.check(bot1.id, "nonexistent")
  end
end
