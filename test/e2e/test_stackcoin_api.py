"""
E2E tests for the StackCoin API layer.
Tests the real server via direct HTTP calls.
"""
import pytest
import httpx


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
            # Should fail with insufficient balance
            assert resp.status_code in (400, 422)


@pytest.mark.asyncio
class TestPaymentRequestLifecycle:

    async def test_create_and_deny_request(self, test_context, auth_headers):
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base) as client:
            # Create a request
            create_resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 10, "label": "E2E request test"},
                headers=auth_headers,
            )
            assert create_resp.status_code == 200
            create_data = create_resp.json()
            assert create_data.get("success") is True or "request_id" in create_data
            request_id = create_data["request_id"]

            # Deny the request
            deny_resp = await client.post(
                f"/api/requests/{request_id}/deny",
                headers=auth_headers,
            )
            assert deny_resp.status_code == 200


@pytest.mark.asyncio
class TestIdempotency:

    async def test_duplicate_send_with_same_key(self, test_context, auth_headers):
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        headers = {**auth_headers, "Idempotency-Key": "e2e-idem-key-1"}

        async with httpx.AsyncClient(base_url=base) as client:
            # Get balance before
            me_before = await client.get("/api/user/me", headers=auth_headers)
            balance_before = me_before.json()["balance"]

            # First request
            r1 = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 3, "label": "idempotent test"},
                headers=headers,
            )
            assert r1.status_code == 200

            # Second request with same key
            r2 = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 3, "label": "idempotent test"},
                headers=headers,
            )
            assert r2.status_code == 200

            # Same response (cached)
            assert r1.json() == r2.json()

            # Balance should only have changed once
            me_after = await client.get("/api/user/me", headers=auth_headers)
            assert me_after.json()["balance"] == balance_before - 3


@pytest.mark.asyncio
class TestEventDelivery:

    async def test_events_appear_after_transfer(self, test_context, auth_headers):
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base) as client:
            # Get events before
            events_before = await client.get("/api/events", headers=auth_headers)
            before_count = len(events_before.json().get("events", []))

            # Transfer
            await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 1, "label": "event test"},
                headers=auth_headers,
            )

            # Get events after
            events_after = await client.get("/api/events", headers=auth_headers)
            after_events = events_after.json()["events"]
            assert len(after_events) > before_count

            transfer_events = [e for e in after_events if e["type"] == "transfer.completed"]
            assert len(transfer_events) > 0
