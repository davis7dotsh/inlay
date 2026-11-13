import { constants } from "node:fs";
import { open, rm } from "node:fs/promises";
import { join } from "node:path";
import {
  MAXIMUM_METADATA_BYTES,
  type ServerPreferences,
  type DictationContinuation,
  type TextProcessingRecord,
} from "./api.ts";
import type { InferenceBackend, SpeechInferenceResult } from "./inference/native-inference.ts";
import { atomicPrivateWrite, ensureDirectory, readRegularFile } from "./storage.ts";
import { validScreenContextTerm } from "./domain/dictionary.ts";
import {
  createLongRecordingTextState,
  processLongRecordingTextWindow,
  finalizeLongRecordingText,
  drainLongRecordingTextSpans,
  longRecordingTextResult,
  type LongRecordingTextSpan,
} from "./domain/long-recording-text.ts";

const rate = 16_000;
const target = 30 * rate;
const cap = 40 * rate;
type TextState = ReturnType<typeof createLongRecordingTextState>;
interface Checkpoint {
  version: 1;
  speechFrames: number;
  speechCount: number;
  proofCount: number;
  text: TextState;
}
interface SpeechWindow {
  firstFrame: number;
  frameCount: number;
  speech: SpeechInferenceResult;
}
interface Session {
  checkpoint: Checkpoint;
  previous?: DictationContinuation;
  settings: ServerPreferences;
  /** Optional Qwen hints bound before upload, replaced by any sent at Finish. */
  screenContextTerms: string[];
  available: number;
  final: boolean;
  controller: AbortController;
  speech?: Promise<void>;
  proof?: Promise<void>;
  error?: unknown;
  captureRetries: number;
  mutation: Promise<unknown>;
  finishing?: Promise<unknown>;
}

/** Durable source offsets, independent FIFO helpers, and no guessed token seams.
 * Parakeet has no timed-span contract: each nonoverlapping acoustic interval is
 * decoded once. Prefer a pause near 30 s; a continuous speaker gets a bounded
 * lowest-energy cut by 40 s. Never delete repeated words using text matching.
 */
export class RollingTranscription {
  private sessions = new Map<string, Promise<Session>>();
  constructor(
    private readonly root: string,
    private readonly inference: InferenceBackend,
    private readonly stage: <T>(
      kind: "speech" | "proof",
      work: () => Promise<T>,
      signal?: AbortSignal,
    ) => Promise<T>,
  ) {}

  private directory(id: string) {
    return join(this.root, id, "rolling");
  }
  private async session(id: string, settings: ServerPreferences) {
    let pending = this.sessions.get(id);
    if (!pending) {
      pending = (async () => {
        await ensureDirectory(this.directory(id));
        let previous: DictationContinuation | undefined;
        let screenContextTerms: string[] = [];
        try {
          const context = JSON.parse(
            (
              await readRegularFile(
                join(this.root, id, "capture-context.json"),
                MAXIMUM_METADATA_BYTES,
              )
            ).toString(),
          ) as { previous?: DictationContinuation; screenContextTerms?: string[] };
          previous = context.previous;
          const terms = context.screenContextTerms ?? [];
          if (settings.textCorrectionEnabled)
            screenContextTerms = terms.filter(validScreenContextTerm).slice(0, 40);
        } catch (error) {
          if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error;
        }
        let checkpoint: Checkpoint;
        try {
          checkpoint = JSON.parse(
            (
              await readRegularFile(
                join(this.directory(id), "checkpoint.json"),
                MAXIMUM_METADATA_BYTES,
              )
            ).toString(),
          ) as Checkpoint;
          if (
            checkpoint.version !== 1 ||
            ![checkpoint.speechFrames, checkpoint.speechCount, checkpoint.proofCount].every(
              Number.isSafeInteger,
            ) ||
            checkpoint.speechFrames < 0 ||
            checkpoint.proofCount < 0 ||
            checkpoint.proofCount > checkpoint.speechCount
          )
            throw new Error("Invalid rolling transcription checkpoint. Audio is retained.");
        } catch (error) {
          if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error;
          checkpoint = {
            version: 1,
            speechFrames: 0,
            speechCount: 0,
            proofCount: 0,
            text: createLongRecordingTextState(previous?.list),
          };
        }
        return {
          checkpoint,
          previous,
          settings: structuredClone(settings),
          screenContextTerms,
          available: checkpoint.speechFrames,
          final: false,
          controller: new AbortController(),
          mutation: Promise.resolve(),
          captureRetries: 0,
        } satisfies Session;
      })();
      this.sessions.set(id, pending);
      const initializing = pending;
      void pending.catch(() => {
        if (this.sessions.get(id) === initializing) this.sessions.delete(id);
      });
    }
    return pending;
  }

