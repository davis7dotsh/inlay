import { constants } from "node:fs";
import { randomUUID } from "node:crypto";
import { lstat, mkdir, open, readdir, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import type {
  GenerationRecord,
  PreferencesSnapshot,
  WisprFlowArtifactManifest,
  WisprFlowArtifactName,
  WisprFlowImportRequest,
  WisprFlowImportResult,
  WisprFlowKnownIDsRequest,
} from "./api.ts";
import { ServiceError } from "./errors.ts";
import {
  atomicPrivateWrite,
  ensureDirectory,
  readRegularFile,
  requireRegularDirectory,
  sha256,
} from "./storage.ts";

const maximumArtifactBytes = 8_388_608;
const maximumMetadataBytes = 1_048_576;
const artifactNames: WisprFlowArtifactName[] = [
  "source.json",
  "source.wav",
  "opus.json",
  "screenshot.png",
  "built-in-audio.bin",
];
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const validSHA256 = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const isNonnegativeInteger = (value: unknown): value is number =>
  Number.isSafeInteger(value) && Number(value) >= 0;
const positiveInteger = (value: unknown): value is number =>
  isNonnegativeInteger(value) && value > 0;
type JSONValue = null | boolean | number | string | JSONValue[] | JSONObject;
type JSONObject = { [key: string]: JSONValue };
const object = (value: unknown): value is JSONObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const objectArray = (value: unknown): value is JSONObject[] =>
  Array.isArray(value) && value.every(object);
const canonical = (value: JSONValue): JSONValue =>
  Array.isArray(value)
    ? value.map(canonical)
    : object(value)
      ? Object.fromEntries(
          Object.keys(value)
            .sort()
            .map((key) => [key, canonical(value[key]!)]),
        )
      : value;
const encode = (value: JSONValue) => Buffer.from(JSON.stringify(canonical(value)));
const parse = (data: Uint8Array): unknown => {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data));
  } catch {
    throw new ServiceError(400, "invalid_source_json", "The source archive is invalid.");
  }
};
const sourceDocument = (data: Uint8Array) => {
  const document = parse(data);
  if (!object(document))
    throw new ServiceError(400, "invalid_source_json", "The source archive is invalid.");
  return document;
};
const sourceBytes = (document: JSONObject) => {
  const result = encode(document);
  if (result.length > maximumArtifactBytes)
    throw new ServiceError(
      413,
      "source_archive_limit",
      "The preserved source versions exceeded 8 MiB.",
    );
  return result;
};

function sourceOmissions(document: JSONObject) {
  const omissions = document.archiveOmissions;
  if (omissions !== undefined && !objectArray(omissions))
    throw new ServiceError(400, "invalid_source_json", "Media omission records must be an array.");
  return (omissions ?? []).map((entry) => {
    if (
      typeof entry.artifact !== "string" ||
      !artifactNames.includes(entry.artifact as WisprFlowArtifactName) ||
      entry.artifact === "source.json" ||
      !positiveInteger(entry.observedByteCount) ||
      !validSHA256(entry.observedSHA256) ||
      (entry.status !== "archived" && entry.status !== "not-archived")
    ) {
      throw new ServiceError(
        400,
        "invalid_source_json",
        "Media omission records need a valid name, size, digest, and status.",
      );
    }
    return {
      filename: entry.artifact as WisprFlowArtifactName,
      byteCount: entry.observedByteCount,
      sha256: entry.observedSHA256,
    };
  });
}

function recordedProvenanceFieldCount(document: JSONObject) {
  if (!objectArray(document.sources))
    throw new ServiceError(400, "invalid_source_json", "Source provenance rows must be objects.");
  let count = 0;
  for (const source of document.sources) {
    for (const key of ["omittedValueCount", "omittedColumnCount"]) {
      const omitted = source[key];
      if (omitted === undefined) continue;
      if (!isNonnegativeInteger(omitted) || !Number.isSafeInteger(count + omitted))
        throw new ServiceError(
          400,
          "invalid_source_json",
          "Source row omission counts are invalid.",
        );
      count += omitted;
    }
    if (source.omittedValuesSHA256 !== undefined && !validSHA256(source.omittedValuesSHA256))
      throw new ServiceError(
        400,
        "invalid_source_json",
        "Source row omission digests are invalid.",
      );
    for (const field of Object.values(object(source.values) ? source.values : {})) {
      if (!object(field) || field.archiveReason !== "exceeds-source-json-limit") continue;
      if (
        (field.type !== "text" && field.type !== "blob") ||
        !positiveInteger(field.byteCount) ||
        !validSHA256(field.sha256) ||
        field.archiveStatus !== "not-archived" ||
        field.value !== undefined ||
        field.base64 !== undefined ||
        !Number.isSafeInteger(count + 1)
      ) {
        throw new ServiceError(
          400,
          "invalid_source_json",
          "Omitted source values need their size, digest, and reason.",
        );
      }
      count++;
    }
  }
  return count;
}

