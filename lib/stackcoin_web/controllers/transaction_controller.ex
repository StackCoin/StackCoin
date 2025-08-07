defmodule StackCoinWeb.TransactionController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.Bank
  alias StackCoinWeb.ApiHelpers

  operation :index,
    summary: "Get transactions for the authenticated user",
    description:
      "Retrieves transactions involving the authenticated user, with optional filtering and pagination.",
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

  def index(conn, params) do
    current_bot = conn.assigns.current_bot

    # Parse pagination parameters
    %{page: page, limit: limit, offset: offset} = ApiHelpers.parse_pagination_params(params)

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

    # Default to showing all authenticated user transactions (includes_user_id = authenticated user's id)
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
        ApiHelpers.send_error_response(conn, reason)
    end
  end
end
