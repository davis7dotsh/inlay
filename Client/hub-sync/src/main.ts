// The daily sync of this machine's Transcriber archive to the Transcriber Hub.
//   bun src/main.ts [--since <ISO time>] [--only <recording_id>] [--dry-run]
//                   [--hub <url,url>] [--pin sha256/<base64>]
// Settings: ~/.config/transcriber-hub-client/{config.json, hub-cert.pem, token (mode 600)}.
// Confirms: ~/.local/state/transcriber-hub-client/confirms.sqlite.
// Log: one JSON line per record and one per run, to ~/Library/Logs/transcriber-hub-sync.log and stdout.
// --hub and --pin replace the configured addresses and pin for one run (live checks).
// Exit 0 when the run finished, 75 when it stopped early (the rest wait for the next run), 1 on error.
import { appendFileSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { stamp } from "../../../Hub/src/ids.ts";
import { ConfirmStore } from "./confirms.ts";
import { assertHttps } from "./hub-client.ts";
import { runSync } from "./sync.ts";

const home = homedir();
const { values } = parseArgs({
  options: {
    since: { type: "string" },
    only: { type: "string" },
    "dry-run": { type: "boolean", default: false },
    hub: { type: "string" },
    pin: { type: "string" },
    config: { type: "string", default: join(home, ".config/transcriber-hub-client") },
    archive: { type: "string", default: join(home, "Transcripts") },
    state: {
      type: "string",
      default: join(home, ".local/state/transcriber-hub-client/confirms.sqlite"),
    },
    log: { type: "string", default: join(home, "Library/Logs/transcriber-hub-sync.log") },
  },
  strict: true,
});

function log(line: Record<string, unknown>) {
  const text = `${JSON.stringify({ time: new Date().toISOString(), ...line })}\n`;
  appendFileSync(values.log, text, { mode: 0o600 });
  process.stdout.write(text);
}

/// config.json: { "addresses": ["https://...:8797", ...], "pin": "sha256/<base64>" }
async function loadTarget() {
  const config: unknown = JSON.parse(await readFile(join(values.config, "config.json"), "utf8"));
  if (
    typeof config !== "object" ||
    config === null ||
    !("addresses" in config) ||
    !Array.isArray(config.addresses) ||
    !config.addresses.every((a) => typeof a === "string") ||
    !("pin" in config) ||
    typeof config.pin !== "string"
  )
    throw new Error("config.json must hold addresses (a list of URLs) and pin");
  const tokenPath = join(values.config, "token");
  if (statSync(tokenPath).mode & 0o077) throw new Error(`${tokenPath} must be mode 600`);
  const token = (await readFile(tokenPath, "utf8")).trim();
  if (!token) throw new Error(`${tokenPath} is empty`);
  const addresses: string[] = values.hub ? values.hub.split(",") : config.addresses;
  const pin = values.pin ?? config.pin;
  if (!/^sha256\/[A-Za-z0-9+/]{43}=$/.test(pin)) throw new Error("the pin must be sha256/<base64>");
  return { addresses, pin, token, ca: await readFile(join(values.config, "hub-cert.pem"), "utf8") };
}

try {
  if (values.since) stamp(values.since); // refuse a bad time before anything else
  if (values.hub) assertHttps(values.hub.split(",")); // refuse an http override before the config is read
  const target = await loadTarget();
  assertHttps(target.addresses); // before anything is read or sent
  const store = new ConfirmStore(values.state);
  const summary = await runSync({
    archiveRoot: values.archive,
    store,
    target,
    since: values.since ?? null,
    only: values.only ?? null,
    dryRun: values["dry-run"],
    log,
  }).finally(() => store.close());
  log({
    ...summary,
    since: values.since ?? null,
    only: values.only ?? null,
    dry_run: values["dry-run"],
  });
  process.exit(summary.stopped ? 75 : 0);
} catch (error) {
  log({
    event: "run",
    error: (error instanceof Error ? error.message : String(error)).slice(0, 300),
  });
  process.exit(1);
}
