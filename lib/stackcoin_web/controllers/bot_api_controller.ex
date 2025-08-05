defmodule StackCoinWeb.BotApiController do
  use StackCoinWeb, :controller

  alias StackCoin.Core.{Bank, User, Request}

  defp error_to_status_and_message(error) do
    case error do
      :bot_not_found ->
        {:unauthorized, "bot_not_found"}

      :user_not_found ->
        {:not_found, "user_not_found"}

      :invalid_amount ->
        {:bad_request, "invalid_amount"}

      :self_transfer ->
        {:bad_request, "self_transfer"}

      :user_banned ->
        {:forbidden, "user_banned"}

      :recipient_banned ->
        {:forbidden, "recipient_banned"}

      :insufficient_balance ->
        {:unprocessable_entity, "insufficient_balance"}

      :request_not_found ->
        {:not_found, "request_not_found"}

      :not_request_responder ->
        {:forbidden, "not_request_responder"}

      :not_involved_in_request ->
        {:forbidden, "not_involved_in_request"}

      :request_not_pending ->
        {:bad_request, "request_not_pending"}

      :conflicting_filters ->
        {:bad_request, "conflicting_filters"}

      %Ecto.Changeset{} = changeset ->
        # Handle validation errors from changesets
        cond do
          Keyword.has_key?(changeset.errors, :amount) ->
            {:bad_request, "invalid_amount"}

          Keyword.has_key?(changeset.errors, :responder_id) ->
            {:bad_request, "self_transfer"}

          true ->
            {:bad_request, "validation_error"}
        end

      error_atom when is_atom(error_atom) ->
        {:internal_server_error, Atom.to_string(error_atom)}

      _ ->
        {:internal_server_error, "unknown_error"}
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

    # Parse pagination parameters
    page =
      case Map.get(params, "page") do
        nil ->
          1

        page_str ->
          case Integer.parse(page_str) do
            {page_num, ""} when page_num > 0 -> page_num
            _ -> 1
          end
      end

    limit =
      case Map.get(params, "limit") do
        nil ->
          20

        limit_str ->
          case Integer.parse(limit_str) do
            {limit_num, ""} when limit_num > 0 -> limit_num
            _ -> 20
          end
      end

    offset = (page - 1) * limit

    opts = [role: role, limit: limit, offset: offset]
    opts = if status, do: Keyword.put(opts, :status, status), else: opts

    {:ok, %{requests: requests, total_count: total_count}} =
      Request.get_requests_for_user(current_bot.user.id, opts)

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

    total_pages = ceil(total_count / limit)

    json(conn, %{
      requests: formatted_requests,
      pagination: %{
        page: page,
        limit: limit,
        total: total_count,
        total_pages: total_pages
      }
    })
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

  def get_transactions(conn, params) do
    current_bot = conn.assigns.current_bot

    # Parse pagination parameters
    page =
      case Map.get(params, "page") do
        nil ->
          1

        page_str ->
          case Integer.parse(page_str) do
            {page_num, ""} when page_num > 0 -> page_num
            _ -> 1
          end
      end

    limit =
      case Map.get(params, "limit") do
        nil ->
          20

        limit_str ->
          case Integer.parse(limit_str) do
            {limit_num, ""} when limit_num > 0 -> limit_num
            _ -> 20
          end
      end

    offset = (page - 1) * limit

    # Parse filter parameters
    from_user_id =
      case Map.get(params, "from_user_id") do
        nil ->
          nil

        user_id_str ->
          case Integer.parse(user_id_str) do
            {user_id, ""} -> user_id
            _ -> nil
          end
      end

    to_user_id =
      case Map.get(params, "to_user_id") do
        nil ->
          nil

        user_id_str ->
          case Integer.parse(user_id_str) do
            {user_id, ""} -> user_id
            _ -> nil
          end
      end

    # Default to showing all bot transactions (includes_user_id = bot's user id)
    # unless specific from/to filters are provided
    includes_user_id =
      if from_user_id || to_user_id do
        nil
      else
        current_bot.user.id
      end

    opts = [limit: limit, offset: offset]
    opts = if from_user_id, do: Keyword.put(opts, :from_user_id, from_user_id), else: opts
    opts = if to_user_id, do: Keyword.put(opts, :to_user_id, to_user_id), else: opts

    opts =
      if includes_user_id, do: Keyword.put(opts, :includes_user_id, includes_user_id), else: opts

    case Bank.search_transactions(opts) do
      {:ok, %{transactions: transactions, total_count: total_count}} ->
        formatted_transactions =
          Enum.map(transactions, fn transaction ->
            %{
              id: transaction.id,
              from: %{
                id: transaction.from_id,
                username: transaction.from_username
              },
              to: %{
                id: transaction.to_id,
                username: transaction.to_username
              },
              amount: transaction.amount,
              time: transaction.time,
              label: transaction.label
            }
          end)

        total_pages = ceil(total_count / limit)

        json(conn, %{
          transactions: formatted_transactions,
          pagination: %{
            page: page,
            limit: limit,
            total: total_count,
            total_pages: total_pages
          }
        })

      {:error, reason} ->
        {status, message} = error_to_status_and_message(reason)

        conn
        |> put_status(status)
        |> json(%{error: message})
    end
  end
end
