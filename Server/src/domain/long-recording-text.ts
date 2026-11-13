import type {
  ListControlSpan,
  ServerPreferences,
  SpokenListContext,
  TextProcessingRecord,
} from "../api.ts";
import type { InferenceBackend } from "../inference/native-inference.ts";
import { cleanTranscript } from "./cleaner.ts";
import { modelHints, processingRecord } from "./correction.ts";
import { evaluateCorrectionInWorker } from "./correction-runtime.ts";
import {
  applyDictionary,
  dictionaryKey,
  dictionaryVocabularyTerms,
  proofreadingTerms,
} from "./dictionary.ts";
import { formatSpokenList, spokenListBoundaryRanges, type FormattedDictation } from "./lists.ts";

const maximumWindowUnits = 2_400;
const minimumEditableTailUnits = 128;
const maximumProofBytes = 12 * 1024;
const sentenceEnds = /[.!?](?:["'’”)]*)(?=\s)|\n/gu;
const correctionCue = /\b(?:sorry|correction|i\s+mean|err|erm)\b/giu;
const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });

export interface LongRecordingTextSpan {
  revision: number;
  rawStart: number;
  rawEnd: number;
  rawText: string;
  /** Includes the separator from the preceding span, so assembly is one join. */
  text: string;
  processing: TextProcessingRecord[];
  /** The parser's exact UTF-16 ranges refer to this span's dictionary-adjusted source. */
  listControls?: { sourceText: string; spans: ListControlSpan[] };
}

/** The checkpoint stays bounded when committed spans are drained to a journal. */
export interface LongRecordingTextState {
  version: 1;
  revision: number;
  rawOffset: number;
  pendingText: string;
  listContext?: SpokenListContext;
  openListItem: boolean;
  hasOutput: boolean;
  lastEndsWithList: boolean;
  formatting: {
    started: boolean;
    containsList: boolean;
    continuesPreviousList: boolean;
    endedList: boolean;
    sawControl: boolean;
    rejectionReason?: string;
  };
  finalized: boolean;
  spans: LongRecordingTextSpan[];
}

export function createLongRecordingTextState(initialListContext?: SpokenListContext) {
  const state: LongRecordingTextState = {
    version: 1,
    revision: 0,
    rawOffset: 0,
    pendingText: "",
    listContext: initialListContext,
    openListItem: false,
    hasOutput: false,
    lastEndsWithList: initialListContext !== undefined,
    formatting: {
      started: false,
      containsList: false,
      continuesPreviousList: false,
      endedList: false,
      sawControl: false,
    },
    finalized: false,
    spans: [],
  };
  return state;
}

/** Drain an unpublished next state; commit its spans and checkpoint before publishing it. */
export function drainLongRecordingTextSpans(state: LongRecordingTextState) {
  return state.spans.splice(0);
}

function tailUnits(settings: ServerPreferences) {
  return Math.max(
    minimumEditableTailUnits,
    ...settings.dictionary.lists.flatMap((list) =>
      list.entries.flatMap((entry) =>
        [entry.term, ...entry.aliases].map((text) => text.length + 64),
      ),
    ),
  );
}

function scalarBoundary(text: string, index: number) {
  const unit = text.charCodeAt(index);
  return unit >= 0xdc00 && unit <= 0xdfff ? index - 1 : index;
}

/** Prefer sentence boundaries, but never wait indefinitely for punctuation. */
function splitBoundary(text: string, limit: number) {
  let sentence = 0;
  for (const match of text.matchAll(sentenceEnds)) {
    const end = match.index + match[0].length;
    if (end > limit) break;
    sentence = end;
  }
  if (sentence > limit / 2) return sentence;
  const space = text.lastIndexOf(" ", limit);
  return scalarBoundary(text, space > limit / 2 ? space + 1 : limit);
}

