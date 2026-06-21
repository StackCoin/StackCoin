defmodule StackCoin.Core.PreauthorizationTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Preauthorization, User, Bot, Reserve, Bank}

  setup do
    # Create reserve user (ID 1)
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 0)

    # Create owner
    {:ok, owner} = User.create_user_account("100", "Owner", balance: 0)

    # Pump reserve
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 5000, "Test funding")

    # Create bot (creates bot_user record + user record)
    {:ok, bot} = Bot.create_bot_user("100", "TestBot")

    # Fund bot
    {:ok, _tx} = Bank.transfer_between_users(1, bot.user.id, 500, "Bot funding")

    # Create regular user
    {:ok, user} = User.create_user_account("200", "TestUser", balance: 0)

    # Fund user
    {:ok, _tx} = Bank.transfer_between_users(1, user.id, 500, "User funding")

    %{bot: bot, user: user, owner: owner}
  end

  describe "create_preauth/4" do
    test "creates a pending preauth with correct fields", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)

      assert preauth.status == "pending"
      assert preauth.max_amount == 100
      assert preauth.window_hours == 24
      assert preauth.bot_user_id == bot.user.id
      assert preauth.user_id == user.id
      assert preauth.requested_at != nil
      assert preauth.approved_at == nil
    end

    test "rejects duplicate when active/pending preauth already exists", %{bot: bot, user: user} do
      {:ok, _preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)

      assert {:error, :preauth_already_exists} =
               Preauthorization.create_preauth(bot.user.id, user.id, 200, 48)
    end

    test "allows new preauth after old one is revoked", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)
      {:ok, _revoked} = Preauthorization.revoke_preauth(preauth.id)

      {:ok, new_preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 200, 48)
      assert new_preauth.max_amount == 200
      assert new_preauth.window_hours == 48
    end

    test "rejects non-bot user_id as bot_user_id", %{user: user} do
      assert {:error, :not_bot_user} = Preauthorization.create_preauth(user.id, user.id, 100, 24)
    end

    test "rejects invalid max_amount (0)", %{bot: bot, user: user} do
      assert {:error, _} = Preauthorization.create_preauth(bot.user.id, user.id, 0, 24)
    end

    test "rejects invalid max_amount (negative)", %{bot: bot, user: user} do
      assert {:error, _} = Preauthorization.create_preauth(bot.user.id, user.id, -10, 24)
    end

    test "rejects invalid window_hours (0)", %{bot: bot, user: user} do
      assert {:error, _} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 0)
    end
  end

  describe "approve_preauth/1" do
    test "approves pending preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, approved} = Preauthorization.approve_preauth(preauth.id)

      assert approved.status == "active"
      assert approved.approved_at != nil
    end

    test "rejects approving non-pending preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)

      assert {:error, :preauth_not_pending} = Preauthorization.approve_preauth(preauth.id)
    end
  end

  describe "revoke_preauth/1" do
    test "revokes active preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)
      {:ok, revoked} = Preauthorization.revoke_preauth(preauth.id)

      assert revoked.status == "revoked"
      assert revoked.revoked_at != nil
    end

    test "rejects revoking pending preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)

      assert {:error, :preauth_not_active} = Preauthorization.revoke_preauth(preauth.id)
    end
  end

  describe "delete_preauth/1" do
    test "hard-deletes pending preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _deleted} = Preauthorization.delete_preauth(preauth.id)

      assert {:error, :preauth_not_found} = Preauthorization.get_preauth(preauth.id)
    end

    test "rejects deleting active preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)

      assert {:error, :preauth_not_pending} = Preauthorization.delete_preauth(preauth.id)
    end
  end

  describe "get_remaining_budget/1" do
    test "fresh preauth has full budget", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)

      {:ok, remaining} = Preauthorization.get_remaining_budget(preauth.id)
      assert remaining == 100
    end
  end

  describe "get_active_preauth/2" do
    test "returns active preauth for bot+user pair", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)

      {:ok, active} = Preauthorization.get_active_preauth(bot.user.id, user.id)
      assert active.id == preauth.id
      assert active.status == "active"
    end

    test "returns error when none exists", %{bot: bot, user: user} do
      assert {:error, :no_active_preauth} =
               Preauthorization.get_active_preauth(bot.user.id, user.id)
    end

    test "returns error for revoked preauth", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _approved} = Preauthorization.approve_preauth(preauth.id)
      {:ok, _revoked} = Preauthorization.revoke_preauth(preauth.id)

      assert {:error, :no_active_preauth} =
               Preauthorization.get_active_preauth(bot.user.id, user.id)
    end
  end

  describe "list_preauths/1" do
    test "lists all preauths for a bot", %{bot: bot, user: user} do
      {:ok, user2} = User.create_user_account("300", "TestUser2", balance: 0)
      {:ok, _tx} = Bank.transfer_between_users(1, user2.id, 500, "User2 funding")

      {:ok, _p1} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _p2} = Preauthorization.create_preauth(bot.user.id, user2.id, 200, 48)

      preauths = Preauthorization.list_preauths(bot.user.id)
      assert length(preauths) == 2
    end

    test "filters by user_id option", %{bot: bot, user: user} do
      {:ok, user2} = User.create_user_account("301", "TestUser3", balance: 0)
      {:ok, _tx} = Bank.transfer_between_users(1, user2.id, 500, "User3 funding")

      {:ok, _p1} = Preauthorization.create_preauth(bot.user.id, user.id, 100, 24)
      {:ok, _p2} = Preauthorization.create_preauth(bot.user.id, user2.id, 200, 48)

      preauths = Preauthorization.list_preauths(bot.user.id, user_id: user.id)
      assert length(preauths) == 1
      assert hd(preauths).user_id == user.id
    end
  end

  describe "check_budget/2" do
    test "returns ok with remaining when within budget", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, preauth} = Preauthorization.approve_preauth(preauth.id)

      assert {:ok, 5} = Preauthorization.check_budget(preauth, 5)
    end

    test "returns ok with 0 remaining at exact max", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, preauth} = Preauthorization.approve_preauth(preauth.id)

      assert {:ok, 0} = Preauthorization.check_budget(preauth, 10)
    end

    test "returns error when amount exceeds budget", %{bot: bot, user: user} do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, user.id, 10, 24)
      {:ok, preauth} = Preauthorization.approve_preauth(preauth.id)

      assert {:error, :preauth_limit_exceeded} = Preauthorization.check_budget(preauth, 11)
    end
  end
end
