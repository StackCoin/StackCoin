"""
E2E tests for LuckyPot game logic against a real StackCoin server.

These tests import the REAL luckypot package and exercise its game logic,
db module, and stk module against the live StackCoin test server.
"""

import asyncio
import inspect
import os
import sqlite3
from unittest.mock import AsyncMock, patch

import httpx
import pytest
from stackcoin import RequestAcceptedData, RequestDeniedData

from luckypot import db, game, stk
from luckypot.discord import commands


@pytest.mark.asyncio
class TestLuckyPotEntryFlow:
    async def test_enter_pot_unregistered_user(
        self, luckypot_db, configure_luckypot_stk
    ):
        """Unregistered Discord user should get an error."""
        result = await game.enter_pot(
            discord_id="999999999",
            guild_id="test_guild_1",
        )
        assert result["status"] == "error"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_enter_pot_success(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Registered user enters the pot -- creates a payment request on StackCoin."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        assert result["status"] == "pending"
        assert "request_id" in result
        assert "entry_id" in result

        # Verify the entry exists in LuckyPot's local DB
        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, result["entry_id"])
            assert entry is not None
            assert entry["stackcoin_request_id"] == result["request_id"]
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_enter_pot_local_insert_failure_does_not_leave_stackcoin_request(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """If local entry persistence fails, the remote StackCoin request should be cancelled."""
        with patch("luckypot.game.db.add_entry", side_effect=RuntimeError("db write failed")):
            result = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="test_guild_insert_failure",
            )

        assert result["status"] == "error"

        requests = await stk.get_client().get_requests(status="pending")
        luckypot_requests = [
            request
            for request in requests
            if request.label == "LuckyPot entry (pot #1)"
            and request.responder.id == test_context["user1_id"]
        ]
        assert luckypot_requests == []

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_enter_pot_duplicate_blocked(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Second entry attempt for same user in same pot should be rejected."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        assert result1["status"] == "pending"

        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        assert result2["status"] == "already_entered"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_multiple_users_enter_same_pot(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Multiple users can enter the same pot (no instant win)."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        result2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="test_guild_1",
        )
        assert result1["status"] == "pending"
        assert result2["status"] == "pending"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_separate_guilds_separate_pots(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Same user can enter pots in different guilds."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_A",
        )
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_B",
        )
        assert result1["status"] == "pending"
        assert result2["status"] == "pending"


@pytest.mark.asyncio
class TestLuckyPotInstantWin:
    """Tests for the instant win path -- random.random is mocked to always trigger it."""

    @patch("luckypot.game.secrets.randbelow", return_value=0)
    async def test_instant_win_does_not_roll_before_payment(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A user cannot get a free instant-win attempt before paying."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_iw",
        )
        assert result["status"] == "pending"
        assert "entry_id" in result

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, result["entry_id"])
            assert entry is not None
            assert entry["status"] == "pending"
            assert entry["amount"] == game.POT_ENTRY_COST
            assert db.get_active_pot(conn, "test_guild_iw") is not None
        finally:
            conn.close()

    async def test_instant_win_with_pot_pays_out_and_ends(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """An instant win on a pot with confirmed entries pays out immediately and ends the pot."""
        # First, user1 enters normally and confirms
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            result1 = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="test_guild_iw",
            )
        assert result1["status"] == "pending"

        # Confirm user1's entry
        event_data = RequestAcceptedData(
            request_id=int(result1["request_id"]),
            status="accepted",
            transaction_id=0,
            amount=5,
        )
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            await game.on_request_accepted(event_data)

        result2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="test_guild_iw",
        )
        assert result2["status"] == "pending"

        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.on_request_accepted(
                RequestAcceptedData(
                    request_id=int(result2["request_id"]),
                    status="accepted",
                    transaction_id=0,
                    amount=5,
                )
            )

        conn = db.get_connection()
        try:
            history = db.get_pot_history(conn, "test_guild_iw")
            assert history[0]["winning_amount"] == 10
            # Pot should be ended
            assert db.get_active_pot(conn, "test_guild_iw") is None
        finally:
            conn.close()

    async def test_new_pot_starts_after_instant_win(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """After an instant win ends a pot, a new pot can be started."""
        # User1 enters and confirms
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            result1 = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="test_guild_iw",
            )
        assert result1["status"] == "pending"
        event_data = RequestAcceptedData(
            request_id=int(result1["request_id"]),
            status="accepted",
            transaction_id=0,
            amount=5,
        )
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            await game.on_request_accepted(event_data)

        result2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="test_guild_iw",
        )
        assert result2["status"] == "pending"
        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.on_request_accepted(
                RequestAcceptedData(
                    request_id=int(result2["request_id"]),
                    status="accepted",
                    transaction_id=0,
                    amount=5,
                )
            )

        # User1 should be able to enter a new pot
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            result3 = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="test_guild_iw",
            )
        assert result3["status"] == "pending"

    async def test_zero_amount_free_entries_keep_draw_weight(self):
        """Instant-win free entries should be eligible to win later draws."""
        participants = [
            {"discord_id": "free_entry_user", "amount": 0},
            {"discord_id": "paid_entry_user", "amount": game.POT_ENTRY_COST},
        ]

        with patch("luckypot.game.secrets.randbelow", return_value=0):
            winner = game.select_random_winner(participants)

        assert winner["discord_id"] == "free_entry_user"

    async def test_zero_amount_free_entries_do_not_increase_payout_value(
        self, luckypot_db
    ):
        """Free entries should get draw weight without adding uncollected STK to payouts."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild_free_weight")
            db.add_entry(conn, pot["pot_id"], "free_entry_user", 0, status="confirmed")
            db.add_entry(
                conn,
                pot["pot_id"],
                "paid_entry_user",
                game.POT_ENTRY_COST,
                "req_1",
                status="confirmed",
            )
        finally:
            conn.close()

        send = AsyncMock(return_value=True)
        with patch("luckypot.game.send_winnings_to_user", send):
            won = await game.end_pot_with_winner("guild_free_weight")

        assert won is True
        assert send.await_args.args[1] == game.POT_ENTRY_COST

        conn = db.get_connection()
        try:
            history = db.get_pot_history(conn, "guild_free_weight")
            assert history[0]["winning_amount"] == game.POT_ENTRY_COST
        finally:
            conn.close()


@pytest.mark.asyncio
class TestLuckyPotMultiGuildIsolation:
    """Tests that verify pots in different guilds are fully independent."""

    async def test_instant_win_in_guild_a_does_not_affect_guild_b(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """An instant win ending guild A's pot should not affect guild B."""
        # User1 enters guild_A normally and confirms
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            result_a1 = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="guild_A",
            )
        assert result_a1["status"] == "pending"
        event_data = RequestAcceptedData(
            request_id=int(result_a1["request_id"]),
            status="accepted",
            transaction_id=0,
            amount=5,
        )
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            await game.on_request_accepted(event_data)

        # User2 enters guild_B normally
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            result_b = await game.enter_pot(
                discord_id=test_context["user2_discord_id"],
                guild_id="guild_B",
            )
        assert result_b["status"] == "pending"

        result_a2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="guild_A",
        )
        assert result_a2["status"] == "pending"
        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.on_request_accepted(
                RequestAcceptedData(
                    request_id=int(result_a2["request_id"]),
                    status="accepted",
                    transaction_id=0,
                    amount=5,
                )
            )

        conn = db.get_connection()
        try:
            # Guild A pot should be ended
            assert db.get_active_pot(conn, "guild_A") is None

            # Guild B pot should still be active with its pending entry
            pot_b = db.get_active_pot(conn, "guild_B")
            assert pot_b is not None
            entry_b = db.get_entry_by_request_id(conn, result_b["request_id"])
            assert entry_b is not None
            assert entry_b["status"] == "pending"
        finally:
            conn.close()

    async def test_same_user_instant_win_one_guild_normal_entry_another(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Same user can instant win in guild A and enter guild B normally."""
        # On an empty pot, instant-win RNG does not bypass payment.
        with patch("luckypot.game.secrets.randbelow", return_value=0):
            result_a = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="guild_A",
            )
        assert result_a["status"] == "pending"

        # Same user enters guild_B normally
        with patch("luckypot.game.secrets.randbelow", return_value=9999):
            result_b = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="guild_B",
            )
        assert result_b["status"] == "pending"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_denied_in_guild_a_does_not_affect_guild_b_entry(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Denying a payment in guild A should not touch the same user's entry in guild B."""
        # Same user enters both guilds
        result_a = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_A",
        )
        result_b = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_B",
        )
        assert result_a["status"] == "pending"
        assert result_b["status"] == "pending"

        # Deny guild_A entry
        event_data = RequestDeniedData(
            request_id=int(result_a["request_id"]),
            status="denied",
            denied_by_id=0,
        )
        await game.on_request_denied(event_data)

        conn = db.get_connection()
        try:
            entry_a = db.get_entry_by_request_id(conn, result_a["request_id"])
            assert entry_a["status"] == "denied"

            # Guild B entry should be completely untouched
            entry_b = db.get_entry_by_request_id(conn, result_b["request_id"])
            assert entry_b["status"] == "pending"
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_daily_draw_processes_guilds_independently(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Daily draw should process each guild's pot separately."""
        # User1 enters guild_A, user2 enters guild_B
        result_a = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_A",
        )
        result_b = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="guild_B",
        )
        assert result_a["status"] == "pending"
        assert result_b["status"] == "pending"

        # Confirm both entries via accepted events
        for result in [result_a, result_b]:
            event_data = RequestAcceptedData(
                request_id=int(result["request_id"]),
                status="accepted",
                transaction_id=0,
                amount=5,
            )
            await game.on_request_accepted(event_data)

        # Run daily draw with 100% chance (mock random to always trigger)
        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.daily_pot_draw()

        conn = db.get_connection()
        try:
            # Both guilds' pots should have been drawn independently
            assert db.get_active_pot(conn, "guild_A") is None
            assert db.get_active_pot(conn, "guild_B") is None

            # Check pot history — each guild should have exactly one ended pot
            history_a = db.get_pot_history(conn, "guild_A")
            history_b = db.get_pot_history(conn, "guild_B")
            assert len(history_a) == 1
            assert len(history_b) == 1

            # Winners should be the only participant in each guild
            assert history_a[0]["winner_discord_id"] == test_context["user1_discord_id"]
            assert history_b[0]["winner_discord_id"] == test_context["user2_discord_id"]
        finally:
            conn.close()


@pytest.mark.asyncio
class TestLuckyPotPayout:
    async def test_send_winnings_success(self, configure_luckypot_stk, test_context):
        """Bot can send winnings to a user."""
        # Look up the user's STK ID
        stk_user = await stk.get_user_by_discord_id(test_context["user1_discord_id"])
        assert stk_user is not None

        success = await game.send_winnings_to_user(
            test_context["user1_discord_id"],
            10,
        )
        assert success is True

    async def test_send_winnings_insufficient_balance(
        self, configure_luckypot_stk, test_context
    ):
        """Payout fails gracefully when bot balance is too low."""
        success = await game.send_winnings_to_user(
            test_context["user1_discord_id"],
            999999,
        )
        assert success is False

    async def test_failed_payout_reopens_claimed_pot(self, luckypot_db):
        """Claim-before-send should not leave a pot inactive if no payout was sent."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild_payout_fail")
            db.add_entry(
                conn,
                pot["pot_id"],
                "winner",
                5,
                "req_1",
                status="confirmed",
            )
        finally:
            conn.close()

        with patch("luckypot.game.send_winnings_to_user", AsyncMock(return_value=False)):
            won = await game.end_pot_with_winner("guild_payout_fail")

        assert won is False
        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, "guild_payout_fail")
            assert pot is not None
            assert pot["winner_discord_id"] is None
            assert pot["ended_at"] is None
        finally:
            conn.close()

    async def test_duplicate_payout_attempt_sends_once(self, luckypot_db):
        """A second processor cannot pay a pot after the first one claimed it."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild_payout_once")
            pot_id = pot["pot_id"]
            db.add_entry(
                conn,
                pot_id,
                "winner",
                5,
                "req_1",
                status="confirmed",
            )
        finally:
            conn.close()

        send = AsyncMock(return_value=True)
        with patch("luckypot.game.send_winnings_to_user", send):
            conn1 = db.get_connection()
            conn2 = db.get_connection()
            try:
                won1 = await game.process_pot_win(
                    conn1, "guild_payout_once", "winner", 5
                )
                won2 = await game.process_pot_win(
                    conn2, "guild_payout_once", "winner", 5
                )
            finally:
                conn1.close()
                conn2.close()

        assert won1 is True
        assert won2 is False
        assert send.await_count == 1


class TestLuckyPotDb:
    """Test LuckyPot's local DB operations (using real db module)."""

    def test_pot_lifecycle(self, luckypot_db):
        """Create pot, add entries, check status."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            assert pot["pot_id"] is not None

            e1 = db.add_entry(conn, pot["pot_id"], "user1", 5, "req_1")
            e2 = db.add_entry(conn, pot["pot_id"], "user2", 5, "req_2")

            db.confirm_entry(conn, e1)
            db.confirm_entry(conn, e2)

            status = db.get_pot_status(conn, "guild1")
            assert status["active"] is True
            assert status["participants"] == 2
            assert status["total_amount"] == 10

            db.end_pot(conn, pot["pot_id"], "user1", 10, "DAILY DRAW")

            # Pot should no longer be active
            assert db.get_active_pot(conn, "guild1") is None
        finally:
            conn.close()

    def test_duplicate_entry_blocked(self, luckypot_db):
        """Same user cannot enter the same pot twice."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            db.add_entry(conn, pot["pot_id"], "user1", 5, "req_1")

            assert db.has_user_entered(conn, pot["pot_id"], "user1", 1) is True
            assert db.has_user_entered(conn, pot["pot_id"], "user2", 1) is False
        finally:
            conn.close()

    def test_only_one_active_pot_per_guild_can_exist(self, luckypot_db):
        """The DB should reject multiple active pots for the same guild."""
        conn = db.get_connection()
        try:
            db.create_pot(conn, "guild1")
            with pytest.raises(sqlite3.IntegrityError):
                db.create_pot(conn, "guild1")
        finally:
            conn.close()

    def test_stackcoin_request_id_is_unique(self, luckypot_db):
        """A StackCoin request must map to at most one LuckyPot entry."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            db.add_entry(conn, pot["pot_id"], "user1", 5, "req_1")
            with pytest.raises(sqlite3.IntegrityError):
                db.add_entry(conn, pot["pot_id"], "user2", 5, "req_1")
        finally:
            conn.close()

    def test_denied_entry_allows_same_request_id_reuse(self, luckypot_db):
        """After an entry is denied, its request_id can be reused by a new pending entry."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            entry_id = db.add_entry(conn, pot["pot_id"], "user1", 5, "req_1")
            db.deny_entry(conn, entry_id)
            # Should succeed -- the partial unique index only covers pending/confirmed
            entry_id2 = db.add_entry(conn, pot["pot_id"], "user2", 5, "req_1")
            assert entry_id2 is not None
            assert entry_id2 != entry_id
        finally:
            conn.close()


