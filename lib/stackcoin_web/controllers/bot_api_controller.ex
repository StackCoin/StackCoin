defmodule StackCoinWeb.BotApiController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

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

  operation :balance,
    summary: "Get bot's own balance",
    description: "Returns the balance and username of the bot's own user.",
    responses: [
      ok: {"Balance response", "application/json", StackCoinWeb.Schemas.BalanceResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

  def balance(conn, _params) do
    current_bot = conn.assigns.current_bot
    bot_user = current_bot.user
    json(conn, %{balance: bot_user.balance, username: bot_user.username})
  end

  operation :user_balance,
    summary: "Get user balance by ID",
    description: "Returns the balance and username of a specific user.",
    parameters: [
      user_id: [in: :path, description: "User ID", type: :integer, example: 123]
    ],
    responses: [
      ok: {"Balance response", "application/json", StackCoinWeb.Schemas.BalanceResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      bad_request: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

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

  operation :send_stk,
    summary: "Send STK to a user",
    description: "Transfers STK from the bot to a specified user.",
    parameters: [
      user_id: [in: :path, description: "Recipient user ID", type: :integer, example: 123]
    ],
    request_body: {"Send STK params", "application/json", StackCoinWeb.Schemas.SendStkParams},
    responses: [
      ok: {"Send STK response", "application/json", StackCoinWeb.Schemas.SendStkResponse},
      bad_request: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      forbidden: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      unprocessable_entity:
        {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

  def send_stk(conn, %{"user_id" => user_id_str, "amount" => amount} = params) do
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

  def send_stk(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters: amount"})
  end

  operation :create_request,
    summary: "Create a STK request",
    description: "Creates a request for STK from a specified user.",
    parameters: [
      user_id: [in: :path, description: "Responder user ID", type: :integer, example: 456]
    ],
    request_body:
      {"Create request params", "application/json", StackCoinWeb.Schemas.CreateRequestParams},
    responses: [
      ok:
        {"Create request response", "application/json",
         StackCoinWeb.Schemas.CreateRequestResponse},
      bad_request: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      forbidden: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

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

  operation :get_requests,
    summary: "Get requests for the bot",
    description: "Retrieves requests involving the bot, with optional filtering and pagination.",
    parameters: [
      role: [
        in: :query,
        description: "Role filter (requester or responder)",
        type: :string,
        example: "requester"
      ],
      status: [in: :query, description: "Status filter", type: :string, example: "pending"],
      discord_id: [
        in: :query,
        description: "Discord ID filter",
        type: :string,
        example: "123456789"
      ],
      page: [in: :query, description: "Page number", type: :integer, example: 1],
      limit: [in: :query, description: "Items per page", type: :integer, example: 20]
    ],
    responses: [
      ok: {"Requests response", "application/json", StackCoinWeb.Schemas.RequestsResponse}
    ]

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
    discord_id = Map.get(params, "discord_id")

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
    opts = if discord_id, do: Keyword.put(opts, :discord_id, discord_id), else: opts

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

  operation :accept_request,
    summary: "Accept a STK request",
    description: "Accepts a pending STK request, creating a transaction.",
    parameters: [
      request_id: [in: :path, description: "Request ID", type: :integer, example: 789]
    ],
    responses: [
      ok:
        {"Request action response", "application/json",
         StackCoinWeb.Schemas.RequestActionResponse},
      bad_request: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      forbidden: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

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

  operation :deny_request,
    summary: "Deny a STK request",
    description: "Denies a pending STK request without creating a transaction.",
    parameters: [
      request_id: [in: :path, description: "Request ID", type: :integer, example: 789]
    ],
    responses: [
      ok:
        {"Request action response", "application/json",
         StackCoinWeb.Schemas.RequestActionResponse},
      bad_request: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse},
      forbidden: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

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

  operation :get_transactions,
    summary: "Get transactions for the bot",
    description:
      "Retrieves transactions involving the bot, with optional filtering and pagination.",
    parameters: [
      page: [in: :query, description: "Page number", type: :integer, example: 1],
      limit: [in: :query, description: "Items per page", type: :integer, example: 20],
      from_user_id: [
        in: :query,
        description: "Filter by sender user ID",
        type: :integer,
        example: 123
      ],
      to_user_id: [
        in: :query,
        description: "Filter by recipient user ID",
        type: :integer,
        example: 456
      ],
      from_discord_id: [
        in: :query,
        description: "Filter by sender Discord ID",
        type: :string,
        example: "123456789"
      ],
      to_discord_id: [
        in: :query,
        description: "Filter by recipient Discord ID",
        type: :string,
        example: "987654321"
      ],
      includes_discord_id: [
        in: :query,
        description: "Filter by Discord ID (sender or recipient)",
        type: :string,
        example: "123456789"
      ]
    ],
    responses: [
      ok:
        {"Transactions response", "application/json", StackCoinWeb.Schemas.TransactionsResponse},
      bad_request: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

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

    from_discord_id = Map.get(params, "from_discord_id")
    to_discord_id = Map.get(params, "to_discord_id")
    includes_discord_id = Map.get(params, "includes_discord_id")

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
      if from_discord_id, do: Keyword.put(opts, :from_discord_id, from_discord_id), else: opts

    opts = if to_discord_id, do: Keyword.put(opts, :to_discord_id, to_discord_id), else: opts

    opts =
      if includes_discord_id,
        do: Keyword.put(opts, :includes_discord_id, includes_discord_id),
        else: opts

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

  operation :get_users,
    summary: "Get users",
    description: "Retrieves users with optional filtering and pagination.",
    parameters: [
      page: [in: :query, description: "Page number", type: :integer, example: 1],
      limit: [in: :query, description: "Items per page", type: :integer, example: 20],
      username: [in: :query, description: "Filter by username", type: :string, example: "johndoe"],
      discord_id: [
        in: :query,
        description: "Filter by Discord ID",
        type: :string,
        example: "123456789"
      ],
      banned: [in: :query, description: "Filter by banned status", type: :boolean, example: false],
      admin: [in: :query, description: "Filter by admin status", type: :boolean, example: true]
    ],
    responses: [
      ok: {"Users response", "application/json", StackCoinWeb.Schemas.UsersResponse}
    ]

  def get_users(conn, params) do
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
    username = Map.get(params, "username")
    discord_id = Map.get(params, "discord_id")

    banned =
      case Map.get(params, "banned") do
        "true" -> true
        "false" -> false
        _ -> nil
      end

    admin =
      case Map.get(params, "admin") do
        "true" -> true
        "false" -> false
        _ -> nil
      end

    opts = [limit: limit, offset: offset]
    opts = if username, do: Keyword.put(opts, :username, username), else: opts
    opts = if discord_id, do: Keyword.put(opts, :discord_id, discord_id), else: opts
    opts = if banned != nil, do: Keyword.put(opts, :banned, banned), else: opts
    opts = if admin != nil, do: Keyword.put(opts, :admin, admin), else: opts

    {:ok, %{users: users, total_count: total_count}} = User.search_users(opts)

    formatted_users =
      Enum.map(users, fn user ->
        %{
          id: user.id,
          username: user.username,
          balance: user.balance,
          admin: user.admin,
          banned: user.banned
        }
      end)

    total_pages = ceil(total_count / limit)

    json(conn, %{
      users: formatted_users,
      pagination: %{
        page: page,
        limit: limit,
        total: total_count,
        total_pages: total_pages
      }
    })
  end
end
