// The daily NAS status job. It reads the snapshot list and share totals, the newest backups, the
// manifests and the database, and writes nas-status.json, which the viewer's /api/nas serves. A page
// load never touches the NAS.
//   bun src/nas-status.ts
// hub-run runs it once a day after 07:30 Central, outside the NAS window, inside
// deploy/mount-ro.sh, which mounts the agents share read-only as nas-status and unmounts it after:
//   deploy/mount-ro.sh agents ~/mnt/nas-status-agents -- bun src/nas-status.ts
// It reads:
//   snapshots.json  status/snapshots.json on the transcripts share, which DSM task 5 writes at 07:10
//                   Central. For each share: the snapshots (its api field first, its dirs list only
//                   when api is null), and the files, bytes and newest write from its totals field,
//                   which the task counts on the NAS disk. The job walks neither share over SMB: a
//                   walk of agents (over 800,000 files) does not end in 600 s. Totals that are null,
//                   missing or not marked complete make those three fields unavailable. A file over 36
//                   hours old makes the totals and the snapshots unavailable.
//   transcripts     the hub's own mount, HUB_SHARE (it never mounts it and never writes it)
//   agents          NAS_RO_MOUNT from mount-ro.sh, or the reason NAS_RO_ERROR when the mount failed.
//                   Only two folder listings: agent-traces/trace-db and gateway-backups.
//   manifests       db/transcripts-<day>.json and db/superseded/ on the transcripts share
//   database        HUB_DB, read-only: row counts and the newest recorded_at
//   last sync       HUB_CONFIG/last-sync.json, which the hub writes after each 200 POST /v1/records,
//                   or the newest such line in HUB_LOG while that file does not exist yet
// The high-water alarm is set when a live count is below the highest count in any manifest, in db/
// or db/superseded, or when any manifest has a count below the highest count of an earlier manifest
// (by its day, then its created_at), even when the live database has recovered since. Each drop
// names its table, and a manifest drop also names its day. The backup age is the time since the
// newest manifest was made, and backup_stale is true when it is over 26 hours. The viewer computes
// the age again from created_at at page load, so an old status file still turns red.
// Each value it cannot read is {"unavailable": true, "reason": ...}, never 0, and the top-level
// unavailable list names each one.
// It writes HUB_NAS_STATUS (default ~/data/transcripts/nas-status.json) through a temp file and a
// rename. It never starts in the NAS window, 10:57 to 12:00 UTC, and it checks the window again
// before each read of the NAS. When the window starts during a run, the job stops at once with exit
// 75 and writes nothing.
// Settings: HUB_DB, HUB_SHARE, HUB_CONFIG and HUB_NAS_STATUS (as main.ts), HUB_LOG (default
// ~/transcriber-hub-logs/hub.log), HUB_NAS_MANIFESTS (default <HUB_SHARE>/db, the folder of the
// manifests, for a check against a copy).
// One JSON line to stdout. Exit 0 when the file is written, 75 in the NAS window, 1 when the write
// fails.
import { Database } from "bun:sqlite";
import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { SHARE_MARKER, windowWait } from "./share.ts";

const home = homedir();
const env = (name: string, fallback: string) => process.env[name] || fallback;
const dbPath = env("HUB_DB", join(home, "data/transcripts/transcripts.sqlite"));
const shareRoot = env("HUB_SHARE", join(home, "mnt/nas-transcripts"));
const configDir = env("HUB_CONFIG", join(home, ".config/transcriber-hub"));
const statusPath = env("HUB_NAS_STATUS", join(home, "data/transcripts/nas-status.json"));
const hubLog = env("HUB_LOG", join(home, "transcriber-hub-logs/hub.log"));
const manifestDir = env("HUB_NAS_MANIFESTS", join(shareRoot, "db"));

const TABLES = ["recordings", "transcriptions", "cleanups", "audio", "devices"] as const;
type Table = (typeof TABLES)[number];
type Counts = Record<Table, number>;
const MANIFEST = /^transcripts-(\d{4}-\d{2}-\d{2})\.json$/;
const SUPERSEDED_MANIFEST = /^transcripts-(\d{4}-\d{2}-\d{2})\.json\.\d{8}T\d{6}Z$/;
/// A DSM snapshot name, such as GMT-06-2026.11.18-04.00.01: the local time and its UTC offset.
const SNAPSHOT = /^GMT([+-])(\d{2})-(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2})$/;
/// The oldest snapshots.json whose share totals are used. DSM task 5 writes it once a day.
const TOTALS_MAX_HOURS = 36;
/// A newest database copy older than this sets backup_stale. The viewer uses the same limit.
const BACKUP_MAX_HOURS = 26;
const BUSY_TIMEOUT_MS = 10_000;
const LOG_TAIL_BYTES = 8 << 20;
const MAX_JSON_BYTES = 8 << 20;

