import { execSync, spawn, type ChildProcess } from "node:child_process";
import { resolve } from "node:path";

const PORT = 4043;
const STACKCOIN_ROOT = resolve(import.meta.dirname, "../../..");
const DB_FILE = `./data/e2e_test_${PORT}.db`;

let serverProcess: ChildProcess | null = null;

function mixEnv(): Record<string, string> {
  return {
    ...process.env,
    MIX_ENV: "test",
    STACKCOIN_DATABASE: DB_FILE,
    PORT: String(PORT),
    SECRET_KEY_BASE:
      "test_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix_to_accept_it_OK",
    PHX_SERVER: "true",
  } as Record<string, string>;
}

async function waitForServer(baseUrl: string, maxWaitMs = 30_000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    try {
      const resp = await fetch(`${baseUrl}/api/openapi`);
      if (resp.ok) return;
    } catch {
      // Server not ready yet
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`Server did not start within ${maxWaitMs}ms`);
}

export async function setup(): Promise<void> {
  const opts = { env: mixEnv(), cwd: STACKCOIN_ROOT, stdio: "pipe" as const };

  // Create fresh database
  try { execSync("mix ecto.drop --quiet", opts); } catch { /* may not exist yet */ }
  execSync("mix ecto.create --quiet", opts);
  execSync("mix ecto.migrate --quiet", opts);

  // Start server
  serverProcess = spawn("mix", ["phx.server"], {
    env: mixEnv(),
    cwd: STACKCOIN_ROOT,
    stdio: "pipe",
    detached: true,
  });

  await waitForServer(`http://localhost:${PORT}`);

  // Store for tests to read
  process.env.__STACKCOIN_E2E_BASE_URL = `http://localhost:${PORT}`;
  process.env.__STACKCOIN_E2E_PORT = String(PORT);
}

export async function teardown(): Promise<void> {
  if (serverProcess?.pid) {
    try {
      process.kill(-serverProcess.pid, "SIGTERM");
    } catch { /* already dead */ }

    await new Promise<void>((resolve) => {
      const timeout = setTimeout(() => {
        try { process.kill(-serverProcess!.pid!, "SIGKILL"); } catch {}
        resolve();
      }, 10_000);

      serverProcess!.on("exit", () => {
        clearTimeout(timeout);
        resolve();
      });
    });
  }
}
