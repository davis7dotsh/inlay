// The read-only viewer API that main.ts serves on 127.0.0.1:8798 for transcripts.lascari.dev. It
// has its own handler and its own readonly database handle, so no /v1 write route reaches it.
//   GET /, /insights, /nas    Hub/viewer/index.html     GET /app.js, /style.css   Hub/viewer files
//   GET /api/records?q=&source=&mode=&from=&to=&audio=&page=   20 rows per page, newest first.
//                             With q, the fused search of /v1/search, filtered before its top 20 cut.
//                             q has at most 200 characters and 16 words, else 400 q_too_long.
//   GET /api/records/<id>     one recording, its transcriptions, cleanups, audio row and device
//   GET /audio/<sha256>.flac  the FLAC, with 206 for a Range request. 503 nas_window 10:57-12:00 UTC
//   GET /api/insights         words per minute, total words, takes and words per app
//   GET /api/nas              the status file of the daily NAS status job
// Every method but GET and HEAD gets 405. Every response carries Cache-Control: no-store and
// Content-Security-Policy: default-src 'self'. Each route catches its own errors and answers 500, so a
// viewer bug never stops the hub. It logs one line per request (time, listener, route, status) and
// never a query or a text.
import { Database, type SQLQueryBindings } from "bun:sqlite";
import { constants } from "node:fs";
import { lstat, open, realpath, stat, type FileHandle } from "node:fs/promises";
import { join } from "node:path";
import { HttpError } from "./errors.ts";
import { insights, type Insights } from "./insights.ts";
import { parseRecordingId, type Sha256 } from "./record.ts";
import { search, snippet, tokens, type RecordingFilter } from "./search.ts";
import { ArtifactReader, type Clock } from "./share.ts";

export type ViewerConfig = {
  db: Database;
  shareRoot: string;
  /// The folder of index.html, app.js and style.css (cp4).
  staticRoot: string;
  /// The file the daily NAS status job writes (cp5).
  nasStatusPath: string;
  clock?: Clock;
  log?: (line: string) => void;
};

const PAGE_SIZE = 20;
const MAX_PAGE = 100_000;
const INSIGHTS_TTL_MS = 60_000;
const MAX_STATUS_BYTES = 1 << 20;
const MAX_STATIC_BYTES = 8 << 20;
/// The longest search: each word adds FTS5 work that runs on the thread of the client listener.
const MAX_Q_LENGTH = 200;
const MAX_Q_WORDS = 16;
const MIN_YEAR = 2000;
const MAX_YEAR = 2100;
/// Open for reading, never through a link, and never waiting on a FIFO or a device.
const READ_FLAGS = constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK;
const SHA_FLAC = /^\/audio\/([0-9a-f]{64})\.flac$/;
const RECORD = /^\/api\/records\/([^/]+)$/;
const WISPR = "Wispr Flow";

const BASE_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Security-Policy": "default-src 'self'",
  "X-Content-Type-Options": "nosniff",
};

const HTML = { file: "index.html", type: "text/html; charset=utf-8" };
const STATIC = new Map<string, { file: string; type: string }>([
  ["/", HTML],
  ["/index.html", HTML],
  ["/insights", HTML],
  ["/nas", HTML],
  ["/app.js", { file: "app.js", type: "text/javascript; charset=utf-8" }],
  ["/style.css", { file: "style.css", type: "text/css; charset=utf-8" }],
]);

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  Response.json(body, { status, headers: { ...BASE_HEADERS, ...headers } });

/// The viewer's database handle: opened readonly, and query_only on top, so no statement can write.
export function openViewerDb(path: string): Database {
  const db = new Database(path, { readonly: true, strict: true });
  db.exec("PRAGMA query_only = ON");
  db.exec("PRAGMA busy_timeout = 10000");
  return db;
}

/// The filters of /api/records, parsed. Each one is absent or a known value.
type Filters = {
  source?: "transcriber" | "wispr-flow";
  mode?: { kind: "none" } | { kind: "value"; value: string };
  from?: string;
  to?: string;
  audio?: boolean;
};

const PARAMS = new Set(["q", "source", "mode", "from", "to", "audio", "page"]);
const DAY = /^(\d{4})-(\d{2})-(\d{2})$/;

const badFilter = (message: string) => new HttpError(400, "bad_filter", message);

