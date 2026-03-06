"""
E2E test fixtures that start a real StackCoin server and configure test bots.

Each test gets a freshly seeded database — the server stays running but all
tables are truncated and re-seeded before every test.

Setup instructions:
  cd test/e2e
  uv venv
  source .venv/bin/activate
  uv pip install -e "../../tmp/stackcoin-python"
  uv pip install -e "../../tmp/LuckyPot"
  uv pip install -e .
  pytest
"""
import os
import signal
import sqlite3
import subprocess
import time

import httpx
import pytest


STACKCOIN_ROOT = os.path.join(os.path.dirname(__file__), "../..")

# All tables in dependency-safe deletion order (children before parents).
_ALL_TABLES = [
    "events",
    "idempotency_keys",
    "request",
    "pump",
    "transaction",
    "bot_user",
    "discord_guild",
    "discord_user",
    "internal_user",
    "user",
]

SEED_SCRIPT = """
# Re-create the reserve user exactly as the migration does (user + internal_user).
StackCoin.Repo.query!("INSERT INTO user (id, inserted_at, updated_at, username, balance, last_given_dole, admin, banned) VALUES (1, datetime('now'), datetime('now'), 'StackCoin Reserve System', 0, null, 0, 0)")
StackCoin.Repo.query!("INSERT INTO internal_user (id, identifier) VALUES (1, 'StackCoin Reserve System')")

{:ok, owner} = StackCoin.Core.User.create_user_account("100", "E2EOwner", balance: 0)
{:ok, bot} = StackCoin.Core.Bot.create_bot_user("100", "E2ETestBot")
{:ok, _pump} = StackCoin.Core.Reserve.pump_reserve(owner.id, 5000, "E2E funding")
{:ok, _txn} = StackCoin.Core.Bank.transfer_between_users(1, bot.user.id, 1000, "E2E bot funding")
{:ok, user1} = StackCoin.Core.User.create_user_account("200", "TestUser1", balance: 0)
{:ok, _txn} = StackCoin.Core.Bank.transfer_between_users(1, user1.id, 500, "User1 funding")
{:ok, user2} = StackCoin.Core.User.create_user_account("300", "TestUser2", balance: 0)
{:ok, _txn} = StackCoin.Core.Bank.transfer_between_users(1, user2.id, 500, "User2 funding")
IO.puts("BOT_TOKEN:" <> bot.token)
IO.puts("BOT_USER_ID:" <> Integer.to_string(bot.user.id))
IO.puts("USER1_ID:" <> Integer.to_string(user1.id))
IO.puts("USER1_DISCORD_ID:200")
IO.puts("USER2_ID:" <> Integer.to_string(user2.id))
IO.puts("USER2_DISCORD_ID:300")
"""


def _db_path(port: int) -> str:
    return os.path.join(STACKCOIN_ROOT, f"data/e2e_test_{port}.db")


def _truncate_all_tables(db_file: str):
    """Delete all rows from all tables and reset autoincrement counters."""
    conn = sqlite3.connect(db_file, timeout=10)
    try:
        conn.execute("PRAGMA busy_timeout = 5000")
        conn.execute("PRAGMA foreign_keys = OFF")
        for table in _ALL_TABLES:
            conn.execute(f'DELETE FROM "{table}"')
        # Reset autoincrement counters so IDs are deterministic across runs.
        conn.execute("DELETE FROM sqlite_sequence")
        conn.execute("PRAGMA foreign_keys = ON")
        conn.commit()
    finally:
        conn.close()


