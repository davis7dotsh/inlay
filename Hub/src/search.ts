// Keyword search over the cleaned text: reciprocal rank fusion (k = 60) of the top 20 FTS5 BM25 hits
// and the top 20 exact-phrase hits, each mapped to recording_id. A port of check.py fts_query,
// phrase_query, search and rrf (transcripts-nas/import), the method the search spike measured.
import type { Database } from "bun:sqlite";

const FUSE_DEPTH = 20;
const TOPN = 100;
const K = 60;
// The words the cleanups_fts tokenizer (unicode61, apostrophes as token characters) makes: letters
// and digits in every script. "_" separates words there, so it does here. NFC keeps a decomposed
// accented letter in its word.
const TOKEN = /[\p{L}\p{N}'’]+/gu;

const tokens = (q: string) => q.normalize("NFC").toLowerCase().match(TOKEN) ?? [];

export const ftsQuery = (q: string) =>
  tokens(q)
    .map((t) => `"${t}"`)
    .join(" OR ");

export function phraseQuery(q: string): string | null {
  const toks = tokens(q);
  return toks.length ? `"${toks.join(" ").replaceAll('"', "")}"` : null;
}

function ranked(db: Database, match: string | null): string[] {
  if (!match) return [];
  const rows = db
    .query<{ recording_id: string }, [string, number]>(
      "select c.recording_id from cleanups_fts f join cleanups c on c.rowid = f.rowid" +
        " where cleanups_fts match ? order by f.rank limit ?",
    )
    .all(match, TOPN);
  return [...new Set(rows.map((r) => r.recording_id))];
}

export function rrf(...lists: string[][]): { recording_id: string; score: number }[] {
  const score = new Map<string, number>();
  for (const list of lists)
    list.forEach((id, rank) => score.set(id, (score.get(id) ?? 0) + 1 / (K + rank + 1)));
  return [...score]
    .sort((a, b) => b[1] - a[1])
    .map(([recording_id, s]) => ({ recording_id, score: s }));
}

export function search(db: Database, q: string) {
  const fused = rrf(
    ranked(db, phraseQuery(q)).slice(0, FUSE_DEPTH),
    ranked(db, ftsQuery(q) || null).slice(0, FUSE_DEPTH),
  ).slice(0, FUSE_DEPTH);
  const at = db.query<{ recorded_at: string | null }, [string]>(
    "select recorded_at from recordings where recording_id = ?",
  );
  return fused.map((hit) => ({
    ...hit,
    recorded_at: at.get(hit.recording_id)?.recorded_at ?? null,
  }));
}
