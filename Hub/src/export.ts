// The JSONL export of the transcripts database, and its rebuild into an empty database.
// One line per recording, in recordings rowid order:
//   { recording, device, transcriptions, cleanups, audio }
// recording: every column of the recordings row. device: the devices row of recording.device_id
// with the latest owner period that starts at or before recorded_at, or null when recorded_at is
// NULL or no period starts by then (the export never guesses a period). transcriptions and
// cleanups: every row of the recording, in rowid order. audio: the audio row of
// recording.audio_sha256, or null for a text-only take. Each row keeps every column, so a column
// that schema.sql adds later goes into the export with no change here.
// U+2028 and U+2029 are written as \u2028 and \u2029, so a line holds no character that a line
// reader can take as a line end.
// The rest file, a gzip JSON object { devices, audio }, holds every devices and audio row that no
// recording line holds, so the two files together hold every row of the five tables.
// The rebuild needs only the two files and schema.sql. It restores devices, audio, recordings,
// transcriptions and cleanups, and the cleanups_ai trigger fills cleanups_fts again.
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import {
  closeSync,
  createReadStream,
  createWriteStream,
  existsSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { createGunzip, createGzip, gunzipSync, gzipSync } from "node:zlib";

type Value = string | number | null;
type Row = Record<string, Value>;
export type JsonlLine = {
  recording: Row;
  device: Row | null;
  transcriptions: Row[];
  cleanups: Row[];
  audio: Row | null;
};
/// The rows that no recording line holds.
export type Rest = { devices: Row[]; audio: Row[] };
/// The rows that a JSONL file and its rest file hold, per table, with each devices and audio row once.
export type Covered = {
  lines: number;
  devices: number;
  audio: number;
  recordings: number;
  transcriptions: number;
  cleanups: number;
};

export const SCHEMA = new URL("../schema.sql", import.meta.url);

const deviceKey = (row: Row) => JSON.stringify([row.device_id ?? null, row.from ?? null]);
const audioKey = (row: Row) => JSON.stringify([row.sha256 ?? null]);

/// A JSON line with U+2028 and U+2029 escaped. They can only occur inside JSON strings.
const jsonLine = (v: unknown) =>
  `${JSON.stringify(v).replace(/[\u2028\u2029]/g, (c) => (c === "\u2028" ? "\\u2028" : "\\u2029"))}\n`;

const emptyCovered = (): Covered => ({
  lines: 0,
  devices: 0,
  audio: 0,
  recordings: 0,
  transcriptions: 0,
  cleanups: 0,
});

/// The lines of the export, read one recording at a time from the database. Adds the key of each
/// devices and audio row that a line holds to devices and audios.
function* lines(
  db: Database,
  covered: Covered,
  devices: Set<string>,
  audios: Set<string>,
): Generator<string> {
  // "from" <= NULL is NULL, so a NULL recorded_at selects no period.
  const device = db.query<Row, [Value, Value]>(
    'select * from devices where device_id = ? and "from" <= ? order by "from" desc limit 1',
  );
  const transcriptions = db.query<Row, [Value]>(
    "select * from transcriptions where recording_id = ? order by rowid",
  );
  const cleanups = db.query<Row, [Value]>(
    "select * from cleanups where recording_id = ? order by rowid",
  );
  const audio = db.query<Row, [Value]>("select * from audio where sha256 = ?");
  for (const recording of db.query<Row, []>("select * from recordings order by rowid").iterate()) {
    const id = recording.recording_id ?? null;
    const sha = recording.audio_sha256 ?? null;
    const line: JsonlLine = {
      recording,
      device: device.get(recording.device_id ?? null, recording.recorded_at ?? null),
      transcriptions: transcriptions.all(id),
      cleanups: cleanups.all(id),
      audio: sha === null ? null : audio.get(sha),
    };
    if (line.device) devices.add(deviceKey(line.device));
    if (line.audio) audios.add(audioKey(line.audio));
    covered.lines += 1;
    covered.recordings += 1;
    covered.transcriptions += line.transcriptions.length;
    covered.cleanups += line.cleanups.length;
    yield jsonLine(line);
  }
}

/// Write the export of the database at dbPath to a new gzip JSONL file at out, and the rows that no
/// line holds to a new gzip JSON file at restOut. Fails when out or restOut exists: it never
/// replaces a file. The lines stream from the database to the file, so only one recording is in
/// memory at a time.
export async function exportJsonl(dbPath: string, out: string, restOut: string): Promise<Covered> {
  const covered = emptyCovered();
  const devices = new Set<string>();
  const audios = new Set<string>();
  const db = new Database(dbPath, { readonly: true, strict: true });
  try {
    await pipeline(
      Readable.from(lines(db, covered, devices, audios)),
      createGzip(),
      createWriteStream(out, { flags: "wx", mode: 0o600 }),
    );
    const rest: Rest = {
      devices: db
        .query<Row, []>('select * from devices order by device_id, "from"')
        .all()
        .filter((r) => !devices.has(deviceKey(r))),
      audio: [],
    };
    for (const r of db.query<Row, []>("select * from audio order by sha256").iterate())
      if (!audios.has(audioKey(r))) rest.audio.push(r);
    writeFileSync(restOut, gzipSync(JSON.stringify(rest)), { flag: "wx", mode: 0o600 });
    covered.devices = devices.size + rest.devices.length;
    covered.audio = audios.size + rest.audio.length;
  } finally {
    db.close();
  }
  return covered;
}

const isValue = (v: unknown): v is Value =>
  v === null || typeof v === "string" || typeof v === "number";
const isRow = (v: unknown): v is Row =>
  typeof v === "object" && v !== null && !Array.isArray(v) && Object.values(v).every(isValue);
const isRows = (v: unknown): v is Row[] => Array.isArray(v) && v.every(isRow);

/// Parse one JSONL line, or throw when it does not have the export's shape.
function parseLine(text: string, at: number): JsonlLine {
  const v: unknown = JSON.parse(text);
  if (
    typeof v === "object" &&
    v !== null &&
    "recording" in v &&
    isRow(v.recording) &&
    "device" in v &&
    (v.device === null || isRow(v.device)) &&
    "transcriptions" in v &&
    isRows(v.transcriptions) &&
    "cleanups" in v &&
    isRows(v.cleanups) &&
    "audio" in v &&
    (v.audio === null || isRow(v.audio))
  )
    return {
      recording: v.recording,
      device: v.device,
      transcriptions: v.transcriptions,
      cleanups: v.cleanups,
      audio: v.audio,
    };
  throw new Error(`line ${at} of the JSONL is not a recording line`);
}

/// Parse a rest file, or throw when it does not have the rest shape.
function parseRest(bytes: Uint8Array): Rest {
  const v: unknown = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(gunzipSync(bytes)),
  );
  if (
    typeof v === "object" &&
    v !== null &&
    "devices" in v &&
    isRows(v.devices) &&
    "audio" in v &&
    isRows(v.audio)
  )
    return { devices: v.devices, audio: v.audio };
  throw new Error("the rest file is not a { devices, audio } object");
}

