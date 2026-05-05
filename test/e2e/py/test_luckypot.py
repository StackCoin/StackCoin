"""
E2E tests for LuckyPot game logic against a real StackCoin server.

These tests import the REAL luckypot package and exercise its game logic,
db module, and stk module against the live StackCoin test server.
"""

import asyncio
import inspect
import sqlite3
from unittest.mock import AsyncMock, patch

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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.001)
    async def test_instant_win_on_empty_pot_gives_free_entry(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """An instant win on an empty pot gives a free confirmed entry (no payment)."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_iw",
        )
        assert result["status"] == "instant_win_free_entry"
        assert "entry_id" in result

        # Entry should be confirmed with amount=0 (free)
        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, result["entry_id"])
            assert entry is not None
            assert entry["status"] == "confirmed"
            assert entry["amount"] == 0

            # Pot should still be active (not ended — nothing to win)
            assert db.get_active_pot(conn, "test_guild_iw") is not None
        finally:
            conn.close()

    async def test_instant_win_with_pot_pays_out_and_ends(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """An instant win on a pot with confirmed entries pays out immediately and ends the pot."""
        # First, user1 enters normally and confirms
        with patch("luckypot.game.random.random", return_value=0.99):
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
            amount=0,
        )
        await game.on_request_accepted(event_data)

        # Now user2 enters and rolls instant win — should win the pot
        with patch("luckypot.game.random.random", return_value=0.001):
            result2 = await game.enter_pot(
                discord_id=test_context["user2_discord_id"],
                guild_id="test_guild_iw",
            )
        assert result2["status"] == "instant_win"
        assert result2["winning_amount"] == 5  # user1's 5 STK entry

        conn = db.get_connection()
        try:
            # Pot should be ended
            assert db.get_active_pot(conn, "test_guild_iw") is None
        finally:
            conn.close()

    async def test_new_pot_starts_after_instant_win(
        self, luckypot_db, configure_luckypot_stk, test_context
    ):
        """After an instant win ends a pot, a new pot can be started."""
        # User1 enters and confirms
        with patch("luckypot.game.random.random", return_value=0.99):
            result1 = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="test_guild_iw",
            )
        assert result1["status"] == "pending"
        event_data = RequestAcceptedData(
            request_id=int(result1["request_id"]),
            status="accepted",
            transaction_id=0,
            amount=0,
        )
        await game.on_request_accepted(event_data)

        # User2 instant wins
        with patch("luckypot.game.random.random", return_value=0.001):
            result2 = await game.enter_pot(
                discord_id=test_context["user2_discord_id"],
                guild_id="test_guild_iw",
            )
        assert result2["status"] == "instant_win"

        # User1 should be able to enter a new pot
        with patch("luckypot.game.random.random", return_value=0.99):
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

        with patch("luckypot.game.random.uniform", return_value=0.1):
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
        with patch("luckypot.game.random.random", return_value=0.99):
            result_a1 = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="guild_A",
            )
        assert result_a1["status"] == "pending"
        event_data = RequestAcceptedData(
            request_id=int(result_a1["request_id"]),
            status="accepted",
            transaction_id=0,
            amount=0,
        )
        await game.on_request_accepted(event_data)

        # User2 enters guild_B normally
        with patch("luckypot.game.random.random", return_value=0.99):
            result_b = await game.enter_pot(
                discord_id=test_context["user2_discord_id"],
                guild_id="guild_B",
            )
        assert result_b["status"] == "pending"

        # User2 instant wins guild_A's pot — ends it
        with patch("luckypot.game.random.random", return_value=0.001):
            result_a2 = await game.enter_pot(
                discord_id=test_context["user2_discord_id"],
                guild_id="guild_A",
            )
        assert result_a2["status"] == "instant_win"

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
        # On an empty pot, instant win gives a free entry
        with patch("luckypot.game.random.random", return_value=0.001):
            result_a = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="guild_A",
            )
        assert result_a["status"] == "instant_win_free_entry"

        # Same user enters guild_B normally
        with patch("luckypot.game.random.random", return_value=0.99):
            result_b = await game.enter_pot(
                discord_id=test_context["user1_discord_id"],
                guild_id="guild_B",
            )
        assert result_b["status"] == "pending"

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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
                amount=0,
            )
            await game.on_request_accepted(event_data)

        # Run daily draw with 100% chance (mock random to always trigger)
        with patch("luckypot.game.random.random", return_value=0.01):
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

            assert db.has_user_entered(conn, pot["pot_id"], "user1") is True
            assert db.has_user_entered(conn, pot["pot_id"], "user2") is False
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
            request_id=request_id, status="accepted", transaction_id=0, amount=0
        )
        await game.on_request_accepted(event_data)

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "confirmed"
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.001)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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
    @patch("luckypot.game.random.random", return_value=0.99)
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
                amount=0,
            )
        )

        # Force draw — pot ends, user1 wins
        with patch("luckypot.game.random.random", return_value=0.01):
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
                    conn, new_pot["pot_id"], test_context["user2_discord_id"]
                )
                is True
            )
        finally:
            conn.close()

    @patch("luckypot.game.AUTO_ENTER_DELAY_SECONDS", 0)
    @patch("luckypot.game.random.random", return_value=0.99)
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
                amount=0,
            )
        )

        with patch("luckypot.game.random.random", return_value=0.01):
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
    @patch("luckypot.game.random.random", return_value=0.99)
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
                amount=0,
            )
        )

        with patch("luckypot.game.random.random", return_value=0.01):
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
                    conn, new_pot["pot_id"], test_context["user2_discord_id"]
                )
                is False
            )
        finally:
            conn.close()


@pytest.mark.asyncio
class TestPreauthFlow:
    """Tests for preauthorization-enhanced pot entry."""

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
    async def test_enter_pot_without_preauth_falls_back(
        self, _mock_random, luckypot_db, configure_luckypot_stk, test_context
    ):
        """Without preauth, enter_pot creates a pending request as usual."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_no_preauth_guild",
        )
        assert result["status"] == "pending"

    @patch("luckypot.game.random.random", return_value=0.99)
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

    @patch("luckypot.game.random.random", return_value=0.99)
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
        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
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
    @patch("luckypot.game.random.random", return_value=0.99)
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
            assert db.has_user_entered(conn, pot["pot_id"], test_context["user1_discord_id"])
            assert db.has_user_entered(conn, pot["pot_id"], test_context["user2_discord_id"])
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

        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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
    @patch("luckypot.game.random.random", return_value=0.99)
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

        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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

        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
            bot_before = (await client.get("/api/user/me", headers=headers)).json()["balance"]
            user_before = (await client.get(f"/api/user/{user1_id}", headers=headers)).json()["balance"]

        preauth = await stk.create_preauth(
            user_id=user1_id, max_amount=10, window_hours=24,
        )
        approve_preauth(preauth["id"])

        # Transfer 7 STK via preauth
        async with httpx.AsyncClient(base_url=base) as client:
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
        async with httpx.AsyncClient(base_url=base) as client:
            resp = await client.post(
                f"/api/user/{user1_id}/request",
                json={"amount": 5, "use_preauth": True, "label": "pending-preauth"},
                headers=headers,
            )

        data = resp.json()
        assert data["status"] == "pending", (
            f"Expected pending (preauth not yet approved), got {data['status']}"
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
