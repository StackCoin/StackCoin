defmodule StackCoinTest.Support.DiscordUtils do
  import Mock
  alias StackCoin.Core.{User, Bank, DiscordGuild}
  alias Nostrum.Constants.InteractionType

  def setup_admin_user(admin_user_id) do
    # Set up admin user in config for this test
    Application.put_env(:stackcoin, :admin_user_id, to_string(admin_user_id))
  end

  def create_mock_interaction(user_id, guild_id, channel_id, data) do
    %{
      type: InteractionType.application_command(),
      user: %{id: user_id},
      guild_id: guild_id,
      channel_id: channel_id,
      data: data
    }
  end

  def setup_guild_and_users(admin_user_id, guild_id, channel_id, sender_id, recipient_id) do
    setup_admin_user(admin_user_id)

    # Create users
    {:ok, sender} = User.create_user_account(sender_id, "SenderUser")
    {:ok, recipient} = User.create_user_account(recipient_id, "RecipientUser")

    # Set up guild
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
       ]}
    ]) do
      {:ok, {_guild, :created}} =
        DiscordGuild.admin_register_guild(admin_user_id, guild_id, "Test Guild", channel_id)
    end

    {sender, recipient}
  end

  def setup_guild_with_admin(admin_user_id, guild_id, channel_id) do
    setup_admin_user(admin_user_id)

    # Set up guild
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
       ]}
    ]) do
      {:ok, {guild, :created}} =
        DiscordGuild.admin_register_guild(admin_user_id, guild_id, "Test Guild", channel_id)

      guild
    end
  end

  def create_reserve_user(balance) do
    # Create or update the reserve user (ID 1) that the system expects
    # Use Bank.update_user_balance which handles the database operations safely
    case User.get_user_by_id(1) do
      {:ok, _user} ->
        # Reserve user exists, update balance
        Bank.update_user_balance(1, balance)

      {:error, :user_not_found} ->
        # Reserve user doesn't exist, create it manually
        alias StackCoin.Schema

        # First create the User record
        {:ok, user} =
          StackCoin.Repo.insert(%Schema.User{
            id: 1,
            username: "Reserve",
            balance: balance,
            admin: false,
            banned: false
          })

        # Then create the InternalUser record that the pump system expects
        {:ok, _internal_user} =
          StackCoin.Repo.insert(%Schema.InternalUser{
            id: 1,
            identifier: "reserve"
          })

        {:ok, user}
    end
  end
end