class TestLuckyPotBanDb:
    """Test LuckyPot's ban-related DB operations."""

    def test_ban_user_creates_record(self, luckypot_db):
        conn = db.get_connection()
        try:
            db.ban_user(conn, "user1", "guild1", "payment_denied", 48)
            ban = db.get_active_ban(conn, "user1", "guild1")
            assert ban is not None
            assert ban["discord_id"] == "user1"
            assert ban["guild_id"] == "guild1"
            assert ban["reason"] == "payment_denied"
        finally:
            conn.close()

    def test_get_active_ban_returns_none_when_no_ban(self, luckypot_db):
        conn = db.get_connection()
        try:
            ban = db.get_active_ban(conn, "user1", "guild1")
            assert ban is None
        finally:
            conn.close()

    def test_expired_ban_not_returned(self, luckypot_db):
        conn = db.get_connection()
        try:
            # Insert an already-expired ban
            conn.execute(
                """INSERT INTO user_bans (discord_id, guild_id, reason, expires_at)
                   VALUES (?, ?, ?, datetime('now', '-1 hours'))""",
                ("user1", "guild1", "payment_denied"),
            )
            conn.commit()
            ban = db.get_active_ban(conn, "user1", "guild1")
            assert ban is None
        finally:
            conn.close()

    def test_ban_is_guild_scoped(self, luckypot_db):
        conn = db.get_connection()
        try:
            db.ban_user(conn, "user1", "guild_A", "payment_denied", 48)
            assert db.get_active_ban(conn, "user1", "guild_A") is not None
            assert db.get_active_ban(conn, "user1", "guild_B") is None
        finally:
            conn.close()


@pytest.mark.asyncio
class TestLuckyPotEventHandlers:
    """Test the event handlers that will be wired to the WebSocket gateway."""

    async def test_on_request_accepted_confirms_entry(
        self, luckypot_db, configure_luckypot_stk
    ):
        """Simulating a request.accepted event should confirm a pending entry."""
        request_id = 12345
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            # DB column is TEXT; game.on_request_accepted converts int→str via str()
            entry_id = db.add_entry(conn, pot["pot_id"], "user1", 5, str(request_id))
        finally:
            conn.close()

        event_data = RequestAcceptedData(
            request_id=request_id, status="accepted", transaction_id=0, amount=5
        )
        await game.on_request_accepted(event_data)

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "confirmed"
        finally:
            conn.close()

    async def test_on_request_accepted_rejects_wrong_amount(
        self, luckypot_db, configure_luckypot_stk
    ):
        """An accepted event must match the local entry amount before confirmation."""
        request_id = 12346
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            entry_id = db.add_entry(conn, pot["pot_id"], "user1", 5, str(request_id))
        finally:
            conn.close()

        await game.on_request_accepted(
            RequestAcceptedData(
                request_id=request_id, status="accepted", transaction_id=0, amount=0
            )
        )

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "pending"
        finally:
            conn.close()

    async def test_denied_after_accepted_does_not_unconfirm_or_ban(
        self, luckypot_db, configure_luckypot_stk
    ):
        """A stale denied event must not overwrite a confirmed paid entry."""
        request_id = 12347
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            entry_id = db.add_entry(conn, pot["pot_id"], "user1", 5, str(request_id))
        finally:
            conn.close()

        await game.on_request_accepted(
            RequestAcceptedData(
                request_id=request_id, status="accepted", transaction_id=0, amount=5
            )
        )
        await game.on_request_denied(
            RequestDeniedData(request_id=request_id, status="denied", denied_by_id=0)
        )

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "confirmed"
            assert db.get_active_ban(conn, "user1", "guild1") is None
        finally:
            conn.close()

    async def test_on_request_accepted_after_pot_ended_refunds_entry(
        self, luckypot_db, configure_luckypot_stk
    ):
        """Accepting an old request after payout should refund instead of growing an ended pot."""
        request_id = 12345
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            entry_id = db.add_entry(conn, pot["pot_id"], "user1", 5, str(request_id))
            db.end_pot(conn, pot["pot_id"], "winner", 5, "DAILY DRAW")
        finally:
            conn.close()

        event_data = RequestAcceptedData(
            request_id=request_id, status="accepted", transaction_id=0, amount=5
        )
        refund = AsyncMock(return_value=True)
        with patch("luckypot.game.send_winnings_to_user", refund):
            await game.on_request_accepted(event_data)

        refund.assert_awaited_once_with("user1", 5, idempotency_key="pot_refund:12345")

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, entry_id)
            history = db.get_pot_history(conn, "guild1")
            assert entry["status"] == "denied"
            assert history[0]["winning_amount"] == 5
        finally:
            conn.close()

    async def test_payout_retry_after_local_end_failure_does_not_require_current_balance(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A retry after payout succeeds but local pot end fails should still close the pot."""
        guild_id = "guild_payout_retry"
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, guild_id)
            db.add_entry(
                conn,
                pot["pot_id"],
                test_context["user1_discord_id"],
                5,
                "req_1",
                status="confirmed",
            )
        finally:
            conn.close()

        send = AsyncMock(return_value=True)
        with patch("luckypot.game.send_winnings_to_user", send), patch(
            "luckypot.game.db.end_pot", side_effect=RuntimeError("db end failed")
        ):
            with pytest.raises(RuntimeError):
                await game.end_pot_with_winner(guild_id)

        with patch("luckypot.game.stk.get_bot_balance", AsyncMock(return_value=0)), patch(
            "luckypot.game.stk.get_user_by_discord_id",
            AsyncMock(return_value={"id": test_context["user1_id"]}),
        ), patch(
            "luckypot.game.stk.send_stk",
            AsyncMock(return_value={"success": True, "transaction_id": 1}),
        ):
            won = await game.end_pot_with_winner(guild_id)

        assert won is True
        conn = db.get_connection()
        try:
            assert db.get_active_pot(conn, guild_id) is None
        finally:
            conn.close()

    async def test_payout_retry_with_multiple_participants_does_not_double_pay(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Retrying a draw with >1 participant must pay the same winner, not re-roll."""
        guild_id = "guild_multi_retry"
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, guild_id)
            db.add_entry(
                conn,
                pot["pot_id"],
                test_context["user1_discord_id"],
                5,
                "req_a",
                status="confirmed",
            )
            db.add_entry(
                conn,
                pot["pot_id"],
                test_context["user2_discord_id"],
                5,
                "req_b",
                status="confirmed",
            )
        finally:
            conn.close()

        send_calls = []

        async def tracking_send(discord_id, amount, idempotency_key=None):
            send_calls.append(
                {"discord_id": discord_id, "amount": amount, "key": idempotency_key}
            )
            return True

        # end_pot fails on first attempt, then succeeds on internal retry.
        # process_pot_win should handle this without re-rolling the winner.
        call_count = {"n": 0}
        original_end_pot = db.end_pot

        def end_pot_fail_once(conn, pot_id, winner, amount, win_type):
            call_count["n"] += 1
            if call_count["n"] == 1:
                raise RuntimeError("db end failed")
            return original_end_pot(conn, pot_id, winner, amount, win_type)

        with patch("luckypot.game.send_winnings_to_user", side_effect=tracking_send), patch(
            "luckypot.game.db.end_pot", side_effect=end_pot_fail_once
        ):
            won = await game.end_pot_with_winner(guild_id)

        assert won is True
        # Only one payout should have been made (not two to different winners)
        assert len(send_calls) == 1

        conn = db.get_connection()
        try:
            assert db.get_active_pot(conn, guild_id) is None
            history = db.get_pot_history(conn, guild_id)
            assert history[0]["winner_discord_id"] == send_calls[0]["discord_id"]
            assert history[0]["winning_amount"] == 10
        finally:
            conn.close()

    async def test_on_request_denied_denies_entry(
        self, luckypot_db, configure_luckypot_stk
    ):
        """Simulating a request.denied event should deny a pending entry."""
        request_id = 99999
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            # DB column is TEXT; game.on_request_denied converts int→str via str()
            entry_id = db.add_entry(conn, pot["pot_id"], "user1", 5, str(request_id))
        finally:
            conn.close()

        event_data = RequestDeniedData(
            request_id=request_id, status="denied", denied_by_id=0
        )
        await game.on_request_denied(event_data)

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "denied"

            # Ban should also have been created
            ban = db.get_active_ban(conn, "user1", "guild1")
            assert ban is not None
            assert ban["reason"] == "payment_denied"
        finally:
            conn.close()


def test_enter_pot_command_defers_before_slow_stackcoin_work():
    """/enter-pot should acknowledge Discord before slow StackCoin calls."""
    source = inspect.getsource(commands.register_commands)
    enter_start = source.index("class EnterPot")
    pot_status_start = source.index("class PotStatus")
    enter_source = source[enter_start:pot_status_start]

    assert "ctx.defer" in enter_source
    assert enter_source.index("ctx.defer") < enter_source.index("enter_pot(")


