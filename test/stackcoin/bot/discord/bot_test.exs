defmodule StackCoinTest.Bot.Discord.Bot do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.Bot, as: BotCommand
  alias StackCoin.Core.{Bot, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  defp create_bot_interaction(user_id, guild_id, channel_id, subcommand, options \\ []) do
    create_mock_interaction(user_id, guild_id, channel_id, %{
      options: [
        %{
          name: subcommand,
          options: Enum.map(options, fn {name, value} -> %{name: name, value: value} end)
        }
      ]
    })
  end

  defp nostrum_api_mocks(admin_user_id, response_fn) do
    [
      {Nostrum.Api.User, [],
       [
         get: fn user_id ->
           if user_id == admin_user_id or user_id == to_string(admin_user_id) do
             {:ok, %{id: admin_user_id, username: "TestAdmin"}}
           else
             {:error, :not_found}
           end
         end,
         create_dm: fn _user_id -> {:ok, %{id: 12345}} end
       ]},
      {Nostrum.Api.Message, [],
       [
         create: fn _channel_id, _message -> {:ok, %{id: 0}} end
       ]},
      {Nostrum.Api, [],
       [
         create_interaction_response: response_fn
       ]}
    ]
  end

  describe "create subcommand" do
    test "admin can create a bot and receives token via DM" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      interaction =
        create_bot_interaction(admin_user_id, guild_id, channel_id, "create", [{"name", "MyBot"}])

      dm_sent = :ets.new(:dm_sent, [:set, :public])
      :ets.insert(dm_sent, {:sent, false})

      with_mocks([
        {Nostrum.Api.User, [],
         [
           get: fn user_id ->
             if user_id == admin_user_id or user_id == to_string(admin_user_id) do
               {:ok, %{id: admin_user_id, username: "TestAdmin"}}
             else
               {:error, :not_found}
             end
           end,
           create_dm: fn _user_id -> {:ok, %{id: 12345}} end
         ]},
        {Nostrum.Api.Message, [],
         [
           create: fn _channel_id, message ->
             # Verify DM contains the token in spoiler tags
             embed = hd(message.embeds)
             assert String.contains?(embed.title, "Bot Token")
             assert String.contains?(embed.description, "MyBot")
             assert String.contains?(embed.description, "||")
             assert String.contains?(embed.description, "Authorization: Bearer")
             :ets.insert(dm_sent, {:sent, true})
             {:ok, %{id: 0}}
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "Bot Created")
             assert String.contains?(embed.description, "MyBot")
             assert String.contains?(embed.description, "direct message")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end

      [{:sent, was_sent}] = :ets.lookup(dm_sent, :sent)
      assert was_sent, "Bot token DM should have been sent"
      :ets.delete(dm_sent)

      # Verify bot exists in DB
      {:ok, bot} = Bot.get_bot_by_name("MyBot")
      assert bot.name == "MyBot"
      assert bot.active == true
      assert bot.user.balance == 0
    end

    test "non-admin cannot create a bot" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      regular_user_id = 777_777_777

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")

      interaction =
        create_bot_interaction(regular_user_id, guild_id, channel_id, "create", [
          {"name", "SneakyBot"}
        ])

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
        BotCommand.handle(interaction)
      end

      # Verify bot was NOT created
      assert {:error, :bot_not_found} = Bot.get_bot_by_name("SneakyBot")
    end

    test "creating a bot with a duplicate name fails" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      # Create first bot directly
      {:ok, _bot} = Bot.create_bot_user(admin_user_id, "DuplicateBot")

      # Try to create another with the same name via Discord command
      interaction =
        create_bot_interaction(admin_user_id, guild_id, channel_id, "create", [
          {"name", "DuplicateBot"}
        ])

      with_mocks(
        nostrum_api_mocks(admin_user_id, fn _interaction, response ->
          assert response.type == 4
          # Should be an error, not a success embed
          assert response.data.content != nil
          {:ok}
        end)
      ) do
        BotCommand.handle(interaction)
      end
    end
  end

  describe "list subcommand" do
    test "lists bots owned by the user" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      # Create a couple of bots
      {:ok, _bot1} = Bot.create_bot_user(admin_user_id, "BotAlpha")
      {:ok, _bot2} = Bot.create_bot_user(admin_user_id, "BotBeta")

      interaction = create_bot_interaction(admin_user_id, guild_id, channel_id, "list")

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "Your Bots")
             assert String.contains?(embed.description, "BotAlpha")
             assert String.contains?(embed.description, "BotBeta")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end
    end

    test "shows empty message when user has no bots" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _user} = User.create_user_account(user_id, "NoBotUser")

      interaction = create_bot_interaction(user_id, guild_id, channel_id, "list")

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)
             assert String.contains?(embed.description, "no active bots")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end
    end

    test "user without StackCoin account gets appropriate error" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      unknown_user_id = 666_666_666

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      interaction = create_bot_interaction(unknown_user_id, guild_id, channel_id, "list")

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "StackCoin account")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end
    end
  end

  describe "reset-token subcommand" do
    test "owner can reset their bot's token" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, bot} = Bot.create_bot_user(admin_user_id, "TokenBot")
      old_token = bot.token

      interaction =
        create_bot_interaction(admin_user_id, guild_id, channel_id, "reset-token", [
          {"bot_id", bot.id}
        ])

      with_mocks(
        nostrum_api_mocks(admin_user_id, fn _interaction, response ->
          assert response.type == 4
          embed = hd(response.data.embeds)
          assert String.contains?(embed.title, "Bot Token Reset")
          assert String.contains?(embed.description, "TokenBot")
          {:ok}
        end)
      ) do
        BotCommand.handle(interaction)
      end

      # Verify token actually changed
      {:ok, updated_bot} = Bot.get_bot_by_name("TokenBot")
      assert updated_bot.token != old_token

      # Old token no longer works
      assert {:error, :invalid_token} = Bot.get_bot_by_token(old_token)

      # New token works
      assert {:ok, _} = Bot.get_bot_by_token(updated_bot.token)
    end

    test "cannot reset token for a bot you don't own" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      other_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _other} = User.create_user_account(other_user_id, "OtherUser")
      {:ok, bot} = Bot.create_bot_user(admin_user_id, "NotYourBot")

      # Other user tries to reset the admin's bot token
      interaction =
        create_bot_interaction(other_user_id, guild_id, channel_id, "reset-token", [
          {"bot_id", bot.id}
        ])

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "Bot not found")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end
    end

    test "reset-token with nonexistent bot ID fails" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      interaction =
        create_bot_interaction(admin_user_id, guild_id, channel_id, "reset-token", [
          {"bot_id", 99999}
        ])

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "Bot not found")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end
    end
  end

  describe "delete subcommand" do
    test "owner can delete their bot (soft-delete)" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, bot} = Bot.create_bot_user(admin_user_id, "Doomed")

      interaction =
        create_bot_interaction(admin_user_id, guild_id, channel_id, "delete", [
          {"bot_id", bot.id}
        ])

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)
             assert String.contains?(embed.title, "Bot Deleted")
             assert String.contains?(embed.description, "Doomed")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end

      # Bot no longer findable by name or token
      assert {:error, :bot_not_found} = Bot.get_bot_by_name("Doomed")
      assert {:error, :invalid_token} = Bot.get_bot_by_token(bot.token)

      # Bot no longer shows in owner's list
      {:ok, bots} = Bot.get_user_bots(admin_user_id)
      refute Enum.any?(bots, fn b -> b.name == "Doomed" end)
    end

    test "cannot delete a bot you don't own" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      other_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _other} = User.create_user_account(other_user_id, "OtherUser")
      {:ok, bot} = Bot.create_bot_user(admin_user_id, "ProtectedBot")

      interaction =
        create_bot_interaction(other_user_id, guild_id, channel_id, "delete", [
          {"bot_id", bot.id}
        ])

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil
             assert String.contains?(response.data.content, "Bot not found")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end

      # Bot should still be active
      {:ok, still_there} = Bot.get_bot_by_name("ProtectedBot")
      assert still_there.active == true
    end

    test "deleted bot no longer appears in list" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _bot1} = Bot.create_bot_user(admin_user_id, "KeepMe")
      {:ok, bot2} = Bot.create_bot_user(admin_user_id, "DeleteMe")

      # Delete one bot
      delete_interaction =
        create_bot_interaction(admin_user_id, guild_id, channel_id, "delete", [
          {"bot_id", bot2.id}
        ])

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, _response -> {:ok} end
         ]}
      ]) do
        BotCommand.handle(delete_interaction)
      end

      # List should only show the surviving bot
      list_interaction = create_bot_interaction(admin_user_id, guild_id, channel_id, "list")

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)
             assert String.contains?(embed.description, "KeepMe")
             refute String.contains?(embed.description, "DeleteMe")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(list_interaction)
      end

      # Verify via core too
      {:ok, bots} = Bot.get_user_bots(admin_user_id)
      names = Enum.map(bots, & &1.name)
      assert "KeepMe" in names
      refute "DeleteMe" in names
    end
  end
end
