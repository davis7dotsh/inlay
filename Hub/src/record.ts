// The body of POST /v1/records, and its parse into the rows of the transcripts database.
// The client maps a Transcriber archive record (metadata.json, raw.txt, clean.txt, the last
// source_versions/<sha>.json) the way importer.py transcriber_rows does, and sends the fields that
// mapping fills. The hub derives the IDs, the created_at values and the settings JSON itself, so the
// import of a take and a later sync of the same take write the same rows.
import { createHash } from "node:crypto";
import { HttpError } from "./errors.ts";
import { cleanupId, pythonJson, stamp, transcriptionId } from "./ids.ts";

export type Sha256 = string & { readonly __brand: "Sha256" };
export type RecordingId = string & { readonly __brand: "RecordingId" };
export type DeviceId = string & { readonly __brand: "DeviceId" };

/// The wire shape. Each field names its source in the archive record.
export type RecordPost = {
  recording: {
    recording_id: string; // metadata.id, any case
    recorded_at: string; // metadata.timestamp
    device_id?: string | null; // metadata.context.device.id; the token decides the stored device
    mode: string | null; // metadata.mode
    status: string; // metadata.status
    language: string | null; // metadata.context.language
    app: string | null; // metadata.context.app
    duration_seconds: number | null; // metadata.duration_seconds
  };
  // null when raw.txt and clean.txt are both empty (a cancelled take)
  transcription: null | {
    provider: string; // speech.backend, or "unknown"
    model: string; // speech.modelID, or "unknown"
    model_version: string | null; // speech.engineVersion
    settings: Record<string, unknown>; // preferences language and vocabulary, speech.fallbackReason
    processing_seconds: number | null; // speech.processingSeconds
    detected_language: string | null; // detectedLanguage
    text: string; // raw.txt
  };
  // null when clean.txt is empty
  cleanup: null | {
    engine: string; // "Transcriber"
    engine_version: string | null; // textProcessing.engineVersion
    model: string; // textProcessing.modelID, or "none"
    model_sha256: string | null; // textProcessing.modelSHA256
    prompt_sha256: string | null; // SHA-256 of preferences.proofreadingPrompt when textProcessing.enabled
    status: string | null; // textProcessing.status
    text: string; // clean.txt
  };
  // null for a take with no audio
  audio: null | {
    sha256: string; // claimed SHA-256 of the FLAC bytes
    source_sha256: string; // SHA-256 of the original WAV
    source_bytes: number | null;
    sample_rate: number | null;
    frame_count: number | null;
    flac_base64: string; // the mono FLAC bytes
  };
};

export type Rows = {
  recording: {
    recording_id: RecordingId;
    recorded_at: string | null;
    device_id: DeviceId;
    mode: string | null;
    status: string;
    language: string | null;
    app: string | null;
    duration_seconds: number | null;
    audio_sha256: Sha256 | null;
  };
  audio: null | {
    sha256: Sha256;
    source_sha256: Sha256;
    bytes: number;
    source_bytes: number | null;
    sample_rate: number | null;
    frame_count: number | null;
    nas_path: string;
    flac: Uint8Array;
  };
  transcription: null | {
    transcription_id: string;
    recording_id: RecordingId;
    provider: string;
    model: string;
    model_version: string | null;
    settings: string;
    created_at: string | null;
    processing_seconds: number | null;
    detected_language: string | null;
    text: string;
  };
  cleanup: null | {
    cleanup_id: string;
    transcription_id: string;
    recording_id: RecordingId;
    engine: string;
    engine_version: string | null;
    model: string;
    model_sha256: string | null;
    prompt_sha256: string | null;
    created_at: string | null;
    status: string | null;
    text: string;
  };
};

export const sha256Hex = (data: Uint8Array | string) =>
  createHash("sha256").update(data).digest("hex") as Sha256;

export const artifactPath = (sha: Sha256) => `artifacts/${sha.slice(0, 2)}/${sha}.flac`;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA = /^[0-9a-f]{64}$/;

