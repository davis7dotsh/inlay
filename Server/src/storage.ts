import { constants } from "node:fs";
import { chmod, lstat, mkdir, open, rename, rm, statfs } from "node:fs/promises";
import { dirname, basename, join } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { ServiceError } from "./errors.ts";

export async function requireRegularDirectory(path: string) {
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink())
    throw new ServiceError(
      500,
      "invalid_storage",
      "Archive directories must be regular directories.",
    );
}

export async function ensureDirectory(path: string) {
  try {
    await mkdir(path, { mode: 0o700 });
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
  }
  await requireRegularDirectory(path);
  await chmod(path, 0o700);
}

export async function readRegularFile(path: string, maximumBytes: number) {
  await requireRegularDirectory(dirname(path));
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = await file.stat();
    if (!info.isFile() || info.size > maximumBytes)
      throw new ServiceError(
        500,
        "invalid_archive",
        "An archive artifact must be a regular file within its storage limit.",
      );
    const data = await file.readFile();
    if (data.length > maximumBytes)
      throw new ServiceError(
        500,
        "invalid_archive",
        "An archive artifact exceeded its storage limit.",
      );
    return data;
  } finally {
    await file.close();
  }
}

export async function atomicPrivateWrite(path: string, data: Uint8Array | string) {
  await requireRegularDirectory(dirname(path));
  try {
    const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink())
      throw new ServiceError(500, "invalid_storage", "An archive artifact must be a regular file.");
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error;
  }
  const temporary = join(dirname(path), `.${basename(path)}.${randomUUID()}.partial`);
  const file = await open(
    temporary,
    constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_EXCL |
      constants.O_NOFOLLOW |
      constants.O_NONBLOCK,
    0o600,
  );
  try {
    await file.writeFile(data);
    await file.sync();
    await file.close();
    await rename(temporary, path);
    // Persist the directory entry before acknowledging a durable mutation.
    await syncDirectory(dirname(path));
  } catch (error) {
    await file.close().catch(() => {});
    await rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
}

export async function syncDirectory(path: string) {
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

export const sha256 = (data: Uint8Array | string) =>
  createHash("sha256").update(data).digest("hex");

export async function freeBytes(dataDirectory: string) {
  const disk = await statfs(dataDirectory, { bigint: true });
  return disk.bavail * disk.bsize;
}

export async function requireDiskSpaceFor(dataDirectory: string, additionalBytes: number) {
  if ((await freeBytes(dataDirectory)) < 100n * 1024n * 1024n + BigInt(Math.ceil(additionalBytes)))
    throw new ServiceError(
      507,
      "storage_full",
      "The server needs more free disk space before accepting audio.",
    );
}

export async function requireDiskSpace(dataDirectory: string) {
  return requireDiskSpaceFor(dataDirectory, 0);
}
