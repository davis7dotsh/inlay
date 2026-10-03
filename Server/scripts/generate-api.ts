import { copyFile, mkdtemp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import openapiTS, { astToString } from "openapi-typescript";
import { format, resolveConfig } from "prettier";
import { parse } from "yaml";

const serverDirectory = resolve(import.meta.dir, "..");
const repositoryDirectory = resolve(serverDirectory, "..");
const schemaPath = join(serverDirectory, "api/openapi.yaml");
const swiftConfig = join(serverDirectory, "api/swift-openapi-generator-config.yaml");
const tsOutput = join(serverDirectory, "src/generated/api.ts");
const swiftOutput = join(repositoryDirectory, "Sources/InlayAPIWire");
const generatorVersion = "1.13.1";
const generatorRevision = "39d49cf22abab58a07f02bb76808b5d2839b294a";
const options = new Set(process.argv.slice(2));
const supported = new Set(["--check", "--typescript-only", "--swift-only"]);
for (const option of options) {
  if (!supported.has(option)) throw new Error(`Unknown API generation option: ${option}`);
}
if (options.has("--typescript-only") && options.has("--swift-only")) {
  throw new Error("Select either --typescript-only or --swift-only.");
}
const check = options.has("--check");
const staging = check ? await mkdtemp(join(tmpdir(), "inlay-api-generation-")) : undefined;

async function command(arguments_: string[]) {
  const child = Bun.spawn(arguments_, {
    cwd: repositoryDirectory,
    stdout: "inherit",
    stderr: "inherit",
  });
  if ((await child.exited) !== 0) throw new Error(`API generation failed: ${arguments_[0]}`);
}

async function compare(expected: string, generated: string) {
  const [existing, next] = await Promise.all([
    readFile(expected, "utf8"),
    readFile(generated, "utf8"),
  ]);
  if (existing !== next) throw new Error(`Generated API bindings are stale: ${expected}`);
}

try {
  if (!options.has("--swift-only")) {
    const document = parse(await readFile(schemaPath, "utf8"));
    const output = staging ? join(staging, "api.ts") : tsOutput;
    await mkdir(dirname(output), { recursive: true });
    const source = astToString(await openapiTS(document, { defaultNonNullable: false }));
    const formatted = await format(source, {
      ...(await resolveConfig(tsOutput)),
      filepath: tsOutput,
    });
    await writeFile(output, formatted);
    if (check) await compare(tsOutput, output);
  }

  if (!options.has("--typescript-only")) {
    // The generator is a Swift development tool. Client builds use committed
    // bindings and only depend on swift-openapi-runtime, not this checkout.
    const generator = join(repositoryDirectory, `.build/openapi-generator-${generatorVersion}`);
    if (!(await Bun.file(join(generator, "Package.swift")).exists())) {
      await mkdir(dirname(generator), { recursive: true });
      await command([
        "git",
        "clone",
        "--depth",
        "1",
        "--branch",
        generatorVersion,
        "https://github.com/apple/swift-openapi-generator.git",
        generator,
      ]);
    }
    const revision = Bun.spawn(["git", "-C", generator, "rev-parse", "HEAD"], {
      stdout: "pipe",
      stderr: "inherit",
    });
    const actualRevision = (await new Response(revision.stdout).text()).trim();
    if ((await revision.exited) !== 0 || actualRevision !== generatorRevision) {
      throw new Error(
        `Swift API generator checkout must match ${generatorVersion} (${generatorRevision}).`,
      );
    }
    await copyFile(
      join(serverDirectory, "api/swift-generator.Package.resolved"),
      join(generator, "Package.resolved"),
    );
    const output = staging ? join(staging, "swift") : swiftOutput;
    await mkdir(output, { recursive: true });
    await command([
      "swift",
      "run",
      "--package-path",
      generator,
      "--configuration",
      "release",
      "swift-openapi-generator",
      "generate",
      schemaPath,
      "--config",
      swiftConfig,
      "--output-directory",
      output,
    ]);
    if (check) {
      const expectedFiles = (await readdir(swiftOutput))
        .filter((name) => name.endsWith(".swift"))
        .sort();
      const generatedFiles = (await readdir(output))
        .filter((name) => name.endsWith(".swift"))
        .sort();
      if (expectedFiles.join("\n") !== generatedFiles.join("\n")) {
        throw new Error("The generated Swift API file set is stale.");
      }
      for (const name of generatedFiles) await compare(join(swiftOutput, name), join(output, name));
    }
  }
  console.log(check ? "API bindings match the contract." : "Generated API bindings.");
} finally {
  if (staging) await rm(staging, { recursive: true, force: true });
}
