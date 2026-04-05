"""
E2E tests for LuckyPot game logic against a real StackCoin server.

These tests import the REAL luckypot package and exercise its game logic,
db module, and stk module against the live StackCoin test server.
"""

import asyncio
from unittest.mock import patch

import pytest
from stackcoin import RequestAcceptedData, RequestDeniedData

from luckypot import db, game, stk


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

        event_data = RequestDeniedData(request_id=request_id, status="denied")
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
