// The nightly copy of the transcripts database to the transcripts share, and its checks.
//   bun src/backup.ts [--day YYYY-MM-DD]   copy the database to db/transcripts-<day>.sqlite,
//                                          db/transcripts-<day>.jsonl.gz and
//                                          db/transcripts-<day>.rest.json.gz on the share
//   bun src/backup.ts --restore-check      restore the newest copy from the share and check it
//   bun src/backup.ts --restore-check --day YYYY-MM-DD
//                                          restore that day's copy and check it against its
//                                          manifest (hub-run uses this one)
//   bun src/backup.ts --jsonl-check        rebuild the newest JSONL that matches the live database
//   bun src/backup.ts --jsonl-check --day YYYY-MM-DD
//                                          rebuild that day's JSONL and check it against its
//                                          manifest (hub-run uses this one)
// hub-run runs the copy once a day from 03:00 local time, outside the NAS window, then both checks.
// The copy: VACUUM INTO a file in a new temp folder, HUB_BACKUP_DIR/.run-<random> (a consistent
// snapshot while the hub writes), an integrity check, and the JSONL and rest export of that
// snapshot (export.ts) into the same folder. Every check runs on the temp files first. Only then
// do the local copy and the share files change. The manifest db/transcripts-<day>.json (SHA-256,
// bytes, row counts, the text hash, and the JSONL and rest SHA-256) goes last, so a copy with a
// manifest is whole.
// The copy never replaces a file. A day path that holds the new bytes is kept. A day path that
// holds other bytes (a local copy, a share SQLite, JSONL, rest file or manifest that an earlier
// run of the day left) is first moved to <name>.<UTC time> in db/superseded on the share, or in
// HUB_BACKUP_DIR/superseded, and read back there. The manifest moves first, so a manifest in db/
// always names the files beside it. All moves come before the first write, and a move that fails
// stops the run with no write. Nothing removes a file from the two superseded folders, or a .run-
// folder that a killed run left.
// The history stays: a count below the highest count in any manifest (in db/ or db/superseded), or
// a JSONL and rest file that do not hold every row, exits 1 and changes no file. The live counts
// are checked first, so a second run on a day that is whole on the share also exits 1 on a drop.
// Otherwise the share drops a SQLite copy only when it is older than 30 days, not one of the
// newest 30, and its day has a manifest that lists a JSONL and a rest file (a manifest from before
// cp2 lists none, so its SQLite copy stays), and HUB_BACKUP_DIR keeps the newest 7 and each copy whose
// day has no manifest. Manifests, JSONL and rest files are never removed.
// A copy writes only today or tomorrow on this clock: a --day before today exits 2 with no read of
// the share, so a past day is never written again. One copy runs at a time (a lock file in
// HUB_BACKUP_DIR).
// The restore check reads the newest copy, or with --day that day's copy, back from the share into
// a temp folder. It checks the SHA-256 against the manifest, the integrity, the row counts, the
// keyword index against the cleanups table (the FTS5 integrity-check), and that every row of the
// copy is in the live database (the hub never deletes a row).
// The JSONL check rebuilds a JSONL and its rest file into an empty database in a temp folder and
// compares the counts and the text hash. With --day, against that day's manifest. Without it,
// against the live database: it tries each manifest with the live counts, newest first, and passes
// on the first match.
// Settings: HUB_DB and HUB_SHARE (as main.ts), HUB_BACKUP_DIR (default ~/data/transcripts/backups).
// One JSON line to stdout. Exit 0 when done, 75 when the NAS window or a missing share stopped it,
// 2 for a --day that is refused (not a real date, after tomorrow, or a copy before today), 1 on any
// other error.
import { Database } from "bun:sqlite";
import {
  chmodSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, join } from "node:path";
import { parseArgs } from "node:util";
import { HttpError } from "./errors.ts";
import { type Covered, exportJsonl, rebuildJsonl, textHash } from "./export.ts";
import { type Sha256, sha256Hex } from "./record.ts";
import { Share } from "./share.ts";

