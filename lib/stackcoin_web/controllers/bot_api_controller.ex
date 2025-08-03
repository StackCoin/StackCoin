defmodule StackCoinWeb.BotApiController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.{Bank, User}

  def balance(conn, _params) do
    current_bot = conn.assigns.current_bot
    bot_user = current_bot.user
    json(conn, %{balance: bot_user.balance, username: bot_user.username})
  end

  def user_balance(conn, %{"user_id" => user_id_str}) do
    case Integer.parse(user_id_str) do
      {user_id, ""} ->
        case User.get_user_by_id(user_id) do
          {:ok, user} ->
            json(conn, %{balance: user.balance, username: user.username})

          {:error, :user_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "User not found"})
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid user ID"})
    end
  end

  def send_tokens(conn, %{"to_user_id" => to_user_id_str, "amount" => amount} = params) do
    current_bot = conn.assigns.current_bot
    label = Map.get(params, "label")

    with {to_user_id, ""} <- Integer.parse(to_user_id_str),
         {amount_int, ""} <- Integer.parse(to_string(amount)) do
      case Bank.bot_transfer(current_bot.token, to_user_id, amount_int, label) do
        {:ok, transaction} ->
          json(conn, %{
            success: true,
            transaction_id: transaction.id,
            amount: transaction.amount,
            from_new_balance: transaction.from_new_balance,
            to_new_balance: transaction.to_new_balance
          })

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Transfer failed: #{inspect(reason)}"})
      end
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid user ID or amount"})
    end
  end

  def send_tokens(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters: to_user_id, amount"})
  end
end
