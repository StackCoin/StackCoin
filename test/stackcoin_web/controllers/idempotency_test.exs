defmodule StackCoinWebTest.IdempotencyTest do
  use StackCoinWeb.ConnCase

  alias StackCoin.Core.{User, Bot, Bank, Reserve}

  setup do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{bot: bot, recipient: recipient, bot_token: bot.token}
  end

  test "same idempotency key returns same response without double-sending", %{
    conn: conn,
    bot_token: bot_token,
    bot: bot,
    recipient: recipient
  } do
    conn1 =
      conn
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> put_req_header("idempotency-key", "unique-key-1")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 25})

    response1 = json_response(conn1, 200)
    assert response1["success"] == true
    assert response1["from_new_balance"] == 125

    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> put_req_header("idempotency-key", "unique-key-1")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 25})

    response2 = json_response(conn2, 200)
    assert response2 == response1

    {:ok, updated_bot} = User.get_user_by_id(bot.user.id)
    assert updated_bot.balance == 125
  end

  test "different idempotency keys create different transfers", %{
    conn: conn,
    bot_token: bot_token,
    recipient: recipient
  } do
    conn1 =
      conn
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> put_req_header("idempotency-key", "key-a")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 10})

    assert json_response(conn1, 200)["from_new_balance"] == 140

    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> put_req_header("idempotency-key", "key-b")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 10})

    assert json_response(conn2, 200)["from_new_balance"] == 130
  end

  test "requests without idempotency key work normally (no caching)", %{
    conn: conn,
    bot_token: bot_token,
    recipient: recipient
  } do
    conn1 =
      conn
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 10})

    assert json_response(conn1, 200)["from_new_balance"] == 140

    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/user/#{recipient.id}/send", %{"amount" => 10})

    assert json_response(conn2, 200)["from_new_balance"] == 130
  end
end
