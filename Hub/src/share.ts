// The transcripts share: the only place the hub reads or writes audio and the database copies.
// Every file step first checks the share marker, and every chunk read or written checks the NAS
// window, so a request that runs into 10:57 UTC stops at its next chunk, and a bare mount point
// (the share not mounted) is never written.
import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import {
  lstat,
  mkdir,
  open,
  readdir,
  realpath,
  rename,
  rm,
  stat,
  type FileHandle,
} from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { HttpError } from "./errors.ts";
import { artifactPath, type Sha256 } from "./record.ts";

/// The NAS window: the daily NAS job (11:15 UTC) owns the NAS from 10:57 until 12:00 UTC.
const WINDOW_START = 10 * 60 + 57;
const WINDOW_END = 12 * 60;

export type Clock = () => Date;

/// Seconds until the window ends, or 0 when the window is open.
export function windowWait(now: Date): number {
  const minute = now.getUTCHours() * 60 + now.getUTCMinutes();
  if (minute < WINDOW_START || minute >= WINDOW_END) return 0;
  const end = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 12);
  return Math.max(1, Math.ceil((end - now.getTime()) / 1000));
}

export function assertWindowOpen(now: Date) {
  const wait = windowWait(now);
  if (wait > 0)
    throw new HttpError(503, "nas_window", "the NAS is busy from 10:57 to 12:00 UTC", {
      "Retry-After": String(wait),
    });
}

/// A file at the share root that exists only on the mounted share, never in the bare mount point.
export const SHARE_MARKER = ".transcriber-hub-share";

const CHUNK = 1 << 20;
/// A temp file older than this belongs to no live upload (a post times out long before).
const STALE_PARTIAL_MS = 60 * 60 * 1000;
/// A temp file: .<final name>.<12 hex>.partial, such as .<sha>.flac.0123456789ab.partial
const PARTIAL = /^\.[A-Za-z0-9][A-Za-z0-9._-]*\.[0-9a-f]{12}\.partial$/;

/// Whether a path holds anything: a file, a folder or a link. Any error but "no entry" throws.
async function exists(path: string): Promise<boolean> {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") return false;
    throw error;
  }
}

export class Share {
  /// The temp files this process is writing now. removeStalePartials never removes them, so an
  /// upload that stalls for over an hour keeps its own partial. One hub process writes the share.
  private readonly activePartials = new Set<string>();

  constructor(
    private readonly root: string,
    private readonly clock: Clock,
  ) {}

  private async guard() {
    assertWindowOpen(this.clock());
    try {
      await stat(join(this.root, SHARE_MARKER));
    } catch {
      throw new HttpError(503, "share_unavailable", "the transcripts share is not mounted");
    }
    // The marker check awaited, so the window can have started since the first check. The open() or
    // rename() that follows a guard runs right after this one.
    assertWindowOpen(this.clock());
  }