type Unavailable = { unavailable: true; reason: string };
type Maybe<T> = T | Unavailable;

const unavailable = (reason: string): Unavailable => ({
  unavailable: true,
  reason: reason.slice(0, 300),
});
const isUnavailable = (v: unknown): v is Unavailable =>
  typeof v === "object" && v !== null && (v as { unavailable?: unknown }).unavailable === true;
const messageOf = (error: unknown) => (error instanceof Error ? error.message : String(error));

/// The NAS window started during the run. It stops the whole job (exit 75), never one value.
class WindowError extends Error {
  constructor() {
    super("the NAS window started at 10:57 UTC");
  }
}

/// Throw a WindowError when the NAS window has started. Called before each read of the NAS.
function checkWindow() {
  if (windowWait(new Date()) > 0) throw new WindowError();
}

/// Run a read, and turn a throw into an unavailable value with the reason. A WindowError passes
/// through, so the job stops.
async function attempt<T>(what: string, read: () => Promise<T> | T): Promise<Maybe<T>> {
  try {
    return await read();
  } catch (error) {
    if (error instanceof WindowError) throw error;
    return unavailable(`${what}: ${messageOf(error)}`);
  }
}

const iso = (ms: number) => new Date(ms).toISOString();
const hoursSince = (ms: number) => Math.round((Date.now() - ms) / 360_000) / 10;

/// Read a small regular file, never through a link and never waiting on a FIFO. For a file on the
/// NAS, it checks the window before each file call, so no call starts after 10:57 UTC.
async function readSmall(path: string, onNas = true): Promise<string> {
  const guard = onNas ? checkWindow : () => {};
  guard();
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    guard();
    const info = await file.stat();
    if (!info.isFile()) throw new Error(`${path} is not a regular file`);
    if (info.size > MAX_JSON_BYTES) throw new Error(`${path} is over ${MAX_JSON_BYTES} bytes`);
    guard();
    return await file.readFile("utf8");
  } finally {
    await file.close();
  }
}

// ---- Share totals ------------------------------------------------------------------------------

/// The writer of the totals, named in the output next to each share's numbers.
const TOTALS_WRITER =
  "DSM task 5 (root, daily 07:10 Central): find on the NAS disk, without @eaDir and #recycle";

type TotalsSource = {
  file: "status/snapshots.json";
  writer: string;
  generated: string | null;
  age_hours: number | null;
  /// How long the count took on the NAS, in seconds.
  count_seconds: number | null;
};

/// The generated time and age of snapshots.json, and why it is not fresh (null when it is): no valid
/// generated time, over TOTALS_MAX_HOURS old, or over 1 hour in the future. totalsOf and snapshotsOf
/// both use it.
function freshness(file: SnapshotFile): {
  generated: string | null;
  age_hours: number | null;
  stale: string | null;
} {
  const generatedMs = typeof file.generated === "string" ? Date.parse(file.generated) : NaN;
  if (!Number.isFinite(generatedMs))
    return {
      generated: null,
      age_hours: null,
      stale: "snapshots.json has no valid generated time",
    };
  const generated = iso(generatedMs);
  const age_hours = hoursSince(generatedMs);
  const stale =
    age_hours > TOTALS_MAX_HOURS
      ? `snapshots.json is ${age_hours} h old, over ${TOTALS_MAX_HOURS} h: DSM task 5 has not written it since ${generated}`
      : age_hours < -1
        ? `snapshots.json was generated in the future, ${generated}`
        : null;
  return { generated, age_hours, stale };
}

