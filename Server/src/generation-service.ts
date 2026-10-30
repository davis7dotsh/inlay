import { constants } from "node:fs";
import { access, mkdir, open, readdir, rename, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import type {
  AudioArtifact,
  AudioChunkReceipt,
  AudioKind,
  AudioStreamFormat,
  CreateGenerationRequest,
  DeliveryReceipt,
  EnrollDeviceRequest,
  PurgeAudioRequest,
  DictationContinuation,
  FinishGenerationRequest,
  GenerationPage,
  GenerationSummary,
  GenerationRecord,
  PreferencesSnapshot,
  ServerHealth,
  ServerPreferences,
  TextProcessingRecord,
  WisprFlowArtifactName,
  WisprFlowImportRequest,
  WisprFlowKnownIDsRequest,
} from "./api.ts";
import type { components } from "./generated/api.ts";
import {
  API_VERSION,
  MAXIMUM_CHUNK_BYTES,
  MAXIMUM_METADATA_BYTES,
  MAXIMUM_PREFERENCES_BYTES,
} from "./api.ts";
import { decodePersonalDictionary } from "./domain/dictionary.ts";
import { validateBody } from "./validation.ts";
import type { InferenceBackend } from "./inference/native-inference.ts";
import { InferenceError } from "./inference/inference-error.ts";
import { DeviceStore, timingSafeStringEqual, type RequestActor } from "./devices.ts";
import { ServiceError } from "./errors.ts";
import { SERVER_VERSION } from "./version.ts";
import { logError, logInfo, logWarn } from "./log.ts";
import {
  atomicPrivateWrite,
  ensureDirectory,
  readRegularFile,
  requireDiskSpace,
  requireDiskSpaceFor,
  freeBytes,
  requireRegularDirectory,
  syncDirectory,
} from "./storage.ts";
import { WisprFlowImports } from "./imports.ts";
import {
  applyDictionary,
  defaultDictionary,
  dictionaryValidationError,
  dictionaryVocabularyTerms,
} from "./domain/dictionary.ts";
import { cleanTranscript } from "./domain/cleaner.ts";
import { composeDictation } from "./domain/composition.ts";
import { formatSpokenList } from "./domain/lists.ts";
import { evaluateCorrectionInWorker } from "./domain/correction-runtime.ts";
import { maxInputCharacters, modelHints, processingRecord } from "./domain/correction.ts";

const MAX_ACTIVE_GENERATIONS = 12;
const RECEIVING_IDLE_MS = 120_000;
const RECEIVING_TOTAL_MS = 900_000;
// Event streams repeat the latest record on every tick unless a line went out
// within the last half interval, so subscribers see a line at least every ~3 s.
const HEARTBEAT_MS = 2_000;
const terminal = (record: GenerationRecord) =>
  ["completed", "failed", "cancelled"].includes(record.status);
const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const uuid = () => randomUUID().toUpperCase();
const isUUID = (value: string) =>
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const copy = <T>(value: T): T => structuredClone(value);
const graphemes = (text: string) =>
  [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)].length;

import { DEFAULT_PROOFREADING_PROMPT } from "./generated/shared.ts";

export const defaultProofreadingPrompt = DEFAULT_PROOFREADING_PROMPT;
// History pages carry the list projection only; full records come from
// GET /v1/generations/:id. Optional fields stay omitted, never null.
const summarizeGeneration = (record: GenerationRecord): GenerationSummary => ({
  id: record.id,
  device: record.device,
  mode: record.mode,
  status: record.status,
  createdAt: record.createdAt,
  updatedAt: record.updatedAt,
  previewText: record.previewText,
  ...(record.queuePosition !== undefined ? { queuePosition: record.queuePosition } : {}),
  ...(record.originalAudioOmittedReason !== undefined
    ? { originalAudioOmittedReason: record.originalAudioOmittedReason }
    : {}),
  ...(record.importedSource !== undefined ? { importedSource: record.importedSource } : {}),
});

export const defaultPreferences = (): PreferencesSnapshot => ({
  revision: 0,
  preferences: {
    language: "en",
    proofreadingPrompt: defaultProofreadingPrompt,
    vocabulary: "",
    dictionary: copy(defaultDictionary),
    textCorrectionEnabled: true,
    keepOriginalAudio: true,
    audioRetentionDays: 90,
  },
});
export function preferencesValidationError(preferences: ServerPreferences) {
  if (
    ![
      "en",
      "auto",
      "es",
      "fr",
      "de",
      "it",
      "pt",
      "nl",
      "ja",
      "zh",
      "ko",
      "hi",
      "ar",
      "pl",
      "ru",
      "uk",
      "sv",
    ].includes(preferences.language)
  )
    return "Choose a supported language.";
  if (!preferences.proofreadingPrompt.trim()) return "The cleanup system prompt cannot be empty.";
  if (
    !Number.isInteger(preferences.audioRetentionDays) ||
    preferences.audioRetentionDays < 0 ||
    preferences.audioRetentionDays > 3650
  )
    return "Choose an audio retention between 0 (keep forever) and 3650 days.";
  if (
    Buffer.byteLength(preferences.proofreadingPrompt) > 4096 ||
    preferences.proofreadingPrompt.includes("\0")
  )
    return "The cleanup system prompt must fit within 4 KB and contain no null characters.";
  if (
    Buffer.byteLength(preferences.vocabulary) > 16_384 ||
    [...preferences.vocabulary].some(
      (character) => /[\p{Cc}\p{Cf}]/u.test(character) && !/\s/u.test(character),
    )
  )
    return "Vocabulary must fit within 16 KB and contain no hidden control characters.";
  if (
    preferences.dictionary.lists.some((list) =>
      list.entries.some((entry) => Buffer.byteLength(entry.term) > 16_384),
    )
  )
    return "Each dictionary word must fit within 16 KB for speech recognition.";
  return dictionaryValidationError(preferences.dictionary);
}

function normalizePreferences(
  value: components["schemas"]["ServerPreferences"],
): ServerPreferences {
  const dictionary = decodePersonalDictionary(value.dictionary);
  if (dictionary.error) throw new ServiceError(400, "invalid_preferences", dictionary.error);
  return {
    ...value,
    dictionary: dictionary.value!,
    proofreadingPrompt: value.proofreadingPrompt ?? defaultProofreadingPrompt,
    audioRetentionDays: value.audioRetentionDays ?? 90,
  };
}

interface ServiceConfiguration {
  dataDirectory: string;
  development: boolean;
  adminToken: string;
}

const validDeviceLabel = (text: string) =>
  text.length > 0 &&
  graphemes(text) <= 128 &&
  text === text.trim() &&
  !/[\p{Cc}\p{Zl}\p{Zp}]/u.test(text);
// Revocation carries the ID in one URL segment, so also keep its encoded size
// comfortably inside the router and HTTP request-line limits.
const validDeviceID = (text: string) =>
  validDeviceLabel(text) && text.length <= 2_048 && Buffer.byteLength(text) <= 4_096;
interface Upload {
  format: AudioStreamFormat;
  chunks: { offset: number; count: number }[];
  bytes: number;
}
interface Watcher {
  queue: GenerationRecord[];
  wake?: () => void;
  done: boolean;
  lastVersion?: number;
  lastSentAt?: number;
  lastQueuePosition?: number;
}