  private mutate(session: Session, work: () => Promise<void>) {
    const next = session.mutation.then(work);
    session.mutation = next.catch(() => {});
    return next;
  }
  private save(id: string, checkpoint: Checkpoint) {
    return atomicPrivateWrite(
      join(this.directory(id), "checkpoint.json"),
      JSON.stringify(checkpoint),
    );
  }

  async notify(id: string, frames: number, settings: ServerPreferences) {
    const session = await this.session(id, settings);
    session.available = Math.max(session.available, frames);
    if (session.controller.signal.aborted || session.final) return;
    // A later upload can retry one transient capture-time failure from its
    // durable cursor. Persistent failures wait for explicit Finish/Retry.
    if (session.error && !session.speech && !session.proof && session.captureRetries < 1) {
      session.captureRetries++;
      session.error = undefined;
      this.startProof(id, session);
    }
    if (!session.error) this.startSpeech(id, session);
  }

  private startSpeech(id: string, session: Session) {
    if (session.speech) return;
    const available = session.available;
    session.speech = this.speechLoop(id, session)
      .catch((error: unknown) => {
        session.error = error;
      })
      .finally(() => {
        session.speech = undefined;
        if (!session.error && !session.controller.signal.aborted && session.available > available)
          this.startSpeech(id, session);
      });
  }
  private startProof(id: string, session: Session) {
    if (session.proof) return;
    session.proof = this.proofLoop(id, session)
      .catch((error: unknown) => {
        session.error = error;
      })
      .finally(() => {
        session.proof = undefined;
        if (
          !session.error &&
          !session.controller.signal.aborted &&
          session.checkpoint.proofCount < session.checkpoint.speechCount
        )
          this.startProof(id, session);
      });
  }

  private async readAudio(id: string, first: number, count: number) {
    let file;
    let offset = first * 4;
    try {
      file = await open(
        join(this.root, id, "inference.raw"),
        constants.O_RDONLY | constants.O_NOFOLLOW,
      );
    } catch (error) {
      if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error;
      file = await open(
        join(this.root, id, "inference.wav"),
        constants.O_RDONLY | constants.O_NOFOLLOW,
      );
      offset += 44;
    }
    try {
      if (!(await file.stat()).isFile()) throw new Error("Recording audio is not a regular file.");
      const bytes = Buffer.alloc(count * 4);
      let read = 0;
      while (read < bytes.length) {
        const result = await file.read(bytes, read, bytes.length - read, offset + read);
        if (!result.bytesRead) throw new Error("Committed recording audio is missing.");
        read += result.bytesRead;
      }
      return bytes;
    } finally {
      await file.close();
    }
  }

  private cut(bytes: Buffer, final: boolean) {
    const frames = bytes.length / 4;
    if (final && frames <= cap) return frames;
    const block = 320;
    let best = cap,
      score = Infinity,
      quiet = 0;
    for (let frame = target; frame + block <= frames; frame += block) {
      let energy = 0;
      for (let i = frame; i < frame + block; i++) {
        const value = bytes.readFloatLE(i * 4);
        energy += value * value;
      }
      if (energy < score) {
        score = energy;
        best = frame + block / 2;
      }
      quiet = energy / block < 0.000001 ? quiet + block : 0;
      if (quiet >= rate / 4) return frame + block - Math.floor(quiet / 2);
    }
    return frames >= cap ? best : undefined;
  }

