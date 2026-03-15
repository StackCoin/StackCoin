defmodule StackCoin.Core.IdempotencyTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Idempotency, User, Bot}

  setup do
    # Clear any pre-existing idempotency keys so delete_expired counts are predictable
    Repo.delete_all(StackCoin.Schema.IdempotencyKey)

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

  describe "delete_expired/0" do
    test "deletes keys older than 7 days", %{bot1: bot1} do
      :ok = Idempotency.store(bot1.id, "old-key", 200, ~s({"old": true}))

      # Backdate the record to 8 days ago
      eight_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-8, :day)

      from(k in StackCoin.Schema.IdempotencyKey,
        where: k.bot_id == ^bot1.id and k.key == "old-key"
      )
      |> StackCoin.Repo.update_all(set: [inserted_at: eight_days_ago])

      assert 1 = Idempotency.delete_expired()
      assert :miss = Idempotency.check(bot1.id, "old-key")
    end

    test "preserves keys newer than 7 days", %{bot1: bot1} do
      :ok = Idempotency.store(bot1.id, "fresh-key", 200, ~s({"fresh": true}))

      assert 0 = Idempotency.delete_expired()
      assert {:hit, 200, _} = Idempotency.check(bot1.id, "fresh-key")
    end

    test "deletes only expired keys, keeps fresh ones", %{bot1: bot1, bot2: bot2} do
      :ok = Idempotency.store(bot1.id, "old-key", 200, ~s({"old": true}))
      :ok = Idempotency.store(bot2.id, "fresh-key", 200, ~s({"fresh": true}))

      # Backdate only bot1's key
      eight_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-8, :day)

      from(k in StackCoin.Schema.IdempotencyKey, where: k.bot_id == ^bot1.id)
      |> StackCoin.Repo.update_all(set: [inserted_at: eight_days_ago])

      assert 1 = Idempotency.delete_expired()
      assert :miss = Idempotency.check(bot1.id, "old-key")
      assert {:hit, 200, _} = Idempotency.check(bot2.id, "fresh-key")
    end
  end
end