def _run_seed(port: int) -> dict:
    """Run the Elixir seed script and parse the output into a dict."""
    result = subprocess.run(
        ["mix", "run", "-e", SEED_SCRIPT],
        env={
            **os.environ,
            "MIX_ENV": "test",
            "PHX_SERVER": "true",  # Use regular pool, not Sandbox
            "STACKCOIN_DATABASE": f"./data/e2e_test_{port}.db",
        },
        cwd=STACKCOIN_ROOT,
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Seed script failed: {result.stderr}")

    values = {}
    for line in result.stdout.strip().split("\n"):
        if ":" in line:
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip()
            if key in ("BOT_TOKEN", "BOT_USER_ID", "USER1_ID",
                       "USER1_DISCORD_ID", "USER2_ID", "USER2_DISCORD_ID"):
                values[key] = val

    required = ["BOT_TOKEN", "BOT_USER_ID", "USER1_ID", "USER2_ID"]
    for k in required:
        if k not in values:
            raise RuntimeError(f"Seed script did not output {k}. Got: {values}")
    return values


# ---------------------------------------------------------------------------
# Session-scoped: server lifecycle
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def stackcoin_server():
    """Start a real StackCoin Phoenix server in test mode on port 4042."""
    port = 4042
    env = {
        **os.environ,
        "MIX_ENV": "test",
        "STACKCOIN_DATABASE": f"./data/e2e_test_{port}.db",
        "PORT": str(port),
        "SECRET_KEY_BASE": "test_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix_to_accept_it_OK",
        "PHX_SERVER": "true",
    }

    # Create a fresh database with schema
    subprocess.run(
        ["mix", "ecto.drop", "--quiet"],
        env=env, cwd=STACKCOIN_ROOT,
        capture_output=True, timeout=30,
    )
    result = subprocess.run(
        ["mix", "ecto.create", "--quiet"],
        env=env, cwd=STACKCOIN_ROOT,
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ecto.create failed: {result.stderr}")
    result = subprocess.run(
        ["mix", "ecto.migrate", "--quiet"],
        env=env, cwd=STACKCOIN_ROOT,
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ecto.migrate failed: {result.stderr}")

    # Start the server
    proc = subprocess.Popen(
        ["mix", "phx.server"],
        env=env, cwd=STACKCOIN_ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        preexec_fn=os.setsid,
    )

    base_url = f"http://localhost:{port}"

    # Wait for server to be ready
    for _ in range(30):
        try:
            resp = httpx.get(f"{base_url}/api/openapi", timeout=2)
            if resp.status_code == 200:
                break
        except (httpx.ConnectError, httpx.ReadTimeout):
            time.sleep(1)
    else:
        proc.terminate()
        raise RuntimeError("StackCoin server failed to start within 30 seconds")

    yield {"base_url": base_url, "port": port, "process": proc}

    # Cleanup
    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    finally:
        if proc.stdout:
            proc.stdout.close()
        if proc.stderr:
            proc.stderr.close()


# ---------------------------------------------------------------------------
# Per-test: fresh database state
# ---------------------------------------------------------------------------


@pytest.fixture
def seed_data(stackcoin_server):
    """Truncate all tables and re-seed the database. Returns fresh IDs/tokens.

    This runs before every test that (directly or transitively) depends on it,
    giving each test a completely clean StackCoin database.
    """
    port = stackcoin_server["port"]
    _truncate_all_tables(_db_path(port))
    return _run_seed(port)


@pytest.fixture
def test_context(stackcoin_server, seed_data):
    """Full test context with all IDs, URLs, and Discord snowflakes."""
    return {
        "base_url": stackcoin_server["base_url"],
        "bot_token": seed_data["BOT_TOKEN"],
        "bot_user_id": int(seed_data["BOT_USER_ID"]),
        "user1_id": int(seed_data["USER1_ID"]),
        "user1_discord_id": seed_data.get("USER1_DISCORD_ID", "200"),
        "user2_id": int(seed_data["USER2_ID"]),
        "user2_discord_id": seed_data.get("USER2_DISCORD_ID", "300"),
    }


@pytest.fixture
def auth_headers(seed_data):
    """Authorization headers for the bot."""
    return {
        "Authorization": f"Bearer {seed_data['BOT_TOKEN']}",
        "Content-Type": "application/json",
    }


# ---------------------------------------------------------------------------
# LuckyPot fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def luckypot_db(tmp_path):
    """Provide a fresh LuckyPot SQLite database for each test.

    Patches settings.db_path to use a temp file so tests are isolated.
    """
    from luckypot.config import settings
    import luckypot.db as lp_db

    db_path = str(tmp_path / "test_lucky_pot.db")
    original_path = settings.db_path
    settings.db_path = db_path
    lp_db.init_database()

    yield db_path

    settings.db_path = original_path


@pytest.fixture
def configure_luckypot_stk(stackcoin_server, seed_data):
    """Configure luckypot.stk to point at the test StackCoin server."""
    from luckypot.config import settings
    import luckypot.stk as lp_stk

    original_url = settings.stackcoin_api_url
    original_token = settings.stackcoin_api_token

    settings.stackcoin_api_url = stackcoin_server["base_url"]
    settings.stackcoin_api_token = seed_data["BOT_TOKEN"]
    lp_stk.reset_client()  # force new client with updated settings

    yield

    settings.stackcoin_api_url = original_url
    settings.stackcoin_api_token = original_token
    lp_stk.reset_client()  # reset for next test