function sourceProvenanceIsPartial(document: JSONObject) {
  const countKeys = [
    "provenanceOmittedFieldCount",
    "provenanceOmittedSourceCount",
    "provenanceOmittedMediaVersionCount",
  ];
  const digestKeys = ["provenanceOmittedSourcesSHA256", "provenanceOmittedMediaVersionsSHA256"];
  const recordedCount = recordedProvenanceFieldCount(document);
  if (document.provenanceStatus === undefined) {
    if (
      recordedCount ||
      [...countKeys, "provenanceOmittedColumnCount", ...digestKeys].some(
        (key) => document[key] !== undefined,
      )
    ) {
      throw new ServiceError(
        400,
        "invalid_source_json",
        "Source provenance status and omission counts disagree.",
      );
    }
    return false;
  }
  if (
    document.provenanceStatus !== "partial" ||
    !countKeys.every((key) => isNonnegativeInteger(document[key])) ||
    !countKeys.some((key) => Number(document[key]) > 0) ||
    Number(document[countKeys[0]!]) < recordedCount ||
    (document.provenanceOmittedColumnCount !== undefined &&
      !isNonnegativeInteger(document.provenanceOmittedColumnCount)) ||
    digestKeys.some((key) => document[key] !== undefined && !validSHA256(document[key]))
  ) {
    throw new ServiceError(
      400,
      "invalid_source_json",
      "Partial source provenance needs valid omission counts and digests.",
    );
  }
  return true;
}

const mediaColumns = {
  audio: "source.wav",
  opusChunks: "opus.json",
  screenshot: "screenshot.png",
  builtInAudio: "built-in-audio.bin",
};

function reconciledSourceJSON(data: Uint8Array, archivedHashes: Record<string, string>) {
  const document = sourceDocument(data);
  sourceOmissions(document);
  const provenancePartial = sourceProvenanceIsPartial(document);
  const unarchivedHashes: Record<string, string> = {};
  for (const key of ["archiveOmissions", "archiveConflicts"]) {
    const entries = document[key];
    if (key === "archiveConflicts" && entries !== undefined && !objectArray(entries))
      throw new ServiceError(400, "invalid_source_json", "Source conflict history is invalid.");
    if (!objectArray(entries)) continue;
    for (const entry of entries) {
      if (typeof entry.artifact !== "string" || !validSHA256(entry.observedSHA256)) continue;
      const archived = archivedHashes[entry.artifact] === entry.observedSHA256;
      entry.status = archived ? "archived" : "not-archived";
      if (!archived && unarchivedHashes[entry.artifact] === undefined)
        unarchivedHashes[entry.artifact] = entry.observedSHA256;
    }
  }
  if (objectArray(document.sources))
    for (const source of document.sources) {
      if (!object(source.values)) continue;
      for (const [column, filename] of Object.entries(mediaColumns)) {
        const field = source.values[column];
        if (!object(field) || !validSHA256(field.sha256)) continue;
        if (archivedHashes[filename] === field.sha256) {
          field.artifact = filename;
          field.archiveStatus = "archived";
          delete field.archiveReason;
        } else if (field.archiveStatus === "not-archived") delete field.artifact;
      }
    }
  return { data: sourceBytes(document), unarchivedHashes, provenancePartial };
}

