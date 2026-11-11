import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { MAXIMUM_CHUNK_BYTES, type AudioKind, type AudioStreamFormat } from "./api.ts";
import { atomicPrivateWrite, readRegularFile } from "./storage.ts";

export interface Upload {
  format: AudioStreamFormat;
  chunks: { offset: number; count: number }[];
  bytes: number;
}
type Uploads = Partial<Record<AudioKind, Upload>>;
const magic = "INLAYU01";
const headerBytes = 16;
const receiptBytes = 8;
const maximumChunks = 1_000_000;
const missing = (error: unknown) =>
  error instanceof Error && "code" in error && error.code === "ENOENT";
const journalPath = (directory: string, kind: AudioKind) => join(directory, `${kind}.uploads`);

function header(format: AudioStreamFormat) {
  const bytes = Buffer.alloc(headerBytes);
  bytes.write(magic);
  bytes.writeUInt32LE(format.sampleRate, 8);
  bytes.writeUInt32LE(format.channels, 12);
  return bytes;
}
function receipt(count: number) {
  const bytes = Buffer.alloc(receiptBytes);
  bytes.writeUInt32LE(count);
  bytes.writeUInt32LE(~count >>> 0, 4);
  return bytes;
}

/** Raw PCM must be synced first. Publish the in-memory cursor only after this
 * receipt is synced. On a failed append, the next attempt truncates any suffix
 * beyond that cursor before retrying; no acknowledged receipt is discarded.
 */
export async function appendUploadReceipt(
  directory: string,
  kind: AudioKind,
  upload: Upload,
  count: number,
) {
  const path = journalPath(directory, kind);
  const position = headerBytes + upload.chunks.length * receiptBytes;
  const writeSnapshot = () => {
    const bytes = Buffer.alloc(position + receiptBytes);
    header(upload.format).copy(bytes);
    for (const [index, chunk] of upload.chunks.entries()) {
      const offset = headerBytes + index * receiptBytes;
      bytes.writeUInt32LE(chunk.count, offset);
      bytes.writeUInt32LE(~chunk.count >>> 0, offset + 4);
    }
    receipt(count).copy(bytes, position);
    return atomicPrivateWrite(path, bytes);
  };
  // The first receipt, or the one-time migration of a legacy uploads.json,
  // persists the new directory entry atomically. Later appends are constant size.
  if (!upload.chunks.length) return writeSnapshot();
  let file;
  try {
    file = await open(path, constants.O_RDWR | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (error) {
    if (missing(error)) return writeSnapshot();
    throw error;
  }
  try {
    const info = await file.stat();
    if (!info.isFile() || info.size < position)
      throw new Error("Acknowledged upload receipts are missing.");
    if (info.size > position) await file.truncate(position);
    const bytes = receipt(count);
    let written = 0;
    while (written < bytes.length) {
      const result = await file.write(bytes, written, bytes.length - written, position + written);
      if (!result.bytesWritten) throw new Error("Upload receipt write failed.");
      written += result.bytesWritten;
    }
    await file.sync();
  } finally {
    await file.close();
  }
}

/** Read old whole-file journals and new per-stream append logs. A migrated
 * stream's log supersedes its legacy entry; the legacy file is left intact.
 */
export async function recoverUploads(directory: string): Promise<Uploads> {
  let streams: Uploads = {};
  try {
    const raw: unknown = JSON.parse(
      (await readRegularFile(join(directory, "uploads.json"), 32 * 1_048_576)).toString(),
    );
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
      throw new Error("Invalid upload journal.");
    streams = raw as Uploads;
  } catch (error) {
    if (!missing(error)) throw error;
  }
  for (const kind of ["inference", "original"] as const) {
    const path = journalPath(directory, kind);
    let bytes: Buffer;
    try {
      bytes = await readRegularFile(path, headerBytes + maximumChunks * receiptBytes + 7);
    } catch (error) {
      if (missing(error)) continue;
      throw error;
    }
    if (bytes.length < headerBytes || bytes.toString("ascii", 0, 8) !== magic)
      throw new Error("Invalid upload receipt header.");
    const upload: Upload = {
      format: { sampleRate: bytes.readUInt32LE(8), channels: bytes.readUInt32LE(12) },
      bytes: 0,
      chunks: [],
    };
    let position = headerBytes;
    while (position + receiptBytes <= bytes.length) {
      const count = bytes.readUInt32LE(position);
      if (bytes.readUInt32LE(position + 4) !== ~count >>> 0) {
        // A crash can tear only the final append. Interior corruption must
        // never silently erase later acknowledged receipts.
        if (position + receiptBytes !== bytes.length)
          throw new Error("Invalid interior upload receipt.");
        break;
      }
      upload.chunks.push({ offset: upload.bytes, count });
      upload.bytes += count;
      position += receiptBytes;
    }
    if (position !== bytes.length) {
      const file = await open(path, constants.O_RDWR | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        if (!(await file.stat()).isFile()) throw new Error("Invalid upload receipt file.");
        await file.truncate(position);
        await file.sync();
      } finally {
        await file.close();
      }
    }
    streams[kind] = upload;
  }
  for (const [kind, upload] of Object.entries(streams)) {
    if (
      !["inference", "original"].includes(kind) ||
      !upload ||
      !upload.format ||
      !Array.isArray(upload.chunks) ||
      upload.chunks.length > maximumChunks ||
      !Number.isSafeInteger(upload.bytes) ||
      upload.bytes < 0 ||
      upload.bytes > 0xffff_ff00 ||
      !Number.isInteger(upload.format.sampleRate) ||
      upload.format.sampleRate < 8_000 ||
      upload.format.sampleRate > 192_000 ||
      !Number.isInteger(upload.format.channels) ||
      upload.format.channels < 1 ||
      upload.format.channels > 8 ||
      (kind === "inference" &&
        (upload.format.sampleRate !== 16_000 || upload.format.channels !== 1))
    )
      throw new Error("Invalid durable upload format.");
    let offset = 0;
    for (const chunk of upload.chunks) {
      if (
        !chunk ||
        chunk.offset !== offset ||
        !Number.isSafeInteger(chunk.count) ||
        chunk.count <= 0 ||
        chunk.count > MAXIMUM_CHUNK_BYTES ||
        chunk.count % (upload.format.channels * 4)
      )
        throw new Error("Invalid durable upload sequence.");
      offset += chunk.count;
    }
    if (offset !== upload.bytes) throw new Error("Invalid durable upload length.");
    const file = await open(
      join(directory, `${kind}.raw`),
      constants.O_RDWR | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    try {
      const info = await file.stat();
      if (!info.isFile() || info.size < upload.bytes)
        throw new Error("Acknowledged audio is missing.");
      if (info.size > upload.bytes) {
        await file.truncate(upload.bytes);
        await file.sync();
      }
    } finally {
      await file.close();
    }
  }
  return streams;
}