/// The share removes a SQLite copy only when its day is more than this many days before the new
/// day and it is not one of this many newest copies.
const KEEP_ON_SHARE = 30;
/// How long a read of the live database waits for a writer's lock.
const BUSY_TIMEOUT_MS = 5000;
const KEEP_LOCAL = 7;
const TABLES = ["recordings", "transcriptions", "cleanups", "audio", "devices"] as const;
/// The primary key columns of each table, for the restore check.
const KEYS = {
  recordings: ["recording_id"],
  transcriptions: ["transcription_id"],
  cleanups: ["cleanup_id"],
  audio: ["sha256"],
  devices: ["device_id", '"from"'],
} as const;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const COPY = /^transcripts-(\d{4}-\d{2}-\d{2})\.sqlite$/;
const MANIFEST = /^transcripts-(\d{4}-\d{2}-\d{2})\.json$/;
/// The folder, in db/ on the share and in HUB_BACKUP_DIR, for each file that a copy found at a
/// path it had to write. A file there is <name>.<UTC time>. No code removes one.
const SUPERSEDED = "superseded";
const SUPERSEDED_MANIFEST = /^transcripts-\d{4}-\d{2}-\d{2}\.json\.\d{8}T\d{6}Z$/;

/// A real calendar date, YYYY-MM-DD.
type Day = string & { readonly __brand: "Day" };
type Table = (typeof TABLES)[number];
type Counts = Record<Table, number>;
type FileEntry = { name: string; sha256: Sha256; bytes: number };
type Jsonl = FileEntry & { lines: number };
/// A manifest that cp2 wrote has devices in counts, a jsonl and a rest entry, and the snapshot's
/// text hash. Older ones have none of them.
type Manifest = {
  name: string;
  sha256: Sha256;
  bytes: number;
  created_at: string;
  counts: Partial<Counts>;
  text_sha256?: string;
  jsonl?: Jsonl;
  rest?: FileEntry;
};

const home = homedir();
const env = (name: string, fallback: string) => process.env[name] || fallback;
const dbPath = env("HUB_DB", join(home, "data/transcripts/transcripts.sqlite"));
const localDir = env("HUB_BACKUP_DIR", join(home, "data/transcripts/backups"));
const share = new Share(env("HUB_SHARE", join(home, "mnt/nas-transcripts")), () => new Date());

const { values } = parseArgs({
  options: {
    day: { type: "string" },
    "restore-check": { type: "boolean", default: false },
    "jsonl-check": { type: "boolean", default: false },
  },
  strict: true,
});

/// The date on this machine's clock, YYYY-MM-DD.
const localDay = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

const daysOf = (names: string[], pattern: RegExp) =>
  names.map((n) => pattern.exec(n)?.[1]).filter((d): d is string => d !== undefined);

/// Whether text is YYYY-MM-DD and a date of the calendar: 2026-11-31 is not.
function isDay(text: string): text is Day {
  if (!DAY.test(text)) return false;
  const ms = Date.parse(`${text}T00:00:00Z`);
  return Number.isFinite(ms) && new Date(ms).toISOString().slice(0, 10) === text;
}

/// The day n days before a day.
const daysBefore = (day: Day, n: number) =>
  new Date(Date.parse(`${day}T00:00:00Z`) - n * 86_400_000).toISOString().slice(0, 10);

const entryOf = (name: string, bytes: Uint8Array): FileEntry => ({
  name,
  sha256: sha256Hex(bytes),
  bytes: bytes.length,
});

/// The text hash of a database file.
function textHashOf(path: string): string {
  const db = new Database(path, { readonly: true, strict: true });
  try {
    return textHash(db);
  } finally {
    db.close();
  }
}

function counts(db: Database): Counts {
  const one = (table: string) =>
    db.query<{ n: number }, []>(`select count(*) n from ${table}`).get()?.n ?? 0;
  return Object.fromEntries(TABLES.map((t) => [t, one(t)])) as Counts;
}

