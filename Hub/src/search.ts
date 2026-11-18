// Keyword search over the cleaned text: reciprocal rank fusion (k = 60) of the top 20 FTS5 BM25 hits
// and the top 20 exact-phrase hits, each mapped to recording_id. A port of check.py fts_query,
// phrase_query, search and rrf (transcripts-nas/import), the method the search spike measured.
// The viewer passes a filter on the recordings (alias r), which runs inside both ranked lists, so
// the filter applies before the top 20 cut. With no filter, the queries are the /v1/search ones.
import type { Database, SQLQueryBindings } from "bun:sqlite";

const FUSE_DEPTH = 20;
const TOPN = 100;
const K = 60;
// The words the cleanups_fts tokenizer (unicode61, apostrophes as token characters) makes: letters
// and digits in every script. "_" separates words there, so it does here. NFC keeps a decomposed
// accented letter in its word.
const TOKEN = /[\p{L}\p{N}'’]+/gu;

export const tokens = (q: string) => q.normalize("NFC").toLowerCase().match(TOKEN) ?? [];

export const ftsQuery = (q: string) =>
  tokens(q)
    .map((t) => `"${t}"`)
    .join(" OR ");

export function phraseQuery(q: string): string | null {
  const toks = tokens(q);
  return toks.length ? `"${toks.join(" ").replaceAll('"', "")}"` : null;
}

/// A condition on the recordings table under the alias r, with its ? parameters in order.
export type RecordingFilter = { where: string; args: SQLQueryBindings[] };

function ranked(db: Database, match: string | null, filter?: RecordingFilter): string[] {
  if (!match) return [];
  const rows = filter
    ? db
        .query<{ recording_id: string }, SQLQueryBindings[]>(
          "select c.recording_id from cleanups_fts f join cleanups c on c.rowid = f.rowid" +
            " join recordings r on r.recording_id = c.recording_id" +
            ` where cleanups_fts match ? and (${filter.where}) order by f.rank limit ?`,
        )
        .all(match, ...filter.args, TOPN)
    : db
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

export function search(db: Database, q: string, filter?: RecordingFilter) {
  const fused = rrf(
    ranked(db, phraseQuery(q), filter).slice(0, FUSE_DEPTH),
    ranked(db, ftsQuery(q) || null, filter).slice(0, FUSE_DEPTH),
  ).slice(0, FUSE_DEPTH);
  const at = db.query<{ recorded_at: string | null }, [string]>(
    "select recorded_at from recordings where recording_id = ?",
  );
  return fused.map((hit) => ({
    ...hit,
    recorded_at: at.get(hit.recording_id)?.recorded_at ?? null,
  }));
}

/// The number of words in a text: the words the search index makes (TOKEN).
/// It counts matches one at a time, so it never builds an array of every word.
export function wordCount(text: string): number {
  const word = new RegExp(TOKEN);
  const body = text.normalize("NFC");
  let n = 0;
  while (word.exec(body)) n++;
  return n;
}

const WORD_CHAR = "[\\p{L}\\p{N}'’]";
const SNIPPET_BEFORE = 60;
const SNIPPET_LENGTH = 220;

/// A short part of a text around the first query word, with the place of each query word in it as
/// UTF-16 offsets [start, end). The page builds a mark element for each; it never parses HTML.
export function snippet(text: string, q: string): { text: string; marks: [number, number][] } {
  const body = text.normalize("NFC");
  const words = [...new Set(tokens(q))].map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (!words.length) return { text: body.slice(0, SNIPPET_LENGTH), marks: [] };
  const source = `(?<!${WORD_CHAR})(?:${words.join("|")})(?!${WORD_CHAR})`;
  // Two RegExps: the first has no g flag, so it keeps no lastIndex for matchAll to start from.
  const first = new RegExp(source, "iu").exec(body);
  const start = first ? Math.max(0, first.index - SNIPPET_BEFORE) : 0;
  const part = body.slice(start, start + SNIPPET_LENGTH);
  const marks: [number, number][] = [];
  for (const m of part.matchAll(new RegExp(source, "giu")))
    marks.push([m.index, m.index + m[0].length]);
  return { text: part, marks };
}