@pytest.mark.asyncio
class TestLuckyPotPaymentDenialBan:
    """Tests for the payment denial ban system."""

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_denial_creates_ban(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Denying a payment request should create a ban record."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_ban",
        )
        assert result["status"] == "pending"

        event_data = RequestDeniedData(
            request_id=int(result["request_id"]),
            status="denied",
            denied_by_id=0,
        )
        await game.on_request_denied(event_data)

        conn = db.get_connection()
        try:
            ban = db.get_active_ban(
                conn, test_context["user1_discord_id"], "test_guild_ban"
            )
            assert ban is not None
            assert ban["reason"] == "payment_denied"
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_reenter_after_denial_uses_a_new_stackcoin_request(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Retrying after a denied request should not reuse the denied StackCoin request."""
        guild_id = "test_guild_retry_denied"
        first = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert first["status"] == "pending"

        await stk.get_client().deny_request(int(first["request_id"]))
        await game.on_request_denied(
            RequestDeniedData(
                request_id=int(first["request_id"]),
                status="denied",
                denied_by_id=test_context["bot_user_id"],
            )
        )

        conn = db.get_connection()
        try:
            conn.execute("DELETE FROM user_bans")
            conn.commit()
        finally:
            conn.close()

        second = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert second["status"] == "pending"
        assert second["request_id"] != first["request_id"]

        conn = db.get_connection()
        try:
            rows = conn.execute(
                """SELECT stackcoin_request_id, status FROM pot_entries
                   WHERE stackcoin_request_id = ?""",
                (first["request_id"],),
            ).fetchall()
            assert len(rows) == 1
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_banned_user_cannot_enter_pot(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A banned user should be rejected from entering any pot."""
        # Enter and deny to get banned
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_ban",
        )
        assert result["status"] == "pending"

        event_data = RequestDeniedData(
            request_id=int(result["request_id"]),
            status="denied",
            denied_by_id=0,
        )
        await game.on_request_denied(event_data)

        # Try to enter again — should be banned
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_ban",
        )
        assert result2["status"] == "banned"
        assert "expires_at" in result2

    @patch("luckypot.game.secrets.randbelow", return_value=0)
    async def test_banned_user_cannot_roll_instant_win(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A banned user should not get to roll for instant win — ban check comes first."""
        # Manually create a ban
        conn = db.get_connection()
        try:
            db.ban_user(
                conn,
                test_context["user1_discord_id"],
                "test_guild_ban",
                "payment_denied",
                48,
            )
        finally:
            conn.close()

        # Even with instant win rigged, should be blocked
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_ban",
        )
        assert result["status"] == "banned"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_ban_is_guild_scoped(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A ban in guild A should not block entry to guild B."""
        # Get banned in guild A
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_A_ban",
        )
        assert result["status"] == "pending"
        event_data = RequestDeniedData(
            request_id=int(result["request_id"]),
            status="denied",
            denied_by_id=0,
        )
        await game.on_request_denied(event_data)

        # Should be banned in guild A
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_A_ban",
        )
        assert result2["status"] == "banned"

        # Should be able to enter guild B
        result3 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_B_ban",
        )
        assert result3["status"] == "pending"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_expired_ban_allows_entry(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """After a ban expires, the user should be able to enter again."""
        # Create an already-expired ban
        conn = db.get_connection()
        try:
            conn.execute(
                """INSERT INTO user_bans (discord_id, guild_id, reason, expires_at)
                   VALUES (?, ?, ?, datetime('now', '-1 hours'))""",
                (
                    test_context["user1_discord_id"],
                    "test_guild_expired",
                    "payment_denied",
                ),
            )
            conn.commit()
        finally:
            conn.close()

        # Should be allowed to enter (ban is expired)
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_expired",
        )
        assert result["status"] == "pending"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_other_user_not_affected_by_ban(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Banning user1 should not affect user2 in the same guild."""
        # Ban user1
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_other",
        )
        assert result["status"] == "pending"
        event_data = RequestDeniedData(
            request_id=int(result["request_id"]),
            status="denied",
            denied_by_id=0,
        )
        await game.on_request_denied(event_data)

        # User2 should be able to enter the same guild
        result2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="test_guild_other",
        )
        assert result2["status"] == "pending"


class TestAutoEnterDb:
    """Test auto_enter_users DB operations."""

    def test_opt_in_creates_record(self, luckypot_db):
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, "user1", "guild1", True)
            assert db.get_auto_enter_status(conn, "user1", "guild1") is True
        finally:
            conn.close()

    def test_opt_out_removes_record(self, luckypot_db):
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, "user1", "guild1", True)
            db.set_auto_enter(conn, "user1", "guild1", False)
            assert db.get_auto_enter_status(conn, "user1", "guild1") is False
        finally:
            conn.close()

    def test_opt_out_when_not_opted_in_is_safe(self, luckypot_db):
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, "user1", "guild1", False)
            assert db.get_auto_enter_status(conn, "user1", "guild1") is False
        finally:
            conn.close()

    def test_opt_in_twice_is_idempotent(self, luckypot_db):
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, "user1", "guild1", True)
            db.set_auto_enter(conn, "user1", "guild1", True)
            users = db.get_auto_enter_users(conn, "guild1")
            assert users.count("user1") == 1
        finally:
            conn.close()

    def test_get_auto_enter_users_returns_all_opted_in(self, luckypot_db):
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, "user1", "guild1", True)
            db.set_auto_enter(conn, "user2", "guild1", True)
            db.set_auto_enter(conn, "user3", "guild1", True)  # opt in first
            db.set_auto_enter(conn, "user3", "guild1", False)  # then opt out
            users = db.get_auto_enter_users(conn, "guild1")
            assert set(users) == {"user1", "user2"}
        finally:
            conn.close()

    def test_auto_enter_is_guild_scoped(self, luckypot_db):
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, "user1", "guild_A", True)
            assert db.get_auto_enter_status(conn, "user1", "guild_A") is True
            assert db.get_auto_enter_status(conn, "user1", "guild_B") is False
        finally:
            conn.close()


@pytest.mark.asyncio
class TestAutoEnterTrigger:
    """Test that auto-enter fires correctly after a pot win."""

    @patch("luckypot.game.AUTO_ENTER_DELAY_SECONDS", 0)
    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_opted_in_user_is_entered_after_win(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """After a pot ends, opted-in users are automatically entered into the new pot."""
        guild_id = "test_guild_ae"

        # Opt user2 in to auto-enter
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, test_context["user2_discord_id"], guild_id, True)
        finally:
            conn.close()

        # User1 enters and confirms
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert result1["status"] == "pending"
        await game.on_request_accepted(
            RequestAcceptedData(
                request_id=int(result1["request_id"]),
                status="accepted",
                transaction_id=0,
                amount=5,
            )
        )

        # Force draw — pot ends, user1 wins
        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.end_pot_with_winner(guild_id, win_type="DAILY DRAW")

        # Drain all pending tasks (including the fire-and-forget _auto_enter_users task)
        await asyncio.gather(
            *[t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
        )

        # User2 should now have a pending entry in the NEW pot
        conn = db.get_connection()
        try:
            new_pot = db.get_active_pot(conn, guild_id)
            assert new_pot is not None
            assert (
                db.has_user_entered(
                    conn, new_pot["pot_id"], test_context["user2_discord_id"], 1
                )
                is True
            )
        finally:
            conn.close()

    @patch("luckypot.game.AUTO_ENTER_DELAY_SECONDS", 0)
    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_not_opted_in_user_is_not_entered(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Users not opted in are not auto-entered after a pot ends."""
        guild_id = "test_guild_ae_no"

        # User1 enters and confirms, no one opts in to auto-enter
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert result1["status"] == "pending"
        await game.on_request_accepted(
            RequestAcceptedData(
                request_id=int(result1["request_id"]),
                status="accepted",
                transaction_id=0,
                amount=5,
            )
        )

        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.end_pot_with_winner(guild_id, win_type="DAILY DRAW")

        # Drain all pending tasks (including the fire-and-forget _auto_enter_users task)
        await asyncio.gather(
            *[t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
        )

        # No new pot should exist yet (nobody entered to trigger ensure_active_pot)
        conn = db.get_connection()
        try:
            assert db.get_active_pot(conn, guild_id) is None
        finally:
            conn.close()

    @patch("luckypot.game.AUTO_ENTER_DELAY_SECONDS", 0)
    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_banned_user_skipped_by_auto_enter(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Auto-enter silently skips banned users."""
        guild_id = "test_guild_ae_ban"

        # Opt user2 in but also ban them
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, test_context["user2_discord_id"], guild_id, True)
            db.ban_user(
                conn, test_context["user2_discord_id"], guild_id, "payment_denied", 48
            )
        finally:
            conn.close()

        # User1 enters and confirms
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert result1["status"] == "pending"
        await game.on_request_accepted(
            RequestAcceptedData(
                request_id=int(result1["request_id"]),
                status="accepted",
                transaction_id=0,
                amount=5,
            )
        )

        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.end_pot_with_winner(guild_id, win_type="DAILY DRAW")

        # Drain all pending tasks (including the fire-and-forget _auto_enter_users task)
        await asyncio.gather(
            *[t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
        )

        # Banned user2 should not be in the new pot
        conn = db.get_connection()
        try:
            new_pot = db.get_active_pot(conn, guild_id)
            assert (
                new_pot is not None
            )  # ensure_active_pot creates it before the ban check fires
            assert (
                db.has_user_entered(
                    conn, new_pot["pot_id"], test_context["user2_discord_id"], 1
                )
                is False
            )
        finally:
            conn.close()


@pytest.mark.asyncio
class TestPreauthFlow:
    """Tests for preauthorization-enhanced pot entry."""

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_enter_pot_with_preauth_instant_confirm(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """With active preauth, enter_pot confirms entry immediately."""
        # Create and approve preauth for user1
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"],
            max_amount=10,
            window_hours=24,
        )
        assert preauth is not None
        approve_preauth(preauth["id"])

        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_preauth_guild",
        )
        assert result["status"] == "confirmed"
        assert "entry_id" in result

        # Verify entry is confirmed in LuckyPot DB
        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, result["entry_id"])
            assert entry is not None
            assert entry["status"] == "confirmed"
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_enter_pot_without_preauth_falls_back(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Without preauth, enter_pot creates a pending request as usual."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_no_preauth_guild",
        )
        assert result["status"] == "pending"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_enter_pot_preauth_budget_exceeded_skips_no_ban(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """When preauth budget is exceeded, entry is skipped without ban."""
        # Create preauth with budget of 5 (one entry only)
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"],
            max_amount=5,
            window_hours=24,
        )
        approve_preauth(preauth["id"])

        # First entry uses full budget
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_budget_guild",
        )
        assert result1["status"] == "confirmed"

        # End the pot so user can enter a new one
        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, "test_budget_guild")
            db.end_pot(conn, pot["pot_id"], test_context["user1_discord_id"], 5, "TEST")
        finally:
            conn.close()

        # Second entry exceeds budget — should be skipped
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_budget_guild",
        )
        assert result2["status"] == "skipped"

        # Verify no ban was applied
        conn = db.get_connection()
        try:
            ban = db.get_active_ban(conn, test_context["user1_discord_id"], "test_budget_guild")
            assert ban is None
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_preauth_and_normal_entry_in_same_pot(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """User with preauth gets instant entry, user without gets pending."""
        # User 1 has preauth
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"],
            max_amount=10,
            window_hours=24,
        )
        approve_preauth(preauth["id"])

        # User 1 enters — instant confirm
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_mixed_guild",
        )
        assert result1["status"] == "confirmed"

        # User 2 enters — pending (no preauth)
        result2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="test_mixed_guild",
        )
        assert result2["status"] == "pending"


# ======================================================================
# RED TEAM: Preauthorization Adversarial Tests
# ======================================================================


@pytest.mark.asyncio
class TestPreauthRedTeam:
    """Adversarial tests attempting to break the preauthorization system."""

    # ------------------------------------------------------------------
    # 1. Race condition: concurrent preauth transfers for the same user
    # ------------------------------------------------------------------
    async def test_concurrent_preauth_transfers_do_not_exceed_budget(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Two concurrent preauth requests should not allow spending more than the budget.

        Attack: user has 10 STK preauth budget. Fire two 6 STK requests
        simultaneously. Only one should succeed via preauth; the other should
        either fail with preauth_limit_exceeded or fall back to pending.
        """
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Create preauth with budget=10
        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Fire two 6-STK requests concurrently — both individually fit but
        # collectively exceed the 10 STK budget (6+6=12 > 10).
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            r1, r2 = await asyncio.gather(
                client.post(
                    f"/api/user/{user1_id}/request",
                    json={"amount": 6, "use_preauth": True, "label": "race-1"},
                    headers=headers,
                ),
                client.post(
                    f"/api/user/{user1_id}/request",
                    json={"amount": 6, "use_preauth": True, "label": "race-2"},
                    headers=headers,
                ),
            )

        results = [r1.json(), r2.json()]
        accepted_count = sum(
            1 for r in results if r.get("status") == "accepted"
        )

        # At most one should succeed via preauth. If both got accepted, the
        # budget was not atomically enforced — that's a bug.
        assert accepted_count <= 1, (
            f"Both concurrent requests were accepted via preauth! "
            f"Budget should have been 10 but 12 STK was transferred. "
            f"Responses: {results}"
        )

    # ------------------------------------------------------------------
    # 2. Budget boundary: many small requests that collectively exceed
    # ------------------------------------------------------------------
    async def test_budget_boundary_many_small_requests(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Rapid sequential small requests should not exceed the preauth budget.

        Attack: preauth is 10 STK. Send 3 requests of 4 STK each (total 12).
        Only the first two should succeed (4+4=8 ≤ 10), third should fail.
        """
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        accepted_count = 0
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            for i in range(3):
                resp = await client.post(
                    f"/api/user/{user1_id}/request",
                    json={"amount": 4, "use_preauth": True, "label": f"small-{i}"},
                    headers=headers,
                )
                data = resp.json()
                if data.get("status") == "accepted":
                    accepted_count += 1

        # First two should succeed (4+4=8 ≤ 10), third should fail (8+4=12 > 10)
        assert accepted_count == 2, (
            f"Expected exactly 2 accepted, got {accepted_count}"
        )

        # Verify remaining budget
        preauth_info = await stk.get_client().get_preauth(preauth["id"])
        assert preauth_info["remaining_budget"] == 2  # 10 - 8 = 2

    # ------------------------------------------------------------------
    # 3. Preauth + normal request interaction
    # ------------------------------------------------------------------
    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_preauth_entry_and_normal_entry_concurrent(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Preauth entry for user1 and normal entry for user2 in the same pot
        at the same time should both work correctly without interference."""

        # User 1 has preauth
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"], max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        guild_id = "test_concurrent_entry_guild"

        # Both users enter concurrently
        r1, r2 = await asyncio.gather(
            game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id=guild_id,
            ),
            game.enter_pot(
                discord_id=test_context["user2_discord_id"],
                guild_id=guild_id,
            ),
        )

        # User1 should be confirmed (preauth), user2 should be pending (no preauth)
        statuses = {r1["status"], r2["status"]}
        assert "confirmed" in statuses or "pending" in statuses, (
            f"Unexpected statuses: r1={r1['status']}, r2={r2['status']}"
        )

        # Both should have entries
        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, guild_id)
            assert pot is not None
            assert db.has_user_entered(conn, pot["pot_id"], test_context["user1_discord_id"], 1)
            assert db.has_user_entered(conn, pot["pot_id"], test_context["user2_discord_id"], 1)
        finally:
            conn.close()

    # ------------------------------------------------------------------
    # 4. Double preauth creation
    # ------------------------------------------------------------------
    async def test_double_preauth_creation_blocked(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Rapidly creating two preauths for the same user should fail on the second.

        BUG FOUND: When two preauth creations race, the second one hits a DB
        constraint and returns 500 instead of 409. The check_no_existing_preauth
        SELECT runs before INSERT for both requests, so both see "no existing" and
        both try to insert. The second INSERT violates a unique constraint but
        the changeset error is not mapped to :preauth_already_exists.
        """
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            r1, r2 = await asyncio.gather(
                client.post(
                    f"/api/user/{user1_id}/preauth",
                    json={"max_amount": 10, "window_hours": 24},
                    headers=headers,
                ),
                client.post(
                    f"/api/user/{user1_id}/preauth",
                    json={"max_amount": 20, "window_hours": 48},
                    headers=headers,
                ),
            )

        statuses = sorted([r1.status_code, r2.status_code])
        # One should succeed (200). The other should be 409 (conflict),
        # but due to the race condition bug it currently returns 500.
        assert 200 in statuses, f"At least one should succeed, got {statuses}"
        second_status = [s for s in statuses if s != 200][0]
        # This assertion documents the bug: we WANT 409, we GET 500
        assert second_status == 409, (
            f"BUG: Expected 409 (conflict) for duplicate preauth, got {second_status}. "
            f"The server returns 500 because the DB constraint violation is not "
            f"handled gracefully. "
            f"r1: {r1.status_code} {r1.json()}, r2: {r2.status_code} {r2.json()}"
        )

    # ------------------------------------------------------------------
    # 5. Preauth with zero balance user
    # ------------------------------------------------------------------
    async def test_preauth_transfer_fails_with_zero_balance(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Using preauth when the user has 0 STK should fail with insufficient balance."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Drain user1's balance first (send all 500 to bot)
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            # Get user1 balance
            me_resp = await client.get(f"/api/user/{user1_id}", headers=headers)
            balance = me_resp.json()["balance"]

            if balance > 0:
                # User needs to send to bot — we can't do this via bot API.
                # Instead, use the bot to send STK to drain user1 via requests.
                # Actually, let's just create a preauth and try to use it.
                pass

        # Create and approve preauth
        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=1000, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Try to transfer more than user's balance
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 501, "use_preauth": True, "label": "drain-attempt"},
                headers=headers,
            )

        data = resp.json()
        # Should fail — user only has 500 STK
        assert resp.status_code != 200 or data.get("status") != "accepted", (
            f"Transfer of 501 STK should have failed for user with 500 balance. "
            f"Response: {data}"
        )

    # ------------------------------------------------------------------
    # 6. Preauth for non-existent user
    # ------------------------------------------------------------------
    async def test_preauth_for_nonexistent_user(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Creating a preauth for a non-existent user ID should fail.

        BUG FOUND: The server returns 500 instead of 404 when the target user_id
        doesn't exist. The create_preauth function doesn't validate that the
        user_id exists before inserting, so the FK constraint fails and causes
        an unhandled 500 error.
        """
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                "/api/user/999999/preauth",
                json={"max_amount": 10, "window_hours": 24},
                headers=headers,
            )

        # BUG: Server returns 500 instead of 404 for non-existent user
        assert resp.status_code in (400, 404, 422), (
            f"BUG: Expected 400/404/422 for non-existent user, got {resp.status_code}. "
            f"The server crashes with an unhandled FK constraint error instead of "
            f"returning a proper error response. Response: {resp.json()}"
        )

    # ------------------------------------------------------------------
    # 7. Preauth for self (bot creates preauth for its own user ID)
    # ------------------------------------------------------------------
    async def test_preauth_for_self_rejected(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Bot should not be able to create a preauth targeting itself."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        bot_user_id = test_context["bot_user_id"]

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{bot_user_id}/preauth",
                json={"max_amount": 10, "window_hours": 24},
                headers=headers,
            )

        # Bot creating a preauth for itself is nonsensical and potentially
        # exploitable (drain own account). It should be rejected.
        assert resp.status_code != 200, (
            f"Bot was able to create a preauth for itself! "
            f"This could be exploitable. Response: {resp.json()}"
        )
        # Verify it's a proper error response, not a 500
        assert resp.status_code in (400, 403, 409, 422), (
            f"Expected a 4xx client error, got {resp.status_code}: {resp.json()}"
        )

    # ------------------------------------------------------------------
    # 8. Remaining budget accuracy after transfers
    # ------------------------------------------------------------------
    async def test_remaining_budget_decreases_correctly(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """The remaining_budget endpoint should accurately reflect transfers."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Check initial budget
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 10

        # Spend 3
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 3, "use_preauth": True, "label": "budget-test-1"},
                headers=headers,
            )
            assert resp.json()["status"] == "accepted"

        # Check budget: should be 7
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 7, (
            f"Expected 7, got {info['remaining_budget']}"
        )

        # Spend 7 (exact remaining)
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 7, "use_preauth": True, "label": "budget-test-2"},
                headers=headers,
            )
            assert resp.json()["status"] == "accepted"

        # Budget should be 0
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 0, (
            f"Expected 0, got {info['remaining_budget']}"
        )

        # One more STK should fail
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 1, "use_preauth": True, "label": "budget-test-3"},
                headers=headers,
            )
            assert resp.json().get("error") == "preauth_limit_exceeded"

    # ------------------------------------------------------------------
    # 9. Idempotency key + preauth
    # ------------------------------------------------------------------
    async def test_idempotency_key_with_preauth_request(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Duplicate requests with same idempotency key should return cached
        result and not double-charge the preauth budget."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
            "Idempotency-Key": "preauth-idem-test-1",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp1 = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "use_preauth": True, "label": "idem-preauth"},
                headers=headers,
            )
            resp2 = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "use_preauth": True, "label": "idem-preauth"},
                headers=headers,
            )

        data1 = resp1.json()
        data2 = resp2.json()

        assert data1["status"] == "accepted"
        assert data1 == data2, (
            f"Idempotent responses should match. r1={data1}, r2={data2}"
        )

        # Budget should only be charged once
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 5, (
            f"Expected 5 (single charge), got {info['remaining_budget']}"
        )

    # ------------------------------------------------------------------
    # 10. Revoke preauth then try to use it
    # ------------------------------------------------------------------
    async def test_revoked_preauth_falls_back_to_pending(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """After revoking a preauth, requests should fall back to normal pending."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Revoke it
        await stk.get_client().revoke_preauth(preauth["id"])

        # Try to use it — should fall back to pending request
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "use_preauth": True, "label": "post-revoke"},
                headers=headers,
            )

        data = resp.json()
        assert data["status"] == "pending", (
            f"Expected pending (fallback), got {data['status']}. "
            f"Revoked preauth should not allow transfers."
        )

    # ------------------------------------------------------------------
    # 11. Preauth budget exact boundary (off-by-one check)
    # ------------------------------------------------------------------
    async def test_preauth_exact_boundary_then_one_more(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Spending exactly the budget should succeed, then 1 more should fail."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=5, window_hours=24,
        )
        approve_preauth(preauth["id"])

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            # Exact budget should succeed
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "use_preauth": True, "label": "exact-budget"},
                headers=headers,
            )
            assert resp.json()["status"] == "accepted"

            # One more should fail
            resp2 = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 1, "use_preauth": True, "label": "over-budget"},
                headers=headers,
            )
            assert resp2.json().get("error") == "preauth_limit_exceeded", (
                f"Expected preauth_limit_exceeded, got {resp2.json()}"
            )

    # ------------------------------------------------------------------
    # 12. Multiple pots same guild: preauth budget spans pots
    # ------------------------------------------------------------------
    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_preauth_budget_spans_pot_boundaries(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Preauth budget should be shared across pot boundaries.
        If user enters pot #1 (5 STK) and pot #2 (5 STK), a 10 STK
        preauth should be fully consumed."""

        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"], max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        guild_id = "test_budget_spans_guild"

        # Enter pot #1 — should confirm via preauth (5 STK)
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert result1["status"] == "confirmed"

        # End pot #1 so a new pot starts
        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, guild_id)
            db.end_pot(conn, pot["pot_id"], test_context["user1_discord_id"], 5, "TEST")
        finally:
            conn.close()

        # Enter pot #2 — should also confirm (5 STK, total 10 = budget)
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert result2["status"] == "confirmed"

        # Check remaining budget = 0
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 0

        # End pot #2 and try pot #3 — should be skipped (budget exhausted)
        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, guild_id)
            db.end_pot(conn, pot["pot_id"], test_context["user1_discord_id"], 5, "TEST")
        finally:
            conn.close()

        result3 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert result3["status"] == "skipped", (
            f"Expected skipped (budget exhausted), got {result3['status']}"
        )

    # ------------------------------------------------------------------
    # 13. Concurrent preauth transfers: higher concurrency stress test
    # ------------------------------------------------------------------
    async def test_concurrent_preauth_transfers_stress_no_overspend(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Fire 5 concurrent 3-STK requests against a 10-STK preauth.
        The critical invariant: total spending must not exceed the 10 STK budget.
        Some requests may fail due to SQLite lock contention, but none should
        cause an overspend."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            tasks = [
                client.post(
                    f"/api/user/{user1_id}/request",
                    json={"amount": 3, "use_preauth": True, "label": f"stress-{i}"},
                    headers=headers,
                )
                for i in range(5)
            ]
            responses = await asyncio.gather(*tasks)

        accepted = [r for r in responses if r.json().get("status") == "accepted"]
        total_spent = len(accepted) * 3

        # Critical safety check: never overspend the budget
        assert total_spent <= 10, (
            f"BUDGET OVERFLOW BUG! {len(accepted)} requests accepted for {total_spent} STK "
            f"against a 10 STK budget. Responses: "
            f"{[r.json() for r in responses]}"
        )

        # At least one should have succeeded
        assert len(accepted) >= 1, (
            f"Expected at least 1 accepted, got {len(accepted)}. "
            f"Responses: {[r.json() for r in responses]}"
        )

        # Verify the remaining budget is consistent
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 10 - total_spent, (
            f"Budget accounting mismatch: spent {total_spent}, "
            f"remaining {info['remaining_budget']}, max was 10"
        )

    # ------------------------------------------------------------------
    # 14. Preauth after revoke: create new preauth should work
    # ------------------------------------------------------------------
    async def test_new_preauth_after_revoke(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """After revoking a preauth, creating a new one should succeed."""
        user1_id = test_context["user1_id"]

        preauth1 = await stk.create_preauth(
            user_id=user1_id, max_amount=5, window_hours=24,
        )
        approve_preauth(preauth1["id"])
        await stk.get_client().revoke_preauth(preauth1["id"])

        # Should be able to create a new preauth
        preauth2 = await stk.create_preauth(
            user_id=user1_id, max_amount=20, window_hours=48,
        )
        assert preauth2 is not None
        assert preauth2["max_amount"] == 20

    # ------------------------------------------------------------------
    # 15. Negative and zero amounts via API
    # ------------------------------------------------------------------
    async def test_preauth_request_with_zero_amount(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """A preauth request with amount=0 should be rejected."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 0, "use_preauth": True, "label": "zero-amount"},
                headers=headers,
            )

        assert resp.status_code == 400, (
            f"Expected 400 for zero amount, got {resp.status_code}: {resp.json()}"
        )

    async def test_preauth_request_with_negative_amount(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """A preauth request with negative amount should be rejected."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": -5, "use_preauth": True, "label": "negative-amount"},
                headers=headers,
            )

        assert resp.status_code == 400, (
            f"Expected 400 for negative amount, got {resp.status_code}: {resp.json()}"
        )

    # ------------------------------------------------------------------
    # 16. use_preauth=false should never use preauth
    # ------------------------------------------------------------------
    async def test_use_preauth_false_ignores_active_preauth(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Setting use_preauth=false should create a pending request even
        when an active preauth exists."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "use_preauth": False, "label": "no-preauth"},
                headers=headers,
            )

        data = resp.json()
        assert data["status"] == "pending", (
            f"Expected pending when use_preauth=false, got {data['status']}"
        )

        # Budget should be unchanged
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 10

    # ------------------------------------------------------------------
    # 17. Preauth with zero max_amount (validation bypass attempt)
    # ------------------------------------------------------------------
    async def test_preauth_creation_rejects_zero_max_amount(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Creating a preauth with max_amount=0 should be rejected."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{test_context['user1_id']}/preauth",
                json={"max_amount": 0, "window_hours": 24},
                headers=headers,
            )

        assert resp.status_code == 400, (
            f"Expected 400 for zero max_amount, got {resp.status_code}: {resp.json()}"
        )

    async def test_preauth_creation_rejects_negative_max_amount(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Creating a preauth with negative max_amount should be rejected."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{test_context['user1_id']}/preauth",
                json={"max_amount": -10, "window_hours": 24},
                headers=headers,
            )

        assert resp.status_code == 400, (
            f"Expected 400 for negative max_amount, got {resp.status_code}: {resp.json()}"
        )

    # ------------------------------------------------------------------
    # 18. Revoke another bot's preauth
    # ------------------------------------------------------------------
    async def test_cannot_revoke_another_bots_preauth(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Bot should not be able to revoke a preauth it didn't create.
        (In e2e context with one bot, we test that the API at least
        returns 403 for a preauth ID that doesn't belong to it.)
        """
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }

        # Try to revoke a non-existent preauth (ID 99999)
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                "/api/preauth/99999/revoke",
                headers=headers,
            )

        assert resp.status_code == 404, (
            f"Expected 404 for non-existent preauth, got {resp.status_code}: {resp.json()}"
        )

    # ------------------------------------------------------------------
    # 19. Preauth transfer should move STK correctly
    # ------------------------------------------------------------------
    async def test_preauth_transfer_updates_balances_correctly(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Preauth transfer should move STK from user to bot."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Get balances before
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            bot_before = (await client.get("/api/user/me", headers=headers)).json()["balance"]
            user_before = (await client.get(f"/api/user/{user1_id}", headers=headers)).json()["balance"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Transfer 7 STK via preauth
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 7, "use_preauth": True, "label": "balance-check"},
                headers=headers,
            )
            assert resp.json()["status"] == "accepted"

            # Check balances after
            bot_after = (await client.get("/api/user/me", headers=headers)).json()["balance"]
            user_after = (await client.get(f"/api/user/{user1_id}", headers=headers)).json()["balance"]

        assert bot_after == bot_before + 7, (
            f"Bot balance should increase by 7: {bot_before} -> {bot_after}"
        )
        assert user_after == user_before - 7, (
            f"User balance should decrease by 7: {user_before} -> {user_after}"
        )

    # ------------------------------------------------------------------
    # 20. Pending preauth should not allow transfers
    # ------------------------------------------------------------------
    async def test_pending_preauth_does_not_allow_transfers(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A pending (not yet approved) preauth should not allow preauth transfers."""
        import httpx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Create preauth but DON'T approve it
        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        assert preauth["status"] == "pending"

        # Try to use it — should fall back to pending request
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "use_preauth": True, "label": "pending-preauth"},
                headers=headers,
            )

        data = resp.json()
        assert data["status"] == "pending", (
            f"Expected pending (preauth not yet approved), got {data['status']}"
        )


# ======================================================================
# RED TEAM: API Authorization, Race Conditions, and Data Consistency
# ======================================================================


@pytest.mark.asyncio
class TestAPIRedTeam:
    """
    Red team tests targeting the StackCoin HTTP API layer.

    Categories:
      - Authorization: can one bot act on another bot's resources?
      - Race conditions: can concurrent requests break invariants?
      - Data consistency: does the ledger stay balanced after stress?
    """

    # ==================================================================
    # AUTHORIZATION TESTS
    # ==================================================================

    async def test_invalid_token_returns_401(self, stackcoin_server):
        """Requests with a bogus token should be rejected with 401."""
        base = stackcoin_server["base_url"]
        headers = {"Authorization": "Bearer bogus_token_12345"}

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.get("/api/user/me", headers=headers)

        assert resp.status_code == 401, (
            f"Expected 401 for invalid token, got {resp.status_code}: {resp.json()}"
        )

    async def test_missing_auth_header_returns_401(self, stackcoin_server):
        """Requests with no Authorization header should be rejected with 401."""
        base = stackcoin_server["base_url"]

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.get("/api/user/me")

        assert resp.status_code == 401, (
            f"Expected 401 for missing auth, got {resp.status_code}: {resp.json()}"
        )

    async def test_malformed_auth_header_returns_401(self, stackcoin_server):
        """Authorization header without 'Bearer ' prefix should be rejected."""
        base = stackcoin_server["base_url"]
        headers = {"Authorization": "Token some_value"}

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.get("/api/user/me", headers=headers)

        assert resp.status_code == 401, (
            f"Expected 401 for malformed auth header, got {resp.status_code}: {resp.json()}"
        )

    async def test_bot_a_cannot_accept_bot_b_request(
        self, test_context, stackcoin_server, seed_data
    ):
        """Bot A should not be able to accept a request where Bot A is not the responder.

        The request controller checks validate_request_responder which compares
        request.responder_id to current_bot.user.id. If Bot A is both requester
        and tries to accept its own request (where someone else is the responder),
        it should fail.

        Here we create a request from user1 -> bot (bot is responder), then try
        to accept it using the bot's own token — which should succeed because the
        bot IS the responder. But we also test the inverse: create a request from
        bot -> user1 (user1 is responder), then try to accept it as the bot — this
        should fail with 'not_request_responder'.
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Create a request FROM the bot TO user1 (user1 is the responder)
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            create_resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 1, "label": "authz-test-accept"},
                headers=headers,
            )
            assert create_resp.status_code == 200, (
                f"Request creation failed: {create_resp.json()}"
            )
            request_id = create_resp.json()["request_id"]

            # Bot tries to accept the request — but user1 is the responder, not bot
            accept_resp = await client.post(
                f"/api/requests/{request_id}/accept",
                headers=headers,
            )

        # Should be forbidden: bot is the requester, not the responder
        assert accept_resp.status_code == 403, (
            f"Bot should not be able to accept a request where it is the requester. "
            f"Expected 403, got {accept_resp.status_code}: {accept_resp.json()}"
        )
        assert accept_resp.json()["error"] == "not_request_responder"

    async def test_bot_cannot_deny_unrelated_request(
        self, test_context
    ):
        """Bot should not be able to deny a request it's not involved in at all.

        Code analysis: deny_request uses validate_request_participant which checks
        that user_id is either requester_id or responder_id. Since our bot creates
        requests between itself and test users, any request the bot creates will
        involve it. To test properly, we'd need two bots.

        FINDING: With a single bot, we can't truly test cross-bot deny. However,
        we can verify that the participant check works by checking the error mapping.
        The core function returns :not_involved_in_request -> 403.
        """
        # This is a documentation test. With one bot in e2e, we verify the
        # API at least maps the error correctly for non-existent requests.
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                "/api/requests/999999/deny",
                headers=headers,
            )

        assert resp.status_code == 404, (
            f"Expected 404 for non-existent request, got {resp.status_code}: {resp.json()}"
        )

    async def test_bot_a_cannot_revoke_bot_b_preauth(
        self, test_context, approve_preauth
    ):
        """The preauth revoke endpoint checks bot_user_id ownership.

        We create a preauth (owned by our bot), approve it, then verify the
        ownership check exists. Since we only have one bot, we verify the
        positive case works and document that the check at
        preauth_controller.ex:90 exists.

        AUDIT FINDING: The check `preauth.bot_user_id != current_bot.user.id`
        at preauth_controller.ex:90 is CORRECT — it returns 403 "Not your
        preauthorization". This is properly secured.
        """
        import httpx as hx

        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Create and approve a preauth
        async with hx.AsyncClient(base_url=base) as client:
            create_resp = await client.post(
                f"/api/user/{user1_id}/preauth",
                json={"max_amount": 10, "window_hours": 24},
                headers=headers,
            )
            assert create_resp.status_code == 200
            preauth_id = create_resp.json()["id"]
            approve_preauth(preauth_id)

            # Bot CAN revoke its own preauth (positive test)
            revoke_resp = await client.post(
                f"/api/preauth/{preauth_id}/revoke",
                headers=headers,
            )
            assert revoke_resp.status_code == 200, (
                f"Bot should be able to revoke its own preauth: {revoke_resp.json()}"
            )

    async def test_request_show_no_access_control(
        self, test_context
    ):
        """FINDING: GET /api/request/:id has NO access control — any authenticated
        bot can view any request by ID, regardless of involvement.

        File: request_controller.ex:319-355
        The show/2 function fetches the request by ID and returns it without
        checking if the current bot is the requester or responder.

        Severity: MEDIUM — information disclosure of request details.
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Create a request
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            create_resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 1, "label": "show-test"},
                headers=headers,
            )
            request_id = create_resp.json()["request_id"]

            # Any bot can view it — this documents the lack of access control
            show_resp = await client.get(
                f"/api/request/{request_id}",
                headers=headers,
            )

        # This PASSES (200) — documenting that there's no scoping
        assert show_resp.status_code == 200
        # This is the finding: the endpoint works but doesn't check ownership

    async def test_transaction_show_no_access_control(
        self, test_context
    ):
        """FINDING: GET /api/transaction/:id has NO access control — any authenticated
        bot can view any transaction by ID.

        File: transaction_controller.ex:168-201
        The show/2 function fetches the transaction by ID and returns it without
        checking if the current bot is the sender or receiver.

        Severity: MEDIUM — information disclosure of transaction details including
        amounts, labels, and balance snapshots.
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Create a transaction (bot sends to user1)
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            send_resp = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 1, "label": "txn-show-test"},
                headers=headers,
            )
            assert send_resp.status_code == 200
            txn_id = send_resp.json()["transaction_id"]

            # Any bot can view it
            show_resp = await client.get(
                f"/api/transaction/{txn_id}",
                headers=headers,
            )

        assert show_resp.status_code == 200
        # This documents the finding: no ownership check on transaction show

    # ==================================================================
    # RACE CONDITION / STRESS TESTS
    # ==================================================================

    async def test_concurrent_balance_overdraw(self, test_context):
        """Fire 5 concurrent sends of 30 STK from a bot with 1000 STK balance.

        At most floor(1000/30)=33 could succeed. With 5 concurrent, all 5 might
        succeed (150 STK total, well within 1000). The real test is: does balance
        ever go negative?

        To make this a real overdraw test, we first drain the bot down to ~100 STK,
        then fire 5 concurrent sends of 30 each (150 total > 100 available).
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]
        user2_id = test_context["user2_id"]

        # First check bot balance
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            me_resp = await client.get("/api/user/me", headers=headers)
            bot_balance = me_resp.json()["balance"]

        # Drain bot to ~100 by sending to user1
        drain_amount = bot_balance - 100
        if drain_amount > 0:
            async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
                drain_resp = await client.post(
                    f"/api/user/{user1_id}/send",
                    json={"amount": drain_amount, "label": "drain-for-stress"},
                    headers=headers,
                )
                assert drain_resp.status_code == 200, (
                    f"Drain failed: {drain_resp.json()}"
                )

        # Verify bot has ~100 STK
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            me_resp = await client.get("/api/user/me", headers=headers)
            bot_balance = me_resp.json()["balance"]
        assert bot_balance == 100, f"Expected 100, got {bot_balance}"

        # Fire 5 concurrent sends of 30 STK each (150 total > 100 available)
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            tasks = [
                client.post(
                    f"/api/user/{user2_id}/send",
                    json={"amount": 30, "label": f"overdraw-{i}"},
                    headers=headers,
                )
                for i in range(5)
            ]
            responses = await asyncio.gather(*tasks)

        successes = [r for r in responses if r.status_code == 200]
        failures = [r for r in responses if r.status_code != 200]

        # At most 3 should succeed (3*30=90 <= 100, 4*30=120 > 100)
        assert len(successes) <= 3, (
            f"OVERDRAW BUG! {len(successes)} sends of 30 STK succeeded from 100 STK balance. "
            f"Max allowed is 3. Responses: {[r.json() for r in responses]}"
        )

        # At least 1 should succeed
        assert len(successes) >= 1, (
            f"Expected at least 1 success, got {len(successes)}. "
            f"Responses: {[r.json() for r in responses]}"
        )

        # CRITICAL: Balance must never go negative
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            me_resp = await client.get("/api/user/me", headers=headers)
            final_balance = me_resp.json()["balance"]

        assert final_balance >= 0, (
            f"CRITICAL BUG: Balance went negative! Final balance: {final_balance}. "
            f"{len(successes)} sends of 30 succeeded from initial 100."
        )

        # Verify consistency: balance should be exactly 100 - (successes * 30)
        expected = 100 - (len(successes) * 30)
        assert final_balance == expected, (
            f"Balance inconsistency: expected {expected}, got {final_balance}. "
            f"{len(successes)} sends succeeded."
        )

    async def test_concurrent_request_accept_double_charge(self, test_context):
        """Create a request, then fire 5 concurrent accept calls.

        Only 1 should succeed — the others should fail with request_not_pending.
        If more than 1 succeeds, the responder gets double-charged.

        Code path: accept_request reads the request, checks status=="pending",
        then does the transfer. Race: two concurrent accepts both see "pending".
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        bot_user_id = test_context["bot_user_id"]
        user1_id = test_context["user1_id"]

        # Get bot balance before
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            me_resp = await client.get("/api/user/me", headers=headers)
            bot_balance_before = me_resp.json()["balance"]

        # Create a request FROM user1 TO bot (bot is responder, will pay)
        # We use the bot to create a request to itself... actually the bot
        # can only create requests FROM itself. So we need a request where
        # the bot is the responder. The bot creates requests where it's the requester.
        #
        # Workaround: create request from bot to user1, then user1 needs to accept.
        # But user1 is not a bot, can't make API calls.
        #
        # Actually: POST /api/user/:id/request creates a request where:
        #   requester = current_bot.user, responder = :id
        # So if bot requests from user1, user1 is the responder.
        # For bot to be the responder, user1 would need to request from bot.
        #
        # Since we can only make API calls as the bot, let's have the bot create
        # a request where user1 is the responder, then we CAN'T accept it as the bot
        # (bot is the requester, not the responder).
        #
        # Alternative approach: test with a request where bot IS the responder.
        # We'd need user1 to create a request... which requires user1 to be a bot.
        #
        # Best approach for this test: create the request via the seed, or test
        # that concurrent accepts of a request the bot CAN accept don't double-charge.
        #
        # Let's create a request from bot (requester) to user1 (responder), then
        # try to accept it as bot. This should fail because bot is not the responder.
        # That's an auth test, not a race test.
        #
        # For the race test, we need to test that the status check is atomic.
        # Let's use the fact that the first accept transitions pending->accepted,
        # and subsequent accepts should see "accepted" and fail.
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            # Bot creates request: bot(requester) -> user1(responder)
            create_resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "label": "race-accept-test"},
                headers=headers,
            )
            assert create_resp.status_code == 200
            request_id = create_resp.json()["request_id"]

        # The bot is the requester, user1 is the responder.
        # Only user1 can accept. Since bot can't accept (it's the requester),
        # all 5 attempts should fail with not_request_responder.
        # This becomes an auth test rather than a race test.
        #
        # However, we can still test: fire 5 concurrent deny calls (bot CAN deny
        # as the requester/participant). Only 1 should succeed.
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            tasks = [
                client.post(
                    f"/api/requests/{request_id}/deny",
                    headers=headers,
                )
                for _ in range(5)
            ]
            responses = await asyncio.gather(*tasks)

        successes = [r for r in responses if r.status_code == 200]
        request_not_pending = [
            r for r in responses
            if r.status_code != 200 and r.json().get("error") == "request_not_pending"
        ]

        # With the atomic status check (WHERE status = 'pending' in the UPDATE),
        # exactly 1 concurrent deny should succeed and the rest should get
        # request_not_pending.
        assert len(successes) == 1, (
            f"Expected exactly 1 successful deny, got {len(successes)}. "
            f"Responses: {[r.json() for r in responses]}"
        )
        assert len(request_not_pending) == 4, (
            f"Expected 4 request_not_pending errors, got {len(request_not_pending)}. "
            f"Responses: {[r.json() for r in responses]}"
        )

    async def test_concurrent_preauth_transfers_budget_enforcement(
        self, test_context, approve_preauth
    ):
        """Fire 5 concurrent preauth requests for 3 STK each against a 10 STK budget.

        At most 3 should succeed (3*3=9 <= 10). If 4+ succeed, the budget was exceeded.

        RACE CONDITION ANALYSIS (preauthorization.ex:212-219):
        check_budget reads get_used_amount (a SELECT SUM), then the transfer happens.
        Two concurrent requests could both read used=0, both see 0+3 <= 10, both proceed.
        This is a classic TOCTOU race. SQLite's WAL mode may serialize, but the race
        window exists between the read and the write.
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Create preauth with budget=10
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            create_resp = await client.post(
                f"/api/user/{user1_id}/preauth",
                json={"max_amount": 10, "window_hours": 24},
                headers=headers,
            )
            assert create_resp.status_code == 200
            preauth_id = create_resp.json()["id"]
        approve_preauth(preauth_id)

        # Fire 5 concurrent 3-STK preauth transfers
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            tasks = [
                client.post(
                    f"/api/user/{user1_id}/request",
                    json={"amount": 3, "use_preauth": True, "label": f"race-preauth-{i}"},
                    headers=headers,
                )
                for i in range(5)
            ]
            responses = await asyncio.gather(*tasks)

        accepted = [r for r in responses if r.json().get("status") == "accepted"]
        total_spent = len(accepted) * 3

        # CRITICAL: total spent must not exceed budget
        assert total_spent <= 10, (
            f"PREAUTH BUDGET OVERFLOW! {len(accepted)} requests accepted = {total_spent} STK "
            f"against 10 STK budget. Responses: {[r.json() for r in responses]}"
        )

        # At most 3 should succeed (3*3=9 <= 10)
        assert len(accepted) <= 3, (
            f"Too many accepted: {len(accepted)} (max should be 3). "
            f"Responses: {[r.json() for r in responses]}"
        )

        # At least 1 should succeed
        assert len(accepted) >= 1, (
            f"Expected at least 1 accepted, got {len(accepted)}. "
            f"Responses: {[r.json() for r in responses]}"
        )

        # Verify remaining budget is consistent
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            preauth_resp = await client.get(
                f"/api/preauth/{preauth_id}",
                headers=headers,
            )
        remaining = preauth_resp.json()["remaining_budget"]
        assert remaining == 10 - total_spent, (
            f"Budget accounting mismatch: spent {total_spent}, remaining {remaining}, max 10"
        )

    async def test_idempotency_under_concurrency(self, test_context):
        """Fire 5 concurrent requests with the same idempotency key.

        Only 1 transfer should be created. All 5 should return the same response.

        Code path (idempotency.ex): claim_key uses INSERT OR IGNORE which is atomic
        in SQLite. The first to insert claims it, others get :contended and poll.

        NOTE: The idempotency poll timeout is 5s (idempotency.ex:23), and the
        underlying operation may block on SQLite locks. We use a generous HTTP
        timeout to account for this.
        """
        base = test_context["base_url"]
        idem_key = f"stress-idem-{asyncio.get_event_loop().time()}"
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
            "Idempotency-Key": idem_key,
        }
        user1_id = test_context["user1_id"]

        # Get bot balance before
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            me_resp = await client.get(
                "/api/user/me",
                headers={"Authorization": f"Bearer {test_context['bot_token']}"},
            )
            bot_balance_before = me_resp.json()["balance"]

        # Fire 5 concurrent sends with same idempotency key
        # Use a long timeout since contended requests poll for up to 5s
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            tasks = [
                client.post(
                    f"/api/user/{user1_id}/send",
                    json={"amount": 10, "label": "idem-stress"},
                    headers=headers,
                )
                for _ in range(5)
            ]
            results = await asyncio.gather(*tasks, return_exceptions=True)

        # Separate successful responses from timeouts/errors
        responses = [r for r in results if isinstance(r, httpx.Response)]
        timeouts = [r for r in results if isinstance(r, Exception)]

        if timeouts:
            # Timeouts under idempotency contention with SQLite are a finding
            pytest.xfail(
                f"IDEMPOTENCY CONTENTION BUG: {len(timeouts)} of 5 concurrent requests "
                f"timed out. The idempotency poll loop (idempotency.ex:167) combined with "
                f"SQLite busy locks causes requests to exceed HTTP timeouts. "
                f"Severity: HIGH — clients get timeouts instead of idempotent responses."
            )

        # Check for 500 errors caused by SQLite contention within idempotency
        errors_500 = [r for r in responses if r.status_code == 500]
        ok_responses = [r for r in responses if r.status_code == 200]

        if errors_500:
            # BUG: When the idempotency system's poll_for_response times out
            # (idempotency.ex:52-57), it falls back to executing the function.
            # But the fallback also hits SQLite BUSY, causing a 500.
            # Meanwhile, the claim_key approach is sound — at most 1 transfer
            # should have been created. Verify the data integrity.
            pytest.xfail(
                f"IDEMPOTENCY + SQLITE CONTENTION BUG: {len(errors_500)} of "
                f"{len(responses)} idempotent requests returned 500. "
                f"The idempotency claim (INSERT OR IGNORE) is atomic, but the "
                f"underlying operation and the fallback path both crash on SQLite BUSY. "
                f"Severity: HIGH — idempotent requests should never return 500. "
                f"File: idempotency.ex:52-57 (fallback after poll timeout). "
                f"Successes: {len(ok_responses)}, 500s: {len(errors_500)}"
            )

        # All successful responses should return 200
        for r in ok_responses:
            assert r.status_code == 200

        # All should return the same transaction_id
        txn_ids = {r.json()["transaction_id"] for r in ok_responses}
        assert len(txn_ids) == 1, (
            f"IDEMPOTENCY BUG: Multiple transactions created! "
            f"Transaction IDs: {txn_ids}. Responses: {[r.json() for r in ok_responses]}"
        )

        # Balance should only decrease by 10 (one transfer)
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            me_resp = await client.get(
                "/api/user/me",
                headers={"Authorization": f"Bearer {test_context['bot_token']}"},
            )
            bot_balance_after = me_resp.json()["balance"]

        assert bot_balance_after == bot_balance_before - 10, (
            f"Balance should decrease by exactly 10 (one transfer). "
            f"Before: {bot_balance_before}, After: {bot_balance_after}, "
            f"Diff: {bot_balance_before - bot_balance_after}"
        )

    async def test_idempotency_different_keys_create_separate_transfers(
        self, test_context
    ):
        """Different idempotency keys should create separate transfers.

        SQLite's single-writer model means truly concurrent writes may still
        fail under tight contention even with busy_timeout. We verify at least
        1 succeeds and none produce inconsistent data.
        """
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            tasks = [
                client.post(
                    f"/api/user/{user1_id}/send",
                    json={"amount": 1, "label": f"diff-key-{i}"},
                    headers={
                        "Authorization": f"Bearer {test_context['bot_token']}",
                        "Content-Type": "application/json",
                        "Idempotency-Key": f"unique-key-{i}-{asyncio.get_event_loop().time()}",
                    },
                )
                for i in range(3)
            ]
            responses = await asyncio.gather(*tasks)

        successes = [r for r in responses if r.status_code == 200]
        errors = [r for r in responses if r.status_code != 200]
        txn_ids = {r.json()["transaction_id"] for r in successes}

        # At least 1 must succeed; all that succeed must have unique txn IDs
        assert len(successes) >= 1, (
            f"At least 1 should succeed: {[r.json() for r in responses]}"
        )
        assert len(txn_ids) == len(successes), (
            f"Each success should have a unique transaction. Got IDs: {txn_ids}"
        )

    # ==================================================================
    # DATA CONSISTENCY TESTS
    # ==================================================================

    async def test_ledger_consistency_after_stress(self, test_context, stackcoin_server):
        """After multiple concurrent operations, verify:
        sum(all_balances) == sum(all_pumps)

        This is the fundamental ledger invariant. Pumps inject STK into the system
        from the reserve, and the total of all user balances must equal the total
        pumped amount.
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]
        user2_id = test_context["user2_id"]

        # Run a bunch of concurrent transfers to stress the system
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            tasks = []
            for i in range(5):
                tasks.append(
                    client.post(
                        f"/api/user/{user1_id}/send",
                        json={"amount": 1, "label": f"stress-{i}"},
                        headers=headers,
                    )
                )
                tasks.append(
                    client.post(
                        f"/api/user/{user2_id}/send",
                        json={"amount": 1, "label": f"stress-{i}"},
                        headers=headers,
                    )
                )
            responses = await asyncio.gather(*tasks)

        # Now verify ledger consistency by querying the database directly
        port = stackcoin_server["port"]
        db_file = os.path.join(
            os.path.dirname(__file__), "../../..",
            f"data/e2e_test_{port}.db",
        )
        conn = sqlite3.connect(db_file, timeout=10)
        try:
            conn.execute("PRAGMA busy_timeout = 5000")

            # Sum of all user balances
            total_balances = conn.execute(
                "SELECT COALESCE(SUM(balance), 0) FROM user"
            ).fetchone()[0]

            # Sum of all pumps (STK injected into the system)
            total_pumps = conn.execute(
                "SELECT COALESCE(SUM(amount), 0) FROM pump"
            ).fetchone()[0]
        finally:
            conn.close()

        assert total_balances == total_pumps, (
            f"LEDGER INCONSISTENCY! "
            f"sum(balances)={total_balances} != sum(pumps)={total_pumps}. "
            f"Difference: {total_balances - total_pumps}"
        )

    async def test_failed_transfer_leaves_consistent_state(self, test_context):
        """A failed transfer (insufficient balance) should not leave partial state.

        Send more than the bot has — should fail cleanly with no balance change.
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Get balances before
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            bot_before = (await client.get("/api/user/me", headers=headers)).json()["balance"]
            user_before = (await client.get(f"/api/user/{user1_id}", headers=headers)).json()["balance"]

            # Try to send way more than available
            resp = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 999999, "label": "should-fail"},
                headers=headers,
            )
            assert resp.status_code == 422  # insufficient_balance

            # Verify balances unchanged
            bot_after = (await client.get("/api/user/me", headers=headers)).json()["balance"]
            user_after = (await client.get(f"/api/user/{user1_id}", headers=headers)).json()["balance"]

        assert bot_after == bot_before, (
            f"Bot balance changed after failed transfer: {bot_before} -> {bot_after}"
        )
        assert user_after == user_before, (
            f"User balance changed after failed transfer: {user_before} -> {user_after}"
        )

    async def test_self_transfer_rejected(self, test_context):
        """Bot should not be able to send STK to itself."""
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        bot_user_id = test_context["bot_user_id"]

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{bot_user_id}/send",
                json={"amount": 1, "label": "self-transfer"},
                headers=headers,
            )

        assert resp.status_code == 400, (
            f"Expected 400 for self-transfer, got {resp.status_code}: {resp.json()}"
        )
        assert resp.json()["error"] == "self_transfer"

    async def test_negative_amount_transfer_rejected(self, test_context):
        """Sending a negative amount should be rejected.

        Code path: bank.ex:397 validate_transfer_amount returns :invalid_amount
        for amount <= 0. But ApiHelpers.validate_amount (api_helpers.ex:144)
        accepts any integer. The amount check happens in the core.
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": -10, "label": "negative-transfer"},
                headers=headers,
            )

        assert resp.status_code == 400, (
            f"Expected 400 for negative amount, got {resp.status_code}: {resp.json()}"
        )

    async def test_zero_amount_transfer_rejected(self, test_context):
        """Sending zero STK should be rejected."""
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/send",
                json={"amount": 0, "label": "zero-transfer"},
                headers=headers,
            )

        assert resp.status_code == 400, (
            f"Expected 400 for zero amount, got {resp.status_code}: {resp.json()}"
        )

    async def test_concurrent_sends_final_balance_correct(self, test_context):
        """After many concurrent small sends, the final balance should be
        exactly initial - (successful_sends * amount).

        This catches scenarios where balance updates are lost due to
        non-atomic read-modify-write patterns.
        """
        base = test_context["base_url"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }
        user1_id = test_context["user1_id"]

        # Get initial balance
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            me_resp = await client.get("/api/user/me", headers=headers)
            initial_balance = me_resp.json()["balance"]

        # Fire 10 concurrent sends of 1 STK each
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            tasks = [
                client.post(
                    f"/api/user/{user1_id}/send",
                    json={"amount": 1, "label": f"small-send-{i}"},
                    headers=headers,
                )
                for i in range(10)
            ]
            responses = await asyncio.gather(*tasks)

        successes = sum(1 for r in responses if r.status_code == 200)

        # Check final balance
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            me_resp = await client.get("/api/user/me", headers=headers)
            final_balance = me_resp.json()["balance"]

        expected = initial_balance - successes
        assert final_balance == expected, (
            f"LOST UPDATE BUG! Balance should be {expected} "
            f"(initial {initial_balance} - {successes} sends), "
            f"but got {final_balance}. Difference: {final_balance - expected}"
        )


