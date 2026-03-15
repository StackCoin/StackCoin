defmodule StackCoinWebTest.RequestsLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bank, Request}

  setup do
    {:ok, reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, bob} = User.create_user_account("bob_discord", "bob", balance: 0)

    {:ok, _} = Bank.transfer_between_users(reserve.id, alice.id, 500, "Seed alice")
    {:ok, _} = Bank.transfer_between_users(reserve.id, bob.id, 200, "Seed bob")

    %{alice: alice, bob: bob}
  end

  defp login(conn, user) do
    conn |> Plug.Test.init_test_session(%{user_id: user.id})
  end

  describe "authentication" do
    test "redirects to home when not logged in", %{conn: conn} do
      assert {:error,
              {:live_redirect,
               %{to: "/", flash: %{"error" => "You must be logged in to view requests."}}}} =
               live(conn, ~p"/requests")
    end

    test "renders requests page when logged in", %{conn: conn, alice: alice} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/requests")

      assert html =~ "Requests"
      assert html =~ "Pending"
      assert html =~ "All"
    end
  end

  describe "request management" do
    test "shows pending requests with accept/deny buttons", %{conn: conn, alice: alice, bob: bob} do
      {:ok, _request} = Request.create_request(bob.id, alice.id, 75, "Payment")

      {:ok, _view, html} = conn |> login(alice) |> live(~p"/requests")

      assert html =~ "75 STK"
      assert html =~ "bob"
      assert html =~ "Accept"
      assert html =~ "Deny"
    end

    test "accept request works", %{conn: conn, alice: alice, bob: bob} do
      {:ok, request} = Request.create_request(bob.id, alice.id, 50)

      {:ok, view, _html} = conn |> login(alice) |> live(~p"/requests")

      html = render_click(view, "accept_request", %{"id" => to_string(request.id)})

      assert html =~ "Request accepted"
    end

    test "deny request works", %{conn: conn, alice: alice, bob: bob} do
      {:ok, request} = Request.create_request(bob.id, alice.id, 50)

      {:ok, view, _html} = conn |> login(alice) |> live(~p"/requests")

      html = render_click(view, "deny_request", %{"id" => to_string(request.id)})

      assert html =~ "Request denied"
    end

    test "filter tabs switch between pending and all", %{conn: conn, alice: alice, bob: bob} do
      {:ok, request} = Request.create_request(bob.id, alice.id, 30)
      {:ok, _} = Request.deny_request(request.id, alice.id)

      # Pending tab should not show denied requests
      {:ok, view, html} = conn |> login(alice) |> live(~p"/requests")
      refute html =~ "30 STK"

      # All tab should show denied requests
      html = view |> element("a", "All") |> render_click()
      assert html =~ "30 STK"
      assert html =~ "denied"
    end

    test "cannot accept someone else's request", %{conn: conn, alice: alice, bob: bob} do
      # alice requests from bob, then alice tries to accept her own request
      {:ok, request} = Request.create_request(alice.id, bob.id, 50)

      {:ok, view, _html} = conn |> login(alice) |> live(~p"/requests")

      # Alice is the requester, not the responder -- no accept button should appear
      # But even if we send the event directly, the backend should reject it
      html = render_click(view, "accept_request", %{"id" => to_string(request.id)})
      assert html =~ "Failed" or html =~ "can't respond"
    end
  end
end
