import { dlopen } from "bun:ffi";
import { closeSync, constants, fstatSync, mkdirSync, openSync } from "node:fs";
import { join } from "node:path";

// Keep the same inode and advisory lock used by the Swift server. An exclusive
// create/PID file would not prevent the two implementations sharing an archive.
export function acquireDataDirectoryLock(directory: string) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const libraryPath = process.platform === "darwin" ? "/usr/lib/libSystem.B.dylib" : "libc.so.6";
  if (process.platform !== "darwin" && process.platform !== "linux") {
    throw new Error("The Inlay server supports macOS and Linux.");
  }
  const library = dlopen(libraryPath, {
    flock: { args: ["i32", "i32"], returns: "i32" },
  });
  // `bun --watch` reloads by exec in place. Close-on-exec drops the old lock so the
  // reloaded server can take it again. fs.constants does not expose O_CLOEXEC.
  const closeOnExec = process.platform === "darwin" ? 0x1000000 : 0o2000000;
  let descriptor: number | undefined;
  try {
    descriptor = openSync(
      join(directory, ".server.lock"),
      constants.O_RDWR |
        constants.O_CREAT |
        constants.O_NOFOLLOW |
        constants.O_NONBLOCK |
        closeOnExec,
      0o600,
    );
    if (!fstatSync(descriptor).isFile()) {
      throw new Error("The server data directory lock must be a regular file.");
    }
    if (library.symbols.flock(descriptor, 2 | 4) !== 0) {
      throw new Error(
        "Another Inlay server is already using this data directory, or its lock could not be acquired. Stop that runner or choose a different --data-dir.",
      );
    }
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    library.close();
    throw error;
  }

  return {
    release() {
      if (descriptor === undefined) return;
      const opened = descriptor;
      descriptor = undefined;
      // Closing the descriptor releases flock even after a process crash. Never
      // unlink .server.lock: another runner could then lock a different inode.
      closeSync(opened);
      library.close();
    },
  };
}
