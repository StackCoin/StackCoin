defmodule StackCoin.EventSchemaTest do
  use ExUnit.Case, async: true

  alias StackCoin.Core.EventData

  describe "event_types/0" do
    test "returns all registered event types" do
      types = EventData.event_types()
      assert "transfer.completed" in types
      assert "request.created" in types
      assert "request.accepted" in types
      assert "request.denied" in types
      assert length(types) == 4
    end
  end

  describe "schema_for/1" do
    test "returns Ecto module for known event types" do
      assert {:ok, EventData.TransferCompleted} = EventData.schema_for("transfer.completed")
      assert {:ok, EventData.RequestCreated} = EventData.schema_for("request.created")
      assert {:ok, EventData.RequestAccepted} = EventData.schema_for("request.accepted")
      assert {:ok, EventData.RequestDenied} = EventData.schema_for("request.denied")
    end

    test "returns error for unknown event type" do
      assert {:error, :unknown_event_type} = EventData.schema_for("unknown.type")
    end
  end

  describe "Ecto embedded schemas" do
    test "TransferCompleted has expected fields" do
      fields = EventData.TransferCompleted.__schema__(:fields)
      assert :transaction_id in fields
      assert :from_id in fields
      assert :to_id in fields
      assert :amount in fields
      assert :role in fields
    end

    test "RequestCreated has expected fields" do
      fields = EventData.RequestCreated.__schema__(:fields)
      assert :request_id in fields
      assert :requester_id in fields
      assert :responder_id in fields
      assert :amount in fields
      assert :label in fields
    end

    test "RequestAccepted has expected fields" do
      fields = EventData.RequestAccepted.__schema__(:fields)
      assert :request_id in fields
      assert :status in fields
      assert :transaction_id in fields
      assert :amount in fields
    end

    test "RequestDenied has expected fields" do
      fields = EventData.RequestDenied.__schema__(:fields)
      assert :request_id in fields
      assert :status in fields
    end
  end

  describe "changeset validation" do
    test "TransferCompleted changeset validates required fields" do
      changeset =
        EventData.TransferCompleted.changeset(%{
          transaction_id: 1,
          from_id: 2,
          to_id: 3,
          amount: 100,
          role: "sender"
        })

      assert changeset.valid?
    end

    test "TransferCompleted changeset rejects missing required fields" do
      changeset = EventData.TransferCompleted.changeset(%{})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :transaction_id)
      assert Keyword.has_key?(changeset.errors, :from_id)
    end

    test "RequestCreated changeset allows optional label" do
      changeset =
        EventData.RequestCreated.changeset(%{
          request_id: 1,
          requester_id: 2,
          responder_id: 3,
          amount: 50
        })

      assert changeset.valid?
    end

    test "RequestDenied changeset validates required fields" do
      changeset = EventData.RequestDenied.changeset(%{request_id: 1, status: "denied"})
      assert changeset.valid?
    end

    test "RequestDenied changeset rejects missing required fields" do
      changeset = EventData.RequestDenied.changeset(%{})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :request_id)
      assert Keyword.has_key?(changeset.errors, :status)
    end
  end

  describe "validate/2" do
    test "validates valid data and returns struct" do
      {:ok, result} =
        EventData.validate("transfer.completed", %{
          transaction_id: 1,
          from_id: 2,
          to_id: 3,
          amount: 100,
          role: "sender"
        })

      assert %EventData.TransferCompleted{} = result
      assert result.transaction_id == 1
      assert result.amount == 100
    end

    test "returns error for invalid data" do
      assert {:error, {:invalid_event_data, _errors}} =
               EventData.validate("transfer.completed", %{})
    end

    test "returns error for unknown event type" do
      assert {:error, :unknown_event_type} = EventData.validate("unknown.type", %{foo: "bar"})
    end
  end

  describe "OpenApiSpex schemas" do
    test "data schemas exist with correct properties" do
      schema = StackCoinWeb.Schemas.TransferCompletedData.schema()
      assert schema.title == "TransferCompletedData"
      assert schema.type == :object
      assert Map.has_key?(schema.properties, :transaction_id)
      assert Map.has_key?(schema.properties, :from_id)
      assert :transaction_id in schema.required
    end

    test "event wrapper schemas exist with correct properties" do
      schema = StackCoinWeb.Schemas.TransferCompletedEvent.schema()
      assert schema.title == "TransferCompletedEvent"
      assert schema.type == :object
      assert Map.has_key?(schema.properties, :id)
      assert Map.has_key?(schema.properties, :type)
      assert Map.has_key?(schema.properties, :data)
      assert Map.has_key?(schema.properties, :inserted_at)
      assert [:id, :type, :data, :inserted_at] == schema.required
    end

    test "Event discriminated union schema exists" do
      schema = StackCoinWeb.Schemas.Event.schema()
      assert schema.title == "Event"
      assert length(schema.oneOf) == 4
      assert schema.discriminator.propertyName == "type"
      assert Map.has_key?(schema.discriminator.mapping, "transfer.completed")
    end

    test "EventsResponse schema exists" do
      schema = StackCoinWeb.Schemas.EventsResponse.schema()
      assert schema.title == "EventsResponse"
      assert schema.type == :object
      assert Map.has_key?(schema.properties, :events)
      assert [:events, :has_more] == schema.required
      assert Map.has_key?(schema.properties, :has_more)
    end
  end
end