/// The files, bytes and newest write of one share from the totals field in snapshots.json. Each is
/// unavailable with one reason when the file does not read, is not fresh or has no complete totals
/// for the share: null when the count on the NAS failed, and complete must be exactly true (a file
/// from an older DSM task has no complete field). Never 0 in place of a number.
function totalsOf(file: Maybe<SnapshotFile>, share: string) {
  const source: TotalsSource = {
    file: "status/snapshots.json",
    writer: TOTALS_WRITER,
    generated: null,
    age_hours: null,
    count_seconds: null,
  };
  const none = (reason: string) => {
    const u = unavailable(reason);
    return { files: u, bytes: u, newest_write: u, totals_source: source };
  };
  if (isUnavailable(file)) return none(file.reason);
  const fresh = freshness(file);
  source.generated = fresh.generated;
  source.age_hours = fresh.age_hours;
  if (fresh.stale) return none(fresh.stale);
  const entry = file.shares?.[share];
  if (!entry) return none(`snapshots.json has no entry for ${share}`);
  if (entry.totals === undefined)
    return none(`snapshots.json has no totals for ${share}: DSM task 5 is an older version`);
  if (entry.totals === null)
    return none(`the count of ${share} on the NAS failed or was partial (totals is null)`);
  if (typeof entry.totals !== "object")
    return none(`the totals of ${share} in snapshots.json are not an object`);
  const t = entry.totals as Record<string, unknown>;
  if (t.complete !== true)
    return none(
      `the totals of ${share} in snapshots.json are not marked complete: DSM task 5 is an older version or its count did not finish`,
    );
  const count = (key: string) => {
    const v = t[key];
    return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null;
  };
  const files = count("files");
  const bytes = count("bytes");
  const newest = count("newest_epoch");
  if (files === null || bytes === null || newest === null)
    return none(
      `the totals of ${share} in snapshots.json are not whole numbers: ${JSON.stringify(t).slice(0, 120)}`,
    );
  source.count_seconds = count("seconds");
  return {
    files,
    bytes,
    // The NAS writes newest_epoch 0 when the share holds no files.
    newest_write: files > 0 ? iso(newest * 1000) : null,
    totals_source: source,
  };
}

/// Whether the transcripts share is mounted: the hub's marker is there. null when it is.
async function transcriptsReady(): Promise<string | null> {
  checkWindow();
  try {
    await stat(join(shareRoot, SHARE_MARKER));
    return null;
  } catch {
    return `the transcripts share is not mounted at ${shareRoot} (no ${SHARE_MARKER})`;
  }
}

/// Whether mount-ro.sh mounted the agents share read-only. null when it did.
async function agentsReady(): Promise<string | null> {
  const error = process.env.NAS_RO_ERROR;
  if (error) return error;
  const point = process.env.NAS_RO_MOUNT;
  if (!point) return "the agents share was not mounted: run the job through deploy/mount-ro.sh";
  const mounts = Bun.spawnSync(["/sbin/mount"]).stdout.toString().split("\n");
  const line = mounts.find((l) => l.includes(` on ${point} (smbfs`));
  if (!line) return `the agents share is not mounted at ${point}`;
  if (!line.includes("read-only")) return `the agents share at ${point} is not mounted read-only`;
  return null;
}

// ---- Snapshots ---------------------------------------------------------------------------------

/// The UTC time of a DSM snapshot name, or null when the name is not one.
function snapshotTime(name: string): number | null {
  const m = SNAPSHOT.exec(name);
  if (!m) return null;
  const [, sign, offset, y, mo, d, h, mi, s] = m;
  const local = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s));
  const offsetMs = Number(offset) * 3_600_000 * (sign === "-" ? -1 : 1);
  return local - offsetMs;
}

type SnapshotFile = {
  generated?: unknown;
  shares?: Record<string, { api?: unknown; dirs?: unknown; totals?: unknown } | undefined>;
};

type Snapshots = {
  count: number;
  newest: string | null;
  from: "api" | "dirs";
  generated: string | null;
  age_hours: number | null;
};

