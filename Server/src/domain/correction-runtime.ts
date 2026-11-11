import type { VerifiedTextRepair } from "../api.ts";
import { ServiceError } from "../errors.ts";

interface Evaluation {
  rejectionReason?: string;
  verifiedRepairs: VerifiedTextRepair[];
}
const validEvaluation = (value: unknown): value is Evaluation =>
  typeof value === "object" &&
  value !== null &&
  "verifiedRepairs" in value &&
  Array.isArray(value.verifiedRepairs) &&
  (!("rejectionReason" in value) ||
    value.rejectionReason === undefined ||
    typeof value.rejectionReason === "string");

/** Release the HTTP event loop while the bounded alignment policy runs. */
export function evaluateCorrectionInWorker(
  original: string,
  candidate: string,
  dictionaryTerms: string[],
  screenTerms: string[],
  signal?: AbortSignal,
): Promise<Evaluation> {
  signal?.throwIfAborted();
  if (
    Buffer.byteLength(original) > 131_072 ||
    Buffer.byteLength(candidate) > 131_072 ||
    dictionaryTerms.length > 500 ||
    screenTerms.length > 40 ||
    [...dictionaryTerms, ...screenTerms].some((term) => Buffer.byteLength(term) > 16_384)
  )
    return Promise.reject(
      new ServiceError(400, "correction_limit", "The correction evaluation exceeded its limits."),
    );
  let worker: Worker;
  try {
    worker = new Worker(
      new URL(
        Bun.isStandaloneExecutable ? "./domain/correction-worker.ts" : "./correction-worker.ts",
        import.meta.url,
      ).href,
    );
  } catch {
    return Promise.reject(new Error("Correction evaluation is unavailable."));
  }
  return new Promise((resolve, reject) => {
    let finished = false;
    const finish = (result: Evaluation | undefined, error?: Error) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      worker.terminate();
      if (result) resolve(result);
      else reject(error ?? new Error("Correction evaluation failed."));
    };
    const abort = () => finish(undefined, new Error("Recording cancelled."));
    const timer = setTimeout(
      () => finish(undefined, new Error("Correction evaluation timed out.")),
      10_000,
    );
    signal?.addEventListener("abort", abort, { once: true });
    worker.onmessage = (event) =>
      validEvaluation(event.data)
        ? finish(event.data)
        : finish(undefined, new Error("Correction evaluation returned invalid output."));
    worker.onerror = () => finish(undefined, new Error("Correction evaluation failed."));
    worker.postMessage({ original, candidate, dictionaryTerms, screenTerms });
  });
}