/// The UTC start of a day given as YYYY-MM-DD in the years 2000 to 2100, plus a number of days, as
/// stored in recorded_at. The year bound keeps the result a 4-digit year that sorts as text.
function dayStart(value: string, name: string, plusDays = 0): string {
  const m = DAY.exec(value);
  const [y, mo, d] = m ? [Number(m[1]), Number(m[2]), Number(m[3])] : [0, 0, 0];
  const time = new Date(Date.UTC(y, mo - 1, d));
  if (!m || time.getUTCFullYear() !== y || time.getUTCMonth() !== mo - 1 || time.getUTCDate() !== d)
    throw badFilter(`${name} must be a date YYYY-MM-DD`);
  if (y < MIN_YEAR || y > MAX_YEAR)
    throw badFilter(`${name} must be in the years ${MIN_YEAR} to ${MAX_YEAR}`);
  return new Date(time.getTime() + plusDays * 86_400_000).toISOString();
}

function parseFilters(db: Database, params: URLSearchParams): Filters {
  for (const key of params.keys())
    if (!PARAMS.has(key)) throw badFilter(`unknown parameter ${key.slice(0, 40)}`);
  const filters: Filters = {};
  const source = params.get("source") ?? "";
  if (source === "transcriber" || source === "wispr-flow") filters.source = source;
  else if (source) throw badFilter("source must be transcriber or wispr-flow");
  const mode = params.get("mode") ?? "";
  if (mode === "none") filters.mode = { kind: "none" };
  else if (mode) {
    const known = db
      .query<{ mode: string }, []>("select distinct mode from recordings where mode is not null")
      .all()
      .map((r) => r.mode);
    if (!known.includes(mode)) throw badFilter(`mode must be none or one of ${known.join(", ")}`);
    filters.mode = { kind: "value", value: mode };
  }
  const from = params.get("from") ?? "";
  if (from) filters.from = dayStart(from, "from");
  const to = params.get("to") ?? "";
  if (to) filters.to = dayStart(to, "to", 1);
  const audio = params.get("audio") ?? "";
  if (audio === "1" || audio === "0") filters.audio = audio === "1";
  else if (audio) throw badFilter("audio must be 1 or 0");
  return filters;
}

/// A Wispr Flow take: one with a Wispr Flow transcription, or a take with no mode and no
/// transcription at all. Wispr Flow takes with empty text have no transcription row (importer.py
/// and hub-sync archive.ts store none), and every Wispr Flow take has no mode. A Transcriber take
/// with a transcription is never matched, so its source stays transcriber.
const IS_WISPR =
  "(exists (select 1 from transcriptions t where t.recording_id = r.recording_id and t.provider = ?)" +
  " or (r.mode is null and not exists" +
  " (select 1 from transcriptions t where t.recording_id = r.recording_id)))";

function filterSql(filters: Filters): RecordingFilter {
  const where: string[] = [];
  const args: SQLQueryBindings[] = [];
  if (filters.source) {
    where.push(filters.source === "wispr-flow" ? IS_WISPR : `not ${IS_WISPR}`);
    args.push(WISPR);
  }
  if (filters.mode?.kind === "none") where.push("r.mode is null");
  if (filters.mode?.kind === "value") {
    where.push("r.mode = ?");
    args.push(filters.mode.value);
  }
  if (filters.from) {
    where.push("r.recorded_at >= ?");
    args.push(filters.from);
  }
  if (filters.to) {
    where.push("r.recorded_at < ?");
    args.push(filters.to);
  }
  if (filters.audio !== undefined)
    where.push(filters.audio ? "r.audio_sha256 is not null" : "r.audio_sha256 is null");
  return { where: where.length ? where.join(" and ") : "1", args };
}

type ListRow = {
  recording_id: string;
  recorded_at: string | null;
  source: string;
  mode: string | null;
  status: string;
  app: string | null;
  duration_seconds: number | null;
  has_audio: number;
  text: string | null;
};

/// The columns of one list row. text is the newest cleanup, or the newest raw text without one.
const LIST_COLUMNS =
  "select r.recording_id, r.recorded_at," +
  ` case when ${IS_WISPR} then 'wispr-flow' else 'transcriber' end as source,` +
  " r.mode, r.status, r.app, r.duration_seconds, r.audio_sha256 is not null as has_audio," +
  " coalesce((select c.text from cleanups c where c.recording_id = r.recording_id" +
  "   order by c.created_at desc, c.rowid desc limit 1)," +
  "  (select t.text from transcriptions t where t.recording_id = r.recording_id" +
  "   order by t.created_at desc, t.rowid desc limit 1)) as text" +
  " from recordings r";