/// The snapshots of one share from snapshots.json: its api answer first, its dirs list only when
/// api is null. Names in dirs that are not snapshot names (desktop.ini) are left out. Unavailable
/// when the file is not fresh, or when api is null and dirs is not a list (null: the listing failed).
function snapshotsOf(file: Maybe<SnapshotFile>, share: string): Maybe<Snapshots> {
  if (isUnavailable(file)) return file;
  const { generated, age_hours, stale } = freshness(file);
  if (stale) return unavailable(stale);
  const entry = file.shares?.[share];
  if (!entry) return unavailable(`snapshots.json has no entry for ${share}`);
  let times: (number | null)[];
  let count: number;
  let from: "api" | "dirs";
  if (entry.api !== null && entry.api !== undefined) {
    const api = entry.api as {
      success?: unknown;
      error?: unknown;
      data?: { total?: unknown; snapshots?: unknown };
    };
    if (api.success !== true)
      return unavailable(
        `the DSM snapshot list of ${share} failed: ${JSON.stringify(api.error ?? null).slice(0, 120)}`,
      );
    const list = Array.isArray(api.data?.snapshots) ? (api.data.snapshots as unknown[]) : null;
    if (!list) return unavailable(`the DSM snapshot list of ${share} has no snapshots array`);
    times = list.map((s) => {
      const time = (s as { time?: unknown } | null)?.time;
      return typeof time === "string" ? snapshotTime(time) : null;
    });
    count = typeof api.data?.total === "number" ? api.data.total : list.length;
    from = "api";
  } else {
    if (!Array.isArray(entry.dirs))
      return unavailable(
        entry.dirs === null
          ? `the DSM snapshot list of ${share} failed and its snapshot folder could not be listed (api and dirs are null)`
          : `the DSM snapshot list of ${share} failed (api is null) and snapshots.json has no dirs list`,
      );
    times = entry.dirs
      .map((d) => (typeof d === "string" ? snapshotTime(d) : null))
      .filter((t) => t !== null);
    count = times.length;
    from = "dirs";
  }
  const known = times.filter((t): t is number => t !== null);
  const newest = known.length ? iso(Math.max(...known)) : null;
  return { count, newest, from, generated, age_hours };
}

async function readSnapshotFile(): Promise<Maybe<SnapshotFile>> {
  const ready = await transcriptsReady();
  if (ready) return unavailable(ready);
  return attempt("status/snapshots.json on the transcripts share cannot be read", async () => {
    checkWindow();
    const parsed: unknown = JSON.parse(await readSmall(join(shareRoot, "status/snapshots.json")));
    if (typeof parsed !== "object" || parsed === null) throw new Error("it is not a JSON object");
    return parsed as SnapshotFile;
  });
}

// ---- Manifests, the newest backup and the high-water alarm ------------------------------------

type Manifest = {
  name: string;
  sha256: string;
  bytes: number;
  created_at: string;
  counts: Partial<Counts>;
};

function parseManifest(text: string, where: string): Manifest {
  const m = JSON.parse(text) as Partial<Manifest> | null;
  if (
    !m ||
    typeof m.name !== "string" ||
    typeof m.sha256 !== "string" ||
    typeof m.bytes !== "number" ||
    typeof m.created_at !== "string" ||
    typeof m.counts !== "object" ||
    m.counts === null
  )
    throw new Error(`${where} is not a database copy manifest`);
  return m as Manifest;
}

type Manifests = {
  /// The manifests in db/, oldest day first.
  days: { day: string; manifest: Manifest }[];
  /// The manifests in db/superseded, with the day in each name.
  superseded: { day: string; manifest: Manifest }[];
};

/// Every manifest. Any one that does not read makes the whole set unavailable, so the highest
/// counts are never taken from part of the history.
/// On the default path (no HUB_NAS_MANIFESTS) the transcripts share must be mounted first.
async function readManifests(): Promise<Manifests> {
  if (!process.env.HUB_NAS_MANIFESTS) {
    const ready = await transcriptsReady();
    if (ready) throw new Error(ready);
  }
  checkWindow();
  const days = [];
  for (const name of (await readdir(manifestDir)).sort()) {
    const day = MANIFEST.exec(name)?.[1];
    if (!day) continue;
    const path = join(manifestDir, name);
    checkWindow();
    days.push({ day, manifest: parseManifest(await readSmall(path), path) });
  }
  const superseded = [];
  const folder = join(manifestDir, "superseded");
  let names: string[] = [];
  try {
    checkWindow();
    names = await readdir(folder);
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error;
  }
  for (const name of names.sort()) {
    const day = SUPERSEDED_MANIFEST.exec(name)?.[1];
    if (!day) continue;
    const path = join(folder, name);
    checkWindow();
    superseded.push({ day, manifest: parseManifest(await readSmall(path), path) });
  }
  return { days, superseded };
}

