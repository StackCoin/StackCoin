defmodule StackCoinWeb.BotApiController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.{Bank, User}

  defp error_to_status_and_message(error_atom) do
    case error_atom do
      :bot_not_found -> {:unauthorized, "bot_not_found"}
      :user_not_found -> {:not_found, "user_not_found"}
      :invalid_amount -> {:bad_request, "invalid_amount"}
      :self_transfer -> {:bad_request, "self_transfer"}
      :user_banned -> {:forbidden, "user_banned"}
      :recipient_banned -> {:forbidden, "recipient_banned"}
      :insufficient_balance -> {:unprocessable_entity, "insufficient_balance"}
      _ -> {:internal_server_error, Atom.to_string(error_atom)}
    end
  end

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

  def send_tokens(conn, %{"user_id" => user_id_str, "amount" => amount} = params) do
    current_bot = conn.assigns.current_bot
    label = Map.get(params, "label")

    case Integer.parse(user_id_str) do
      {to_user_id, ""} ->
        cond do
          not is_integer(amount) ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Invalid amount. Must be an integer."})

          true ->
            case Bank.bot_transfer(current_bot.token, to_user_id, amount, label) do
              {:ok, transaction} ->
                json(conn, %{
                  success: true,
                  transaction_id: transaction.id,
                  amount: transaction.amount,
                  from_new_balance: transaction.from_new_balance,
                  to_new_balance: transaction.to_new_balance
                })

              {:error, reason} ->
                {status, message} = error_to_status_and_message(reason)

                conn
                |> put_status(status)
                |> json(%{error: message})
            end
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid user ID"})
    end
  end

  def send_tokens(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters: amount"})
  end
end
