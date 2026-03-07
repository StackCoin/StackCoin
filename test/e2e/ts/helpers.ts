import { execSync } from "node:child_process";
import { resolve } from "node:path";
import { writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";

const STACKCOIN_ROOT = resolve(import.meta.dirname, "../../..");

const ALL_TABLES = [
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
];

// Exact same seed script as py/conftest.py
const SEED_SCRIPT = `\
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
`;

export interface TestContext {
  baseUrl: string;
  botToken: string;
  botUserId: number;
  user1Id: number;
  user1DiscordId: string;
  user2Id: number;
  user2DiscordId: string;
}

function truncateAllTables(port: number): void {
  const dbPath = resolve(STACKCOIN_ROOT, `data/e2e_test_${port}.db`);
  const db = new Database(dbPath, { timeout: 10_000 });
  try {
    db.pragma("busy_timeout = 5000");
    db.pragma("foreign_keys = OFF");
    for (const table of ALL_TABLES) {
      db.exec(`DELETE FROM "${table}"`);
    }
    db.exec("DELETE FROM sqlite_sequence");
    db.pragma("foreign_keys = ON");
  } finally {
    db.close();
  }
}

function runSeed(port: number): Record<string, string> {
  // Write seed script to a temp file to avoid shell escaping issues
  const tmpFile = join(tmpdir(), `stackcoin_seed_${Date.now()}.exs`);
  writeFileSync(tmpFile, SEED_SCRIPT);

  try {
    const stdout = execSync(`mix run ${tmpFile}`, {
      env: {
        ...process.env,
        MIX_ENV: "test",
        PHX_SERVER: "true",
        STACKCOIN_DATABASE: `./data/e2e_test_${port}.db`,
      },
      cwd: STACKCOIN_ROOT,
      encoding: "utf-8",
      timeout: 30_000,
    });

    const values: Record<string, string> = {};
    for (const line of stdout.trim().split("\n")) {
      const colonIdx = line.indexOf(":");
      if (colonIdx > 0) {
        const key = line.slice(0, colonIdx).trim();
        const val = line.slice(colonIdx + 1).trim();
        if (["BOT_TOKEN", "BOT_USER_ID", "USER1_ID", "USER1_DISCORD_ID", "USER2_ID", "USER2_DISCORD_ID"].includes(key)) {
          values[key] = val;
        }
      }
    }

    for (const k of ["BOT_TOKEN", "BOT_USER_ID", "USER1_ID", "USER2_ID"]) {
      if (!(k in values)) {
        throw new Error(`Seed script did not output ${k}. Got: ${JSON.stringify(values)}`);
      }
    }

    return values;
  } finally {
    try { unlinkSync(tmpFile); } catch {}
  }
}

export function seedDatabase(): TestContext {
  const port = Number(process.env.__STACKCOIN_E2E_PORT ?? "4043");
  const baseUrl = process.env.__STACKCOIN_E2E_BASE_URL ?? `http://localhost:${port}`;

  truncateAllTables(port);
  const seed = runSeed(port);

  return {
    baseUrl,
    botToken: seed.BOT_TOKEN,
    botUserId: Number(seed.BOT_USER_ID),
    user1Id: Number(seed.USER1_ID),
    user1DiscordId: seed.USER1_DISCORD_ID ?? "200",
    user2Id: Number(seed.USER2_ID),
    user2DiscordId: seed.USER2_DISCORD_ID ?? "300",
  };
}