function sourceVersionKey(source: JSONValue) {
  if (!object(source))
    throw new ServiceError(
      400,
      "invalid_source_json",
      "The source contains an invalid row version.",
    );
  const normalized = structuredClone(source);
  if (object(normalized.values))
    for (const column of Object.keys(mediaColumns)) {
      const field = normalized.values[column];
      if (!object(field)) continue;
      for (const key of ["artifact", "archiveStatus", "archiveReason"]) delete field[key];
    }
  return sha256(encode(normalized));
}

function mergedSourceJSON(old: Uint8Array, incoming: Uint8Array) {
  const earlier = sourceDocument(old),
    newer = sourceDocument(incoming);
  if (
    earlier.provider !== "wispr-flow" ||
    typeof earlier.sourceID !== "string" ||
    typeof newer.sourceID !== "string" ||
    earlier.sourceID.toLowerCase() !== newer.sourceID.toLowerCase() ||
    !Array.isArray(earlier.sources) ||
    !Array.isArray(newer.sources)
  ) {
    throw new ServiceError(500, "invalid_archive", "The existing source archive cannot be merged.");
  }
  sourceOmissions(earlier);
  sourceOmissions(newer);
  const seen = new Set<string>();
  const sources = [...earlier.sources, ...newer.sources].filter((source) => {
    const key = sourceVersionKey(source);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  const omissions: JSONObject[] = [],
    seenOmissions = new Set<string>();
  for (const document of [earlier, newer])
    if (objectArray(document.archiveOmissions))
      for (const omission of document.archiveOmissions) {
        const key = JSON.stringify([
          omission.artifact ?? "",
          omission.observedSHA256 ?? "",
          omission.sourceName ?? "",
          Number(omission.sourceRowID ?? 0),
        ]);
        if (!seenOmissions.has(key)) {
          seenOmissions.add(key);
          omissions.push(omission);
        }
      }
  const merged = { ...earlier };
  for (const [key, value] of Object.entries(newer))
    if (key !== "sources" && key !== "archiveOmissions") merged[key] = value;
  merged.sources = sources;
  if (omissions.length) merged.archiveOmissions = omissions;
  const earlierPartial = sourceProvenanceIsPartial(earlier),
    newerPartial = sourceProvenanceIsPartial(newer);
  if (earlierPartial || newerPartial) {
    merged.provenanceStatus = "partial";
    const recorded = recordedProvenanceFieldCount(merged);
    for (const key of [
      "provenanceOmittedFieldCount",
      "provenanceOmittedSourceCount",
      "provenanceOmittedMediaVersionCount",
      "provenanceOmittedColumnCount",
    ]) {
      const count = Math.max(
        Number(earlier[key] ?? 0),
        Number(newer[key] ?? 0),
        key === "provenanceOmittedFieldCount" ? recorded : 0,
      );
      if (key !== "provenanceOmittedColumnCount" || count > 0) merged[key] = count;
    }
    for (const key of ["provenanceOmittedSourcesSHA256", "provenanceOmittedMediaVersionsSHA256"]) {
      if (
        typeof earlier[key] === "string" &&
        typeof newer[key] === "string" &&
        earlier[key] !== newer[key]
      )
        delete merged[key];
    }
  }
  sourceProvenanceIsPartial(merged);
  return sourceBytes(merged);
}

function recordingConflict(
  data: Uint8Array,
  manifest: WisprFlowArtifactManifest,
  archivedSHA256: string,
) {
  const document = sourceDocument(data);
  if (document.archiveConflicts !== undefined && !objectArray(document.archiveConflicts))
    throw new ServiceError(500, "invalid_archive", "Source conflict history is invalid.");
  if (objectArray(document.sources))
    for (const source of document.sources) {
      if (!object(source.values)) continue;
      for (const column of Object.keys(mediaColumns)) {
        const field = source.values[column];
        if (
          object(field) &&
          field.artifact === manifest.filename &&
          field.sha256 === manifest.sha256
        ) {
          delete field.artifact;
          field.archiveStatus = "not-archived";
        }
      }
    }
  const conflicts = document.archiveConflicts ?? [];
  if (
    !conflicts.some(
      (entry) => entry.artifact === manifest.filename && entry.observedSHA256 === manifest.sha256,
    )
  ) {
    conflicts.push({
      artifact: manifest.filename,
      archivedSHA256,
      observedSHA256: manifest.sha256,
      observedByteCount: manifest.byteCount,
      status: "not-archived",
    });
  }
  document.archiveConflicts = conflicts;
  return sourceBytes(document);
}

type ImportContext = {
  dataDirectory: string;
  getPreferences(): PreferencesSnapshot;
  getRecord(id: string): GenerationRecord;
  publish(record: GenerationRecord): void;
  requireDiskSpace(): Promise<void>;
};
type ImportStage = {
  request: WisprFlowImportRequest;
  directory: string;
  uploaded: Set<WisprFlowArtifactName>;
  touchedAt: number;
};

async function exists(path: string) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (object(error) && error.code === "ENOENT") return false;
    throw error;
  }
}
async function syncDirectory(path: string) {
  const directory = await open(
    path,
    constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
  );
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
}

