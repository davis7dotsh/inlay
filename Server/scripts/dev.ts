import { randomBytes } from "node:crypto";
import { existsSync, lstatSync, readdirSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { isLoopbackHost, parseConfiguration, usage } from "../src/configuration.ts";

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  console.log(`bun run dev [server arguments]\n\n${usage}`);
} else {
  const projectDirectory = resolve(import.meta.dirname, "../..");
  const directory = resolve(projectDirectory, ".local/dev-server");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const arguments_ = process.argv.slice(2);
  const tokenIndex = arguments_.lastIndexOf("--token-file");
  const tokenFile =
    (tokenIndex >= 0 ? arguments_[tokenIndex + 1] : undefined) ??
    process.env.INLAY_SERVER_TOKEN_FILE ??
    resolve(directory, "token");
  if (!process.env.INLAY_SERVER_TOKEN_FILE && !process.argv.includes("--token-file")) {
    try {
      await writeFile(tokenFile, randomBytes(32).toString("hex"), { flag: "wx", mode: 0o600 });
    } catch (error) {
      if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
    }
  }
  const isMac = process.platform === "darwin";
  // Match the directories scripts/setup.sh downloads into. INLAY_MODEL_DIR
  // overrides both; otherwise fall back to the previous dev default when only
  // it holds the weights.
  const modelDirectory = isMac
    ? resolve(homedir(), "Library/Application Support/Inlay/Models")
    : resolve(projectDirectory, ".local/models");
  const legacyModelDirectory = isMac
    ? resolve(homedir(), ".inlay/models")
    : resolve(directory, "models");
  // download-text-model.sh creates the MLX directory before its verified files
  // land, and the app rejects any folder that is not exactly these regular
  // files, so only such a copy counts.
  const mlxFiles = [
    "model.safetensors",
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "generation_config.json",
    "chat_template.jinja",
  ];
  const entries = (path: string) => {
    try {
      return lstatSync(path).isDirectory() ? readdirSync(path) : [];
    } catch {
      return [];
    }
  };
  const isRegularFile = (path: string) => {
    try {
      return lstatSync(path).isFile();
    } catch {
      return false;
    }
  };
  const hasModel = (path: string) => {
    if (!path.endsWith("-MLX-4bit")) return existsSync(path);
    const names = entries(path);
    return (
      names.length === mlxFiles.length &&
      mlxFiles.every((file) => names.includes(file) && isRegularFile(resolve(path, file)))
    );
  };
  const modelPath = (name: string) => {
    if (process.env.INLAY_MODEL_DIR) return resolve(process.env.INLAY_MODEL_DIR, name);
    const path = resolve(modelDirectory, name);
    const legacyPath = resolve(legacyModelDirectory, name);
    return !hasModel(path) && hasModel(legacyPath) ? legacyPath : path;
  };
  const environment = {
    INLAY_SERVER_HOST: "127.0.0.1",
    INLAY_SERVER_PORT: "8392",
    INLAY_SERVER_TOKEN_FILE: tokenFile,
    INLAY_ENGINE_PATH: resolve(projectDirectory, "build/server/helpers/inlay-engine"),
    INLAY_VAD_PATH: resolve(projectDirectory, "build/server/resources/silero-vad.bin"),
    INLAY_TEXT_ENGINE_PATH: resolve(projectDirectory, "build/server/helpers/inlay-text-engine"),
    INLAY_SPEECH_MODEL:
      process.env.INLAY_SPEECH_MODEL ?? modelPath("ggml-parakeet-tdt-0.6b-v3-f16.bin"),
    INLAY_TEXT_MODEL:
      process.env.INLAY_TEXT_MODEL ??
      modelPath(isMac ? "Qwen3-4B-Instruct-2507-MLX-4bit" : "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"),
    ...process.env,
    // A regular server's exported archive must never become the dev default.
    // Explicit --data-dir arguments still take precedence in parseConfiguration.
    INLAY_SERVER_DATA_DIR: resolve(directory, "data"),
    INLAY_DEV: "1",
  };
  const configuration = await parseConfiguration(arguments_, environment);
  const displayHost =
    process.env.INLAY_DEV_DISPLAY_HOST ??
    (isLoopbackHost(configuration.host) ? "localhost" : configuration.host);
  console.log(`Development URL: http://${displayHost}:${configuration.port}/v1/liveness`);
  console.log(`Data: ${configuration.dataDirectory}\nToken file: ${tokenFile}`);
  console.log("Bun watches source changes. Missing helpers/models appear in health readiness.");
  const child = Bun.spawn(
    [process.execPath, "--watch", resolve(projectDirectory, "Server/src/main.ts"), ...arguments_],
    {
      cwd: projectDirectory,
      env: environment,
      stdin: "inherit",
      stdout: "inherit",
      stderr: "inherit",
    },
  );
  process.once("SIGINT", () => child.kill("SIGINT"));
  process.once("SIGTERM", () => child.kill("SIGTERM"));
  process.exitCode = await child.exited;
}
