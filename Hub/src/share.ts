// The transcripts share: the only place the hub reads or writes audio and the database copies.
// Every file step first checks the share marker, and every chunk read or written checks the NAS
// window, so a request that runs into 10:57 UTC stops at its next chunk, and a bare mount point
// (the share not mounted) is never written.
import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { mkdir, open, readdir, rename, rm, stat } from "node:fs/promises";
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
  /// them back. A file that already holds these bytes is kept as it is. Returns whether it wrote.
  async putFile(relative: string, bytes: Uint8Array, sha: Sha256): Promise<{ wrote: boolean }> {
    if ((await this.hash(relative)) === sha) return { wrote: false };
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
    return { wrote: true };
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
