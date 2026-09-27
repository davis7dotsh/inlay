import { afterEach, expect, setSystemTime, test } from "bun:test";
import { mkdtemp, readFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { GenerationService } from "../src/generation-service.ts";
import type { InferenceBackend } from "../src/inference/native-inference.ts";

class FakeInference implements InferenceBackend {
  failProof = false;
  blocked = false;
  text = "Hello Codex.";
  language = "en";
  proofreadingLanguage: string | undefined;
  readiness() {
    return Promise.resolve({
      available: true,
      speechLoaded: true,
      proofLoaded: true,
      message: "Ready",
    });
  }
  warmUp() {
    return Promise.resolve();
  }
  async transcribe(
    _path: string,
    _language: string,
    _terms: string[],
    progress?: (value: number) => void,
    signal?: AbortSignal,
  ) {
    if (this.blocked)
      await new Promise<void>((_resolve, reject) => {
        if (signal?.aborted) reject(new Error("Cancelled"));
        else
          signal?.addEventListener("abort", () => reject(new Error("Cancelled")), { once: true });
      });
    progress?.(0.5);
    return {
      text: this.text,
      language: this.language,
      processingSeconds: 0.1,
      audioSeconds: 0.25,
      engineVersion: "fixture",
    };
  }
  correct(text: string, _terms?: string[], language?: string) {
    this.proofreadingLanguage = language;
    return this.failProof
      ? Promise.reject(new Error("Proof unavailable."))
      : Promise.resolve({ text, processingSeconds: 0.01 });
  }
  cancel() {
    return Promise.resolve();
  }
  shutdown() {
    return Promise.resolve();
  }
}
const request = () => ({
  requestID: randomUUID(),
  device: { id: "test-device", name: "Test Mac" },
  mode: "test" as const,
});
const format = { sampleRate: 16000, channels: 1 },
  pcm = () => Buffer.alloc(16_000);
const resources: { service: GenerationService; path: string }[] = [];
afterEach(async () => {
  for (const { service, path } of resources.splice(0)) {
    await service.shutdown();
    await rm(path, { recursive: true, force: true });
  }
});
async function setup(inference = new FakeInference()) {
  const path = await mkdtemp(join(tmpdir(), "v07-generation-test-"));
  const service = await GenerationService.open(
    { dataDirectory: path, development: true },
    inference,
  );
  resources.push({ service, path });
  const preferences = await service.getPreferences();
  preferences.preferences.keepOriginalAudio = false;
  await service.updatePreferences(preferences);
  return { service, path, inference };
}
async function completed(service: GenerationService, id: string) {
  for await (const record of await service.events(id))
    if (["completed", "failed", "cancelled"].includes(record.status)) return record;
  throw new Error("No terminal event.");
}
async function upload(service: GenerationService) {
  const record = await service.create(request());
  await service.appendAudio(record.id, "inference", 0, format, pcm());
  return record;
}

test("Parakeet uses the proofreading preference without inventing detected-language metadata", async () => {
  const { service, inference } = await setup();
  inference.language = "auto";
  const preferences = await service.getPreferences();
  preferences.preferences.language = "es";
  await service.updatePreferences(preferences);
  const record = await upload(service);
  await service.finish(record.id, { inferenceFrames: 4000 });
  const result = await completed(service, record.id);
  expect(result.status).toBe("completed");
  expect(result.detectedLanguage).toBeUndefined();
  expect(result.speech?.modelID).toBe("parakeet-tdt-0.6b-v3");
  expect(inference.proofreadingLanguage).toBe("es");
});

test("repeated requests return the same frozen generation while new recordings are accepted", async () => {
  const { service } = await setup(),
    input = request();
  const [a, b] = await Promise.all([service.create(input), service.create(input)]);
  expect(a.id).toBe(b.id);
  expect((await service.create(request())).id).not.toBe(a.id);
  expect((await service.health()).ready).toBe(true);
  const preferences = await service.getPreferences();
  preferences.preferences.language = "es";
  await service.updatePreferences(preferences);
  expect((await service.get(a.id)).settings.preferences.language).toBe("en");
  await expect(service.updatePreferences(preferences)).rejects.toMatchObject({
    code: "stale_preferences",
  });
});
test("concurrent recordings have independent upload streams", async () => {
  const { service } = await setup();
  const records = await Promise.all(Array.from({ length: 4 }, () => upload(service)));
  expect(new Set(records.map((record) => record.id)).size).toBe(4);
  expect((await service.health()).ready).toBe(true);
  await Promise.all(records.map((record) => service.finish(record.id, { inferenceFrames: 4000 })));
  const results = await Promise.all(records.map((record) => completed(service, record.id)));
  expect(results.map((record) => record.status)).toEqual(Array(4).fill("completed"));
});
test("chunk ordering, finite samples, byte-identical replay and format restrictions", async () => {
  const { service } = await setup(),
    record = await service.create(request());
  await expect(service.appendAudio(record.id, "inference", 1, format, pcm())).rejects.toMatchObject(
    { code: "missing_chunk" },
  );
  const nan = pcm();
  nan.writeUInt32LE(0x7fc00000);
  await expect(service.appendAudio(record.id, "inference", 0, format, nan)).rejects.toMatchObject({
    code: "invalid_samples",
  });
  const receipt = await service.appendAudio(record.id, "inference", 0, format, pcm());
  expect(receipt).toEqual({ nextSequence: 1, frameCount: 4000 });
  expect(await service.appendAudio(record.id, "inference", 0, format, pcm())).toEqual(receipt);
  const conflict = pcm();
  conflict.writeFloatLE(0.5);
  await expect(
    service.appendAudio(record.id, "inference", 0, format, conflict),
  ).rejects.toMatchObject({ code: "conflicting_chunk" });
  await expect(
    service.appendAudio(record.id, "inference", 1, { channels: 2, sampleRate: 16000 }, pcm()),
  ).rejects.toMatchObject({ code: "invalid_format" });
});
test("seals WAV, completes pipeline, delivery, artifact and history deletion", async () => {
  const { service, path } = await setup(),
    record = await upload(service);
  await expect(service.finish(record.id, { inferenceFrames: 3999 })).rejects.toMatchObject({
    code: "incomplete_audio",
  });
  expect((await service.finish(record.id, { inferenceFrames: 4000 })).status).toBe("queued");
  const final = await completed(service, record.id);
  expect(final.status).toBe("completed");
  expect(final.finalText).toBe("Hello Codex.");
  expect(final.inferenceAudio).toMatchObject({ frameCount: 4000, byteCount: 16044 });
  const wav = await readFile(join(path, "generations", record.id, "inference.wav"));
  expect(wav.subarray(0, 4).toString()).toBe("RIFF");
  expect(wav.readUInt16LE(20)).toBe(3);
  expect(wav.length).toBe(16044);
  expect((await service.finish(record.id, { inferenceFrames: 4000 })).id).toBe(record.id);
  await expect(service.finish(record.id, { inferenceFrames: 4001 })).rejects.toMatchObject({
    code: "conflicting_finish",
  });
  const receipt = { status: "tested", reportedAt: "2000-01-01T00:00:00Z" },
    delivered = await service.recordDelivery(record.id, receipt);
  expect(delivered.delivery?.reportedAt).not.toBe(receipt.reportedAt);
  expect((await service.recordDelivery(record.id, receipt)).delivery).toEqual(delivered.delivery);
  await expect(
    service.recordDelivery(record.id, { ...receipt, status: "copied" }),
  ).rejects.toMatchObject({ code: "delivery_recorded" });
  const handle = await service.artifact(record.id, "transcript.txt");
  expect((await handle.readFile()).toString()).toBe(final.finalText);
  await handle.close();
  await expect(service.artifact(record.id, "../preferences.json")).rejects.toMatchObject({
    code: "artifact_not_found",
  });
  await service.delete(record.id);
  await expect(service.get(record.id)).rejects.toMatchObject({ status: 404 });
});
test("proofreading failure preserves deterministic transcript", async () => {
  const { service, inference } = await setup();
  inference.failProof = true;
  const record = await upload(service);
  await service.finish(record.id, { inferenceFrames: 4000 });
  const final = await completed(service, record.id);
  expect(final.status).toBe("completed");
  expect(final.finalText).toBe("Hello Codex.");
  expect(final.textProcessing?.status).toBe("failed");
});
test("cancel wakes only that recording’s terminal subscribers", async () => {
  const { service, inference } = await setup();
  inference.blocked = true;
  const record = await upload(service);
  await service.finish(record.id, { inferenceFrames: 4000 });
  const final = completed(service, record.id);
  expect((await service.cancel(record.id)).status).toBe("cancelled");
  expect((await final).status).toBe("cancelled");
  expect((await service.create(request())).status).toBe("receiving");
});
test("disconnect returns from pending next and releases watcher capacity", async () => {
  const { service } = await setup(),
    record = await service.create(request()),
    iterator = (await service.events(record.id))[Symbol.asyncIterator]();
  await iterator.next();
  const waiting = iterator.next();
  await iterator.return?.();
  expect((await waiting).done).toBe(true);
  const watchers = await Promise.all(Array.from({ length: 8 }, () => service.events(record.id)));
  await expect(service.events(record.id)).rejects.toMatchObject({ status: 429 });
  for (const watcher of watchers) await watcher[Symbol.asyncIterator]().return?.();
});
test("restart recovers unfinished metadata and removes partial audio", async () => {
  const { service, path } = await setup(),
    record = await upload(service),
    recovered = await GenerationService.open(
      { dataDirectory: path, development: true },
      new FakeInference(),
    );
  resources.push({ service: recovered, path });
  expect((await recovered.get(record.id)).status).toBe("failed");
  expect((await recovered.get(record.id)).error).toContain("Server restarted");
  await expect(
    readFile(join(path, "generations", record.id, "inference.raw")),
  ).rejects.toMatchObject({ code: "ENOENT" });
});
test("artifact path symlink cannot disclose preferences", async () => {
  const { service, path } = await setup(),
    record = await upload(service);
  await service.finish(record.id, { inferenceFrames: 4000 });
  await completed(service, record.id);
  const transcript = join(path, "generations", record.id, "transcript.txt");
  await rm(transcript);
  await symlink(join(path, "preferences.json"), transcript);
  await expect(service.artifact(record.id, "transcript.txt")).rejects.toMatchObject({
    code: "artifact_not_found",
  });
});
test("history pagination and source filters remain stable", async () => {
  const { service } = await setup(),
    first = await service.create(request());
  await service.cancel(first.id);
  const second = await service.create(request());
  await service.cancel(second.id);
  const page = await service.history(1, undefined, "v07");
  expect(page.items).toHaveLength(1);
  expect(page.nextCursor).toBeDefined();
  expect((await service.history(1, page.nextCursor, "v07")).items[0]?.id).not.toBe(
    page.items[0]?.id,
  );
  expect((await service.history(50, undefined, "wispr-flow")).items).toHaveLength(0);
});

test("original audio sealing enforces complete counts and matching duration", async () => {
  const { service } = await setup();
  const preferences = await service.getPreferences();
  preferences.preferences.keepOriginalAudio = true;
  await service.updatePreferences(preferences);
  const record = await upload(service);
  await expect(service.finish(record.id, { inferenceFrames: 4000 })).rejects.toMatchObject({
    code: "incomplete_original",
  });
  await service.appendAudio(record.id, "original", 0, format, Buffer.alloc(32_000));
  await expect(
    service.finish(record.id, { inferenceFrames: 4000, originalFrames: 8000 }),
  ).rejects.toMatchObject({ code: "audio_mismatch" });
  await service.cancel(record.id);
  const matched = await upload(service);
  await service.appendAudio(matched.id, "original", 0, format, pcm());
  await service.finish(matched.id, { inferenceFrames: 4000, originalFrames: 4000 });
  const final = await completed(service, matched.id);
  expect(final.originalAudio?.frameCount).toBe(4000);
  expect(final.status).toBe("completed");
});
test("too-short audio stays receiving and can be cancelled", async () => {
  const { service } = await setup(),
    record = await service.create(request());
  await service.appendAudio(record.id, "inference", 0, format, Buffer.alloc(4));
  await expect(service.finish(record.id, { inferenceFrames: 1 })).rejects.toMatchObject({
    code: "invalid_duration",
  });
  expect((await service.get(record.id)).status).toBe("receiving");
});
test("wire preferences preserve historical defaults", async () => {
  const { service } = await setup(),
    preferences = await service.getPreferences();
  const updated = await service.updatePreferences({
    revision: preferences.revision,
    preferences: {
      language: "en",
      vocabulary: "",
      textCorrectionEnabled: false,
      keepOriginalAudio: false,
      dictionary: {
        lists: [{ id: "personal", name: "Personal", entries: [{ id: "codex", term: "Codex" }] }],
      },
    },
  });
  expect(updated.preferences.proofreadingPrompt).toContain("Cleanup");
  expect(updated.preferences.dictionary.lists[0]?.entries[0]?.aliases).toEqual([]);
  expect(updated.preferences.dictionary.lists[0]?.entries[0]?.isPriority).toBe(false);
});
test("list continuations carry only confirmed compatible device context", async () => {
  const { service, inference } = await setup();
  inference.text = "Make a list. One, apples. Two, bananas.";
  const preferences = await service.getPreferences();
  preferences.preferences.textCorrectionEnabled = false;
  await service.updatePreferences(preferences);
  const first = await upload(service);
  await service.finish(first.id, { inferenceFrames: 4000 });
  const initial = await completed(service, first.id);
  expect(initial.continuation?.list?.nextNumber).toBe(3);
  inference.text = "Next item, oranges.";
  const next = await upload(service);
  await service.finish(next.id, { inferenceFrames: 4000, continuationID: first.id });
  const continued = await completed(service, next.id);
  expect(continued.finalText).toBe("3. oranges");
  expect(continued.previewText).toBe("1. apples\n2. bananas\n3. oranges");
  const other = await service.create({
    ...request(),
    device: { id: "other-device", name: "Other Mac" },
  });
  await service.appendAudio(other.id, "inference", 0, format, pcm());
  await service.finish(other.id, { inferenceFrames: 4000, continuationID: next.id });
  expect((await completed(service, other.id)).finalText).not.toBe("4. oranges");
});

test("idle upload expiry cancels every stale receiver and preserves a fresh recording", async () => {
  const { service } = await setup();
  const stale = await Promise.all([upload(service), upload(service)]);
  service.start();
  try {
    setSystemTime(new Date(Date.now() + 46_000));
    const fresh = await upload(service);
    const expired = await Promise.all(stale.map((record) => completed(service, record.id)));
    expect(expired.map((record) => record.status)).toEqual(["cancelled", "cancelled"]);
    expect((await service.get(fresh.id)).status).toBe("receiving");
    expect((await service.health()).ready).toBe(true);
  } finally {
    setSystemTime();
  }
});

test("FIFO artifacts are rejected promptly and leave the mutation queue responsive", async () => {
  const { service, path } = await setup(),
    record = await upload(service);
  await service.finish(record.id, { inferenceFrames: 4000 });
  await completed(service, record.id);
  const transcript = join(path, "generations", record.id, "transcript.txt");
  await rm(transcript);
  expect(
    await Bun.spawn(["mkfifo", transcript], { stdout: "ignore", stderr: "ignore" }).exited,
  ).toBe(0);
  const [artifact, snapshot] = await Promise.allSettled([
    service.artifact(record.id, "transcript.txt"),
    service.get(record.id),
  ]);
  expect(artifact.status).toBe("rejected");
  if (artifact.status === "rejected")
    expect(artifact.reason).toMatchObject({ code: "artifact_not_found" });
  expect(snapshot.status).toBe("fulfilled");
}, 1000);

test("FIFO replay targets are rejected before any read and leave the mutation queue responsive", async () => {
  const { service, path } = await setup(),
    record = await upload(service),
    raw = join(path, "generations", record.id, "inference.raw");
  await rm(raw);
  expect(await Bun.spawn(["mkfifo", raw], { stdout: "ignore", stderr: "ignore" }).exited).toBe(0);
  const [replay, snapshot] = await Promise.allSettled([
    service.appendAudio(record.id, "inference", 0, format, pcm()),
    service.get(record.id),
  ]);
  expect(replay.status).toBe("rejected");
  if (replay.status === "rejected")
    expect(replay.reason).toMatchObject({ code: "invalid_archive" });
  expect(snapshot.status).toBe("fulfilled");
}, 1000);

function deferred() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  return { promise, release };
}
class DelayedCleanupInference extends FakeInference {
  started = deferred();
  aborted = deferred();
  cleanup = deferred();
  backendStopped = deferred();
  cleaned = false;
  override shutdown() {
    this.backendStopped.release();
    return super.shutdown();
  }
  override async transcribe(
    _path: string,
    _language: string,
    _terms: string[],
    _progress?: (value: number) => void,
    signal?: AbortSignal,
  ) {
    signal?.addEventListener("abort", () => this.aborted.release(), { once: true });
    this.started.release();
    await this.aborted.promise;
    await this.cleanup.promise;
    this.cleaned = true;
    return {
      text: this.text,
      language: "en",
      processingSeconds: 0.1,
      audioSeconds: 0.25,
      engineVersion: "fixture",
    };
  }
}
for (const retired of [false, true]) {
  test(
    retired
      ? "shutdown drains processing retired by earlier cancellation"
      : "shutdown awaits processing cleanup after cancelling active inference",
    async () => {
      const inference = new DelayedCleanupInference();
      const { service } = await setup(inference),
        record = await upload(service);
      await service.finish(record.id, { inferenceFrames: 4000 });
      await inference.started.promise;
      if (retired) {
        await service.cancel(record.id);
        await service.create(request());
      }
      let stopped = false;
      const shutdown = service.shutdown().then(() => {
        stopped = true;
      });
      try {
        await inference.aborted.promise;
        await inference.backendStopped.promise;
        expect((await service.get(record.id)).status).toBe("cancelled");
        // Give queued shutdown continuations a turn while helper cleanup is held.
        await Bun.sleep(0);
        expect(stopped).toBe(false);
      } finally {
        inference.cleanup.release();
        await shutdown;
      }
      expect(inference.cleaned).toBe(true);
      expect(stopped).toBe(true);
    },
  );
}

