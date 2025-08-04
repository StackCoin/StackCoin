defmodule StackCoinWeb.BotApiController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.{Bank, User, Request}

  defp error_to_status_and_message(error_atom) do
    case error_atom do
      :bot_not_found -> {:unauthorized, "bot_not_found"}
      :user_not_found -> {:not_found, "user_not_found"}
      :invalid_amount -> {:bad_request, "invalid_amount"}
      :self_transfer -> {:bad_request, "self_transfer"}
      :user_banned -> {:forbidden, "user_banned"}
      :recipient_banned -> {:forbidden, "recipient_banned"}
      :insufficient_balance -> {:unprocessable_entity, "insufficient_balance"}
      :request_not_found -> {:not_found, "request_not_found"}
      :not_request_responder -> {:forbidden, "not_request_responder"}
      :request_not_pending -> {:bad_request, "request_not_pending"}
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

  def create_request(conn, %{"user_id" => user_id_str, "amount" => amount} = params) do
    current_bot = conn.assigns.current_bot
    label = Map.get(params, "label")

    case Integer.parse(user_id_str) do
      {responder_id, ""} ->
        cond do
          not is_integer(amount) ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Invalid amount. Must be an integer."})

          true ->
            case Request.create_request(current_bot.user.id, responder_id, amount, label) do
              {:ok, request} ->
                json(conn, %{
                  success: true,
                  request_id: request.id,
                  amount: request.amount,
                  status: request.status,
                  requested_at: request.requested_at,
                  requester: %{
                    id: request.requester.id,
                    username: request.requester.username
                  },
                  responder: %{
                    id: request.responder.id,
                    username: request.responder.username
                  }
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

  def create_request(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters: user_id, amount"})
  end

  def get_requests(conn, params) do
    current_bot = conn.assigns.current_bot

    # Parse query parameters
    role =
      case Map.get(params, "role") do
        "requester" -> :requester
        "responder" -> :responder
        # default to requester (requests made by bot)
        _ -> :requester
      end

    status = Map.get(params, "status")

    opts = [role: role]
    opts = if status, do: Keyword.put(opts, :status, status), else: opts

    case Request.get_requests_for_user(current_bot.user.id, opts) do
      {:ok, requests} ->
        formatted_requests =
          Enum.map(requests, fn request ->
            %{
              id: request.id,
              amount: request.amount,
              status: request.status,
              requested_at: request.requested_at,
              resolved_at: request.resolved_at,
              label: request.label,
              requester: %{
                id: request.requester.id,
                username: request.requester.username
              },
              responder: %{
                id: request.responder.id,
                username: request.responder.username
              },
              transaction_id: if(request.transaction, do: request.transaction.id, else: nil)
            }
          end)

        json(conn, %{requests: formatted_requests})

      {:error, reason} ->
        {status, message} = error_to_status_and_message(reason)

        conn
        |> put_status(status)
        |> json(%{error: message})
    end
  end

  def accept_request(conn, %{"request_id" => request_id_str}) do
    current_bot = conn.assigns.current_bot

    case Integer.parse(request_id_str) do
      {request_id, ""} ->
        case Request.accept_request(request_id, current_bot.user.id) do
          {:ok, request} ->
            json(conn, %{
              success: true,
              request_id: request.id,
              status: request.status,
              resolved_at: request.resolved_at,
              transaction_id: if(request.transaction, do: request.transaction.id, else: nil)
            })

          {:error, reason} ->
            {status, message} = error_to_status_and_message(reason)

            conn
            |> put_status(status)
            |> json(%{error: message})
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid request ID"})
    end
  end

  def accept_request(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: request_id"})
  end

  def deny_request(conn, %{"request_id" => request_id_str}) do
    current_bot = conn.assigns.current_bot

    case Integer.parse(request_id_str) do
      {request_id, ""} ->
        case Request.deny_request(request_id, current_bot.user.id) do
          {:ok, request} ->
            json(conn, %{
              success: true,
              request_id: request.id,
              status: request.status,
              resolved_at: request.resolved_at
            })

          {:error, reason} ->
            {status, message} = error_to_status_and_message(reason)

            conn
            |> put_status(status)
            |> json(%{error: message})
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid request ID"})
    end
  end

  def deny_request(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: request_id"})
  end
end
