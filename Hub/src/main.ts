// Serve the hub over TLS on each address of HUB_HOSTS (the LAN and tailnet addresses), never on a
// wildcard address. Settings (environment):
//   HUB_HOSTS   comma list of addresses to listen on. Required.
//   HUB_PORT    default 8797
//   HUB_DB      default ~/data/transcripts/transcripts.sqlite
//   HUB_SHARE   default ~/mnt/nas-transcripts
//   HUB_CONFIG  default ~/.config/transcriber-hub (tokens.json, tls/cert.pem, tls/key.pem)
import { homedir } from "node:os";
import { join } from "node:path";
import { createHub } from "./hub.ts";
import { openStore } from "./store.ts";

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
const db = openStore(env("HUB_DB", join(home, "data/transcripts/transcripts.sqlite")));
const hub = createHub({
  db,
  shareRoot: env("HUB_SHARE", join(home, "mnt/nas-transcripts")),
  tokensPath: join(configDir, "tokens.json"),
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

/// Let requests in flight finish (at most 60 s), then close the database. A second signal waits
/// for the first shutdown.
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await Promise.race([Promise.all(servers.map((s) => s.stop())), Bun.sleep(60_000)]);
  db.close();
  process.exit(0);
}
process.on("SIGTERM", () => void stop());
process.on("SIGINT", () => void stop());
