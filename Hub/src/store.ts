// The transcripts database (schema.sql, owned by the transcripts-nas Session). The hub never changes
// its tables. It writes each record in one BEGIN IMMEDIATE transaction with INSERT OR IGNORE, so a
// replay changes nothing, and the cleanups_ai and cleanups_au triggers keep cleanups_fts in step.
// A post whose texts differ from the stored rows of the same IDs (a take Transcriber processed
// again) updates those rows in place.
import { Database } from "bun:sqlite";
import { HttpError } from "./errors.ts";
import type { Confirm, DeviceId, RecordingId, Rows, Sha256 } from "./record.ts";
import { sha256Hex } from "./record.ts";

const TABLES = ["recordings", "audio", "transcriptions", "cleanups", "cleanups_fts"];

export function openStore(path: string): Database {
  const db = new Database(path, { strict: true });
  db.exec("PRAGMA foreign_keys = ON");
  db.exec("PRAGMA busy_timeout = 10000");
  const have = new Set(
    db
      .query<{ name: string }, []>("select name from sqlite_master where type in ('table')")
      .all()
      .map((r) => r.name),
  );
  const missing = TABLES.filter((t) => !have.has(t));
  if (missing.length) throw new Error(`${path} lacks the tables ${missing.join(", ")}`);
  return db;
}

export type Owner = { device_id: DeviceId; audio_sha256: Sha256 | null };

export function recordingOwner(db: Database, id: RecordingId): Owner | null {
  return db
    .query<Owner, [string]>("select device_id, audio_sha256 from recordings where recording_id = ?")
    .get(id);
}

/// 403 when the recording belongs to another device, 409 when it already has other audio.
export function assertWritable(db: Database, rows: Rows) {
  const owner = recordingOwner(db, rows.recording.recording_id);
  if (owner && owner.device_id !== rows.recording.device_id)
    throw new HttpError(403, "device_mismatch", "the recording belongs to another device");
  if (owner?.audio_sha256 && rows.audio && owner.audio_sha256 !== rows.audio.sha256)
    throw new HttpError(409, "audio_conflict", "the recording already has other audio");
}

/// Write one record. The ownership and audio checks run again inside the write lock, so two
/// devices that post the same new recording at once cannot both write under it.
export function writeRows(db: Database, rows: Rows) {
  db.transaction(() => {
    assertWritable(db, rows);
    const { recording: r, audio: a, transcription: t, cleanup: c } = rows;
    if (a)
      db.query(
        "insert or ignore into audio(sha256, source_sha256, bytes, source_bytes, sample_rate, frame_count, nas_path)" +
          " values (?, ?, ?, ?, ?, ?, ?)",
      ).run(
        a.sha256,
        a.source_sha256,
        a.bytes,
        a.source_bytes,
        a.sample_rate,
        a.frame_count,
        a.nas_path,
      );
    db.query(
      "insert or ignore into recordings(recording_id, recorded_at, device_id, mode, status, language, app," +
        " duration_seconds, audio_sha256) values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ).run(
      r.recording_id,
      r.recorded_at,
      r.device_id,
      r.mode,
      r.status,
      r.language,
      r.app,
      r.duration_seconds,
      r.audio_sha256,
    );
    // The import wrote recordings without audio. A later sync of the same take fills audio_sha256 once.
    if (a)
      db.query(
        "update recordings set audio_sha256 = ? where recording_id = ? and audio_sha256 is null",
      ).run(a.sha256, r.recording_id);
    if (t)
      db.query(
        "insert or ignore into transcriptions(transcription_id, recording_id, provider, model, model_version, settings," +
          " created_at, processing_seconds, detected_language, text) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      ).run(
        t.transcription_id,
        t.recording_id,
        t.provider,
        t.model,
        t.model_version,
        t.settings,
        t.created_at,
        t.processing_seconds,
        t.detected_language,
        t.text,
      );
    // The same take processed again: the row of these IDs takes the new text and its run details.
    if (t)
      db.query(
        "update transcriptions set model_version = ?, settings = ?, processing_seconds = ?," +
          " detected_language = ?, text = ? where transcription_id = ? and text is not ?",
      ).run(
        t.model_version,
        t.settings,
        t.processing_seconds,
        t.detected_language,
        t.text,
        t.transcription_id,
        t.text,
      );
    if (c)
      db.query(
        "insert or ignore into cleanups(cleanup_id, transcription_id, recording_id, engine, engine_version, model," +
          " model_sha256, prompt_sha256, created_at, status, text) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      ).run(
        c.cleanup_id,
        c.transcription_id,
        c.recording_id,
        c.engine,
        c.engine_version,
        c.model,
        c.model_sha256,
        c.prompt_sha256,
        c.created_at,
        c.status,
        c.text,
      );
    if (c)
      db.query(
        "update cleanups set engine = ?, engine_version = ?, model = ?, model_sha256 = ?, prompt_sha256 = ?," +
          " status = ?, text = ? where cleanup_id = ? and text is not ?",
      ).run(
        c.engine,
        c.engine_version,
        c.model,
        c.model_sha256,
        c.prompt_sha256,
        c.status,
        c.text,
        c.cleanup_id,
        c.text,
      );
    if (t || c)
      db.query("update recordings set status = ? where recording_id = ? and status is not ?").run(
        r.status,
        r.recording_id,
        r.status,
      );
  }).immediate();
}

const textHash = (row: { text: string } | null) => (row ? sha256Hex(row.text) : null);

/// The confirm, read from the stored rows: what the database holds, not what the post claimed.
export function confirmFor(db: Database, rows: Rows): Confirm {
  const id = rows.recording.recording_id;
  const owner = recordingOwner(db, id);
  const raw = rows.transcription
    ? db
        .query<{ text: string }, [string]>(
          "select text from transcriptions where transcription_id = ?",
        )
        .get(rows.transcription.transcription_id)
    : null;
  const clean = rows.cleanup
    ? db
        .query<{ text: string }, [string]>("select text from cleanups where cleanup_id = ?")
        .get(rows.cleanup.cleanup_id)
    : null;
  return {
    recording_id: id,
    flac_sha256: owner?.audio_sha256 ?? null,
    text_sha256: { raw: textHash(raw), clean: textHash(clean) },
  };
}

export type Stored = {
  audio_sha256: Sha256 | null;
  source_sha256: Sha256 | null;
  nas_path: string | null;
  raw: Sha256[];
  clean: Sha256[];
};

export function storedHashes(db: Database, id: RecordingId): Stored {
  const row = db
    .query<
      { audio_sha256: Sha256 | null; source_sha256: Sha256 | null; nas_path: string | null },
      [string]
    >(
      "select r.audio_sha256, a.source_sha256, a.nas_path from recordings r" +
        " left join audio a on a.sha256 = r.audio_sha256" +
        " where r.recording_id = ?",
    )
    .get(id);
  const texts = (table: string) =>
    db
      .query<{ text: string }, [string]>(
        `select text from ${table} where recording_id = ? order by rowid`,
      )
      .all(id)
      .map((r) => sha256Hex(r.text));
  return {
    audio_sha256: row?.audio_sha256 ?? null,
    source_sha256: row?.source_sha256 ?? null,
    nas_path: row?.nas_path ?? null,
    raw: texts("transcriptions"),
    clean: texts("cleanups"),
  };
}
