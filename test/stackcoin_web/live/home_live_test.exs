defmodule StackCoinWebTest.HomeLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bot, Bank, Request}

  setup do
    {:ok, reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, bob} = User.create_user_account("bob_discord", "bob", balance: 0)
    {:ok, _owner} = User.create_user_account("bot_owner_discord", "BotOwner")
    {:ok, bot} = Bot.create_bot_user("bot_owner_discord", "LuckyBot")

    # Fund users from reserve
    {:ok, _} = Bank.transfer_between_users(reserve.id, alice.id, 500, "Seed alice")
    {:ok, _} = Bank.transfer_between_users(reserve.id, bob.id, 200, "Seed bob")

    %{alice: alice, bob: bob, bot: bot}
  end

  defp login(conn, user) do
    conn |> Plug.Test.init_test_session(%{user_id: user.id})
  end

  describe "public access (not logged in)" do
    test "renders user list", %{conn: conn, alice: _alice, bob: _bob} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "alice"
      assert html =~ "bob"
      assert html =~ "STK"
    end

    test "renders recent transactions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Recent Transactions"
    end

    test "filter tabs work", %{conn: conn, bot: bot} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Filter to bots only
      html = view |> element("a", "Bots") |> render_click()
      assert html =~ bot.name

      # Filter to users only
      html = view |> element("a", "Users") |> render_click()
      refute html =~ bot.name
      assert html =~ "alice"
    end

    test "does not show pending requests when not logged in", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Pending Requests"
      refute html =~ "Your Requests"
    end

    test "does not show YOU badge when not logged in", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "YOU"
    end
  end

  describe "authenticated access" do
    test "shows YOU badge for logged-in user", %{conn: conn, alice: alice} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/")

      assert html =~ "YOU"
    end

    test "shows Your Requests link when no pending requests", %{conn: conn, alice: alice} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/")

      assert html =~ "Your Requests"
    end

    test "shows pending requests with accept/deny buttons", %{conn: conn, alice: alice, bob: bob} do
      {:ok, _request} = Request.create_request(bob.id, alice.id, 50, "Pay me")

      {:ok, _view, html} = conn |> login(alice) |> live(~p"/")

      assert html =~ "Pending Requests"
      assert html =~ "bob"
      assert html =~ "50 STK"
      assert html =~ "Accept"
      assert html =~ "Deny"
    end

    test "accept request works", %{conn: conn, alice: alice, bob: bob} do
      {:ok, request} = Request.create_request(bob.id, alice.id, 50)

      {:ok, view, _html} = conn |> login(alice) |> live(~p"/")

      html = render_click(view, "accept_request", %{"id" => to_string(request.id)})

      assert html =~ "Request accepted"
    end

    test "deny request works", %{conn: conn, alice: alice, bob: bob} do
      {:ok, request} = Request.create_request(bob.id, alice.id, 50)

      {:ok, view, _html} = conn |> login(alice) |> live(~p"/")

      html = render_click(view, "deny_request", %{"id" => to_string(request.id)})

      assert html =~ "Request denied"
    end
  end
end