  /// SHA-256 of the file at a share path, or null when there is no file.
  async hash(relative: string): Promise<Sha256 | null> {
    await this.guard();
    let file;
    try {
      file = await open(join(this.root, relative), constants.O_RDONLY | constants.O_NOFOLLOW);
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "ENOENT") return null;
      throw error;
    }
    try {
      const h = createHash("sha256");
      const buffer = new Uint8Array(CHUNK);
      for (;;) {
        assertWindowOpen(this.clock());
        const { bytesRead } = await file.read(buffer, 0, buffer.length, null);
        if (bytesRead === 0) break;
        h.update(buffer.subarray(0, bytesRead));
      }
      return h.digest("hex") as Sha256;
    } finally {
      await file.close();
    }
  }

  /// Put the FLAC at artifacts/<2 hex>/<sha>.flac. Returns whether it wrote.
  putFlac(sha: Sha256, flac: Uint8Array): Promise<{ wrote: boolean }> {
    return this.putFile(artifactPath(sha), flac, sha);
  }

  /// Put bytes whose SHA-256 is sha at a share path through a temp file and a rename, then read
  /// them back. A file that already holds these bytes is kept as it is, and a file that holds
  /// other bytes is replaced. Returns whether it wrote.
  async putFile(relative: string, bytes: Uint8Array, sha: Sha256): Promise<{ wrote: boolean }> {
    if ((await this.hash(relative)) === sha) return { wrote: false };
    await this.write(relative, bytes, sha, "replace");
    return { wrote: true };
  }

  /// Put bytes whose SHA-256 is sha at a share path that holds no file, through a temp file and a
  /// rename, then read them back. Throws when the path holds a file: it never replaces one.
  async putNewFile(relative: string, bytes: Uint8Array, sha: Sha256) {
    await this.write(relative, bytes, sha, "new");
  }

  /// Move the file at a share path to a share path that holds no file. Throws when the target
  /// holds a file: it never replaces one.
  async move(from: string, to: string) {
    const target = join(this.root, to);
    await this.guard();
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    await this.guard();
    if (await exists(target)) throw new Error(`${to} holds a file. Nothing is moved`);
    await this.guard();
    await rename(join(this.root, from), target);
  }

  private async write(relative: string, bytes: Uint8Array, sha: Sha256, mode: "replace" | "new") {
    const final = join(this.root, relative);
    await this.guard();
    await mkdir(dirname(final), { recursive: true, mode: 0o700 });
    await this.removeStalePartials(dirname(final));
    // A temp name that a stopped write leaves behind is recognizable: .<name>.<random>.partial
    const temp = join(
      dirname(final),
      `.${basename(final)}.${randomBytes(6).toString("hex")}.partial`,
    );
    await this.guard();
    this.activePartials.add(temp);
    try {
      const file = await open(temp, "wx", 0o600);
      try {
        for (let at = 0; at < bytes.length;) {
          assertWindowOpen(this.clock());
          at += (await file.write(bytes, at, Math.min(CHUNK, bytes.length - at))).bytesWritten;
        }
        assertWindowOpen(this.clock());
        await file.sync();
      } finally {
        await file.close();
      }
      await this.guard();
      if (mode === "new" && (await exists(final)))
        throw new Error(`${relative} holds a file. Nothing is written`);
      await rename(temp, final);
    } catch (error) {
      // Outside the NAS window, remove the temp file now. Inside it, the next upload to this
      // folder after the window removes it (removeStalePartials).
      if (windowWait(this.clock()) === 0) await rm(temp, { force: true }).catch(() => {});
      throw error;
    } finally {
      this.activePartials.delete(temp);
    }
    const back = await this.hash(relative);
    if (back !== sha) {
      await this.guard();
      await rm(final, { force: true });
      throw new HttpError(
        502,
        "readback_mismatch",
        `the file read back from ${relative} holds other bytes`,
      );
    }
  }

  /// The names in a share folder, or [] when there is no folder.
  async list(folder: string): Promise<string[]> {
    await this.guard();
    try {
      return await readdir(join(this.root, folder));
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "ENOENT") return [];
      throw error;
    }
  }

  /// The bytes of the file at a share path, read in chunks that each check the NAS window.
  async read(relative: string): Promise<Uint8Array> {
    await this.guard();
    const file = await open(join(this.root, relative), constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const chunks: Uint8Array[] = [];
      for (;;) {
        assertWindowOpen(this.clock());
        const buffer = new Uint8Array(CHUNK);
        const { bytesRead } = await file.read(buffer, 0, CHUNK, null);
        if (bytesRead === 0) break;
        chunks.push(buffer.subarray(0, bytesRead));
      }
      return Buffer.concat(chunks);
    } finally {
      await file.close();
    }
  }

  async remove(relative: string) {
    await this.guard();
    await rm(join(this.root, relative), { force: true });
  }

  /// Remove temp files older than an hour in one artifacts folder: what a failed or stopped upload
  /// left. A temp file that this process is writing now is never touched, however old.
  private async removeStalePartials(folder: string) {
    await this.guard();
    const now = this.clock().getTime();
    for (const name of await readdir(folder)) {
      if (!PARTIAL.test(name)) continue;
      const path = join(folder, name);
      if (this.activePartials.has(path)) continue;
      await this.guard();
      const info = await stat(path).catch(() => null);
      if (!info || now - info.mtimeMs <= STALE_PARTIAL_MS) continue;
      await this.guard();
      await rm(path, { force: true });
    }
  }
}

