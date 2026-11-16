// Manage tokens.json on services-01, as services-admin:
//   bun src/tokens-cli.ts add <device_id>      reads the token from stdin, stores only its SHA-256
//   bun src/tokens-cli.ts revoke <device_id>   removes every hash of that device
//   bun src/tokens-cli.ts list                 prints each device and the first 8 hex of its hash
// It never prints a token. HUB_CONFIG sets the folder (default ~/.config/transcriber-hub).
import { mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { DeviceId } from "./record.ts";
import { addToken, readTokens, revokeDevice, writeTokens } from "./tokens.ts";

const dir = process.env.HUB_CONFIG || join(homedir(), ".config/transcriber-hub");
const path = join(dir, "tokens.json");
const [command, deviceArg] = process.argv.slice(2);
await mkdir(dir, { recursive: true, mode: 0o700 });
// Read the token before the table, so the table this run writes back is read a moment before.
const token = command === "add" ? (await Bun.stdin.text()).replace(/[\r\n]+$/, "") : "";
const table = await readTokens(path);

if (command === "add" && deviceArg) {
  await writeTokens(path, addToken(table, deviceArg as DeviceId, token));
  console.log(`tokens-cli: stored the hash of a ${token.length}-character token for ${deviceArg}`);
} else if (command === "revoke" && deviceArg) {
  const next = revokeDevice(table, deviceArg as DeviceId);
  await writeTokens(path, next);
  console.log(
    `tokens-cli: removed ${Object.keys(table).length - Object.keys(next).length} hash(es) of ${deviceArg}`,
  );
} else if (command === "list") {
  for (const [hash, device] of Object.entries(table)) console.log(`${device} ${hash.slice(0, 8)}…`);
} else {
  console.error("usage: tokens-cli.ts add <device_id> | revoke <device_id> | list");
  process.exit(2);
}
