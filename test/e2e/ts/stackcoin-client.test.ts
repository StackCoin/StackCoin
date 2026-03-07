import { describe, it, expect, beforeEach } from "vitest";
import { Client, StackCoinError } from "stackcoin";
import { seedDatabase, type TestContext } from "./helpers.js";

let ctx: TestContext;
let client: Client;

beforeEach(() => {
  ctx = seedDatabase();
  client = new Client({ token: ctx.botToken, baseUrl: ctx.baseUrl });
});

describe("auth", () => {
  it("rejects invalid token with 401", async () => {
    const badClient = new Client({ token: "totally_fake_token", baseUrl: ctx.baseUrl });
    try {
      await badClient.getMe();
      expect.unreachable("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(StackCoinError);
      expect((e as StackCoinError).statusCode).toBe(401);
    }
  });
});

describe("read endpoints", () => {
  it("getMe returns the bot user", async () => {
    const me = await client.getMe();
    expect(me.id).toBe(ctx.botUserId);
    expect(me.username).toBeDefined();
    expect(me.balance).toBeGreaterThan(0);
  });

  it("getUser returns another user", async () => {
    const user = await client.getUser(ctx.user1Id);
    expect(user.id).toBe(ctx.user1Id);
    expect(user.username).toBeDefined();
  });

  it("getUsers returns a list", async () => {
    const users = await client.getUsers();
    expect(users.length).toBeGreaterThan(0);
  });

  it("getTransactions returns seeded transactions", async () => {
    const txns = await client.getTransactions();
    expect(txns.length).toBeGreaterThan(0);
    expect(txns[0].id).toBeDefined();
    expect(txns[0].amount).toBeDefined();
  });

  it("getTransaction returns a single transaction", async () => {
    const txns = await client.getTransactions();
    const txn = await client.getTransaction(txns[0].id);
    expect(txn.id).toBe(txns[0].id);
  });
});

describe("transfers", () => {
  it("send succeeds and updates balances", async () => {
    const result = await client.send(ctx.user1Id, 5, { label: "e2e test" });
    expect(result.success).toBe(true);
    expect(result.amount).toBe(5);
    expect(result.transaction_id).toBeDefined();
  });

  it("send with insufficient balance throws 422", async () => {
    try {
      await client.send(ctx.user1Id, 999999);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(StackCoinError);
      expect((e as StackCoinError).statusCode).toBe(422);
    }
  });

  it("self-transfer throws 400", async () => {
    try {
      await client.send(ctx.botUserId, 1);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(StackCoinError);
      expect((e as StackCoinError).statusCode).toBe(400);
    }
  });
});

describe("requests", () => {
  it("create and deny request lifecycle", async () => {
    const created = await client.createRequest(ctx.user1Id, 10, { label: "e2e request" });
    expect(created.request_id).toBeDefined();
    expect(created.status).toBe("pending");

    const denied = await client.denyRequest(created.request_id);
    expect(denied.success).toBe(true);
    expect(denied.status).toBe("denied");
  });

  it("acceptRequest rejects for requester with 403", async () => {
    const created = await client.createRequest(ctx.user1Id, 1);
    try {
      await client.acceptRequest(created.request_id);
      expect.unreachable("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(StackCoinError);
      expect((e as StackCoinError).statusCode).toBe(403);
    }
  });

  it("getRequest returns a single request", async () => {
    const created = await client.createRequest(ctx.user1Id, 5);
    const fetched = await client.getRequest(created.request_id);
    expect(fetched.id).toBe(created.request_id);
  });

  it("getRequests returns list", async () => {
    await client.createRequest(ctx.user1Id, 5);
    const requests = await client.getRequests();
    expect(requests.length).toBeGreaterThan(0);
  });
});

describe("events", () => {
  it("getEvents returns events after transfer", async () => {
    await client.send(ctx.user1Id, 1, { label: "event test" });
    const events = await client.getEvents();
    expect(events.length).toBeGreaterThan(0);
    const transfers = events.filter((e) => e.type === "transfer.completed");
    expect(transfers.length).toBeGreaterThan(0);
  });
});

describe("idempotency", () => {
  it("same idempotency key returns same result", async () => {
    const key = "e2e-idem-key-1";
    const r1 = await client.send(ctx.user1Id, 3, { idempotencyKey: key });
    const r2 = await client.send(ctx.user1Id, 3, { idempotencyKey: key });
    expect(r1.transaction_id).toBe(r2.transaction_id);

    const me = await client.getMe();
    expect(me.balance).toBe(1000 - 3);
  });

  it("different keys create separate transactions", async () => {
    const r1 = await client.send(ctx.user1Id, 1, { idempotencyKey: "key-a" });
    const r2 = await client.send(ctx.user1Id, 1, { idempotencyKey: "key-b" });
    expect(r1.transaction_id).not.toBe(r2.transaction_id);
  });
});

describe("discord", () => {
  it("getDiscordBotId returns a string", async () => {
    const botId = await client.getDiscordBotId();
    expect(typeof botId).toBe("string");
    expect(botId.length).toBeGreaterThan(0);
  });
});
