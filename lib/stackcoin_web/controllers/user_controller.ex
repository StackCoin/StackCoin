defmodule StackCoinWeb.UserController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.User
  alias StackCoinWeb.ApiHelpers

  operation :me,
    operation_id: "stackcoin_user_me",
    summary: "Get authenticated user's profile",
    description: "Returns the full profile of the authenticated bot user.",
    responses: [
      ok: {"User response", "application/json", StackCoinWeb.Schemas.UserResponse}
    ]

  operation :show,
    operation_id: "stackcoin_user",
    summary: "Get user by ID",
    description: "Retrieves a single user by their ID.",
    parameters: [
      user_id: [
        in: :path,
        description: "User ID",
        type: :integer,
        example: 123
      ]
    ],
    responses: [
      ok: {"User response", "application/json", StackCoinWeb.Schemas.UserResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

  operation :index,
    operation_id: "stackcoin_users",
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

  def index(conn, params) do
    # Parse pagination parameters
    %{page: page, limit: limit, offset: offset} = ApiHelpers.parse_pagination_params(params)

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

  def me(conn, _params) do
    current_bot = conn.assigns.current_bot
    bot_user = current_bot.user

    formatted_user = %{
      id: bot_user.id,
      username: bot_user.username,
      balance: bot_user.balance,
      admin: bot_user.admin,
      banned: bot_user.banned,
      inserted_at: bot_user.inserted_at,
      updated_at: bot_user.updated_at
    }

    json(conn, formatted_user)
  end

  def show(conn, %{"user_id" => user_id_str}) do
    case ApiHelpers.parse_user_id(user_id_str) do
      {:ok, user_id} ->
        case User.get_user_by_id(user_id) do
          {:ok, user} ->
            formatted_user = %{
              id: user.id,
              username: user.username,
              balance: user.balance,
              admin: user.admin,
              banned: user.banned,
              inserted_at: user.inserted_at,
              updated_at: user.updated_at
            }

            json(conn, formatted_user)

          {:error, :user_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "User not found"})
        end

      {:error, :invalid_user_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid user ID"})
    end
  end
end