class QueuedInference extends FakeInference {
  calls: string[] = [];
  signals: (AbortSignal | undefined)[] = [];
  starts = Array.from({ length: 4 }, deferred);
  releases = Array.from({ length: 4 }, deferred);
  failFirst = false;
  cold = false;
  proofStarted = deferred();
  proofRelease?: ReturnType<typeof deferred>;
  override readiness() {
    return super.readiness().then((state) => ({ ...state, speechLoaded: !this.cold }));
  }
  override async transcribe(
    path: string,
    _language: string,
    _terms: string[],
    _progress?: (value: number) => void,
    signal?: AbortSignal,
  ) {
    const index = this.calls.length;
    this.calls.push(path);
    this.signals.push(signal);
    this.starts[index]!.release();
    // Deliberately hold cleanup after abort to detect overlapping replacement work.
    await this.releases[index]!.promise;
    signal?.throwIfAborted();
    if (this.failFirst && index === 0) throw new Error("Speech helper failed.");
    return {
      text: `Recording ${index + 1}.`,
      language: "en",
      processingSeconds: 0.1,
      audioSeconds: 0.25,
      engineVersion: "fixture",
    };
  }
  override async correct(text: string) {
    this.proofStarted.release();
    await this.proofRelease?.promise;
    return super.correct(text);
  }
  override async cancel() {
    throw new Error("Per-record cancellation must not cancel the entire backend.");
  }
  override shutdown() {
    this.proofRelease?.release();
    for (const release of this.releases) release.release();
    return super.shutdown();
  }
}

