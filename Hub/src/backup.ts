// The nightly copy of the transcripts database to the transcripts share, and its restore check.
//   bun src/backup.ts [--day YYYY-MM-DD]   copy the database to db/transcripts-<day>.sqlite on the share
//   bun src/backup.ts --restore-check      restore the newest copy from the share and check it
// hub-run runs the copy once a day from 03:00 local time, outside the NAS window.
// The copy: VACUUM INTO a local file (a consistent snapshot while the hub writes), an integrity
// check, then the share through a temp file, a rename and a read-back. The manifest
// db/transcripts-<day>.json (SHA-256, bytes, row counts) goes last, so a copy with a manifest is
// whole. The share keeps the newest 30 days of copies, and HUB_BACKUP_DIR keeps the newest 7.
// The restore check reads the newest copy back from the share into a temp folder. It checks the
// SHA-256 against the manifest, the integrity, the row counts and the keyword index, and that every
// row of the copy is in the live database (the hub never deletes a row).
// Settings: HUB_DB and HUB_SHARE (as main.ts), HUB_BACKUP_DIR (default ~/data/transcripts/backups).
// One JSON line to stdout. Exit 0 when done, 75 when the NAS window or a missing share stopped it,
// 1 on any other error.
import { Database } from "bun:sqlite";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { HttpError } from "./errors.ts";
import { type Sha256, sha256Hex } from "./record.ts";
import { Share } from "./share.ts";

const KEEP_ON_SHARE = 30;
const KEEP_LOCAL = 7;
const TABLES = ["recordings", "transcriptions", "cleanups", "audio"] as const;
/// The primary key of each table, for the restore check.
const KEYS = {
  recordings: "recording_id",
  transcriptions: "transcription_id",
  cleanups: "cleanup_id",
  audio: "sha256",
} as const;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const COPY = /^transcripts-(\d{4}-\d{2}-\d{2})\.sqlite$/;
const MANIFEST = /^transcripts-(\d{4}-\d{2}-\d{2})\.json$/;

type Counts = Record<(typeof TABLES)[number], number>;
type Manifest = { name: string; sha256: Sha256; bytes: number; created_at: string; counts: Counts };

const home = homedir();
const env = (name: string, fallback: string) => process.env[name] || fallback;
const dbPath = env("HUB_DB", join(home, "data/transcripts/transcripts.sqlite"));
const localDir = env("HUB_BACKUP_DIR", join(home, "data/transcripts/backups"));
const share = new Share(env("HUB_SHARE", join(home, "mnt/nas-transcripts")), () => new Date());

const { values } = parseArgs({
  options: {
    day: { type: "string" },
    "restore-check": { type: "boolean", default: false },
  },
  strict: true,
});

/// The date on this machine's clock, YYYY-MM-DD.
const localDay = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

const daysOf = (names: string[], pattern: RegExp) =>
  names.map((n) => pattern.exec(n)?.[1]).filter((d): d is string => d !== undefined);

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

const readManifest = async (relative: string) =>
  JSON.parse(new TextDecoder().decode(await share.read(relative))) as Manifest;

async function backup(day: string) {
  const name = `transcripts-${day}.sqlite`;
  const manifestPath = `db/transcripts-${day}.json`;
  if ((await share.list("db")).includes(`transcripts-${day}.json`)) {
    const done = await readManifest(manifestPath);
    if ((await share.hash(`db/${name}`)) === done.sha256)
      return { event: "backup", day, result: "exists", sha256: done.sha256 };
  }

  mkdirSync(localDir, { recursive: true, mode: 0o700 });
  chmodSync(localDir, 0o700);
  const temp = join(localDir, `.${name}.tmp`);
  rmSync(temp, { force: true });
  const live = new Database(dbPath, { readonly: true });
  try {
    live.run("VACUUM INTO ?", [temp]);
  } finally {
    live.close();
  }
  chmodSync(temp, 0o600);
  const rowCounts = checkCopy(temp);
  const bytes = readFileSync(temp);
  const sha = sha256Hex(bytes);
  renameSync(temp, join(localDir, name));

  const { wrote } = await share.putFile(`db/${name}`, bytes, sha);
  const manifest: Manifest = {
    name,
    sha256: sha,
    bytes: bytes.length,
    created_at: new Date().toISOString(),
    counts: rowCounts,
  };
  const text = new TextEncoder().encode(`${JSON.stringify(manifest, null, 1)}\n`);
  await share.putFile(manifestPath, text, sha256Hex(text));

  // Keep the newest days. A day's manifest goes before its copy, so a half-removed day has no
  // manifest and never counts as a copy. The day just written is never removed.
  const shareDays = [
    ...new Set(
      daysOf(await share.list("db"), /^transcripts-(\d{4}-\d{2}-\d{2})\.(?:sqlite|json)$/),
    ),
  ]
    .sort()
    .reverse();
  const pruned = shareDays.slice(KEEP_ON_SHARE).filter((d) => d !== day);
  for (const d of pruned) {
    await share.remove(`db/transcripts-${d}.json`);
    await share.remove(`db/transcripts-${d}.sqlite`);
  }
  const localDays = daysOf(readdirSync(localDir), COPY).sort().reverse();
  const prunedLocal = localDays.slice(KEEP_LOCAL).filter((d) => d !== day);
  for (const d of prunedLocal) rmSync(join(localDir, `transcripts-${d}.sqlite`), { force: true });

  return {
    event: "backup",
    day,
    result: wrote ? "written" : "kept",
    sha256: sha,
    bytes: bytes.length,
    counts: rowCounts,
    pruned,
    pruned_local: prunedLocal,
  };
}

async function restoreCheck() {
  const day = daysOf(await share.list("db"), MANIFEST)
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
    for (const t of TABLES)
      if (restored[t] !== manifest.counts[t])
        throw new Error(
          `the restored ${t} count ${restored[t]} is not the manifest's ${manifest.counts[t]}`,
        );
    // A read-only main database attaches the live one read-only too.
    const db = new Database(path, { readonly: true, strict: true });
    try {
      const found =
        db
          .query<{ n: number }, []>(
            "select count(*) n from cleanups_fts where cleanups_fts match 'the'",
          )
          .get()?.n ?? 0;
      if (found === 0) throw new Error("the restored keyword index finds no cleanup for 'the'");
      db.run("ATTACH DATABASE ? AS live", [dbPath]);
      const missing = Object.fromEntries(
        TABLES.map((t) => [
          t,
          db
            .query<{ n: number }, []>(
              `select count(*) n from main.${t} c where not exists (select 1 from live.${t} l where l.${KEYS[t]} = c.${KEYS[t]})`,
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
        keyword_hits_for_the: found,
      };
    } finally {
      db.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const event = values["restore-check"] ? "restore_check" : "backup";
const say = (line: Record<string, unknown>) =>
  process.stdout.write(`${JSON.stringify({ time: new Date().toISOString(), ...line })}\n`);
try {
  const day = values.day ?? localDay(new Date());
  if (!DAY.test(day)) throw new Error("--day must be YYYY-MM-DD");
  say(values["restore-check"] ? await restoreCheck() : await backup(day));
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
