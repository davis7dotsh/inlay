import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import {
  createInferenceConfiguration,
  type InferenceConfiguration,
} from "./inference/native-inference.ts";

export interface ServerConfiguration {
  host: string;
  port: number;
  dataDirectory: string;
  token?: string;
  development: boolean;
  inference: InferenceConfiguration;
}

export const usage = `V07 server — independent dictation service
v07-server --data-dir PATH --speech-helper PATH --speech-model PATH --vad-model PATH \
  --proof-helper PATH --proof-model PATH [--host 127.0.0.1] [--port 8391] [--token-file PATH] [--dev]

macOS uses Parakeet/Metal and Qwen/MLX. Linux uses Parakeet/CUDA or CPU and Qwen/llama.cpp.
Models must already exist. The server never downloads or imports personal data automatically.
Use persistent storage for --data-dir. Remote bindings require --token-file.
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
  let development = environment.V07_DEV === "1";
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
  const rawPort = value("port", "V07_SERVER_PORT") ?? "8391";
  const port = Number(rawPort);
  if (!/^\d+$/.test(rawPort) || !Number.isSafeInteger(port) || port < 1 || port > 65535) {
    throw new Error("Port must be between 1 and 65535.");
  }
  let token: string | undefined;
  const tokenFile = value("token-file", "V07_SERVER_TOKEN_FILE");
  if (tokenFile) {
    const file = await open(
      expandPath(tokenFile),
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    try {
      const stat = await file.stat();
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
  const host = value("host", "V07_SERVER_HOST") ?? "127.0.0.1";
  if (!isLoopbackHost(host) && Buffer.byteLength(token ?? "") < 32) {
    throw new Error(
      "Listening beyond localhost requires a token file containing at least 32 characters. Use HTTPS or a private encrypted network for remote connections.",
    );
  }
  return {
    host,
    port,
    token,
    development,
    dataDirectory: path("data-dir", "V07_SERVER_DATA_DIR"),
    inference: createInferenceConfiguration({
      speechHelper: path("speech-helper", "V07_ENGINE_PATH"),
      speechModel: path("speech-model", "V07_SPEECH_MODEL"),
      vadModel: path("vad-model", "V07_VAD_PATH"),
      proofHelper: path("proof-helper", "V07_TEXT_ENGINE_PATH"),
      proofModel: path("proof-model", "V07_TEXT_MODEL"),
    }),
  } satisfies ServerConfiguration;
}
