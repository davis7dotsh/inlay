import { randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { mkdir, open, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { logWarn } from "./log.ts";
import {
  createInferenceConfiguration,
  type InferenceConfiguration,
} from "./inference/native-inference.ts";

export interface ServerConfiguration {
  host: string;
  port: number;
  dataDirectory: string;
  /** Admin/bootstrap token: enrolls and revokes devices; never a dictation credential. */
  token: string;
  adminTokenFile: string;
  adminTokenCreated: boolean;
  development: boolean;
  inference: InferenceConfiguration;
}

export const usage = `Inlay server — independent dictation service
inlay-server --data-dir PATH --speech-helper PATH --speech-model PATH --vad-model PATH \
  --proof-helper PATH --proof-model PATH [--host 127.0.0.1] [--port 8391] [--token-file PATH] [--dev]

macOS uses Parakeet/Metal and Qwen/MLX. Linux uses Parakeet/CUDA or CPU and Qwen/llama.cpp.
Models must already exist. The server never downloads or imports personal data automatically.
Use persistent storage for --data-dir. Without --token-file, an admin token is created at <data-dir>/admin-token.
`;

const names = new Set([
  "host",
  "port",
  "data-dir",
  "token-file",
  "speech-helper",
  "speech-model",
  "vad-model",
  "proof-helper",
  "proof-model",
]);
export const isLoopbackHost = (host: string) => ["localhost", "127.0.0.1", "::1"].includes(host);
const expandPath = (value: string) =>
  resolve(
    value === "~" ? homedir() : value.startsWith("~/") ? `${homedir()}/${value.slice(2)}` : value,
  );

export async function parseConfiguration(
  args = process.argv.slice(2),
  environment: NodeJS.ProcessEnv = process.env,
) {
  const options = new Map<string, string>();
  let development = environment.INLAY_DEV === "1";
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--dev") {
      development = true;
      continue;
    }
    const name = argument.slice(2);
    const value = args[index + 1];
    if (
      !argument.startsWith("--") ||
      !names.has(name) ||
      value === undefined ||
      value.startsWith("--")
    ) {
      throw new Error(`Unknown or incomplete argument: ${argument}. Use --help for usage.`);
    }
    options.set(name, value);
    index++;
  }
  const value = (name: string, variable: string) => options.get(name) ?? environment[variable];
  const path = (name: string, variable: string) => {
    const raw = value(name, variable);
    if (!raw) throw new Error(`Configure --${name} or ${variable}.`);
    return expandPath(raw);
  };
  const rawPort = value("port", "INLAY_SERVER_PORT") ?? "8391";
  const port = Number(rawPort);
  if (!/^\d+$/.test(rawPort) || !Number.isSafeInteger(port) || port < 1 || port > 65535) {
    throw new Error("Port must be between 1 and 65535.");
  }
  const dataDirectory = path("data-dir", "INLAY_SERVER_DATA_DIR");
  let token: string | undefined;
  let tokenFile = value("token-file", "INLAY_SERVER_TOKEN_FILE");
  let adminTokenCreated = false;
  if (!tokenFile) {
    tokenFile = join(dataDirectory, "admin-token");
    await mkdir(dataDirectory, { recursive: true, mode: 0o700 });
    try {
      await writeFile(tokenFile, randomBytes(32).toString("hex"), { flag: "wx", mode: 0o600 });
      adminTokenCreated = true;
    } catch (error) {
      if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
    }
  }
  {
    const file = await open(
      expandPath(tokenFile),
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    try {
      const stat = await file.stat();
      if ((stat.mode & 0o077) !== 0)
        logWarn("token_file_permissions", {
          file: expandPath(tokenFile),
          message: "Admin token file should have mode 0600.",
        });
      if (!stat.isFile() || stat.size > 4096)
        throw new Error("The token file must contain at most 4096 bytes of UTF-8 text.");
      const bytes = await file.readFile();
      if (bytes.length > 4096)
        throw new Error("The token file must contain at most 4096 bytes of UTF-8 text.");
      token = new TextDecoder("utf-8", { fatal: true }).decode(bytes).trim();
    } finally {
      await file.close();
    }
    if (!token || /\s/u.test(token))
      throw new Error("The server token must be nonempty and contain no whitespace.");
  }
  const host = value("host", "INLAY_SERVER_HOST") ?? "127.0.0.1";
  if (Buffer.byteLength(token ?? "") < 32) {
    throw new Error(
      "The admin token must contain at least 32 characters. Use HTTPS or a private encrypted network (Tailscale) for remote connections.",
    );
  }
  return {
    host,
    port,
    token: token!,
    adminTokenFile: expandPath(tokenFile),
    adminTokenCreated,
    development,
    dataDirectory,
    inference: createInferenceConfiguration({
      speechHelper: path("speech-helper", "INLAY_ENGINE_PATH"),
      speechModel: path("speech-model", "INLAY_SPEECH_MODEL"),
      vadModel: path("vad-model", "INLAY_VAD_PATH"),
      proofHelper: path("proof-helper", "INLAY_TEXT_ENGINE_PATH"),
      proofModel: path("proof-model", "INLAY_TEXT_MODEL"),
    }),
  } satisfies ServerConfiguration;
}
