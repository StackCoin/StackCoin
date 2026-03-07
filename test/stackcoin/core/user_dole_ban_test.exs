defmodule StackCoinTest.Core.UserDoleBanTest do
  use ExUnit.Case
  import Mock
  alias StackCoin.Core.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  describe "dole_ban_user/1" do
    test "sets dole_banned to true" do
      {:ok, user} = User.create_user_account(111_111_111, "TestUser")
      assert user.dole_banned == false

      {:ok, updated} = User.dole_ban_user(user)
      assert updated.dole_banned == true
    end
  end

  describe "dole_unban_user/1" do
    test "sets dole_banned to false" do
      {:ok, user} = User.create_user_account(111_111_111, "TestUser")
      {:ok, banned} = User.dole_ban_user(user)
      assert banned.dole_banned == true

      {:ok, unbanned} = User.dole_unban_user(banned)
      assert unbanned.dole_banned == false
    end
  end

  describe "check_user_dole_banned/1" do
    test "returns ok for non-dole-banned user" do
      {:ok, user} = User.create_user_account(111_111_111, "TestUser")
      assert {:ok, :not_dole_banned} = User.check_user_dole_banned(user)
    end

    test "returns error for dole-banned user" do
      {:ok, user} = User.create_user_account(111_111_111, "TestUser")
      {:ok, banned} = User.dole_ban_user(user)
      assert {:error, :user_dole_banned} = User.check_user_dole_banned(banned)
    end
  end

  describe "admin_dole_ban_user/2" do
    test "admin can dole-ban an existing user" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}

               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "TargetUser"}}

               true ->
                 {:error, :not_found}
             end
           end
         ]}
      ]) do
        {:ok, _admin} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)
        {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

        {:ok, result} = User.admin_dole_ban_user(admin_user_id, target_user_id)
        assert result.dole_banned == true
      end
    end

    test "admin can dole-ban a user who does not have an account (pre-ban)" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}

               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "PreBannedUser"}}

               true ->
                 {:error, :not_found}
             end
           end
         ]}
      ]) do
        {:ok, _admin} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)

        {:ok, result} = User.admin_dole_ban_user(admin_user_id, target_user_id)
        assert result.dole_banned == true

        # Verify account was created
        {:ok, user} = User.get_user_by_discord_id(target_user_id)
        assert user.dole_banned == true
        assert user.banned == false
      end
    end

    test "non-admin cannot dole-ban a user" do
      regular_user_id = 777_777_777
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, "999999999")
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      assert {:error, :not_admin} = User.admin_dole_ban_user(regular_user_id, target_user_id)
    end
  end

  describe "admin_dole_unban_user/2" do
    test "admin can dole-unban a dole-banned user" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}

               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "TargetUser"}}

               true ->
                 {:error, :not_found}
             end
           end
         ]}
      ]) do
        {:ok, _admin} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)
        {:ok, target} = User.create_user_account(target_user_id, "TargetUser")
        {:ok, _banned} = User.dole_ban_user(target)

        {:ok, result} = User.admin_dole_unban_user(admin_user_id, target_user_id)
        assert result.dole_banned == false
      end
    end

    test "dole-unban fails when target has no account" do
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}

               true ->
                 {:error, :not_found}
             end
           end
         ]}
      ]) do
        {:ok, _admin} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)

        assert {:error, :other_user_not_found} =
                 User.admin_dole_unban_user(admin_user_id, target_user_id)
      end
    end

    test "non-admin cannot dole-unban a user" do
      regular_user_id = 777_777_777
      target_user_id = 888_888_888

      Application.put_env(:stackcoin, :admin_user_id, "999999999")
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, target} = User.create_user_account(target_user_id, "TargetUser")
      {:ok, _banned} = User.dole_ban_user(target)

      assert {:error, :not_admin} = User.admin_dole_unban_user(regular_user_id, target_user_id)
    end
  end
end
