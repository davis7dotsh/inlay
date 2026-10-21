import { copyFile, mkdtemp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
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
  {
    // Shared values: generated in every mode so --typescript-only CI keeps them fresh.
    const document = parse(await readFile(schemaPath, "utf8")) as Record<string, unknown>;
    const intValue = (key: string) => {
      const value = document[key];
      if (typeof value !== "number" || !Number.isInteger(value)) {
        throw new Error(`openapi.yaml must define an integer ${key}.`);
      }
      return value;
    };
    const apiVersion = intValue("x-inlay-apiVersion");
    const defaultPort = intValue("x-inlay-defaultPort");
    const maximumRecordingSeconds = intValue("x-inlay-maximumRecordingSeconds");
    const maximumChunkBytes = intValue("x-inlay-maximumChunkBytes");
    const maximumArtifactBytes = intValue("x-inlay-maximumArtifactBytes");
    const maximumDictionaryBytes = intValue("x-inlay-maximumDictionaryBytes");
    const maximumMetadataBytes = intValue("x-inlay-maximumMetadataBytes");
    const maximumPreferencesBytes = intValue("x-inlay-maximumPreferencesBytes");
    const languages = document["x-inlay-supportedLanguages"];
    if (!Array.isArray(languages) || !languages.every((code) => typeof code === "string")) {
      throw new Error("openapi.yaml must define a string array x-inlay-supportedLanguages.");
    }
    const prompt = await readFile(
      join(serverDirectory, "api/default-proofreading-prompt.txt"),
      "utf8",
    );
    const ts = `/** Generated from Server/api (openapi.yaml + default-proofreading-prompt.txt) by generate-api.ts; edit the sources, never this file. */
export const API_VERSION = ${apiVersion};
export const DEFAULT_PORT = ${defaultPort};
export const MAXIMUM_RECORDING_SECONDS = ${maximumRecordingSeconds};
export const MAXIMUM_CHUNK_BYTES = ${maximumChunkBytes};
export const MAXIMUM_ARTIFACT_BYTES = ${maximumArtifactBytes};
export const MAXIMUM_DICTIONARY_BYTES = ${maximumDictionaryBytes};
export const MAXIMUM_METADATA_BYTES = ${maximumMetadataBytes};
export const MAXIMUM_PREFERENCES_BYTES = ${maximumPreferencesBytes};
export const SUPPORTED_LANGUAGES: readonly string[] = ${JSON.stringify(languages)};
export const DEFAULT_PROOFREADING_PROMPT = ${JSON.stringify(prompt)};
`;
    const indented = prompt
      .split("\n")
      .map((line) => (line === "" ? "" : "        " + line))
      .join("\n");
    const swiftShared = `// Generated from Server/api (openapi.yaml + default-proofreading-prompt.txt) by generate-api.ts; edit the sources, never this file.

enum GeneratedShared {
    static let apiVersion = ${apiVersion}
    static let defaultPort = ${defaultPort}
    static let maximumRecordingSeconds = ${maximumRecordingSeconds}
    static let maximumChunkBytes = ${maximumChunkBytes}
    static let maximumArtifactBytes = ${maximumArtifactBytes}
    static let maximumDictionaryBytes = ${maximumDictionaryBytes}
    static let maximumMetadataBytes = ${maximumMetadataBytes}
    static let maximumPreferencesBytes = ${maximumPreferencesBytes}
    static let supportedLanguages = [${languages.map((code: string) => JSON.stringify(code)).join(", ")}]
    static let defaultProofreadingPrompt = """
${indented}
        """
}
`;
    interface PinFile {
      filename: string;
      bytes: number;
      sha256: string;
      url: string;
    }
    interface Pins {
      speech: {
        id: string;
        name: string;
        filename: string;
        bytes: number;
        sha256: string;
        url: string;
      };
      text: { id: string; name: string; directory: string; files: PinFile[] };
      linuxProof: { bytes: number; sha256: string };
    }
    const pins = JSON.parse(
      await readFile(join(serverDirectory, "api/model-pins.json"), "utf8"),
    ) as Pins;
    const manifest = [...pins.text.files]
      .sort((a, b) => (a.filename < b.filename ? -1 : a.filename > b.filename ? 1 : 0))
      .map((file) => `${file.filename}\t${file.bytes}\t${file.sha256}\n`)
      .join("");
    const manifestHash = createHash("sha256").update(manifest, "utf8").digest("hex");
    const tsPins = `/** Generated from Server/api/model-pins.json by generate-api.ts; edit the source, never this file. */
export const speechModelPin = {
  bytes: ${pins.speech.bytes},
  sha256: "${pins.speech.sha256}",
};

export const linuxProofModelPin = {
  bytes: ${pins.linuxProof.bytes},
  sha256: "${pins.linuxProof.sha256}",
};

// The MLX helper verifies its six-file artifact before emitting \`ready\`.
export const macProofManifestSHA256 = "${manifestHash}";
`;
    const filesSwift = pins.text.files
      .map(
        (file) =>
          `        Pin(filename: "${file.filename}", byteCount: ${file.bytes}, sha256: "${file.sha256}", url: "${file.url}"),`,
      )
      .join("\n");
    const swiftPins = `// Generated from Server/api/model-pins.json by generate-api.ts; edit the source, never this file.

public enum GeneratedModelPins {
    public struct Pin: Sendable {
        public let filename: String
        public let byteCount: Int64
        public let sha256: String
        public let url: String
    }

    public static let speechID = "${pins.speech.id}"
    public static let speechName = "${pins.speech.name}"
    public static let speechFilename = "${pins.speech.filename}"
    public static let speechByteCount: Int64 = ${pins.speech.bytes}
    public static let speechSHA256 = "${pins.speech.sha256}"
    public static let speechURL = "${pins.speech.url}"

    public static let textID = "${pins.text.id}"
    public static let textName = "${pins.text.name}"
    public static let textDirectory = "${pins.text.directory}"
    public static let textFiles: [Pin] = [
${filesSwift}
    ]
}
`;
    const formatTS = async (source: string, filepath: string) =>
      format(source, { ...(await resolveConfig(filepath)), filepath });
    const outputs: [string, string, string][] = [
      [
        join(serverDirectory, "src/generated/shared.ts"),
        await formatTS(ts, join(serverDirectory, "src/generated/shared.ts")),
        "shared.ts",
      ],
      [
        join(repositoryDirectory, "Sources/InlayAPI/GeneratedShared.swift"),
        swiftShared,
        "GeneratedShared.swift",
      ],
      [
        join(serverDirectory, "src/generated/model-pins.ts"),
        await formatTS(tsPins, join(serverDirectory, "src/generated/model-pins.ts")),
        "model-pins.ts",
      ],
      [
        join(repositoryDirectory, "Sources/InlayCore/GeneratedModelPins.swift"),
        swiftPins,
        "GeneratedModelPins.swift",
      ],
    ];
    for (const [target, content, stagedName] of outputs) {
      const destination = staging ? join(staging, stagedName) : target;
      await mkdir(dirname(destination), { recursive: true });
      await writeFile(destination, content);
      if (check) await compare(target, destination);
    }
  }

  console.log(check ? "API bindings match the contract." : "Generated API bindings.");
} finally {
  if (staging) await rm(staging, { recursive: true, force: true });
}