/// The columns of a table, to check each JSONL key before it goes into SQL.
function columnsOf(db: Database, table: string): Set<string> {
  return new Set(
    db
      .query<{ name: string }, []>(`select name from pragma_table_info('${table}')`)
      .all()
      .map((r) => r.name),
  );
}

/// Rebuild the gzip JSONL file at jsonl and the rest file at rest into a new database at out, made
/// from schema.sql. Refuses an out path that exists, or that has a -wal or -shm file beside it, and
/// touches none of them. Every insert fails on any constraint error.
/// The one row that the format repeats, a devices or audio row that two lines hold, goes in once,
/// and only when both copies are the same. Throws when a table's count after the rebuild is not
/// the count of rows that the files hold. A rebuild that fails removes the out file it made, with
/// its -wal and -shm files, so the same out path works again.
export async function rebuildJsonl(jsonl: string, rest: string, out: string): Promise<Covered> {
  const made = [out, `${out}-wal`, `${out}-shm`];
  const there = made.find((path) => existsSync(path));
  if (there !== undefined) throw new Error(`${there} exists. The rebuild needs a new path`);
  // "wx" fails when out exists, so every file removed below is one that this call made.
  closeSync(openSync(out, "wx", 0o600));
  try {
    return await fill(jsonl, rest, out);
  } catch (error) {
    for (const path of made) rmSync(path, { force: true });
    throw error;
  }
}

