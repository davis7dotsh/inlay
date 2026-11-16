// The client's settings: ~/.config/transcriber-hub-client/{config.json, hub-cert.pem, token (mode 600)}.
// config.json: { "addresses": ["https://...:8797", ...], "pin": "sha256/<base64>" }
import { statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { HubTarget } from "./hub-client.ts";

/// hub and pin replace the configured addresses and pin for one run (live checks).
export async function loadTarget(
  configDir: string,
  override: { hub?: string; pin?: string } = {},
): Promise<HubTarget> {
  const config: unknown = JSON.parse(await readFile(join(configDir, "config.json"), "utf8"));
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
  const tokenPath = join(configDir, "token");
  if (statSync(tokenPath).mode & 0o077) throw new Error(`${tokenPath} must be mode 600`);
  const token = (await readFile(tokenPath, "utf8")).trim();
  if (!token) throw new Error(`${tokenPath} is empty`);
  const addresses: string[] = override.hub ? override.hub.split(",") : config.addresses;
  const pin = override.pin ?? config.pin;
  if (!/^sha256\/[A-Za-z0-9+/]{43}=$/.test(pin)) throw new Error("the pin must be sha256/<base64>");
  return { addresses, pin, token, ca: await readFile(join(configDir, "hub-cert.pem"), "utf8") };
}
