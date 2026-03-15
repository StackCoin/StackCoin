defmodule StackCoin.Core.EventTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Event, User}

  describe "create_event/3" do
    setup do
      {:ok, user1} = User.create_user_account("111", "EventUser1", balance: 0)
      {:ok, user2} = User.create_user_account("222", "EventUser2", balance: 0)
      %{user1: user1, user2: user2}
    end

    test "creates an event with type, user_id, and data", %{user1: user1, user2: user2} do
      {:ok, event} =
        Event.create_event("request.created", user1.id, %{
          request_id: 42,
          requester_id: user1.id,
          responder_id: user2.id,
          amount: 100,
          label: "test"
        })

      assert event.type == "request.created"
      assert event.user_id == user1.id
      assert event.id != nil

      decoded = Jason.decode!(event.data)
      assert decoded["request_id"] == 42
      assert decoded["amount"] == 100
    end

    test "creates an event without user_id", %{user1: user1, user2: user2} do
      {:ok, event} =
        Event.create_event("transfer.completed", nil, %{
          transaction_id: 5,
          from_id: user1.id,
          to_id: user2.id,
          amount: 100,
          role: "sender"
        })

      assert event.type == "transfer.completed"
      assert event.user_id == nil
    end

    test "rejects event with missing required fields", %{user1: user1} do
      assert {:error, {:invalid_event_data, _}} =
               Event.create_event("transfer.completed", user1.id, %{})
    end

    test "rejects unknown event type", %{user1: user1} do
      assert {:error, :unknown_event_type} =
               Event.create_event("unknown.type", user1.id, %{foo: "bar"})
    end
  end

  describe "list_events_since/2" do
    setup do
      {:ok, user1} = User.create_user_account("333", "EventListUser1", balance: 0)
      {:ok, user2} = User.create_user_account("444", "EventListUser2", balance: 0)
      %{user1: user1, user2: user2}
    end

    test "returns events after a given ID for a specific user", %{user1: user1, user2: user2} do
      {:ok, e1} =
        Event.create_event("request.created", user1.id, %{
          request_id: 1,
          requester_id: user1.id,
          responder_id: user2.id,
          amount: 50
        })

      {:ok, e2} =
        Event.create_event("request.accepted", user1.id, %{
          request_id: 1,
          status: "accepted",
          transaction_id: 10,
          amount: 50
        })

      {:ok, _e3} =
        Event.create_event("request.created", user2.id, %{
          request_id: 2,
          requester_id: user2.id,
          responder_id: user1.id,
          amount: 25
        })

      {events, _has_more} = Event.list_events_since(user1.id, e1.id)
      assert length(events) == 1
      assert hd(events).id == e2.id
    end

    test "returns all events for user when last_event_id is 0", %{user1: user1, user2: user2} do
      {:ok, _e1} =
        Event.create_event("request.created", user1.id, %{
          request_id: 1,
          requester_id: user1.id,
          responder_id: user2.id,
          amount: 50
        })

      {:ok, _e2} =
        Event.create_event("request.accepted", user1.id, %{
          request_id: 1,
          status: "accepted",
          transaction_id: 10,
          amount: 50
        })

      {events, _has_more} = Event.list_events_since(user1.id, 0)
      assert length(events) == 2
    end

    test "returns has_more=false when events fit in one page", %{user1: user1} do
      {:ok, _} =
        Event.create_event("request.denied", user1.id, %{
          denied_by_id: user1.id,
          request_id: 1,
          status: "denied"
        })

      {events, has_more} = Event.list_events_since(user1.id, 0)
      assert length(events) == 1
      refute has_more
    end

    test "returns has_more=true when more events exist beyond the limit", %{user1: user1} do
      for _ <- 1..4 do
        Event.create_event("request.denied", user1.id, %{
          denied_by_id: user1.id,
          request_id: 1,
          status: "denied"
        })
      end

      # Use a small limit to test the boundary without inserting 101 rows
      {events, has_more} = Event.list_events_since(user1.id, 0, 3)
      assert length(events) == 3
      assert has_more

      # Paginate with cursor from last event
      last_id = List.last(events).id
      {events2, has_more2} = Event.list_events_since(user1.id, last_id, 3)
      assert length(events2) == 1
      refute has_more2
    end
  end
end
