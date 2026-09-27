import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmod, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  NativeInference,
  createInferenceConfiguration,
  InferenceError,
  type InferenceConfiguration,
} from "../src/inference/native-inference";
import { ModelVerifier } from "../src/inference/model-verification";
import { HelperProcess } from "../src/inference/helper-process";

const fixtures: { directory: string; inference: NativeInference }[] = [];

async function fixture(
  mode = "valid",
  overrides: Partial<InferenceConfiguration> = {},
  pinned = false,
) {
  const directory = await mkdtemp(join(tmpdir(), "v07-native-inference-"));
  const model = join(directory, mode);
  const executable = join(directory, "helper");
  const source = await readFile(new URL("./fixtures/native-helper.ts", import.meta.url), "utf8");
  await writeFile(executable, `#!${process.execPath}\n${source}`);
  await chmod(executable, 0o700);
  await writeFile(model, "fixture model");
  const configuration = createInferenceConfiguration({
    speechHelper: executable,
    speechModel: model,
    vadModel: model,
    proofHelper: executable,
    proofModel: model,
    speechLoadTimeout: 3,
    speechTimeout: 3,
    proofLoadTimeout: 3,
    proofTimeout: 3,
    ...overrides,
  });
  const digest = createHash("sha256").update("fixture model").digest("hex");
  const inference = new NativeInference(
    configuration,
    pinned ? { speech: { sha256: digest } } : {},
  );
  fixtures.push({ directory, inference });
  return { directory, model, executable, inference, configuration, digest };
}

afterEach(async () => {
  for (const { directory, inference } of fixtures.splice(0)) {
    await inference.shutdown();
    await rm(directory, { recursive: true, force: true });
  }
});