const bad = (message: string) => new HttpError(400, "bad_record", message);

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);

function obj(parent: Obj, key: string): Obj {
  const v = parent[key];
  if (!isObj(v)) throw bad(`${key} must be an object`);
  return v;
}
function objOrNull(parent: Obj, key: string): Obj | null {
  const v = parent[key];
  if (v === null || v === undefined) return null;
  if (!isObj(v)) throw bad(`${key} must be an object or null`);
  return v;
}
function str(o: Obj, key: string): string {
  const v = o[key];
  if (typeof v !== "string") throw bad(`${key} must be a string`);
  return v;
}
function strOrNull(o: Obj, key: string): string | null {
  const v = o[key];
  if (v === null || v === undefined) return null;
  if (typeof v !== "string") throw bad(`${key} must be a string or null`);
  return v;
}
function numOrNull(o: Obj, key: string): number | null {
  const v = o[key];
  if (v === null || v === undefined) return null;
  if (typeof v !== "number" || !Number.isFinite(v)) throw bad(`${key} must be a number or null`);
  return v;
}
function intOrNull(o: Obj, key: string): number | null {
  const v = numOrNull(o, key);
  if (v !== null && (!Number.isSafeInteger(v) || v < 0))
    throw bad(`${key} must be a whole number or null`);
  return v;
}

export function parseSha(value: unknown, field: string): Sha256 {
  if (typeof value !== "string" || !SHA.test(value))
    throw bad(`${field} must be 64 lowercase hex digits`);
  return value as Sha256;
}

export function parseRecordingId(value: string): RecordingId {
  const id = value.toLowerCase();
  if (!UUID.test(id)) throw bad("recording_id must be a UUID");
  return id as RecordingId;
}

function stampOrBad(value: string): string | null {
  try {
    return stamp(value);
  } catch (error) {
    throw bad(`recorded_at: ${error instanceof Error ? error.message : "not a time"}`);
  }
}

/// A mono FLAC begins with "fLaC" and a STREAMINFO block whose channel field is 0 (1 channel).
function isMonoFlac(bytes: Uint8Array): boolean {
  if (bytes.length < 42) return false;
  if (bytes[0] !== 0x66 || bytes[1] !== 0x4c || bytes[2] !== 0x61 || bytes[3] !== 0x43)
    return false;
  if ((bytes[4]! & 0x7f) !== 0) return false; // the first metadata block must be STREAMINFO
  return ((bytes[8 + 12]! >> 1) & 0x07) === 0;
}

