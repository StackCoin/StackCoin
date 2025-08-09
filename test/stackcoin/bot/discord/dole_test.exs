defmodule StackCoinTest.Bot.Discord.Dole do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.{Admin, Dole}
  alias StackCoin.Core.{Reserve, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  defp create_dole_interaction(user_id, guild_id, channel_id, username \\ "TestUser") do
    %{
      user: %{id: user_id, username: username},
      guild_id: guild_id,
      channel_id: channel_id,
      data: %{options: nil}
    }
  end

  defp create_admin_pump_interaction(admin_user_id, guild_id, channel_id, amount, label) do
    create_mock_interaction(admin_user_id, guild_id, channel_id, %{
      options: [
        %{
          name: "pump",
          options: [
            %{name: "amount", value: amount},
            %{name: "label", value: label}
          ]
        }
      ]
    })
  end

  test "dole creates account for new user and succeeds when reserve has funds" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    new_user_id = 888_888_888

    # Set up admin and reserve
    setup_admin_user(admin_user_id)
    # Start with 100 balance
    create_reserve_user(100)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)

    # Create dole interaction for new user
    interaction = create_dole_interaction(new_user_id, guild_id, designated_channel_id, "NewUser")

    # Test dole command - should create account and give dole
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           # channel_message_with_source
           assert response.type == 4
           assert response.data.embeds != nil
           embed = hd(response.data.embeds)
           assert String.contains?(embed.title, "Received **10 STK**")
           assert String.contains?(embed.description, "New Balance: **10 STK**")
           {:ok}
         end
       ]}
    ]) do
      Dole.handle(interaction)
    end

    # Verify user was created and has correct balance
    {:ok, user} = User.get_user_by_discord_id(new_user_id)
    assert user.username == "NewUser"
    assert user.balance == 10

    # Verify reserve balance was reduced by 10
    {:ok, reserve_balance} = Reserve.get_reserve_balance()
    # 100 - 10
    assert reserve_balance == 90
  end

  test "dole fails when reserve system is empty" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    # Set up admin and reserve with no funds
    setup_admin_user(admin_user_id)
    # Explicitly set to 0
    create_reserve_user(0)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "TestUser")

    # Create dole interaction
    interaction = create_dole_interaction(user_id, guild_id, designated_channel_id)

    # Test dole command - should fail due to insufficient reserve (5 < 10 needed)
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           # Should fail because 5 STK < 10 STK needed for dole
           if Map.has_key?(response.data, :content) do
             assert String.contains?(response.data.content, "doesn't have enough STK")
           else
             # If it succeeded, the reserve had more funds than expected
             flunk("Expected insufficient reserve error, but dole succeeded")
           end

           {:ok}
         end
       ]}
    ]) do
      Dole.handle(interaction)
    end

    # Verify user balance unchanged
    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 0
  end

  test "admin pump command adds funds to reserve" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    pump_amount = 500
    pump_label = "Initial funding"

    # Set up admin and reserve
    setup_admin_user(admin_user_id)
    create_reserve_user(100)
    # Create admin user account first
    {:ok, _admin_user} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)

    # Create admin pump interaction
    interaction =
      create_admin_pump_interaction(
        admin_user_id,
        guild_id,
        designated_channel_id,
        pump_amount,
        pump_label
      )

    # Test admin pump command
    with_mocks([
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
           embed = hd(response.data.embeds)
           assert String.contains?(embed.title, "Reserve Pumped Successfully!")
           assert String.contains?(embed.description, "**#{pump_amount} STK**")

           assert String.contains?(embed.description, "New Reserve Balance:")
           assert String.contains?(embed.description, "Label: #{pump_label}")
           {:ok}
         end
       ]}
    ]) do
      Admin.handle(interaction)
    end

    # Verify reserve balance increased by pump amount
    {:ok, reserve_balance} = Reserve.get_reserve_balance()
    # Should be at least the pump amount
    assert reserve_balance >= pump_amount
  end

  test "admin pump insufficient amount then successful dole" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    # Set up admin, reserve, and user
    setup_admin_user(admin_user_id)
    # Start with empty reserve
    create_reserve_user(0)
    # Create admin user account first
    {:ok, _admin_user} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "TestUser")

    # First pump insufficient amount (less than 10 STK needed for dole)
    insufficient_pump =
      create_admin_pump_interaction(
        admin_user_id,
        guild_id,
        designated_channel_id,
        5,
        "Insufficient pump"
      )

    with_mocks([
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
           assert response.type == 4
           assert response.data.embeds != nil
           {:ok}
         end
       ]}
    ]) do
      Admin.handle(insufficient_pump)
    end

    # Try dole - should fail
    dole_interaction = create_dole_interaction(user_id, guild_id, designated_channel_id)

    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.content != nil
           assert String.contains?(response.data.content, "doesn't have enough STK")
           {:ok}
         end
       ]}
    ]) do
      Dole.handle(dole_interaction)
    end

    # Now pump sufficient amount
    sufficient_pump =
      create_admin_pump_interaction(
        admin_user_id,
        guild_id,
        designated_channel_id,
        20,
        "Sufficient pump"
      )

    with_mocks([
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
           assert response.type == 4
           assert response.data.embeds != nil
           {:ok}
         end
       ]}
    ]) do
      Admin.handle(sufficient_pump)
    end

    # Now dole should succeed
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.embeds != nil
           embed = hd(response.data.embeds)
           assert String.contains?(embed.title, "Received **10 STK**")
           {:ok}
         end
       ]}
    ]) do
      Dole.handle(dole_interaction)
    end

    # Verify final balances
    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 10

    {:ok, reserve_balance} = Reserve.get_reserve_balance()
    # 5 + 20 - 10
    assert reserve_balance == 15
  end

  test "dole fails when already given today" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    # Set up admin, reserve with funds, and user
    setup_admin_user(admin_user_id)
    create_reserve_user(100)

    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "TestUser")

    # Create dole interaction
    interaction = create_dole_interaction(user_id, guild_id, designated_channel_id)

    # First dole should succeed
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.embeds != nil
           {:ok}
         end
       ]}
    ]) do
      Dole.handle(interaction)
    end

    # Second dole should fail
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.content != nil
           assert String.contains?(response.data.content, "already received")
           {:ok}
         end
       ]}
    ]) do
      Dole.handle(interaction)
    end

    # Verify user only got one dole
    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 10
  end

  test "dole fails in wrong channel" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    wrong_channel_id = 111_111_111
    admin_user_id = 999_999_999
    user_id = 888_888_888

    # Set up admin, reserve with funds, and user
    setup_admin_user(admin_user_id)
    create_reserve_user(100)

    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "TestUser")

    # Create dole interaction in wrong channel
    interaction = create_dole_interaction(user_id, guild_id, wrong_channel_id)

    # Test dole command - should fail due to wrong channel
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.content != nil
           assert String.contains?(response.data.content, "designated StackCoin channel")
           {:ok}
         end
       ]}
    ]) do
      Dole.handle(interaction)
    end

    # Verify user balance unchanged
    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 0
  end

  test "dole fails for banned user" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    # Set up admin, reserve with funds, and user
    setup_admin_user(admin_user_id)
    create_reserve_user(100)

    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, user} = User.create_user_account(user_id, "TestUser")

    # Ban the user
    {:ok, _banned_user} = User.ban_user(user)

    # Create dole interaction
    interaction = create_dole_interaction(user_id, guild_id, designated_channel_id)

    # Test dole command - should fail due to user being banned
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.content != nil
           assert String.contains?(response.data.content, "banned")
           {:ok}
         end
       ]}
    ]) do
      Dole.handle(interaction)
    end

    # Verify user balance unchanged
    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 0
  end

  test "non-admin cannot use pump command" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    regular_user_id = 888_888_888

    # Set up admin and regular user
    setup_admin_user(admin_user_id)
    create_reserve_user(50)
    # Create admin user account first
    {:ok, _admin_user} = User.create_user_account(admin_user_id, "TestAdmin", admin: true)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(regular_user_id, "RegularUser")

    # Create pump interaction from regular user
    interaction =
      create_admin_pump_interaction(
        regular_user_id,
        guild_id,
        designated_channel_id,
        100,
        "Unauthorized pump"
      )

    # Test admin pump command - should fail due to lack of admin permissions
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.content != nil
           assert String.contains?(response.data.content, "admin")
           {:ok}
         end
       ]}
    ]) do
      Admin.handle(interaction)
    end

    # Verify reserve balance unchanged
    {:ok, reserve_balance} = Reserve.get_reserve_balance()
    assert reserve_balance == 50
  end

  test "dole works for existing user with sufficient reserve" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    # Set up admin, reserve with funds, and existing user
    setup_admin_user(admin_user_id)
    create_reserve_user(100)

    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "ExistingUser", balance: 25)

    # Create dole interaction
    interaction = create_dole_interaction(user_id, guild_id, designated_channel_id)

    # Test dole command - should succeed
    with_mocks([
      {Nostrum.Api, [],
       [
         create_interaction_response: fn _interaction, response ->
           assert response.type == 4
           assert response.data.embeds != nil
           embed = hd(response.data.embeds)
           assert String.contains?(embed.title, "Received **10 STK**")
           assert String.contains?(embed.description, "New Balance: **35 STK**")
           {:ok}
         end
       ]}
    ]) do
      Dole.handle(interaction)
    end

    # Verify user balance increased
    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 35

    # Verify reserve balance decreased by 10
    {:ok, reserve_balance} = Reserve.get_reserve_balance()
    # 100 - 10
    assert reserve_balance == 90
  end
end
