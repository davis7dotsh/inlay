// Read one archive record into the hub's post body, the way importer.py maps it, so a sync and the
// import write the same rows: a Transcriber record (~/Transcripts/records/transcriber/<id>/, as
// transcriber_rows) or a Wispr Flow record (~/Transcripts/records/wispr-flow/<id>/, as wispr_rows).
// It only reads the archive. It never writes, moves or deletes a file there.
import { readdir, readFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { NS, stamp, uuid5 } from "../../../Hub/src/ids.ts";
import { parseSha, sha256Hex, type RecordPost, type Sha256 } from "../../../Hub/src/record.ts";

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const o = (v: unknown): Obj => (isObj(v) ? v : {});

/// Field readers that refuse a wrong type, so a malformed metadata.json fails its record here.
function str(from: Obj, key: string): string {
  const v = from[key];
  if (typeof v !== "string") throw new Error(`${key} must be a string`);
  return v;
}
function strOrNull(from: Obj, key: string): string | null {
  const v = from[key];
  if (v === null || v === undefined) return null;
  if (typeof v !== "string") throw new Error(`${key} must be a string or null`);
  return v;
}
function numOrNull(from: Obj, key: string): number | null {
  const v = from[key];
  if (v === null || v === undefined) return null;
  if (typeof v !== "number") throw new Error(`${key} must be a number or null`);
  return v;
}
/// Python's `x.get(key) or fallback`.
const strOr = (from: Obj, key: string, fallback: string) => strOrNull(from, key) || fallback;

/// The WAV the record's audio comes from, as metadata.json lists it: the "original-audio" artifact
/// of a Transcriber record (not its "audio" inference WAV), the "audio" artifact of a Wispr Flow one.
export type SourceWav = { path: string; sha256: Sha256; bytes: number | null };

export type TextSha256 = { raw: Sha256 | null; clean: Sha256 | null };

/// One archive record: the post body without its audio, and what the confirm must hold.
export type ArchiveRecord = {
  dir: string;
  recordingId: string; // lowercase
  recordedAt: string | null; // stamp() form; null for a Wispr Flow row without a timestamp
  post: Omit<RecordPost, "audio">;
  sourceWav: SourceWav | null;
  textSha256: TextSha256;
};

export const SOURCES = ["transcriber", "wispr-flow"] as const;
export type Source = (typeof SOURCES)[number];

/// The source of a record folder: the name of the folder it sits in.
export function sourceOf(dir: string): Source {
  const s = basename(dirname(dir));
  if (s !== "transcriber" && s !== "wispr-flow") throw new Error(`not a record folder: ${dir}`);
  return s;
}

/// The record folders of every source, by path. A missing source folder holds no records.
export async function recordDirs(archiveRoot: string): Promise<string[]> {
  const out: string[] = [];
  for (const source of SOURCES) {
    const root = join(archiveRoot, "records", source);
    let entries;
    try {
      entries = await readdir(root, { withFileTypes: true });
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "ENOENT") continue;
      throw error;
    }
    for (const e of entries)
      if (e.isDirectory() && !e.name.startsWith(".")) out.push(join(root, e.name));
  }
  return out.sort();
}

/// The MacBook: importer.py stores it as the device of every Wispr Flow recording.
export const MACBOOK = "05d8dedd-c925-4924-8db9-45f3e7452d34";

/// importer.py wispr_recording_id: transcriptEntityId in lowercase, or uuid5 of the archiver key
/// (missing-id:<db>:<rowid>) when the row has no ID.
export function wisprRecordingId(sourceId: string): string {
  if (sourceId && !sourceId.startsWith("missing-id:")) return sourceId.toLowerCase();
  return uuid5(NS, `wispr|${sourceId}`);
}

/// The recording ID and stamped time of a record, from metadata.json only.
export async function readHead(
  dir: string,
): Promise<{ recordingId: string; recordedAt: string | null }> {
  const m = o(JSON.parse(await readFile(join(dir, "metadata.json"), "utf8")));
  if (sourceOf(dir) === "wispr-flow")
    return {
      recordingId: wisprRecordingId(str(m, "source_id")),
      recordedAt: stamp(strOrNull(m, "timestamp")),
    };
  const at = stamp(str(m, "timestamp"));
  if (!at) throw new Error("metadata.json has no timestamp");
  return { recordingId: str(m, "id").toLowerCase(), recordedAt: at };
}

/// The artifact of one kind that metadata.json lists, as a path inside the record folder.
function sourceWav(dir: string, m: Obj, kind: string): SourceWav | null {
  const artifacts = Array.isArray(m.artifacts) ? m.artifacts.map(o) : [];
  const a = artifacts.find((x) => x.kind === kind);
  if (!a) return null;
  return {
    path: join(dir, str(a, "path")),
    sha256: parseSha(a.sha256, `${kind} sha256`),
    bytes: numOrNull(a, "bytes"),
  };
}

export const textShas = (post: Omit<RecordPost, "audio">): TextSha256 => ({
  raw: post.transcription ? sha256Hex(post.transcription.text) : null,
  clean: post.cleanup ? sha256Hex(post.cleanup.text) : null,
});

export async function readRecord(dir: string): Promise<ArchiveRecord> {
  return sourceOf(dir) === "wispr-flow" ? readWispr(dir) : readTranscriber(dir);
}