function protectedBoundary(text: string, proposed: number, settings: ServerPreferences) {
  const guard = tailUnits(settings);
  let offset = scalarBoundary(text, Math.max(0, proposed - guard));
  // The guard may start inside a word. A short correction neighborhood can
  // fall back to that start, so retain the entire word rather than split it.
  if (offset && /\S/u.test(text[offset] ?? ""))
    offset -= text.slice(0, offset).match(/\S+$/u)?.[0].length ?? 0;
  text = text.slice(offset, Math.min(text.length, proposed + guard));
  const ranges = [...spokenListBoundaryRanges(text)];
  // Match the dictionary's full Unicode fold while retaining source offsets.
  const boundaries = new Map<number, number>([[0, 0]]);
  const parts: string[] = [];
  let length = 0;
  for (const part of graphemes.segment(text)) {
    const folded = dictionaryKey(part.segment);
    parts.push(folded);
    length += folded.length;
    boundaries.set(length, part.index + part.segment.length);
  }
  const spellings = settings.dictionary.lists.flatMap((list) =>
    list.entries.flatMap((entry) => [entry.term, ...entry.aliases]),
  );
  if (spellings.length) {
    const escaped = [...new Set(spellings.map(dictionaryKey))]
      .sort((left, right) => right.length - left.length)
      .map((value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
    const word = "[\\p{L}\\p{M}\\p{N}\\p{Pc}\\u200C\\u200D]";
    const pattern = new RegExp(`(?<!${word})(?:${escaped.join("|")})(?!${word})`, "gu");
    for (const match of parts.join("").matchAll(pattern)) {
      const start = boundaries.get(match.index);
      const end = boundaries.get(match.index + match[0].length);
      if (start !== undefined && end !== undefined) ranges.push({ start, end });
    }
  }
  // A repair may abandon up to eight nearby words. Keep its complete neighborhood.
  for (const match of text.matchAll(correctionCue)) {
    const words = [...text.slice(0, match.index).matchAll(/\S+/gu)];
    const start = words.at(-8)?.index ?? 0;
    const after = [...text.slice(match.index + match[0].length).matchAll(/\S+/gu)].at(8);
    const end = after ? match.index + match[0].length + after.index : text.length;
    ranges.push({ start, end });
  }
  let cut = proposed - offset;
  let previous: number;
  do {
    previous = cut;
    for (const range of ranges) if (range.start < cut && range.end > cut) cut = range.start;
    // Moving out of one protected span may enter an earlier overlapping span.
  } while (cut < previous);
  return cut + offset;
}

function commitBoundary(text: string, settings: ServerPreferences) {
  const remaining = text.length - tailUnits(settings);
  if (remaining <= 0) return 0;
  const limit = Math.min(maximumWindowUnits, remaining);
  let sentence = 0;
  for (const match of text.matchAll(sentenceEnds)) {
    const end = match.index + match[0].length;
    if (end > limit) break;
    sentence = end;
  }
  if (!sentence && remaining < maximumWindowUnits) return 0;
  const cut = protectedBoundary(text, sentence || splitBoundary(text, limit), settings);
  // Pathological endless correction cues must not grow the checkpoint indefinitely.
  return cut || (remaining >= maximumWindowUnits ? splitBoundary(text, limit) : 0);
}

function proofBudgetError(error: unknown) {
  return (
    error instanceof Error &&
    /(?:token|context|correction limit|too long|length limit|exceeds.*limit|budget)/iu.test(
      error.message,
    )
  );
}

async function proofreadPart(
  text: string,
  settings: ServerPreferences,
  inference: InferenceBackend,
  signal?: AbortSignal,
  depth = 0,
  screenContextTerms: string[] = [],
): Promise<{ text: string; processing: TextProcessingRecord[] }> {
  signal?.throwIfAborted();
  const started = performance.now();
  const terms = dictionaryVocabularyTerms(settings.dictionary);
  const allTerms = proofreadingTerms(settings.dictionary, screenContextTerms);
  const screenTerms = allTerms.slice(terms.length);
  const record = (
    status: TextProcessingRecord["status"],
    extra: Partial<TextProcessingRecord> = {},
  ) =>
    processingRecord({
      dictionaryTerms: terms,
      dictionaryChangedText: false,
      inputText: text,
      outputText: text,
      enabled: settings.textCorrectionEnabled,
      status,
      wallSeconds: (performance.now() - started) / 1000,
      ...extra,
    });
  if (!settings.textCorrectionEnabled) return { text, processing: [record("disabled")] };
  try {
    const proof = await inference.correct(
      text,
      modelHints(allTerms),
      settings.language,
      settings.proofreadingPrompt,
      signal,
    );
    signal?.throwIfAborted();
    const candidate = applyDictionary(settings.dictionary, proof.text.trim(), 24 * 1024);
    const evaluation = await evaluateCorrectionInWorker(
      text,
      candidate,
      terms,
      screenTerms,
      signal,
    );
    signal?.throwIfAborted();
    const accepted = evaluation.rejectionReason === undefined;
    const output = accepted ? candidate : text;
    return {
      text: output,
      processing: [
        record(accepted ? (output === text ? "unchanged" : "applied") : "rejected", {
          outputText: output,
          proposedText: candidate,
          reason: evaluation.rejectionReason,
          verifiedRepairs: evaluation.verifiedRepairs,
          processingSeconds: proof.processingSeconds,
          engineVersion: proof.engineVersion,
          modelSHA256: proof.modelSHA256,
        }),
      ],
    };
  } catch (error) {
    signal?.throwIfAborted();
    // Native helpers own the exact tokenizer. Retry only their explicit budget
    // rejection, progressively shortening input; timeouts retain deterministic text.
    if (proofBudgetError(error) && text.length > 128 && depth < 5) {
      const cut = protectedBoundary(
        text,
        splitBoundary(text, Math.floor(text.length / 2)),
        settings,
      );
      if (cut > 0 && cut < text.length) {
        const leftSource = text.slice(0, cut);
        const rightSource = text.slice(cut);
        const leftBody = leftSource.trimEnd();
        const rightBody = rightSource.trimStart();
        if (leftBody && rightBody) {
          const left = await proofreadPart(
            leftBody,
            settings,
            inference,
            signal,
            depth + 1,
            screenContextTerms,
          );
          const right = await proofreadPart(
            rightBody,
            settings,
            inference,
            signal,
            depth + 1,
            screenContextTerms,
          );
          const separator =
            leftSource.slice(leftBody.length) +
            rightSource.slice(0, rightSource.length - rightBody.length);
          return {
            text: left.text + separator + right.text,
            processing: [...left.processing, ...right.processing],
          };
        }
      }
    }
    return {
      text,
      processing: [
        record("failed", {
          reason: error instanceof Error ? error.message : "Proofreading failed.",
        }),
      ],
    };
  }
}

async function proofreadBounded(
  text: string,
  settings: ServerPreferences,
  inference: InferenceBackend,
  signal?: AbortSignal,
  screenContextTerms: string[] = [],
) {
  const output: string[] = [];
  const processing: TextProcessingRecord[] = [];
  let remaining = text;
  while (remaining) {
    let limit = Math.min(maximumWindowUnits, remaining.length);
    while (Buffer.byteLength(remaining.slice(0, limit)) > maximumProofBytes)
      limit = scalarBoundary(remaining, Math.floor(limit / 2));
    const proposed = remaining.length > limit ? splitBoundary(remaining, limit) : limit;
    const cut = protectedBoundary(remaining, proposed, settings) || proposed;
    const source = remaining.slice(0, cut);
    remaining = remaining.slice(cut);
    const prefix = source.match(/^\s*/u)![0];
    const suffix = source.match(/\s*$/u)![0];
    const body = source.trim();
    if (!body) {
      output.push(source);
      continue;
    }
    const result = await proofreadPart(body, settings, inference, signal, 0, screenContextTerms);
    output.push(prefix, result.text, suffix);
    processing.push(...result.processing);
  }
  return { text: output.join(""), processing };
}

async function commitPrefix(
  state: LongRecordingTextState,
  count: number,
  settings: ServerPreferences,
  inference: InferenceBackend,
  final: boolean,
  signal?: AbortSignal,
  screenContextTerms: string[] = [],
) {
  const rawText = state.pendingText.slice(0, count);
  const clean = cleanTranscript(rawText);
  const dictionaryText = applyDictionary(settings.dictionary, clean, 24 * 1024);
  const formatted = formatSpokenList(dictionaryText, state.listContext, {
    continuePreviousItem: state.openListItem,
    keepTailPunctuation: !final,
  });
  const corrected = await proofreadBounded(
    formatted.text,
    settings,
    inference,
    signal,
    screenContextTerms,
  );
  let separator = "";
  if (corrected.text && state.hasOutput) {
    separator = formatted.continuesPreviousItem
      ? " "
      : formatted.continuesPreviousList
        ? "\n"
        : state.lastEndsWithList || formatted.containsList
          ? "\n\n"
          : " ";
  }
  state.revision += 1;
  state.spans.push({
    revision: state.revision,
    rawStart: state.rawOffset,
    rawEnd: state.rawOffset + rawText.length,
    rawText,
    text: separator + corrected.text,
    processing: corrected.processing.map((record) => ({
      ...record,
      dictionaryChangedText: dictionaryText !== clean,
    })),
    ...(formatted.consumedControls.length
      ? { listControls: { sourceText: dictionaryText, spans: formatted.consumedControls } }
      : {}),
  });
  state.rawOffset += rawText.length;
  state.pendingText = state.pendingText.slice(count);
  if (dictionaryText) {
    // Capture the first meaningful parser result, including control-only starts.
    // Later streaming chunks receive internal context and must not turn a new
    // list into a continuation of the destination's previous list.
    if (!state.formatting.started) {
      state.formatting.started = true;
      state.formatting.continuesPreviousList = formatted.continuesPreviousList;
    }
    state.formatting.containsList ||= formatted.containsList;
    state.formatting.endedList ||= formatted.endedList;
    state.formatting.sawControl ||=
      formatted.isControlOnly || formatted.consumedControls.length > 0;
    state.formatting.rejectionReason ??= formatted.formattingRejectionReason;
    state.listContext = formatted.context;
    state.openListItem = formatted.endsWithOpenItem === true;
  }
  if (corrected.text) {
    state.hasOutput = true;
    state.lastEndsWithList = formatted.endsWithList;
  }
}

export async function processLongRecordingTextWindow(
  state: LongRecordingTextState,
  text: string,
  settings: ServerPreferences,
  inference: InferenceBackend,
  signal?: AbortSignal,
  screenContextTerms: string[] = [],
) {
  if (state.finalized) throw new Error("The text session is already finalized.");
  const next = structuredClone(state);
  if (text) next.pendingText += (next.pendingText || next.rawOffset ? " " : "") + text;
  let boundary = commitBoundary(next.pendingText, settings);
  while (boundary) {
    await commitPrefix(next, boundary, settings, inference, false, signal, screenContextTerms);
    boundary = commitBoundary(next.pendingText, settings);
  }
  return next;
}

export async function finalizeLongRecordingText(
  state: LongRecordingTextState,
  settings: ServerPreferences,
  inference: InferenceBackend,
  signal?: AbortSignal,
  screenContextTerms: string[] = [],
) {
  if (state.finalized) return structuredClone(state);
  const next = structuredClone(state);
  while (next.pendingText) {
    const proposed =
      next.pendingText.length > maximumWindowUnits
        ? splitBoundary(next.pendingText, maximumWindowUnits)
        : next.pendingText.length;
    const boundary = protectedBoundary(next.pendingText, proposed, settings) || proposed;
    await commitPrefix(
      next,
      boundary,
      settings,
      inference,
      boundary === next.pendingText.length,
      signal,
      screenContextTerms,
    );
  }
  next.finalized = true;
  return next;
}

export function longRecordingTextResult(
  state: LongRecordingTextState,
  archivedSpans: LongRecordingTextSpan[] = [],
) {
  const spans = [...archivedSpans, ...state.spans];
  const cleanedText = spans.map((span) => span.text).join("");
  const formatted: FormattedDictation = {
    text: cleanedText,
    context: state.listContext,
    containsList: state.formatting.containsList,
    endsWithList: state.hasOutput && state.lastEndsWithList,
    continuesPreviousList: state.formatting.continuesPreviousList,
    endedList: state.formatting.endedList,
    isControlOnly: state.formatting.sawControl && !state.hasOutput,
    // Control offsets are preserved against their exact local source in the
    // span journal; dictionary substitutions prevent one global offset space.
    consumedControls: [],
    formattingRejectionReason: state.formatting.rejectionReason,
  };
  return {
    rawText: spans.map((span) => span.rawText).join("") + state.pendingText,
    cleanedText,
    formatted,
    listContext: state.listContext,
    finalized: state.finalized,
    revision: state.revision,
  };
}
