"""
E2E tests for the WebSocket gateway.

Uses the Phoenix Channel protocol over WebSocket to verify
real-time event delivery.
"""
import asyncio
import json

import httpx
import pytest
import websockets


async def phoenix_connect(base_url: str, token: str, last_event_id: int = 0):
    """Connect to Phoenix Channel and join the user events channel."""
    ws_url = base_url.replace("http://", "ws://") + f"/ws?token={token}&vsn=2.0.0"

    ws = await websockets.connect(ws_url)

    # Join the user events channel
    join_msg = json.dumps([None, "1", "user:self", "phx_join", {"last_event_id": last_event_id}])
    await ws.send(join_msg)

    # Wait for join reply
    reply = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
    assert reply[3] == "phx_reply"
    assert reply[4]["status"] == "ok"

    return ws


@pytest.mark.asyncio
class TestWebSocketGateway:

    async def test_connect_and_join(self, test_context):
        """Can connect and join with a valid bot token."""
        ws = await phoenix_connect(test_context["base_url"], test_context["bot_token"])
        await ws.close()

    async def test_receives_event_on_transfer(self, test_context, auth_headers):
        """Perform a transfer and verify the event arrives via WebSocket."""
        base = test_context["base_url"]
        token = test_context["bot_token"]
        user1_id = test_context["user1_id"]

        ws = await phoenix_connect(base, token)

        try:
            # Perform a transfer via HTTP
            async with httpx.AsyncClient(base_url=base) as client:
                resp = await client.post(
                    f"/api/user/{user1_id}/send",
                    json={"amount": 1, "label": "ws e2e test"},
                    headers=auth_headers,
                )
                assert resp.status_code == 200

            # Wait for event via WebSocket (may get multiple messages, including
            # replayed seed-data events). Look for the specific transfer we made.
            received_transfer = False
            for _ in range(20):
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=3)
                    msg = json.loads(raw)
                    if len(msg) >= 5 and msg[3] == "event":
                        if (
                            msg[4].get("type") == "transfer.completed"
                            and msg[4]["data"]["amount"] == 1
                        ):
                            received_transfer = True
                            break
                except asyncio.TimeoutError:
                    break

            assert received_transfer, "Did not receive transfer.completed event with amount=1 via WebSocket"
        finally:
            await ws.close()

    async def test_event_replay_on_reconnect(self, test_context, auth_headers):
        """Events created before connecting are replayed on join."""
        base = test_context["base_url"]
        token = test_context["bot_token"]
        user1_id = test_context["user1_id"]

        # Perform a transfer BEFORE connecting
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 1, "label": "before ws connect"},
                headers=auth_headers,
            )
            assert resp.status_code == 200

        # Connect with last_event_id=0 to replay everything
        ws = await phoenix_connect(base, token, last_event_id=0)

        try:
            received_any = False
            for _ in range(20):
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=3)
                    msg = json.loads(raw)
                    if len(msg) >= 5 and msg[3] == "event":
                        received_any = True
                        break
                except asyncio.TimeoutError:
                    break

            assert received_any, "Did not receive any replayed events"
        finally:
            await ws.close()


@pytest.mark.asyncio
class TestWebSocketRobustness:

    async def test_join_other_users_channel_rejected(self, test_context):
        """Joining another user's channel should return an 'unauthorized' error."""
        base = test_context["base_url"]
        token = test_context["bot_token"]
        user1_id = test_context["user1_id"]

        ws_url = base.replace("http://", "ws://") + f"/ws?token={token}&vsn=2.0.0"
        ws = await websockets.connect(ws_url)

        try:
            join_msg = json.dumps([None, "1", f"user:{user1_id}", "phx_join", {}])
            await ws.send(join_msg)

            reply = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            assert reply[3] == "phx_reply"
            assert reply[4]["status"] == "error"
            assert reply[4]["response"]["reason"] == "unauthorized"
        finally:
            await ws.close()

    async def test_replay_with_nonzero_last_event_id(self, test_context, auth_headers):
        """Connecting with last_event_id > 0 only replays events after that ID."""
        base = test_context["base_url"]
        token = test_context["bot_token"]

        # Fetch current events via HTTP to find a known event ID
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.get("/api/events", headers=auth_headers)
            assert resp.status_code == 200
            all_events = resp.json()["events"]

        assert len(all_events) > 0, "Need at least one existing event for this test"

        # Use the latest event ID — no events should be replayed after it
        latest_event_id = all_events[-1]["id"]

        ws = await phoenix_connect(base, token, last_event_id=latest_event_id)

        try:
            replayed_events = []
            for _ in range(10):
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=2)
                    msg = json.loads(raw)
                    if len(msg) >= 5 and msg[3] == "event":
                        replayed_events.append(msg[4])
                except asyncio.TimeoutError:
                    break

            # All replayed event IDs must be strictly greater than latest_event_id
            for event in replayed_events:
                assert event["id"] > latest_event_id, (
                    f"Replayed event {event['id']} should be > last_event_id {latest_event_id}"
                )
        finally:
            await ws.close()

        # Test with an earlier event ID to confirm partial replay works
        if len(all_events) >= 2:
            mid_index = len(all_events) // 2
            mid_event_id = all_events[mid_index]["id"]
            expected_after = [e for e in all_events if e["id"] > mid_event_id]

            ws2 = await phoenix_connect(base, token, last_event_id=mid_event_id)

            try:
                replayed_events_2 = []
                for _ in range(50):
                    try:
                        raw = await asyncio.wait_for(ws2.recv(), timeout=2)
                        msg = json.loads(raw)
                        if len(msg) >= 5 and msg[3] == "event":
                            replayed_events_2.append(msg[4])
                    except asyncio.TimeoutError:
                        break

                # Every replayed ID must be > mid_event_id
                for e in replayed_events_2:
                    assert e["id"] > mid_event_id

                # All expected events should appear in the replay
                expected_ids = {e["id"] for e in expected_after}
                replayed_ids = {e["id"] for e in replayed_events_2}
                assert expected_ids.issubset(replayed_ids), (
                    f"Expected events {expected_ids - replayed_ids} were not replayed"
                )
            finally:
                await ws2.close()

    async def test_request_events_over_websocket(self, test_context, auth_headers):
        """Creating a payment request should push a request.created event via WebSocket."""
        base = test_context["base_url"]
        token = test_context["bot_token"]
        user1_id = test_context["user1_id"]

        # Get latest event ID so we only see new events (skip replay noise)
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.get("/api/events", headers=auth_headers)
            assert resp.status_code == 200
            events = resp.json()["events"]
            last_event_id = events[-1]["id"] if events else 0

        ws = await phoenix_connect(base, token, last_event_id=last_event_id)

        try:
            # Create a payment request via HTTP
            async with httpx.AsyncClient(base_url=base) as client:
                resp = await client.post(
                    f"/api/user/{user1_id}/request",
                    json={"amount": 5, "label": "ws request e2e test"},
                    headers=auth_headers,
                )
                assert resp.status_code == 200
                request_id = resp.json()["request_id"]

            # Wait for the request.created event via WebSocket
            received_request_event = False
            for _ in range(20):
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=3)
                    msg = json.loads(raw)
                    if len(msg) >= 5 and msg[3] == "event":
                        event = msg[4]
                        if (
                            event.get("type") == "request.created"
                            and event["data"].get("request_id") == request_id
                        ):
                            received_request_event = True
                            break
                except asyncio.TimeoutError:
                    break

            assert received_request_event, (
                f"Did not receive request.created event with request_id={request_id} via WebSocket"
            )
        finally:
            await ws.close()
