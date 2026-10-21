import { acquireDataDirectoryLock } from "./data-lock.ts";
import {
  isLoopbackHost,
  parseConfiguration,
  usage,
  type ServerConfiguration,
} from "./configuration.ts";
import { createHTTPServer } from "./http-server.ts";
import { GenerationService, defaultProofreadingPrompt } from "./generation-service.ts";
import { logError, logInfo, logWarn } from "./log.ts";
import { NativeInference } from "./inference/native-inference.ts";

export async function startServer(configuration: ServerConfiguration) {
  const lock = acquireDataDirectoryLock(configuration.dataDirectory);
  let service: GenerationService | undefined;
  try {
    service = await GenerationService.open(
      {
        dataDirectory: configuration.dataDirectory,
        development: configuration.development,
        adminToken: configuration.token,
      },
      new NativeInference(configuration.inference),
    );
    const app = createHTTPServer(service);
    service.start();
    const address = await app.listen({ host: configuration.host, port: configuration.port });
    if (!isLoopbackHost(configuration.host))
      logWarn("plain_http_non_loopback", {
        host: configuration.host,
        message:
          "Plain HTTP on a non-loopback bind leaves tokens, audio, and transcripts unencrypted. Use a Tailscale address or an HTTPS reverse proxy.",
      });
    let closing: Promise<void> | undefined;
    const close = () =>
      (closing ??= (async () => {
        try {
          await service!.shutdown();
        } finally {
          try {
            await app.close();
          } finally {
            lock.release();
          }
        }
      })());
    return { app, service, address, close };
  } catch (error) {
    try {
      await service?.shutdown();
    } finally {
      lock.release();
    }
    throw error;
  }
}

if (import.meta.main) {
  try {
    if (process.argv.includes("--help") || process.argv.includes("-h")) console.log(usage);
    else if (process.argv.includes("--print-default-proofreading-prompt"))
      console.log(defaultProofreadingPrompt);
    else {
      const configuration = await parseConfiguration();
      const server = await startServer(configuration);
      if (configuration.adminTokenCreated)
        logInfo("admin_token_created", { file: configuration.adminTokenFile });
      logInfo("server_listening", { address: server.address });
      const stop = () => {
        void server.close().then(
          () => process.exit(0),
          () => process.exit(1),
        );
      };
      process.once("SIGTERM", stop);
      process.once("SIGINT", stop);
    }
  } catch (error) {
    logError("server_start_failed", error);
    process.exitCode = 1;
  }
}
