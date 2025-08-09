defmodule StackCoinWebTest.BalanceControllerTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)

    # Create owner user
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)

    # Create bot user
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")

    # Create recipient user
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)

    # Give bot some initial balance using reserve pump
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{
      owner: owner,
      bot: bot,
      recipient: recipient,
      bot_token: bot.token
    }
  end

  describe "GET /api/balance" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/balance")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> get(~p"/api/balance")

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "returns authenticated user's balance", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/balance")

      response = json_response(conn, 200)
      assert response["balance"] == 150
      assert response["username"] == "TestBot"
    end
  end

  describe "GET /api/users/:user_id/balance" do
    test "returns 401 if Authorization header is missing", %{conn: conn, recipient: recipient} do
      conn = get(conn, ~p"/api/users/#{recipient.id}/balance")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns user balance when authenticated", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users/#{recipient.id}/balance")

      response = json_response(conn, 200)
      assert response["balance"] == 100
      assert response["username"] == "RecipientUser"
    end

    test "returns 404 for non-existent user", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users/99999/balance")

      assert json_response(conn, 404) == %{"error" => "User not found"}
    end

    test "returns 400 for invalid user ID", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/users/invalid/balance")

      assert json_response(conn, 400) == %{"error" => "Invalid user ID"}
    end
  end
end
