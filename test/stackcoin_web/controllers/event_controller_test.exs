defmodule StackCoinWebTest.EventControllerTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Event}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{bot: bot, recipient: recipient, bot_token: bot.token}
  end

  describe "GET /api/events" do
    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, ~p"/api/events")
      assert json_response(conn, 401)
    end

    test "returns events for authenticated user (bot)", %{
      conn: conn,
      bot: bot,
      bot_token: bot_token,
      recipient: recipient
    } do
      {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 10, "test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/events")

      response = json_response(conn, 200)
      assert is_list(response["events"])
      assert length(response["events"]) >= 1

      event = hd(response["events"])
      assert Map.has_key?(event, "id")
      assert Map.has_key?(event, "type")
      assert Map.has_key?(event, "data")
      assert Map.has_key?(event, "inserted_at")
    end

    test "filters events with since_id parameter", %{
      conn: conn,
      bot: bot,
      bot_token: bot_token,
      recipient: recipient
    } do
      {:ok, _txn1} = Bank.transfer_between_users(bot.user.id, recipient.id, 5, "first")
      {:ok, _txn2} = Bank.transfer_between_users(bot.user.id, recipient.id, 5, "second")

      events = Event.list_events_since(bot.user.id, 0)
      first_id = hd(events).id

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/events?since_id=#{first_id}")

      response = json_response(conn, 200)
      assert Enum.all?(response["events"], fn e -> e["id"] > first_id end)
    end
  end
end