/// The SHA-256 of a file, read in chunks. It stops when the NAS window starts.
async function sha256File(path: string): Promise<{ sha256: string; bytes: number }> {
  checkWindow();
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    checkWindow();
    if (!(await file.stat()).isFile()) throw new Error(`${path} is not a regular file`);
    const hash = createHash("sha256");
    const buffer = Buffer.alloc(1 << 20);
    let bytes = 0;
    for (;;) {
      checkWindow();
      const { bytesRead } = await file.read(buffer, 0, buffer.length, bytes);
      if (bytesRead === 0) break;
      hash.update(buffer.subarray(0, bytesRead));
      bytes += bytesRead;
    }
    return { sha256: hash.digest("hex"), bytes };
  } finally {
    await file.close();
  }
}

/// The newest database copy: its day, the manifest's SHA-256, and whether the file on the share
/// has that SHA-256 and size.
async function newestBackup(manifests: Maybe<Manifests>) {
  if (isUnavailable(manifests)) return manifests;
  const newest = manifests.days.at(-1);
  if (!newest) return unavailable("the share holds no database copy manifest");
  const { day, manifest } = newest;
  const ready = await transcriptsReady();
  const held = ready
    ? unavailable(ready)
    : await attempt(`db/${manifest.name} cannot be read`, () =>
        sha256File(join(shareRoot, "db", manifest.name)),
      );
  return {
    day,
    name: manifest.name,
    sha256: manifest.sha256,
    bytes: manifest.bytes,
    created_at: manifest.created_at,
    match: isUnavailable(held)
      ? held
      : held.sha256 === manifest.sha256 && held.bytes === manifest.bytes,
  };
}

function backupAge(manifests: Maybe<Manifests>) {
  if (isUnavailable(manifests)) return manifests;
  const newest = manifests.days.at(-1)?.manifest;
  if (!newest) return unavailable("the share holds no database copy manifest");
  const made = Date.parse(newest.created_at);
  if (!Number.isFinite(made)) return unavailable(`the newest manifest has no valid created_at`);
  const hours = hoursSince(made);
  return {
    hours,
    newest_created_at: iso(made),
    day: manifests.days.at(-1)!.day,
    max_hours: BACKUP_MAX_HOURS,
    // The raw age decides, not the rounded hours, so a copy 26 h 1 min old is stale.
    backup_stale: Date.now() - made > BACKUP_MAX_HOURS * 3_600_000,
  };
}

function highWater(live: Maybe<DatabaseNumbers>, manifests: Maybe<Manifests>) {
  if (isUnavailable(live)) return unavailable(`the live counts: ${live.reason}`);
  if (isUnavailable(manifests)) return unavailable(`the manifests: ${manifests.reason}`);
  // Every manifest in the order it was made: by day, then by created_at. A superseded manifest
  // of a day was made before the one that replaced it.
  const made = (m: Manifest) => {
    const ms = Date.parse(m.created_at);
    return Number.isFinite(ms) ? ms : 0;
  };
  const all = [...manifests.days, ...manifests.superseded].sort(
    (a, b) => a.day.localeCompare(b.day) || made(a.manifest) - made(b.manifest),
  );
  if (!all.length) return unavailable("the share holds no database copy manifest");
  const highest: Partial<Counts> = {};
  const highestDay: Partial<Record<Table, string>> = {};
  const drops: (
    | {
        kind: "manifest";
        table: Table;
        day: string;
        count: number;
        highest: number;
        highest_day: string;
      }
    | { kind: "live"; table: Table; live: number; highest: number; highest_day: string }
  )[] = [];
  for (const { day, manifest } of all)
    for (const t of TABLES) {
      const n = manifest.counts[t];
      if (typeof n !== "number") continue;
      const high = highest[t];
      if (high !== undefined && n < high)
        drops.push({
          kind: "manifest",
          table: t,
          day,
          count: n,
          highest: high,
          highest_day: highestDay[t]!,
        });
      if (high === undefined || n > high) {
        highest[t] = n;
        highestDay[t] = day;
      }
    }
  for (const t of TABLES) {
    const high = highest[t];
    if (high !== undefined && live.counts[t] < high)
      drops.push({
        kind: "live",
        table: t,
        live: live.counts[t],
        highest: high,
        highest_day: highestDay[t]!,
      });
  }
  return {
    alarm: drops.length > 0,
    drops,
    highest,
    live: live.counts,
    manifests: { in_db: manifests.days.length, in_superseded: manifests.superseded.length },
  };
}