/** Called under GenerationService's mutation queue. Inference never owns this state. */
export class WisprFlowImports {
  private readonly stages = new Map<string, ImportStage>();
  private readonly index = new Map<string, string>();
  private readonly root: string;
  private readonly stagingRoot: string;
  private readonly transactionsRoot: string;

  constructor(private readonly context: ImportContext) {
    this.root = join(context.dataDirectory, "imports", "wispr-flow");
    this.stagingRoot = join(this.root, "staging");
    this.transactionsRoot = join(this.root, "transactions");
  }

  async initialize() {
    for (const root of [
      join(this.context.dataDirectory, "imports"),
      this.root,
      this.stagingRoot,
      this.transactionsRoot,
    ])
      await ensureDirectory(root);
    // Recover a rename interrupted between removing the old directory and publishing
    // the complete replacement. This runs before GenerationService reads metadata.
    for (const filename of await readdir(this.transactionsRoot)) {
      if (!filename.endsWith(".json") || !uuidPattern.test(filename.slice(0, -5))) continue;
      const journal = sourceDocument(
        await readRegularFile(join(this.transactionsRoot, filename), 1024),
      );
      if (
        typeof journal.recordID !== "string" ||
        !uuidPattern.test(journal.recordID) ||
        typeof journal.stageID !== "string" ||
        !uuidPattern.test(journal.stageID) ||
        journal.stageID !== filename.slice(0, -5)
      )
        throw new ServiceError(500, "invalid_archive", "An import replacement journal is invalid.");
      const live = this.directory(journal.recordID),
        backup = join(this.transactionsRoot, `${journal.stageID}.backup`);
      if (await exists(live)) await requireRegularDirectory(live);
      if (await exists(backup)) {
        await requireRegularDirectory(backup);
        if (await exists(live)) await rm(backup, { recursive: true });
        else {
          await rename(backup, live);
          await syncDirectory(join(this.context.dataDirectory, "generations"));
          await syncDirectory(this.transactionsRoot);
        }
      } else if (!(await exists(live)))
        throw new ServiceError(
          500,
          "invalid_archive",
          "An import replacement has lost its durable archive.",
        );
      await rm(join(this.transactionsRoot, filename));
    }
    for (const child of await readdir(this.stagingRoot))
      if (uuidPattern.test(child))
        await rm(join(this.stagingRoot, child), { recursive: true, force: true });
  }

  indexRecord(record: GenerationRecord) {
    if (record.importedSource?.provider !== "wispr-flow") return;
    const key = record.importedSource.sourceID.toLowerCase();
    if (this.index.has(key))
      throw new ServiceError(
        500,
        "duplicate_import",
        "The archive contains duplicate Wispr Flow source IDs.",
      );
    this.index.set(key, record.id);
  }
  removeRecord(record: GenerationRecord) {
    if (record.importedSource?.provider === "wispr-flow")
      this.index.delete(record.importedSource.sourceID.toLowerCase());
  }
  knownWisprFlowIDs(request: WisprFlowKnownIDsRequest) {
    if (request.sourceIDs.length > 10_000)
      throw new ServiceError(413, "source_id_limit", "Check at most 10,000 source IDs at once.");
    return { knownSourceIDs: request.sourceIDs.filter((id) => this.index.has(id.toLowerCase())) };
  }

