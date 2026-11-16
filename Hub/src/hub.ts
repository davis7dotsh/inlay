// The hub's routes, as one fetch handler that main.ts serves over TLS and the tests call directly.
//   POST /v1/records                       store one record, reply with the confirm
//   POST /v1/records/{recording_id}/reconfirm  re-hash the FLAC on the share and compare every hash
//                                          (and, when sent, the source WAV's SHA-256)
//   GET  /v1/search?q=...                  keyword search over the cleaned text
//   GET  /healthz                          "ok", no auth
// It logs one line per request (time, route, device_id, status, recording_id) and never a token,
// a header, a query or a text.
import type { Database } from "bun:sqlite";
import { HttpError } from "./errors.ts";
import {
  parseHeld,
  parseRecordPost,
  parseRecordingId,
  type DeviceId,
  type RecordingId,
} from "./record.ts";
import { search } from "./search.ts";
import { assertWindowOpen, Share, type Clock } from "./share.ts";
import { assertWritable, confirmFor, recordingOwner, storedHashes, writeRows } from "./store.ts";
import { deviceFor, readTokens } from "./tokens.ts";

export type HubConfig = {
  db: Database;
  shareRoot: string;
  tokensPath: string;
  clock?: Clock;
  log?: (line: string) => void;
};

export type LogLine = {
  time: string;
  route: string;
  device_id: string | null;
  status: number;
  recording_id: string | null;
};

type Context = { device: DeviceId | null; recording: string | null };

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  Response.json(body, { status, headers: { "Cache-Control": "no-store", ...headers } });

const RECONFIRM = /^\/v1\/records\/([^/]+)\/reconfirm$/;

export function createHub(config: HubConfig) {
  const clock = config.clock ?? (() => new Date());
  const log = config.log ?? ((line: string) => process.stdout.write(`${line}\n`));
  const share = new Share(config.shareRoot, clock);
  const { db } = config;

  const authenticate = async (req: Request, ctx: Context) => {
    ctx.device = deviceFor(await readTokens(config.tokensPath), req.headers.get("authorization"));
    return ctx.device;
  };

  const body = async (req: Request) => {
    try {
      return (await req.json()) as unknown;
    } catch {
      throw new HttpError(400, "bad_json", "the body must be complete JSON");
    }
  };

  const assertOwner = (id: RecordingId, device: DeviceId) => {
    const owner = recordingOwner(db, id);
    if (owner && owner.device_id !== device)
      throw new HttpError(403, "device_mismatch", "the recording belongs to another device");
    return owner;
  };

  async function postRecord(req: Request, ctx: Context) {
    const device = await authenticate(req, ctx);
    assertWindowOpen(clock());
    const rows = parseRecordPost(await body(req), device);
    ctx.recording = rows.recording.recording_id;
    // Refuse early, before the FLAC upload. writeRows checks again inside its write lock.
    assertWritable(db, rows);
    if (rows.audio) await share.putFlac(rows.audio.sha256, rows.audio.flac);
    writeRows(db, rows);
    return json(confirmFor(db, rows));
  }

  async function reconfirm(req: Request, ctx: Context, rawId: string) {
    const device = await authenticate(req, ctx);
    assertWindowOpen(clock());
    const id = parseRecordingId(decodeURIComponent(rawId));
    ctx.recording = id;
    const held = parseHeld(await body(req), id);
    const owner = assertOwner(id, device);
    if (!owner)
      return json({ ok: false, mismatches: [{ field: "recording", expected: id, found: null }] });
    // Read the stored hashes after the awaited FLAC hash, so a concurrent re-send cannot leave
    // the text hashes stale.
    const before = storedHashes(db, id);
    const onShare =
      before.audio_sha256 && before.nas_path ? await share.hash(before.nas_path) : null;
    const stored = storedHashes(db, id);
    const mismatches: {
      field: string;
      expected: string | null;
      found: string | string[] | null;
    }[] = [];
    if (held.flac_sha256 !== stored.audio_sha256)
      mismatches.push({
        field: "flac_row",
        expected: held.flac_sha256,
        found: stored.audio_sha256,
      });
    if (stored.audio_sha256 && onShare !== stored.audio_sha256)
      mismatches.push({ field: "flac_file", expected: stored.audio_sha256, found: onShare });
    if (held.source_sha256 !== undefined && held.source_sha256 !== stored.source_sha256)
      mismatches.push({
        field: "source",
        expected: held.source_sha256,
        found: stored.source_sha256,
      });
    for (const field of ["raw", "clean"] as const) {
      const want = held.text_sha256[field];
      const have = stored[field];
      if (want === null ? have.length > 0 : !have.includes(want))
        mismatches.push({ field, expected: want, found: have });
    }
    return json(mismatches.length ? { ok: false, mismatches } : { ok: true });
  }

  async function searchRoute(req: Request, ctx: Context, url: URL) {
    await authenticate(req, ctx);
    const q = url.searchParams.get("q")?.trim() ?? "";
    if (!q) throw new HttpError(400, "no_query", "send ?q=<words>");
    return json({ results: search(db, q) });
  }

  async function route(req: Request, url: URL, ctx: Context): Promise<[string, Response]> {
    const { pathname } = url;
    if (pathname === "/healthz")
      return [
        "GET /healthz",
        req.method === "GET" ? new Response("ok") : json({ error: "method" }, 405),
      ];
    if (pathname === "/v1/records" && req.method === "POST")
      return ["POST /v1/records", await postRecord(req, ctx)];
    const m = RECONFIRM.exec(pathname);
    if (m && req.method === "POST")
      return ["POST /v1/records/:id/reconfirm", await reconfirm(req, ctx, m[1]!)];
    if (pathname === "/v1/search" && req.method === "GET")
      return ["GET /v1/search", await searchRoute(req, ctx, url)];
    return ["other", json({ error: "not_found" }, 404)];
  }

  async function fetch(req: Request): Promise<Response> {
    const ctx: Context = { device: null, recording: null };
    const url = new URL(req.url);
    let name = `${req.method} ${url.pathname.startsWith("/v1/records/") ? "/v1/records/:id/reconfirm" : url.pathname}`;
    let res: Response;
    try {
      [name, res] = await route(req, url, ctx);
    } catch (error) {
      if (error instanceof HttpError) {
        res = json({ error: error.code, message: error.message }, error.status, error.headers);
      } else {
        const code = error instanceof Error && "code" in error ? String(error.code) : "internal";
        const message = error instanceof Error ? error.message.slice(0, 300) : "unknown";
        process.stderr.write(
          `${JSON.stringify({ time: clock().toISOString(), event: "error", route: name, code, message })}\n`,
        );
        res = json({ error: "internal" }, 500);
      }
    }
    const line: LogLine = {
      time: clock().toISOString(),
      route: name,
      device_id: ctx.device,
      status: res.status,
      recording_id: ctx.recording,
    };
    log(JSON.stringify(line));
    return res;
  }

  return { fetch };
}
