"""
E2E test fixtures that start a real StackCoin server and configure test bots.

Setup instructions:
  cd test/e2e
  uv venv
  source .venv/bin/activate
  uv pip install -e "../../tmp/stackcoin-python/stackcoin"
  uv pip install -e "../../tmp/LuckyPot"
  uv pip install -e .
  pytest
"""
import os
import signal
import subprocess
import time
import tempfile

import httpx
import pytest


STACKCOIN_ROOT = os.path.join(os.path.dirname(__file__), "../..")


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

    # Reset the test database
    subprocess.run(
        ["mix", "ecto.reset"],
        env=env, cwd=STACKCOIN_ROOT,
        capture_output=True, timeout=30,
    )

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


@pytest.fixture(scope="session")
def seed_data(stackcoin_server):
    """Seed the test database with users, a bot, and funded balances.

    Returns a dict of IDs and tokens parsed from the seed script output.
    """
    seed_script = """
    {:ok, _reserve} = StackCoin.Core.User.create_user_account("1", "Reserve", balance: 10000)
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

    result = subprocess.run(
        ["mix", "run", "-e", seed_script],
        env={
            **os.environ,
            "MIX_ENV": "test",
            "STACKCOIN_DATABASE": f"./data/e2e_test_{stackcoin_server['port']}.db",
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
            if key in ("BOT_TOKEN", "BOT_USER_ID", "USER1_ID", "USER1_DISCORD_ID", "USER2_ID", "USER2_DISCORD_ID"):
                values[key] = val

    required = ["BOT_TOKEN", "BOT_USER_ID", "USER1_ID", "USER2_ID"]
    for k in required:
        if k not in values:
            raise RuntimeError(f"Seed script did not output {k}. Got: {values}")

    return values


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


@pytest.fixture
def luckypot_db(tmp_path):
    """Provide a fresh LuckyPot SQLite database for each test.

    Patches luckypot.config.DB_PATH to use a temp file so tests are isolated.
    """
    import luckypot.config as lp_config
    import luckypot.db as lp_db

    db_path = str(tmp_path / "test_lucky_pot.db")
    original_path = lp_config.DB_PATH
    lp_config.DB_PATH = db_path
    lp_db.init_database()

    yield db_path

    lp_config.DB_PATH = original_path


@pytest.fixture
def configure_luckypot_stk(stackcoin_server, seed_data):
    """Configure luckypot.stk to point at the test StackCoin server."""
    import luckypot.config as lp_config

    original_url = lp_config.STACKCOIN_API_URL
    original_token = lp_config.STACKCOIN_API_TOKEN

    lp_config.STACKCOIN_API_URL = stackcoin_server["base_url"]
    lp_config.STACKCOIN_API_TOKEN = seed_data["BOT_TOKEN"]

    yield

    lp_config.STACKCOIN_API_URL = original_url
    lp_config.STACKCOIN_API_TOKEN = original_token