/// Parse the posted body into rows for the device the token names. Throws HttpError 400 for a
/// malformed body or FLAC bytes that do not hash to the claimed SHA-256, and 403 when the body
/// names another device. Nothing is written before this returns.
export function parseRecordPost(body: unknown, device: DeviceId): Rows {
  if (!isObj(body)) throw bad("the body must be a JSON object");
  const r = obj(body, "recording");
  const named = strOrNull(r, "device_id");
  if (named !== null && named.toLowerCase() !== device.toLowerCase())
    throw new HttpError(403, "device_mismatch", "the record names another device than the token");
  const recordingId = parseRecordingId(str(r, "recording_id"));
  const at = stampOrBad(str(r, "recorded_at"));

  const a = objOrNull(body, "audio");
  let audio: Rows["audio"] = null;
  if (a) {
    const claimed = parseSha(a.sha256, "audio.sha256");
    const encoded = str(a, "flac_base64");
    // Decode, then require the canonical re-encode to give back the same text. No regex: Bun's
    // regex engine stops matching a base64 pattern past about 8 MB of text (a 75 s take).
    const decoded = Buffer.from(encoded, "base64");
    if (decoded.toString("base64") !== encoded) throw bad("audio.flac_base64 must be base64");
    const flac = new Uint8Array(decoded);
    if (sha256Hex(flac) !== claimed)
      throw new HttpError(400, "bad_hash", "the FLAC bytes do not hash to audio.sha256");
    if (!isMonoFlac(flac)) throw bad("the audio must be a mono FLAC");
    audio = {
      sha256: claimed,
      source_sha256: parseSha(a.source_sha256, "audio.source_sha256"),
      bytes: flac.length,
      source_bytes: intOrNull(a, "source_bytes"),
      sample_rate: intOrNull(a, "sample_rate"),
      frame_count: intOrNull(a, "frame_count"),
      nas_path: artifactPath(claimed),
      flac,
    };
  }

  const t = objOrNull(body, "transcription");
  const c = objOrNull(body, "cleanup");
  if (c && !t) throw bad("a cleanup needs a transcription");
  let transcription: Rows["transcription"] = null;
  let cleanup: Rows["cleanup"] = null;
  if (t) {
    const provider = str(t, "provider");
    const model = str(t, "model");
    const tid = transcriptionId(recordingId, provider, model, at);
    let settings: string;
    try {
      settings = pythonJson(obj(t, "settings"));
    } catch (error) {
      throw error instanceof HttpError ? error : bad("transcription.settings must be JSON");
    }
    transcription = {
      transcription_id: tid,
      recording_id: recordingId,
      provider,
      model,
      model_version: strOrNull(t, "model_version"),
      settings,
      created_at: at,
      processing_seconds: numOrNull(t, "processing_seconds"),
      detected_language: strOrNull(t, "detected_language"),
      text: str(t, "text"),
    };
    if (c) {
      const promptSha = strOrNull(c, "prompt_sha256");
      const modelSha = strOrNull(c, "model_sha256");
      cleanup = {
        cleanup_id: cleanupId(tid),
        transcription_id: tid,
        recording_id: recordingId,
        engine: str(c, "engine"),
        engine_version: strOrNull(c, "engine_version"),
        model: str(c, "model"),
        model_sha256: modelSha,
        prompt_sha256: promptSha === null ? null : parseSha(promptSha, "cleanup.prompt_sha256"),
        created_at: at,
        status: strOrNull(c, "status"),
        text: str(c, "text"),
      };
    }
  }

  return {
    recording: {
      recording_id: recordingId,
      recorded_at: at,
      device_id: device,
      mode: strOrNull(r, "mode"),
      status: str(r, "status"),
      language: strOrNull(r, "language"),
      app: strOrNull(r, "app"),
      duration_seconds: numOrNull(r, "duration_seconds"),
      audio_sha256: audio?.sha256 ?? null,
    },
    audio,
    transcription,
    cleanup,
  };
}

/// What the hub confirms, and what the client sends back to reconfirm before a delete.
export type Confirm = {
  recording_id: RecordingId;
  flac_sha256: Sha256 | null;
  text_sha256: { raw: Sha256 | null; clean: Sha256 | null };
};

/// source_sha256, when sent, is the SHA-256 of the client's WAV now. The reconfirm then also checks
/// that the stored FLAC was made from that WAV (null: the client holds no audio).
export type Held = Omit<Confirm, "recording_id"> & { source_sha256?: Sha256 | null };

export function parseHeld(body: unknown, recordingId: RecordingId): Held {
  if (!isObj(body)) throw bad("the body must be a JSON object");
  if (body.recording_id !== undefined && body.recording_id !== recordingId)
    throw bad("recording_id in the body differs from the path");
  const texts = obj(body, "text_sha256");
  const shaOrNull = (v: unknown, f: string) =>
    v === null || v === undefined ? null : parseSha(v, f);
  return {
    flac_sha256: shaOrNull(body.flac_sha256, "flac_sha256"),
    text_sha256: {
      raw: shaOrNull(texts.raw, "text_sha256.raw"),
      clean: shaOrNull(texts.clean, "text_sha256.clean"),
    },
    ...("source_sha256" in body
      ? { source_sha256: shaOrNull(body.source_sha256, "source_sha256") }
      : {}),
  };
}
