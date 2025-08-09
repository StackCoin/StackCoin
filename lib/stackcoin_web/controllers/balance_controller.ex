defmodule StackCoinWeb.BalanceController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.User
  alias StackCoinWeb.ApiHelpers

  operation :self_balance,
    operation_id: "stackcoin_self_balance",
    summary: "Get authenticated user's balance",
    description: "Returns the balance and username of the authenticated user.",
    responses: [
      ok: {"Balance response", "application/json", StackCoinWeb.Schemas.BalanceResponse},
      not_found: {"Error response", "application/json", StackCoinWeb.Schemas.ErrorResponse}
    ]

  def self_balance(conn, _params) do
    current_bot = conn.assigns.current_bot
    bot_user = current_bot.user
    json(conn, %{balance: bot_user.balance, username: bot_user.username})
  end

  operation :user_balance,
    operation_id: "stackcoin_user_balance",
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
    case ApiHelpers.parse_user_id(user_id_str) do
      {:ok, user_id} ->
        case User.get_user_by_id(user_id) do
          {:ok, user} ->
            json(conn, %{balance: user.balance, username: user.username})

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