  async beginWisprFlowImport(request: WisprFlowImportRequest) {
    await this.expireImportStages();
    if (this.stages.size >= 16)
      throw new ServiceError(429, "import_limit", "Too many imports are staged.");
    const createdAt = Date.parse(request.createdAt) / 1000;
    if (!(createdAt > 0 && createdAt < 4_102_444_800))
      throw new ServiceError(
        400,
        "invalid_source_date",
        "The source date is outside the supported range.",
      );
    const optionalLabel = (label: string | undefined, limit: number) =>
      label === undefined || (Buffer.byteLength(label) <= limit && !/[\0\n]/.test(label));
    if (
      Buffer.byteLength(request.finalText) > 65_536 ||
      Buffer.byteLength(request.rawText) > 65_536 ||
      !optionalLabel(request.sourceStatus, 128) ||
      request.variantNames.length > 32 ||
      request.variantNames.some((name) => !optionalLabel(name, 64)) ||
      (request.durationSeconds !== undefined &&
        (!Number.isFinite(request.durationSeconds) ||
          request.durationSeconds < 0 ||
          request.durationSeconds > 86_400))
    ) {
      throw new ServiceError(
        400,
        "invalid_source_metadata",
        "The source metadata exceeds its limits or contains invalid values.",
      );
    }
    const names = request.artifacts.map((manifest) => manifest.filename);
    const validManifest = (manifest: WisprFlowArtifactManifest) =>
      positiveInteger(manifest.byteCount) &&
      validSHA256(manifest.sha256) &&
      artifactNames.includes(manifest.filename);
    if (
      names.length < 1 ||
      names.length > 4 ||
      new Set(names).size !== names.length ||
      !names.includes("source.json") ||
      names.includes("built-in-audio.bin") ||
      request.artifacts.some(
        (manifest) => !validManifest(manifest) || manifest.byteCount > maximumArtifactBytes,
      ) ||
      (request.unarchivedArtifacts ?? []).some(
        (manifest) => manifest.filename === "source.json" || !validManifest(manifest),
      )
    ) {
      throw new ServiceError(
        400,
        "invalid_artifact_manifest",
        "Supply one valid manifest per allowlisted artifact, including source.json.",
      );
    }
    await this.context.requireDiskSpace();
    const id = randomUUID().toUpperCase(),
      directory = join(this.stagingRoot, id);
    await requireRegularDirectory(this.stagingRoot);
    await mkdir(directory, { mode: 0o700 });
    this.stages.set(id, {
      request: structuredClone(request),
      directory,
      uploaded: new Set(),
      touchedAt: Date.now(),
    });
    return { id };
  }

