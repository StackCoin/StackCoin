"""
E2E tests for LuckyPot game logic against a real StackCoin server.

These tests import the REAL luckypot package and exercise its game logic,
db module, and stk module against the live StackCoin test server.
"""
import pytest

from luckypot import db, game, stk


@pytest.mark.asyncio
class TestLuckyPotEntryFlow:

    async def test_enter_pot_unregistered_user(self, luckypot_db, configure_luckypot_stk):
        """Unregistered Discord user should get an error."""
        result = await game.enter_pot(
            discord_id="999999999",
            guild_id="test_guild_1",
        )
        assert result["status"] == "error"

    async def test_enter_pot_success(self, luckypot_db, configure_luckypot_stk, test_context):
        """Registered user enters the pot -- creates a payment request on StackCoin."""
        result = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        assert result["status"] in ("pending", "instant_win")
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

    async def test_enter_pot_duplicate_blocked(self, luckypot_db, configure_luckypot_stk, test_context):
        """Second entry attempt for same user in same pot should be rejected."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        assert result1["status"] in ("pending", "instant_win")

        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        assert result2["status"] == "already_entered"

    async def test_multiple_users_enter_same_pot(self, luckypot_db, configure_luckypot_stk, test_context):
        """Multiple users can enter the same pot."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="test_guild_1",
        )
        result2 = await game.enter_pot(
            discord_id=test_context["user2_discord_id"],
            guild_id="test_guild_1",
        )
        assert result1["status"] in ("pending", "instant_win")
        assert result2["status"] in ("pending", "instant_win")

    async def test_separate_guilds_separate_pots(self, luckypot_db, configure_luckypot_stk, test_context):
        """Same user can enter pots in different guilds."""
        result1 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_A",
        )
        result2 = await game.enter_pot(
            discord_id=test_context["user1_discord_id"],
            guild_id="guild_B",
        )
        assert result1["status"] in ("pending", "instant_win")
        assert result2["status"] in ("pending", "instant_win")


@pytest.mark.asyncio
class TestLuckyPotPayout:

    async def test_send_winnings_success(self, configure_luckypot_stk, test_context):
        """Bot can send winnings to a user."""
        # Look up the user's STK ID
        stk_user = await stk.get_user_by_discord_id(test_context["user1_discord_id"])
        assert stk_user is not None

        success = await game.send_winnings_to_user(
            test_context["user1_discord_id"], 10,
        )
        assert success is True

    async def test_send_winnings_insufficient_balance(self, configure_luckypot_stk, test_context):
        """Payout fails gracefully when bot balance is too low."""
        success = await game.send_winnings_to_user(
            test_context["user1_discord_id"], 999999,
        )
        assert success is False


@pytest.mark.asyncio
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

    def test_instant_win_included_in_status(self, luckypot_db):
        """Instant-win entries should be counted in pot status."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            e1 = db.add_entry(conn, pot["pot_id"], "user1", 5, "req_1")
            db.mark_entry_instant_win(conn, e1)

            status = db.get_pot_status(conn, "guild1")
            assert status["participants"] == 1
            assert status["total_amount"] == 5
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


@pytest.mark.asyncio
class TestLuckyPotEventHandlers:
    """Test the event handlers that will be wired to the WebSocket gateway."""

    async def test_on_request_accepted_confirms_entry(self, luckypot_db, configure_luckypot_stk):
        """Simulating a request.accepted event should confirm a pending entry."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            entry_id = db.add_entry(conn, pot["pot_id"], "user1", 5, "12345")
        finally:
            conn.close()

        event = {"request_id": "12345"}
        await game.on_request_accepted(event)

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "confirmed"
        finally:
            conn.close()

    async def test_on_request_denied_denies_entry(self, luckypot_db, configure_luckypot_stk):
        """Simulating a request.denied event should deny a pending entry."""
        conn = db.get_connection()
        try:
            pot = db.create_pot(conn, "guild1")
            entry_id = db.add_entry(conn, pot["pot_id"], "user1", 5, "99999")
        finally:
            conn.close()

        event = {"request_id": "99999"}
        await game.on_request_denied(event)

        conn = db.get_connection()
        try:
            entry = db.get_entry_by_id(conn, entry_id)
            assert entry["status"] == "denied"
        finally:
            conn.close()