// ---- Database and last sync --------------------------------------------------------------------

type DatabaseNumbers = { counts: Counts; newest_recorded_at: string | null };

function databaseNumbers(): DatabaseNumbers {
  const db = new Database(dbPath, { readonly: true, strict: true });
  try {
    db.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
    return db.transaction(() => {
      const one = (sql: string) => db.query<{ n: number }, []>(sql).get()?.n;
      const counts = Object.fromEntries(
        TABLES.map((t) => {
          const n = one(`select count(*) as n from ${t}`);
          if (n === undefined) throw new Error(`no count for ${t}`);
          return [t, n];
        }),
      ) as Counts;
      const newest =
        db.query<{ t: string | null }, []>("select max(recorded_at) as t from recordings").get()
          ?.t ?? null;
      return { counts, newest_recorded_at: newest };
    })();
  } finally {
    db.close();
  }
}

/// The time of the last 200 POST /v1/records: the hub's state file, or the newest such line in the
/// tail of hub.log while the state file does not exist yet.
async function lastSync() {
  const statePath = join(configDir, "last-sync.json");
  let stateError: string;
  try {
    const state = JSON.parse(await readSmall(statePath, false)) as { last_sync?: unknown };
    const ms = typeof state.last_sync === "string" ? Date.parse(state.last_sync) : NaN;
    if (Number.isFinite(ms))
      return { time: iso(ms), from: "state_file", hours_ago: hoursSince(ms) };
    stateError = `${statePath} has no valid last_sync`;
  } catch (error) {
    stateError =
      error instanceof Error && "code" in error && error.code === "ENOENT"
        ? `${statePath} does not exist yet`
        : messageOf(error);
  }
  try {
    const file = await open(
      hubLog,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    let text: string;
    try {
      const size = (await file.stat()).size;
      const start = Math.max(0, size - LOG_TAIL_BYTES);
      const buffer = Buffer.alloc(size - start);
      const { bytesRead } = await file.read(buffer, 0, buffer.length, start);
      text = buffer.subarray(0, bytesRead).toString("utf8");
    } finally {
      await file.close();
    }
    let newest = -1;
    for (const line of text.split("\n")) {
      if (!line.includes('"POST /v1/records"')) continue;
      try {
        const entry = JSON.parse(line) as { route?: unknown; status?: unknown; time?: unknown };
        if (entry.route !== "POST /v1/records" || entry.status !== 200) continue;
        const ms = typeof entry.time === "string" ? Date.parse(entry.time) : NaN;
        if (Number.isFinite(ms)) newest = Math.max(newest, ms);
      } catch {
        // A line that is not JSON (hub-run and mount.sh write plain lines) is skipped.
      }
    }
    if (newest >= 0) return { time: iso(newest), from: "hub_log", hours_ago: hoursSince(newest) };
    return unavailable(
      `${stateError}, and the last ${LOG_TAIL_BYTES >> 20} MiB of ${hubLog} hold no 200 POST /v1/records`,
    );
  } catch (error) {
    return unavailable(`${stateError}, and ${hubLog} cannot be read: ${messageOf(error)}`);
  }
}

// ---- The file ---------------------------------------------------------------------------------

/// Every unavailable value in the status, by its path, such as shares.agents.files.
function unavailableList(value: unknown, path: string, out: { field: string; reason: string }[]) {
  if (isUnavailable(value)) {
    out.push({ field: path, reason: value.reason });
    return out;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const name = (item as { name?: unknown } | null)?.name;
      unavailableList(item, typeof name === "string" ? `${path}.${name}` : path, out);
    }
  } else if (typeof value === "object" && value !== null)
    for (const [key, v] of Object.entries(value))
      unavailableList(v, path ? `${path}.${key}` : key, out);
  return out;
}

async function writeStatus(status: unknown) {
  await mkdir(dirname(statusPath), { recursive: true, mode: 0o700 });
  const temp = join(dirname(statusPath), `.nas-status.${randomBytes(6).toString("hex")}.tmp`);
  try {
    await writeFile(temp, `${JSON.stringify(status, null, 1)}\n`, { mode: 0o600, flag: "wx" });
    await rename(temp, statusPath);
  } catch (error) {
    await rm(temp, { force: true }).catch(() => {});
    throw error;
  }
}