test("finished recordings run FIFO, remain ready, and deliver only to their own subscribers", async () => {
  const inference = new QueuedInference();
  const { service, path } = await setup(inference);
  const [first, second, third] = await Promise.all(
    Array.from({ length: 3 }, () => upload(service)),
  );
  const results = [second!, first!, third!].map((record) => completed(service, record.id));
  await service.finish(second!.id, { inferenceFrames: 4000 });
  await inference.starts[0]!.promise;
  await service.finish(first!.id, { inferenceFrames: 4000 });
  await service.finish(third!.id, { inferenceFrames: 4000 });
  await service.finish(first!.id, { inferenceFrames: 4000 });
  expect((await service.get(first!.id)).status).toBe("queued");
  expect((await service.get(third!.id)).status).toBe("queued");
  expect((await service.health()).ready).toBe(true);
  expect((await service.create(request())).status).toBe("receiving");
  expect(inference.calls).toEqual([join(path, "generations", second!.id, "inference.wav")]);
  for (let index = 0; index < results.length; index++) {
    inference.releases[index]!.release();
    const result = await results[index]!;
    expect(result.id).toBe([second!, first!, third!][index]!.id);
    expect(result.status).toBe("completed");
    expect(result.finalText).toBe(`Recording ${index + 1}.`);
    if (index + 1 < results.length) await inference.starts[index + 1]!.promise;
  }
  expect(inference.calls).toEqual(
    [second!, first!, third!].map((record) =>
      join(path, "generations", record.id, "inference.wav"),
    ),
  );
});