/// Fill the empty database file at out from the two files. The database is closed on return.
async function fill(jsonl: string, rest: string, out: string): Promise<Covered> {
  const db = new Database(out, { readwrite: true, strict: true });
  try {
    db.run(readFileSync(SCHEMA, "utf8"));
    const columns = Object.fromEntries(
      ["devices", "audio", "recordings", "transcriptions", "cleanups"].map((t) => [
        t,
        columnsOf(db, t),
      ]),
    );
    const statements = new Map<string, ReturnType<Database["query"]>>();
    const insert = (table: string, row: Row) => {
      const keys = Object.keys(row);
      const bad = keys.find((k) => !columns[table]?.has(k));
      if (bad !== undefined)
        throw new Error(`the JSONL has ${table}.${bad}, which is not a column`);
      const sql = `insert into ${table}(${keys.map((k) => `"${k}"`).join(", ")}) values (${keys.map(() => "?").join(", ")})`;
      let statement = statements.get(sql);
      if (!statement) {
        statement = db.query(sql);
        statements.set(sql, statement);
      }
      statement.run(...Object.values(row));
    };
    // The key of each devices and audio row put in so far, with the row's JSON.
    const seen = { devices: new Map<string, string>(), audio: new Map<string, string>() };
    const insertOnce = (table: "devices" | "audio", key: string, row: Row) => {
      const text = JSON.stringify(row);
      const before = seen[table].get(key);
      if (before === text) return;
      if (before !== undefined)
        throw new Error(`the JSONL holds two different ${table} rows with the key ${key}`);
      insert(table, row);
      seen[table].set(key, text);
    };
    const covered = emptyCovered();
    const take = (text: string) => {
      if (text === "") return;
      const line = parseLine(text, covered.lines + 1);
      if (line.device) insertOnce("devices", deviceKey(line.device), line.device);
      if (line.audio) insertOnce("audio", audioKey(line.audio), line.audio);
      insert("recordings", line.recording);
      for (const t of line.transcriptions) insert("transcriptions", t);
      for (const c of line.cleanups) insert("cleanups", c);
      covered.lines += 1;
      covered.recordings += 1;
      covered.transcriptions += line.transcriptions.length;
      covered.cleanups += line.cleanups.length;
    };
    db.run("BEGIN");
    try {
      // The rows that no line holds. The export never puts a row in both files.
      const extra = parseRest(readFileSync(rest));
      for (const d of extra.devices) insertOnce("devices", deviceKey(d), d);
      for (const a of extra.audio) insertOnce("audio", audioKey(a), a);
      // Lines end only at \n. pipeline() fails the rebuild on a read or gunzip error.
      await pipeline(
        createReadStream(jsonl),
        createGunzip(),
        async (source: AsyncIterable<Uint8Array>) => {
          const decoder = new TextDecoder("utf-8", { fatal: true });
          let tail = "";
          for await (const chunk of source) {
            const parts = (tail + decoder.decode(chunk, { stream: true })).split("\n");
            tail = parts.pop() ?? "";
            for (const part of parts) take(part);
          }
          take(tail + decoder.decode());
        },
      );
      db.run("COMMIT");
    } catch (error) {
      db.run("ROLLBACK");
      throw error;
    }
    covered.devices = seen.devices.size;
    covered.audio = seen.audio.size;
    const one = (table: string) =>
      db.query<{ n: number }, []>(`select count(*) n from ${table}`).get()?.n ?? 0;
    const off = (["devices", "audio", "recordings", "transcriptions", "cleanups"] as const).filter(
      (t) => one(t) !== covered[t],
    );
    if (off.length)
      throw new Error(`the rebuilt ${off.join(", ")} counts are not the counts the files hold`);
    // schema.sql turns on WAL. A WAL file with no -shm beside it cannot open read-only.
    db.run("PRAGMA journal_mode = DELETE");
    return covered;
  } finally {
    db.close();
  }
}

/// SHA-256 over the text columns of a database: each transcription's text and words and each
/// cleanup's status and text, with its ID, in ID order. The same rows give the same hash in any
/// database, whatever their rowids.
export function textHash(db: Database): string {
  const h = createHash("sha256");
  for (const r of db
    .query<Row, []>(
      "select transcription_id, text, words from transcriptions order by transcription_id",
    )
    .iterate())
    h.update(`${JSON.stringify(["t", r.transcription_id, r.text, r.words])}\n`);
  for (const r of db
    .query<Row, []>("select cleanup_id, status, text from cleanups order by cleanup_id")
    .iterate())
    h.update(`${JSON.stringify(["c", r.cleanup_id, r.status, r.text])}\n`);
  return h.digest("hex");
}
