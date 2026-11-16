// One sync run: select every archive record without a stored confirm, or whose texts changed since
// their confirm (Transcriber processed the take again), post each one with its mono FLAC, check the
// confirm against what was sent, and store it. A hub that cannot be reached, a 503
// (the NAS window or an unmounted share), a refused pin or a refused token stops the run; the rest
// wait for the next run. A record that fails on its own is logged and tried again next run.
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stamp } from "../../../Hub/src/ids.ts";
import { sha256Hex, type RecordPost, type Sha256 } from "../../../Hub/src/record.ts";
import { readHead, readRecord, recordDirs, type ArchiveRecord } from "./archive.ts";
import { monoFlac, scanWav, type ChannelResult } from "./audio.ts";
import type { ConfirmedTexts, ConfirmStore } from "./confirms.ts";
import { HubClient, RecordRefused, StopRun, type HubTarget, type Stop } from "./hub-client.ts";

export type SyncOptions = {
  archiveRoot: string;
  store: ConfirmStore;
  target: HubTarget;
  since: string | null; // ISO time; records recorded before it are not selected
  only: string | null; // one recording ID
  dryRun: boolean;
  log: (line: Record<string, unknown>) => void;
  now?: () => Date;
};

/// resend: the record has a confirm, but its texts changed since.
export type Selected = { dir: string; recordingId: string; recordedAt: string; resend: boolean };

export type RunSummary = {
  event: "run";
  selected: number;
  confirmed: number;
  failed: number;
  left: number;
  stopped: Stop | null;
  hub: string | null;
};

/// Every record without a stored confirm or whose texts differ from it, oldest first, after --since
/// and narrowed by --only. A folder that cannot be read is reported through onError and left out.
export async function selectRecords(opts: {
  archiveRoot: string;
  confirmed: Map<string, ConfirmedTexts>;
  since: string | null;
  only: string | null;
  onError: (dir: string, error: unknown) => void;
}): Promise<Selected[]> {
  const since = stamp(opts.since);
  const only = opts.only?.toLowerCase() ?? null;
  const out: Selected[] = [];
  for (const dir of await recordDirs(opts.archiveRoot)) {
    try {
      const head = await readHead(dir);
      if (only && head.recordingId !== only) continue;
      if (since && head.recordedAt < since) continue;
      const confirmed = opts.confirmed.get(head.recordingId);
      if (confirmed) {
        const now = (await readRecord(dir)).textSha256;
        if (now.raw === confirmed.raw && now.clean === confirmed.clean) continue;
      }
      out.push({ dir, ...head, resend: confirmed !== undefined });
    } catch (error) {
      opts.onError(dir, error);
    }
  }
  return out.sort((a, b) => a.recordedAt.localeCompare(b.recordedAt));
}

type Prepared = {
  post: RecordPost;
  record: ArchiveRecord;
  flacSha: Sha256 | null;
  flacBytes: number | null;
  channels: ChannelResult | null;
};