/** Durable mutations serialize per generation; shared state uses the global queue. Model work proceeds outside both. */
export class GenerationService {
  private preferences: PreferencesSnapshot = defaultPreferences();
  private records = new Map<string, GenerationRecord>();
  private uploads = new Map<string, Partial<Record<AudioKind, Upload>>>();
  private processingControllers = new Map<string, AbortController>();
  private speechStageQueue: Promise<unknown> = Promise.resolve();
  private proofStageQueue: Promise<unknown> = Promise.resolve();
  private processingTasks = new Set<Promise<void>>();
  private warmController?: AbortController;
  private warmTask?: Promise<void>;
  private warming = false;
  /** Why the last warmup could not load speech; undefined once it loads. */
  private speechLoadError?: string;
  private proofLoadError?: string;
  private warmupFailures = 0;
  private nextWarmupAt = 0;
  private stopping = false;
  private timer?: ReturnType<typeof setInterval>;
  private lastRetentionSweep = 0;
  private queue: Promise<unknown> = Promise.resolve();
  private generationQueues = new Map<string, Promise<unknown>>();
  private recordVersions = new Map<string, number>();
  private lastProgressYieldAt = new Map<string, number>();
  private processingOrder: string[] = [];
  private importQueue: Promise<unknown> = Promise.resolve();
  private subscribers = new Map<string, Set<Watcher>>();
  private readonly imports: WisprFlowImports;
  private devices!: DeviceStore;
  private constructor(
    private readonly configuration: ServiceConfiguration,
    private readonly inference: InferenceBackend,
  ) {
    this.imports = new WisprFlowImports({
      dataDirectory: configuration.dataDirectory,
      getPreferences: () => copy(this.preferences),
      getRecord: (id) => this.getInternal(id),
      publish: (record) => this.publish(record),
      requireDiskSpace: () => requireDiskSpace(configuration.dataDirectory),
      withGenerationLock: (id, operation) => this.withGenerationLock(id, operation),
    });
  }
  static async open(configuration: ServiceConfiguration, inference: InferenceBackend) {
    const service = new GenerationService(configuration, inference);
    await service.initialize();
    return service;
  }
  private mutate<T>(operation: () => Promise<T> | T): Promise<T> {
    const result = this.queue.then(operation);
    this.queue = result.catch(() => {});
    return result;
  }
  // Lock ordering: never await a generation lock while holding the global
  // queue, and global-queue operations never call generation-locked methods.
  // The import queue may take a generation lock; generation-locked code never
  // waits on the import queue.
  private withGenerationLock<T>(id: string, operation: () => Promise<T> | T): Promise<T> {
    const key = id.toUpperCase();
    const previous = this.generationQueues.get(key) ?? Promise.resolve();
    const result = previous.then(operation);
    const tail = result.catch(() => {});
    this.generationQueues.set(key, tail);
    void tail.finally(() => {
      if (this.generationQueues.get(key) === tail) this.generationQueues.delete(key);
    });
    return result;
  }
  private withImportQueue<T>(operation: () => Promise<T> | T): Promise<T> {
    const result = this.importQueue.then(operation);
    this.importQueue = result.catch(() => {});
    return result;
  }
  /** One job per helper at a time; speech of take N+1 overlaps proof of take N. */
  private withStage<T>(stage: "speech" | "proof", operation: () => Promise<T> | T): Promise<T> {
    const queue = stage === "speech" ? this.speechStageQueue : this.proofStageQueue;
    const result = queue.then(operation);
    const tail = result.catch(() => {});
    if (stage === "speech") this.speechStageQueue = tail;
    else this.proofStageQueue = tail;
    return result;
  }
  private directory(id: string) {
    return join(this.configuration.dataDirectory, "generations", id);
  }
  private requireOwner(record: GenerationRecord, actorDeviceID: string) {
    if (record.device.id !== actorDeviceID)
      throw new ServiceError(
        403,
        "device_mismatch",
        "This credential belongs to a different device.",
      );
  }
  private getInternal(id: string) {
    const record = this.records.get(id.toUpperCase());
    if (!record) throw new ServiceError(404, "not_found", "Recording not found.");
    return this.decorate(copy(record));
  }
  /** Computes queuePosition on a copy only; it is never persisted (save strips it). */
  private decorate(record: GenerationRecord): GenerationRecord {
    delete record.queuePosition;
    if (record.status === "queued") {
      let position = 0;
      for (const queuedID of this.processingOrder) {
        if (this.records.get(queuedID)?.status !== "queued") continue;
        position++;
        if (queuedID === record.id) {
          record.queuePosition = position;
          break;
        }
      }
    }
    return record;
  }
  private async initialize() {
    const data = resolve(this.configuration.dataDirectory);
    await mkdir(dirname(data), { recursive: true, mode: 0o700 });
    await ensureDirectory(data);
    await ensureDirectory(join(data, "generations"));
    await this.imports.initialize();
    this.devices = await DeviceStore.open(data);
    const path = join(data, "preferences.json");
    try {
      const raw: unknown = JSON.parse(
        (await readRegularFile(path, MAXIMUM_PREFERENCES_BYTES)).toString("utf8"),
      );
      if (typeof raw !== "object" || raw === null || !("preferences" in raw))
        throw new ServiceError(500, "invalid_preferences", "Server preferences are invalid.");
      const loaded = validateBody("PreferencesSnapshot", raw) as PreferencesSnapshot;
      loaded.preferences = normalizePreferences(loaded.preferences);
      const error = preferencesValidationError(loaded.preferences);
      if (!Number.isSafeInteger(loaded.revision) || loaded.revision < 0 || error)
        throw new ServiceError(
          500,
          "invalid_preferences",
          error ?? "Server preference revision is invalid.",
        );
      this.preferences = loaded;
    } catch (error) {
      if (!(error instanceof Error && "code" in error && error.code === "ENOENT"))
        throw new Error(
          `Server preferences at ${path} are invalid: ${error instanceof Error ? error.message : "unreadable"}`,
          { cause: error },
        );
      await atomicPrivateWrite(path, JSON.stringify(this.preferences));
    }
    const requeue: { id: string; createdAt: string }[] = [];
    let quarantined = 0;
    for (const name of await readdir(join(data, "generations"))) {
      if (!isUUID(name)) continue;
      const id = name.toUpperCase();
      try {
        await requireRegularDirectory(join(data, "generations", name));
        // Swift UUID filenames are uppercase; normalize migrated lowercase dirs.
        if (name !== id) await rename(join(data, "generations", name), this.directory(id));
        let record: GenerationRecord;
        try {
          record = validateBody(
            "GenerationRecord",
            JSON.parse(
              (
                await readRegularFile(
                  join(this.directory(id), "metadata.json"),
                  MAXIMUM_METADATA_BYTES,
                )
              ).toString("utf8"),
            ),
          ) as GenerationRecord;
        } catch (error) {
          if (error instanceof Error && "code" in error && error.code === "ENOENT") {
            logWarn("generation_metadata_missing", { id });
            continue;
          }
          throw error;
        }
        record.settings.preferences = normalizePreferences(record.settings.preferences);
        if (
          record.id.toUpperCase() !== id ||
          record.schemaVersion !== 1 ||
          ![
            "receiving",
            "queued",
            "transcribing",
            "proofreading",
            "completed",
            "failed",
            "cancelled",
          ].includes(record.status)
        )
          throw new ServiceError(500, "invalid_archive", "A generation has invalid metadata.");
        record.id = id;
        if (!terminal(record)) {
          let sealed = false;
          if (record.status !== "receiving" && record.inferenceAudio) {
            try {
              const file = await open(
                join(this.directory(id), "inference.wav"),
                constants.O_RDONLY | constants.O_NOFOLLOW,
              );
              try {
                sealed = (await file.stat()).isFile();
              } finally {
                await file.close();
              }
            } catch {
              sealed = false;
            }
          }
          if (sealed) {
            record.status = "queued";
            record.progress = 0;
            delete record.error;
            record.updatedAt = now();
            requeue.push({ id, createdAt: record.createdAt });
          } else {
            const wasReceiving = record.status === "receiving";
            record.status = "failed";
            record.error = wasReceiving
              ? "Server restarted before this generation completed."
              : "Sealed audio is missing, so this generation cannot be transcribed.";
            record.updatedAt = now();
            delete record.progress;
            await this.cleanPartial(id);
          }
          if (Buffer.byteLength(JSON.stringify(record)) <= MAXIMUM_METADATA_BYTES)
            await atomicPrivateWrite(
              join(this.directory(id), "metadata.json"),
              JSON.stringify(record),
            );
        }
        this.records.set(id, record);
        this.imports.indexRecord(record);
      } catch (error) {
        this.records.delete(id);
        try {
          let source = this.directory(id);
          for (const candidate of [this.directory(id), join(data, "generations", name)])
            if (
              await access(candidate).then(
                () => true,
                () => false,
              )
            ) {
              source = candidate;
              break;
            }
          let target = `${this.directory(id)}.quarantined`;
          for (
            let suffix = 2;
            await access(target).then(
              () => true,
              () => false,
            );
            suffix++
          )
            target = `${this.directory(id)}.quarantined-${suffix}`;
          await rename(source, target);
          quarantined++;
          await atomicPrivateWrite(
            join(target, "quarantine-reason.txt"),
            `${now()}\n${error instanceof Error ? error.message : "Invalid generation record."}\n`,
          ).catch(() => {});
          logError("generation_quarantined", error, { id, to: target });
        } catch (quarantineError) {
          logError("generation_quarantine_failed", quarantineError, { id });
        }
      }
    }
    logInfo("archive_loaded", { records: this.records.size, quarantined });
    requeue.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    for (const entry of requeue) this.enqueueProcessing(entry.id, undefined);
  }
  start() {
    if (this.stopping || this.timer) return;
    this.beginWarmup();
    this.lastRetentionSweep = Date.now();
    void this.sweepAudioRetention().catch((error) => logError("retention_sweep_failed", error));
    this.timer = setInterval(() => {
      void this.tick().catch((error) => logError("tick_failed", error));
    }, HEARTBEAT_MS);
    this.timer.unref();
  }
  private async tick() {
    // Synchronous heartbeat: do not add an await to this loop without re-queueing it.
    for (const [id, watchers] of this.subscribers) {
      const record = this.records.get(id);
      if (record) for (const watcher of watchers) this.yieldTo(watcher, record);
    }
    await this.withImportQueue(async () => {
      await this.imports.expireImportStages();
    });
    for (const snapshot of this.records.values()) {
      if (
        snapshot.status !== "receiving" ||
        !(
          Date.now() - Date.parse(snapshot.updatedAt) > RECEIVING_IDLE_MS ||
          Date.now() - Date.parse(snapshot.createdAt) > RECEIVING_TOTAL_MS
        )
      )
        continue;
      await this.withGenerationLock(snapshot.id, async () => {
        const record = this.records.get(snapshot.id);
        if (record?.status === "receiving") await this.cancelRecord(record.id);
      });
    }
    if (Date.now() - this.lastRetentionSweep >= 86_400_000) {
      this.lastRetentionSweep = Date.now();
      await this.sweepAudioRetention();
    }
  }
  async shutdown() {
    this.stopping = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    this.warmController?.abort();
    for (const controller of this.processingControllers.values()) controller.abort();
    await this.inference.shutdown();
    await Promise.allSettled(
      [...this.processingTasks, this.warmTask].filter((task): task is Promise<void> =>
        Boolean(task),
      ),
    );
    // Sealed work survives shutdown as queued; only unsealed receiving
    // sessions are cancelled. This runs after the queue drains so the
    // queued state is the final write.
    for (const snapshot of this.records.values()) {
      await this.withGenerationLock(snapshot.id, async () => {
        const record = this.records.get(snapshot.id);
        if (!record) return;
        if (record.status === "receiving") await this.cancelRecord(record.id);
        else if (!terminal(record) && record.inferenceAudio) {
          const queued = copy(record);
          queued.status = "queued";
          delete queued.progress;
          delete queued.error;
          queued.updatedAt = now();
          await this.save(queued).catch(() => this.publish(queued));
        }
      });
    }
    await this.mutate(() => {
      for (const watchers of this.subscribers.values())
        for (const watcher of watchers) {
          watcher.done = true;
          watcher.wake?.();
        }
      this.subscribers.clear();
    });
  }
  async health(): Promise<ServerHealth> {
    const state = await this.inference.readiness(false);
    let writable = true;
    try {
      await access(this.configuration.dataDirectory, constants.W_OK);
      await requireDiskSpace(this.configuration.dataDirectory);
    } catch {
      writable = false;
    }
    // Synchronous read-copy from here: do not add an await without re-queueing.
    const failure = this.speechLoadFailure(state);
    const ready = state.available && writable && !this.stopping && !failure;
    const message = !writable
      ? "Server storage is unavailable or full."
      : this.stopping
        ? "The server is shutting down."
        : ready
          ? state.speechLoaded
            ? "Server ready."
            : "Loading server models; recordings will queue."
          : (failure ??
            (this.warming ? "Loading server models…" : "Server models are unavailable."));
    if (!state.speechLoaded) this.beginWarmup();
    return {
      apiVersion: API_VERSION,
      serverVersion: SERVER_VERSION,
      isDev: this.configuration.development,
      ready,
      speech: {
        modelID: "parakeet-tdt-0.6b-v3",
        backend: this.speechBackend,
        ready: state.speechLoaded,
      },
      proofreading: {
        modelID: "Qwen3-4B-Instruct-2507",
        backend: this.proofBackend,
        ready: state.proofLoaded,
        message: this.preferences.preferences.textCorrectionEnabled
          ? state.proofLoaded
            ? undefined
            : (this.proofLoadError ?? "Unavailable; deterministic text is preserved.")
          : "Disabled",
      },
      message,
    };
  }
  async getPreferences() {
    // Synchronous read-copy: do not add an await without re-queueing.
    return copy(this.preferences);
  }
  authenticate(token: string | undefined): RequestActor {
    if (!token) return { kind: "none" };
    if (timingSafeStringEqual(this.configuration.adminToken, token)) return { kind: "admin" };
    const device = this.devices?.authenticateDevice(token);
    if (!device) return { kind: "none" };
    void this.devices.touch(device.id).catch(() => {});
    return { kind: "device", id: device.id, name: device.name };
  }
  enrollDevice(request: EnrollDeviceRequest, actor: RequestActor) {
    return this.mutate(async () => {
      if (!validDeviceID(request.device.id) || !validDeviceLabel(request.device.name))
        throw new ServiceError(
          400,
          "invalid_device",
          "Device ID and name must be nonempty single-line text within supported length limits.",
        );
      if (actor.kind === "device" && actor.id !== request.device.id)
        throw new ServiceError(
          403,
          "device_mismatch",
          "A device may only renew its own credential.",
        );
      // Once closed, only a device's own credential renews it; the admin
      // token can no longer mint or rotate any device credential.
      if (actor.kind === "admin" && this.devices.legacyEnrollmentClosed)
        throw new ServiceError(
          403,
          "enrollment_closed",
          "The admin token no longer enrolls devices on this server.",
        );
      return this.devices.enroll(request.device);
    });
  }
  listDevices() {
    return this.devices.list();
  }
  revokeDevice(id: string) {
    return this.mutate(() => this.devices.revoke(id));
  }
  closeLegacyEnrollment() {
    return this.mutate(() => this.devices.closeLegacyEnrollment());
  }
  updatePreferences(update: components["schemas"]["PreferencesSnapshot"]) {
    return this.mutate(async () => {
      if (update.revision !== this.preferences.revision)
        throw new ServiceError(
          409,
          "stale_preferences",
          "Preferences changed on another device. Reload and try again.",
        );
      const normalized = normalizePreferences(update.preferences);
      const error = preferencesValidationError(normalized);
      if (error) throw new ServiceError(400, "invalid_preferences", error);
      const next = { revision: this.preferences.revision + 1, preferences: normalized };
      const data = JSON.stringify(next);
      if (Buffer.byteLength(data) > MAXIMUM_PREFERENCES_BYTES)
        throw new ServiceError(
          413,
          "preferences_too_large",
          "Server preferences exceeded the 256 KiB storage limit.",
        );
      await atomicPrivateWrite(join(this.configuration.dataDirectory, "preferences.json"), data);
      this.preferences = next;
      this.beginWarmup(true);
      return copy(next);
    });
  }
  async create(request: CreateGenerationRequest, actorDeviceID: string) {
    const state = await this.inference.readiness(false);
    return this.mutate(async () => {
      if (this.stopping)
        throw new ServiceError(503, "server_stopping", "The server is shutting down.");
      if (!validDeviceID(request.device.id) || !validDeviceLabel(request.device.name))
        throw new ServiceError(
          400,
          "invalid_device",
          "Device ID and name must be nonempty single-line text within supported length limits.",
        );
      if (request.device.id !== actorDeviceID)
        throw new ServiceError(
          403,
          "device_mismatch",
          "This credential belongs to a different device.",
        );
      await this.devices.rename(request.device.id, request.device.name);
      const existing = [...this.records.values()].find(
        (record) =>
          record.requestID.toUpperCase() === request.requestID.toUpperCase() &&
          record.device.id === request.device.id,
      );
      if (existing) return copy(existing);
      const active = [...this.records.values()].filter((record) => !terminal(record)).length;
      if (active >= MAX_ACTIVE_GENERATIONS)
        throw new ServiceError(
          429,
          "server_busy",
          "The server is already processing the maximum number of recordings. Try again shortly.",
        );
      const failure = this.speechLoadFailure(state);
      if (!state.available || failure) {
        this.beginWarmup();
        throw new ServiceError(503, "server_unavailable", failure ?? state.message);
      }
      // Starting a take loads any cold model now, not when the recording is sealed.
      if (
        !state.speechLoaded ||
        (this.preferences.preferences.textCorrectionEnabled && !state.proofLoaded)
      )
        this.beginWarmup();
      await requireDiskSpace(this.configuration.dataDirectory);
      const record = this.newRecord(
        uuid(),
        request.requestID.toUpperCase(),
        request.device,
        request.mode,
        now(),
      );
      await mkdir(this.directory(record.id), { mode: 0o700 });
      await this.save(record);
      this.uploads.set(record.id, {});
      return copy(record);
    });
  }
  private newRecord(
    id: string,
    requestID: string,
    device: CreateGenerationRequest["device"],
    mode: CreateGenerationRequest["mode"],
    date: string,
  ): GenerationRecord {
    return {
      schemaVersion: 1,
      id,
      requestID,
      device: copy(device),
      mode,
      status: "receiving",
      createdAt: date,
      updatedAt: date,
      settings: copy(this.preferences),
      rawText: "",
      finalText: "",
      insertionText: "",
      previewText: "",
    };
  }
  appendAudio(
    id: string,
    kind: AudioKind,
    sequence: number,
    format: AudioStreamFormat,
    data: Uint8Array,
    actorDeviceID: string,
  ): Promise<AudioChunkReceipt> {
    const bytes = Buffer.from(data);
    return this.withGenerationLock(id, async () => {
      const record = this.getInternal(id);
      id = record.id;
      this.requireOwner(record, actorDeviceID);
      if (record.status !== "receiving")
        throw new ServiceError(
          409,
          "upload_closed",
          "This recording is no longer accepting audio.",
        );
      if (kind === "original" && !record.settings.preferences.keepOriginalAudio)
        throw new ServiceError(
          400,
          "original_disabled",
          "Original audio retention was disabled for this recording.",
        );
      if (!Number.isInteger(sequence) || sequence < 0 || sequence >= 4096)
        throw new ServiceError(
          413,
          "chunk_limit",
          "This recording exceeded its audio chunk limit.",
        );
      if (
        !Number.isInteger(format.sampleRate) ||
        !Number.isInteger(format.channels) ||
        format.sampleRate < 8000 ||
        format.sampleRate > 192000 ||
        format.channels < 1 ||
        format.channels > 8 ||
        (kind === "inference" && (format.sampleRate !== 16000 || format.channels !== 1))
      )
        throw new ServiceError(
          400,
          "invalid_format",
          "Inference audio must be mono 16 kHz. Original audio must have 1–8 channels at 8–192 kHz.",
        );
      if (
        !bytes.length ||
        bytes.length > MAXIMUM_CHUNK_BYTES ||
        bytes.length % (format.channels * 4)
      )
        throw new ServiceError(
          bytes.length > MAXIMUM_CHUNK_BYTES ? 413 : 400,
          "invalid_chunk",
          "Audio chunks must contain complete float32 frames and fit within 1 MiB.",
        );
      for (let offset = 0; offset < bytes.length; offset += 4)
        if ((bytes.readUInt32LE(offset) & 0x7f800000) === 0x7f800000)
          throw new ServiceError(
            400,
            "invalid_samples",
            "Audio must contain finite float32 samples.",
          );
      const streams = this.uploads.get(id) ?? {};
      const upload = streams[kind] ?? { format: copy(format), chunks: [], bytes: 0 };
      if (
        upload.format.sampleRate !== format.sampleRate ||
        upload.format.channels !== format.channels
      )
        throw new ServiceError(
          409,
          "format_changed",
          "An audio stream cannot change format during recording.",
        );
      await requireRegularDirectory(this.directory(id));
      const path = join(this.directory(id), `${kind}.raw`);
      if (sequence < upload.chunks.length) {
        const chunk = upload.chunks[sequence]!;
        const file = await open(
          path,
          constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
        );
        try {
          const info = await file.stat();
          if (!info.isFile() || info.size !== upload.bytes)
            throw new ServiceError(500, "invalid_archive", "An audio upload changed unexpectedly.");
          const replay = Buffer.alloc(chunk.count);
          const result = await file.read(replay, 0, replay.length, chunk.offset);
          if (
            chunk.count !== bytes.length ||
            result.bytesRead !== replay.length ||
            !replay.equals(bytes)
          )
            throw new ServiceError(
              409,
              "conflicting_chunk",
              "A repeated audio chunk did not match the original.",
            );
        } finally {
          await file.close();
        }
        record.updatedAt = now();
        this.records.set(id, record);
        return {
          nextSequence: upload.chunks.length,
          frameCount: upload.bytes / (format.channels * 4),
        };
      }
      if (sequence !== upload.chunks.length)
        throw new ServiceError(409, "missing_chunk", "Audio chunks must arrive in sequence.");
      const nextBytes = upload.bytes + bytes.length;
      if (nextBytes / (format.sampleRate * format.channels * 4) > 180.1 || nextBytes > 268_435_456)
        throw new ServiceError(
          413,
          "recording_limit",
          "Recordings are limited to 180 seconds and 256 MiB per audio stream.",
        );
      if (upload.bytes === 0) await requireDiskSpace(this.configuration.dataDirectory);
      const file = await open(
        path,
        constants.O_WRONLY |
          constants.O_NOFOLLOW |
          constants.O_NONBLOCK |
          (upload.bytes ? 0 : constants.O_CREAT | constants.O_EXCL),
        0o600,
      );
      try {
        const info = await file.stat();
        if (!info.isFile() || info.size !== upload.bytes)
          throw new ServiceError(500, "invalid_archive", "An audio upload changed unexpectedly.");
        let written = 0;
        while (written < bytes.length) {
          const result = await file.write(
            bytes,
            written,
            bytes.length - written,
            upload.bytes + written,
          );
          if (!result.bytesWritten) throw new Error("Audio write failed.");
          written += result.bytesWritten;
        }
      } finally {
        await file.close();
      }
      upload.chunks.push({ offset: upload.bytes, count: bytes.length });
      upload.bytes = nextBytes;
      streams[kind] = upload;
      this.uploads.set(id, streams);
      record.updatedAt = now();
      this.records.set(id, record);
      return {
        nextSequence: upload.chunks.length,
        frameCount: upload.bytes / (format.channels * 4),
      };
    });
  }
  finish(id: string, request: FinishGenerationRequest, actorDeviceID: string) {
    return this.withGenerationLock(id, async () => {
      const record = this.getInternal(id);
      id = record.id;
      this.requireOwner(record, actorDeviceID);
      if (record.status !== "receiving") {
        if (
          record.inferenceAudio?.frameCount !== request.inferenceFrames ||
          record.originalAudio?.frameCount !== request.originalFrames
        )
          throw new ServiceError(
            409,
            "conflicting_finish",
            "The recording was already sealed with different audio counts.",
          );
        return copy(record);
      }
      const streams = this.uploads.get(id),
        speech = streams?.inference;
      if (!speech || speech.bytes / 4 !== request.inferenceFrames)
        throw new ServiceError(
          409,
          "incomplete_audio",
          "Inference audio has not been completely uploaded.",
        );
      const duration = speech.bytes / 64000;
      if (duration < 0.25 || duration > 180)
        throw new ServiceError(
          400,
          "invalid_duration",
          "Recordings must be between 0.25 and 180 seconds.",
        );
      const original = streams?.original;
      let sealOriginal = original;
      if (record.settings.preferences.keepOriginalAudio) {
        if (request.originalFrames === undefined) {
          // Deliberate omission (format too large to archive): seal inference only.
          if (original) {
            await rm(join(this.directory(id), "original.raw"), { force: true }).catch(() => {});
            if (streams) delete streams.original;
            sealOriginal = undefined;
          }
          record.originalAudioOmittedReason =
            "Original audio was not kept for this recording because its format is too large to archive.";
        } else {
          if (
            !original ||
            original.bytes / (original.format.channels * 4) !== request.originalFrames
          )
            throw new ServiceError(
              409,
              "incomplete_original",
              "Original audio has not been completely uploaded.",
            );
          if (
            Math.abs(
              original.bytes / (original.format.sampleRate * original.format.channels * 4) -
                duration,
            ) > 0.075
          )
            throw new ServiceError(
              400,
              "audio_mismatch",
              "Original and inference audio must cover the same recording interval.",
            );
        }
      } else if (request.originalFrames !== undefined || original)
        throw new ServiceError(
          400,
          "unexpected_original",
          "This recording does not retain original audio.",
        );
      const previous = this.continuation(request.continuationID, record);
      await requireDiskSpaceFor(
        this.configuration.dataDirectory,
        speech.bytes + 44 + (sealOriginal ? sealOriginal.bytes + 44 : 0),
      );
      try {
        if (!record.inferenceAudio)
          record.inferenceAudio = await this.seal(id, "inference", speech);
        if (sealOriginal && !record.originalAudio)
          record.originalAudio = await this.seal(id, "original", sealOriginal);
        record.status = "queued";
        delete record.error;
        record.updatedAt = now();
        record.progress = 0;
        await this.save(record);
      } catch (error) {
        logError("seal_failed", error, { id });
        // Keep the uploaded audio: a seal failure is retryable with the same
        // frame counts once space is freed. Drop only the partial WAVs, and
        // clear an artifact assignment only when its raw source still exists
        // (a completed seal already removed the raw; keep that artifact).
        for (const kind of ["inference", "original"] as const) {
          const rawKept = await access(join(this.directory(id), `${kind}.raw`)).then(
            () => true,
            () => false,
          );
          if (rawKept) delete record[kind === "inference" ? "inferenceAudio" : "originalAudio"];
        }
        record.status = "receiving";
        record.error = "The server could not preserve the complete recording.";
        record.updatedAt = now();
        await this.save(record).catch(() => this.publish(record));
        await this.cleanSealPartials(id);
        throw new ServiceError(500, "audio_storage_failed", record.error);
      }
      this.uploads.delete(id);
      this.enqueueProcessing(id, previous);
      return copy(record);
    });
  }
  async get(id: string) {
    // Synchronous read-copy: do not add an await without re-queueing.
    return this.getInternal(id);
  }
  async history(limit = 50, before?: string, source?: string): Promise<GenerationPage> {
    // Synchronous read-copy: do not add an await without re-queueing.
    if (!Number.isInteger(limit) || limit < 1 || limit > 100)
      throw new ServiceError(400, "invalid_limit", "History page size must be between 1 and 100.");
    if (source !== undefined && source !== "wispr-flow" && source !== "inlay")
      throw new ServiceError(400, "invalid_source", "Choose Wispr Flow or Inlay history.");
    const sorted = [...this.records.values()]
      .filter((record) =>
        !source || source === "wispr-flow"
          ? !source || record.importedSource?.provider === "wispr-flow"
          : !record.importedSource,
      )
      .sort(
        (a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt) || b.id.localeCompare(a.id),
      );
    let start = 0;
    if (before) {
      const index = sorted.findIndex((record) => record.id === before.toUpperCase());
      if (index < 0)
        throw new ServiceError(
          400,
          "invalid_cursor",
          "The history cursor is no longer valid. Reload history.",
        );
      start = index + 1;
    }
    const items = sorted.slice(start, start + limit);
    return {
      items: items.map((item) => summarizeGeneration(this.decorate(copy(item)))),
      nextCursor: start + items.length < sorted.length ? items.at(-1)?.id : undefined,
    };
  }
  async events(id: string): Promise<AsyncIterable<GenerationRecord>> {
    const watcher = await this.mutate(() => {
      const record = this.getInternal(id);
      id = record.id;
      const group = this.subscribers.get(id) ?? new Set<Watcher>();
      if (group.size >= 8)
        throw new ServiceError(
          429,
          "stream_limit",
          "Too many connections are watching this recording.",
        );
      const watcher: Watcher = {
        queue: [record],
        done: terminal(record),
        lastVersion: this.recordVersions.get(record.id) ?? 0,
        lastSentAt: Date.now(),
      };
      if (!watcher.done) {
        group.add(watcher);
        this.subscribers.set(id, group);
      }
      return watcher;
    });
    const iterator: AsyncIterableIterator<GenerationRecord> = {
      [Symbol.asyncIterator]() {
        return iterator;
      },
      async next() {
        while (true) {
          const record = watcher.queue.shift();
          if (record) return { value: record, done: false };
          if (watcher.done) return { value: undefined, done: true };
          await new Promise<void>((resolve) => {
            watcher.wake = resolve;
          });
          watcher.wake = undefined;
        }
      },
      return: async () => {
        watcher.done = true;
        watcher.queue = [];
        watcher.wake?.();
        await this.mutate(() => {
          const group = this.subscribers.get(id);
          group?.delete(watcher);
          if (!group?.size) this.subscribers.delete(id);
        });
        return { value: undefined, done: true };
      },
    };
    return iterator;
  }

