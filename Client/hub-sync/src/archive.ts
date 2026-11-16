// Read one Transcriber archive record (~/Transcripts/records/transcriber/<id>/) into the hub's post
// body, the way importer.py transcriber_rows maps it, so a sync and the import write the same rows.
// It only reads the archive. It never writes, moves or deletes a file there.
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { stamp } from "../../../Hub/src/ids.ts";
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

/// The original WAV that metadata.json lists as the "original-audio" artifact.
export type OriginalAudio = { path: string; sha256: Sha256; bytes: number | null };

/// One archive record: the post body without its audio, and what the confirm must hold.
export type ArchiveRecord = {
  dir: string;
  recordingId: string; // lowercase
  recordedAt: string; // stamp() form, for --since
  post: Omit<RecordPost, "audio">;
  originalAudio: OriginalAudio | null;
  textSha256: { raw: Sha256 | null; clean: Sha256 | null };
};

export const transcriberRecords = (archiveRoot: string) =>
  join(archiveRoot, "records", "transcriber");

/// The record folders, by name. A folder name is the lowercase recording ID.
export async function recordDirs(archiveRoot: string): Promise<string[]> {
  const root = transcriberRecords(archiveRoot);
  const entries = await readdir(root, { withFileTypes: true });
  return entries
    .filter((e) => e.isDirectory() && !e.name.startsWith("."))
    .map((e) => join(root, e.name))
    .sort();
}

/// The recording ID and stamped time of a record, from metadata.json only.
export async function readHead(dir: string): Promise<{ recordingId: string; recordedAt: string }> {
  const m = o(JSON.parse(await readFile(join(dir, "metadata.json"), "utf8")));
  const at = stamp(str(m, "timestamp"));
  if (!at) throw new Error("metadata.json has no timestamp");
  return { recordingId: str(m, "id").toLowerCase(), recordedAt: at };
}

export async function readRecord(dir: string): Promise<ArchiveRecord> {
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

  const artifacts = Array.isArray(m.artifacts) ? m.artifacts.map(o) : [];
  const original = artifacts.find((a) => a.kind === "original-audio");
  let originalAudio: OriginalAudio | null = null;
  if (original) {
    originalAudio = {
      path: join(dir, str(original, "path")),
      sha256: parseSha(original.sha256, "original-audio sha256"),
      bytes: numOrNull(original, "bytes"),
    };
  }

  return {
    dir,
    ...head,
    post,
    originalAudio,
    textSha256: {
      raw: post.transcription ? sha256Hex(post.transcription.text) : null,
      clean: post.cleanup ? sha256Hex(post.cleanup.text) : null,
    },
  };
}
