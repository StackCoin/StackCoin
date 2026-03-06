defmodule StackCoin.SchedulerTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Idempotency, User, Bot}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, _owner} = User.create_user_account("owner1", "Owner1")
    {:ok, bot} = Bot.create_bot_user("owner1", "Bot1")
    %{bot: bot}
  end

  test "cleanup message triggers delete_expired", %{bot: bot} do
    :ok = Idempotency.store(bot.id, "old-key", 200, ~s({"old": true}))

    # Backdate the record to 8 days ago
    eight_days_ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-8, :day)

    from(k in StackCoin.Schema.IdempotencyKey,
      where: k.bot_id == ^bot.id and k.key == "old-key"
    )
    |> StackCoin.Repo.update_all(set: [inserted_at: eight_days_ago])

    # Trigger cleanup on the app-managed scheduler and wait for it to process
    send(StackCoin.Scheduler, :cleanup)
    :sys.get_state(StackCoin.Scheduler)

    assert :miss = Idempotency.check(bot.id, "old-key")
  end

  test "scheduler is running in the supervision tree" do
    assert Process.whereis(StackCoin.Scheduler) != nil
  end
end
