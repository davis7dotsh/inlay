import { ServiceError } from "./errors.ts";
import { InferenceError } from "./inference/inference-error.ts";

export type LogFields = Record<string, string | number | boolean | null | undefined>;

const truncate = (value: string, limit: number) =>
  value.length > limit ? `${value.slice(0, limit)}…` : value;

function write(level: string, event: string, fields: LogFields, error?: unknown) {
  const line: Record<string, string | number | boolean | null> = {
    time: new Date().toISOString(),
    level,
    event,
  };
  for (const [key, value] of Object.entries(fields))
    if (value !== undefined) line[key] = typeof value === "string" ? truncate(value, 4096) : value;
  if (error !== undefined) {
    if (error instanceof ServiceError) {
      line.errorCode = error.code;
      line.errorStatus = error.status;
      line.error = truncate(error.message, 512);
    } else if (error instanceof InferenceError) {
      line.errorCode = error.code;
      line.error = truncate(error.message, 512);
    } else if (error instanceof Error) {
      const code = "code" in error ? error.code : undefined;
      if (typeof code === "string") line.errorCode = code;
      line.error = truncate(error.message, 512);
      if (error.stack) line.stack = truncate(error.stack, 4096);
      const cause = "cause" in error ? error.cause : undefined;
      if (cause instanceof Error) line.cause = truncate(cause.message, 512);
    } else {
      line.error = truncate(JSON.stringify(error) ?? "unknown error", 512);
    }
  }
  process.stderr.write(`${JSON.stringify(line)}\n`);
}

/// Structured, metadata-only server logging. Never pass transcript text,
/// audio, prompts, or tokens as fields; IDs, codes, durations, and counts
/// are the intended payload. One JSON line per call on stderr.
export const logInfo = (event: string, fields: LogFields = {}) => write("info", event, fields);
export const logWarn = (event: string, fields: LogFields = {}, error?: unknown) =>
  write("warn", event, fields, error);
export const logError = (event: string, error?: unknown, fields: LogFields = {}) =>
  write("error", event, fields, error);