  async uploadWisprFlowArtifact(id: string, filename: WisprFlowArtifactName, input: Uint8Array) {
    const stage = this.stage(id),
      manifest = stage.request.artifacts.find((item) => item.filename === filename),
      data = Buffer.from(input);
    if (!manifest)
      throw new ServiceError(
        400,
        "artifact_unexpected",
        "This artifact is not in the import manifest.",
      );
    if (data.length !== manifest.byteCount || sha256(data) !== manifest.sha256)
      throw new ServiceError(
        400,
        "artifact_checksum",
        "The artifact size or checksum does not match its manifest.",
      );
    switch (filename) {
      case "source.json": {
        const source = sourceDocument(data);
        if (
          source.schemaVersion !== 1 ||
          source.provider !== "wispr-flow" ||
          typeof source.sourceID !== "string" ||
          source.sourceID.toLowerCase() !== stage.request.sourceID.toLowerCase() ||
          !Array.isArray(source.sources)
        ) {
          throw new ServiceError(
            400,
            "invalid_source_json",
            "The source artifact must describe this Wispr Flow session.",
          );
        }
        const recorded = new Set(
          sourceOmissions(source).map(
            (item) => `${item.filename}:${item.byteCount}:${item.sha256}`,
          ),
        );
        sourceProvenanceIsPartial(source);
        if (
          (stage.request.unarchivedArtifacts ?? []).some(
            (item) => !recorded.has(`${item.filename}:${item.byteCount}:${item.sha256}`),
          )
        )
          throw new ServiceError(
            400,
            "invalid_source_json",
            "Every omitted media digest must be recorded in source.json.",
          );
        break;
      }
      case "opus.json":
        try {
          parse(data);
        } catch {
          throw new ServiceError(400, "invalid_opus_json", "Opus source data must be valid JSON.");
        }
        break;
      case "source.wav":
        if (
          data.length < 12 ||
          !data.subarray(0, 4).equals(Buffer.from("RIFF")) ||
          !data.subarray(8, 12).equals(Buffer.from("WAVE"))
        )
          throw new ServiceError(
            400,
            "invalid_source_wav",
            "Source audio must be a RIFF WAVE file.",
          );
        break;
      case "screenshot.png":
        if (!data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])))
          throw new ServiceError(
            400,
            "invalid_screenshot",
            "Source screenshot must be a PNG file.",
          );
        break;
      case "built-in-audio.bin":
        throw new ServiceError(
          400,
          "unsupported_source_artifact",
          "Unknown built-in audio bytes can be recorded as omitted, not uploaded.",
        );
    }
    await this.context.requireDiskSpace();
    await requireRegularDirectory(stage.directory);
    await atomicPrivateWrite(join(stage.directory, filename), data);
    stage.uploaded.add(filename);
    stage.touchedAt = Date.now();
    return { filename, byteCount: data.length };
  }

  async completeWisprFlowImport(id: string): Promise<WisprFlowImportResult> {
    const stage = this.stage(id),
      request = stage.request;
    if (
      stage.uploaded.size !== request.artifacts.length ||
      request.artifacts.some((item) => !stage.uploaded.has(item.filename))
    )
      throw new ServiceError(
        409,
        "incomplete_import",
        "Upload every manifest artifact before completing this import.",
      );
    await requireRegularDirectory(stage.directory);
    for (const manifest of request.artifacts) {
      let bytes: Buffer;
      try {
        bytes = await readRegularFile(
          join(stage.directory, manifest.filename),
          maximumArtifactBytes,
        );
      } catch {
        throw new ServiceError(
          409,
          "staged_artifact_changed",
          "A staged artifact no longer matches its manifest.",
        );
      }
      if (bytes.length !== manifest.byteCount || sha256(bytes) !== manifest.sha256)
        throw new ServiceError(
          409,
          "staged_artifact_changed",
          "A staged artifact no longer matches its manifest.",
        );
    }
    const incomingHashes = Object.fromEntries(
      request.artifacts.map((item) => [item.filename, item.sha256]),
    );
    const sourceHash = incomingHashes["source.json"]!;
    const existingID = this.index.get(request.sourceID.toLowerCase());
    if (existingID) {
      const record = structuredClone(this.context.getRecord(existingID)),
        source = record.importedSource;
      if (!source)
        throw new ServiceError(500, "invalid_archive", "The existing source archive is invalid.");
      const conflicts = request.artifacts.filter(
        (item) =>
          item.filename !== "source.json" &&
          source.artifactSHA256[item.filename] !== undefined &&
          source.artifactSHA256[item.filename] !== item.sha256,
      );
      const sameArtifacts = request.artifacts.every((item) =>
        item.filename === "source.json"
          ? source.sourceSHA256 === item.sha256
          : source.artifactSHA256[item.filename] === item.sha256 ||
            (source.artifactSHA256[item.filename] !== undefined &&
              source.unarchivedArtifactSHA256?.[item.filename] === item.sha256),
      );
      const variants = new Set(source.variantNames);
      const sameMetadata =
        (!request.finalText || record.finalText === request.finalText) &&
        (!request.rawText || record.rawText === request.rawText) &&
        (request.sourceStatus === undefined || source.sourceStatus === request.sourceStatus) &&
        (request.durationSeconds === undefined ||
          source.durationSeconds === request.durationSeconds) &&
        request.variantNames.every((name) => variants.has(name));
      const earlierDirectory = this.directory(existingID);
      await requireRegularDirectory(earlierDirectory);
      const oldSource = await readRegularFile(
        join(earlierDirectory, "source.json"),
        maximumArtifactBytes,
      );
      if (sameArtifacts && sameMetadata) {
        const partial = sourceProvenanceIsPartial(sourceDocument(oldSource));
        await rm(stage.directory, { recursive: true });
        this.stages.delete(id.toUpperCase());
        const names = this.names(source.unarchivedArtifactSHA256 ?? {});
        return {
          outcome: names.length || partial ? "partial" : "skipped",
          record,
          unarchivedArtifactNames: names,
        };
      }
      let nextSource =
        source.sourceSHA256 !== sourceHash
          ? mergedSourceJSON(
              oldSource,
              await readRegularFile(join(stage.directory, "source.json"), maximumArtifactBytes),
            )
          : oldSource;
      source.sourceSHA256 = sourceHash;
      for (const manifest of conflicts) {
        const oldHash = source.artifactSHA256[manifest.filename]!;
        const earlier = await readRegularFile(
          join(earlierDirectory, manifest.filename),
          maximumArtifactBytes,
        );
        if (sha256(earlier) !== oldHash)
          throw new ServiceError(
            500,
            "invalid_archive",
            "An archived source artifact no longer matches its metadata.",
          );
        await atomicPrivateWrite(join(stage.directory, manifest.filename), earlier);
        nextSource = recordingConflict(nextSource, manifest, oldHash);
      }
      for (const manifest of request.artifacts)
        if (
          manifest.filename !== "source.json" &&
          source.artifactSHA256[manifest.filename] === undefined
        )
          source.artifactSHA256[manifest.filename] = manifest.sha256;
      const reconciliation = reconciledSourceJSON(nextSource, source.artifactSHA256);
      source.unarchivedArtifactSHA256 = reconciliation.unarchivedHashes;
      await atomicPrivateWrite(join(stage.directory, "source.json"), reconciliation.data);
      source.artifactSHA256["source.json"] = sha256(reconciliation.data);
      for (const filename of source.artifactNames)
        if (!stage.uploaded.has(filename))
          await readRegularFile(join(earlierDirectory, filename), maximumArtifactBytes);
      for (const filename of await readdir(earlierDirectory)) {
        if (await exists(join(stage.directory, filename))) continue;
        await atomicPrivateWrite(
          join(stage.directory, filename),
          await readRegularFile(join(earlierDirectory, filename), maximumArtifactBytes),
        );
      }
      source.sourceStatus = request.sourceStatus ?? source.sourceStatus;
      source.durationSeconds = request.durationSeconds ?? source.durationSeconds;
      source.variantNames = [...new Set([...source.variantNames, ...request.variantNames])].sort();
      source.artifactNames = this.names(source.artifactSHA256);
      if (request.finalText) record.finalText = request.finalText;
      if (request.rawText) record.rawText = request.rawText;
      record.updatedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
      await this.writeRecord(stage.directory, record);
      await this.replaceDirectory(existingID, id.toUpperCase(), stage.directory);
      this.context.publish(record);
      this.stages.delete(id.toUpperCase());
      const names = this.names(reconciliation.unarchivedHashes);
      return {
        outcome: names.length || reconciliation.provenancePartial ? "partial" : "enriched",
        record,
        unarchivedArtifactNames: names,
      };
    }
    const recordID = randomUUID().toUpperCase(),
      now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    const reconciliation = reconciledSourceJSON(
      await readRegularFile(join(stage.directory, "source.json"), maximumArtifactBytes),
      incomingHashes,
    );
    await atomicPrivateWrite(join(stage.directory, "source.json"), reconciliation.data);
    incomingHashes["source.json"] = sha256(reconciliation.data);
    const record: GenerationRecord = {
      schemaVersion: 1,
      id: recordID,
      requestID: request.sourceID,
      device: { id: "wispr-flow", name: "Wispr Flow" },
      mode: "dictation",
      status: "completed",
      createdAt: new Date(request.createdAt).toISOString().replace(/\.\d{3}Z$/, "Z"),
      updatedAt: now,
      settings: structuredClone(this.context.getPreferences()),
      rawText: request.rawText,
      finalText: request.finalText,
      insertionText: "",
      previewText: request.finalText,
      importedSource: {
        provider: "wispr-flow",
        sourceID: request.sourceID,
        sourceStatus: request.sourceStatus,
        importedAt: now,
        variantNames: request.variantNames,
        artifactNames: this.names(incomingHashes),
        durationSeconds: request.durationSeconds,
        sourceSHA256: sourceHash,
        artifactSHA256: incomingHashes,
        unarchivedArtifactSHA256: reconciliation.unarchivedHashes,
      },
    };
    await this.writeRecord(stage.directory, record);
    await requireRegularDirectory(join(this.context.dataDirectory, "generations"));
    await rename(stage.directory, this.directory(recordID));
    await syncDirectory(join(this.context.dataDirectory, "generations"));
    await syncDirectory(this.stagingRoot);
    this.context.publish(record);
    this.index.set(request.sourceID.toLowerCase(), recordID);
    this.stages.delete(id.toUpperCase());
    const names = this.names(reconciliation.unarchivedHashes);
    return {
      outcome: names.length || reconciliation.provenancePartial ? "partial" : "imported",
      record,
      unarchivedArtifactNames: names,
    };
  }

  async cancelWisprFlowImport(id: string) {
    const key = id.toUpperCase(),
      stage = this.stages.get(key);
    if (!stage) return;
    await rm(stage.directory, { recursive: true, force: true });
    this.stages.delete(key);
  }
  async expireImportStages() {
    for (const [id, stage] of this.stages)
      if (stage.touchedAt < Date.now() - 900_000) await this.cancelWisprFlowImport(id);
  }
  async archiveWisprFlowDictionary(input: Uint8Array) {
    const data = Buffer.from(input);
    let document: unknown;
    try {
      document = parse(data);
    } catch {
      /* Return the dictionary-specific error below. */
    }
    if (
      !data.length ||
      data.length > maximumArtifactBytes ||
      !object(document) ||
      document.provider !== "wispr-flow"
    )
      throw new ServiceError(
        400,
        "invalid_dictionary_archive",
        "Dictionary source data must be valid Wispr Flow JSON within 8 MiB.",
      );
    await this.context.requireDiskSpace();
    const hash = sha256(data),
      versions = join(this.root, "dictionary-versions"),
      version = join(versions, `${hash}.json`);
    await requireRegularDirectory(this.root);
    await ensureDirectory(versions);
    if (await exists(version)) {
      if (sha256(await readRegularFile(version, maximumArtifactBytes)) !== hash)
        throw new ServiceError(
          500,
          "invalid_dictionary_archive",
          "An existing dictionary version is invalid.",
        );
    } else await atomicPrivateWrite(version, data);
    await atomicPrivateWrite(join(this.root, "dictionary.json"), data);
    return { byteCount: data.length, sha256: hash };
  }

  private directory(id: string) {
    return join(this.context.dataDirectory, "generations", id);
  }
  private stage(id: string) {
    const stage = this.stages.get(id.toUpperCase());
    if (!stage) throw new ServiceError(404, "import_not_found", "Import session not found.");
    return stage;
  }
  private names(hashes: Record<string, string>) {
    return artifactNames.filter((name) => hashes[name] !== undefined).sort();
  }
  private async writeRecord(directory: string, record: GenerationRecord) {
    const metadata = Buffer.from(JSON.stringify(record));
    if (metadata.length > maximumMetadataBytes)
      throw new ServiceError(
        413,
        "metadata_too_large",
        "The imported metadata exceeded its 1 MiB storage limit.",
      );
    await atomicPrivateWrite(join(directory, "transcript.txt"), Buffer.from(record.finalText));
    await atomicPrivateWrite(join(directory, "metadata.json"), metadata);
  }
  private async replaceDirectory(recordID: string, stageID: string, directory: string) {
    const journal = join(this.transactionsRoot, `${stageID}.json`),
      backup = join(this.transactionsRoot, `${stageID}.backup`),
      live = this.directory(recordID);
    await requireRegularDirectory(this.transactionsRoot);
    await atomicPrivateWrite(journal, encode({ recordID, stageID }));
    await rename(live, backup);
    await syncDirectory(this.transactionsRoot);
    await syncDirectory(join(this.context.dataDirectory, "generations"));
    try {
      await rename(directory, live);
    } catch (error) {
      await rename(backup, live);
      await syncDirectory(join(this.context.dataDirectory, "generations"));
      await syncDirectory(this.transactionsRoot);
      await rm(journal);
      throw error;
    }
    await syncDirectory(join(this.context.dataDirectory, "generations"));
    await syncDirectory(this.stagingRoot);
    // The replacement is committed. Cleanup failures must not make callers retry
    // a successful import; initialize will remove a remaining backup and journal.
    try {
      await rm(backup, { recursive: true });
      await rm(journal);
    } catch {
      /* Recovered on restart. */
    }
  }
}
