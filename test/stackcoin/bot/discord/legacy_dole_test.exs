defmodule StackCoinTest.Bot.Discord.LegacyDole do
  use ExUnit.Case
  import Mock
  import StackCoinTest.Support.DiscordUtils

  alias StackCoin.Bot.Discord.Dole
  alias StackCoin.Core.{Reserve, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  defp create_legacy_msg(user_id, guild_id, channel_id, username \\ "TestUser") do
    %{
      author: %{id: user_id, username: username, bot: false},
      guild_id: guild_id,
      channel_id: channel_id,
      content: "s!dole"
    }
  end

  test "s!dole creates account for new user and succeeds when reserve has funds" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    new_user_id = 888_888_888

    setup_admin_user(admin_user_id)
    create_reserve_user(100)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)

    msg = create_legacy_msg(new_user_id, guild_id, designated_channel_id, "NewUser")

    with_mocks([
      {Nostrum.Api.Message, [],
       [
         create: fn channel_id, opts ->
           assert channel_id == designated_channel_id
           embed = hd(opts[:embeds])
           assert String.contains?(embed.title, "Received **10 STK**")
           assert String.contains?(embed.description, "New Balance: **10 STK**")
           {:ok, %{}}
         end
       ]}
    ]) do
      Dole.handle_legacy(msg)
    end

    {:ok, user} = User.get_user_by_discord_id(new_user_id)
    assert user.username == "NewUser"
    assert user.balance == 10

    {:ok, reserve_balance} = Reserve.get_reserve_balance()
    assert reserve_balance == 90
  end

  test "s!dole fails when reserve is empty" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    setup_admin_user(admin_user_id)
    create_reserve_user(0)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "TestUser")

    msg = create_legacy_msg(user_id, guild_id, designated_channel_id)

    with_mocks([
      {Nostrum.Api.Message, [],
       [
         create: fn channel_id, content ->
           assert channel_id == designated_channel_id
           assert is_binary(content)
           assert String.contains?(content, "reserve doesn't have enough STK")
           {:ok, %{}}
         end
       ]}
    ]) do
      Dole.handle_legacy(msg)
    end

    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 0
  end

  test "s!dole works for existing user with sufficient reserve" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    setup_admin_user(admin_user_id)
    create_reserve_user(100)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "ExistingUser", balance: 25)

    msg = create_legacy_msg(user_id, guild_id, designated_channel_id)

    with_mocks([
      {Nostrum.Api.Message, [],
       [
         create: fn _channel_id, opts ->
           embed = hd(opts[:embeds])
           assert String.contains?(embed.title, "Received **10 STK**")
           assert String.contains?(embed.description, "New Balance: **35 STK**")
           {:ok, %{}}
         end
       ]}
    ]) do
      Dole.handle_legacy(msg)
    end

    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 35
  end

  test "s!dole fails when already given today" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    setup_admin_user(admin_user_id)
    create_reserve_user(100)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "TestUser")

    msg = create_legacy_msg(user_id, guild_id, designated_channel_id)

    # First dole succeeds
    with_mocks([
      {Nostrum.Api.Message, [],
       [
         create: fn _channel_id, opts ->
           assert is_list(opts[:embeds])
           {:ok, %{}}
         end
       ]}
    ]) do
      Dole.handle_legacy(msg)
    end

    # Second dole fails
    with_mocks([
      {Nostrum.Api.Message, [],
       [
         create: fn _channel_id, content ->
           assert is_binary(content)
           assert String.contains?(content, "already received")
           {:ok, %{}}
         end
       ]}
    ]) do
      Dole.handle_legacy(msg)
    end

    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 10
  end

  test "s!dole fails in wrong channel" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    wrong_channel_id = 111_111_111
    admin_user_id = 999_999_999
    user_id = 888_888_888

    setup_admin_user(admin_user_id)
    create_reserve_user(100)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, _user} = User.create_user_account(user_id, "TestUser")

    msg = create_legacy_msg(user_id, guild_id, wrong_channel_id)

    with_mocks([
      {Nostrum.Api.Message, [],
       [
         create: fn channel_id, content ->
           assert channel_id == wrong_channel_id
           assert is_binary(content)
           assert String.contains?(content, "designated StackCoin channel")
           {:ok, %{}}
         end
       ]}
    ]) do
      Dole.handle_legacy(msg)
    end

    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 0
  end

  test "s!dole fails for banned user" do
    guild_id = 123_456_789
    designated_channel_id = 987_654_321
    admin_user_id = 999_999_999
    user_id = 888_888_888

    setup_admin_user(admin_user_id)
    create_reserve_user(100)
    setup_guild_with_admin(admin_user_id, guild_id, designated_channel_id)
    {:ok, user} = User.create_user_account(user_id, "TestUser")
    {:ok, _banned_user} = User.ban_user(user)

    msg = create_legacy_msg(user_id, guild_id, designated_channel_id)

    with_mocks([
      {Nostrum.Api.Message, [],
       [
         create: fn _channel_id, content ->
           assert is_binary(content)
           assert String.contains?(content, "You have been banned")
           {:ok, %{}}
         end
       ]}
    ]) do
      Dole.handle_legacy(msg)
    end

    {:ok, user} = User.get_user_by_discord_id(user_id)
    assert user.balance == 0
  end
end