/// One FLAC under artifacts/, open for reading only, and its size.
export type OpenArtifact = { file: FileHandle; size: number };

/// Read-only access to the FLACs under artifacts/ for the viewer. It has no write step. Every step
/// checks the share marker and the NAS window, and every chunk read checks the window again, so a
/// stream that runs into 10:57 UTC stops at its next chunk. It never follows a link: the file opens
/// with O_NOFOLLOW, no folder on the way may be a link, and the real path must lie in artifacts/.
/// It opens with O_NONBLOCK and serves only a regular file, so a FIFO never blocks the open.
export class ArtifactReader {
  constructor(
    private readonly root: string,
    private readonly clock: Clock,
  ) {}

  private async guard() {
    assertWindowOpen(this.clock());
    try {
      await stat(join(this.root, SHARE_MARKER));
    } catch {
      throw new HttpError(503, "share_unavailable", "the transcripts share is not mounted");
    }
    assertWindowOpen(this.clock());
  }

  /// Open artifacts/<2 hex>/<sha>.flac, or null when there is no file. The caller closes it.
  async open(sha: Sha256): Promise<OpenArtifact | null> {
    const artifacts = join(this.root, "artifacts");
    const relative = artifactPath(sha);
    const path = join(this.root, relative);
    const refuse = () =>
      new HttpError(403, "link_refused", "the audio path is a link or leaves artifacts/");
    await this.guard();
    let file: FileHandle;
    try {
      // O_NONBLOCK: a FIFO or a device opens at once, and the regular-file check below refuses it.
      // A blocked open would hold a filesystem worker that the client sync routes also need.
      file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    } catch (error) {
      if (error instanceof Error && "code" in error) {
        if (error.code === "ENOENT") return null;
        if (error.code === "ELOOP" || error.code === "ENXIO" || error.code === "EOPNOTSUPP")
          throw refuse();
      }
      throw error;
    }
    try {
      const info = await file.stat();
      if (!info.isFile())
        throw new HttpError(403, "not_a_file", "the audio path is not a regular file");
      for (const folder of [artifacts, dirname(path)]) {
        await this.guard();
        if (!(await lstat(folder)).isDirectory()) throw refuse();
      }
      await this.guard();
      const real = await realpath(path);
      if (real !== join(await realpath(artifacts), relative.slice("artifacts/".length)))
        throw refuse();
      const same = await stat(real);
      if (same.dev !== info.dev || same.ino !== info.ino) throw refuse();
      return { file, size: info.size };
    } catch (error) {
      await file.close();
      throw error;
    }
  }

  /// The bytes start to end (both included) of an open artifact, read in chunks of at most 1 MiB
  /// that each check the NAS window. The stream closes the file when it ends, fails or is cancelled.
  stream({ file }: OpenArtifact, start: number, end: number): ReadableStream<Uint8Array> {
    let at = start;
    let closed = false;
    const close = async () => {
      if (closed) return;
      closed = true;
      await file.close().catch(() => {});
    };
    return new ReadableStream<Uint8Array>({
      pull: async (controller) => {
        try {
          if (at > end) {
            await close();
            controller.close();
            return;
          }
          assertWindowOpen(this.clock());
          const want = Math.min(CHUNK, end - at + 1);
          const buffer = new Uint8Array(want);
          const { bytesRead } = await file.read(buffer, 0, want, at);
          if (bytesRead === 0) throw new Error("the file ended before the range");
          at += bytesRead;
          controller.enqueue(buffer.subarray(0, bytesRead));
        } catch (error) {
          await close();
          controller.error(error);
        }
      },
      cancel: close,
    });
  }
}