const PREVIEW_LENGTH = 200;

function listItem({ text, has_audio, ...row }: ListRow) {
  return { ...row, has_audio: has_audio === 1, preview: text?.slice(0, PREVIEW_LENGTH) ?? null };
}

/// The parts of a Range header that this server serves: one range of bytes.
type Range =
  { kind: "full" } | { kind: "part"; start: number; end: number } | { kind: "unsatisfiable" };

/// One range "bytes=a-b", "bytes=a-" or "bytes=-n". Any other header (several ranges, another
/// unit, bad syntax) is ignored, as RFC 9110 allows, and the whole file is sent.
function parseRange(header: string | null, size: number): Range {
  const m = header ? /^bytes=(\d*)-(\d*)$/.exec(header.trim()) : null;
  if (!m || (!m[1] && !m[2])) return { kind: "full" };
  if (!m[1]) {
    const suffix = Number(m[2]);
    if (suffix === 0 || size === 0) return { kind: "unsatisfiable" };
    return { kind: "part", start: Math.max(0, size - suffix), end: size - 1 };
  }
  const start = Number(m[1]);
  const last = m[2] ? Number(m[2]) : null;
  if (last !== null && last < start) return { kind: "full" };
  if (start >= size) return { kind: "unsatisfiable" };
  return { kind: "part", start, end: Math.min(last ?? size - 1, size - 1) };
}

