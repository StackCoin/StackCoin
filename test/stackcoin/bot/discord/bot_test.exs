defmodule StackCoinTest.Bot.Discord.Bot do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.Bot, as: BotCommand
  alias StackCoin.Core.{Bot, Request, User}

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
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)
             assert String.contains?(embed.description, "sent for approval")
             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end

      # Verify bot was NOT created (needs admin approval)
      assert {:error, :bot_not_found} = Bot.get_bot_by_name("SneakyBot")
    end

    test "user without StackCoin account is denied bot creation and told to run /dole" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      no_account_user_id = 555_555_555

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)

      # User has no StackCoin account — never ran /dole
      interaction =
        create_bot_interaction(no_account_user_id, guild_id, channel_id, "create", [
          {"name", "GhostBot"}
        ])

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             assert response.data.content != nil

             assert String.contains?(response.data.content, "StackCoin account"),
                    "Should tell user they don't have an account"

             assert String.contains?(response.data.content, "/dole"),
                    "Should tell user to use /dole"

             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end

      # Bot should NOT exist
      assert {:error, :bot_not_found} = Bot.get_bot_by_name("GhostBot")
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

    test "deleting a bot cancels all pending requests involving that bot" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      other_user_id = 888_888_888

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, other} = User.create_user_account(other_user_id, "OtherUser")
      {:ok, bot} = Bot.create_bot_user(admin_user_id, "VictimBot")

      # Create pending requests involving the bot's user
      {req_from_bot, req_to_bot} =
        with_mocks([
          {Nostrum.Api.User, [], [create_dm: fn _id -> {:error, :no_dm} end]},
          {Nostrum.Api.Message, [], [create: fn _ch, _msg -> {:ok, %{id: 0}} end]}
        ]) do
          {:ok, r1} = Request.create_request(bot.user.id, other.id, 10, "from bot")
          {:ok, r2} = Request.create_request(other.id, bot.user.id, 20, "to bot")
          {r1, r2}
        end

      # Verify both are pending
      {:ok, check1} = Request.get_request_by_id(req_from_bot.id)
      assert check1.status == "pending"
      {:ok, check2} = Request.get_request_by_id(req_to_bot.id)
      assert check2.status == "pending"

      # Now delete the bot via Discord command
      interaction =
        create_bot_interaction(admin_user_id, guild_id, channel_id, "delete", [
          {"bot_id", bot.id}
        ])

      with_mocks([
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, _response -> {:ok} end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end

      # Both requests should now be cancelled
      {:ok, req1} = Request.get_request_by_id(req_from_bot.id)

      assert req1.status == "cancelled",
             "Pending request FROM deleted bot should be cancelled, got: #{req1.status}"

      {:ok, req2} = Request.get_request_by_id(req_to_bot.id)

      assert req2.status == "cancelled",
             "Pending request TO deleted bot should be cancelled, got: #{req2.status}"
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

  describe "bot creation approval flow" do
    test "non-admin bot create sends approval request to admin" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      regular_user_id = 777_777_777

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _regular} = User.create_user_account(regular_user_id, "RegularUser")

      interaction =
        create_bot_interaction(regular_user_id, guild_id, channel_id, "create", [
          {"name", "RequestedBot"}
        ])

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
             # Verify DM to admin uses Components v2 with approval buttons and bot name
             assert message.flags == 32768,
                    "DM should use Components v2 flag"

             assert message.components != nil,
                    "DM should have components"

             container = hd(message.components)
             assert container.type == 17, "First component should be a container"

             text_display =
               Enum.find(container.components, fn c -> c.type == 10 end)

             assert text_display != nil, "Container should have a text_display"

             assert String.contains?(text_display.content, "RequestedBot"),
                    "DM should mention the bot name"

             assert String.contains?(text_display.content, "RegularUser"),
                    "DM should mention the requester"

             action_row =
               Enum.find(container.components, fn c -> c.type == 1 end)

             assert action_row != nil, "Container should have an action row with buttons"
             assert length(action_row.components) == 2, "Should have Accept and Reject buttons"

             :ets.insert(dm_sent, {:sent, true})
             {:ok, %{id: 0}}
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             assert response.type == 4
             embed = hd(response.data.embeds)

             assert String.contains?(embed.description, "RequestedBot"),
                    "Channel reply should mention bot name"

             assert String.contains?(embed.description, "approval") or
                      String.contains?(embed.description, "sent"),
                    "Channel reply should mention approval or sent"

             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle(interaction)
      end

      [{:sent, was_sent}] = :ets.lookup(dm_sent, :sent)
      assert was_sent, "Approval DM should have been sent to admin"
      :ets.delete(dm_sent)

      # Bot should NOT exist yet — it needs admin approval
      assert {:error, :bot_not_found} = Bot.get_bot_by_name("RequestedBot")
    end

    test "admin approves bot creation request via button" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      requester_user_id = 777_777_777

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _requester} = User.create_user_account(requester_user_id, "RequesterUser")

      # Button interaction (type 3 = message component)
      interaction = %{
        type: 3,
        user: %{id: admin_user_id},
        guild_id: guild_id,
        channel_id: channel_id,
        data: %{custom_id: "bot_create_accept:#{requester_user_id}:ApprovedBot"}
      }

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
             # Verify DM to requester contains bot name and token in spoiler tags
             embed =
               cond do
                 is_map(message) and Map.has_key?(message, :embeds) -> hd(message.embeds)
                 is_list(message[:embeds]) -> hd(message[:embeds])
               end

             assert String.contains?(embed.description, "ApprovedBot"),
                    "DM should contain the bot name"

             assert String.contains?(embed.description, "||"),
                    "DM should contain spoiler-tagged token"

             :ets.insert(dm_sent, {:sent, true})
             {:ok, %{id: 0}}
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             # Type 7 = UPDATE_MESSAGE (edit the original approval DM)
             assert response.type == 7,
                    "Response should be type 7 (update_message), got #{response.type}"

             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle_bot_creation_interaction(interaction)
      end

      [{:sent, was_sent}] = :ets.lookup(dm_sent, :sent)
      assert was_sent, "Token DM should have been sent to requester"
      :ets.delete(dm_sent)

      # Bot should now exist
      {:ok, bot} = Bot.get_bot_by_name("ApprovedBot")
      assert bot.active == true
    end

    test "admin rejects bot creation request via button" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      requester_user_id = 777_777_777

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _requester} = User.create_user_account(requester_user_id, "RequesterUser")

      # Button interaction (type 3 = message component)
      interaction = %{
        type: 3,
        user: %{id: admin_user_id},
        guild_id: guild_id,
        channel_id: channel_id,
        data: %{custom_id: "bot_create_reject:#{requester_user_id}:RejectedBot"}
      }

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
             # Verify DM to requester contains rejection info
             content =
               cond do
                 is_map(message) and Map.has_key?(message, :embeds) ->
                   hd(message.embeds).description

                 is_map(message) and Map.has_key?(message, :content) ->
                   message.content

                 is_list(message[:embeds]) ->
                   hd(message[:embeds]).description

                 true ->
                   message[:content] || ""
               end

             assert String.contains?(content, "RejectedBot"),
                    "DM should mention the bot name"

             assert String.contains?(content, "denied") or
                      String.contains?(content, "rejected"),
                    "DM should indicate rejection"

             :ets.insert(dm_sent, {:sent, true})
             {:ok, %{id: 0}}
           end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             # Type 7 = UPDATE_MESSAGE
             assert response.type == 7,
                    "Response should be type 7 (update_message), got #{response.type}"

             {:ok}
           end
         ]}
      ]) do
        BotCommand.handle_bot_creation_interaction(interaction)
      end

      [{:sent, was_sent}] = :ets.lookup(dm_sent, :sent)
      assert was_sent, "Rejection DM should have been sent to requester"
      :ets.delete(dm_sent)

      # Bot should NOT exist
      assert {:error, :bot_not_found} = Bot.get_bot_by_name("RejectedBot")
    end

    test "duplicate approval is handled gracefully" do
      guild_id = 123_456_789
      channel_id = 987_654_321
      admin_user_id = 999_999_999
      requester_user_id = 777_777_777

      setup_admin_user(admin_user_id)
      setup_guild_with_admin(admin_user_id, guild_id, channel_id)
      {:ok, _requester} = User.create_user_account(requester_user_id, "RequesterUser")

      # Create the bot directly first (simulating it was already approved)
      {:ok, _bot} = Bot.create_bot_user(requester_user_id, "AlreadyApproved")

      # Then simulate another Accept button click with the same name
      interaction = %{
        type: 3,
        user: %{id: admin_user_id},
        guild_id: guild_id,
        channel_id: channel_id,
        data: %{custom_id: "bot_create_accept:#{requester_user_id}:AlreadyApproved"}
      }

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
           create: fn _channel_id, _message -> {:ok, %{id: 0}} end
         ]},
        {Nostrum.Api, [],
         [
           create_interaction_response: fn _interaction, response ->
             # Type 7 = UPDATE_MESSAGE — should not crash
             assert response.type == 7,
                    "Response should be type 7 (update_message), got #{response.type}"

             {:ok}
           end
         ]}
      ]) do
        # Should not crash even though bot already exists
        BotCommand.handle_bot_creation_interaction(interaction)
      end

      # Bot should still exist (the original one)
      {:ok, bot} = Bot.get_bot_by_name("AlreadyApproved")
      assert bot.active == true
    end
  end
end