/// Open a copy read-only, refuse it unless integrity_check says ok, and return its row counts.
function checkCopy(path: string): Counts {
  const db = new Database(path, { readonly: true, strict: true });
  try {
    const rows = db.query<{ integrity_check: string }, []>("pragma integrity_check").all();
    if (rows.length !== 1 || rows[0]?.integrity_check !== "ok")
      throw new Error(
        `${path} fails the integrity check: ${rows
          .slice(0, 3)
          .map((r) => r.integrity_check)
          .join("; ")}`,
      );
    return counts(db);
  } finally {
    db.close();
  }
}

/// Refuse a database file unless its keyword index agrees with the cleanups table: the FTS5
/// integrity-check with a rank of 1 compares the index with its external content table. The command
/// is an INSERT, so the file opens read-write. It changes no row.
function checkKeywordIndex(path: string) {
  const db = new Database(path, { strict: true });
  try {
    db.run("INSERT INTO cleanups_fts(cleanups_fts, rank) VALUES ('integrity-check', 1)");
  } catch (error) {
    throw new Error(
      `${path} fails the keyword index check: ${error instanceof Error ? error.message : String(error)}`,
    );
  } finally {
    db.close();
  }
}

const readManifest = async (relative: string) =>
  JSON.parse(new TextDecoder().decode(await share.read(relative))) as Manifest;

/// Every manifest on the share, oldest day first.
async function manifests(): Promise<{ day: string; manifest: Manifest }[]> {
  const out = [];
  for (const day of daysOf(await share.list("db"), MANIFEST).sort())
    out.push({ day, manifest: await readManifest(`db/transcripts-${day}.json`) });
  return out;
}

/// The highest count of each table in any manifest.
function highest(all: { manifest: Manifest }[]): Partial<Counts> {
  const top: Partial<Counts> = {};
  for (const { manifest } of all)
    for (const t of TABLES) {
      const n = manifest.counts[t];
      if (n !== undefined && n > (top[t] ?? -1)) top[t] = n;
    }
  return top;
}

/// Every manifest that a copy moved to db/superseded. Its counts stay on record.
async function supersededManifests(): Promise<{ manifest: Manifest }[]> {
  const out = [];
  for (const name of (await share.list(`db/${SUPERSEDED}`)).sort())
    if (SUPERSEDED_MANIFEST.test(name))
      out.push({ manifest: await readManifest(`db/${SUPERSEDED}/${name}`) });
  return out;
}

/// The tables with a count below the highest count in any manifest.
function drops(rowCounts: Counts, top: Partial<Counts>): string[] {
  const out: string[] = [];
  for (const t of TABLES) {
    const high = top[t];
    if (high !== undefined && rowCounts[t] < high)
      out.push(`${t} has ${rowCounts[t]} rows, below the ${high} of an earlier manifest`);
  }
  return out;
}

/// The reasons this copy must not be written: a count below the highest count in any manifest, or
/// a table row that the JSONL and rest file do not hold.
function problems(rowCounts: Counts, top: Partial<Counts>, covered: Covered): string[] {
  const out = drops(rowCounts, top);
  for (const t of TABLES)
    if (covered[t] !== rowCounts[t])
      out.push(`the JSONL and rest file hold ${covered[t]} of the ${rowCounts[t]} ${t} rows`);
  if (covered.lines !== rowCounts.recordings)
    out.push(`the JSONL has ${covered.lines} lines for ${rowCounts.recordings} recordings`);
  return out;
}

/// The row counts of the live database, from one read transaction.
function liveCounts(): Counts {
  const live = new Database(dbPath, { readonly: true, strict: true });
  try {
    live.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
    return live.transaction(() => counts(live))();
  } finally {
    live.close();
  }
}

