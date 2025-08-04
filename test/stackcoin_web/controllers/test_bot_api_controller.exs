defmodule StackCoinWebTest.BotApiController do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Request}

  setup do
    # Create reserve user (ID 1)
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

  describe "GET /api/bot/self/balance" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/bot/self/balance")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> get(~p"/api/bot/self/balance")

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "returns bot balance when authenticated", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/self/balance")

      response = json_response(conn, 200)
      assert response["balance"] == 150
      assert response["username"] == "TestBot"
    end
  end

  describe "GET /api/bot/user/:user_id/balance" do
    test "returns 401 if Authorization header is missing", %{conn: conn, recipient: recipient} do
      conn = get(conn, ~p"/api/bot/user/#{recipient.id}/balance")
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
        |> get(~p"/api/bot/user/#{recipient.id}/balance")

      response = json_response(conn, 200)
      assert response["balance"] == 100
      assert response["username"] == "RecipientUser"
    end

    test "returns 404 for non-existent user", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/user/99999/balance")

      assert json_response(conn, 404) == %{"error" => "User not found"}
    end

    test "returns 400 for invalid user ID", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/user/invalid/balance")

      assert json_response(conn, 400) == %{"error" => "Invalid user ID"}
    end
  end

  describe "POST /api/bot/user/:user_id/send" do
    test "returns 401 if Authorization header is missing", %{conn: conn, recipient: recipient} do
      conn =
        post(conn, ~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => 50
        })

      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "successfully sends tokens", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => 50
        })

      response = json_response(conn, 200)
      assert response["success"] == true
      assert response["amount"] == 50
      assert response["from_new_balance"] == 100
      assert response["to_new_balance"] == 150
      assert is_integer(response["transaction_id"])

      # Verify balances were updated
      {:ok, updated_bot} = User.get_user_by_id(bot.user.id)
      {:ok, updated_recipient} = User.get_user_by_id(recipient.id)
      assert updated_bot.balance == 100
      assert updated_recipient.balance == 150
    end

    test "successfully sends tokens with label", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => 25,
          "label" => "Test payment"
        })

      response = json_response(conn, 200)
      assert response["success"] == true
      assert response["amount"] == 25
    end

    test "returns 400 for missing parameters", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{})

      assert json_response(conn, 400) == %{
               "error" => "Missing required parameters: amount"
             }
    end

    test "returns 400 for invalid user_id", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/invalid/send", %{
          "amount" => 50
        })

      assert json_response(conn, 400) == %{
               "error" => "Invalid user ID"
             }
    end

    test "returns 400 for invalid amount", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => "invalid"
        })

      assert json_response(conn, 400) == %{"error" => "Invalid amount. Must be an integer."}
    end

    test "returns 400 for zero amount", %{conn: conn, bot_token: bot_token, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => 0
        })

      assert json_response(conn, 400) == %{"error" => "invalid_amount"}
    end

    test "returns 400 for negative amount", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => -10
        })

      assert json_response(conn, 400) == %{"error" => "invalid_amount"}
    end

    test "returns 422 for insufficient balance", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => 200
        })

      assert json_response(conn, 422) == %{"error" => "insufficient_balance"}
    end

    test "returns 400 for self transfer", %{conn: conn, bot_token: bot_token, bot: bot} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{bot.user.id}/send", %{
          "amount" => 50
        })

      assert json_response(conn, 400) == %{"error" => "self_transfer"}
    end

    test "returns 404 for non-existent recipient", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/99999/send", %{
          "amount" => 50
        })

      assert json_response(conn, 404) == %{"error" => "user_not_found"}
    end

    test "returns 403 when bot user is banned", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Ban the bot user
      {:ok, _banned_bot} = User.ban_user(bot.user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => 50
        })

      assert json_response(conn, 403) == %{"error" => "user_banned"}
    end

    test "returns 403 when recipient is banned", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      # Ban the recipient
      {:ok, _banned_recipient} = User.ban_user(recipient)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/send", %{
          "amount" => 50
        })

      assert json_response(conn, 403) == %{"error" => "recipient_banned"}
    end
  end

  describe "POST /api/bot/user/:user_id/request" do
    test "returns 401 if Authorization header is missing", %{conn: conn, recipient: recipient} do
      conn =
        post(conn, ~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "successfully creates request", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => 75
        })

      response = json_response(conn, 200)
      assert response["success"] == true
      assert response["amount"] == 75
      assert response["status"] == "pending"
      assert is_integer(response["request_id"])
      assert response["requester"]["id"] == bot.user.id
      assert response["requester"]["username"] == "TestBot"
      assert response["responder"]["id"] == recipient.id
      assert response["responder"]["username"] == "RecipientUser"
      assert is_binary(response["requested_at"])
    end

    test "successfully creates request with label", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => 30,
          "label" => "Payment for services"
        })

      response = json_response(conn, 200)
      assert response["success"] == true
      assert response["amount"] == 30
      assert response["status"] == "pending"
    end

    test "returns 400 for missing parameters", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{})

      assert json_response(conn, 400) == %{
               "error" => "Missing required parameters: user_id, amount"
             }
    end

    test "returns 400 for invalid user_id", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/invalid/request", %{
          "amount" => 50
        })

      assert json_response(conn, 400) == %{
               "error" => "Invalid user ID"
             }
    end

    test "returns 400 for invalid amount", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => "invalid"
        })

      assert json_response(conn, 400) == %{"error" => "Invalid amount. Must be an integer."}
    end

    test "returns 400 for zero amount", %{conn: conn, bot_token: bot_token, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => 0
        })

      assert json_response(conn, 400) == %{"error" => "invalid_amount"}
    end

    test "returns 400 for negative amount", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => -10
        })

      assert json_response(conn, 400) == %{"error" => "invalid_amount"}
    end

    test "returns 400 for self request", %{conn: conn, bot_token: bot_token, bot: bot} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{bot.user.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 400) == %{"error" => "self_transfer"}
    end

    test "returns 404 for non-existent responder", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/99999/request", %{
          "amount" => 50
        })

      assert json_response(conn, 404) == %{"error" => "user_not_found"}
    end

    test "returns 403 when bot user is banned", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Ban the bot user
      {:ok, _banned_bot} = User.ban_user(bot.user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 403) == %{"error" => "user_banned"}
    end

    test "returns 403 when responder is banned", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      # Ban the recipient
      {:ok, _banned_recipient} = User.ban_user(recipient)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/user/#{recipient.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 403) == %{"error" => "recipient_banned"}
    end
  end

  describe "GET /api/bot/requests" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/bot/requests")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns all requests made by bot (default role=requester)", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a test request
      {:ok, _request} = Request.create_request(bot.user.id, recipient.id, 100, "Test request")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/requests")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["amount"] == 100
      assert request["status"] == "pending"
      assert request["requester"]["id"] == bot.user.id
      assert request["responder"]["id"] == recipient.id
      assert is_binary(request["requested_at"])
    end

    test "returns requests to bot (role=responder)", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a test request where recipient requests from bot
      {:ok, _request} = Request.create_request(recipient.id, bot.user.id, 50, "Request to bot")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/requests?role=responder")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["amount"] == 50
      assert request["status"] == "pending"
      assert request["requester"]["id"] == recipient.id
      assert request["responder"]["id"] == bot.user.id
    end

    test "filters by status=pending", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create requests with different statuses
      {:ok, pending_request} = Request.create_request(bot.user.id, recipient.id, 100, "Pending")
      {:ok, denied_request} = Request.create_request(bot.user.id, recipient.id, 200, "Denied")

      # Deny one request
      {:ok, _} = Request.deny_request(denied_request.id, recipient.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/requests?status=pending")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["status"] == "pending"
      assert request["amount"] == 100
    end

    test "filters by status=accepted", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request and accept it
      {:ok, accepted_request} = Request.create_request(recipient.id, bot.user.id, 75, "Accepted")
      {:ok, _} = Request.accept_request(accepted_request.id, bot.user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/requests?role=responder&status=accepted")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["status"] == "accepted"
      assert request["amount"] == 75
      assert is_integer(request["transaction_id"])
    end

    test "filters by status=denied", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request and deny it
      {:ok, denied_request} = Request.create_request(bot.user.id, recipient.id, 25, "Denied")
      {:ok, _} = Request.deny_request(denied_request.id, recipient.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/requests?status=denied")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["status"] == "denied"
      assert request["amount"] == 25
      assert is_nil(request["transaction_id"])
    end

    test "combines role=responder and status=pending", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create requests in both directions
      {:ok, _request_from_bot} =
        Request.create_request(bot.user.id, recipient.id, 100, "From bot")

      {:ok, _request_to_bot} = Request.create_request(recipient.id, bot.user.id, 200, "To bot")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/requests?role=responder&status=pending")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["status"] == "pending"
      assert request["amount"] == 200
      assert request["requester"]["id"] == recipient.id
      assert request["responder"]["id"] == bot.user.id
    end

    test "returns empty array for invalid status", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a test request
      {:ok, _request} = Request.create_request(bot.user.id, recipient.id, 100, "Test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/bot/requests?status=invalid_status")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 0
    end
  end

  describe "POST /api/bot/requests/:request_id/accept" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/bot/requests/1/accept")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "successfully accepts request and creates transaction", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request where recipient requests from bot
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 80, "Accept test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/accept")

      response = json_response(conn, 200)
      assert response["success"] == true
      assert response["request_id"] == request.id
      assert response["status"] == "accepted"
      assert is_binary(response["resolved_at"])
      assert is_integer(response["transaction_id"])
    end

    test "updates balances correctly after accept", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request where recipient requests from bot
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 60, "Balance test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/accept")

      assert json_response(conn, 200)

      # Verify balances were updated
      {:ok, updated_bot} = User.get_user_by_id(bot.user.id)
      {:ok, updated_recipient} = User.get_user_by_id(recipient.id)
      # 150 - 60
      assert updated_bot.balance == 90
      # 100 + 60
      assert updated_recipient.balance == 160
    end

    test "returns 400 for invalid request_id", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/invalid/accept")

      assert json_response(conn, 400) == %{"error" => "Invalid request ID"}
    end

    test "returns 404 for non-existent request", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/99999/accept")

      assert json_response(conn, 404) == %{"error" => "request_not_found"}
    end

    test "returns 403 for request not belonging to bot (not responder)", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request where bot requests from recipient (bot is requester, not responder)
      {:ok, request} = Request.create_request(bot.user.id, recipient.id, 50, "Wrong responder")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/accept")

      assert json_response(conn, 403) == %{"error" => "not_request_responder"}
    end

    test "returns 400 for request not in pending status", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create and deny a request
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 40, "Already denied")
      {:ok, _} = Request.deny_request(request.id, bot.user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/accept")

      assert json_response(conn, 400) == %{"error" => "request_not_pending"}
    end

    test "returns 422 for insufficient balance", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request for more than bot has
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 200, "Too much")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/accept")

      assert json_response(conn, 422) == %{"error" => "insufficient_balance"}
    end

    test "returns 400 for missing parameters", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests//accept")

      assert json_response(conn, 400) == %{"error" => "Missing required parameter: request_id"}
    end
  end

  describe "POST /api/bot/requests/:request_id/deny" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/bot/requests/1/deny")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "successfully denies request", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request where recipient requests from bot
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 90, "Deny test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/deny")

      response = json_response(conn, 200)
      assert response["success"] == true
      assert response["request_id"] == request.id
      assert response["status"] == "denied"
      assert is_binary(response["resolved_at"])
    end

    test "updates request status and resolved_at correctly", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request where recipient requests from bot
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 70, "Status test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/deny")

      assert json_response(conn, 200)

      # Verify request was updated in database
      {:ok, updated_request} = Request.get_request_by_id(request.id)
      assert updated_request.status == "denied"
      assert updated_request.resolved_at != nil
      assert updated_request.transaction_id == nil
    end

    test "returns 400 for invalid request_id", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/invalid/deny")

      assert json_response(conn, 400) == %{"error" => "Invalid request ID"}
    end

    test "returns 404 for non-existent request", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/99999/deny")

      assert json_response(conn, 404) == %{"error" => "request_not_found"}
    end

    test "returns 403 for request not belonging to bot (not responder)", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request where bot requests from recipient (bot is requester, not responder)
      {:ok, request} = Request.create_request(bot.user.id, recipient.id, 35, "Wrong responder")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/deny")

      assert json_response(conn, 403) == %{"error" => "not_request_responder"}
    end

    test "returns 400 for request not in pending status", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create and accept a request
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 20, "Already accepted")
      {:ok, _} = Request.accept_request(request.id, bot.user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests/#{request.id}/deny")

      assert json_response(conn, 400) == %{"error" => "request_not_pending"}
    end

    test "returns 400 for missing parameters", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/bot/requests//deny")

      assert json_response(conn, 400) == %{"error" => "Missing required parameter: request_id"}
    end
  end
end
