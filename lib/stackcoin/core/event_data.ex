defmodule StackCoin.Core.EventData do
  @moduledoc """
  Canonical definitions for all StackCoin event types.

  Each `defevent` generates:
  - An Ecto embedded schema for internal validation
  - OpenApiSpex schemas for API spec generation
  - Registry entries for runtime lookup
  """

  use StackCoin.EventSchema

  defevent "transfer.completed", TransferCompleted do
    field(:transaction_id, :integer, required: true, description: "Transaction ID")
    field(:from_id, :integer, required: true, description: "Sender user ID")
    field(:to_id, :integer, required: true, description: "Recipient user ID")
    field(:amount, :integer, required: true, description: "Amount transferred")

    field(:role, :string,
      required: true,
      description: "Role of the event recipient (sender or receiver)"
    )
  end

  defevent "request.created", RequestCreated do
    field(:request_id, :integer, required: true, description: "Request ID")
    field(:requester_id, :integer, required: true, description: "Requester user ID")
    field(:responder_id, :integer, required: true, description: "Responder user ID")
    field(:amount, :integer, required: true, description: "Requested amount")
    field(:label, :string, required: false, description: "Request label")
  end

  defevent "request.accepted", RequestAccepted do
    field(:request_id, :integer, required: true, description: "Request ID")
    field(:status, :string, required: true, description: "New request status")
    field(:transaction_id, :integer, required: true, description: "Created transaction ID")
    field(:amount, :integer, required: true, description: "Request amount")
  end

  defevent "request.denied", RequestDenied do
    field(:request_id, :integer, required: true, description: "Request ID")
    field(:status, :string, required: true, description: "New request status")
  end
end