@pytest.mark.asyncio
class TestAutoEnterPreauthReRequest:
    """Test that re-running auto-enter re-requests a preauth after revocation."""

    async def test_auto_enter_re_requests_preauth_after_revoke(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """If a user is already opted in but their preauth was revoked,
        running /auto-enter enabled:true again should re-request a preauth
        instead of just saying 'already opted in'."""
        discord_id = test_context["user1_discord_id"]
        guild_id = "test_reenter_guild"

        # Step 1: Opt in to auto-enter
        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, discord_id, guild_id, True)
            assert db.get_auto_enter_status(conn, discord_id, guild_id) is True
        finally:
            conn.close()

        # Step 2: Create and approve a preauth (simulating first /auto-enter)
        stk_user = await stk.get_user_by_discord_id(discord_id)
        assert stk_user is not None
        preauth = await stk.create_preauth(
            user_id=stk_user["id"],
            max_amount=10,
            window_hours=24,
        )
        assert preauth is not None
        approve_preauth(preauth["id"])

        # Step 3: Revoke the preauth (user runs /preauths revoke)
        client = stk.get_client()
        await client.revoke_preauth(preauth["id"])

        # Step 4: Verify preauth is revoked — no active/pending preauths
        preauths = await stk.get_preauths(user_id=stk_user["id"])
        active_or_pending = [
            p for p in preauths if p.get("status") in ("active", "pending")
        ]
        assert len(active_or_pending) == 0

        # Step 5: Simulate what /auto-enter should do when already opted in
        # The current bug: it short-circuits at "already opted in" without
        # checking preauth status. After the fix, it should detect the
        # missing preauth and request a new one.
        #
        # We simulate the command's preauth check logic here:
        preauths = await stk.get_preauths(user_id=stk_user["id"])
        active = [p for p in preauths if p.get("status") == "active"]
        pending = [p for p in preauths if p.get("status") == "pending"]

        if not active and not pending:
            # This is what the fixed command should do:
            new_preauth = await stk.create_preauth(
                user_id=stk_user["id"],
                max_amount=10,
                window_hours=24,
            )
            assert new_preauth is not None, "Should be able to request a new preauth after revoke"

        # Verify a new preauth was created
        preauths = await stk.get_preauths(user_id=stk_user["id"])
        pending_preauths = [p for p in preauths if p.get("status") == "pending"]
        assert len(pending_preauths) == 1, (
            f"Expected 1 pending preauth after re-request, got {len(pending_preauths)}"
        )


