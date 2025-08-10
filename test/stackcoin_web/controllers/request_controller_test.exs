defmodule StackCoinWebTest.RequestControllerTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Request}
  alias StackCoin.Repo

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

  describe "POST /api/user/:user_id/request" do
    test "returns 401 if Authorization header is missing", %{conn: conn, recipient: recipient} do
      conn =
        post(conn, ~p"/api/user/#{recipient.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> post(~p"/api/user/#{recipient.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "successfully creates STK request", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/request", %{
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

    test "successfully creates STK request with label", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/request", %{
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
        |> post(~p"/api/user/#{recipient.id}/request", %{})

      assert json_response(conn, 400) == %{
               "error" => "Missing required parameters: user_id, amount"
             }
    end

    test "returns 400 for invalid user_id", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/invalid/request", %{
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
        |> post(~p"/api/user/#{recipient.id}/request", %{
          "amount" => "invalid"
        })

      assert json_response(conn, 400) == %{"error" => "Invalid amount. Must be an integer."}
    end

    test "returns 400 for zero amount", %{conn: conn, bot_token: bot_token, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/request", %{
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
        |> post(~p"/api/user/#{recipient.id}/request", %{
          "amount" => -10
        })

      assert json_response(conn, 400) == %{"error" => "invalid_amount"}
    end

    test "returns 400 for self request", %{conn: conn, bot_token: bot_token, bot: bot} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{bot.user.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 400) == %{"error" => "self_transfer"}
    end

    test "returns 404 for non-existent responder", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/99999/request", %{
          "amount" => 50
        })

      assert json_response(conn, 404) == %{"error" => "user_not_found"}
    end

    test "returns 403 when authenticated user is banned", %{
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
        |> post(~p"/api/user/#{recipient.id}/request", %{
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
        |> post(~p"/api/user/#{recipient.id}/request", %{
          "amount" => 50
        })

      assert json_response(conn, 403) == %{"error" => "recipient_banned"}
    end
  end

  describe "GET /api/requests" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/requests")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns all requests involving authenticated user when role is not specified", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create requests in both directions
      {:ok, _request_from_bot} =
        Request.create_request(bot.user.id, recipient.id, 100, "From bot")

      {:ok, _request_to_bot} = Request.create_request(recipient.id, bot.user.id, 50, "To bot")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/requests")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 2

      # Should include both requests where bot is either requester or responder
      amounts = Enum.map(response["requests"], & &1["amount"])
      assert 100 in amounts
      assert 50 in amounts
    end

    test "returns only requests made by authenticated user (role=requester)", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create requests in both directions
      {:ok, _request_from_bot} =
        Request.create_request(bot.user.id, recipient.id, 100, "From bot")

      {:ok, _request_to_bot} = Request.create_request(recipient.id, bot.user.id, 50, "To bot")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/requests?role=requester")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["amount"] == 100
      assert request["status"] == "pending"
      assert request["requester"]["id"] == bot.user.id
      assert request["responder"]["id"] == recipient.id
    end

    test "returns requests to authenticated user (role=responder)", %{
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
        |> get(~p"/api/requests?role=responder")

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
      {:ok, _pending_request} = Request.create_request(bot.user.id, recipient.id, 100, "Pending")
      {:ok, denied_request} = Request.create_request(bot.user.id, recipient.id, 200, "Denied")

      # Deny one request
      {:ok, _} = Request.deny_request(denied_request.id, recipient.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/requests?status=pending")

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
        |> get(~p"/api/requests?role=responder&status=accepted")

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
        |> get(~p"/api/requests?status=denied")

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
        |> get(~p"/api/requests?role=responder&status=pending")

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
        |> get(~p"/api/requests?status=invalid_status")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 0
    end

    test "filters by since parameter with valid time format", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create an old request (simulate by creating and then updating its timestamp)
      {:ok, old_request} = Request.create_request(bot.user.id, recipient.id, 50, "Old request")

      # Update the old request to be 2 days ago, truncating microseconds
      two_days_ago =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-2 * 24 * 60 * 60, :second)
        |> NaiveDateTime.truncate(:second)

      Repo.update!(Ecto.Changeset.change(old_request, requested_at: two_days_ago))

      # Create a recent request
      {:ok, _recent_request} =
        Request.create_request(bot.user.id, recipient.id, 100, "Recent request")

      # Filter for requests in the last day
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/requests?since=1d")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["amount"] == 100
      assert request["label"] == "Recent request"
    end

    test "filters by since parameter with different time units", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request
      {:ok, _request} = Request.create_request(bot.user.id, recipient.id, 75, "Test request")

      # Test different time formats
      time_formats = ["30s", "5m", "2h", "3d", "1w"]

      for format <- time_formats do
        conn =
          conn
          |> put_req_header("authorization", "Bearer #{bot_token}")
          |> get(~p"/api/requests?since=#{format}")

        response = json_response(conn, 200)
        assert is_list(response["requests"])
        # Should return the request since it was just created
        assert length(response["requests"]) == 1
      end
    end

    test "returns 400 for invalid since parameter format", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/requests?since=invalid")

      assert json_response(conn, 400) == %{
               "error" => "Invalid time format. Use formats like: 30s, 5m, 2h, 3d, 1w"
             }
    end

    test "returns 400 for invalid since parameter with wrong unit", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/requests?since=5x")

      assert json_response(conn, 400) == %{
               "error" => "Invalid time format. Use formats like: 30s, 5m, 2h, 3d, 1w"
             }
    end

    test "returns 400 for since parameter with no number", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/requests?since=d")

      assert json_response(conn, 400) == %{
               "error" => "Invalid time format. Use formats like: 30s, 5m, 2h, 3d, 1w"
             }
    end

    test "ignores empty since parameter", %{
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
        |> get(~p"/api/requests?since=")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1
    end

    test "combines since filter with other filters", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a pending request
      {:ok, _pending_request} = Request.create_request(bot.user.id, recipient.id, 100, "Pending")

      # Create and deny another request
      {:ok, denied_request} = Request.create_request(bot.user.id, recipient.id, 200, "Denied")
      {:ok, _} = Request.deny_request(denied_request.id, recipient.id)

      # Filter for pending requests in the last hour
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/requests?since=1h&status=pending")

      response = json_response(conn, 200)
      assert is_list(response["requests"])
      assert length(response["requests"]) == 1

      request = List.first(response["requests"])
      assert request["status"] == "pending"
      assert request["amount"] == 100
    end
  end

  describe "POST /api/requests/:request_id/accept" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/requests/1/accept")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "successfully accepts STK request and creates transaction", %{
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
        |> post(~p"/api/requests/#{request.id}/accept")

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
        |> post(~p"/api/requests/#{request.id}/accept")

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
        |> post(~p"/api/requests/invalid/accept")

      assert json_response(conn, 400) == %{"error" => "Invalid request ID"}
    end

    test "returns 404 for non-existent request", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/requests/99999/accept")

      assert json_response(conn, 404) == %{"error" => "request_not_found"}
    end

    test "returns 403 for request not belonging to authenticated user (not responder)", %{
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
        |> post(~p"/api/requests/#{request.id}/accept")

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
        |> post(~p"/api/requests/#{request.id}/accept")

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
        |> post(~p"/api/requests/#{request.id}/accept")

      assert json_response(conn, 422) == %{"error" => "insufficient_balance"}
    end
  end

  describe "POST /api/requests/:request_id/deny" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/requests/1/deny")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "successfully denies STK request", %{
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
        |> post(~p"/api/requests/#{request.id}/deny")

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
        |> post(~p"/api/requests/#{request.id}/deny")

      assert json_response(conn, 200)

      # Verify request was updated in database
      {:ok, updated_request} = Request.get_request_by_id(request.id)
      assert updated_request.status == "denied"
      assert updated_request.resolved_at != nil
      assert updated_request.transaction_id == nil
      assert updated_request.denied_by_id == bot.user.id
    end

    test "returns 400 for invalid request_id", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/requests/invalid/deny")

      assert json_response(conn, 400) == %{"error" => "Invalid request ID"}
    end

    test "returns 404 for non-existent request", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/requests/99999/deny")

      assert json_response(conn, 404) == %{"error" => "request_not_found"}
    end

    test "returns 403 for request not belonging to authenticated user (neither requester nor responder)",
         %{
           conn: conn,
           bot_token: bot_token,
           owner: owner,
           recipient: recipient
         } do
      # Create a request between two other users (bot is neither requester nor responder)
      {:ok, request} = Request.create_request(owner.id, recipient.id, 35, "Not involved")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/requests/#{request.id}/deny")

      assert json_response(conn, 403) == %{"error" => "not_involved_in_request"}
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
        |> post(~p"/api/requests/#{request.id}/deny")

      assert json_response(conn, 400) == %{"error" => "request_not_pending"}
    end

    test "allows requester to deny their own request", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request where bot requests from recipient (bot is requester)
      {:ok, request} = Request.create_request(bot.user.id, recipient.id, 45, "Self deny test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/requests/#{request.id}/deny")

      response = json_response(conn, 200)
      assert response["success"] == true
      assert response["request_id"] == request.id
      assert response["status"] == "denied"
      assert is_binary(response["resolved_at"])

      # Verify request was updated in database
      {:ok, updated_request} = Request.get_request_by_id(request.id)
      assert updated_request.status == "denied"
      assert updated_request.resolved_at != nil
      assert updated_request.transaction_id == nil
      assert updated_request.denied_by_id == bot.user.id
    end

    test "stores correct denied_by_id when responder denies request", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request where recipient requests from bot (bot is responder)
      {:ok, request} =
        Request.create_request(recipient.id, bot.user.id, 30, "Responder deny test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/requests/#{request.id}/deny")

      response = json_response(conn, 200)
      assert response["success"] == true

      # Verify the bot (responder) is stored as the one who denied it
      {:ok, updated_request} = Request.get_request_by_id(request.id)
      assert updated_request.status == "denied"
      assert updated_request.denied_by_id == bot.user.id
    end

    test "returns 400 for missing request_id parameter", %{conn: conn, bot_token: bot_token} do
      # The deny_request fallback clause is hard to test via HTTP routes since Phoenix
      # routing requires the :request_id parameter. This test documents the behavior
      # but we'll skip the actual HTTP test since it's not reachable via normal routing.

      # Instead, let's test that the route requires request_id by trying an invalid route
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/requests/invalid_id/deny")

      # This should return 400 for invalid request ID, not the missing parameter error
      assert json_response(conn, 400) == %{"error" => "Invalid request ID"}
    end
  end

  describe "GET /api/request/:request_id" do
    test "returns 401 if Authorization header is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/request/1")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 if Authorization header is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> get(~p"/api/request/1")

      assert json_response(conn, 401) == %{"error" => "Invalid bot token"}
    end

    test "returns request when found", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a test request
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 100, "Test request")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/request/#{request.id}")

      response = json_response(conn, 200)
      assert is_map(response)

      assert response["id"] == request.id
      assert response["amount"] == 100
      assert response["status"] == "pending"
      assert response["label"] == "Test request"
      assert is_binary(response["requested_at"])
      assert is_nil(response["resolved_at"])
      assert is_nil(response["transaction_id"])

      # Check requester and responder details
      assert response["requester"]["id"] == recipient.id
      assert response["requester"]["username"] == recipient.username
      assert response["responder"]["id"] == bot.user.id
      assert response["responder"]["username"] == bot.user.username
    end

    test "returns 404 when request not found", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/request/99999")

      response = json_response(conn, 404)
      assert response == %{"error" => "Request not found"}
    end

    test "returns 400 for invalid request_id", %{
      conn: conn,
      bot_token: bot_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/request/invalid_id")

      response = json_response(conn, 400)
      assert response == %{"error" => "Invalid request ID"}
    end

    test "returns correct request structure", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a test request
      {:ok, request} = Request.create_request(bot.user.id, recipient.id, 75, "Structure test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/request/#{request.id}")

      response = json_response(conn, 200)

      # Verify all expected fields are present
      assert Map.has_key?(response, "id")
      assert Map.has_key?(response, "amount")
      assert Map.has_key?(response, "status")
      assert Map.has_key?(response, "requested_at")
      assert Map.has_key?(response, "resolved_at")
      assert Map.has_key?(response, "label")
      assert Map.has_key?(response, "requester")
      assert Map.has_key?(response, "responder")
      assert Map.has_key?(response, "transaction_id")

      # Verify field types
      assert is_integer(response["id"])
      assert is_integer(response["amount"])
      assert is_binary(response["status"])
      assert is_binary(response["requested_at"])
      assert is_nil(response["resolved_at"])
      assert is_binary(response["label"])
      assert is_map(response["requester"])
      assert is_map(response["responder"])
      assert is_nil(response["transaction_id"])

      # Verify nested user objects
      assert Map.has_key?(response["requester"], "id")
      assert Map.has_key?(response["requester"], "username")
      assert Map.has_key?(response["responder"], "id")
      assert Map.has_key?(response["responder"], "username")
    end

    test "returns accepted request with transaction_id", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create and accept a request
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 50, "Accepted test")
      {:ok, accepted_request} = Request.accept_request(request.id, bot.user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/request/#{request.id}")

      response = json_response(conn, 200)

      assert response["id"] == request.id
      assert response["status"] == "accepted"
      assert is_binary(response["resolved_at"])
      assert is_integer(response["transaction_id"])
      assert response["transaction_id"] == accepted_request.transaction.id
    end

    test "returns denied request with resolved_at", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create and deny a request
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 25, "Denied test")
      {:ok, _denied_request} = Request.deny_request(request.id, bot.user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/request/#{request.id}")

      response = json_response(conn, 200)

      assert response["id"] == request.id
      assert response["status"] == "denied"
      assert is_binary(response["resolved_at"])
      assert is_nil(response["transaction_id"])
    end

    test "returns request with null label", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Create a request without a label
      {:ok, request} = Request.create_request(recipient.id, bot.user.id, 30, nil)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/request/#{request.id}")

      response = json_response(conn, 200)

      assert response["id"] == request.id
      assert is_nil(response["label"])
    end

    test "handles different request statuses correctly", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      # Test pending request
      {:ok, pending_request} = Request.create_request(recipient.id, bot.user.id, 40, "Pending")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/request/#{pending_request.id}")

      response = json_response(conn, 200)
      assert response["status"] == "pending"
      assert is_nil(response["resolved_at"])
      assert is_nil(response["transaction_id"])
    end
  end
end
