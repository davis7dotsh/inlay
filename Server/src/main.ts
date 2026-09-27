import { acquireDataDirectoryLock } from "./data-lock.ts";
import { parseConfiguration, usage, type ServerConfiguration } from "./configuration.ts";
import { createHTTPServer } from "./http-server.ts";
import { GenerationService, defaultProofreadingPrompt } from "./generation-service.ts";
import { NativeInference } from "./inference/native-inference.ts";

export async function startServer(configuration: ServerConfiguration) {
  const lock = acquireDataDirectoryLock(configuration.dataDirectory);
  let service: GenerationService | undefined;
  try {
    service = await GenerationService.open(
      configuration,
      new NativeInference(configuration.inference),
    );
    const app = createHTTPServer(service, configuration.token);
    service.start();
    const address = await app.listen({ host: configuration.host, port: configuration.port });
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
      const server = await startServer(await parseConfiguration());
      console.log(`V07 server listening at ${server.address}`);
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
    console.error(error instanceof Error ? error.message : "The server could not start.");
    process.exitCode = 1;
  }
}
