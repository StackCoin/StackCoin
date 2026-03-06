"""
E2E tests for the StackCoin API layer.
Tests the real server via direct HTTP calls.
"""
import asyncio

import httpx
import pytest
import websockets


# ---------------------------------------------------------------------------
# Auth & Security
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestAuthSecurity:

    async def test_no_auth_header_returns_401(self, test_context):
        """Protected endpoints must reject requests with no auth header."""
        async with httpx.AsyncClient(base_url=test_context["base_url"]) as client:
            resp = await client.get("/api/user/me")
            assert resp.status_code == 401
            body = resp.json()
            assert "error" in body

    async def test_bogus_token_returns_401(self, test_context):
        """A completely fabricated token must be rejected."""
        headers = {
            "Authorization": "Bearer totally_fake_token_abc123",
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(base_url=test_context["base_url"]) as client:
            resp = await client.get("/api/user/me", headers=headers)
            assert resp.status_code == 401

    async def test_malformed_auth_header_returns_401(self, test_context):
        """Using the wrong auth scheme (Basic instead of Bearer) must be rejected."""
        headers = {
            "Authorization": "Basic some_value",
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(base_url=test_context["base_url"]) as client:
            resp = await client.get("/api/user/me", headers=headers)
            assert resp.status_code == 401

    async def test_websocket_rejects_invalid_token(self, test_context):
        """WebSocket endpoint must refuse connections with an invalid token."""
        ws_url = (
            test_context["base_url"].replace("http://", "ws://")
            + "/ws?token=invalid_token_here&vsn=2.0.0"
        )
        rejected = False
        try:
            async with websockets.connect(ws_url, open_timeout=5) as ws:
                # If the connection opens, the server should close it quickly.
                try:
                    await asyncio.wait_for(ws.recv(), timeout=5)
                except (
                    websockets.exceptions.ConnectionClosed,
                    asyncio.TimeoutError,
                ):
                    rejected = True
        except (
            websockets.exceptions.InvalidStatus,
            websockets.exceptions.InvalidHandshake,
            ConnectionRefusedError,
            OSError,
        ):
            rejected = True

        assert rejected, "WebSocket should reject connections with an invalid token"


# ---------------------------------------------------------------------------
# Transfers (happy path + edge cases)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestDirectTransfer:

    async def test_send_stk_success(self, test_context, auth_headers):
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 5, "label": "E2E transfer test"},
                headers=auth_headers,
            )
            assert resp.status_code == 200
            data = resp.json()
            assert data["success"] is True

    async def test_send_stk_insufficient_balance(self, test_context, auth_headers):
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 999999},
                headers=auth_headers,
            )
            assert resp.status_code in (400, 422)


@pytest.mark.asyncio
class TestTransferEdgeCases:

    async def test_self_transfer_rejected(self, test_context, auth_headers):
        """Bot cannot send STK to itself."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.post(
                f"/api/user/{test_context['bot_user_id']}/send",
                headers=auth_headers,
                json={"amount": 1, "label": "self-transfer attempt"},
            )
        assert resp.status_code == 400
        assert "self_transfer" in resp.json()["error"]

    async def test_zero_amount_rejected(self, test_context, auth_headers):
        """Sending zero STK should be rejected."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.post(
                f"/api/user/{test_context['user1_id']}/send",
                headers=auth_headers,
                json={"amount": 0, "label": "zero amount"},
            )
        assert resp.status_code in (400, 422)
        assert "error" in resp.json()

    async def test_negative_amount_rejected(self, test_context, auth_headers):
        """Sending negative STK should be rejected."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.post(
                f"/api/user/{test_context['user1_id']}/send",
                headers=auth_headers,
                json={"amount": -5, "label": "negative amount"},
            )
        assert resp.status_code in (400, 422)
        assert "error" in resp.json()

    async def test_transfer_to_nonexistent_user(self, test_context, auth_headers):
        """Sending to a non-existent user ID should return 404."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.post(
                f"/api/user/999999/send",
                headers=auth_headers,
                json={"amount": 1, "label": "nonexistent user"},
            )
        assert resp.status_code == 404
        assert "error" in resp.json()


# ---------------------------------------------------------------------------
# Request lifecycle
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestPaymentRequestLifecycle:

    async def test_create_and_deny_request(self, test_context, auth_headers):
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base) as client:
            create_resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 10, "label": "E2E request test"},
                headers=auth_headers,
            )
            assert create_resp.status_code == 200
            create_data = create_resp.json()
            assert create_data.get("success") is True or "request_id" in create_data
            request_id = create_data["request_id"]

            deny_resp = await client.post(
                f"/api/requests/{request_id}/deny",
                headers=auth_headers,
            )
            assert deny_resp.status_code == 200