describe("native inference subprocess protocol", () => {
  test("warm helpers serve both requests, clamp matching progress, and survive idle cancellation", async () => {
    const { inference, model } = await fixture();
    await inference.warmUp();
    await inference.cancel();
    expect(await inference.readiness()).toMatchObject({
      available: true,
      speechLoaded: true,
      proofLoaded: true,
    });
    const progress: number[] = [];
    const speech = await inference.transcribe(model, "en", ["auth"], (value) =>
      progress.push(value),
    );
    expect(speech).toMatchObject({
      text: "Hello world.",
      audioSeconds: 2,
      processingSeconds: 0.1,
      language: "en",
      engineVersion: "fixture-1",
    });
    expect(speech.hints).toEqual({
      includedTerms: ["auth"],
      omittedTerms: [],
      tokenCount: 1,
      tokenBudget: 223,
    });
    expect(progress).toEqual([0, 0.5, 1]);
    expect(await inference.correct(speech.text, ["V07"], "en", "Keep punctuation.")).toMatchObject({
      text: "Hello world.",
      engineVersion: "fixture-1",
    });
  });

  test("Parakeet reports automatic language and no recognition vocabulary support", async () => {
    const { inference, model } = await fixture("parakeet");
    for (const terms of [[], ["Codex", "Café"]]) {
      const speech = await inference.transcribe(model, "en", terms);
      expect(speech.language).toBe("auto");
      expect(speech.hints).toEqual({
        includedTerms: [],
        omittedTerms: terms,
        tokenCount: 0,
        tokenBudget: 0,
      });
    }
  });

  test("requests may span stdout reads and diagnostics are drained", async () => {
    for (const mode of ["split-json", "stderr"]) {
      const { inference, model } = await fixture(mode);
      expect((await inference.transcribe(model, "en", [])).text).toBe("Hello world.");
    }
  });

  test("invalid vocabulary fails before starting a helper", async () => {
    const { inference, model } = await fixture("no-ready");
    for (const terms of [
      ["auth", "auth"],
      [" auth"],
      ["auth "],
      [" "],
      ["auth\u00a0"],
      ["auth\nterm"],
      ["auth\u200bterm"],
      ["x".repeat(16_385)],
    ]) {
      await expect(inference.transcribe(model, "en", terms)).rejects.toMatchObject({
        code: "invalidRequest",
      });
    }
    expect((await inference.readiness(false)).speechLoaded).toBe(false);
  });

  test("malformed vocabulary diagnostics and result content invalidate the helper", async () => {
    for (const mode of ["invalid-hints", "invalid-result", "invalid-zero-budget"]) {
      const { inference, model } = await fixture(mode);
      await expect(inference.transcribe(model, "en", ["auth"])).rejects.toMatchObject({
        code: "invalidResponse",
      });
      expect((await inference.readiness(false)).speechLoaded).toBe(false);
    }
  });

  test("loading and inference deadlines resolve waiters and reset processes", async () => {
    const loading = await fixture("no-ready", { speechLoadTimeout: 0.05 });
    await expect(loading.inference.warmUp(false)).rejects.toMatchObject({ code: "timeout" });
    const running = await fixture("no-result", { speechTimeout: 0.05 });
    await expect(running.inference.transcribe(running.model, "en", [])).rejects.toMatchObject({
      code: "timeout",
    });
    expect((await running.inference.readiness(false)).speechLoaded).toBe(false);
  });

  test("active cancellation resolves the request and forces replacement", async () => {
    const { inference, model } = await fixture("no-result");
    await inference.warmUp(false);
    const controller = new AbortController();
    const request = inference.transcribe(model, "en", [], undefined, controller.signal);
    const rejected = request.catch((error) => error);
    await Bun.sleep(20);
    controller.abort();
    expect(await rejected).toMatchObject({ code: "cancelled" });
    expect((await inference.readiness(false)).speechLoaded).toBe(false);
    await inference.warmUp(false);
    expect((await inference.readiness(false)).speechLoaded).toBe(true);
  });

  test("a concurrent request cannot replace an outstanding request", async () => {
    const { inference, model } = await fixture("no-result");
    await inference.warmUp(false);
    const first = inference.transcribe(model, "en", []);
    const rejected = first.catch((error) => error);
    await Bun.sleep(20);
    await expect(inference.transcribe(model, "en", [])).rejects.toMatchObject({ code: "busy" });
    await inference.cancel();
    expect(await rejected).toMatchObject({ code: "cancelled" });
  });

  test("cancelled load cannot launch after asynchronous asset checks", async () => {
    const { inference } = await fixture("no-ready");
    const controller = new AbortController();
    const loading = inference.warmUp(false, controller.signal).catch((error) => error);
    controller.abort();
    expect(await loading).toMatchObject({ code: "cancelled" });
    expect((await inference.readiness(false)).speechLoaded).toBe(false);
  });

  test("stale output cannot reset replacements and ignored SIGTERM escalates to SIGKILL", async () => {
    const { executable, model } = await fixture("ignore-term");
    const helper = new HelperProcess({
      name: "Fixture",
      executable,
      arguments: ["--model", model],
      requiredFiles: [model],
      loadTimeout: 3,
      lineLimit: 65_536,
    });
    try {
      await helper.ensureLoaded();
      const oldPID = Number(helper.snapshot().engineVersion?.slice(4));
      expect(oldPID).toBeGreaterThan(0);
      const request = helper
        .request({ type: "transcribe", id: "first" }, "first", 3)
        .catch((error) => error);
      await Bun.sleep(20);
      helper.cancel();
      expect(await request).toMatchObject({ code: "cancelled" });
      await helper.ensureLoaded();
      expect(helper.snapshot().engineVersion).not.toBe(`pid:${oldPID}`);
      await Bun.sleep(150);
      expect(helper.snapshot().loaded).toBe(true);
      process.kill(oldPID, 0);
      await Bun.sleep(1950);
      expect(() => process.kill(oldPID, 0)).toThrow();
    } finally {
      await helper.shutdown();
    }
  }, 7000);

  test("an immediately exiting parent leaves no current or previously cancelled native helpers", async () => {
    const { executable, model } = await fixture("ignore-term");
    const parent = Bun.spawn(
      [
        process.execPath,
        new URL("./fixtures/native-shutdown-parent.ts", import.meta.url).pathname,
        executable,
        model,
      ],
      {
        stdout: "ignore",
        stderr: "pipe",
      },
    );
    let helperPIDs: number[] = [];
    try {
      const stderr = new Response(parent.stderr).text();
      expect(await parent.exited).toBe(0);
      expect(await stderr).toBe("");
      helperPIDs = (await readFile(`${model}.pids`, "utf8")).trim().split("\n").map(Number);
      expect(helperPIDs).toHaveLength(3);
      for (const pid of helperPIDs) expect(() => process.kill(pid, 0)).toThrow();
    } finally {
      if (parent.exitCode === null) parent.kill();
      // If the assertion catches an orphan, remove only this test's helpers.
      if (!helperPIDs.length) {
        try {
          helperPIDs = (await readFile(`${model}.pids`, "utf8")).trim().split("\n").map(Number);
        } catch {}
      }
      for (const pid of helperPIDs) {
        try {
          process.kill(pid, "SIGKILL");
        } catch {}
      }
    }
  }, 5000);

  test("oversized unterminated lines are bounded before JSON decoding", async () => {
    const { inference } = await fixture("oversized");
    await expect(inference.correct("Hello.", [], "en", "Keep punctuation.")).rejects.toMatchObject({
      code: "unavailable",
      message: expect.stringContaining("size limit"),
    });
  });

  test("invalid JSON and unknown events reset the helper", async () => {
    for (const mode of ["invalid-json", "unknown-event"]) {
      const { inference, model } = await fixture(mode);
      await expect(inference.transcribe(model, "en", [])).rejects.toMatchObject({
        code: "invalidResponse",
      });
    }
  });

  test("missing proof assets do not block speech-only readiness", async () => {
    const { inference, configuration } = await fixture("no-ready", {
      proofModel: "/nonexistent/v07-proof-model",
    });
    expect((await inference.readiness(false)).available).toBe(true);
    expect((await inference.readiness(true)).available).toBe(false);
    const production = new NativeInference(configuration);
    expect((await production.readiness(false)).available).toBe(false);
    await production.shutdown();
  });
});