async function collect() {
  const started_at = new Date().toISOString();
  const database = await attempt("the database cannot be read", databaseNumbers);
  const manifests = await attempt("the manifests cannot be read", readManifests);
  const snapshotFile = await readSnapshotFile();

  const transcripts = {
    name: "transcripts",
    ...totalsOf(snapshotFile, "transcripts"),
    newest_backup: await newestBackup(manifests),
    snapshots: snapshotsOf(snapshotFile, "transcripts"),
  };
  const agents = {
    name: "agents",
    ...totalsOf(snapshotFile, "agents"),
    newest_backup: await agentsBackup(),
    snapshots: snapshotsOf(snapshotFile, "agents"),
  };
  const status = {
    checked_at: "",
    started_at,
    shares: [transcripts, agents],
    database: isUnavailable(database)
      ? { counts: database, newest_recorded_at: database, last_sync: await lastSync() }
      : { ...database, last_sync: await lastSync() },
    high_water: highWater(database, manifests),
    backup_age: backupAge(manifests),
  };
  status.checked_at = new Date().toISOString();
  return { ...status, unavailable: unavailableList(status, "", []) };
}

/// A ClickHouse backup name in agent-traces/trace-db, the same names that agent-traces
/// parseBackupName (packages/nas/archive.ts) reads: <database>-<YYYY-MM-DDTHH-MM-SS-mmmZ>.zip, which
/// nas:backup makes and nas:copy carries, or the older folder of the same name without .zip. An
/// older -incr folder is an increment, which agent-traces never counts as a backup, so it does not
/// match. A .zip.lock, a .nas-tmp-<pid> file and a scratch folder (agents_history) do not match.
const TRACE_BACKUP =
  /^[A-Za-z_][A-Za-z0-9_]*-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z)(?:\.zip)?$/;

/// The newest backup on the agents share: the newest ClickHouse backup in agent-traces/trace-db and
/// the newest Token Gateway copy in gateway-backups, by the time in their names, which the trace
/// job's nas:copy and nas:gateway-backups write.
async function agentsBackup() {
  const why = await agentsReady().catch((error: unknown) => messageOf(error));
  if (why) return unavailable(why);
  const root = process.env.NAS_RO_MOUNT ?? "";
  /// The name whose time (the first match group) is newest.
  const newestIn = async (folder: string, pattern: RegExp) => {
    checkWindow();
    const timed = (await readdir(join(root, folder))).flatMap((n) => {
      const time = pattern.exec(n)?.[1];
      return time ? [{ n, time }] : [];
    });
    if (!timed.length) return unavailable(`${folder} holds no backup`);
    const name = timed.sort((a, b) => a.time.localeCompare(b.time)).at(-1)!.n;
    checkWindow();
    const info = await lstat(join(root, folder, name));
    return { name, modified: iso(info.mtimeMs) };
  };
  return {
    trace_db: await attempt("agent-traces/trace-db cannot be read", () =>
      newestIn("agent-traces/trace-db", TRACE_BACKUP),
    ),
    gateway: await attempt("gateway-backups cannot be read", () =>
      newestIn("gateway-backups", /^gateway-(\d{4}-\d{2}-\d{2})\.sqlite$/),
    ),
  };
}

const say = (line: Record<string, unknown>) =>
  process.stdout.write(
    `${JSON.stringify({ time: new Date().toISOString(), event: "nas_status", ...line })}\n`,
  );

if (windowWait(new Date()) > 0) {
  say({ result: "stopped", error: "it is 10:57 to 12:00 UTC, the NAS window" });
  process.exit(75);
}
try {
  const status = await collect();
  await writeStatus(status);
  say({
    result: "written",
    path: statusPath,
    unavailable: status.unavailable.map((u) => u.field),
    alarm: isUnavailable(status.high_water) ? null : status.high_water.alarm,
    backup_stale: isUnavailable(status.backup_age) ? null : status.backup_age.backup_stale,
  });
  process.exit(0);
} catch (error) {
  if (error instanceof WindowError) {
    say({ result: "stopped", error: `${error.message}: the run stopped and wrote nothing` });
    process.exit(75);
  }
  say({ result: "failed", error: messageOf(error).slice(0, 300) });
  process.exit(1);
}
