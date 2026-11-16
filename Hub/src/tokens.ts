// Device tokens. The hub stores only the SHA-256 of each token, in tokens.json (mode 600), as
// { "<sha256 hex>": "<device_id>" }. It reads the file on each request, so a revoke takes effect at once.
import { chmod, open, readFile, rename } from "node:fs/promises";
import { dirname, join } from "node:path";
import { randomBytes } from "node:crypto";
import { HttpError } from "./errors.ts";
import { sha256Hex, type DeviceId } from "./record.ts";

export const MIN_TOKEN_LENGTH = 40;

export type TokenTable = Record<string, DeviceId>;

export async function readTokens(path: string): Promise<TokenTable> {
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") return {};
    throw error;
  }
  const parsed: unknown = JSON.parse(text);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
    throw new Error(`${path} must hold a JSON object`);
  const table: TokenTable = {};
  for (const [hash, device] of Object.entries(parsed)) {
    if (!/^[0-9a-f]{64}$/.test(hash) || typeof device !== "string" || !device)
      throw new Error(`${path} holds an entry that is not <sha256 hex>: <device_id>`);
    table[hash] = device as DeviceId;
  }
  return table;
}

/// The device of the bearer token in an Authorization header. 401 when it is missing or unknown.
export function deviceFor(table: TokenTable, authorization: string | null): DeviceId {
  const m = authorization ? /^Bearer ([\x21-\x7e]+)$/.exec(authorization) : null;
  if (!m) throw new HttpError(401, "no_token", "send Authorization: Bearer <device token>");
  const device = table[sha256Hex(m[1]!)];
  if (!device) throw new HttpError(401, "bad_token", "the token is not known");
  return device;
}

/// Replace tokens.json through a temp file and a rename, mode 600.
export async function writeTokens(path: string, table: TokenTable) {
  const temp = join(dirname(path), `.tokens.${randomBytes(6).toString("hex")}.json`);
  const file = await open(temp, "wx", 0o600);
  try {
    await file.writeFile(`${JSON.stringify(table, null, 2)}\n`);
    await file.sync();
  } finally {
    await file.close();
  }
  await chmod(temp, 0o600);
  await rename(temp, path);
}

/// Store the hash of a token for a device. The device's old token, if any, stops working.
export function addToken(table: TokenTable, device: DeviceId, token: string): TokenTable {
  if (token.length < MIN_TOKEN_LENGTH || !/^[\x21-\x7e]+$/.test(token))
    throw new Error(`a token must be ${MIN_TOKEN_LENGTH} or more printable ASCII characters`);
  const next = revokeDevice(table, device);
  next[sha256Hex(token)] = device;
  return next;
}

export function revokeDevice(table: TokenTable, device: DeviceId): TokenTable {
  return Object.fromEntries(Object.entries(table).filter(([, d]) => d !== device));
}
