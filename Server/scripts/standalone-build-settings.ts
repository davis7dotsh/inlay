import { resolve } from "node:path";

// Production and the compiled worker probe share this manifest so removing a
// worker entry or changing its embedded path fails the packaging check.
export function standaloneBuildSettings(
  entrypoint = resolve(import.meta.dirname, "../src/main.ts"),
) {
  return {
    root: resolve(import.meta.dirname, "../src"),
    entrypoints: [entrypoint, resolve(import.meta.dirname, "../src/domain/correction-worker.ts")],
    minify: true,
    sourcemap: "inline" as const,
    define: {
      "process.env.NODE_ENV": JSON.stringify("production"),
      "process.env.INLAY_SERVER_VERSION": JSON.stringify(
        process.env.INLAY_SERVER_VERSION ?? "0.0.0-dev",
      ),
    },
  };
}
