defmodule StackCoinWebTest.TransferControllerTest do
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

  describe "POST /api/user/:user_id/send" do
    test "returns 401 if Authorization header is missing", %{conn: conn, recipient: recipient} do
      conn =
        post(conn, ~p"/api/user/#{recipient.id}/send", %{
          "amount" => 50
        })

      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "successfully sends STK", %{
      conn: conn,
      bot_token: bot_token,
      bot: bot,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/send", %{
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

    test "successfully sends STK with label", %{
      conn: conn,
      bot_token: bot_token,
      recipient: recipient
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/send", %{
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
        |> post(~p"/api/user/#{recipient.id}/send", %{})

      assert json_response(conn, 400) == %{
               "error" => "Missing required parameters: amount"
             }
    end

    test "returns 400 for invalid user_id", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/invalid/send", %{
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
        |> post(~p"/api/user/#{recipient.id}/send", %{
          "amount" => "invalid"
        })

      assert json_response(conn, 400) == %{"error" => "Invalid amount. Must be an integer."}
    end

    test "returns 400 for zero amount", %{conn: conn, bot_token: bot_token, recipient: recipient} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{recipient.id}/send", %{
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
        |> post(~p"/api/user/#{recipient.id}/send", %{
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
        |> post(~p"/api/user/#{recipient.id}/send", %{
          "amount" => 200
        })

      assert json_response(conn, 422) == %{"error" => "insufficient_balance"}
    end

    test "returns 400 for self transfer", %{conn: conn, bot_token: bot_token, bot: bot} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/#{bot.user.id}/send", %{
          "amount" => 50
        })

      assert json_response(conn, 400) == %{"error" => "self_transfer"}
    end

    test "returns 404 for non-existent recipient", %{conn: conn, bot_token: bot_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/user/99999/send", %{
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
        |> post(~p"/api/user/#{recipient.id}/send", %{
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
        |> post(~p"/api/user/#{recipient.id}/send", %{
          "amount" => 50
        })

      assert json_response(conn, 403) == %{"error" => "recipient_banned"}
    end
  end
end