/// Let one copy run at a time on this machine: an exclusive transaction on a lock file in
/// HUB_BACKUP_DIR. The system drops the lock when the process ends, however it ends. A second run
/// throws at once. The lock file stays empty, and its journal stays in memory, so a killed copy
/// leaves no journal file.
function lockCopies(): Database {
  const path = join(localDir, ".backup-lock.sqlite");
  const lock = new Database(path, { create: true });
  try {
    lock.run("PRAGMA busy_timeout = 0");
    lock.run("PRAGMA journal_mode = MEMORY");
    lock.run("BEGIN EXCLUSIVE");
  } catch (error) {
    lock.close();
    throw new Error(
      `another copy holds the lock ${path}: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  return lock;
}

/// The UTC time in a superseded file name, such as 20261118T182301Z.
const stampOf = (d: Date) => d.toISOString().replace(/[-:]|\.\d{3}/g, "");

/// Move a file in HUB_BACKUP_DIR to its superseded folder. A hard link, then the removal of the
/// old name: the link fails when the target exists, so the move never replaces a file.
function supersedeLocal(path: string, stamp: string): string {
  const folder = join(localDir, SUPERSEDED);
  mkdirSync(folder, { recursive: true, mode: 0o700 });
  const to = join(folder, `${basename(path)}.${stamp}`);
  linkSync(path, to);
  rmSync(path);
  return to;
}

/// Move the share file at a db/ path, whose SHA-256 is sha, to db/superseded, and read it back
/// there. Share.move never replaces a file.
async function supersedeOnShare(relative: string, sha: Sha256, stamp: string): Promise<string> {
  const to = `db/${SUPERSEDED}/${basename(relative)}.${stamp}`;
  await share.move(relative, to);
  if ((await share.hash(to)) !== sha || (await share.hash(relative)) !== null)
    throw new Error(`the move of ${relative} to ${to} did not hold. Nothing is written`);
  return to;
}

async function backup(day: Day) {
  mkdirSync(localDir, { recursive: true, mode: 0o700 });
  chmodSync(localDir, 0o700);
  const lock = lockCopies();
  try {
    return await copy(day);
  } finally {
    lock.close();
  }
}

async function copy(day: Day) {
  const name = `transcripts-${day}.sqlite`;
  const jsonlName = `transcripts-${day}.jsonl.gz`;
  const restName = `transcripts-${day}.rest.json.gz`;
  const manifestPath = `db/transcripts-${day}.json`;
  const before = await manifests();
  const top = highest([...before, ...(await supersededManifests())]);
  // The live counts come before the "exists" answer, so a drop exits 1 on every run of the day.
  const dropped = drops(liveCounts(), top);
  if (dropped.length) throw new Error(`nothing is written or pruned: ${dropped.join("; ")}`);
  const done = before.find((m) => m.day === day)?.manifest;
  if (
    done?.jsonl &&
    done.rest &&
    done.text_sha256 &&
    (await share.hash(`db/${name}`)) === done.sha256 &&
    (await share.hash(`db/${done.jsonl.name}`)) === done.jsonl.sha256 &&
    (await share.hash(`db/${done.rest.name}`)) === done.rest.sha256
  )
    return { event: "backup", day, result: "exists", sha256: done.sha256 };

  // The snapshot and its export go to a temp folder of this run alone. No existing file changes
  // until every check passes.
  const folder = mkdtempSync(join(localDir, ".run-"));
  const temp = join(folder, name);
  const jsonlTemp = join(folder, jsonlName);
  const restTemp = join(folder, restName);
  try {
    const live = new Database(dbPath, { readonly: true });
    try {
      live.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
      live.run("VACUUM INTO ?", [temp]);
    } finally {
      live.close();
    }
    chmodSync(temp, 0o600);
    const rowCounts = checkCopy(temp);
    const text_sha256 = textHashOf(temp);
    const covered = await exportJsonl(temp, jsonlTemp, restTemp);

    // A drop or a gap refuses the copy before any write, so the highest counts stay on record and
    // every earlier file stays as it was.
    const found = problems(rowCounts, top, covered);
    if (found.length) throw new Error(`nothing is written or pruned: ${found.join("; ")}`);

    const bytes = readFileSync(temp);
    const sha = sha256Hex(bytes);
    const jsonlBytes = readFileSync(jsonlTemp);
    const jsonl: Jsonl = { ...entryOf(jsonlName, jsonlBytes), lines: covered.lines };
    const restBytes = readFileSync(restTemp);
    const rest = entryOf(restName, restBytes);
    const manifest: Manifest = {
      name,
      sha256: sha,
      bytes: bytes.length,
      created_at: new Date().toISOString(),
      counts: rowCounts,
      text_sha256,
      jsonl,
      rest,
    };
    const text = new TextEncoder().encode(`${JSON.stringify(manifest, null, 1)}\n`);

    // Read what each day path holds now. A path that holds the new bytes is kept as it is.
    const files = [
      { path: `db/${name}`, bytes, sha },
      { path: `db/${jsonlName}`, bytes: jsonlBytes, sha: jsonl.sha256 },
      { path: `db/${restName}`, bytes: restBytes, sha: rest.sha256 },
      { path: manifestPath, bytes: text, sha: sha256Hex(text) },
    ];
    const stale = [];
    for (const file of files) {
      const held = await share.hash(file.path);
      if (held !== file.sha) stale.push({ ...file, held });
    }
    const local = join(localDir, name);
    const localHeld = existsSync(local) ? sha256Hex(readFileSync(local)) : null;

    // Every move comes before the first write, and the manifest moves first: a failed move stops
    // the run with no write, and a manifest in db/ always names the files beside it.
    const stamp = stampOf(new Date());
    const superseded: string[] = [];
    for (const file of [...stale].reverse())
      if (file.held !== null) superseded.push(await supersedeOnShare(file.path, file.held, stamp));
    if (localHeld !== null && localHeld !== sha) superseded.push(supersedeLocal(local, stamp));

    // Each write goes to a path that holds no file. linkSync and putNewFile fail when one does.
    if (localHeld !== sha) linkSync(temp, local);
    for (const file of stale) await share.putNewFile(file.path, file.bytes, file.sha);

    // Only SQLite copies go, and only of a day with a manifest: on the share those older than 30
    // days that are not among the newest 30, in HUB_BACKUP_DIR those that are not among the newest
    // 7. Manifests, JSONL and rest files stay, and so does every file in a superseded folder. The
    // share keeps each SQLite copy whose day has no JSONL and rest file on the share with the
    // sha256 its manifest lists: then that copy is the only restorable copy of its day.
    const manifested = new Set(before.map((m) => m.day));
    const listed = new Map(before.map((m) => [m.day, m.manifest]));
    const oldest = daysBefore(day, KEEP_ON_SHARE);
    const candidates = daysOf(await share.list("db"), COPY)
      .sort()
      .reverse()
      .slice(KEEP_ON_SHARE)
      .filter((d) => d < oldest && d !== day);
    const pruned: string[] = [];
    for (const d of candidates) {
      const m = listed.get(d);
      if (!m?.jsonl || !m.rest) continue;
      if ((await share.hash(`db/${m.jsonl.name}`)) !== m.jsonl.sha256) continue;
      if ((await share.hash(`db/${m.rest.name}`)) !== m.rest.sha256) continue;
      pruned.push(d);
    }
    for (const d of pruned) await share.remove(`db/transcripts-${d}.sqlite`);
    const localDays = daysOf(readdirSync(localDir), COPY).sort().reverse();
    const prunedLocal = localDays.slice(KEEP_LOCAL).filter((d) => d !== day && manifested.has(d));
    for (const d of prunedLocal) rmSync(join(localDir, `transcripts-${d}.sqlite`), { force: true });

    return {
      event: "backup",
      day,
      result: stale.some((file) => file.path === `db/${name}`) ? "written" : "kept",
      sha256: sha,
      bytes: bytes.length,
      counts: rowCounts,
      text_sha256,
      jsonl,
      rest,
      superseded,
      pruned,
      pruned_local: prunedLocal,
    };
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
}

/// Restore one day's copy, or without a day the newest copy, and check it.
async function restoreCheck(only?: Day) {
  const day =
    only ??
    daysOf(await share.list("db"), MANIFEST)
      .sort()
      .at(-1);
  if (!day) throw new Error("the share holds no database copy with a manifest");
  const manifest = await readManifest(`db/transcripts-${day}.json`);
  const bytes = await share.read(`db/${manifest.name}`);
  const sha = sha256Hex(bytes);
  if (sha !== manifest.sha256 || bytes.length !== manifest.bytes)
    throw new Error(`db/${manifest.name} on the share does not match its manifest`);

  const dir = mkdtempSync(join(tmpdir(), "transcripts-restore-"));
  try {
    const path = join(dir, manifest.name);
    writeFileSync(path, bytes, { mode: 0o600 });
    const restored = checkCopy(path);
    checkKeywordIndex(path);
    // A manifest from before cp2 has no devices count.
    for (const t of TABLES)
      if (manifest.counts[t] !== undefined && restored[t] !== manifest.counts[t])
        throw new Error(
          `the restored ${t} count ${restored[t]} is not the manifest's ${manifest.counts[t]}`,
        );
    // A read-only main database attaches the live one read-only too.
    const db = new Database(path, { readonly: true, strict: true });
    try {
      db.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
      db.run("ATTACH DATABASE ? AS live", [dbPath]);
      const missing = Object.fromEntries(
        TABLES.map((t) => [
          t,
          db
            .query<{ n: number }, []>(
              `select count(*) n from main.${t} c where not exists (select 1 from live.${t} l where ${KEYS[t].map((k) => `l.${k} = c.${k}`).join(" and ")})`,
            )
            .get()?.n ?? 0,
        ]),
      ) as Counts;
      const liveCounts = Object.fromEntries(
        TABLES.map((t) => [
          t,
          db.query<{ n: number }, []>(`select count(*) n from live.${t}`).get()?.n ?? 0,
        ]),
      ) as Counts;
      if (TABLES.some((t) => missing[t] > 0))
        throw new Error(
          `rows of the copy are missing in the live database: ${JSON.stringify(missing)}`,
        );
      return {
        event: "restore_check",
        day,
        result: "ok",
        sha256: sha,
        bytes: bytes.length,
        counts: restored,
        live: liveCounts,
        keyword_index: "ok",
      };
    } finally {
      db.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/// Read a day's JSONL and rest file from the share, check them against the manifest, rebuild them
/// into an empty database in a temp folder, and check the rebuilt counts against the manifest.
async function rebuildDay(day: string, manifest: Manifest) {
  const { jsonl, rest } = manifest;
  if (!jsonl || !rest) throw new Error(`the manifest of ${day} has no JSONL and rest file`);
  const dir = mkdtempSync(join(tmpdir(), "transcripts-jsonl-"));
  try {
    const paths = [];
    for (const entry of [jsonl, rest]) {
      const bytes = await share.read(`db/${entry.name}`);
      if (sha256Hex(bytes) !== entry.sha256 || bytes.length !== entry.bytes)
        throw new Error(`db/${entry.name} on the share does not match its manifest`);
      const path = join(dir, entry.name);
      writeFileSync(path, bytes, { mode: 0o600 });
      paths.push(path);
    }
    const [gz = "", restGz = ""] = paths;
    const path = join(dir, "rebuilt.sqlite");
    const covered = await rebuildJsonl(gz, restGz, path);
    if (covered.lines !== jsonl.lines)
      throw new Error(`the JSONL has ${covered.lines} lines, not the manifest's ${jsonl.lines}`);
    const rebuilt = checkCopy(path);
    checkKeywordIndex(path);
    const off = TABLES.filter((t) => rebuilt[t] !== manifest.counts[t]);
    if (off.length)
      throw new Error(
        `the rebuilt counts differ from the manifest's in ${off.join(", ")}: ${JSON.stringify(rebuilt)}`,
      );
    const db = new Database(path, { readonly: true, strict: true });
    try {
      return {
        jsonl_sha256: jsonl.sha256,
        lines: covered.lines,
        counts: rebuilt,
        text_sha256: textHash(db),
        keyword_index: "ok",
      };
    } finally {
      db.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/// Rebuild one day's JSONL and check it against its own manifest: what hub-run runs after the
/// copy, so a live write after the copy cannot fail it.
async function jsonlDayCheck(day: Day) {
  const manifest = await readManifest(`db/transcripts-${day}.json`);
  if (!manifest.text_sha256) throw new Error(`the manifest of ${day} has no text hash`);
  const result = await rebuildDay(day, manifest);
  if (result.text_sha256 !== manifest.text_sha256)
    throw new Error("the rebuilt text hash is not the manifest's text hash");
  return { event: "jsonl_check", against: "manifest", day, result: "ok", ...result };
}

/// Rebuild the newest JSONL whose counts and text hash are the live database's. Tries each
/// manifest with the live counts, newest first, and fails only when none matches.
async function jsonlLiveCheck() {
  // The live counts and text hash from one read transaction.
  const liveDb = new Database(dbPath, { readonly: true, strict: true });
  let live: { counts: Counts; text_sha256: string };
  try {
    liveDb.run(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
    live = liveDb.transaction(() => ({ counts: counts(liveDb), text_sha256: textHash(liveDb) }))();
  } finally {
    liveDb.close();
  }
  const candidates = (await manifests())
    .reverse()
    .filter(
      (m) => m.manifest.jsonl && TABLES.every((t) => m.manifest.counts[t] === live.counts[t]),
    );
  const misses: string[] = [];
  for (const { day, manifest } of candidates) {
    if (manifest.text_sha256 !== undefined && manifest.text_sha256 !== live.text_sha256) {
      misses.push(`${day}: its text hash is not the live one`);
      continue;
    }
    try {
      const result = await rebuildDay(day, manifest);
      if (result.text_sha256 === live.text_sha256)
        return { event: "jsonl_check", against: "live", day, result: "ok", ...result };
      misses.push(`${day}: the rebuilt text hash is not the live one`);
    } catch (error) {
      // The NAS window or a missing share stops the check (exit 75). Any other error skips the day.
      if (error instanceof HttpError) throw error;
      misses.push(`${day}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  throw new Error(
    `no JSONL on the share matches the live counts ${JSON.stringify(live.counts)} and text hash${misses.length ? `: ${misses.join("; ")}` : ""}`,
  );
}

const event = values["jsonl-check"]
  ? "jsonl_check"
  : values["restore-check"]
    ? "restore_check"
    : "backup";
const say = (line: Record<string, unknown>) =>
  process.stdout.write(`${JSON.stringify({ time: new Date().toISOString(), ...line })}\n`);
function refuse(error: string): never {
  say({ event, result: "refused", error });
  process.exit(2);
}
// The day is checked before any read of the share. A --day after tomorrow on this clock would keep
// a future manifest forever, and a copy of a day before today would write a past day again.
const today = localDay(new Date());
const tomorrow = localDay(new Date(Date.now() + 86_400_000));
const day = values.day ?? today;
if (!isDay(day)) refuse(`--day ${day} is not a real YYYY-MM-DD date`);
if (day > tomorrow) refuse(`--day ${day} is after tomorrow, ${tomorrow}`);
if (event === "backup" && day < today)
  refuse(`--day ${day} is before today, ${today}. A copy never writes a past day again`);
try {
  say(
    event === "jsonl_check"
      ? values.day === undefined
        ? await jsonlLiveCheck()
        : await jsonlDayCheck(day)
      : event === "restore_check"
        ? await restoreCheck(values.day === undefined ? undefined : day)
        : await backup(day),
  );
  process.exit(0);
} catch (error) {
  const stopped = error instanceof HttpError && error.status === 503;
  say({
    event,
    result: stopped ? "stopped" : "failed",
    error: (error instanceof Error ? error.message : String(error)).slice(0, 300),
  });
  process.exit(stopped ? 75 : 1);
}
