defmodule StackCoin.Core.EventIntegrationTest do
  use StackCoin.DataCase

  import Mock

  alias StackCoin.Core.{User, Bot, Bank, Reserve, Request, Event}

  # Mock Nostrum Discord API calls that fire as side effects when creating requests.
  setup_with_mocks([
    {Nostrum.Api.User, [], [create_dm: fn _user_id -> {:ok, %{id: 0}} end]},
    {Nostrum.Api.Message, [], [create: fn _channel_id, _msg -> {:ok, %{id: 0}} end]}
  ]) do
    {:ok, _reserve} = User.create_user_account("1", "Reserve", balance: 1000)
    {:ok, owner} = User.create_user_account("123456789", "TestOwner", balance: 500)
    {:ok, bot} = Bot.create_bot_user("123456789", "TestBot")
    {:ok, recipient} = User.create_user_account("987654321", "RecipientUser", balance: 100)
    {:ok, _pump} = Reserve.pump_reserve(owner.id, 200, "Test funding")
    {:ok, _transaction} = Bank.transfer_between_users(1, bot.user.id, 150, "Bot funding")

    %{owner: owner, bot: bot, recipient: recipient}
  end

  test "transfer emits transfer.completed event for both users", %{bot: bot, recipient: recipient} do
    {:ok, _txn} = Bank.transfer_between_users(bot.user.id, recipient.id, 50, "test")

    {sender_events, _has_more} = Event.list_events_since(bot.user.id, 0)

    sender_event =
      Enum.find(sender_events, fn e ->
        e.type == "transfer.completed" &&
          match?(%{"amount" => 50, "to_id" => _}, Jason.decode!(e.data))
      end)

    assert sender_event, "expected a transfer.completed event with amount 50 for sender"
    data = Jason.decode!(sender_event.data)
    assert data["amount"] == 50
    assert data["to_id"] == recipient.id

    {receiver_events, _has_more} = Event.list_events_since(recipient.id, 0)

    receiver_event =
      Enum.find(receiver_events, fn e ->
        e.type == "transfer.completed" && match?(%{"amount" => 50}, Jason.decode!(e.data))
      end)

    assert receiver_event, "expected a transfer.completed event with amount 50 for receiver"
  end

  test "create_request emits request.created event for both parties", %{
    bot: bot,
    recipient: recipient
  } do
    {:ok, request} = Request.create_request(bot.user.id, recipient.id, 75, "test request")

    {requester_events, _has_more} = Event.list_events_since(bot.user.id, 0)

    requester_event =
      Enum.find(requester_events, fn e ->
        e.type == "request.created" &&
          (fn data -> data["request_id"] == request.id && data["amount"] == 75 end).(
            Jason.decode!(e.data)
          )
      end)

    assert requester_event,
           "expected a request.created event with request_id #{request.id} for requester"

    data = Jason.decode!(requester_event.data)
    assert data["request_id"] == request.id
    assert data["amount"] == 75

    {responder_events, _has_more} = Event.list_events_since(recipient.id, 0)

    responder_event =
      Enum.find(responder_events, fn e ->
        e.type == "request.created" &&
          (fn data -> data["request_id"] == request.id end).(Jason.decode!(e.data))
      end)

    assert responder_event,
           "expected a request.created event with request_id #{request.id} for responder"
  end

  test "accept_request emits request.accepted event for both parties", %{
    bot: bot,
    recipient: recipient
  } do
    {:ok, request} = Request.create_request(recipient.id, bot.user.id, 50, "accept test")
    {:ok, _accepted} = Request.accept_request(request.id, bot.user.id)

    {responder_events, _has_more} = Event.list_events_since(bot.user.id, 0)

    responder_event =
      Enum.find(responder_events, fn e ->
        e.type == "request.accepted" &&
          (fn data -> data["request_id"] == request.id && data["status"] == "accepted" end).(
            Jason.decode!(e.data)
          )
      end)

    assert responder_event,
           "expected a request.accepted event with request_id #{request.id} for responder"

    data = Jason.decode!(responder_event.data)
    assert data["request_id"] == request.id
    assert data["status"] == "accepted"

    {requester_events, _has_more} = Event.list_events_since(recipient.id, 0)

    requester_event =
      Enum.find(requester_events, fn e ->
        e.type == "request.accepted" &&
          (fn data -> data["request_id"] == request.id end).(Jason.decode!(e.data))
      end)

    assert requester_event,
           "expected a request.accepted event with request_id #{request.id} for requester"
  end

  test "deny_request emits request.denied event for both parties", %{
    bot: bot,
    recipient: recipient
  } do
    {:ok, request} = Request.create_request(recipient.id, bot.user.id, 30, "deny test")
    {:ok, _denied} = Request.deny_request(request.id, bot.user.id)

    {responder_events, _has_more} = Event.list_events_since(bot.user.id, 0)

    responder_event =
      Enum.find(responder_events, fn e ->
        e.type == "request.denied" &&
          (fn data -> data["request_id"] == request.id && data["status"] == "denied" end).(
            Jason.decode!(e.data)
          )
      end)

    assert responder_event,
           "expected a request.denied event with request_id #{request.id} for responder"

    data = Jason.decode!(responder_event.data)
    assert data["denied_by_id"] == bot.user.id
    assert data["request_id"] == request.id
    assert data["status"] == "denied"

    {requester_events, _has_more} = Event.list_events_since(recipient.id, 0)

    requester_event =
      Enum.find(requester_events, fn e ->
        e.type == "request.denied" &&
          (fn data -> data["request_id"] == request.id end).(Jason.decode!(e.data))
      end)

    assert requester_event,
           "expected a request.denied event with request_id #{request.id} for requester"

    requester_data = Jason.decode!(requester_event.data)
    assert requester_data["denied_by_id"] == bot.user.id
  end
end
