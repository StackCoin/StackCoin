defmodule StackCoin.Core.PreauthRequestTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Preauthorization, Request, User, Bot, Reserve, Bank}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 0)
    {:ok, owner} = User.create_user_account("100", "Owner", balance: 0)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 5000, "Test funding")

    {:ok, bot} = Bot.create_bot_user("100", "TestBot")
    {:ok, _txn} = Bank.transfer_between_users(1, bot.user.id, 500, "Bot funding")

    {:ok, user} = User.create_user_account("200", "TestUser", balance: 0)
    {:ok, _txn} = Bank.transfer_between_users(1, user.id, 500, "User funding")

    # Create and approve a preauth: 10 STK per 24 hours
    {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
    {:ok, preauth} = Preauthorization.approve_preauth(preauth.id)

    %{bot: bot, user: user, preauth: preauth}
  end

  describe "create_request_with_preauth/4" do
    test "instant transfer with active preauth", %{bot: bot, user: user, preauth: preauth} do
      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, user.id, 5, "Test label")

      assert request.status == "accepted"
      assert request.preauthorization_id == preauth.id
      assert request.transaction_id != nil
      assert request.amount == 5

      # User balance should have decreased (500 - 5 = 495)
      {:ok, updated_user} = User.get_user_by_id(user.id)
      assert updated_user.balance == 495

      # Bot balance should have increased (500 + 5 = 505)
      {:ok, updated_bot} = User.get_user_by_id(bot.user.id)
      assert updated_bot.balance == 505
    end

    test "budget decreases after transfer", %{bot: bot, user: user} do
      {:ok, _} = Request.create_request_with_preauth(bot.user.id, user.id, 5, "First")
      {:ok, _} = Request.create_request_with_preauth(bot.user.id, user.id, 5, "Second")

      # Budget should now be 0 — next request exceeds limit
      assert {:error, :preauth_limit_exceeded} =
               Request.create_request_with_preauth(bot.user.id, user.id, 1, "Third")
    end

    test "exact max_amount succeeds", %{bot: bot, user: user} do
      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, user.id, 10, "Max")

      assert request.status == "accepted"
    end

    test "exceeds max_amount fails", %{bot: bot, user: user} do
      assert {:error, :preauth_limit_exceeded} =
               Request.create_request_with_preauth(bot.user.id, user.id, 11, "Over")
    end

    test "insufficient balance returns error", %{bot: bot, user: user} do
      # Drain user's balance
      {:ok, _txn} = Bank.transfer_between_users(user.id, 1, 500, "drain")

      assert {:error, :insufficient_balance} =
               Request.create_request_with_preauth(bot.user.id, user.id, 5, "No funds")
    end

    test "no active preauth falls back to pending request", %{bot: bot} do
      {:ok, other_user} = User.create_user_account("300", "Other", balance: 0)
      {:ok, _txn} = Bank.transfer_between_users(1, other_user.id, 100, "Fund other")

      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, other_user.id, 5, "Fallback")

      assert request.status == "pending"
      assert request.preauthorization_id == nil
    end

    test "revoked preauth falls back to pending", %{bot: bot, user: user, preauth: preauth} do
      {:ok, _} = Preauthorization.revoke_preauth(preauth.id)

      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, user.id, 5, "After revoke")

      assert request.status == "pending"
      assert request.preauthorization_id == nil
    end

    test "pending preauth falls back to pending request", %{bot: bot} do
      {:ok, other_user} = User.create_user_account("400", "PendingUser", balance: 0)
      {:ok, _txn} = Bank.transfer_between_users(1, other_user.id, 100, "Fund")

      {:ok, _pending_preauth} =
        Preauthorization.create_preauth(bot.user.id, other_user.id, 10, 24)

      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, other_user.id, 5, "Pending preauth")

      assert request.status == "pending"
    end

    test "preauth request links via preauthorization_id", %{
      bot: bot,
      user: user,
      preauth: preauth
    } do
      {:ok, request} =
        Request.create_request_with_preauth(bot.user.id, user.id, 5, "Linked")

      assert request.preauthorization_id == preauth.id
      loaded = StackCoin.Repo.preload(request, :preauthorization)
      assert loaded.preauthorization.id == preauth.id
    end
  end
end
