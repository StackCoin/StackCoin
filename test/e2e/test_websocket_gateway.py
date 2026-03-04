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
    ws_url = base_url.replace("http://", "ws://") + f"/bot/websocket?token={token}&vsn=2.0.0"

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

            # Wait for event via WebSocket (may get multiple messages)
            received_transfer = False
            for _ in range(10):
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=3)
                    msg = json.loads(raw)
                    if len(msg) >= 5 and msg[3] == "event":
                        if msg[4].get("type") == "transfer.completed":
                            assert msg[4]["data"]["amount"] == 1
                            received_transfer = True
                            break
                except asyncio.TimeoutError:
                    break

            assert received_transfer, "Did not receive transfer.completed event via WebSocket"
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
                        # Just need to confirm we got at least one replayed event
                        break
                except asyncio.TimeoutError:
                    break

            assert received_any, "Did not receive any replayed events"
        finally:
            await ws.close()
