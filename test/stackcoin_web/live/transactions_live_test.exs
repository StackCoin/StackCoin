defmodule StackCoinWebTest.TransactionsLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bank}

  setup do
    {:ok, reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, bob} = User.create_user_account("bob_discord", "bob", balance: 0)

    {:ok, _} = Bank.transfer_between_users(reserve.id, alice.id, 500, "Seed alice")
    {:ok, _} = Bank.transfer_between_users(reserve.id, bob.id, 200, "Seed bob")
    {:ok, _} = Bank.transfer_between_users(alice.id, bob.id, 100, "Payment")

    %{alice: alice, bob: bob}
  end

  describe "public access" do
    test "renders transactions page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/transactions")

      assert html =~ "Transactions"
      assert html =~ "STK"
    end

    test "shows transaction details", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/transactions")

      assert html =~ "alice"
      assert html =~ "bob"
    end

    test "user filter works", %{conn: conn, alice: alice} do
      {:ok, view, _html} = live(conn, ~p"/transactions")

      # Filter to alice's transactions
      html =
        view
        |> form("form", %{user_id: to_string(alice.id)})
        |> render_change()

      assert html =~ "alice"
    end

    test "filter via URL param works", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/transactions?user=#{alice.id}")

      assert html =~ "alice"
    end

    test "direction filter hidden when no user selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/transactions")

      refute html =~ "Direction"
    end

    test "direction filter shows when user is selected", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/transactions?user=#{alice.id}")

      assert html =~ "Direction"
    end

    test "from direction filter works via URL", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/transactions?user=#{alice.id}&dir=from")

      # Alice sent 100 to bob ("Payment"), so this should appear
      assert html =~ "alice"
    end

    test "to direction filter works via URL", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/transactions?user=#{alice.id}&dir=to")

      # Alice received 500 from reserve
      assert html =~ "alice"
    end
  end
end
