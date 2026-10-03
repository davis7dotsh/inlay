import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { standaloneBuildSettings } from "./standalone-build-settings.ts";

const targets = ["bun-darwin-arm64", "bun-linux-x64", "bun-linux-arm64"] as const;
function currentTarget() {
  if (process.platform === "darwin" && process.arch === "arm64") return targets[0];
  if (process.platform === "linux" && process.arch === "x64") return targets[1];
  if (process.platform === "linux" && process.arch === "arm64") return targets[2];
  throw new Error("Supported server packages are Apple Silicon macOS and Linux x64/arm64.");
}
function options(arguments_: string[]) {
  let all = false;
  let target: (typeof targets)[number] | undefined;
  let outfile: string | undefined;
  for (let index = 0; index < arguments_.length; index++) {
    const argument = arguments_[index];
    if (argument === "--all") {
      all = true;
      continue;
    }
    if (argument === "--target" || argument?.startsWith("--target=")) {
      const value = argument === "--target" ? arguments_[++index] : argument.slice(9);
      target = targets.find((candidate) => candidate === value);
      if (!target) throw new Error(`Unsupported target: ${value}. Use ${targets.join(", ")}.`);
      continue;
    }
    if (argument === "--outfile" || argument?.startsWith("--outfile=")) {
      outfile = argument === "--outfile" ? arguments_[++index] : argument.slice(10);
      if (!outfile) throw new Error("--outfile requires a path.");
      continue;
    }
    throw new Error(`Unknown build argument: ${argument}.`);
  }
  if (all && (target || outfile))
    throw new Error("--all cannot be combined with --target or --outfile.");
  return { all, target, outfile };
}

const configuration = options(process.argv.slice(2));
const projectDirectory = resolve(import.meta.dirname, "../..");
const selectedTargets = configuration.all ? targets : [configuration.target ?? currentTarget()];
for (const target of selectedTargets) {
  const compileTarget = target === "bun-linux-x64" ? "bun-linux-x64-baseline" : target;
  const outfile = configuration.all
    ? resolve(projectDirectory, "build/server-coordinators", target.slice(4), "inlay-server")
    : resolve(configuration.outfile ?? resolve(projectDirectory, "build/server/inlay-server"));
  await mkdir(dirname(outfile), { recursive: true });
  const result = await Bun.build({
    ...standaloneBuildSettings(),
    compile: { target: compileTarget, outfile, autoloadDotenv: false, autoloadBunfig: false },
  });
  if (!result.success) {
    for (const message of result.logs) console.error(message);
    process.exitCode = 1;
    break;
  }
  console.log(`Built ${target}: ${outfile}`);
}