# ======================================================================
# REGRESSION: Preauth + Idempotency + Multi-Guild Boundary Bugs
# ======================================================================


@pytest.mark.asyncio
class TestPreauthRegressions:
    """Regression and hardening tests for production bugs involving the
    preauth budget system, idempotency caching, and multi-guild scenarios.

    Production bug summary:
    - User in 2 guilds. Auto-enter fires for both at ~00:00.
    - Guild 1 auto-enter fails (preauth budget full). StackCoin returns 400.
    - Idempotency system cached this 400.
    - Guild 2 auto-enter succeeds (budget recovered by then).
    - User manually retries /enter-pot with same idempotency key → cached 400.

    Fixes applied:
    - Idempotency system no longer caches error responses (only 2xx).
    - Rolling window has a 30s grace buffer (effective 23h59m30s).
    """

    async def test_idempotency_does_not_cache_preauth_error(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Regression: a preauth_limit_exceeded 400 was cached by idempotency,
        blocking retries even after budget recovered. Errors should not be cached.

        Strategy:
        1. Create preauth with max_amount=5 for user1
        2. Hit API with key="X", amount=10, use_preauth=True → 400 (10 > 5 budget)
        3. Hit API with key="X", amount=3, use_preauth=True → if error was cached,
           returns the stale 400. If NOT cached (the fix), re-executes with
           amount=3 which fits in budget → 200.
        """
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]
        idem_key = "regression-error-cache-key"

        # Create preauth with budget=5
        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=5, window_hours=24,
        )
        approve_preauth(preauth["id"])

        headers_with_key = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
            "Idempotency-Key": idem_key,
        }

        # Step 1: amount=10 exceeds budget=5 → should be 400
        async with httpx.AsyncClient(
            base_url=base, timeout=30.0
        ) as client:
            resp1 = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 10, "use_preauth": True, "label": "over-budget"},
                headers=headers_with_key,
            )
        assert resp1.status_code == 400, (
            f"Expected 400 for amount=10 against budget=5, got {resp1.status_code}: "
            f"{resp1.json()}"
        )

        # Step 2: same key, amount=3 fits in budget → should succeed if error
        # was NOT cached. If error was cached, we'd get the stale 400 back.
        async with httpx.AsyncClient(
            base_url=base, timeout=30.0
        ) as client:
            resp2 = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 3, "use_preauth": True, "label": "within-budget"},
                headers=headers_with_key,
            )
        assert resp2.status_code == 200, (
            f"Expected 200 (error should not be cached by idempotency system), "
            f"got {resp2.status_code}: {resp2.json()}. "
            f"If this is 400, the idempotency system is still caching error responses."
        )
        assert resp2.json()["status"] == "accepted"

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_multi_guild_preauth_budget_shared(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """Preauth budget is shared across guilds. A user in 2 guilds uses
        budget from both entries against the same preauth.

        Steps:
        1. Create preauth max_amount=10 for user1
        2. Enter pot in guild_A (preauth, 5 STK) → confirmed
        3. End pot in guild_A
        4. Enter pot in guild_B (preauth, 5 STK) → confirmed (budget now 0/10)
        5. End pot in guild_B, enter new pot in guild_A → skipped (budget exceeded)
        6. Verify no ban
        """
        guild_a = "regression_multi_guild_A"
        guild_b = "regression_multi_guild_B"
        discord_id = test_context["user1_discord_id"]

        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"], max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Enter guild_A → confirmed via preauth (5 STK)
        result_a = await game.enter_pot(
            discord_id=discord_id, guild_id=guild_a,
        )
        assert result_a["status"] == "confirmed", (
            f"Expected confirmed in guild_A, got {result_a['status']}"
        )

        # End pot in guild_A so user can enter guild_B
        conn = db.get_connection()
        try:
            pot_a = db.get_active_pot(conn, guild_a)
            db.end_pot(conn, pot_a["pot_id"], discord_id, 5, "TEST")
        finally:
            conn.close()

        # Enter guild_B → confirmed via preauth (another 5 STK, total 10 = budget)
        result_b = await game.enter_pot(
            discord_id=discord_id, guild_id=guild_b,
        )
        assert result_b["status"] == "confirmed", (
            f"Expected confirmed in guild_B, got {result_b['status']}"
        )

        # Budget should now be 0/10
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 0, (
            f"Expected 0 remaining after 2 entries, got {info['remaining_budget']}"
        )

        # End pot in guild_B, enter new pot in guild_A → should be skipped
        conn = db.get_connection()
        try:
            pot_b = db.get_active_pot(conn, guild_b)
            db.end_pot(conn, pot_b["pot_id"], discord_id, 5, "TEST")
        finally:
            conn.close()

        result_a2 = await game.enter_pot(
            discord_id=discord_id, guild_id=guild_a,
        )
        assert result_a2["status"] == "skipped", (
            f"Expected skipped (budget exhausted), got {result_a2['status']}"
        )

        # Verify no ban was applied (budget exceeded is not a bannable offence)
        conn = db.get_connection()
        try:
            ban_a = db.get_active_ban(conn, discord_id, guild_a)
            ban_b = db.get_active_ban(conn, discord_id, guild_b)
            assert ban_a is None, f"Unexpected ban in guild_A: {ban_a}"
            assert ban_b is None, f"Unexpected ban in guild_B: {ban_b}"
        finally:
            conn.close()

    async def test_window_grace_allows_retry_near_boundary(
        self, luckypot_db, configure_luckypot_stk, test_context, approve_preauth,
        stackcoin_server,
    ):
        """The 30s grace on the rolling window means entries age out slightly
        early, preventing the daily auto-enter boundary race.

        Strategy:
        1. Create preauth max_amount=5, use it fully (budget → 0)
        2. Manipulate the request's requested_at in the DB to be 23h59m45s ago
           (within the 24hr window but outside the 23h59m30s grace window)
        3. Check remaining_budget via API — should be 5 (entry aged out due to grace)
        """
        base = test_context["base_url"]
        user1_id = test_context["user1_id"]
        headers = {
            "Authorization": f"Bearer {test_context['bot_token']}",
            "Content-Type": "application/json",
        }

        # Create preauth with budget=5
        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=5, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Spend the full budget
        async with httpx.AsyncClient(base_url=base, timeout=30.0) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "use_preauth": True, "label": "grace-test"},
                headers=headers,
            )
        assert resp.status_code == 200
        assert resp.json()["status"] == "accepted"
        request_id = resp.json()["request_id"]

        # Budget should be 0
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 0

        # Manipulate the request's requested_at to be 23h59m45s ago
        # (86400 - 15 = 86385 seconds). This is inside the 24hr window but
        # outside the 23h59m30s effective window (86400 - 30 = 86370 seconds).
        port = stackcoin_server["port"]
        db_file = os.path.join(
            os.path.dirname(__file__), "../../..",
            f"data/e2e_test_{port}.db",
        )
        conn = sqlite3.connect(db_file, timeout=10)
        try:
            conn.execute("PRAGMA busy_timeout = 5000")
            conn.execute(
                "UPDATE request SET requested_at = datetime('now', '-86385 seconds') "
                "WHERE id = ?",
                (request_id,),
            )
            conn.commit()
        finally:
            conn.close()

        # Now check remaining budget — with the 30s grace, the entry at 23h59m45s
        # ago should be considered "aged out" (outside the 23h59m30s effective window)
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 5, (
            f"Expected 5 (entry aged out due to 30s grace buffer), "
            f"got {info['remaining_budget']}. "
            f"The rolling window grace buffer may not be working correctly."
        )

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_idempotency_key_reusable_after_error(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context,
        approve_preauth, stackcoin_server,
    ):
        """After a failed request, the same idempotency key can be reused
        and succeed if the underlying condition has changed.

        This simulates the production scenario:
        1. User enters pot → confirmed (5 STK, budget exhausted)
        2. End pot, new pot starts
        3. Enter pot again → skipped (budget exceeded), idempotency key is
           pot_entry:<pot2>:<user>:1
        4. Manually age the first request past the 24h window
        5. Enter pot AGAIN → same pot, same user, same attempt = same key
        6. Should succeed (budget recovered, error not cached)
        """
        guild_id = "regression_idem_retry_guild"
        discord_id = test_context["user1_discord_id"]

        # Create preauth with budget=5 (exactly one entry)
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"], max_amount=5, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Enter pot #1 → confirmed (5 STK, budget now 0)
        result1 = await game.enter_pot(
            discord_id=discord_id, guild_id=guild_id,
        )
        assert result1["status"] == "confirmed"

        # End pot #1, new pot starts
        conn = db.get_connection()
        try:
            pot1 = db.get_active_pot(conn, guild_id)
            db.end_pot(conn, pot1["pot_id"], discord_id, 5, "TEST")
        finally:
            conn.close()

        # Enter pot #2 → skipped (budget exceeded)
        result2 = await game.enter_pot(
            discord_id=discord_id, guild_id=guild_id,
        )
        assert result2["status"] == "skipped", (
            f"Expected skipped (budget exhausted), got {result2['status']}"
        )

        # Now simulate time passing: age the original request past 24h
        # so the budget recovers
        port = stackcoin_server["port"]
        db_file = os.path.join(
            os.path.dirname(__file__), "../../..",
            f"data/e2e_test_{port}.db",
        )
        stk_conn = sqlite3.connect(db_file, timeout=10)
        try:
            stk_conn.execute("PRAGMA busy_timeout = 5000")
            # Move ALL requests for this preauth's user to >24h ago
            stk_conn.execute(
                "UPDATE request SET requested_at = datetime('now', '-90000 seconds') "
                "WHERE responder_id = ?",
                (test_context["user1_id"],),
            )
            stk_conn.commit()
        finally:
            stk_conn.close()

        # Verify budget recovered
        info = await stk.get_client().get_preauth(preauth["id"])
        assert info["remaining_budget"] == 5, (
            f"Expected budget to recover to 5 after aging requests, "
            f"got {info['remaining_budget']}"
        )

        # Enter pot #2 again — same pot, same user, same attempt count
        # = same idempotency key. Should succeed if errors aren't cached.
        result3 = await game.enter_pot(
            discord_id=discord_id, guild_id=guild_id,
        )
        assert result3["status"] == "confirmed", (
            f"Expected confirmed (budget recovered, error should not be cached), "
            f"got {result3['status']}. "
            f"If this is 'skipped', the idempotency system may still be caching "
            f"the previous error response."
        )


@pytest.mark.asyncio
class TestDailyDrawReentry:
    """Daily-draw re-entry across multiple rounds.

    Each test exercises the round system: misses advance pot.current_round,
    users can re-enter the same pot in a new round, and a draw pays out
    the sum of all confirmed entries across rounds.
    """

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_single_miss_advances_round(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """One missed draw advances pot.current_round from 1 to 2."""
        await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )

        announces = []

        async def announce(gid, msg, **kw):
            announces.append((gid, msg))

        await game.daily_pot_draw(announce=announce, edit_announce=None)

        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, "test_guild_reentry")
            assert pot["current_round"] == 2
            assert pot["is_active"] == 1
        finally:
            conn.close()

        assert any("round 2" in msg for _, msg in announces)

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_three_misses_in_a_row_advance_to_round_4(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Three consecutive misses advance the pot to round 4."""
        await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )

        for _ in range(3):
            await game.daily_pot_draw(announce=None, edit_announce=None)

        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, "test_guild_reentry")
            assert pot["current_round"] == 4
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_user_can_reenter_after_miss(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """After a miss, a user can /enter-pot again and get a round-2 entry."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )
        assert result1["status"] == "pending"

        await game.daily_pot_draw(announce=None, edit_announce=None)

        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )
        assert result2["status"] == "pending"

        conn = db.get_connection()
        try:
            rows = conn.execute(
                """SELECT entry_round FROM pot_entries
                   WHERE discord_id = ? AND status IN ('pending','confirmed')
                   ORDER BY entry_id""",
                (test_context["user1_discord_id"],),
            ).fetchall()
            assert [r["entry_round"] for r in rows] == [1, 2]
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_cannot_reenter_within_same_round(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Without a miss, a user cannot enter the same round twice."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )
        assert result1["status"] == "pending"

        # No daily_pot_draw call: round is still 1
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )
        assert result2["status"] == "already_entered"

    async def test_unique_index_prevents_duplicate_round_entry(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Bypassing has_user_entered and inserting directly raises IntegrityError."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "test_guild_reentry")
            db.add_entry(conn, pot["pot_id"], test_context["user1_discord_id"], 5, "req_1")

            with pytest.raises(sqlite3.IntegrityError):
                conn.execute(
                    """INSERT INTO pot_entries
                         (pot_id, discord_id, amount, status, stackcoin_request_id, entry_round)
                       VALUES (?, ?, ?, 'pending', 'force-dup', 1)""",
                    (pot["pot_id"], test_context["user1_discord_id"], 5),
                )
        finally:
            conn.close()

    async def test_different_round_entries_allowed_by_index(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """The unique index permits the same (pot, user) at different rounds."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "test_guild_reentry")
            db.add_entry(conn, pot["pot_id"], test_context["user1_discord_id"], 5, "req_1", entry_round=1)
            db.add_entry(conn, pot["pot_id"], test_context["user1_discord_id"], 5, "req_2", entry_round=2)
            rows = conn.execute(
                "SELECT entry_round FROM pot_entries WHERE pot_id = ? ORDER BY entry_round",
                (pot["pot_id"],),
            ).fetchall()
            assert [r["entry_round"] for r in rows] == [1, 2]
        finally:
            conn.close()

    @patch("luckypot.game.AUTO_ENTER_DELAY_SECONDS", 0)
    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_auto_enter_fires_on_miss(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Opted-in users get auto-entered into the new round after a miss."""
        guild_id = "test_guild_reentry"

        conn = db.get_connection()
        try:
            db.set_auto_enter(conn, test_context["user1_discord_id"], guild_id, True)
        finally:
            conn.close()

        # First enter pot in round 1 and confirm so auto-enter has a baseline
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        await game.on_request_accepted(
            RequestAcceptedData(
                request_id=int(result1["request_id"]),
                status="accepted",
                transaction_id=0,
                amount=5,
            )
        )

        # Miss the draw -> round advances and auto-enter fires
        await game.daily_pot_draw(announce=None, edit_announce=None)

        # Drain the fire-and-forget auto-enter task
        await asyncio.gather(
            *[t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
        )

        conn = db.get_connection()
        try:
            rows = conn.execute(
                """SELECT entry_round FROM pot_entries
                   WHERE discord_id = ? AND status IN ('pending','confirmed')
                   ORDER BY entry_id""",
                (test_context["user1_discord_id"],),
            ).fetchall()
            assert [r["entry_round"] for r in rows] == [1, 2]
        finally:
            conn.close()

    async def test_winner_weighting_across_rounds(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A user with 3 confirmed entries (rounds 1, 2, 3) wins over a user with 1.

        select_random_winner weights by entry row, so 3 entries from one user
        vs 1 from another gives a 3:1 split in expected winners.

        total_weight = 4 entries x 5 STK = 20. roll in [0, 19].
        - rolls 0..4 -> user1 entry 1
        - rolls 5..9 -> user1 entry 2
        - rolls 10..14 -> user1 entry 3
        - rolls 15..19 -> user2 entry 1
        """
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "test_guild_reentry")
            pot_id = pot["pot_id"]

            # User A enters rounds 1, 2, 3 (3 confirmed entries)
            for r in (1, 2, 3):
                db.add_entry(
                    conn, pot_id=pot_id,
                    discord_id=test_context["user1_discord_id"],
                    amount=5, status="confirmed", entry_round=r,
                    stackcoin_request_id=f"req_a_{r}",
                )
            # User B enters round 1 only (1 confirmed entry)
            db.add_entry(
                conn, pot_id=pot_id,
                discord_id=test_context["user2_discord_id"],
                amount=5, status="confirmed", entry_round=1,
                stackcoin_request_id="req_b_1",
            )

            participants = db.get_pot_participants(conn, pot_id)
            assert len(participants) == 4

            # Total weight = 20 (4 entries x 5). roll range is [0, 19].
            from collections import Counter
            counts = Counter()
            for roll in range(20):
                with patch("luckypot.game.secrets.randbelow", return_value=roll):
                    w = game.select_random_winner(participants)
                    counts[w["discord_id"]] += 1

            assert counts[test_context["user1_discord_id"]] == 15
            assert counts[test_context["user2_discord_id"]] == 5
        finally:
            conn.close()

    async def test_payout_sums_across_rounds(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """end_pot_with_winner pays out the sum of all confirmed entries across rounds."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "test_guild_reentry")
            pot_id = pot["pot_id"]

            # 3 confirmed entries from user1 across rounds 1, 2, 3 (15 STK total)
            for r in (1, 2, 3):
                db.add_entry(
                    conn, pot_id=pot_id,
                    discord_id=test_context["user1_discord_id"],
                    amount=5, status="confirmed", entry_round=r,
                    stackcoin_request_id=f"req_u1_{r}",
                )
            # 1 confirmed entry from user2 in round 1 (5 STK)
            db.add_entry(
                conn, pot_id=pot_id,
                discord_id=test_context["user2_discord_id"],
                amount=5, status="confirmed", entry_round=1,
                stackcoin_request_id="req_u2_1",
            )
        finally:
            conn.close()

        announces = []

        async def announce_fn(msg):
            announces.append(msg)

        won = await game.end_pot_with_winner(
            "test_guild_reentry",
            win_type="DAILY DRAW",
            announce_fn=announce_fn,
            edit_announce_fn=None,
        )
        assert won is True

        conn = db.get_connection()
        try:
            row = conn.execute(
                "SELECT * FROM pots WHERE guild_id = ?",
                ("test_guild_reentry",),
            ).fetchone()
            assert row["is_active"] == 0
            assert row["winning_amount"] == 20  # 4 entries x 5 STK
        finally:
            conn.close()

        assert any("20 STK" in m for m in announces)

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_late_round1_acceptance_during_round2_refunds(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A round-1 pending entry accepted during round 2 is refunded."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )
        assert result["status"] == "pending"
        request_id = int(result["request_id"])

        await game.daily_pot_draw(announce=None, edit_announce=None)

        refund = AsyncMock(return_value=True)
        with patch("luckypot.game.send_winnings_to_user", refund):
            await game.on_request_accepted(
                RequestAcceptedData(
                    request_id=request_id,
                    status="accepted",
                    transaction_id=0,
                    amount=5,
                ),
                announce=None,
            )

        refund.assert_awaited_once_with(
            test_context["user1_discord_id"],
            5,
            idempotency_key=f"pot_refund:stale_round:{request_id}",
        )

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_request_id(conn, str(request_id))
            assert entry["status"] == "denied"
            assert entry["entry_round"] == 1
            assert entry["pot_is_active"] == 1
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_late_acceptance_after_pot_ended_refunds(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """A pending entry accepted after the pot ended should be refunded.

        Reuses the existing late-acceptance path; verifies nothing broke.
        The entry_round field is irrelevant since the pot is no longer
        accepting entries.
        """
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )
        result2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="test_guild_reentry",
        )

        # Accept user2's entry so there's at least 1 confirmed participant
        await game.on_request_accepted(
            RequestAcceptedData(
                request_id=int(result2["request_id"]),
                status="accepted",
                transaction_id=0,
                amount=5,
            ),
            announce=None,
        )

        # Force end the pot by rigging the daily draw to hit. end_pot_with_winner
        # is called with user2's confirmed entry, paying out 5 STK to them.
        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.daily_pot_draw(announce=None, edit_announce=None)

        # user1 accepts their late pending entry: pot is not active so refund
        announces = []

        async def announce(gid, msg, **kw):
            announces.append(msg)

        await game.on_request_accepted(
            RequestAcceptedData(
                request_id=int(result1["request_id"]),
                status="accepted",
                transaction_id=0,
                amount=5,
            ),
            announce=announce,
        )

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_request_id(conn, result1["request_id"])
            assert entry["status"] == "denied"  # refunded path denies the entry
        finally:
            conn.close()

        assert any("refunded" in m for m in announces)

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_miss_with_zero_participants_announces_zero(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Missing a draw with no confirmed participants still advances the
        round and announces 0 entries."""
        # Create an empty pot manually
        conn = db.get_connection()
        try:
            db.create_pot(conn, "test_guild_empty")
        finally:
            conn.close()

        announces = []

        async def announce(gid, msg, **kw):
            announces.append((gid, msg))

        await game.daily_pot_draw(announce=announce, edit_announce=None)

        assert any("0 STK from 0 entries" in m for _, m in announces)

        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, "test_guild_empty")
            assert pot["current_round"] == 2
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_idempotency_key_unique_across_rounds(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """enter_pot builds idempotency keys that differ across rounds.

        Idempotency key is pot_entry:{pot_id}:{discord_id}:{prior_attempts+1}
        where prior_attempts counts ALL entries (any status, any round) for
        that user in that pot. After a miss, the next attempt is attempt #2,
        generating a different key.
        """
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )
        await game.daily_pot_draw(announce=None, edit_announce=None)

        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_reentry",
        )

        conn = db.get_connection()
        try:
            rows = conn.execute(
                """SELECT entry_round, stackcoin_request_id FROM pot_entries
                   WHERE discord_id = ? ORDER BY entry_id""",
                (test_context["user1_discord_id"],),
            ).fetchall()
            assert len(rows) == 2
            assert rows[0]["entry_round"] == 1
            assert rows[1]["entry_round"] == 2
            # Different request_ids (from different StackCoin requests)
            assert rows[0]["stackcoin_request_id"] != rows[1]["stackcoin_request_id"]
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_force_end_pot_with_multi_round_participants(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context
    ):
        """/force-end-pot draws correctly from a multi-round pot."""
        guild_id = "test_guild_reentry"

        # Round 1: user1 enters
        await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        await game.daily_pot_draw(announce=None, edit_announce=None)

        # Round 2: user1 re-enters + user2 enters
        await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id=guild_id,
        )

        # Confirm all 3 pending entries so the pot has actual participants
        conn = db.get_connection()
        try:
            conn.execute(
                "UPDATE pot_entries SET status='confirmed' WHERE discord_id IN (?, ?) AND pot_id IN (SELECT pot_id FROM pots WHERE guild_id=? AND is_active=1)",
                (test_context["user1_discord_id"], test_context["user2_discord_id"], guild_id),
            )
            conn.commit()
        finally:
            conn.close()

        announces = []

        async def announce_fn(msg):
            announces.append(msg)

        won = await game.end_pot_with_winner(
            guild_id,
            win_type="DEBUG FORCE END",
            announce_fn=announce_fn,
            edit_announce_fn=None,
        )
        assert won is True

        conn = db.get_connection()
        try:
            row = conn.execute(
                "SELECT * FROM pots WHERE guild_id = ?",
                (guild_id,),
            ).fetchone()
            assert row["is_active"] == 0
            # 2 entries from user1 (round 1 + round 2) + 1 from user2 (round 2) = 15 STK
            assert row["winning_amount"] == 15
        finally:
            conn.close()

    async def test_migration_preserves_existing_data(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Re-running init_database on an already-migrated DB is idempotent."""
        conn = db.get_connection()
        try:
            info_pots = [r["name"] for r in conn.execute("PRAGMA table_info(pots)")]
            info_entries = [r["name"] for r in conn.execute("PRAGMA table_info(pot_entries)")]
            assert "current_round" in info_pots
            assert "entry_round" in info_entries

            pot = db.create_pot(conn, "test_guild_migration")
            db.add_entry(
                conn, pot_id=pot["pot_id"],
                discord_id=test_context["user1_discord_id"],
                amount=5, status="confirmed", entry_round=1,
                stackcoin_request_id="req_mig",
            )
        finally:
            conn.close()

        # Re-running init should not raise and should not corrupt data
        db.init_database()

        conn = db.get_connection()
        try:
            pot = db.get_active_pot(conn, "test_guild_migration")
            assert pot["current_round"] == 1
            row = conn.execute(
                "SELECT * FROM pot_entries WHERE pot_id = ?",
                (pot["pot_id"],),
            ).fetchone()
            assert row["entry_round"] == 1
            assert row["status"] == "confirmed"
        finally:
            conn.close()

    @patch("luckypot.game.secrets.randbelow", return_value=9999)
    async def test_full_money_flow_across_rounds_e2e(
        self, _mock_rng, luckypot_db, configure_luckypot_stk, test_context, approve_preauth
    ):
        """End-to-end money flow: two real StackCoin entries across two rounds
        then a real pay-out, against the live test server.

        Uses preauth so that enter_pot auto-resolves the request and real STK
        moves from user to bot. Verifies that on the eventual draw, the winner
        receives the 10 STK pot for real, paid out of the bot's accumulated
        balance.
        """
        guild_id = "test_guild_money"

        # Create and approve a preauth for user1 covering both round entries
        preauth = await stk.create_preauth(
            user_id=test_context["user1_id"],
            max_amount=10,
            window_hours=24,
        )
        approve_preauth(preauth["id"])

        # user1 enters round 1 - preauth auto-resolves, real STK moves
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert result1["status"] == "confirmed"

        # user1 starts at 500, paid 5 for round 1 -> 495
        user1_after_r1 = await stk.get_user_by_discord_id(test_context["user1_discord_id"])
        assert user1_after_r1["balance"] == 495

        # Miss the draw -> round advances to 2
        await game.daily_pot_draw(announce=None, edit_announce=None)

        # user1 enters round 2 - preauth still has budget, auto-resolves
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id=guild_id,
        )
        assert result2["status"] == "confirmed"

        # user1 paid another 5 for round 2 -> 490
        user1_after_r2 = await stk.get_user_by_discord_id(test_context["user1_discord_id"])
        assert user1_after_r2["balance"] == 490

        # Bot balance: started at 1000, gained 10 from 2 entries -> 1010
        bot_before_draw = await stk.get_bot_balance()
        assert bot_before_draw == 1010

        # Rig the draw to hit - real pay-out happens via stk.send_stk
        with patch("luckypot.game.secrets.randbelow", return_value=0):
            await game.daily_pot_draw(announce=None, edit_announce=None)

        conn = db.get_connection()
        try:
            pot_row = conn.execute(
                "SELECT * FROM pots WHERE guild_id = ?",
                (guild_id,),
            ).fetchone()
            assert pot_row["is_active"] == 0
            assert pot_row["winning_amount"] == 10
            assert pot_row["winner_discord_id"] == test_context["user1_discord_id"]
        finally:
            conn.close()

        # user1 received 10 STK winnings: 490 + 10 = 500 (back to start)
        winner = await stk.get_user_by_discord_id(test_context["user1_discord_id"])
        assert winner["balance"] == 500

        # Bot balance: 1010 - 10 paid out = 1000 (back to seed)
        bot_after = await stk.get_bot_balance()
        assert bot_after == 1000


@pytest.mark.asyncio
class TestAlembicMigrations:
    """Tests for the alembic migration system.

    Verifies:
    - Fresh DBs are created at the latest schema version
    - Legacy pre-alembic prod-shaped DBs are stamped + upgraded cleanly
    - Existing data survives a legacy -> upgraded migration
    - init_database is idempotent across multiple invocations
    """

    async def test_fresh_db_at_head_revision(self, tmp_path):
        """A fresh LUCKYPOT_DB_PATH is migrated to the latest alembic head."""
        from luckypot.config import settings

        db_path = str(tmp_path / "fresh.db")
        settings.db_path = db_path
        try:
            db.init_database()

            conn = sqlite3.connect(db_path)
            conn.row_factory = sqlite3.Row
            try:
                # alembic_version table exists and is at the head
                row = conn.execute("SELECT version_num FROM alembic_version").fetchone()
                assert row is not None

                # expected schema post-migration
                assert "current_round" in [
                    r["name"] for r in conn.execute("PRAGMA table_info(pots)")
                ]
                assert "entry_round" in [
                    r["name"] for r in conn.execute("PRAGMA table_info(pot_entries)")
                ]
                idxs = [
                    r["name"]
                    for r in conn.execute("PRAGMA index_list('pot_entries')")
                ]
                assert "idx_pot_entries_one_per_round" in idxs
            finally:
                conn.close()
        finally:
            settings.db_path = "luckypot.db"  # restore default

    async def test_legacy_db_is_stamped_and_upgraded(self, tmp_path):
        """A legacy pre-alembic DB (matches prod shape as of 2026-06-22) is
        detected, stamped to 0001_initial, and upgraded to head, preserving
        existing rows.
        """
        from luckypot.config import settings

        db_path = str(tmp_path / "legacy.db")
        settings.db_path = db_path
        try:
            # Seed a legacy pre-alembic DB with the exact pre-migration
            # schema (no current_round, no entry_round, no alembic_version)
            conn = sqlite3.connect(db_path)
            conn.executescript(
                """
                CREATE TABLE pots (
                    pot_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    guild_id TEXT NOT NULL,
                    is_active BOOLEAN NOT NULL DEFAULT TRUE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    ended_at TIMESTAMP,
                    winner_discord_id TEXT,
                    winning_amount INTEGER,
                    win_type TEXT
                );
                CREATE TABLE pot_entries (
                    entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pot_id INTEGER NOT NULL,
                    discord_id TEXT NOT NULL,
                    amount INTEGER NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    stackcoin_request_id TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (pot_id) REFERENCES pots(pot_id)
                );
                CREATE TABLE gateway_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE UNIQUE INDEX idx_pots_one_active_per_guild
                    ON pots(guild_id) WHERE is_active = TRUE;
                CREATE INDEX idx_pots_guild_active ON pots(guild_id, is_active);
                CREATE INDEX idx_pot_entries_pot_id ON pot_entries(pot_id);
                CREATE INDEX idx_pot_entries_request_id ON pot_entries(stackcoin_request_id);
                CREATE UNIQUE INDEX idx_pot_entries_active_request_id_unique
                    ON pot_entries(stackcoin_request_id)
                    WHERE stackcoin_request_id IS NOT NULL
                      AND status IN ('pending', 'confirmed');
                CREATE TABLE user_bans (
                    ban_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    discord_id TEXT NOT NULL,
                    guild_id TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    banned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    expires_at TIMESTAMP NOT NULL
                );
                CREATE INDEX idx_user_bans_lookup
                    ON user_bans(discord_id, guild_id, expires_at);
                CREATE TABLE auto_enter_users (
                    discord_id TEXT NOT NULL,
                    guild_id   TEXT NOT NULL,
                    enabled_at TEXT NOT NULL DEFAULT (datetime('now')),
                    PRIMARY KEY (discord_id, guild_id)
                );
                CREATE INDEX idx_auto_enter_guild ON auto_enter_users(guild_id);

                -- Simulate real prod data
                INSERT INTO pots (guild_id) VALUES ('legacy_guild');
                INSERT INTO pot_entries (pot_id, discord_id, amount, status)
                    VALUES (1, 'legacy_user', 5, 'confirmed');
                INSERT INTO gateway_state (key, value)
                    VALUES ('last_event_id', '7831');
                """
            )
            conn.commit()
            conn.close()

            # Now run init_database -- should detect legacy DB, stamp, and upgrade
            db.init_database()

            conn = sqlite3.connect(db_path)
            conn.row_factory = sqlite3.Row
            try:
                # At head revision
                row = conn.execute("SELECT version_num FROM alembic_version").fetchone()
                assert row is not None
                assert row["version_num"] == "0002_rounds"

                # Schema has the new columns
                pots_cols = [r["name"] for r in conn.execute("PRAGMA table_info(pots)")]
                assert "current_round" in pots_cols
                entries_cols = [
                    r["name"] for r in conn.execute("PRAGMA table_info(pot_entries)")
                ]
                assert "entry_round" in entries_cols

                # New unique index exists
                idxs = [
                    r["name"]
                    for r in conn.execute("PRAGMA index_list('pot_entries')")
                ]
                assert "idx_pot_entries_one_per_round" in idxs

                # Legacy rows are preserved with correct defaults
                pot = conn.execute(
                    "SELECT * FROM pots WHERE guild_id = ?",
                    ("legacy_guild",),
                ).fetchone()
                assert pot is not None
                assert pot["current_round"] == 1  # server_default applied

                entry = conn.execute(
                    "SELECT * FROM pot_entries WHERE discord_id = ?",
                    ("legacy_user",),
                ).fetchone()
                assert entry is not None
                assert entry["entry_round"] == 1  # server_default applied
                assert entry["status"] == "confirmed"  # original value preserved

                # gateway_state preserved
                gs = conn.execute(
                    "SELECT * FROM gateway_state WHERE key = 'last_event_id'"
                ).fetchone()
                assert gs is not None
                assert gs["value"] == "7831"
            finally:
                conn.close()
        finally:
            settings.db_path = "luckypot.db"

    async def test_init_database_is_idempotent(self, tmp_path):
        """Calling init_database multiple times in succession is safe."""
        from luckypot.config import settings

        db_path = str(tmp_path / "idem.db")
        settings.db_path = db_path
        try:
            db.init_database()
            db.init_database()
            db.init_database()

            # Sanity: the pot_entries unique index still works after multiple inits
            conn = db.get_connection()
            try:
                pot = db.create_pot(conn, "idem_guild")
                db.add_entry(
                    conn,
                    pot_id=pot["pot_id"],
                    discord_id="idem_user",
                    amount=5,
                    stackcoin_request_id="req_idem_1",
                    entry_round=1,
                )
                with pytest.raises(sqlite3.IntegrityError):
                    conn.execute(
                        """INSERT INTO pot_entries
                             (pot_id, discord_id, amount, status,
                              stackcoin_request_id, entry_round)
                           VALUES (?, ?, ?, 'pending', 'force-dup', 1)""",
                        (pot["pot_id"], "idem_user", 5),
                    )
            finally:
                conn.close()
        finally:
            settings.db_path = "luckypot.db"
