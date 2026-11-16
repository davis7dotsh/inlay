// The original WAV of a take: its layout, its channel result and its mono FLAC.
// The mono FLAC keeps channel 0 only (afconvert -c 1 drops the other channels), so the channel result
// records, per take, which extra channels hold audio that channel 0 does not: a channel that is
// neither a copy of channel 0 nor silent (every sample byte zero).
import { createHash } from "node:crypto";
import { open, readFile } from "node:fs/promises";
import { join } from "node:path";
import type { Sha256 } from "../../../Hub/src/record.ts";

export type WavLayout = {
  channels: number;
  sampleRate: number;
  blockAlign: number; // bytes per frame, all channels
  dataOffset: number;
  dataBytes: number;
};

/// differing: extra channels that are neither a copy of channel 0 nor silent. Empty: the mono FLAC
/// keeps all of the audio. silent: extra channels whose sample bytes are all zero.
export type ChannelResult = { channels: number; differing: number[]; silent: number[] };

/// What one streaming pass over the WAV learns: its layout, its SHA-256 and its channel result.
export type WavScan = { layout: WavLayout; sha256: Sha256; bytes: number; channels: ChannelResult };

const HEADER_READ = 64 * 1024;

/// Parse the RIFF chunks up to the data chunk. Works for PCM, float and WAVE_FORMAT_EXTENSIBLE.
export function parseWavHeader(head: Uint8Array): WavLayout {
  const b = Buffer.from(head.buffer, head.byteOffset, head.byteLength);
  if (b.toString("ascii", 0, 4) !== "RIFF" || b.toString("ascii", 8, 12) !== "WAVE")
    throw new Error("not a RIFF WAVE file");
  let fmt: Omit<WavLayout, "dataOffset" | "dataBytes"> | null = null;
  for (let at = 12; at + 8 <= b.length;) {
    const id = b.toString("ascii", at, at + 4);
    const size = b.readUInt32LE(at + 4);
    if (id === "fmt ") {
      fmt = {
        channels: b.readUInt16LE(at + 10),
        sampleRate: b.readUInt32LE(at + 12),
        blockAlign: b.readUInt16LE(at + 20),
      };
    } else if (id === "data") {
      if (!fmt) throw new Error("the data chunk comes before the fmt chunk");
      if (fmt.channels < 1 || fmt.blockAlign % fmt.channels !== 0)
        throw new Error("the fmt chunk has an odd channel layout");
      return { ...fmt, dataOffset: at + 8, dataBytes: size };
    }
    at += 8 + size + (size & 1);
  }
  throw new Error("no data chunk in the first 64 KB");
}

/// One pass over the file: hash every byte, and compare each extra channel with channel 0 byte for
/// byte, frame by frame. Stops comparing once every extra channel is known to differ and to hold sound.
export async function scanWav(path: string): Promise<WavScan> {
  const file = await open(path, "r");
  try {
    const head = new Uint8Array(HEADER_READ);
    const { bytesRead } = await file.read(head, 0, HEADER_READ, 0);
    const layout = parseWavHeader(head.subarray(0, bytesRead));
    const { channels, blockAlign, dataOffset } = layout;
    const sampleBytes = blockAlign / channels;
    const dataEnd = dataOffset + layout.dataBytes;
    const differ = Array.from({ length: channels }, () => false); // not a copy of channel 0
    const sound = Array.from({ length: channels }, () => false); // some sample byte is not zero
    let undecided = channels - 1; // extra channels not yet known to differ and hold sound

    const hash = createHash("sha256");
    // Whole frames per read, so a frame never spans two reads.
    const chunk = new Uint8Array(blockAlign * Math.max(1, Math.floor((4 << 20) / blockAlign)));
    let position = 0;
    for (;;) {
      // Stop each read at the data offset and the data end, so a read is all header, data or tail.
      const limit =
        position < dataOffset ? dataOffset : position < dataEnd ? dataEnd : Number.MAX_SAFE_INTEGER;
      let got = 0;
      const want = Math.min(chunk.length, limit - position);
      while (got < want) {
        const r = await file.read(chunk, got, want - got, position + got);
        if (r.bytesRead === 0) break;
        got += r.bytesRead;
      }
      if (got === 0) break;
      hash.update(chunk.subarray(0, got));
      if (position >= dataOffset && position < dataEnd && undecided > 0) {
        const end = got - (got % blockAlign);
        for (let f = 0; f < end && undecided > 0; f += blockAlign)
          for (let c = 1; c < channels; c++) {
            if (differ[c] && sound[c]) continue;
            const base = f + c * sampleBytes;
            for (let i = 0; i < sampleBytes; i++) {
              const byte = chunk[base + i];
              if (byte !== 0) sound[c] = true;
              if (byte !== chunk[f + i]) differ[c] = true;
            }
            if (differ[c] && sound[c]) undecided--;
          }
      }
      position += got;
    }
    return {
      layout,
      sha256: hash.digest("hex") as Sha256, // a SHA-256 hex digest by construction
      bytes: position,
      channels: {
        channels,
        differing: differ.flatMap((d, c) => (d && sound[c] ? [c] : [])),
        silent: sound.flatMap((s, c) => (c > 0 && !s ? [c] : [])),
      },
    };
  } finally {
    await file.close();
  }
}

/// afconvert's FLAC encoder writes 4608-frame blocks. For a WAV shorter than one block it writes a
/// file with no "fLaC" header and no audio, so a short WAV gets 192-frame blocks. Below 192 frames
/// afconvert writes no FLAC at all, and the take fails here.
const DEFAULT_BLOCK = 4608;
const SHORT_BLOCK = 192;

/// Convert the WAV to a mono FLAC (channel 0, same rate, 24-bit for a float source) in tempDir.
/// frames: the WAV's frame count, which picks the block size.
export async function monoFlac(wav: string, tempDir: string, frames: number): Promise<Uint8Array> {
  const out = join(tempDir, "take.flac");
  const format = frames < DEFAULT_BLOCK ? `flac#${SHORT_BLOCK}` : "flac";
  const p = Bun.spawn(["/usr/bin/afconvert", "-f", "flac", "-d", format, "-c", "1", wav, out], {
    stdout: "ignore",
    stderr: "pipe",
  });
  const err = await new Response(p.stderr).text();
  if ((await p.exited) !== 0) throw new Error(`afconvert failed: ${err.trim().slice(0, 300)}`);
  const flac = new Uint8Array(await readFile(out));
  if (Buffer.from(flac.subarray(0, 4)).toString("latin1") !== "fLaC")
    throw new Error(`afconvert wrote no FLAC for a WAV of ${frames} frames`);
  return flac;
}