  cancel(id: string, actorDeviceID: string) {
    return this.withGenerationLock(id, async () => {
      this.requireOwner(this.getInternal(id), actorDeviceID);
      return this.cancelRecord(id);
    });
  }
  reprocess(id: string) {
    return this.withGenerationLock(id, async () => {
      const record = this.getInternal(id);
      if (record.importedSource)
        throw new ServiceError(
          400,
          "imported_reprocess",
          "Imported history cannot be reprocessed.",
        );
      if (this.stopping)
        throw new ServiceError(503, "server_stopping", "The server is shutting down.");
      if (!terminal(record))
        throw new ServiceError(
          409,
          "generation_active",
          "This recording is still being processed.",
        );
      if (record.status === "completed")
        throw new ServiceError(
          409,
          "already_completed",
          "A completed recording cannot be transcribed again.",
        );
      if (!record.inferenceAudio)
        throw new ServiceError(404, "artifact_not_found", "This recording has no sealed audio.");
      try {
        const file = await open(
          join(this.directory(record.id), "inference.wav"),
          constants.O_RDONLY | constants.O_NOFOLLOW,
        );
        try {
          if (!(await file.stat()).isFile()) throw new Error("not a file");
        } finally {
          await file.close();
        }
      } catch {
        throw new ServiceError(404, "artifact_not_found", "The sealed audio file is missing.");
      }
      record.status = "queued";
      record.progress = 0;
      delete record.error;
      record.rawText = "";
      record.finalText = "";
      record.insertionText = "";
      record.previewText = "";
      delete record.speech;
      delete record.proofreading;
      delete record.textProcessing;
      delete record.continuation;
      delete record.delivery;
      delete record.detectedLanguage;
      delete record.recognitionHints;
      delete record.proofreadingHints;
      delete record.formattingRejectionReason;
      delete record.consumedListControls;
      record.updatedAt = now();
      await this.save(record);
      this.enqueueProcessing(record.id, undefined);
      return copy(record);
    });
  }
  private async cancelRecord(id: string) {
    const record = this.getInternal(id);
    if (terminal(record)) return record;
    record.status = "cancelled";
    record.error = "Recording cancelled.";
    delete record.progress;
    record.updatedAt = now();
    this.processingControllers.get(record.id)?.abort();
    await this.save(record).catch(() => this.publish(record));
    await this.cleanPartial(record.id);
    return copy(record);
  }
  recordDelivery(id: string, receipt: DeliveryReceipt, actorDeviceID: string) {
    return this.withGenerationLock(id, async () => {
      const record = this.getInternal(id);
      this.requireOwner(record, actorDeviceID);
      if (record.importedSource)
        throw new ServiceError(
          400,
          "imported_delivery",
          "Imported history cannot receive a delivery receipt.",
        );
      if (
        record.status !== "completed" ||
        ![
          "inserted",
          "copied",
          "unconfirmed",
          "failed",
          "tested",
          "listUpdated",
          "cancelled",
          "none",
        ].includes(receipt.status) ||
        Buffer.byteLength(receipt.message ?? "") > 4096
      )
        throw new ServiceError(
          400,
          "invalid_delivery",
          "A valid delivery receipt requires a completed generation.",
        );
      if (record.delivery) {
        if (
          record.delivery.status !== receipt.status ||
          record.delivery.message !== receipt.message
        )
          throw new ServiceError(
            409,
            "delivery_recorded",
            "This recording already has a delivery outcome.",
          );
        return record;
      }
      record.delivery = { status: receipt.status, message: receipt.message, reportedAt: now() };
      record.updatedAt = now();
      await this.save(record);
      return copy(record);
    });
  }
  delete(id: string) {
    return this.withGenerationLock(id, async () => {
      const record = this.getInternal(id);
      if (!terminal(record))
        throw new ServiceError(
          409,
          "generation_active",
          "Cancel or finish a recording before deleting it.",
        );
      await requireRegularDirectory(this.directory(record.id));
      await rm(this.directory(record.id), { recursive: true });
      this.records.delete(record.id);
      this.imports.removeRecord(record);
    });
  }
  private async purgeAudio(record: GenerationRecord, kinds: AudioKind[]) {
    let freed = 0;
    let changed = false;
    for (const kind of kinds) {
      const field = kind === "inference" ? "inferenceAudio" : "originalAudio";
      const artifact = record[field];
      if (!artifact) continue;
      await rm(join(this.directory(record.id), `${kind}.wav`), { force: true });
      freed += artifact.byteCount;
      delete record[field];
      changed = true;
    }
    if (changed) await this.save(record);
    return freed;
  }
  // Bulk purges take each record's generation lock (not the global queue) and
  // re-check eligibility there, so reprocess, delivery, and delete never
  // interleave with a purge.
  private purgeAudioLocked(
    id: string,
    kinds: AudioKind[],
    eligible: (record: GenerationRecord) => boolean,
  ) {
    return this.withGenerationLock(id, async () => {
      const record = this.records.get(id);
      if (!record || !terminal(record) || !eligible(record)) return 0;
      return this.purgeAudio(record, kinds);
    });
  }
  private async sweepAudioRetention() {
    const days = this.preferences.preferences.audioRetentionDays;
    if (days === 0) return;
    const cutoff = Date.now() - days * 86_400_000;
    const candidates = [...this.records.values()].filter(
      (record) =>
        terminal(record) &&
        Date.parse(record.createdAt) < cutoff &&
        (record.inferenceAudio || record.originalAudio),
    );
    // Re-read retention under each record's lock: a preferences save during
    // the sweep must stop further deletion, not be outlived by a stale cutoff.
    const expired = (record: GenerationRecord) => {
      const current = this.preferences.preferences.audioRetentionDays;
      return current !== 0 && Date.parse(record.createdAt) < Date.now() - current * 86_400_000;
    };
    for (const { id } of candidates) {
      try {
        await this.purgeAudioLocked(id, ["inference", "original"], expired);
      } catch (error) {
        logWarn("retention_purge_failed", { id }, error);
      }
    }
  }
  async storageUsage() {
    let inferenceByteCount = 0;
    let originalByteCount = 0;
    let oldestAudioAt: string | undefined;
    for (const record of this.records.values()) {
      if (record.inferenceAudio) inferenceByteCount += record.inferenceAudio.byteCount;
      if (record.originalAudio) originalByteCount += record.originalAudio.byteCount;
      if (
        (record.inferenceAudio || record.originalAudio) &&
        (oldestAudioAt === undefined || record.createdAt < oldestAudioAt)
      )
        oldestAudioAt = record.createdAt;
    }
    return {
      generationCount: this.records.size,
      audioByteCount: inferenceByteCount + originalByteCount,
      inferenceByteCount,
      originalByteCount,
      oldestAudioAt,
      freeByteCount: Number(await freeBytes(this.configuration.dataDirectory)),
      audioRetentionDays: this.preferences.preferences.audioRetentionDays,
    };
  }
  async purgeAllAudio(request: PurgeAudioRequest) {
    const cutoff =
      request.olderThanDays === undefined
        ? undefined
        : Date.now() - request.olderThanDays * 86_400_000;
    const kinds: AudioKind[] = request.kind ? [request.kind] : ["inference", "original"];
    let purgedRecordCount = 0;
    let freedByteCount = 0;
    const olderThanCutoff = (record: GenerationRecord) =>
      cutoff === undefined || Date.parse(record.createdAt) < cutoff;
    // Snapshot the ids: recordings created after this purge starts are not
    // part of it, even if they finish while it runs.
    const ids = [...this.records.keys()];
    for (const id of ids) {
      const freed = await this.purgeAudioLocked(id, kinds, olderThanCutoff);
      if (freed > 0) {
        purgedRecordCount++;
        freedByteCount += freed;
      }
    }
    return { purgedRecordCount, freedByteCount };
  }
  deleteAudio(id: string) {
    return this.withGenerationLock(id, async () => {
      const record = this.getInternal(id);
      if (!terminal(record))
        throw new ServiceError(
          409,
          "generation_active",
          "Cancel or finish a recording before deleting its audio.",
        );
      await this.purgeAudio(record, ["inference", "original"]);
    });
  }
  artifact(id: string, filename: string) {
    return this.withGenerationLock(id, async () => {
      const record = this.getInternal(id);
      const allowed = [
        "metadata.json",
        "transcript.txt",
        "inference.wav",
        "original.wav",
        ...(record.importedSource?.artifactNames ?? []),
      ];
      if (
        !allowed.includes(filename) ||
        (filename === "inference.wav" && !record.inferenceAudio) ||
        (filename === "original.wav" && !record.originalAudio) ||
        (filename === "transcript.txt" && record.status !== "completed")
      )
        throw new ServiceError(404, "artifact_not_found", "Artifact not found.");
      const path = join(this.directory(record.id), filename);
      await requireRegularDirectory(dirname(path));
      const file = await open(
        path,
        constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
      ).catch(() => undefined);
      if (!file) throw new ServiceError(404, "artifact_not_found", "Artifact not found.");
      try {
        const info = await file.stat();
        if (!info.isFile())
          throw new ServiceError(404, "artifact_not_found", "Artifact not found.");
        return file;
      } catch (error) {
        await file.close();
        throw error;
      }
    });
  }
  knownWisprFlowIDs(request: WisprFlowKnownIDsRequest) {
    return this.withImportQueue(() => this.imports.knownWisprFlowIDs(request));
  }
  beginWisprFlowImport(request: WisprFlowImportRequest) {
    return this.withImportQueue(() => {
      if (this.stopping)
        throw new ServiceError(503, "server_stopping", "The server is shutting down.");
      return this.imports.beginWisprFlowImport(request);
    });
  }
  uploadWisprFlowArtifact(id: string, filename: WisprFlowArtifactName, data: Uint8Array) {
    return this.withImportQueue(() => this.imports.uploadWisprFlowArtifact(id, filename, data));
  }
  completeWisprFlowImport(id: string) {
    return this.withImportQueue(() => this.imports.completeWisprFlowImport(id));
  }
  cancelWisprFlowImport(id: string) {
    return this.withImportQueue(() => this.imports.cancelWisprFlowImport(id));
  }
  archiveWisprFlowDictionary(data: Uint8Array) {
    return this.withImportQueue(() => this.imports.archiveWisprFlowDictionary(data));
  }
  private async seal(id: string, kind: AudioKind, upload: Upload): Promise<AudioArtifact> {
    const directory = this.directory(id);
    await requireRegularDirectory(directory);
    const source = await open(
      join(directory, `${kind}.raw`),
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    const partial = join(directory, `${kind}.wav.partial`);
    try {
      const info = await source.stat();
      if (!info.isFile() || info.size !== upload.bytes)
        throw new Error("Audio changed before sealing.");
      const output = await open(
        partial,
        constants.O_WRONLY |
          constants.O_CREAT |
          constants.O_EXCL |
          constants.O_NOFOLLOW |
          constants.O_NONBLOCK,
        0o600,
      );
      try {
        const header = Buffer.alloc(44);
        header.write("RIFF");
        header.writeUInt32LE(upload.bytes + 36, 4);
        header.write("WAVEfmt ", 8);
        header.writeUInt32LE(16, 16);
        header.writeUInt16LE(3, 20);
        header.writeUInt16LE(upload.format.channels, 22);
        header.writeUInt32LE(upload.format.sampleRate, 24);
        header.writeUInt32LE(upload.format.sampleRate * upload.format.channels * 4, 28);
        header.writeUInt16LE(upload.format.channels * 4, 32);
        header.writeUInt16LE(32, 34);
        header.write("data", 36);
        header.writeUInt32LE(upload.bytes, 40);
        await output.writeFile(header);
        const buffer = Buffer.alloc(MAXIMUM_CHUNK_BYTES);
        let offset = 0;
        while (offset < upload.bytes) {
          const result = await source.read(
            buffer,
            0,
            Math.min(buffer.length, upload.bytes - offset),
            offset,
          );
          if (!result.bytesRead) throw new Error("Audio ended before sealing.");
          await output.writeFile(buffer.subarray(0, result.bytesRead));
          offset += result.bytesRead;
        }
        await output.sync();
      } finally {
        await output.close();
      }
    } finally {
      await source.close();
    }
    await rename(partial, join(directory, `${kind}.wav`));
    await syncDirectory(directory);
    await rm(join(directory, `${kind}.raw`));
    return {
      filename: `${kind}.wav`,
      sampleRate: upload.format.sampleRate,
      channels: upload.format.channels,
      frameCount: upload.bytes / (upload.format.channels * 4),
      byteCount: upload.bytes + 44,
      encoding: "pcm_f32le",
    };
  }
  private continuation(
    id: string | undefined,
    record: GenerationRecord,
  ): DictationContinuation | undefined {
    if (!id) return;
    const previous = this.records.get(id.toUpperCase());
    if (
      !previous ||
      previous.device.id !== record.device.id ||
      previous.status !== "completed" ||
      Date.now() - Date.parse(previous.updatedAt) < 0 ||
      Date.now() - Date.parse(previous.updatedAt) >= 900_000 ||
      previous.mode !== record.mode ||
      (previous.mode !== "test" &&
        !["inserted", "listUpdated"].includes(previous.delivery?.status ?? ""))
    )
      return;
    return copy(previous.continuation);
  }
  private enqueueProcessing(id: string, previous: DictationContinuation | undefined) {
    // A reprocessed id joins the speech queue at its tail, so it moves there too.
    this.processingOrder = [...this.processingOrder.filter((queuedID) => queuedID !== id), id];
    const enqueuedAt = performance.now();
    const controller = new AbortController();
    this.processingControllers.set(id, controller);
    // Jobs run concurrently; withStage serializes each helper's stage, so
    // completion order still equals seal order on both FIFO stages.
    const task = (async () => {
      if (!this.stopping && !controller.signal.aborted)
        await this.process(id, previous, controller.signal, enqueuedAt);
    })().catch((error) => logError("processing_chain_failed", error, { id }));
    this.processingTasks.add(task);
    void task.finally(() => {
      this.processingTasks.delete(task);
      // A cancelled attempt can drain after reprocess registered a new one; leave that one alone.
      if (this.processingControllers.get(id) !== controller) return;
      this.processingControllers.delete(id);
      this.processingOrder = this.processingOrder.filter((queuedID) => queuedID !== id);
      this.beginWarmup();
    });
  }
  private async process(
    id: string,
    previous: DictationContinuation | undefined,
    signal: AbortSignal,
    enqueuedAt = performance.now(),
  ) {
    let startedAt = performance.now();
    let transcribeMs = 0;
    let proofMs = 0;
    try {
      const speechResult = await this.withStage("speech", async () => {
        startedAt = performance.now();
        let record = await this.withGenerationLock(id, async () => {
          const record = this.getInternal(id);
          signal.throwIfAborted();
          if (terminal(record)) return undefined;
          record.status = "transcribing";
          await this.save(record);
          return record;
        });
        if (!record) return undefined;
        const settings = record.settings.preferences;
        const transcribeStartedAt = performance.now();
        const speech = await this.inference.transcribe(
          join(this.directory(id), "inference.wav"),
          settings.language,
          // Parakeet has no vocabulary prompt; dictionary rules apply after recognition.
          [],
          (value) => {
            this.progress(id, value);
          },
          signal,
          record.inferenceAudio ? record.inferenceAudio.frameCount / 16000 : undefined,
        );
        transcribeMs = Math.round(performance.now() - transcribeStartedAt);
        signal.throwIfAborted();
        record.rawText = speech.text;
        record.detectedLanguage = speech.language === "auto" ? undefined : speech.language;
        record.recognitionHints = speech.hints;
        record.speech = {
          modelID: "parakeet-tdt-0.6b-v3",
          modelSHA256: speech.modelSHA256,
          backend: this.speechBackend,
          engineVersion: speech.engineVersion,
          processingSeconds: speech.processingSeconds,
        };
        const cleaned = cleanTranscript(speech.text);
        const transcript = applyDictionary(settings.dictionary, cleaned, 24 * 1024);
        const structured = formatSpokenList(transcript, previous?.list);
        record.formattingRejectionReason = structured.formattingRejectionReason;
        record.consumedListControls = structured.consumedControls;
        return { record, settings, speech, cleaned, transcript, structured };
      });
      if (!speechResult) return;
      const { settings, speech, cleaned, transcript, structured } = speechResult;
      const record = speechResult.record;
      await this.withStage("proof", async () => {
        if (settings.textCorrectionEnabled && structured.text) {
          const updated = await this.withGenerationLock(id, async () => {
            signal.throwIfAborted();
            if (terminal(this.getInternal(id))) return false;
            record.status = "proofreading";
            delete record.progress;
            await this.save(record);
            return true;
          });
          if (!updated) return;
        }
        const proofStartedAt = performance.now();
        const processing = await this.proofread(
          structured.text,
          settings,
          cleaned !== transcript,
          speech.language === "auto" ? settings.language : speech.language,
          signal,
        );
        proofMs = Math.round(performance.now() - proofStartedAt);
        signal.throwIfAborted();
        record.textProcessing = processing;
        if (["applied", "unchanged", "rejected"].includes(processing.status)) {
          const all = dictionaryVocabularyTerms(settings.dictionary),
            included = modelHints(all);
          record.proofreadingHints = {
            includedTerms: included,
            omittedTerms: all.filter((term) => !included.includes(term)),
          };
        }
        if (settings.textCorrectionEnabled)
          record.proofreading = {
            modelID: "Qwen3-4B-Instruct-2507",
            modelSHA256: processing.modelSHA256,
            backend: this.proofBackend,
            engineVersion: processing.engineVersion,
            processingSeconds: processing.processingSeconds,
          };
        const formatted = { ...structured, text: processing.outputText };
        const composition = composeDictation(formatted, previous);
        record.finalText = formatted.text;
        record.insertionText = composition.insertion;
        record.previewText = composition.preview;
        record.continuation = composition.continuation;
        record.status = "completed";
        record.updatedAt = now();
        record.progress = 1;
        await this.withGenerationLock(id, async () => {
          signal.throwIfAborted();
          if (terminal(this.getInternal(id))) return;
          await atomicPrivateWrite(join(this.directory(id), "transcript.txt"), record.finalText);
          await this.save(record);
        });
        logInfo("generation_processed", {
          id,
          queueWaitMs: Math.round(startedAt - enqueuedAt),
          transcribeMs,
          proofMs,
          totalMs: Math.round(performance.now() - startedAt),
          status: "completed",
        });
      });
    } catch (error) {
      if (!signal.aborted)
        logError("generation_failed", error, {
          id,
          queueWaitMs: Math.round(startedAt - enqueuedAt),
          transcribeMs,
          proofMs,
          totalMs: Math.round(performance.now() - startedAt),
        });
      await this.withGenerationLock(id, async () => {
        const record = this.records.get(id);
        if (!record || terminal(record)) return;
        if (this.processingControllers.get(id)?.signal !== signal) return;
        const failed = copy(record);
        if (this.stopping && failed.inferenceAudio) {
          failed.status = "queued";
          delete failed.error;
          delete failed.progress;
          failed.updatedAt = now();
          await this.save(failed).catch(() => this.publish(failed));
          return;
        }
        failed.status = signal.aborted ? "cancelled" : "failed";
        failed.error = signal.aborted
          ? "Recording cancelled."
          : error instanceof Error
            ? error.message
            : "Processing failed.";
        failed.updatedAt = now();
        delete failed.progress;
        await this.save(failed).catch(() => this.publish(failed));
      });
    }
  }

  private async proofread(
    text: string,
    settings: ServerPreferences,
    dictionaryChanged: boolean,
    language: string,
    signal: AbortSignal,
  ) {
    const started = performance.now(),
      terms = dictionaryVocabularyTerms(settings.dictionary);
    const make = (
      status: TextProcessingRecord["status"],
      extra: Partial<TextProcessingRecord> = {},
    ) =>
      processingRecord({
        dictionaryTerms: terms,
        dictionaryChangedText: dictionaryChanged,
        inputText: text,
        outputText: text,
        enabled: settings.textCorrectionEnabled,
        status,
        modelID: settings.textCorrectionEnabled ? "Qwen3-4B-Instruct-2507" : undefined,
        wallSeconds: (performance.now() - started) / 1000,
        ...extra,
      });
    if (!settings.textCorrectionEnabled) return make("disabled");
    if (!text) return make("skipped", { reason: "No text to correct." });
    if (graphemes(text) > maxInputCharacters)
      return make("skipped", { reason: "The transcript exceeded the correction length limit." });
    try {
      const proof = await this.inference.correct(
        text,
        modelHints(terms),
        language,
        settings.proofreadingPrompt,
        signal,
      );
      signal.throwIfAborted();
      const candidate = applyDictionary(settings.dictionary, proof.text.trim(), 24 * 1024);
      const evaluation = await evaluateCorrectionInWorker(text, candidate, terms, signal);
      signal.throwIfAborted();
      const extra = {
        proposedText: candidate,
        verifiedRepairs: evaluation.verifiedRepairs,
        processingSeconds: proof.processingSeconds,
        engineVersion: proof.engineVersion,
        modelSHA256: proof.modelSHA256,
      };
      return evaluation.rejectionReason
        ? make("rejected", { ...extra, reason: evaluation.rejectionReason })
        : make(candidate === text ? "unchanged" : "applied", { ...extra, outputText: candidate });
    } catch (error) {
      signal.throwIfAborted();
      return make("failed", {
        reason: error instanceof Error ? error.message : "Proofreading failed.",
      });
    }
  }
  private async save(record: GenerationRecord) {
    delete record.queuePosition;
    const data = JSON.stringify(record);
    if (Buffer.byteLength(data) > MAXIMUM_METADATA_BYTES)
      throw new ServiceError(
        413,
        "metadata_too_large",
        "The generation metadata exceeded its 1 MiB storage limit.",
      );
    await atomicPrivateWrite(join(this.directory(record.id), "metadata.json"), data);
    this.publish(record);
  }
  private publish(record: GenerationRecord) {
    this.records.set(record.id.toUpperCase(), copy(record));
    this.recordVersions.set(record.id, (this.recordVersions.get(record.id) ?? 0) + 1);
    const group = this.subscribers.get(record.id);
    if (group)
      for (const watcher of group) {
        this.yieldTo(watcher, record);
        if (terminal(record)) {
          watcher.done = true;
          watcher.wake?.();
        }
      }
    if (terminal(record)) {
      this.subscribers.delete(record.id);
      this.recordVersions.delete(record.id);
      this.lastProgressYieldAt.delete(record.id);
    }
  }
  private yieldTo(watcher: Watcher, record: GenerationRecord) {
    const decorated = this.decorate(copy(record));
    const version = this.recordVersions.get(record.id) ?? 0;
    const nowMs = Date.now();
    if (
      !terminal(record) &&
      watcher.lastVersion === version &&
      watcher.lastQueuePosition === decorated.queuePosition &&
      watcher.lastSentAt !== undefined &&
      nowMs - watcher.lastSentAt < HEARTBEAT_MS / 2
    )
      return;
    watcher.queue.push(decorated);
    if (watcher.queue.length > 8) watcher.queue.shift();
    watcher.lastVersion = version;
    watcher.lastQueuePosition = decorated.queuePosition;
    watcher.lastSentAt = nowMs;
    watcher.wake?.();
  }
  private progress(id: string, value: number) {
    const record = this.records.get(id);
    if (!record || record.status !== "transcribing" || !Number.isFinite(value)) return;
    const next = Math.max(0, Math.min(1, value));
    if (record.progress === next) return;
    record.progress = next;
    this.recordVersions.set(id, (this.recordVersions.get(id) ?? 0) + 1);
    const nowMs = Date.now();
    if (next < 1 && nowMs - (this.lastProgressYieldAt.get(id) ?? 0) < 250) return;
    this.lastProgressYieldAt.set(id, nowMs);
    for (const watcher of this.subscribers.get(id) ?? []) this.yieldTo(watcher, record);
  }
  private async cleanSealPartials(id: string) {
    for (const name of ["inference.wav.partial", "original.wav.partial"])
      await rm(join(this.directory(id), name), { force: true }).catch(() => {});
  }
  private async cleanPartial(id: string) {
    this.uploads.delete(id);
    for (const name of [
      "inference.raw",
      "original.raw",
      "inference.wav.partial",
      "original.wav.partial",
    ])
      await rm(join(this.directory(id), name), { force: true }).catch(() => {});
  }
  private beginWarmup(force = false) {
    if (this.stopping || this.warming || this.processingControllers.size) return;
    if (!force && Date.now() < this.nextWarmupAt) return;
    this.warming = true;
    const controller = new AbortController();
    this.warmController = controller;
    this.warmTask = this.inference
      .warmUp(this.preferences.preferences.textCorrectionEnabled, controller.signal)
      .then(
        () => {
          this.speechLoadError = undefined;
          this.proofLoadError = undefined;
          this.warmupFailures = 0;
          this.nextWarmupAt = 0;
          logInfo("warmup_succeeded");
        },
        async (error) => {
          // A cancelled take or shutdown can interrupt loading; that is not a failure.
          if (error instanceof InferenceError && error.code === "cancelled") return;
          const snapshot = await this.inference.readiness(false);
          const unavailable = error instanceof InferenceError && error.code === "unavailable";
          if (
            snapshot.speechLoaded &&
            this.preferences.preferences.textCorrectionEnabled &&
            !snapshot.proofLoaded
          ) {
            this.proofLoadError = unavailable
              ? error.message
              : "Proofreading model failed to load.";
            this.speechLoadError = undefined;
          } else if (!snapshot.speechLoaded) {
            this.speechLoadError = unavailable ? error.message : "Speech model failed to load.";
          } else {
            this.speechLoadError = undefined;
            this.proofLoadError = undefined;
          }
          this.warmupFailures++;
          const retryAfterMs = Math.min(300_000, 5_000 * 2 ** (this.warmupFailures - 1));
          this.nextWarmupAt = Date.now() + retryAfterMs;
          logWarn("warmup_failed", {
            attempt: this.warmupFailures,
            retryAfterMs,
            speech: !snapshot.speechLoaded,
          });
        },
      )
      .catch(() => {})
      .finally(() => {
        this.warming = false;
        this.warmController = undefined;
        this.warmTask = undefined;
      });
  }
  /** Queue recordings through a reload, but not behind a helper that failed to start. */
  private speechLoadFailure(state: { speechLoaded: boolean }) {
    return state.speechLoaded ? undefined : this.speechLoadError;
  }
  private get speechBackend() {
    return process.platform === "darwin" ? "parakeet.cpp/Metal" : "parakeet.cpp";
  }
  private get proofBackend() {
    return process.platform === "darwin" ? "MLX" : "llama.cpp";
  }
}