  private async speechLoop(id: string, session: Session) {
    const signal = session.controller.signal;
    while (true) {
      signal.throwIfAborted();
      const first = session.checkpoint.speechFrames;
      const count = Math.min(cap, session.available - first);
      if (!count || (!session.final && count < target + rate / 4)) return;
      const bytes = await this.readAudio(id, first, count);
      const last = session.final && first + count === session.available;
      const cut = this.cut(bytes, last);
      if (cut === undefined) return;
      // Parakeet requires at least 0.2 s. Padding belongs only to the
      // inference WAV; the durable cursor always advances real source frames.
      const inferenceFrames = Math.max(cut, rate / 5);
      const audio = Buffer.alloc(inferenceFrames * 4);
      bytes.copy(audio, 0, 0, cut * 4);
      const header = Buffer.alloc(44);
      header.write("RIFF");
      header.writeUInt32LE(audio.length + 36, 4);
      header.write("WAVEfmt ", 8);
      header.writeUInt32LE(16, 16);
      header.writeUInt16LE(3, 20);
      header.writeUInt16LE(1, 22);
      header.writeUInt32LE(rate, 24);
      header.writeUInt32LE(rate * 4, 28);
      header.writeUInt16LE(4, 32);
      header.writeUInt16LE(32, 34);
      header.write("data", 36);
      header.writeUInt32LE(audio.length, 40);
      const path = join(this.directory(id), "window.wav");
      await atomicPrivateWrite(path, Buffer.concat([header, audio]));
      let speech: SpeechInferenceResult;
      try {
        speech = await this.stage(
          "speech",
          () =>
            this.inference.transcribe(
              path,
              session.settings.language,
              [],
              undefined,
              signal,
              inferenceFrames / rate,
            ),
          signal,
        );
      } finally {
        await rm(path, { force: true });
      }
      signal.throwIfAborted();
      const window: SpeechWindow = { firstFrame: first, frameCount: cut, speech };
      await this.mutate(session, async () => {
        const checkpoint = structuredClone(session.checkpoint);
        await atomicPrivateWrite(
          join(this.directory(id), `speech-${checkpoint.speechCount}.json`),
          JSON.stringify(window),
        );
        checkpoint.speechCount++;
        checkpoint.speechFrames += cut;
        await this.save(id, checkpoint);
        session.checkpoint = checkpoint;
      });
      this.startProof(id, session);
    }
  }

  private async proofLoop(id: string, session: Session) {
    while (session.checkpoint.proofCount < session.checkpoint.speechCount) {
      const signal = session.controller.signal;
      signal.throwIfAborted();
      const index = session.checkpoint.proofCount;
      const window = JSON.parse(
        (
          await readRegularFile(
            join(this.directory(id), `speech-${index}.json`),
            MAXIMUM_METADATA_BYTES,
          )
        ).toString(),
      ) as SpeechWindow;
      const text = await this.stage(
        "proof",
        () =>
          processLongRecordingTextWindow(
            structuredClone(session.checkpoint.text),
            window.speech.text,
            session.settings,
            this.inference,
            signal,
            session.screenContextTerms,
          ),
        signal,
      );
      const spans = drainLongRecordingTextSpans(text);
      await this.mutate(session, async () => {
        signal.throwIfAborted();
        const checkpoint = structuredClone(session.checkpoint);
        await atomicPrivateWrite(
          join(this.directory(id), `proof-${index}.json`),
          JSON.stringify(spans),
        );
        checkpoint.proofCount++;
        checkpoint.text = text;
        await this.save(id, checkpoint);
        session.checkpoint = checkpoint;
      });
    }
  }

  async finish(
    id: string,
    frames: number,
    settings: ServerPreferences,
    signal: AbortSignal,
    screenContextTerms: string[] = [],
  ) {
    const session = await this.session(id, settings);
    const task = this.finishSession(id, frames, settings, signal, screenContextTerms, session);
    session.finishing = task;
    try {
      return await task;
    } finally {
      if (session.finishing === task) session.finishing = undefined;
    }
  }

