defmodule StackCoinTest.Bot.Discord.Admin do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.Admin
  alias StackCoin.Core.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  defp create_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id) do
    create_mock_interaction(admin_user_id, guild_id, channel_id, %{
      options: [
        %{
          name: "ban",
          options: [
            %{name: "user", value: target_user_id}
          ]
        }
      ]
    })
  end

  defp create_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id) do
    create_mock_interaction(admin_user_id, guild_id, channel_id, %{
      options: [
        %{
          name: "unban",
          options: [
            %{name: "user", value: target_user_id}
          ]
        }
      ]
    })
  end

  describe "ban command" do
    test "admin can ban an existing user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      interaction = create_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

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
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.embeds != nil
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "User Banned")
             assert String.contains?(embed.description, "TargetUser")
             assert String.contains?(embed.description, "has been banned")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      # Verify user is now banned
      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.banned == true
    end

    test "admin can ban a user who does not have a StackCoin account (pre-ban)" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      # Target user does NOT have a StackCoin account
      assert {:error, :user_not_found} = User.get_user_by_discord_id(target_user_id)

      interaction = create_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

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
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.embeds != nil
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "User Banned")
             assert String.contains?(embed.description, "PreBannedUser")
             assert String.contains?(embed.description, "has been banned")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      # Verify user account was created and is banned
      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.banned == true
      assert user.balance == 0
    end

    test "non-admin cannot ban a user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      regular_user_id = 777_777_777
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      interaction = create_ban_interaction(regular_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "don't have permission")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      # Verify target user is NOT banned
      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.banned == false
    end
  end

  describe "unban command" do
    test "admin can unban a banned user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, target} = User.create_user_account(target_user_id, "TargetUser")
      {:ok, _banned} = User.ban_user(target)

      interaction = create_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

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
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.embeds != nil
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "User Unbanned")
             assert String.contains?(embed.description, "TargetUser")
             assert String.contains?(embed.description, "has been unbanned")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      # Verify user is now unbanned
      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.banned == false
    end

    test "unban fails with clear message when target user has no account" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      # Target user does NOT have a StackCoin account
      assert {:error, :user_not_found} = User.get_user_by_discord_id(target_user_id)

      interaction = create_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

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
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             # Should say "That user doesn't have a StackCoin account yet."
             # NOT "You don't have a StackCoin account yet."
             assert String.contains?(response.data.content, "That user")
             assert String.contains?(response.data.content, "doesn't have a StackCoin account")
             refute String.contains?(response.data.content, "Use `/dole` to get started")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end
    end

    test "non-admin cannot unban a user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      regular_user_id = 777_777_777
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, target} = User.create_user_account(target_user_id, "TargetUser")
      {:ok, _banned} = User.ban_user(target)

      interaction =
        create_unban_interaction(regular_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "don't have permission")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      # Verify target user is still banned
      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.banned == true
    end
  end

  describe "ban then unban flow" do
    test "admin can ban and then unban a user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      nostrum_mock =
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

      # Ban the user
      ban_interaction =
        create_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        nostrum_mock,
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "User Banned")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(ban_interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.banned == true

      # Unban the user
      unban_interaction =
        create_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        nostrum_mock,
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "User Unbanned")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(unban_interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.banned == false
    end
  end
end