test("cancelling receiving and queued recordings leaves active inference alone; active cleanup precedes the next job", async () => {
  const inference = new QueuedInference();
  const { service, path } = await setup(inference);
  const first = await upload(service);
  await service.finish(first.id, { inferenceFrames: 4000 });
  await inference.starts[0]!.promise;
  const queued = await upload(service);
  await service.finish(queued.id, { inferenceFrames: 4000 });
  const receiving = await upload(service);
  const next = await upload(service);
  await service.finish(next.id, { inferenceFrames: 4000 });
  expect((await service.cancel(receiving.id)).status).toBe("cancelled");
  expect((await service.cancel(queued.id)).status).toBe("cancelled");
  expect(inference.signals[0]!.aborted).toBe(false);
  expect((await service.cancel(first.id)).status).toBe("cancelled");
  expect(inference.signals[0]!.aborted).toBe(true);
  await service.delete(queued.id);
  await Bun.sleep(0);
  expect(inference.calls).toHaveLength(1);
  expect((await service.get(next.id)).status).toBe("queued");
  inference.releases[0]!.release();
  await inference.starts[1]!.promise;
  expect(inference.calls[1]).toBe(join(path, "generations", next.id, "inference.wav"));
  inference.releases[1]!.release();
  expect((await completed(service, next.id)).status).toBe("completed");
  expect((await service.get(first.id)).status).toBe("cancelled");
  expect((await service.health()).ready).toBe(true);
});

