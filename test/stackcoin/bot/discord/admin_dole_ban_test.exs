defmodule StackCoinTest.Bot.Discord.AdminDoleBan do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.Admin
  alias StackCoin.Core.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  defp create_dole_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id) do
    create_mock_interaction(admin_user_id, guild_id, channel_id, %{
      options: [
        %{
          name: "dole-ban",
          options: [
            %{name: "user", value: target_user_id}
          ]
        }
      ]
    })
  end

  defp create_dole_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id) do
    create_mock_interaction(admin_user_id, guild_id, channel_id, %{
      options: [
        %{
          name: "dole-unban",
          options: [
            %{name: "user", value: target_user_id}
          ]
        }
      ]
    })
  end

  describe "dole-ban command" do
    test "admin can dole-ban an existing user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      interaction =
        create_dole_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

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
             assert String.contains?(embed.title, "Dole Banned")
             assert String.contains?(embed.description, "TargetUser")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.dole_banned == true
      assert user.banned == false
    end

    test "admin can dole-ban a user who does not have an account (pre-ban)" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      interaction =
        create_dole_ban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             cond do
               user_id == admin_user_id or user_id == to_string(admin_user_id) ->
                 {:ok, %{id: admin_user_id, username: "TestAdmin"}}

               user_id == target_user_id or user_id == to_string(target_user_id) ->
                 {:ok, %{id: target_user_id, username: "PreDoleBannedUser"}}

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
             assert String.contains?(embed.title, "Dole Banned")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.dole_banned == true
      assert user.banned == false
    end

    test "non-admin cannot dole-ban a user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      regular_user_id = 777_777_777
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")
      {:ok, _target} = User.create_user_account(target_user_id, "TargetUser")

      interaction =
        create_dole_ban_interaction(regular_user_id, guild_id, channel_id, target_user_id)

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

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.dole_banned == false
    end
  end

  describe "dole-unban command" do
    test "admin can dole-unban a dole-banned user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, target} = User.create_user_account(target_user_id, "TargetUser")
      {:ok, _banned} = User.dole_ban_user(target)

      interaction =
        create_dole_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

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
             assert String.contains?(embed.title, "Dole Unbanned")
             assert String.contains?(embed.description, "TargetUser")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end

      {:ok, user} = User.get_user_by_discord_id(target_user_id)
      assert user.dole_banned == false
    end

    test "dole-unban fails when target has no account" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      target_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      interaction =
        create_dole_unban_interaction(admin_user_id, guild_id, channel_id, target_user_id)

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
             assert String.contains?(response.data.content, "That user")
             {:ok}
           end
         ]}
      ]) do
        Admin.handle(interaction)
      end
    end
  end
end
