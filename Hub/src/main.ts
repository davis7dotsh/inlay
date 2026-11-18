// Serve the hub over TLS on each address of HUB_HOSTS (the LAN and tailnet addresses), never on a
// wildcard address. Settings (environment):
//   HUB_HOSTS   comma list of addresses to listen on. Required.
//   HUB_PORT    default 8797
//   HUB_DB      default ~/data/transcripts/transcripts.sqlite
//   HUB_SHARE   default ~/mnt/nas-transcripts
//   HUB_CONFIG  default ~/.config/transcriber-hub (tokens.json, tls/cert.pem, tls/key.pem)
//   HUB_VIEWER_PORT  default 8798. The read-only viewer API (viewer.ts) listens on 127.0.0.1 only,
//                    over plain HTTP for Caddy, with its own readonly database handle.
//   HUB_NAS_STATUS   default ~/data/transcripts/nas-status.json, the NAS status job's file
// The hub writes the time of each 200 POST /v1/records to HUB_CONFIG/last-sync.json, which the NAS
// status job (nas-status.ts) reads.
import { homedir } from "node:os";
import { join } from "node:path";
import { createHub } from "./hub.ts";
import { openStore } from "./store.ts";
import { createViewer, openViewerDb } from "./viewer.ts";

const home = homedir();
const env = (name: string, fallback: string) => process.env[name] || fallback;
const hosts = (process.env.HUB_HOSTS ?? "")
  .split(",")
  .map((h) => h.trim())
  .filter(Boolean);
if (!hosts.length) throw new Error("set HUB_HOSTS to the addresses to listen on");
for (const h of hosts)
  if (["0.0.0.0", "::", "[::]", ""].includes(h))
    throw new Error(`HUB_HOSTS must not hold the wildcard ${h}`);
const port = Number(env("HUB_PORT", "8797"));
const configDir = env("HUB_CONFIG", join(home, ".config/transcriber-hub"));
const dbPath = env("HUB_DB", join(home, "data/transcripts/transcripts.sqlite"));
const shareRoot = env("HUB_SHARE", join(home, "mnt/nas-transcripts"));
const db = openStore(dbPath);
const hub = createHub({
  db,
  shareRoot,
  tokensPath: join(configDir, "tokens.json"),
  syncStatePath: join(configDir, "last-sync.json"),
});
const tls = {
  cert: Bun.file(join(configDir, "tls/cert.pem")),
  key: Bun.file(join(configDir, "tls/key.pem")),
};

const servers = hosts.map((hostname) =>
  Bun.serve({
    hostname,
    port,
    tls,
    maxRequestBodySize: 512 * 1024 * 1024,
    idleTimeout: 120,
    fetch: hub.fetch,
  }),
);
process.stdout.write(
  `${JSON.stringify({ time: new Date().toISOString(), event: "listening", hosts, port })}\n`,
);

/// The viewer listener. It starts after the client listeners, and a failure to start it is logged
/// and leaves the client listeners serving.
const viewerPort = Number(env("HUB_VIEWER_PORT", "8798"));
let viewerDb: ReturnType<typeof openViewerDb> | null = null;
try {
  viewerDb = openViewerDb(dbPath);
  const viewer = createViewer({
    db: viewerDb,
    shareRoot,
    staticRoot: join(import.meta.dir, "../viewer"),
    nasStatusPath: env("HUB_NAS_STATUS", join(home, "data/transcripts/nas-status.json")),
  });
  servers.push(
    Bun.serve({
      hostname: "127.0.0.1",
      port: viewerPort,
      idleTimeout: 120,
      maxRequestBodySize: 64 * 1024,
      fetch: viewer.fetch,
      error: () =>
        Response.json(
          { error: "internal" },
          {
            status: 500,
            headers: {
              "Cache-Control": "no-store",
              "Content-Security-Policy": "default-src 'self'",
            },
          },
        ),
    }),
  );
  process.stdout.write(
    `${JSON.stringify({ time: new Date().toISOString(), event: "listening", listener: "viewer", host: "127.0.0.1", port: viewerPort })}\n`,
  );
} catch (error) {
  viewerDb?.close();
  viewerDb = null;
  const message = error instanceof Error ? error.message.slice(0, 300) : "unknown";
  process.stderr.write(
    `${JSON.stringify({ time: new Date().toISOString(), event: "error", listener: "viewer", message })}\n`,
  );
}

/// Let requests in flight finish (at most 60 s), then close the database. A second signal waits
/// for the first shutdown.
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await Promise.race([Promise.all(servers.map((s) => s.stop())), Bun.sleep(60_000)]);
  db.close();
  viewerDb?.close();
  process.exit(0);
}
process.on("SIGTERM", () => void stop());
process.on("SIGINT", () => void stop());
