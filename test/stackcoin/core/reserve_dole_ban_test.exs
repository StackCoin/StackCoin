defmodule StackCoinTest.Core.ReserveDoleBanTest do
  use ExUnit.Case
  import StackCoinTest.Support.DiscordUtils
  alias StackCoin.Core.{User, Reserve}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(StackCoin.Repo)
    create_reserve_user(1000)
    :ok
  end

  test "dole-banned user cannot collect dole" do
    {:ok, user} = User.create_user_account(111_111_111, "TestUser")
    {:ok, banned_user} = User.dole_ban_user(user)

    assert {:error, :user_dole_banned} = Reserve.transfer_dole_to_user(banned_user.id)
  end

  test "non-dole-banned user can collect dole" do
    {:ok, user} = User.create_user_account(111_111_111, "TestUser")

    assert {:ok, _transaction} = Reserve.transfer_dole_to_user(user.id)
  end
end
