/**
 * Cross-file text parity checks (owner-approved, Batch 8): generated Swift and
 * TypeScript constants agree, dev/production ports stay distinct, app and
 * package.json release versions match, and every
 * INLAY_* variable named in the READMEs exists in code. This reads text only;
 * it asserts no runtime behaviour. See docs/development.md.
 */
import { readdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const serverDirectory = resolve(import.meta.dir, "..");
const repositoryDirectory = resolve(serverDirectory, "..");
const failures: string[] = [];

const read = (path: string) => readFile(join(repositoryDirectory, path), "utf8");

// --- Generated constants -----------------------------------------------------
const sharedTS = await read("Server/src/generated/shared.ts");
const sharedSwift = await read("Sources/InlayAPI/GeneratedShared.swift");
const pairs: [string, string][] = [
  ["API_VERSION", "apiVersion"],
  ["DEFAULT_PORT", "defaultPort"],
  ["MAXIMUM_RECORDING_SECONDS", "maximumRecordingSeconds"],
  ["MAXIMUM_CHUNK_BYTES", "maximumChunkBytes"],
  ["MAXIMUM_ARTIFACT_BYTES", "maximumArtifactBytes"],
  ["MAXIMUM_DICTIONARY_BYTES", "maximumDictionaryBytes"],
  ["MAXIMUM_METADATA_BYTES", "maximumMetadataBytes"],
  ["MAXIMUM_PREFERENCES_BYTES", "maximumPreferencesBytes"],
];
for (const [tsName, swiftName] of pairs) {
  const ts = new RegExp(`export const ${tsName} = (\\d+)`).exec(sharedTS)?.[1];
  const swift = new RegExp(`static let ${swiftName} = (\\d+)`).exec(sharedSwift)?.[1];
  if (!ts || !swift || ts !== swift) {
    failures.push(
      `generated constant ${tsName}/${swiftName} differs: TS=${ts ?? "?"} Swift=${swift ?? "?"}`,
    );
  }
}
const tsLanguages = [
  ...(sharedTS.match(/SUPPORTED_LANGUAGES[^=]*= \[([^\]]+)\]/s)?.[1] ?? "").matchAll(/"(\w+)"/g),
].map((match) => match[1] ?? "");
const swiftLanguages = [
  ...(sharedSwift.match(/supportedLanguages = \[([^\]]+)\]/)?.[1] ?? "").matchAll(/"(\w+)"/g),
].map((match) => match[1]);
if (tsLanguages.join(",") !== swiftLanguages.join(",")) {
  failures.push(
    `supported languages differ: TS=[${tsLanguages.join(",")}] Swift=[${swiftLanguages.join(",")}]`,
  );
}

// --- Ports -------------------------------------------------------------------
if (!sharedTS.includes("export const DEFAULT_PORT = 8391")) {
  failures.push("production default port is not 8391 in generated shared constants");
}
const devScript = await read("Server/scripts/dev.ts");
if (!devScript.includes('INLAY_SERVER_PORT: "8392"')) {
  failures.push("dev server does not use port 8392");
}

// --- Release version ---------------------------------------------------------
const releaseVersion = (JSON.parse(await read("package.json")) as { version?: string }).version;
for (const plist of ["Resources/Info.plist", "Resources/Info-Dev.plist"]) {
  const version = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(
    await read(plist),
  )?.[1];
  if (!releaseVersion || version !== releaseVersion) {
    failures.push(
      `${plist} version ${version ?? "?"} differs from package.json ${releaseVersion ?? "?"}`,
    );
  }
}

// --- Documented environment variables ----------------------------------------
async function corpus(directories: string[]): Promise<string> {
  const chunks: string[] = [];
  async function walk(directory: string) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (entry.name.startsWith(".build") || entry.name === "node_modules") continue;
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await walk(path);
      else if (/\.(ts|swift|sh|yml|yaml)$/.test(entry.name)) {
        chunks.push(await readFile(path, "utf8"));
      }
    }
  }
  for (const directory of directories) await walk(join(repositoryDirectory, directory));
  return chunks.join("\n");
}
const code = await corpus(["Server/src", "Server/scripts", "Sources", "scripts", ".github"]);
for (const readme of ["README.md", "Server/README.md"]) {
  const text = await read(readme);
  const names = new Set([...text.matchAll(/INLAY_[A-Z][A-Z0-9_]*/g)].map((match) => match[0]));
  for (const name of names) {
    if (!code.includes(name)) failures.push(`${readme} documents ${name}, which no code reads`);
  }
}

if (failures.length) {
  for (const failure of failures) console.error(`parity: ${failure}`);
  process.exit(1);
}
console.log("Parity checks passed.");
