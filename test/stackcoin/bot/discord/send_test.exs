defmodule StackCoinTest.Bot.Discord.Send do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.Send
  alias StackCoin.Core.Bank

  setup do
    # Ensure clean database state for each test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  test "send command transfers STK between users successfully" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    sender_id = 888_888_888
    recipient_id = 777_777_777
    amount = 50

    {sender, _recipient} =
      setup_guild_and_users(
        admin_user_id,
        guild_id,
        designated_channel_id,
        sender_id,
        recipient_id
      )

    # Give sender some initial balance
    {:ok, _} = Bank.update_user_balance(sender.id, 100)

    # Create send command interaction
    interaction =
      create_mock_interaction(sender_id, guild_id, designated_channel_id, %{
        options: [
          %{name: "user", value: recipient_id},
          %{name: "amount", value: amount}
        ]
      })

    # Test send command
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           assert response.data.embeds != nil
           embed = hd(response.data.embeds)
           assert String.contains?(embed.title, "Transfer Successful")
           assert String.contains?(embed.description, "SenderUser")
           assert String.contains?(embed.description, "RecipientUser")
           assert String.contains?(embed.description, "#{amount} STK")
           {:ok}
         end
       ]}
    ]) do
      Send.handle(interaction)
    end

    # Verify balances using Bank functions
    {:ok, updated_sender} = Bank.get_user_by_discord_id(sender_id)
    {:ok, updated_recipient} = Bank.get_user_by_discord_id(recipient_id)

    # 100 - 50
    assert updated_sender.balance == 50
    # 0 + 50
    assert updated_recipient.balance == 50
  end

  test "send command fails when sender has insufficient balance" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    sender_id = 888_888_888
    recipient_id = 777_777_777
    amount = 150

    {sender, _recipient} =
      setup_guild_and_users(
        admin_user_id,
        guild_id,
        designated_channel_id,
        sender_id,
        recipient_id
      )

    # Give sender insufficient balance
    {:ok, _} = Bank.update_user_balance(sender.id, 100)

    # Create send command interaction
    interaction =
      create_mock_interaction(sender_id, guild_id, designated_channel_id, %{
        options: [
          %{name: "user", value: recipient_id},
          %{name: "amount", value: amount}
        ]
      })

    # Test send command - should fail
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           # Error responses use content instead of embeds
           assert response.data.content != nil
           assert String.contains?(response.data.content, "don't have enough")
           {:ok}
         end
       ]}
    ]) do
      Send.handle(interaction)
    end

    # Verify balances unchanged using Bank functions
    {:ok, updated_sender} = Bank.get_user_by_discord_id(sender_id)
    {:ok, updated_recipient} = Bank.get_user_by_discord_id(recipient_id)

    # unchanged
    assert updated_sender.balance == 100
    # unchanged
    assert updated_recipient.balance == 0
  end

  test "send command fails when recipient doesn't exist" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    sender_id = 888_888_888
    nonexistent_recipient_id = 666_666_666
    amount = 50

    setup_admin_user(admin_user_id)
    {:ok, sender} = Bank.create_user_account(sender_id, "SenderUser")

    # Set up guild
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    # Give sender some balance
    {:ok, _} = Bank.update_user_balance(sender.id, 100)

    # Create send command interaction
    interaction =
      create_mock_interaction(sender_id, guild_id, designated_channel_id, %{
        options: [
          %{name: "user", value: nonexistent_recipient_id},
          %{name: "amount", value: amount}
        ]
      })

    # Test send command - should fail
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           # Error responses use content instead of embeds
           assert response.data.content != nil
           assert String.contains?(response.data.content, "recipient")
           {:ok}
         end
       ]}
    ]) do
      Send.handle(interaction)
    end

    # Verify sender balance unchanged using Bank functions
    {:ok, updated_sender} = Bank.get_user_by_discord_id(sender_id)
    # unchanged
    assert updated_sender.balance == 100
  end

  test "send command fails in wrong channel" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    wrong_channel_id = 111_111_111
    admin_user_id = 999_999_999
    sender_id = 888_888_888
    recipient_id = 777_777_777
    amount = 50

    {sender, _recipient} =
      setup_guild_and_users(
        admin_user_id,
        guild_id,
        designated_channel_id,
        sender_id,
        recipient_id
      )

    # Give sender some balance
    {:ok, _} = Bank.update_user_balance(sender.id, 100)

    # Create send command interaction in wrong channel
    interaction =
      create_mock_interaction(sender_id, guild_id, wrong_channel_id, %{
        options: [
          %{name: "user", value: recipient_id},
          %{name: "amount", value: amount}
        ]
      })

    # Test send command - should fail
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
      Send.handle(interaction)
    end

    # Verify balances unchanged using Bank functions
    {:ok, updated_sender} = Bank.get_user_by_discord_id(sender_id)
    {:ok, updated_recipient} = Bank.get_user_by_discord_id(recipient_id)

    # unchanged
    assert updated_sender.balance == 100
    # unchanged
    assert updated_recipient.balance == 0
  end

  test "send command fails when sender doesn't exist" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    nonexistent_sender_id = 555_555_555
    recipient_id = 777_777_777
    amount = 50

    setup_admin_user(admin_user_id)
    {:ok, _recipient} = Bank.create_user_account(recipient_id, "RecipientUser")

    # Set up guild
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    # Create send command interaction
    interaction =
      create_mock_interaction(nonexistent_sender_id, guild_id, designated_channel_id, %{
        options: [
          %{name: "user", value: recipient_id},
          %{name: "amount", value: amount}
        ]
      })

    # Test send command - should fail
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           # Error responses use content instead of embeds
           assert response.data.content != nil
           assert String.contains?(response.data.content, "StackCoin account")
           {:ok}
         end
       ]}
    ]) do
      Send.handle(interaction)
    end

    # Verify recipient balance unchanged using Bank functions
    {:ok, updated_recipient} = Bank.get_user_by_discord_id(recipient_id)
    # unchanged
    assert updated_recipient.balance == 0
  end
end