@pytest.mark.asyncio
class TestRequestLifecycle:

    async def test_accept_request_rejected_for_requester(self, test_context, auth_headers):
        """Bot creates a request, then tries to accept it. Should fail (bot is the requester)."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            create_resp = await client.post(
                f"/api/user/{test_context['user1_id']}/request",
                headers=auth_headers,
                json={"amount": 1, "label": "test accept rejection"},
            )
            assert create_resp.status_code == 200
            request_id = create_resp.json()["request_id"]

            accept_resp = await client.post(
                f"/api/requests/{request_id}/accept",
                headers=auth_headers,
            )
            assert accept_resp.status_code == 403
            assert "not_request_responder" in str(accept_resp.json()).lower()

    async def test_request_events_generated(self, test_context, auth_headers):
        """Creating and denying a request should generate matching events."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            create_resp = await client.post(
                f"/api/user/{test_context['user1_id']}/request",
                headers=auth_headers,
                json={"amount": 2, "label": "test events"},
            )
            assert create_resp.status_code == 200
            request_id = create_resp.json()["request_id"]

            deny_resp = await client.post(
                f"/api/requests/{request_id}/deny",
                headers=auth_headers,
            )
            assert deny_resp.status_code == 200

            events_resp = await client.get("/api/events", headers=auth_headers)
            assert events_resp.status_code == 200
            events = events_resp.json()["events"]

            created_events = [
                e for e in events
                if e["type"] == "request.created"
                and e["data"].get("request_id") == request_id
            ]
            denied_events = [
                e for e in events
                if e["type"] == "request.denied"
                and e["data"].get("request_id") == request_id
            ]

            assert len(created_events) >= 1, "Expected at least one request.created event"
            assert len(denied_events) >= 1, "Expected at least one request.denied event"

    async def test_double_deny_rejected(self, test_context, auth_headers):
        """Acting on an already-resolved request should fail."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            create_resp = await client.post(
                f"/api/user/{test_context['user1_id']}/request",
                headers=auth_headers,
                json={"amount": 3, "label": "test double deny"},
            )
            assert create_resp.status_code == 200
            request_id = create_resp.json()["request_id"]

            first_deny = await client.post(
                f"/api/requests/{request_id}/deny",
                headers=auth_headers,
            )
            assert first_deny.status_code == 200

            second_deny = await client.post(
                f"/api/requests/{request_id}/deny",
                headers=auth_headers,
            )
            assert second_deny.status_code == 400
            assert "request_not_pending" in str(second_deny.json()).lower()

    async def test_deny_by_requester(self, test_context, auth_headers):
        """Requesters can deny their own requests."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            create_resp = await client.post(
                f"/api/user/{test_context['user1_id']}/request",
                headers=auth_headers,
                json={"amount": 5, "label": "test requester deny"},
            )
            assert create_resp.status_code == 200
            data = create_resp.json()
            request_id = data["request_id"]
            assert data["status"] == "pending"

            deny_resp = await client.post(
                f"/api/requests/{request_id}/deny",
                headers=auth_headers,
            )
            assert deny_resp.status_code == 200
            deny_data = deny_resp.json()
            assert deny_data["success"] is True
            assert deny_data["status"] == "denied"


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestIdempotency:

    async def test_duplicate_send_with_same_key(self, test_context, auth_headers):
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        headers = {**auth_headers, "Idempotency-Key": "e2e-idem-key-1"}

        async with httpx.AsyncClient(base_url=base) as client:
            me_before = await client.get("/api/user/me", headers=auth_headers)
            balance_before = me_before.json()["balance"]

            r1 = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 3, "label": "idempotent test"},
                headers=headers,
            )
            assert r1.status_code == 200

            r2 = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 3, "label": "idempotent test"},
                headers=headers,
            )
            assert r2.status_code == 200

            assert r1.json() == r2.json()

            me_after = await client.get("/api/user/me", headers=auth_headers)
            assert me_after.json()["balance"] == balance_before - 3


@pytest.mark.asyncio
class TestIdempotencyEdgeCases:

    async def test_different_keys_create_separate_transactions(self, test_context, auth_headers):
        """Different idempotency keys with identical bodies create separate transactions."""
        base = test_context["base_url"]
        url = f"/api/user/{test_context['user1_id']}/send"
        payload = {"amount": 1, "label": "duplicate body different key"}

        async with httpx.AsyncClient(base_url=base) as client:
            resp1 = await client.post(
                url,
                json=payload,
                headers={**auth_headers, "Idempotency-Key": "key-alpha"},
            )
            resp2 = await client.post(
                url,
                json=payload,
                headers={**auth_headers, "Idempotency-Key": "key-beta"},
            )

        assert resp1.status_code == 200
        assert resp2.status_code == 200
        assert resp1.json()["transaction_id"] != resp2.json()["transaction_id"]

    async def test_idempotency_caches_error_responses(self, test_context, auth_headers):
        """Error responses should also be cached by the idempotency layer."""
        base = test_context["base_url"]
        url = f"/api/user/{test_context['user1_id']}/send"
        payload = {"amount": 999999, "label": "should fail insufficient balance"}

        async with httpx.AsyncClient(base_url=base) as client:
            resp1 = await client.post(
                url,
                json=payload,
                headers={**auth_headers, "Idempotency-Key": "cached-error-key"},
            )
            resp2 = await client.post(
                url,
                json=payload,
                headers={**auth_headers, "Idempotency-Key": "cached-error-key"},
            )

        assert resp1.status_code != 200
        assert resp2.status_code == resp1.status_code
        assert resp2.json() == resp1.json()


