import { mkdir, readFile, readdir, realpath, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";

const serverDirectory = resolve(import.meta.dirname, "..");
const output = resolve(
  process.argv[2] ?? resolve(serverDirectory, "../build/server/resources/javascript-LICENSES.txt"),
);
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
async function manifest(directory: string) {
  const value: unknown = JSON.parse(await readFile(join(directory, "package.json"), "utf8"));
  if (!record(value)) throw new Error(`Invalid package manifest: ${directory}`);
  return value;
}
function dependencyNames(value: unknown) {
  return record(value) ? Object.keys(value).sort() : [];
}
async function installedPackage(name: string, from: string) {
  for (let directory = from; ; directory = dirname(directory)) {
    const candidate = join(directory, "node_modules", name);
    try {
      if ((await stat(join(candidate, "package.json"))).isFile()) return await realpath(candidate);
    } catch (error) {
      if (!record(error) || error.code !== "ENOENT") throw error;
    }
    if (dirname(directory) === directory) return undefined;
  }
}
async function licenseFiles(directory: string) {
  const paths: string[] = [];
  async function add(path: string) {
    const attributes = await stat(path);
    if (attributes.isFile()) paths.push(path);
    else if (attributes.isDirectory()) {
      for (const name of (await readdir(path)).sort()) await add(join(path, name));
    }
  }
  for (const name of (await readdir(directory)).sort()) {
    if (/^(?:licen[cs]e|copying|notice)(?:[._-].*)?$/i.test(name)) await add(join(directory, name));
  }
  return paths;
}

const packages = new Map<
  string,
  { name: string; version: string; license: string; directory: string }
>();
async function visit(name: string, from: string, optional = false) {
  const directory = await installedPackage(name, from);
  if (!directory) {
    if (optional) return;
    throw new Error(`Missing runtime dependency ${name}; run bun install --frozen-lockfile.`);
  }
  if (packages.has(directory)) return;
  const package_ = await manifest(directory);
  if (typeof package_.name !== "string" || typeof package_.version !== "string")
    throw new Error(`Missing package identity: ${directory}`);
  packages.set(directory, {
    name: package_.name,
    version: package_.version,
    license:
      typeof package_.license === "string" ? package_.license : "See upstream license texts.",
    directory,
  });
  for (const dependency of dependencyNames(package_.dependencies))
    await visit(dependency, directory);
  for (const dependency of dependencyNames(package_.optionalDependencies))
    await visit(dependency, directory, true);
  for (const dependency of dependencyNames(package_.peerDependencies))
    await visit(dependency, directory, true);
}
const root = await manifest(serverDirectory);
for (const dependency of dependencyNames(root.dependencies))
  await visit(dependency, serverDirectory);

const notices = [
  "Inlay server JavaScript runtime dependency licenses",
  "Installed versions are pinned by bun.lock. Development-only packages are excluded.",
];
for (const package_ of [...packages.values()].sort(
  (left, right) =>
    left.name.localeCompare(right.name, "en") || left.version.localeCompare(right.version, "en"),
)) {
  const files = await licenseFiles(package_.directory);
  const texts = await Promise.all(
    files.map(async (file) => ({
      name: relative(package_.directory, file),
      text: await readFile(file, "utf8"),
    })),
  );
  if (!texts.length) {
    // A few npm packages ship their license notice only in the README.
    for (const name of (await readdir(package_.directory)).sort()) {
      if (!/^readme(?:\..*)?$/i.test(name)) continue;
      const readme = await readFile(join(package_.directory, name), "utf8");
      const section = /^#{1,6}\s+licen[cs]e\b.*$/im.exec(readme);
      if (section)
        texts.push({ name: `${name} (license section)`, text: readme.slice(section.index) });
    }
  }
  if (!texts.length)
    throw new Error(`No license notice shipped with ${package_.name}@${package_.version}.`);
  notices.push(`\n${"=".repeat(72)}\n${package_.name}@${package_.version} — ${package_.license}`);
  for (const file of texts) notices.push(`\n--- ${file.name} ---\n${file.text.trimEnd()}`);
}
await mkdir(dirname(output), { recursive: true });
await writeFile(output, notices.join("\n") + "\n");
console.log(`Collected license texts for ${packages.size} runtime packages: ${output}`);