/// The fields of one Wispr Flow take, from an archive folder or a flow.sqlite History row.
export type WisprFields = {
  recordingId: string;
  timestamp: string | null;
  status: string | null;
  durationSeconds: number | null;
  app: string | null;
  language: string | null;
  detectedLanguage: string | null;
  raw: string;
  clean: string;
};

/// importer.py wispr_rows: device the MacBook, provider and engine "Wispr Flow", model "unknown".
/// A missing timestamp goes as "", which the hub stamps to null, as the importer stores it.
export function wisprPost(f: WisprFields): Omit<RecordPost, "audio"> {
  const post: Omit<RecordPost, "audio"> = {
    recording: {
      recording_id: f.recordingId,
      recorded_at: f.timestamp ?? "",
      device_id: MACBOOK,
      mode: null,
      status: f.status || "unknown",
      language: f.language,
      app: f.app,
      duration_seconds: f.durationSeconds,
    },
    transcription: null,
    cleanup: null,
  };
  if (!(f.raw || f.clean)) return post;
  post.transcription = {
    provider: "Wispr Flow",
    model: "unknown",
    model_version: null,
    settings: {},
    processing_seconds: null,
    detected_language: f.detectedLanguage,
    text: f.raw,
  };
  if (f.clean)
    post.cleanup = {
      engine: "Wispr Flow",
      engine_version: null,
      model: "unknown",
      model_sha256: null,
      prompt_sha256: null,
      status: f.status,
      text: f.clean,
    };
  return post;
}

/// importer.py wispr_row_texts (archive.py): raw = asrText; clean = the first non-empty of
/// pastedText, serverFinalizedText, formattedText, asrText.
export function wisprRowTexts(v: Record<string, unknown>): { raw: string; clean: string } {
  const text = (k: string) => {
    const t = v[k];
    return typeof t === "string" ? t : "";
  };
  const key =
    ["pastedText", "serverFinalizedText", "formattedText", "asrText"].find((k) => text(k)) ??
    "formattedText";
  return { raw: text("asrText"), clean: text(key) };
}

async function readWispr(dir: string): Promise<ArchiveRecord> {
  const m = o(JSON.parse(await readFile(join(dir, "metadata.json"), "utf8")));
  const head = await readHead(dir);
  const ctx = o(m.context);
  const post = wisprPost({
    recordingId: head.recordingId,
    timestamp: strOrNull(m, "timestamp"),
    status: strOrNull(m, "status"),
    durationSeconds: numOrNull(m, "duration_seconds"),
    app: strOrNull(ctx, "app"),
    language: strOrNull(ctx, "language"),
    detectedLanguage: strOrNull(ctx, "detectedLanguage"),
    raw: await readFile(join(dir, "raw.txt"), "utf8"),
    clean: await readFile(join(dir, "clean.txt"), "utf8"),
  });
  return {
    dir,
    ...head,
    post,
    sourceWav: sourceWav(dir, m, "audio"),
    textSha256: textShas(post),
  };
}

async function readTranscriber(dir: string): Promise<ArchiveRecord> {
  const m = o(JSON.parse(await readFile(join(dir, "metadata.json"), "utf8")));
  const head = await readHead(dir);
  const versions = Array.isArray(m.source_versions) ? m.source_versions : [];
  const lastPath = o(versions.at(-1)).path;
  const v: Obj =
    typeof lastPath === "string" ? o(JSON.parse(await readFile(join(dir, lastPath), "utf8"))) : {};
  const ctx = o(m.context);
  const raw = await readFile(join(dir, "raw.txt"), "utf8");
  const clean = await readFile(join(dir, "clean.txt"), "utf8");

  const post: Omit<RecordPost, "audio"> = {
    recording: {
      recording_id: head.recordingId,
      recorded_at: str(m, "timestamp"),
      device_id: strOrNull(o(ctx.device), "id"),
      mode: strOrNull(m, "mode"),
      status: str(m, "status"),
      language: strOrNull(ctx, "language"),
      app: strOrNull(ctx, "app"),
      duration_seconds: numOrNull(m, "duration_seconds"),
    },
    transcription: null,
    cleanup: null,
  };

  if (raw || clean) {
    const sp = o(v.speech);
    const tp = o(v.textProcessing);
    const prefs = o(o(v.settings).preferences);
    const settings: Obj = {};
    for (const k of ["language", "vocabulary"]) if (k in prefs) settings[k] = prefs[k];
    if (sp.fallbackReason) settings.fallbackReason = sp.fallbackReason;
    post.transcription = {
      provider: strOr(sp, "backend", "unknown"),
      model: strOr(sp, "modelID", "unknown"),
      model_version: strOrNull(sp, "engineVersion"),
      settings,
      processing_seconds: numOrNull(sp, "processingSeconds"),
      detected_language: strOrNull(v, "detectedLanguage"),
      text: raw,
    };
    if (clean) {
      const prompt = tp.enabled ? strOrNull(prefs, "proofreadingPrompt") : null;
      post.cleanup = {
        engine: "Transcriber",
        engine_version: strOrNull(tp, "engineVersion"),
        model: strOr(tp, "modelID", "none"),
        model_sha256: strOrNull(tp, "modelSHA256"),
        prompt_sha256: prompt ? sha256Hex(prompt) : null,
        status: strOrNull(tp, "status"),
        text: clean,
      };
    }
  }

  return {
    dir,
    ...head,
    post,
    sourceWav: sourceWav(dir, m, "original-audio"),
    textSha256: textShas(post),
  };
}
