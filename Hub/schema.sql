-- Transcripts database on services-01. Safe to rerun: every statement uses IF NOT EXISTS.
-- Design: Transcripts slice of the Session "Transcripts on the NAS" (tables, keys, and search).
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- One row per device and owner period.
CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT NOT NULL,
  name      TEXT NOT NULL,
  owner     TEXT NOT NULL,
  "from"    TEXT NOT NULL,          -- ISO date. The first row starts before the oldest record.
  "to"      TEXT,                   -- empty while the owner keeps the device
  PRIMARY KEY (device_id, "from")
);

-- One row per stored mono FLAC on the transcripts share.
CREATE TABLE IF NOT EXISTS audio (
  sha256        TEXT PRIMARY KEY,   -- SHA-256 of the FLAC bytes, also its file name
  source_sha256 TEXT NOT NULL,      -- SHA-256 of the original WAV
  bytes         INTEGER NOT NULL,
  source_bytes  INTEGER,
  sample_rate   INTEGER,
  frame_count   INTEGER,
  nas_path      TEXT NOT NULL
);

-- One row per take. No text.
CREATE TABLE IF NOT EXISTS recordings (
  recording_id     TEXT PRIMARY KEY, -- lowercase archive UUID, or the Wispr Flow key
  recorded_at      TEXT,
  device_id        TEXT NOT NULL,
  mode             TEXT,
  status           TEXT NOT NULL,
  language         TEXT,
  app              TEXT,
  duration_seconds REAL,
  audio_sha256     TEXT REFERENCES audio(sha256)
);

-- Raw text that one provider and model made from one recording.
CREATE TABLE IF NOT EXISTS transcriptions (
  transcription_id   TEXT PRIMARY KEY, -- UUIDv5 of recording_id, provider, model, created_at
  recording_id       TEXT NOT NULL REFERENCES recordings(recording_id),
  provider           TEXT NOT NULL,
  model              TEXT NOT NULL,
  model_version      TEXT,
  settings           TEXT NOT NULL DEFAULT '{}', -- JSON
  created_at         TEXT,
  processing_seconds REAL,
  detected_language  TEXT,
  text               TEXT NOT NULL,
  words              TEXT,                       -- JSON
  UNIQUE (recording_id, provider, model, created_at)
);

-- Cleaned text that one model made from one transcription. At most 1 per transcription.
CREATE TABLE IF NOT EXISTS cleanups (
  cleanup_id       TEXT PRIMARY KEY, -- UUIDv5 of transcription_id
  transcription_id TEXT NOT NULL UNIQUE REFERENCES transcriptions(transcription_id),
  recording_id     TEXT NOT NULL REFERENCES recordings(recording_id),
  engine           TEXT NOT NULL,
  engine_version   TEXT,
  model            TEXT NOT NULL,
  model_sha256     TEXT,
  prompt_sha256    TEXT,
  created_at       TEXT,
  status           TEXT,
  text             TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS transcriptions_recording ON transcriptions(recording_id);
CREATE INDEX IF NOT EXISTS cleanups_recording ON cleanups(recording_id);

-- Keyword search over the cleaned text. The tokenizer keeps apostrophes inside words ("it's" stays one token).
CREATE VIRTUAL TABLE IF NOT EXISTS cleanups_fts USING fts5(
  text, content = 'cleanups', content_rowid = 'rowid',
  tokenize = "unicode61 tokenchars '''’'"
);
CREATE TRIGGER IF NOT EXISTS cleanups_ai AFTER INSERT ON cleanups BEGIN
  INSERT INTO cleanups_fts(rowid, text) VALUES (new.rowid, new.text);
END;
CREATE TRIGGER IF NOT EXISTS cleanups_ad AFTER DELETE ON cleanups BEGIN
  INSERT INTO cleanups_fts(cleanups_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
END;
CREATE TRIGGER IF NOT EXISTS cleanups_au AFTER UPDATE OF text ON cleanups BEGIN
  INSERT INTO cleanups_fts(cleanups_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
  INSERT INTO cleanups_fts(rowid, text) VALUES (new.rowid, new.text);
END;