test("a failed speech job does not strand the next queued recording", async () => {
  const inference = new QueuedInference();
  inference.failFirst = true;
  const { service } = await setup(inference);
  const first = await upload(service);
  await service.finish(first.id, { inferenceFrames: 4000 });
  await inference.starts[0]!.promise;
  const next = await upload(service);
  await service.finish(next.id, { inferenceFrames: 4000 });
  inference.releases[0]!.release();
  expect((await completed(service, first.id)).status).toBe("failed");
  await inference.starts[1]!.promise;
  inference.releases[1]!.release();
  expect((await completed(service, next.id)).status).toBe("completed");
});

test("verified available models accept recordings while their helper reloads", async () => {
  const inference = new QueuedInference();
  inference.cold = true;
  const { service } = await setup(inference);
  const health = await service.health();
  expect(health.ready).toBe(true);
  expect(health.speech.ready).toBe(false);
  const record = await upload(service);
  await service.finish(record.id, { inferenceFrames: 4000 });
  await inference.starts[0]!.promise;
  inference.releases[0]!.release();
  expect((await completed(service, record.id)).status).toBe("completed");
});

test("a speech model that fails to load stops admitting recordings until it loads", async () => {
  const inference = new QueuedInference();
  inference.cold = true;
  const failed = deferred();
  inference.warmUp = () => {
    failed.release();
    return Promise.reject(new Error("Metal device unavailable."));
  };
  const { service } = await setup(inference);
  await failed.promise;
  await Bun.sleep(0);
  const health = await service.health();
  expect(health.ready).toBe(false);
  expect(health.message).toBe("Speech model failed to load.");
  await expect(service.create(request())).rejects.toMatchObject({ code: "server_unavailable" });
  inference.cold = false;
  expect((await service.health()).ready).toBe(true);
});

