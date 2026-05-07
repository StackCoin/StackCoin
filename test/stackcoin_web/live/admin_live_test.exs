defmodule StackCoinWebTest.AdminLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bank}

  setup do
    {:ok, reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, admin} = User.create_user_account("admin_discord", "admin", balance: 0)
    StackCoin.Repo.update!(Ecto.Changeset.change(admin, admin: true))
    {:ok, admin} = User.get_user_by_id(admin.id)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, _} = Bank.transfer_between_users(reserve.id, alice.id, 500, "Seed")

    %{admin: admin, alice: alice}
  end

  defp login(conn, user) do
    conn |> Plug.Test.init_test_session(%{user_id: user.id})
  end

  describe "auth guard" do
    test "redirects when not logged in", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(conn, ~p"/admin")
    end

    test "redirects non-admin users", %{conn: conn, alice: alice} do
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => _}}}} =
               conn |> login(alice) |> live(~p"/admin")
    end
  end

  describe "admin page" do
    test "renders admin page with Reserve and User Management sections", %{
      conn: conn,
      admin: admin
    } do
      {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin")

      assert html =~ "Admin"
      assert html =~ "Reserve"
      assert html =~ "User Management"
    end

    test "shows reserve balance", %{conn: conn, admin: admin} do
      {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin")

      assert html =~ "STK"
    end
  end

  describe "pump reserve" do
    test "pump reserve works", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      html =
        view
        |> form("form[phx-submit=pump]", %{amount: "1000", label: "Test pump"})
        |> render_submit()

      assert html =~ "Reserve pumped"
      assert html =~ "STK"
    end
  end

  describe "user management" do
    test "select user shows ban status", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      html =
        view
        |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
        |> render_change()

      assert html =~ "alice"
    end

    test "ban user works", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      view
      |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
      |> render_change()

      html = render_click(view, "ban_user")

      assert html =~ "User banned"
      assert html =~ "BANNED"
    end

    test "dole ban user works", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      view
      |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
      |> render_change()

      html = render_click(view, "dole_ban_user")

      assert html =~ "User dole banned"
      assert html =~ "DOLE BANNED"
    end

    test "pump with invalid amount shows error", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      html =
        view
        |> form("form[phx-submit=pump]", %{amount: "0", label: "Bad pump"})
        |> render_submit()

      assert html =~ "Invalid amount"
    end

    test "pump with non-numeric amount shows error", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      html =
        view
        |> form("form[phx-submit=pump]", %{amount: "abc", label: "Bad pump"})
        |> render_submit()

      assert html =~ "Invalid amount"
    end

    test "unban user works", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      view
      |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
      |> render_change()

      # Ban first
      render_click(view, "ban_user")

      # Then unban
      html = render_click(view, "ban_user")

      assert html =~ "unbanned"
      refute html =~ "BANNED"
    end

    test "dole unban user works", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      view
      |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
      |> render_change()

      # Dole ban first
      render_click(view, "dole_ban_user")

      # Then dole unban
      html = render_click(view, "dole_ban_user")

      assert html =~ "unbanned"
      refute html =~ "DOLE BANNED"
    end

    test "deselecting user clears selection", %{conn: conn, admin: admin, alice: alice} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin")

      # Select alice
      view
      |> form("form[phx-change=select_user]", %{user_id: to_string(alice.id)})
      |> render_change()

      # Deselect
      html =
        view
        |> form("form[phx-change=select_user]", %{user_id: ""})
        |> render_change()

      # Ban buttons should be gone since no user selected
      refute html =~ "BANNED"
    end
  end
end
