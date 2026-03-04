defmodule StackCoin.Core.EventTest do
  use StackCoin.DataCase

  alias StackCoin.Core.{Event, User}

  describe "create_event/3" do
    setup do
      {:ok, user1} = User.create_user_account("111", "EventUser1", balance: 0)
      {:ok, user2} = User.create_user_account("222", "EventUser2", balance: 0)
      %{user1: user1, user2: user2}
    end

    test "creates an event with type, user_id, and data", %{user1: user1} do
      {:ok, event} =
        Event.create_event("request.created", user1.id, %{request_id: 42, amount: 100})

      assert event.type == "request.created"
      assert event.user_id == user1.id
      assert event.id != nil

      decoded = Jason.decode!(event.data)
      assert decoded["request_id"] == 42
      assert decoded["amount"] == 100
    end

    test "creates an event without user_id" do
      {:ok, event} = Event.create_event("transfer.completed", nil, %{transaction_id: 5})

      assert event.type == "transfer.completed"
      assert event.user_id == nil
    end
  end

  describe "list_events_since/2" do
    setup do
      {:ok, user1} = User.create_user_account("333", "EventListUser1", balance: 0)
      {:ok, user2} = User.create_user_account("444", "EventListUser2", balance: 0)
      %{user1: user1, user2: user2}
    end

    test "returns events after a given ID for a specific user", %{user1: user1, user2: user2} do
      {:ok, e1} = Event.create_event("request.created", user1.id, %{request_id: 1})
      {:ok, e2} = Event.create_event("request.accepted", user1.id, %{request_id: 1})
      {:ok, _e3} = Event.create_event("request.created", user2.id, %{request_id: 2})

      events = Event.list_events_since(user1.id, e1.id)
      assert length(events) == 1
      assert hd(events).id == e2.id
    end

    test "returns all events for user when last_event_id is 0", %{user1: user1} do
      {:ok, _e1} = Event.create_event("request.created", user1.id, %{request_id: 1})
      {:ok, _e2} = Event.create_event("request.accepted", user1.id, %{request_id: 1})

      events = Event.list_events_since(user1.id, 0)
      assert length(events) == 2
    end
  end
end