describe("model integrity", () => {
  test("digest cache is invalidated by same-size edits and inode replacement", async () => {
    const { inference, model, digest, directory } = await fixture("valid", {}, true);
    expect((await inference.readiness(false)).available).toBe(false);
    await inference.warmUp(false);
    expect((await inference.readiness(false)).available).toBe(true);
    await writeFile(model, "altered model");
    expect((await inference.readiness(false)).available).toBe(false);
    await expect(inference.warmUp(false)).rejects.toMatchObject({
      code: "unavailable",
      message: expect.stringContaining("SHA-256"),
    });
    const verifier = new ModelVerifier();
    const second = join(directory, "replacement");
    await writeFile(second, "fixture model");
    expect(await verifier.verify(second, { sha256: digest })).toBe(digest);
    await rm(second);
    await writeFile(second, "fixture model");
    expect(await verifier.isVerified(second, { sha256: digest })).toBe(false);
  });

  test("models must be regular files and cannot be symlinks", async () => {
    const { model, directory, digest } = await fixture();
    const link = join(directory, "model-link");
    await symlink(model, link);
    const verifier = new ModelVerifier();
    await expect(verifier.verify(link, { sha256: digest })).rejects.toBeInstanceOf(InferenceError);
    await expect(verifier.verify(directory, { sha256: digest })).rejects.toMatchObject({
      code: "unavailable",
    });
    await expect(verifier.verify(model, { bytes: 1, sha256: digest })).rejects.toMatchObject({
      code: "unavailable",
      message: expect.stringContaining("incorrect size"),
    });
  });

  test("concurrent verification shares a hash without losing successful callers", async () => {
    const { model, digest } = await fixture();
    const verifier = new ModelVerifier();
    expect(
      await Promise.all([
        verifier.verify(model, { sha256: digest }),
        verifier.verify(model, { sha256: digest }),
      ]),
    ).toEqual([digest, digest]);
  });

  test("configuration clamps invalid deadlines and thread counts", () => {
    const configuration = createInferenceConfiguration({
      speechHelper: "a",
      speechModel: "b",
      vadModel: "c",
      proofHelper: "d",
      proofModel: "e",
      threads: 100,
      speechTimeout: NaN,
      proofTimeout: -1,
      speechLoadTimeout: 3601,
    });
    expect(configuration).toMatchObject({
      threads: 32,
      speechTimeout: 180,
      proofTimeout: 18,
      speechLoadTimeout: 120,
      proofLoadTimeout: 30,
    });
  });
});
