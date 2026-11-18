// The numbers of the viewer's Insights tab, read from the transcripts database. Each number carries
// the formula that made it, and the page shows that formula.
//   A take's words: the words (search.ts wordCount) of its newest cleanup, or of its newest raw
//   transcription when it has no cleanup.
//   Words per minute: the words of the cleaned takes longer than 2 s, divided by their recorded
//   minutes. A take with no cleanup or no duration is left out.
// It reads the recordings in slices of SLICE rows by rowid, one row at a time, and yields to the
// event loop between slices. So it never holds the whole archive in memory, and the client sync
// listener of the same process never waits for more than one slice.
import type { Database } from "bun:sqlite";
import { wordCount } from "./search.ts";

/// Takes this short or shorter are left out of words per minute: a start-and-stop is no speech.
const MIN_SECONDS = 2;

/// Names for the app bundle IDs that hold most takes. Any other app shows its bundle ID.
const APP_NAMES = new Map<string, string>([
  ["com.todesktop.230313mzl4w4u92", "Cursor"],
  ["com.google.Chrome", "Chrome"],
  ["com.anthropic.claudefordesktop", "Claude"],
  ["com.t3tools.t3code", "T3 Code"],
  ["notion.id", "Notion"],
  ["notion.mail.id", "Notion Mail"],
  ["com.cmuxterm.app", "cmux"],
  ["com.openai.chat", "ChatGPT"],
  ["com.openai.codex", "Codex"],
  ["com.pvncher.repoprompt", "Repo Prompt"],
  ["com.tinyspeck.slackmacgap", "Slack"],
  ["com.apple.Terminal", "Terminal"],
  ["com.apple.MobileSMS", "Messages"],
  ["dev.warp.Warp-Stable", "Warp"],
  ["ai.perplexity.mac", "Perplexity"],
  ["com.hnc.Discord", "Discord"],
  ["com.granola.app", "Granola"],
  ["com.apple.finder", "Finder"],
  ["com.electron.wispr-flow", "Wispr Flow"],
  ["com.mitchellh.ghostty", "Ghostty"],
  ["us.zoom.xos", "Zoom"],
]);

export type AppRow = { app: string | null; name: string; takes: number; words: number };

export type Insights = {
  words_per_minute: { value: number | null; words: number; seconds: number; formula: string };
  total_words: { value: number; formula: string };
  takes: { value: number; days: number; formula: string };
  apps: { rows: AppRow[]; formula: string };
};

/// The rows of one slice: rowids after a given one, in rowid order.
const SLICE = 1000;

type TakeRow = {
  id: number;
  app: string | null;
  day: string | null;
  seconds: number | null;
  /// 1 when the take has a cleanup: then text is its newest cleanup, else its newest raw text.
  cleaned: number;
  text: string | null;
};

const nextTick = () => new Promise<void>((resolve) => setImmediate(resolve));

export async function insights(db: Database): Promise<Insights> {
  // coalesce reads the raw text only when there is no cleanup.
  const slice = db.query<TakeRow, [number, number]>(
    "select r.rowid as id, nullif(r.app, '') as app, substr(r.recorded_at, 1, 10) as day," +
      " r.duration_seconds as seconds," +
      " exists (select 1 from cleanups c where c.recording_id = r.recording_id) as cleaned," +
      " coalesce((select c.text from cleanups c where c.recording_id = r.recording_id" +
      "   order by c.created_at desc, c.rowid desc limit 1)," +
      "  (select t.text from transcriptions t where t.recording_id = r.recording_id" +
      "   order by t.created_at desc, t.rowid desc limit 1)) as text" +
      " from recordings r where r.rowid > ? order by r.rowid limit ?",
  );
  let takes = 0;
  let totalWords = 0;
  let wpmWords = 0;
  let wpmSeconds = 0;
  const days = new Set<string>();
  const apps = new Map<string | null, { takes: number; words: number }>();
  let after = -Infinity;
  for (;;) {
    let rows = 0;
    for (const row of slice.iterate(after, SLICE)) {
      rows++;
      after = row.id;
      takes++;
      const words = row.text === null ? 0 : wordCount(row.text);
      totalWords += words;
      if (row.cleaned === 1 && row.seconds !== null && row.seconds > MIN_SECONDS) {
        wpmWords += words;
        wpmSeconds += row.seconds;
      }
      if (row.day) days.add(row.day);
      const app = apps.get(row.app) ?? { takes: 0, words: 0 };
      app.takes++;
      app.words += words;
      apps.set(row.app, app);
    }
    if (rows < SLICE) break;
    await nextTick();
  }
  return {
    words_per_minute: {
      value: wpmSeconds > 0 ? Math.round((wpmWords / wpmSeconds) * 60) : null,
      words: wpmWords,
      seconds: Math.round(wpmSeconds),
      formula: `cleaned words ÷ recorded minutes, takes over ${MIN_SECONDS} s with a cleanup`,
    },
    total_words: {
      value: totalWords,
      formula: "words of each take's cleaned text, or its raw text when it has no cleanup",
    },
    takes: { value: takes, days: days.size, formula: "recordings, all machines" },
    apps: {
      rows: [...apps]
        .map(([app, n]) => ({
          app,
          name: app === null ? "No app" : (APP_NAMES.get(app) ?? app),
          ...n,
        }))
        .sort((a, b) => b.takes - a.takes || b.words - a.words),
      formula: "takes and words per app that was in front when the take started",
    },
  };
}
