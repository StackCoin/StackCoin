defmodule StackCoin.Core.StressTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Request, Preauthorization}

  # Longer timeout for stress tests
  @moduletag timeout: 60_000

  setup do
    # Reserve user (ID 1) is seeded by migrations; create a discord-linked owner
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 0)
    {:ok, owner} = User.create_user_account("100", "Owner", balance: 0)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 10_000, "Stress test funding")

    {:ok, bot} = Bot.create_bot_user("100", "StressBot")
    {:ok, _txn} = Bank.transfer_between_users(1, bot.user.id, 2000, "Bot funding")

    # Create 5 regular users with 500 STK each
    users =
      for i <- 1..5 do
        {:ok, user} = User.create_user_account("#{200 + i}", "StressUser#{i}", balance: 0)
        {:ok, _txn} = Bank.transfer_between_users(1, user.id, 500, "User#{i} funding")
        user
      end

    # Snapshot initial ledger state after setup (accounts for any pre-existing stale data)
    initial_balance_sum = total_balance_sum()
    initial_pump_sum = total_pump_sum()

    %{
      bot: bot,
      users: users,
      owner: owner,
      initial_balance_sum: initial_balance_sum,
      initial_pump_sum: initial_pump_sum
    }
  end

  describe "concurrent transfer stress" do
    test "transfers never overdraw sender balance", ctx do
      %{bot: bot, users: users} = ctx
      recipient = hd(users)
      amount = 60
      num_tasks = 40

      tasks =
        for _ <- 1..num_tasks do
          Task.async(fn ->
            Bank.transfer_between_users(bot.user.id, recipient.id, amount, "stress-transfer")
          end)
        end

      results = Task.await_many(tasks, 30_000)

      successes = Enum.count(results, &match?({:ok, _}, &1))

      # Verify no overdraw
      {:ok, bot_balance} = Bank.get_user_balance(bot.user.id)
      assert bot_balance >= 0
      assert bot_balance == 2000 - successes * amount

      # All failures should be insufficient_balance (or possibly SQLITE_BUSY wrapped)
      for {:error, reason} <- results do
        assert reason in [:insufficient_balance, :busy],
               "Unexpected error reason: #{inspect(reason)}"
      end

      # Transfers are zero-sum: total balances must not have changed
      assert_balances_unchanged(ctx)
    end
  end

  describe "concurrent request accepts" do
    test "concurrent request accepts charge exactly once", ctx do
      %{bot: bot, users: users} = ctx
      user = hd(users)
      {:ok, request} = Request.create_request(bot.user.id, user.id, 50, "stress-request")

      {:ok, fresh_user} = User.get_user_by_id(user.id)
      initial_user_balance = fresh_user.balance

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Request.accept_request(request.id, user.id)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      assert length(successes) == 1, "Expected exactly 1 success, got #{length(successes)}"

      # User paid exactly once
      {:ok, updated_user} = User.get_user_by_id(user.id)
      assert updated_user.balance == initial_user_balance - 50

      assert_balances_unchanged(ctx)
    end
  end

  describe "concurrent preauth transfers" do
    test "concurrent preauth transfers respect budget", ctx do
      %{bot: bot, users: users} = ctx
      user = hd(users)
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Request.create_request_with_preauth(
              bot.user.id,
              user.id,
              3,
              "preauth-stress-#{i}"
            )
          end)
        end

      results = Task.await_many(tasks, 30_000)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      spent = length(successes) * 3

      # Budget check is now inside the transaction, so concurrent calls
      # are serialized and the budget cannot be exceeded.
      assert spent <= 10, "Budget exceeded: spent #{spent} > max_amount 10"
      assert length(successes) <= 3, "More than 3 transfers of 3 STK against 10 budget"

      {:ok, remaining} = Preauthorization.get_remaining_budget(preauth.id)
      assert remaining >= 0
      assert remaining == 10 - spent

      # No negative balances for the user paying via preauth
      {:ok, user_balance} = Bank.get_user_balance(user.id)
      assert user_balance >= 0, "User balance went negative: #{user_balance}"

      assert_balances_unchanged(ctx)
    end
  end

  describe "mixed concurrent operations" do
    test "mixed concurrent operations maintain ledger consistency", ctx do
      %{bot: bot, users: users} = ctx
      [user1, user2, user3, user4, user5] = users

      # Set up a preauth for user1
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user1.id, 50, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)

      # Create some requests
      {:ok, req1} = Request.create_request(bot.user.id, user2.id, 10, "mixed-req-1")
      {:ok, req2} = Request.create_request(bot.user.id, user3.id, 10, "mixed-req-2")

      # Direct transfers from bot
      # Preauth transfers
      # Request accepts
      # User-to-user transfers
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Bank.transfer_between_users(bot.user.id, user4.id, 5, "mixed-transfer-#{i}")
          end)
        end ++
          for i <- 1..5 do
            Task.async(fn ->
              Request.create_request_with_preauth(
                bot.user.id,
                user1.id,
                5,
                "mixed-preauth-#{i}"
              )
            end)
          end ++
          [
            Task.async(fn -> Request.accept_request(req1.id, user2.id) end),
            Task.async(fn -> Request.accept_request(req2.id, user3.id) end)
          ] ++
          for i <- 1..3 do
            Task.async(fn ->
              Bank.transfer_between_users(user5.id, user4.id, 10, "user-transfer-#{i}")
            end)
          end

      _results = Task.await_many(tasks, 30_000)

      # All transfers are zero-sum: total balances must not have changed
      assert_balances_unchanged(ctx)

      # No negative balances
      for user <- [bot.user | users] do
        {:ok, balance} = Bank.get_user_balance(user.id)

        assert balance >= 0,
               "User #{user.id} (#{user.username}) has negative balance: #{balance}"
      end
    end
  end

  describe "rapid back-and-forth transfers" do
    test "rapid back-and-forth transfers maintain consistency", ctx do
      %{users: users} = ctx
      [user1, user2 | _] = users
      num_tasks = 20

      tasks =
        for i <- 1..num_tasks do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              Bank.transfer_between_users(user1.id, user2.id, 1, "ping-#{i}")
            else
              Bank.transfer_between_users(user2.id, user1.id, 1, "pong-#{i}")
            end
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # Count successes in each direction
      indexed_results = Enum.zip(1..num_tasks, results)

      u1_to_u2 =
        Enum.count(indexed_results, fn {i, result} ->
          rem(i, 2) == 0 and match?({:ok, _}, result)
        end)

      u2_to_u1 =
        Enum.count(indexed_results, fn {i, result} ->
          rem(i, 2) != 0 and match?({:ok, _}, result)
        end)

      {:ok, b1} = Bank.get_user_balance(user1.id)
      {:ok, b2} = Bank.get_user_balance(user2.id)

      # Conservation: both users started with 500 each
      assert b1 + b2 == 1000,
             "Balance sum should be 1000, got #{b1} + #{b2} = #{b1 + b2}"

      # Net balance should be consistent with transfer counts
      # user1 sends u1_to_u2 and receives u2_to_u1
      expected_b1 = 500 - u1_to_u2 + u2_to_u1

      assert b1 == expected_b1,
             "User1 balance #{b1} != expected #{expected_b1} (sent #{u1_to_u2}, received #{u2_to_u1})"

      assert_balances_unchanged(ctx)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp total_balance_sum do
    StackCoin.Repo.one(from(u in StackCoin.Schema.User, select: coalesce(sum(u.balance), 0)))
  end

  defp total_pump_sum do
    StackCoin.Repo.one(from(p in StackCoin.Schema.Pump, select: coalesce(sum(p.amount), 0)))
  end

  defp assert_balances_unchanged(%{
         initial_balance_sum: initial_balance,
         initial_pump_sum: initial_pump
       }) do
    current_balance = total_balance_sum()
    current_pump = total_pump_sum()

    # No new pumps should have been created during concurrent operations
    assert current_pump == initial_pump,
           "Pump sum changed! before=#{initial_pump} after=#{current_pump}"

    # All concurrent operations are zero-sum transfers, so total balances must not change
    assert current_balance == initial_balance,
           "LEDGER INCONSISTENT! Total balances changed: before=#{initial_balance} after=#{current_balance}"
  end
end
