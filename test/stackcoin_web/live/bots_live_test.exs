defmodule StackCoinWebTest.BotsLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bot}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, admin} = User.create_user_account("admin_discord", "admin", balance: 0)
    # Set admin flag directly
    StackCoin.Repo.update!(Ecto.Changeset.change(admin, admin: true))
    {:ok, admin} = User.get_user_by_id(admin.id)
    {:ok, bot} = Bot.create_bot_user("admin_discord", "TestBot")

    %{alice: alice, admin: admin, bot: bot}
  end

  defp login(conn, user), do: conn |> Plug.Test.init_test_session(%{user_id: user.id})

  describe "authentication" do
    test "redirects to home when not logged in", %{conn: conn} do
      assert {:error,
              {:live_redirect,
               %{to: "/", flash: %{"error" => "You must be logged in to manage bots."}}}} =
               live(conn, ~p"/bots")
    end

    test "renders page with create form when logged in", %{conn: conn, alice: alice} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/bots")

      assert html =~ "Bots"
      assert html =~ "Create Bot"
      assert html =~ "Bot name"
    end
  end

  describe "bot list" do
    test "lists user's bots for admin who owns TestBot", %{conn: conn, admin: admin} do
      {:ok, _view, html} = conn |> login(admin) |> live(~p"/bots")

      assert html =~ "TestBot"
      assert html =~ "BOT"
      assert html =~ "STK"
      assert html =~ "Reset Token"
      assert html =~ "Delete"
    end

    test "shows empty state for user with no bots", %{conn: conn, alice: alice} do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/bots")

      assert html =~ "You don&#39;t have any bots yet."
    end
  end

  describe "create bot" do
    test "admin can create a bot", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/bots")

      html =
        view
        |> form("form[phx-submit=create_bot]", %{name: "NewBot"})
        |> render_submit()

      assert html =~ "Bot &quot;NewBot&quot; created."
      assert html =~ "NewBot"
      assert html =~ "BOT"
      # Token should be revealed and visible after creation
      assert html =~ "Hide"
      assert html =~ "Copy"
    end

    test "non-admin gets approval flow message", %{conn: conn, alice: alice} do
      {:ok, view, _html} = conn |> login(alice) |> live(~p"/bots")

      html =
        view
        |> form("form[phx-submit=create_bot]", %{name: "AliceBot"})
        |> render_submit()

      assert html =~ "Bot creation request sent"
    end
  end

  describe "delete bot" do
    test "delete bot works", %{conn: conn, admin: admin} do
      {:ok, view, html} = conn |> login(admin) |> live(~p"/bots")

      assert html =~ "TestBot"

      html = render_click(view, "delete_bot", %{"bot-id" => to_string(find_bot_id(admin))})

      assert html =~ "Bot deleted."
      refute html =~ "TestBot"
    end
  end

  describe "reset token" do
    test "reset token works", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/bots")

      html = render_click(view, "reset_token", %{"bot-id" => to_string(find_bot_id(admin))})

      assert html =~ "Token reset."
      # Token reveal should appear and be visible
      assert html =~ "Hide"
      assert html =~ "Copy"
    end
  end

  describe "token toggle" do
    test "toggle show/hide token", %{conn: conn, admin: admin} do
      bot_id = find_bot_id(admin)
      {:ok, view, _html} = conn |> login(admin) |> live(~p"/bots")

      # Reset token to get a revealed token
      html = render_click(view, "reset_token", %{"bot-id" => to_string(bot_id)})

      # Token should be visible after reset (show_tokens includes bot_id)
      assert html =~ "Hide"

      # Toggle to hide
      html = render_click(view, "toggle_token", %{"bot-id" => to_string(bot_id)})
      assert html =~ "Show"
      assert html =~ "••••••••"

      # Toggle to show again
      html = render_click(view, "toggle_token", %{"bot-id" => to_string(bot_id)})
      assert html =~ "Hide"
    end
  end

  defp find_bot_id(admin) do
    snowflake =
      case StackCoin.Repo.preload(admin, :discord_user) do
        %{discord_user: %{snowflake: s}} -> to_string(s)
      end

    {:ok, bots} = Bot.get_user_bots(snowflake)
    hd(bots).id
  end
end