/// Read the record and make its mono FLAC in a temp folder (never in the archive).
async function prepare(dir: string): Promise<Prepared> {
  const record = await readRecord(dir);
  if (!record.originalAudio)
    return {
      post: { ...record.post, audio: null },
      record,
      flacSha: null,
      flacBytes: null,
      channels: null,
    };
  const scan = await scanWav(record.originalAudio.path);
  if (scan.sha256 !== record.originalAudio.sha256)
    throw new Error("the original WAV does not hash to the sha256 in metadata.json");
  const temp = await mkdtemp(join(tmpdir(), "transcriber-hub-sync-"));
  try {
    const flac = await monoFlac(record.originalAudio.path, temp);
    const flacSha = sha256Hex(flac);
    return {
      record,
      flacSha,
      flacBytes: flac.length,
      channels: scan.channels,
      post: {
        ...record.post,
        audio: {
          sha256: flacSha,
          source_sha256: scan.sha256,
          source_bytes: scan.bytes,
          sample_rate: scan.layout.sampleRate,
          frame_count: Math.floor(scan.layout.dataBytes / scan.layout.blockAlign),
          flac_base64: Buffer.from(flac).toString("base64"),
        },
      },
    };
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
}

/// The fields of the hub's reply that differ from what was sent. Empty: the hub holds the record.
export function confirmMismatches(reply: unknown, p: Prepared): string[] {
  if (typeof reply !== "object" || reply === null) return ["reply"];
  const r = reply as Record<string, unknown>; // read field by field below
  const texts =
    typeof r.text_sha256 === "object" && r.text_sha256 !== null
      ? (r.text_sha256 as Record<string, unknown>)
      : {};
  const want: [string, unknown, unknown][] = [
    ["recording_id", r.recording_id, p.record.recordingId],
    ["flac_sha256", r.flac_sha256, p.flacSha],
    ["text_sha256.raw", texts.raw, p.record.textSha256.raw],
    ["text_sha256.clean", texts.clean, p.record.textSha256.clean],
  ];
  return want.filter(([, got, expected]) => got !== expected).map(([field]) => field);
}

export async function runSync(opts: SyncOptions): Promise<RunSummary> {
  const now = opts.now ?? (() => new Date());
  const selected = await selectRecords({
    archiveRoot: opts.archiveRoot,
    confirmed: opts.store.confirmedTexts(),
    since: opts.since,
    only: opts.only,
    onError: (dir, error) =>
      opts.log({ event: "record", dir, result: "unreadable", error: message(error) }),
  });
  const summary: RunSummary = {
    event: "run",
    selected: selected.length,
    confirmed: 0,
    failed: 0,
    left: selected.length,
    stopped: null,
    hub: null,
  };
  if (opts.dryRun) {
    for (const s of selected)
      opts.log({
        event: "record",
        result: "would_send",
        recording_id: s.recordingId,
        recorded_at: s.recordedAt,
        resend: s.resend,
      });
    return summary;
  }
  if (!selected.length) return summary;

  const hub = new HubClient(opts.target);
  try {
    summary.hub = await hub.connect();
    for (const s of selected) {
      const started = Date.now();
      const base = {
        event: "record",
        recording_id: s.recordingId,
        recorded_at: s.recordedAt,
        resend: s.resend,
      };
      let p: Prepared;
      try {
        p = await prepare(s.dir);
      } catch (error) {
        summary.failed++;
        summary.left--;
        opts.log({ ...base, result: "failed", stage: "prepare", error: message(error) });
        continue;
      }
      const facts = {
        flac_sha256: p.flacSha,
        flac_bytes: p.flacBytes,
        channels: p.channels?.channels ?? null,
        differing_channels: p.channels?.differing ?? null,
        silent_channels: p.channels?.silent ?? null,
        has_raw: p.record.textSha256.raw !== null,
        has_clean: p.record.textSha256.clean !== null,
      };
      try {
        const reply = await hub.post(p.post);
        const mismatches = confirmMismatches(reply, p);
        summary.left--;
        if (mismatches.length) {
          summary.failed++;
          opts.log({ ...base, ...facts, result: "failed", stage: "confirm", mismatches });
          continue;
        }
        opts.store.put({
          recording_id: p.record.recordingId,
          flac_sha256: p.flacSha,
          raw_sha256: p.record.textSha256.raw,
          clean_sha256: p.record.textSha256.clean,
          channels: p.channels,
          confirmed_at: now().toISOString(),
          hub: hub.address ?? "",
        });
        summary.confirmed++;
        opts.log({
          ...base,
          ...facts,
          result: "confirmed",
          hub: hub.address,
          ms: Date.now() - started,
        });
      } catch (error) {
        if (error instanceof RecordRefused) {
          summary.failed++;
          summary.left--;
          opts.log({
            ...base,
            ...facts,
            result: "failed",
            stage: "post",
            status: error.status,
            code: error.code,
            message: error.detail,
          });
          continue;
        }
        throw error;
      }
    }
  } catch (error) {
    if (!(error instanceof StopRun)) throw error;
    summary.stopped = error.stop;
  }
  return summary;
}

const message = (error: unknown) =>
  (error instanceof Error ? error.message : String(error)).slice(0, 300);
