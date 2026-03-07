defmodule StackCoinTest.Core.ReserveDoleBanTest do
  use ExUnit.Case, async: false
  import StackCoinTest.Support.DiscordUtils
  alias StackCoin.Core.{User, Reserve}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    :ok
  end

  test "dole ban enforcement in reserve transfers" do
    create_reserve_user(1000)

    # Non-dole-banned user can collect dole
    {:ok, user} = User.create_user_account(111_111_111, "TestUser")
    assert {:ok, _transaction} = Reserve.transfer_dole_to_user(user.id)

    # Dole-banned user cannot collect dole
    {:ok, user2} = User.create_user_account(222_222_222, "TestUser2")
    {:ok, banned_user} = User.dole_ban_user(user2)
    assert {:error, :user_dole_banned} = Reserve.transfer_dole_to_user(banned_user.id)
  end
end
