defmodule StackCoinWeb.TransferController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.Bank
  alias StackCoinWeb.ApiHelpers

  operation :send_stk,
    operation_id: "stackcoin_send_stk",
    summary: "Send STK to a user",
    description: "Transfers STK from the authenticated user to a specified user.",
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

    with {:ok, to_user_id} <- ApiHelpers.parse_user_id(user_id_str),
         {:ok, amount} <- ApiHelpers.validate_amount(amount) do
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

  def send_stk(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters: amount"})
  end
end
