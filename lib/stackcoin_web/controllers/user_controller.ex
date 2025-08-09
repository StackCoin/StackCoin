defmodule StackCoinWeb.UserController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.User
  alias StackCoinWeb.ApiHelpers

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
end