# ---------------------------------------------------------------------------
# Read endpoints
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestReadEndpoints:

    async def test_get_me(self, test_context, auth_headers):
        """GET /api/user/me returns the bot's own user info."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.get("/api/user/me", headers=auth_headers)
        assert resp.status_code == 200
        body = resp.json()
        assert body["id"] == test_context["bot_user_id"]
        assert "username" in body
        assert "balance" in body

    async def test_get_other_user(self, test_context, auth_headers):
        """GET /api/user/:id returns another user's info."""
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.get(f"/api/user/{user1_id}", headers=auth_headers)
        assert resp.status_code == 200
        body = resp.json()
        assert body["id"] == user1_id
        assert "username" in body

    async def test_list_transactions(self, test_context, auth_headers):
        """GET /api/transactions returns a paginated list."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.get("/api/transactions", headers=auth_headers)
        assert resp.status_code == 200
        body = resp.json()
        assert "transactions" in body
        assert "pagination" in body
        txns = body["transactions"]
        assert len(txns) >= 1
        for txn in txns:
            assert "id" in txn
            assert "amount" in txn

    async def test_get_single_transaction(self, test_context, auth_headers):
        """GET /api/transaction/:id returns a single transaction."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            list_resp = await client.get(
                "/api/transactions",
                headers=auth_headers,
                params={"limit": "1"},
            )
        assert list_resp.status_code == 200
        txns = list_resp.json()["transactions"]
        assert len(txns) >= 1
        txn_id = txns[0]["id"]

        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.get(
                f"/api/transaction/{txn_id}",
                headers=auth_headers,
            )
        assert resp.status_code == 200
        assert resp.json()["id"] == txn_id

    async def test_list_requests_with_filter(self, test_context, auth_headers):
        """GET /api/requests?role=requester returns only requests where bot is requester."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.get(
                "/api/requests",
                headers=auth_headers,
                params={"role": "requester"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert "requests" in body
        bot_user_id = test_context["bot_user_id"]
        for req in body["requests"]:
            assert req["requester"]["id"] == bot_user_id


# ---------------------------------------------------------------------------
# Event delivery
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestEventPagination:
    """Test event pagination with has_more."""

    async def test_has_more_false_with_few_events(self, test_context, auth_headers):
        """Events response includes has_more=false when all events fit in one page."""
        base = test_context["base_url"]

        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.get("/api/events", headers=auth_headers)
            assert resp.status_code == 200
            body = resp.json()
            assert "has_more" in body
            assert body["has_more"] is False


@pytest.mark.asyncio
class TestEventDelivery:

    async def test_events_appear_after_transfer(self, test_context, auth_headers):
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base) as client:
            events_before = await client.get("/api/events", headers=auth_headers)
            before_count = len(events_before.json().get("events", []))

            await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 1, "label": "event test"},
                headers=auth_headers,
            )

            events_after = await client.get("/api/events", headers=auth_headers)
            after_events = events_after.json()["events"]
            assert len(after_events) > before_count

            transfer_events = [e for e in after_events if e["type"] == "transfer.completed"]
            assert len(transfer_events) > 0


# ---------------------------------------------------------------------------
# Balance drain
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestBalanceDrain:

    async def test_exact_balance_drain(self, test_context, auth_headers):
        """Sending the exact remaining balance should succeed and leave balance at 0."""
        base = test_context["base_url"]
        async with httpx.AsyncClient(base_url=base) as client:
            me_resp = await client.get("/api/user/me", headers=auth_headers)
            assert me_resp.status_code == 200
            balance = me_resp.json()["balance"]

            assert balance > 0, "Bot should have balance in a fresh seed"

            send_resp = await client.post(
                f"/api/user/{test_context['user1_id']}/send",
                headers=auth_headers,
                json={"amount": balance, "label": "exact balance drain"},
            )
            assert send_resp.status_code == 200
            body = send_resp.json()
            assert body["success"] is True
            assert body["from_new_balance"] == 0
            assert body["amount"] == balance

            verify_resp = await client.get("/api/user/me", headers=auth_headers)
            assert verify_resp.status_code == 200
            assert verify_resp.json()["balance"] == 0

