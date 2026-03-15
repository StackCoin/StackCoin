import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { Client, Gateway } from "stackcoin";
import type { AnyEvent, RequestDeniedEvent, TransferCompletedEvent } from "stackcoin";
import { seedDatabase, type TestContext } from "./helpers.js";

let ctx: TestContext;
let client: Client;
let gateway: Gateway | null = null;

beforeEach(() => {
  ctx = seedDatabase();
  client = new Client({ token: ctx.botToken, baseUrl: ctx.baseUrl });
});

afterEach(() => {
  if (gateway) {
    gateway.stop();
    gateway = null;
  }
});

function wsUrl(baseUrl: string): string {
  return baseUrl.replace("http://", "ws://") + "/ws";
}

function waitForEvent(gw: Gateway, eventType: string, timeoutMs = 10_000): Promise<AnyEvent> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`Timed out waiting for ${eventType} event`));
    }, timeoutMs);

    gw.on(eventType, (event) => {
      clearTimeout(timeout);
      resolve(event);
    });
  });
}

describe("gateway", () => {
  it("receives transfer.completed event", async () => {
    gateway = new Gateway({
      token: ctx.botToken,
      wsUrl: wsUrl(ctx.baseUrl),
    });

    const eventPromise = waitForEvent(gateway, "transfer.completed");

    // Connect in background
    const connectPromise = gateway.connect();

    // Give the gateway a moment to connect and join
    await new Promise((r) => setTimeout(r, 1000));

    // Trigger a transfer
    await client.send(ctx.user1Id, 1, { label: "gateway test" });

    const event = await eventPromise;
    expect(event.type).toBe("transfer.completed");
    const data = (event as TransferCompletedEvent).data;
    expect(data.amount).toBe(1);

    gateway.stop();
    await connectPromise;
  });

  it("replays events with lastEventId", async () => {
    // Create an event via REST first
    await client.send(ctx.user1Id, 1, { label: "before gateway" });

    const receivedEvents: AnyEvent[] = [];

    gateway = new Gateway({
      token: ctx.botToken,
      wsUrl: wsUrl(ctx.baseUrl),
      lastEventId: 0,
    });

    for (const type of ["transfer.completed", "request.created", "request.accepted", "request.denied"]) {
      gateway.on(type, (event) => {
        receivedEvents.push(event);
      });
    }

    const connectPromise = gateway.connect();

    // Wait for replay
    await new Promise((r) => setTimeout(r, 3000));

    expect(receivedEvents.length).toBeGreaterThan(0);

    gateway.stop();
    await connectPromise;
  });

  it("tracks event IDs via onEventId callback", async () => {
    const eventIds: number[] = [];

    gateway = new Gateway({
      token: ctx.botToken,
      wsUrl: wsUrl(ctx.baseUrl),
      lastEventId: 0,
      onEventId: (id) => eventIds.push(id),
    });

    for (const type of ["transfer.completed", "request.created", "request.accepted", "request.denied"]) {
      gateway.on(type, () => {});
    }

    const connectPromise = gateway.connect();

    await new Promise((r) => setTimeout(r, 3000));

    expect(eventIds.length).toBeGreaterThan(0);
    for (let i = 1; i < eventIds.length; i++) {
      expect(eventIds[i]).toBeGreaterThan(eventIds[i - 1]);
    }

    gateway.stop();
    await connectPromise;
  });

  it("includes denied_by_id on request.denied events", async () => {
    gateway = new Gateway({
      token: ctx.botToken,
      wsUrl: wsUrl(ctx.baseUrl),
    });

    const eventPromise = waitForEvent(gateway, "request.denied");
    const connectPromise = gateway.connect();

    await new Promise((r) => setTimeout(r, 1000));

    const request = await client.createRequest(ctx.user1Id, 1, { label: "gateway deny test" });
    await client.denyRequest(request.request_id);

    const event = await eventPromise;
    const data = (event as RequestDeniedEvent).data;

    expect(data.request_id).toBe(request.request_id);
    expect(data.denied_by_id).toBe(ctx.botUserId);

    gateway.stop();
    await connectPromise;
  });
});