export function createViewer(config: ViewerConfig) {
  const clock = config.clock ?? (() => new Date());
  const log = config.log ?? ((line: string) => process.stdout.write(`${line}\n`));
  const reader = new ArtifactReader(config.shareRoot, clock);
  const { db } = config;
  let cached: { at: number; value: Insights } | null = null;
  /// The one insights run in progress. Requests that come during a run wait for it.
  let running: Promise<{ at: number; value: Insights }> | null = null;

  function records(url: URL) {
    const params = url.searchParams;
    const filter = filterSql(parseFilters(db, params));
    const q = params.get("q")?.trim() ?? "";
    const pageText = params.get("page") ?? "1";
    const page = /^\d{1,6}$/.test(pageText) ? Number(pageText) : 0;
    if (page < 1 || page > MAX_PAGE) throw badFilter(`page must be 1 to ${MAX_PAGE}`);
    if (q.length > MAX_Q_LENGTH || tokens(q).length > MAX_Q_WORDS)
      throw new HttpError(
        400,
        "q_too_long",
        `q must have at most ${MAX_Q_LENGTH} characters and ${MAX_Q_WORDS} words`,
      );
    if (q) {
      // The fused search gives one page: the top 20, as /v1/search does.
      const one = db.query<ListRow, SQLQueryBindings[]>(`${LIST_COLUMNS} where r.recording_id = ?`);
      const items =
        page === 1
          ? search(db, q, filter).flatMap((hit) => {
              const row = one.get(WISPR, hit.recording_id);
              if (!row) return [];
              const item = listItem(row);
              return [
                {
                  ...item,
                  score: hit.score,
                  snippet: row.text === null ? null : snippet(row.text, q),
                },
              ];
            })
          : [];
      return json({ query: q, total: items.length, page, page_size: PAGE_SIZE, items });
    }
    const total =
      db
        .query<{ n: number }, SQLQueryBindings[]>(
          `select count(*) as n from recordings r where ${filter.where}`,
        )
        .get(...filter.args)?.n ?? 0;
    const rows = db
      .query<ListRow, SQLQueryBindings[]>(
        `${LIST_COLUMNS} where ${filter.where}` +
          " order by r.recorded_at desc, r.recording_id limit ? offset ?",
      )
      .all(WISPR, ...filter.args, PAGE_SIZE, (page - 1) * PAGE_SIZE);
    return json({ total, page, page_size: PAGE_SIZE, items: rows.map(listItem) });
  }

  function record(rawId: string) {
    let id: string;
    try {
      id = parseRecordingId(decodeURIComponent(rawId));
    } catch {
      throw new HttpError(404, "not_found", "no recording has this id");
    }
    const recording = db
      .query<Record<string, unknown>, [string, string]>(
        "select r.*," +
          ` case when ${IS_WISPR} then 'wispr-flow' else 'transcriber' end as source` +
          " from recordings r where r.recording_id = ?",
      )
      .get(WISPR, id);
    if (!recording) throw new HttpError(404, "not_found", "no recording has this id");
    const transcriptions = db
      .query<Record<string, unknown>, [string]>(
        "select transcription_id, recording_id, provider, model, model_version, settings," +
          " created_at, processing_seconds, detected_language, text" +
          " from transcriptions where recording_id = ? order by created_at, rowid",
      )
      .all(id);
    const cleanups = db
      .query<Record<string, unknown>, [string]>(
        "select * from cleanups where recording_id = ? order by created_at, rowid",
      )
      .all(id);
    const audio = db
      .query<Record<string, unknown>, [string]>(
        "select a.* from audio a join recordings r on a.sha256 = r.audio_sha256" +
          " where r.recording_id = ?",
      )
      .get(id);
    // A take with no recorded_at has no device, as in export.ts: it never guesses a later owner.
    const device =
      db
        .query<Record<string, unknown>, [string]>(
          "select d.* from devices d join recordings r on d.device_id = r.device_id" +
            ' where r.recording_id = ? and d."from" <= r.recorded_at' +
            ' order by d."from" desc limit 1',
        )
        .get(id) ?? null;
    return json({ recording, transcriptions, cleanups, audio, device });
  }

  async function audio(req: Request, sha: Sha256) {
    const row = db
      .query<{ n: number }, [string]>("select 1 as n from audio where sha256 = ?")
      .get(sha);
    if (!row) throw new HttpError(404, "no_audio", "no audio row has this sha256");
    const artifact = await reader.open(sha);
    if (!artifact) throw new HttpError(404, "not_on_share", "the FLAC is not on the share");
    const range = parseRange(req.headers.get("range"), artifact.size);
    const headers: Record<string, string> = {
      ...BASE_HEADERS,
      "Content-Type": "audio/flac",
      "Accept-Ranges": "bytes",
    };
    if (range.kind === "unsatisfiable") {
      await artifact.file.close();
      return new Response(null, {
        status: 416,
        headers: { ...headers, "Content-Range": `bytes */${artifact.size}` },
      });
    }
    const [start, end] = range.kind === "part" ? [range.start, range.end] : [0, artifact.size - 1];
    headers["Content-Length"] = String(Math.max(0, end - start + 1));
    if (range.kind === "part") headers["Content-Range"] = `bytes ${start}-${end}/${artifact.size}`;
    const status = range.kind === "part" ? 206 : 200;
    if (req.method === "HEAD" || artifact.size === 0) {
      await artifact.file.close();
      return new Response(null, { status, headers });
    }
    return new Response(reader.stream(artifact, start, end), { status, headers });
  }

  async function insightsRoute() {
    const now = clock().getTime();
    if (!cached || now - cached.at > INSIGHTS_TTL_MS || now < cached.at) {
      running ??= insights(db)
        .then((value) => ({ at: now, value }))
        .finally(() => (running = null));
      cached = await running;
    }
    return json({ computed_at: new Date(cached.at).toISOString(), ...cached.value });
  }

  /// A small regular file opened with READ_FLAGS, or null when there is none. It never follows a
  /// link and never waits on a FIFO. The caller closes the handle.
  async function openSmallFile(path: string, max: number, refuse: () => HttpError) {
    let file: FileHandle;
    try {
      file = await open(path, READ_FLAGS);
    } catch (error) {
      if (error instanceof Error && "code" in error) {
        if (error.code === "ENOENT") return null;
        if (error.code === "ELOOP" || error.code === "ENXIO" || error.code === "EOPNOTSUPP")
          throw refuse();
      }
      throw error;
    }
    const info = await file.stat().catch(async (error: unknown) => {
      await file.close();
      throw error;
    });
    if (!info.isFile() || info.size > max) {
      await file.close();
      throw refuse();
    }
    return { file, info };
  }

  async function nas() {
    const refuse = () =>
      new HttpError(500, "bad_status_file", "nas-status.json is not a small regular file");
    const opened = await openSmallFile(config.nasStatusPath, MAX_STATUS_BYTES, refuse);
    if (!opened)
      return json({
        available: false,
        reason: "not_yet",
        message: "The NAS status job has not written nas-status.json yet.",
      });
    const { file, info } = opened;
    try {
      const status: unknown = JSON.parse(await file.readFile("utf8"));
      return json({ available: true, file_time: info.mtime.toISOString(), status });
    } finally {
      await file.close();
    }
  }

  async function staticFile(pathname: string) {
    const entry = STATIC.get(pathname);
    if (!entry) return null;
    const path = join(config.staticRoot, entry.file);
    const refuse = () =>
      new HttpError(403, "link_refused", `${entry.file} is a link, not a file, or not in viewer/`);
    // The viewer folder itself must be a real folder, not a link, or realpath below would
    // follow it and approve a file outside it.
    const root = await lstat(config.staticRoot).catch(() => null);
    if (!root) throw new HttpError(404, "not_found", `${entry.file} is not built yet`);
    if (root.isSymbolicLink() || !root.isDirectory()) throw refuse();
    const opened = await openSmallFile(path, MAX_STATIC_BYTES, refuse);
    if (!opened) throw new HttpError(404, "not_found", `${entry.file} is not built yet`);
    const { file, info } = opened;
    try {
      // The file must be the one in the real viewer folder: its real path is <viewer>/<name>,
      // and the open handle is that same file.
      const real = await realpath(path);
      if (real !== join(await realpath(config.staticRoot), entry.file)) throw refuse();
      const same = await stat(real);
      if (same.dev !== info.dev || same.ino !== info.ino) throw refuse();
      const bytes = await file.readFile();
      return new Response(bytes, { headers: { ...BASE_HEADERS, "Content-Type": entry.type } });
    } finally {
      await file.close();
    }
  }

  /// The route of a request. It names the route in at before it runs it, so the log line of a
  /// failed request names the route too.
  async function route(req: Request, url: URL, at: { name: string }): Promise<Response> {
    const { pathname } = url;
    if (req.method !== "GET" && req.method !== "HEAD") {
      at.name = "method";
      return json({ error: "method" }, 405, { Allow: "GET, HEAD" });
    }
    if (pathname === "/api/records") {
      at.name = "/api/records";
      return records(url);
    }
    const r = RECORD.exec(pathname);
    if (r) {
      at.name = "/api/records/:id";
      return record(r[1]!);
    }
    if (pathname.startsWith("/audio/")) {
      at.name = "/audio/:sha";
      const m = SHA_FLAC.exec(pathname);
      if (!m) throw new HttpError(400, "bad_sha", "send /audio/<64 lowercase hex>.flac");
      return await audio(req, m[1]! as Sha256);
    }
    if (pathname === "/api/insights") {
      at.name = "/api/insights";
      return await insightsRoute();
    }
    if (pathname === "/api/nas") {
      at.name = "/api/nas";
      return await nas();
    }
    if (STATIC.has(pathname)) at.name = pathname;
    const file = await staticFile(pathname);
    if (file) return file;
    return json({ error: "not_found" }, 404);
  }

  async function fetch(req: Request): Promise<Response> {
    const at = { name: "other" };
    let res: Response;
    try {
      const url = new URL(req.url);
      res = await route(req, url, at);
    } catch (error) {
      if (error instanceof HttpError) {
        res = json({ error: error.code, message: error.message }, error.status, error.headers);
      } else {
        const code = error instanceof Error && "code" in error ? String(error.code) : "internal";
        const message = error instanceof Error ? error.message.slice(0, 300) : "unknown";
        process.stderr.write(
          `${JSON.stringify({ time: clock().toISOString(), event: "error", listener: "viewer", route: at.name, code, message })}\n`,
        );
        res = json({ error: "internal" }, 500);
      }
    }
    // A HEAD reply keeps the status and headers, and the Content-Length of the GET body, and
    // drops the body. The audio route sets its own Content-Length and sends no body on HEAD.
    if (req.method === "HEAD" && res.body) {
      const headers = new Headers(res.headers);
      try {
        headers.set("Content-Length", String((await res.arrayBuffer()).byteLength));
      } catch {
        headers.delete("Content-Length");
      }
      res = new Response(null, { status: res.status, headers });
    }
    try {
      log(
        JSON.stringify({
          time: clock().toISOString(),
          listener: "viewer",
          route: `${req.method.slice(0, 10)} ${at.name}`,
          status: res.status,
        }),
      );
    } catch {
      // A failed log line never fails the request.
    }
    return res;
  }

  return { fetch };
}
