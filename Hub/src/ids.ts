// The derived keys of the transcripts database. A port of importer.py (transcripts-nas/import), so an
// imported record and a later sync of the same take get the same IDs. Never change NS or the name forms.
import { createHash } from "node:crypto";

const NAMESPACE_URL = "6ba7b811-9dad-11d1-80b4-00c04fd430c8";

/// RFC 4122 UUIDv5: SHA-1 of the namespace bytes and the UTF-8 name, as Python uuid.uuid5 makes it.
export function uuid5(namespace: string, name: string): string {
  const bytes = createHash("sha1")
    .update(Buffer.from(namespace.replaceAll("-", ""), "hex"))
    .update(name, "utf8")
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes[6]! & 0x0f) | 0x50;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const h = bytes.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export const NS = uuid5(NAMESPACE_URL, "https://transcripts.lascari.internal/ns/v1");

export const transcriptionId = (
  recordingId: string,
  provider: string,
  model: string,
  createdAt: string | null,
) => uuid5(NS, `transcription|${recordingId}|${provider}|${model}|${createdAt ?? ""}`);

export const cleanupId = (transcriptionIdValue: string) =>
  uuid5(NS, `cleanup|${transcriptionIdValue}`);

const ISO =
  /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?(?:([+-])(\d{2}):?(\d{2})(?::?(\d{2}))?)?$/;

/// importer.py stamp(): UTC, milliseconds, "Z" (2026-03-01T20:33:44.168Z). Input forms include
/// 2026-11-10T21:11:53Z and 2026-03-01 20:33:44.168 +00:00. A time without a zone is UTC.
/// It refuses a time that has sub-millisecond digits, as the importer does.
export function stamp(value: string | null | undefined): string | null {
  if (!value) return null;
  const text = value
    .replaceAll(" Z", "+00:00")
    .replaceAll(" +", "+")
    .replaceAll(" -", "-")
    .replaceAll("Z", "+00:00");
  const m = ISO.exec(text);
  if (!m) throw new Error(`not an ISO 8601 time: ${value}`);
  const [, y, mo, d, h = "0", mi = "0", s = "0", frac = "", sign, oh = "0", om = "0", os = "0"] = m;
  const micros = Number(frac.padEnd(6, "0").slice(0, 6));
  if (micros % 1000) throw new Error(`sub-millisecond time would be lost: ${value}`);
  const local = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s));
  const check = new Date(local);
  if (
    check.getUTCMonth() !== Number(mo) - 1 ||
    check.getUTCDate() !== Number(d) ||
    check.getUTCHours() !== Number(h) ||
    check.getUTCMinutes() !== Number(mi) ||
    check.getUTCSeconds() !== Number(s)
  )
    throw new Error(`not a valid time: ${value}`);
  const offset = sign
    ? (sign === "-" ? -1 : 1) * ((Number(oh) * 60 + Number(om)) * 60 + Number(os))
    : 0;
  return new Date(local - offset * 1000 + micros / 1000).toISOString();
}

/// Python json.dumps(value, sort_keys=True, ensure_ascii=False): the form importer.py stores in
/// transcriptions.settings, with ", " and ": " between items.
export function pythonJson(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "string")
    return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("settings hold a number JSON cannot carry");
    return Number.isInteger(value) && !Object.is(value, -0) ? String(value) : JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(pythonJson).join(", ")}]`;
  if (typeof value === "object")
    return `{${Object.keys(value)
      .sort()
      .map((k) => `${JSON.stringify(k)}: ${pythonJson((value as Record<string, unknown>)[k])}`)
      .join(", ")}}`;
  throw new Error("settings hold a value JSON cannot carry");
}
