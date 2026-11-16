// One-time post of the Wispr Flow rows that exist only in the import's flow.sqlite snapshot (the
// manifest's "flow-snapshot" entries), with the audio blob of each row and the keys importer.py wrote.
//   bun scripts/snapshot-audio.ts --import <transcripts-nas/import folder> [--log <file>]
// It opens flow-snapshot.sqlite read-only and writes each blob to a temp folder to make its FLAC.
// It stores no confirm: these rows have no archive folder to delete. When the archive later gets a
// folder for one of them, the daily sync posts that folder, and the hub keeps one copy of the audio.
// Log: one JSON line per row and one per run. Exit 0 when every row with audio is confirmed.
import { Database } from "bun:sqlite";
import { appendFileSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { sha256Hex } from "../../../Hub/src/record.ts";
import { textShas, wisprPost, wisprRowTexts } from "../src/archive.ts";
import { loadTarget } from "../src/config.ts";
import { HubClient, RecordRefused } from "../src/hub-client.ts";
import { assertClientWindow, confirmMismatches, flacAudio, message } from "../src/sync.ts";

const { values } = parseArgs({
  options: {
    import: { type: "string" },
    config: { type: "string", default: join(homedir(), ".config/transcriber-hub-client") },
    log: { type: "string", default: join(homedir(), "Library/Logs/transcriber-hub-snapshot.log") },
  },
  strict: true,
});
if (!values.import) throw new Error("pass --import <transcripts-nas/import folder>");

function log(line: Record<string, unknown>) {
  const text = `${JSON.stringify({ time: new Date().toISOString(), ...line })}\n`;
  appendFileSync(values.log, text, { mode: 0o600 });
  process.stdout.write(text);
}

type Entry = { data_from: string; recording_id: string; source_id: string };
const entries = (await readFile(join(values.import, "manifest.jsonl"), "utf8"))
  .split("\n")
  .slice(1)
  .filter(Boolean)
  .map((l) => JSON.parse(l) as Entry)
  .filter((e) => e.data_from === "flow-snapshot");

const COLUMNS =
  "asrText, formattedText, pastedText, serverFinalizedText, timestamp, status, app, language," +
  " detectedLanguage, duration, audio";
type Row = {
  asrText: string | null;
  formattedText: string | null;
  pastedText: string | null;
  serverFinalizedText: string | null;
  timestamp: string | null;
  status: string | null;
  app: string | null;
  language: string | null;
  detectedLanguage: string | null;
  duration: number | null;
  audio: Uint8Array | null;
};
const snap = new Database(join(values.import, "flow-snapshot.sqlite"), { readonly: true });
const byId = snap.query<Row, [string]>(
  `select ${COLUMNS} from History where transcriptEntityId = ?`,
);
const byRowid = snap.query<Row, [number]>(`select ${COLUMNS} from History where rowid = ?`);

const hub = new HubClient(await loadTarget(values.config));
const summary = { event: "run", rows: entries.length, no_audio: 0, confirmed: 0, failed: 0 };
try {
  for (const e of entries) {
    assertClientWindow(new Date());
    // importer.py snapshot_rows: a row without an ID has the key missing-id:flow.sqlite:<rowid>.
    const missing = /^missing-id:[^:]+:(\d+)$/.exec(e.source_id);
    const v = missing ? byRowid.get(Number(missing[1])) : byId.get(e.source_id);
    const base = { event: "row", recording_id: e.recording_id };
    if (!v) throw new Error(`the snapshot has no row for ${e.recording_id}`);
    if (!v.audio) {
      summary.no_audio++;
      log({ ...base, result: "no_audio" });
      continue;
    }
    const temp = await mkdtemp(join(tmpdir(), "transcriber-hub-snapshot-"));
    try {
      const wav = join(temp, "audio.wav");
      await writeFile(wav, v.audio);
      let a: Awaited<ReturnType<typeof flacAudio>>;
      try {
        a = await flacAudio(wav, sha256Hex(v.audio));
      } catch (error) {
        // One WAV that afconvert cannot read must not stop the rows after it.
        summary.failed++;
        log({ ...base, result: "failed", stage: "prepare", error: message(error) });
        continue;
      }
      // A 0-frame blob holds no audio. The import already holds the row's texts.
      if (!a) {
        summary.no_audio++;
        log({ ...base, result: "no_audio", frames: 0 });
        continue;
      }
      const post = wisprPost({
        recordingId: e.recording_id,
        timestamp: v.timestamp,
        status: v.status,
        durationSeconds: v.duration,
        app: v.app,
        language: v.language,
        detectedLanguage: v.detectedLanguage,
        ...wisprRowTexts(v),
      });
      const p = {
        post: { ...post, audio: a.audio },
        recordingId: e.recording_id,
        textSha256: textShas(post),
        flacSha: a.flacSha,
        flacBytes: a.flacBytes,
        channels: a.channels,
      };
      const facts = {
        source_sha256: a.audio.source_sha256,
        flac_sha256: a.flacSha,
        flac_bytes: a.flacBytes,
        channels: a.channels.channels,
        differing_channels: a.channels.differing,
        silent_channels: a.channels.silent,
      };
      assertClientWindow(new Date()); // preparation can end inside the window
      try {
        const mismatches = confirmMismatches(await hub.post(p.post), p);
        if (mismatches.length) {
          summary.failed++;
          log({ ...base, ...facts, result: "failed", stage: "confirm", mismatches });
        } else {
          summary.confirmed++;
          log({ ...base, ...facts, result: "confirmed", hub: hub.address });
        }
      } catch (error) {
        if (!(error instanceof RecordRefused)) throw error;
        summary.failed++;
        log({ ...base, ...facts, result: "failed", status: error.status, code: error.code });
      }
    } finally {
      await rm(temp, { recursive: true, force: true });
    }
  }
  log(summary);
} catch (error) {
  log({ ...summary, error: message(error) });
  process.exitCode = 1;
} finally {
  snap.close();
}
if (summary.failed) process.exitCode = 1;
