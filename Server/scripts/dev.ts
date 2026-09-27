import { randomBytes } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { homedir, hostname } from "node:os";
import { resolve } from "node:path";
import { parseConfiguration, usage } from "../src/configuration.ts";

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
    process.env.V07_SERVER_TOKEN_FILE ??
    resolve(directory, "token");
  if (!process.env.V07_SERVER_TOKEN_FILE && !process.argv.includes("--token-file")) {
    try {
      await writeFile(tokenFile, randomBytes(32).toString("hex"), { flag: "wx", mode: 0o600 });
    } catch (error) {
      if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
    }
  }
  const isMac = process.platform === "darwin";
  const environment = {
    V07_SERVER_HOST: "0.0.0.0",
    V07_SERVER_PORT: "8392",
    V07_SERVER_TOKEN_FILE: tokenFile,
    V07_ENGINE_PATH: resolve(projectDirectory, "build/server/helpers/v07-engine"),
    V07_VAD_PATH: resolve(projectDirectory, "build/server/resources/silero-vad.bin"),
    V07_TEXT_ENGINE_PATH: resolve(projectDirectory, "build/server/helpers/v07-text-engine"),
    V07_SPEECH_MODEL: isMac
      ? resolve(
          homedir(),
          "Library/Application Support/V07/Models/ggml-parakeet-tdt-0.6b-v3-f16.bin",
        )
      : resolve(directory, "models/ggml-parakeet-tdt-0.6b-v3-f16.bin"),
    V07_TEXT_MODEL: isMac
      ? resolve(homedir(), ".v07/models/Qwen3-4B-Instruct-2507-MLX-4bit")
      : resolve(directory, "models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"),
    ...process.env,
    // A regular server's exported archive must never become the dev default.
    // Explicit --data-dir arguments still take precedence in parseConfiguration.
    V07_SERVER_DATA_DIR: resolve(directory, "data"),
    V07_DEV: "1",
  };
  const configuration = await parseConfiguration(arguments_, environment);
  const displayHost = hostname() === "siva" ? "siva.otter-hawksbill.ts.net" : hostname();
  console.log(`Development URL: http://${displayHost}:${configuration.port}/v1/health`);
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
