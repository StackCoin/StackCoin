defmodule StackCoinWebTest.PreauthsLiveTest do
  use StackCoinWeb.ConnCase

  import Phoenix.LiveViewTest

  alias StackCoin.Core.{User, Bot, Preauthorization}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 10_000)
    {:ok, alice} = User.create_user_account("alice_discord", "alice", balance: 0)
    {:ok, bot_owner} = User.create_user_account("owner_discord", "BotOwner", balance: 0)
    {:ok, bot} = Bot.create_bot_user("owner_discord", "LuckyBot")
    # Create and approve a preauth for alice
    {:ok, preauth} = Preauthorization.create_preauth(bot.user_id, alice.id, 10, 24)
    {:ok, preauth} = Preauthorization.approve_preauth(preauth.id)
    %{alice: alice, bot_owner: bot_owner, bot: bot, preauth: preauth}
  end

  defp login(conn, user), do: conn |> Plug.Test.init_test_session(%{user_id: user.id})

  describe "authentication" do
    test "redirects to home when not logged in", %{conn: conn} do
      assert {:error,
              {:live_redirect,
               %{to: "/", flash: %{"error" => "You must be logged in to view preauthorizations."}}}} =
               live(conn, ~p"/preauths")
    end
  end

  describe "preauth list" do
    test "renders preauth list with bot name, budget, and remaining", %{
      conn: conn,
      alice: alice
    } do
      {:ok, _view, html} = conn |> login(alice) |> live(~p"/preauths")

      assert html =~ "Preauthorizations"
      assert html =~ "LuckyBot"
      assert html =~ "BOT"
      assert html =~ "10 STK"
      assert html =~ "24 hrs"
      assert html =~ "remaining"
      assert html =~ "Revoke"
    end

    test "shows empty state for user with no preauths", %{conn: conn, bot_owner: bot_owner} do
      {:ok, _view, html} = conn |> login(bot_owner) |> live(~p"/preauths")

      assert html =~ "No active preauthorizations."
    end
  end

  describe "revoke" do
    test "revoke works", %{conn: conn, alice: alice, preauth: preauth} do
      {:ok, view, html} = conn |> login(alice) |> live(~p"/preauths")

      assert html =~ "LuckyBot"

      html = render_click(view, "revoke", %{"id" => to_string(preauth.id)})

      assert html =~ "Preauthorization revoked."
      refute html =~ "LuckyBot"
      assert html =~ "No active preauthorizations."
    end
  end
end
