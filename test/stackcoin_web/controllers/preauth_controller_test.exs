defmodule StackCoinWebTest.PreauthControllerTest do
  use StackCoinWeb.ConnCase

  import Mock

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Preauthorization}

  setup_with_mocks(
    [
      {Nostrum.Api.User, [], [create_dm: fn _user_id -> {:ok, %{id: 0}} end]},
      {Nostrum.Api.Message, [], [create: fn _channel_id, _msg -> {:ok, %{id: 0}} end]}
    ],
    %{conn: conn}
  ) do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{conn: conn, owner: owner, bot: bot, recipient: recipient, bot_token: bot.token}
  end

  # Tests for POST /api/user/:user_id/preauth
  describe "POST /api/user/:user_id/preauth" do
    test "creates a pending preauth", %{conn: conn, bot_token: bot_token, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/preauth", %{
          "max_amount" => 10,
          "window_hours" => 24
        })

      response = json_response(conn, 200)
      assert response["status"] == "pending"
      assert response["max_amount"] == 10
      assert response["window_hours"] == 24
      assert response["user_id"] == recipient.id
    end

    test "rejects duplicate preauth", %{conn: conn, bot_token: bot_token, recipient: recipient} do
      conn
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/user/#{recipient.id}/preauth", %{"max_amount" => 10, "window_hours" => 24})

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/preauth", %{
          "max_amount" => 20,
          "window_hours" => 48
        })

      assert json_response(conn2, 409)["error"] =~ "already exists"
    end

    test "rejects missing max_amount", %{conn: conn, bot_token: bot_token, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/preauth", %{"window_hours" => 24})

      assert json_response(conn, 400)["error"] =~ "max_amount"
    end

    test "rejects invalid max_amount", %{conn: conn, bot_token: bot_token, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/preauth", %{
          "max_amount" => 0,
          "window_hours" => 24
        })

      assert json_response(conn, 400)["error"] =~ "positive integer"
    end
  end

  # Tests for GET /api/preauths
  describe "GET /api/preauths" do
    test "lists preauths for bot", %{
      conn: conn,
      bot: bot,
      bot_token: bot_token,
      recipient: recipient
    } do
      Preauthorization.create_preauth(bot.user.id, recipient.id, 10, 24)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/preauths")

      response = json_response(conn, 200)
      assert length(response["preauths"]) == 1
    end

    test "filters by user_id", %{
      conn: conn,
      bot: bot,
      bot_token: bot_token,
      recipient: recipient
    } do
      {:ok, other} = User.create_user_account("555", "Other", balance: 0)
      Preauthorization.create_preauth(bot.user.id, recipient.id, 10, 24)
      Preauthorization.create_preauth(bot.user.id, other.id, 20, 48)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/preauths?user_id=#{recipient.id}")

      response = json_response(conn, 200)
      assert length(response["preauths"]) == 1
      assert hd(response["preauths"])["user_id"] == recipient.id
    end
  end

  # Tests for GET /api/preauth/:id
  describe "GET /api/preauth/:id" do
    test "returns preauth with remaining budget", %{
      conn: conn,
      bot: bot,
      bot_token: bot_token,
      recipient: recipient
    } do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, recipient.id, 10, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/preauth/#{preauth.id}")

      response = json_response(conn, 200)
      assert response["id"] == preauth.id
      assert response["remaining_budget"] == 10
    end

    test "returns 404 for non-existent", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/preauth/99999")

      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end

  # Tests for use_preauth on POST /api/user/:user_id/request
  describe "POST /api/user/:user_id/request with use_preauth" do
    test "instant transfer with active preauth", %{
      conn: conn,
      bot: bot,
      bot_token: bot_token,
      recipient: recipient
    } do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, recipient.id, 10, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/request", %{
          "amount" => 5,
          "use_preauth" => true,
          "label" => "Test preauth"
        })

      response = json_response(conn, 200)
      assert response["success"] == true
      assert response["status"] == "accepted"
      assert response["transaction_id"] != nil
    end

    test "falls back to pending without preauth", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/request", %{
          "amount" => 5,
          "use_preauth" => true
        })

      response = json_response(conn, 200)
      assert response["status"] == "pending"
    end

    test "returns error when budget exceeded", %{
      conn: conn,
      bot: bot,
      bot_token: bot_token,
      recipient: recipient
    } do
      {:ok, preauth} = Preauthorization.create_preauth(bot.user.id, recipient.id, 5, 24)
      {:ok, _} = Preauthorization.approve_preauth(preauth.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/request", %{
          "amount" => 10,
          "use_preauth" => true
        })

      response = json_response(conn, 400)
      assert response["error"] == "preauth_limit_exceeded"
    end
  end
end
