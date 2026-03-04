defmodule StackCoinWeb.TransferController do
  use StackCoinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StackCoin.Core.{Bank, Idempotency}
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

  def send_stk(conn, params) do
    idempotency_key = get_req_header(conn, "idempotency-key") |> List.first()

    if idempotency_key do
      bot = conn.assigns.current_bot

      case Idempotency.check(bot.id, idempotency_key) do
        {:hit, code, body} ->
          conn
          |> put_status(code)
          |> json(Jason.decode!(body))

        :miss ->
          {status, response_body} = execute_send_stk(conn, params)
          encoded = Jason.encode!(response_body)
          Idempotency.store(bot.id, idempotency_key, status, encoded)

          conn
          |> put_status(status)
          |> json(response_body)
      end
    else
      {status, response_body} = execute_send_stk(conn, params)

      conn
      |> put_status(status)
      |> json(response_body)
    end
  end

  # Returns {status_code, response_map} without sending the response.
  defp execute_send_stk(conn, %{"user_id" => user_id_str, "amount" => amount} = params) do
    current_bot = conn.assigns.current_bot
    label = Map.get(params, "label")

    with {:ok, to_user_id} <- ApiHelpers.parse_user_id(user_id_str),
         {:ok, amount} <- ApiHelpers.validate_amount(amount) do
      case Bank.bot_transfer(current_bot.token, to_user_id, amount, label) do
        {:ok, transaction} ->
          {200,
           %{
             success: true,
             transaction_id: transaction.id,
             amount: transaction.amount,
             from_new_balance: transaction.from_new_balance,
             to_new_balance: transaction.to_new_balance
           }}

        {:error, reason} ->
          ApiHelpers.error_response_tuple(reason)
      end
    else
      {:error, :invalid_user_id} ->
        {400, %{error: "Invalid user ID"}}

      {:error, :invalid_amount} ->
        {400, %{error: "Invalid amount. Must be an integer."}}
    end
  end

  defp execute_send_stk(_conn, _params) do
    {400, %{error: "Missing required parameters: amount"}}
  end
end