test("shutdown cancels every receiving and queued recording without starting another inference", async () => {
  const inference = new QueuedInference();
  const { service } = await setup(inference);
  const first = await upload(service);
  await service.finish(first.id, { inferenceFrames: 4000 });
  await inference.starts[0]!.promise;
  const queued = await upload(service);
  await service.finish(queued.id, { inferenceFrames: 4000 });
  const receiving = await upload(service);
  const results = [first, queued, receiving].map((record) => completed(service, record.id));
  await service.shutdown();
  expect((await Promise.all(results)).map((record) => record.status)).toEqual(
    Array(3).fill("cancelled"),
  );
  expect(inference.calls).toHaveLength(1);
  expect((await service.health()).ready).toBe(false);
  await expect(service.create(request())).rejects.toMatchObject({ code: "server_stopping" });
});

test("the next recording waits until proofreading and result publication finish", async () => {
  const inference = new QueuedInference();
  inference.proofRelease = deferred();
  const { service } = await setup(inference);
  const first = await upload(service);
  await service.finish(first.id, { inferenceFrames: 4000 });
  await inference.starts[0]!.promise;
  inference.releases[0]!.release();
  await inference.proofStarted.promise;
  const second = await upload(service);
  await service.finish(second.id, { inferenceFrames: 4000 });
  expect((await service.get(first.id)).status).toBe("proofreading");
  expect((await service.get(second.id)).status).toBe("queued");
  expect(inference.calls).toHaveLength(1);
  inference.proofRelease.release();
  await inference.starts[1]!.promise;
  expect((await service.get(first.id)).status).toBe("completed");
  inference.releases[1]!.release();
  expect((await completed(service, second.id)).status).toBe("completed");
});
