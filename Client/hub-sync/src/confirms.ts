// The confirms the hub sent back, in a local SQLite file. A record is skipped by the next run only
// when its confirm is stored here and its texts still hash to the confirmed texts. Checkpoint 6 (the local delete) reconfirms from these rows.
import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { Sha256 } from "../../../Hub/src/record.ts";
import type { ChannelResult } from "./audio.ts";

export type StoredConfirm = {
  recording_id: string;
  flac_sha256: Sha256 | null;
  raw_sha256: Sha256 | null;
  clean_sha256: Sha256 | null;
  channels: ChannelResult | null; // null for a take with no audio
  confirmed_at: string;
  hub: string;
};

export type ConfirmedTexts = { raw: Sha256 | null; clean: Sha256 | null };

export class ConfirmStore {
  private readonly db: Database;

  constructor(path: string) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA busy_timeout = 10000");
    this.db.exec(`CREATE TABLE IF NOT EXISTS confirms (
      recording_id       TEXT PRIMARY KEY,  -- lowercase archive UUID
      flac_sha256        TEXT,              -- null for a take with no audio
      raw_sha256         TEXT,              -- SHA-256 of raw.txt as stored, null when not sent
      clean_sha256       TEXT,
      channels           INTEGER,           -- channel count of the original WAV
      differing_channels TEXT,              -- JSON list of extra channels with audio channel 0 lacks
      silent_channels    TEXT,              -- JSON list of extra channels that are all zero
      confirmed_at       TEXT NOT NULL,
      hub                TEXT NOT NULL      -- the address that confirmed
    )`);
  }

  /// The text hashes of every stored confirm, by recording ID.
  confirmedTexts(): Map<string, ConfirmedTexts> {
    return new Map(
      this.db
        .query<
          { recording_id: string; raw_sha256: Sha256 | null; clean_sha256: Sha256 | null },
          []
        >("select recording_id, raw_sha256, clean_sha256 from confirms")
        .all()
        .map((r) => [r.recording_id, { raw: r.raw_sha256, clean: r.clean_sha256 }]),
    );
  }

  put(c: StoredConfirm) {
    this.db
      .query(
        "insert or replace into confirms(recording_id, flac_sha256, raw_sha256, clean_sha256, channels," +
          " differing_channels, silent_channels, confirmed_at, hub) values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        c.recording_id,
        c.flac_sha256,
        c.raw_sha256,
        c.clean_sha256,
        c.channels?.channels ?? null,
        c.channels ? JSON.stringify(c.channels.differing) : null,
        c.channels ? JSON.stringify(c.channels.silent) : null,
        c.confirmed_at,
        c.hub,
      );
  }

  close() {
    this.db.close();
  }
}
