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
    transfer_events = Enum.filter(sender_events, &(&1.type == "transfer.completed"))
    assert length(transfer_events) >= 1

    event = List.last(transfer_events)
    data = Jason.decode!(event.data)
    assert data["amount"] == 50
    assert data["to_id"] == recipient.id

    {receiver_events, _has_more} = Event.list_events_since(recipient.id, 0)
    receiver_transfer_events = Enum.filter(receiver_events, &(&1.type == "transfer.completed"))
    assert length(receiver_transfer_events) >= 1
  end

  test "create_request emits request.created event for both parties", %{
    bot: bot,
    recipient: recipient
  } do
    {:ok, request} = Request.create_request(bot.user.id, recipient.id, 75, "test request")

    {requester_events, _has_more} = Event.list_events_since(bot.user.id, 0)
    created_events = Enum.filter(requester_events, &(&1.type == "request.created"))
    assert length(created_events) >= 1

    data = Jason.decode!(List.last(created_events).data)
    assert data["request_id"] == request.id
    assert data["amount"] == 75

    {responder_events, _has_more} = Event.list_events_since(recipient.id, 0)
    responder_created = Enum.filter(responder_events, &(&1.type == "request.created"))
    assert length(responder_created) >= 1
  end

  test "accept_request emits request.accepted event for both parties", %{
    bot: bot,
    recipient: recipient
  } do
    {:ok, request} = Request.create_request(recipient.id, bot.user.id, 50, "accept test")
    {:ok, _accepted} = Request.accept_request(request.id, bot.user.id)

    {responder_events, _has_more} = Event.list_events_since(bot.user.id, 0)
    accepted_events = Enum.filter(responder_events, &(&1.type == "request.accepted"))
    assert length(accepted_events) >= 1

    data = Jason.decode!(List.last(accepted_events).data)
    assert data["request_id"] == request.id
    assert data["status"] == "accepted"

    {requester_events, _has_more} = Event.list_events_since(recipient.id, 0)
    requester_accepted = Enum.filter(requester_events, &(&1.type == "request.accepted"))
    assert length(requester_accepted) >= 1
  end

  test "deny_request emits request.denied event for both parties", %{
    bot: bot,
    recipient: recipient
  } do
    {:ok, request} = Request.create_request(recipient.id, bot.user.id, 30, "deny test")
    {:ok, _denied} = Request.deny_request(request.id, bot.user.id)

    {responder_events, _has_more} = Event.list_events_since(bot.user.id, 0)
    denied_events = Enum.filter(responder_events, &(&1.type == "request.denied"))
    assert length(denied_events) >= 1

    data = Jason.decode!(List.last(denied_events).data)
    assert data["request_id"] == request.id
    assert data["status"] == "denied"

    {requester_events, _has_more} = Event.list_events_since(recipient.id, 0)
    requester_denied = Enum.filter(requester_events, &(&1.type == "request.denied"))
    assert length(requester_denied) >= 1
  end
end