  private async finishSession(
    id: string,
    frames: number,
    settings: ServerPreferences,
    signal: AbortSignal,
    screenContextTerms: string[],
    session: Session,
  ) {
    const abort = () => session.controller.abort();
    signal.addEventListener("abort", abort, { once: true });
    try {
      signal.throwIfAborted();
      session.available = frames;
      session.final = true;
      // Windows proofread from here on, including a recovered take's, use the
      // terms sent at Finish. Committed windows are never proofread again.
      if (screenContextTerms.length) session.screenContextTerms = screenContextTerms;
      if (session.controller.signal.aborted)
        throw new Error("Recording processing was interrupted. Retry the saved recording.");
      // A capture-time helper error is retryable from the last durable cursor.
      await session.speech;
      await session.proof;
      session.error = undefined;
      this.startSpeech(id, session);
      await session.speech;
      if (session.error) throw session.error;
      this.startProof(id, session);
      await session.proof;
      if (session.error) throw session.error;
      if (
        session.checkpoint.speechFrames !== frames ||
        session.checkpoint.proofCount !== session.checkpoint.speechCount
      )
        throw new Error("Recording processing has not drained its acknowledged audio.");
      if (!session.checkpoint.text.finalized) {
        const text = await this.stage(
          "proof",
          () =>
            finalizeLongRecordingText(
              structuredClone(session.checkpoint.text),
              settings,
              this.inference,
              session.controller.signal,
              session.screenContextTerms,
            ),
          session.controller.signal,
        );
        session.controller.signal.throwIfAborted();
        const spans = drainLongRecordingTextSpans(text);
        await atomicPrivateWrite(
          join(this.directory(id), "final-proof.json"),
          JSON.stringify(spans),
        );
        const checkpoint = { ...session.checkpoint, text };
        await this.save(id, checkpoint);
        session.checkpoint = checkpoint;
      }
      const spans: LongRecordingTextSpan[] = [];
      let seconds = 0;
      let lastSpeech: SpeechInferenceResult | undefined;
      for (let i = 0; i < session.checkpoint.proofCount; i++) {
        spans.push(
          ...(JSON.parse(
            (
              await readRegularFile(
                join(this.directory(id), `proof-${i}.json`),
                MAXIMUM_METADATA_BYTES,
              )
            ).toString(),
          ) as LongRecordingTextSpan[]),
        );
        const window = JSON.parse(
          (
            await readRegularFile(
              join(this.directory(id), `speech-${i}.json`),
              MAXIMUM_METADATA_BYTES,
            )
          ).toString(),
        ) as SpeechWindow;
        seconds += window.speech.processingSeconds;
        lastSpeech = window.speech;
      }
      spans.push(
        ...(JSON.parse(
          (
            await readRegularFile(
              join(this.directory(id), "final-proof.json"),
              MAXIMUM_METADATA_BYTES,
            )
          ).toString(),
        ) as LongRecordingTextSpan[]),
      );
      const result = longRecordingTextResult(session.checkpoint.text, spans);
      const records = spans.flatMap((span) => span.processing);
      const lastProof = records.findLast((record) => record.engineVersion !== undefined);
      const status: TextProcessingRecord["status"] = !settings.textCorrectionEnabled
        ? "disabled"
        : records.some((record) => record.status === "failed")
          ? "failed"
          : records.some((record) => record.status === "rejected")
            ? "rejected"
            : records.some((record) => record.status === "applied")
              ? "applied"
              : records.length
                ? "unchanged"
                : "skipped";
      const processing: TextProcessingRecord = {
        dictionaryTerms: [...new Set(records.flatMap((record) => record.dictionaryTerms))],
        dictionaryChangedText: records.some((record) => record.dictionaryChangedText),
        inputText: records.map((record) => record.inputText).join(" "),
        outputText: result.cleanedText,
        enabled: settings.textCorrectionEnabled,
        status,
        reason: records.find((record) => record.status === "failed" || record.status === "rejected")
          ?.reason,
        modelID: settings.textCorrectionEnabled ? "Qwen3-4B-Instruct-2507" : undefined,
        modelSHA256: lastProof?.modelSHA256,
        engineVersion: lastProof?.engineVersion,
        processingSeconds: records.reduce(
          (total, record) => total + (record.processingSeconds ?? 0),
          0,
        ),
        wallSeconds: records.reduce((total, record) => total + (record.wallSeconds ?? 0), 0),
      };
      return {
        ...result,
        processing,
        previous: session.previous,
        speech: lastSpeech,
        speechSeconds: seconds,
      };
    } finally {
      signal.removeEventListener("abort", abort);
    }
  }

  /** Release only live tasks; durable cursors survive an explicit Retry. */
  async release(id: string) {
    const pending = this.sessions.get(id);
    try {
      // Initialization may have failed before a Session existed. It must not
      // prevent Cancel/Delete/Retry from releasing the cached promise.
      const session = await pending?.catch(() => undefined);
      if (session) {
        session.controller.abort();
        // Queued stages settle promptly on abort. Active stages and all file
        // writes must finish before callers remove or reuse this directory.
        await Promise.allSettled([session.speech, session.proof, session.finishing]);
        await session.mutation;
      }
    } finally {
      if (this.sessions.get(id) === pending) this.sessions.delete(id);
    }
  }
  async stop() {
    const initialized = await Promise.allSettled(this.sessions.values());
    const sessions = initialized.flatMap((result) =>
      result.status === "fulfilled" ? [result.value] : [],
    );
    for (const session of sessions) session.controller.abort();
    await Promise.allSettled(
      sessions
        .flatMap((session) => [session.speech, session.proof, session.finishing, session.mutation])
        .filter((task): task is Promise<unknown> => task !== undefined),
    );
  }
}
