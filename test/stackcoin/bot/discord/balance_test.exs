defmodule StackCoinTest.Bot.Discord.Balance do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.{Admin, Balance}
  alias StackCoin.Core.{User, DiscordGuild}

  setup do
    # Ensure clean database state for each test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  test "admin register command creates guild and balance command validates channel" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    wrong_channel_id = 111_111_111
    admin_user_id = 999_999_999
    regular_user_id = 888_888_888

    # Set up the admin user
    setup_admin_user(admin_user_id)

    # Create mock interaction for admin register command
    admin_interaction =
      create_mock_interaction(admin_user_id, guild_id, designated_channel_id, %{
        options: [
          %{
            name: "register"
          }
        ]
      })

    # Test admin register command
    with_mocks([
      {Nostrum.Api.Guild, [], [get: fn ^guild_id -> {:ok, %{name: "Test Guild"}} end]},
      {Nostrum.Api.User, [],
       [
         get: fn user_id ->
           if user_id == admin_user_id or user_id == to_string(admin_user_id) do
             {:ok, %{id: admin_user_id, username: "TestAdmin"}}
           else
             {:error, :not_found}
           end
         end
       ]},
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           assert response.data.embeds != nil
           {:ok}
         end
       ]}
    ]) do
      Admin.handle(admin_interaction)
    end

    # Verify guild was created
    {:ok, guild} = DiscordGuild.get_guild_by_discord_id(guild_id)
    assert guild.designated_channel_snowflake == to_string(designated_channel_id)

    # Create a regular user for balance testing
    {:ok, _regular_user} = User.create_user_account(regular_user_id, "RegularUser")

    # Test balance command in wrong channel - should fail
    wrong_channel_interaction =
      create_mock_interaction(regular_user_id, guild_id, wrong_channel_id, %{
        options: nil
      })

    # Test balance command in wrong channel - should fail
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           # Error responses use content instead of embeds
           assert response.data.content != nil
           assert String.contains?(response.data.content, "designated StackCoin channel")
           {:ok}
         end
       ]}
    ]) do
      Balance.handle(wrong_channel_interaction)
    end

    # Test balance command in correct channel - should succeed
    correct_channel_interaction =
      create_mock_interaction(regular_user_id, guild_id, designated_channel_id, %{
        options: nil
      })

    # Test balance command in correct channel - should succeed
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           assert response.data.embeds != nil
           # Verify it shows the user's balance (new users start with 0)
           embed = hd(response.data.embeds)
           assert String.contains?(embed.title, "Your balance: 0 STK")
           {:ok}
         end
       ]}
    ]) do
      Balance.handle(correct_channel_interaction)
    end
  end

  test "balance command can check another user's balance" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    regular_user_id = 888_888_888
    target_user_id = 777_777_777

    # Set up users
    setup_admin_user(admin_user_id)
    {:ok, _regular_user} = User.create_user_account(regular_user_id, "RegularUser")
    {:ok, target_user} = User.create_user_account(target_user_id, "TargetUser")

    # Set up guild (skip the full admin register flow for this test)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)

    # Test balance command checking another user's balance
    interaction =
      create_mock_interaction(regular_user_id, guild_id, designated_channel_id, %{
        options: [
          %{
            name: "user",
            value: target_user_id
          }
        ]
      })

    # Test balance command checking another user's balance
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           assert response.data.embeds != nil
           embed = hd(response.data.embeds)

           assert String.contains?(
                    embed.title,
                    "#{target_user.username}'s balance: #{target_user.balance} STK"
                  )

           {:ok}
         end
       ]}
    ]) do
      Balance.handle(interaction)
    end
  end
end
