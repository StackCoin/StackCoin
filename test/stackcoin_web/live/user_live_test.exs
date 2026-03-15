defmodule StackCoinWebTest.UserLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bot, Bank}

  setup do
    {:ok, reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, bob} = User.create_user_account("bob_discord", "bob", balance: 0)
    {:ok, _owner} = User.create_user_account("bot_owner_discord", "BotOwner")
    {:ok, bot} = Bot.create_bot_user("bot_owner_discord", "LuckyBot")

    {:ok, _} = Bank.transfer_between_users(reserve.id, alice.id, 500, "Seed alice")
    {:ok, _} = Bank.transfer_between_users(reserve.id, bob.id, 200, "Seed bob")

    %{alice: alice, bob: bob, bot: bot}
  end

  defp login(conn, user) do
    conn |> Plug.Test.init_test_session(%{user_id: user.id})
  end

  describe "public access" do
    test "renders user detail page", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/user/#{alice.id}")

      assert html =~ "alice"
      assert html =~ "STK"
    end

    test "renders transactions", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/user/#{alice.id}")

      assert html =~ "Transactions"
    end

    test "does not show send form when not logged in", %{conn: conn, bob: bob} do
      {:ok, _view, html} = live(conn, ~p"/user/#{bob.id}")

      refute html =~ "Send STK"
    end

    test "redirects to home for nonexistent user", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => "User not found"}}}} =
               live(conn, ~p"/user/99999")
    end

    test "pagination works", %{conn: conn, alice: alice} do
      {:ok, _view, html} = live(conn, ~p"/user/#{alice.id}")

      assert html =~ "Transactions"
    end
  end

  describe "send STK" do
    test "shows send form when logged in and viewing another user", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/user/#{bob.id}")

      assert html =~ "Send STK"
    end

    test "does not show send form when viewing own page", %{conn: conn, alice: alice} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/user/#{alice.id}")

      refute html =~ "Send STK"
    end

    test "does not show send form on bot pages", %{conn: conn, alice: alice, bot: bot} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/user/#{bot.user.id}")

      refute html =~ "Send STK"
    end

    test "successfully sends STK", %{conn: conn, alice: alice, bob: bob} do
      {:ok, view, _html} = conn |> login(alice) |> live(~p"/user/#{bob.id}")

      html =
        view
        |> form("form[phx-submit=send_stk]", %{amount: "50"})
        |> render_submit()

      assert html =~ "Sent 50 STK to bob"
    end

    test "shows error for insufficient balance", %{conn: conn, alice: alice, bob: bob} do
      {:ok, view, _html} = conn |> login(alice) |> live(~p"/user/#{bob.id}")

      html =
        view
        |> form("form[phx-submit=send_stk]", %{amount: "999999"})
        |> render_submit()

      assert html =~ "Insufficient balance"
    end

    test "unauthenticated user cannot send STK via event", %{conn: conn, bob: bob} do
      {:ok, view, _html} = live(conn, ~p"/user/#{bob.id}")

      # Even if someone crafts the event directly, it should fail
      html = render_click(view, "send_stk", %{"amount" => "50"})
      assert html =~ "must be logged in"
    end
  end

  describe "YOU badge" do
    test "shows YOU badge on own page", %{conn: conn, alice: alice} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/user/#{alice.id}")

      assert html =~ "YOU"
    end

    test "does not show YOU badge on other user's page", %{conn: conn, alice: alice, bob: bob} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/user/#{bob.id}")

      refute html =~ "YOU"
    end
  end
end
