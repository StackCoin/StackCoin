defmodule StackCoinWeb.RequestController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.Request
  alias StackCoinWeb.ApiHelpers

  operation :show,
    operation_id: "stackcoin_request",
    summary: "Get request by ID",
    description: "Retrieves a single request by its ID.",
    parameters: [
      request_id: [
        in: :path,
        description: "Request ID",
        type: :integer,
        example: 789
      ]
    ],
    responses: [
      ok: {"Request response", "application/json", StackCoinWeb.Schemas.RequestResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

  operation :create,
    operation_id: "stackcoin_create_request",
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

  def create(conn, %{"user_id" => user_id_str, "amount" => amount} = params) do
    current_bot = conn.assigns.current_bot
    label = Map.get(params, "label")

    with {:ok, responder_id} <- ApiHelpers.parse_user_id(user_id_str),
         {:ok, amount} <- ApiHelpers.validate_amount(amount) do
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
          ApiHelpers.send_error_response(conn, reason)
      end
    else
      {:error, :invalid_user_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid user ID"})

      {:error, :invalid_amount} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid amount. Must be an integer."})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters: user_id, amount"})
  end

  operation :index,
    operation_id: "stackcoin_requests",
    summary: "Get requests for the authenticated user",
    description:
      "Retrieves requests involving the authenticated user, with optional filtering and pagination.",
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
      since: [
        in: :query,
        description:
          "Time filter - requests created after this duration ago. Formats: 30s, 5m, 2h, 3d, 1w",
        type: :string,
        example: "1d"
      ],
      page: [in: :query, description: "Page number", type: :integer, example: 1],
      limit: [in: :query, description: "Items per page", type: :integer, example: 20]
    ],
    responses: [
      ok: {"Requests response", "application/json", StackCoinWeb.Schemas.RequestsResponse},
      bad_request: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

  def index(conn, params) do
    current_bot = conn.assigns.current_bot

    # Parse query parameters
    role =
      case Map.get(params, "role") do
        "requester" -> :requester
        "responder" -> :responder
        _ -> nil
      end

    status = Map.get(params, "status")
    discord_id = Map.get(params, "discord_id")
    since_param = Map.get(params, "since")

    # Parse pagination parameters
    %{page: page, limit: limit, offset: offset} = ApiHelpers.parse_pagination_params(params)

    # Parse time filter and proceed or return error
    with {:ok, since_datetime} <- ApiHelpers.parse_time_duration(since_param) do
      opts = [role: role, limit: limit, offset: offset]
      opts = if status, do: Keyword.put(opts, :status, status), else: opts
      opts = if discord_id, do: Keyword.put(opts, :discord_id, discord_id), else: opts
      opts = if since_datetime, do: Keyword.put(opts, :since, since_datetime), else: opts

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
    else
      {:error, :invalid_time_format} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid time format. Use formats like: 30s, 5m, 2h, 3d, 1w"})
        |> halt()
    end
  end

  operation :accept,
    operation_id: "stackcoin_accept_request",
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

  def accept(conn, %{"request_id" => request_id_str}) do
    current_bot = conn.assigns.current_bot

    case ApiHelpers.parse_user_id(request_id_str) do
      {:ok, request_id} ->
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
            ApiHelpers.send_error_response(conn, reason)
        end

      {:error, :invalid_user_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid request ID"})
    end
  end

  operation :deny,
    operation_id: "stackcoin_deny_request",
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

  def deny(conn, %{"request_id" => request_id_str}) do
    current_bot = conn.assigns.current_bot

    case ApiHelpers.parse_user_id(request_id_str) do
      {:ok, request_id} ->
        case Request.deny_request(request_id, current_bot.user.id) do
          {:ok, request} ->
            json(conn, %{
              success: true,
              request_id: request.id,
              status: request.status,
              resolved_at: request.resolved_at
            })

          {:error, reason} ->
            ApiHelpers.send_error_response(conn, reason)
        end

      {:error, :invalid_user_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid request ID"})
    end
  end

  def deny(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: request_id"})
  end

  def show(conn, %{"request_id" => request_id_str}) do
    case ApiHelpers.parse_user_id(request_id_str) do
      {:ok, request_id} ->
        case Request.get_request_by_id(request_id) do
          {:ok, request} ->
            formatted_request = %{
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

            json(conn, formatted_request)

          {:error, :request_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Request not found"})
        end

      {:error, :invalid_user_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid request ID"})
    end
  end
end
