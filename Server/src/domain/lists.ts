import type { ListControlSpan, SpokenListContext } from "../api.ts";

export interface FormattedDictation {
  text: string;
  context?: SpokenListContext;
  containsList: boolean;
  endsWithList: boolean;
  continuesPreviousList: boolean;
  /** A bounded streaming prefix already emitted this item's list marker. */
  continuesPreviousItem?: boolean;
  /** Distinguishes an emitted item tail from a trailing marker awaiting a body. */
  endsWithOpenItem?: boolean;
  endedList: boolean;
  isControlOnly: boolean;
  consumedControls: ListControlSpan[];
  formattingRejectionReason?: string;
}

type Style = SpokenListContext["style"];
type Range = { start: number; end: number };
type Marker = { kind: "number"; number: number } | { kind: "next" | "bullet" };
type Action =
  { kind: "item"; marker: Marker } | { kind: "start" | "resume"; style?: Style } | { kind: "end" };
type Evidence =
  | "explicit"
  | "numeric"
  | "series"
  | "unanchoredSeries"
  | "inlineSeries"
  | "copularSeries"
  | "contextOnly";
type Event = { range: Range; action: Action; evidence: Evidence };
type Token = { value: string; range: Range };
type Match = { end: number; action: Action; evidence: Evidence };
const letter = (value: string) => /\p{L}/u.test(value);
const numeric = (value: string) => /\p{N}/u.test(value);
const content = (value: string) => letter(value) || numeric(value);
const integer = (value: string) =>
  /^[+]?[0-9]+$/.test(value) && Number.isSafeInteger(Number(value)) ? Number(value) : undefined;
const contains = (range: Range, position: number) =>
  position >= range.start && position < range.end;
const boundary = (token: Token) =>
  [".", "!", "?", ";", ":", "\n"].includes(token.value) ||
  (token.value.endsWith(".") && !["dr.", "mr.", "mrs.", "ms.", "st."].includes(token.value));
const abbreviations = new Set([
  "mr",
  "mrs",
  "ms",
  "dr",
  "jr",
  "sr",
  "st",
  "vs",
  "etc",
  "e.g",
  "i.e",
]);
const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });

// Keep original source ranges throughout the grammar. JavaScript indices are
// UTF-16 offsets, matching the persisted Foundation spans used by the client.
function tokenize(text: string): Token[] {
  const chars = Array.from(segmenter.segment(text), ({ segment, index }) => ({
    value: segment,
    index,
  }));
  const result: Token[] = [];
  let cursor = 0;
  while (cursor < chars.length) {
    const start = cursor;
    const first = chars[cursor]!.value;
    cursor += 1;
    if (/^\s+$/u.test(first)) {
      if (/[\n\r\u0085\u2028\u2029]/u.test(first))
        result.push({
          value: "\n",
          range: { start: chars[start]!.index, end: chars[cursor]?.index ?? text.length },
        });
      continue;
    }
    if (content(first)) {
      while (cursor < chars.length) {
        const current = chars[cursor]!.value;
        const previous = chars[cursor - 1]!.value;
        const next = chars[cursor + 1]?.value ?? "";
        const wordJoin = ["'", "’", "-"].includes(current) && letter(previous) && letter(next);
        const numericJoin =
          [".", ",", ":", "/", "-"].includes(current) && numeric(previous) && numeric(next);
        const dottedWord = current === "." && letter(previous) && letter(next);
        if (!(content(current) || wordJoin || numericJoin || dottedWord)) break;
        cursor += 1;
      }
      if (chars[cursor]?.value === ".") {
        const word = text.slice(chars[start]!.index, chars[cursor]!.index);
        const letters = Array.from(word).filter(letter);
        const initials =
          word.includes(".") &&
          letters.length > 0 &&
          letters.every((value) => value.toUpperCase() === value && value.toLowerCase() !== value);
        if (abbreviations.has(word.toLowerCase()) || initials) cursor += 1;
      }
    }
    const range = { start: chars[start]!.index, end: chars[cursor]?.index ?? text.length };
    result.push({
      value: text.slice(range.start, range.end).toLowerCase().replaceAll("’", "'"),
      range,
    });
  }
  return result;
}

const smallNumbers = new Map([
  ...[
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen",
  ].map((word, number) => [word, number] as const),
  ...[
    "zeroth",
    "first",
    "second",
    "third",
    "fourth",
    "fifth",
    "sixth",
    "seventh",
    "eighth",
    "ninth",
    "tenth",
    "eleventh",
    "twelfth",
    "thirteenth",
    "fourteenth",
    "fifteenth",
    "sixteenth",
    "seventeenth",
    "eighteenth",
    "nineteenth",
  ].map((word, number) => [word, number] as const),
]);
const tens = new Map<string, number>([
  ["twenty", 20],
  ["thirty", 30],
  ["forty", 40],
  ["fifty", 50],
  ["sixty", 60],
  ["seventy", 70],
  ["eighty", 80],
  ["ninety", 90],
  ["twentieth", 20],
  ["thirtieth", 30],
  ["fortieth", 40],
  ["fiftieth", 50],
  ["sixtieth", 60],
  ["seventieth", 70],
  ["eightieth", 80],
  ["ninetieth", 90],
]);

function englishNumber(words: string[]): number | undefined {
  const first = words[0];
  if (!first) return undefined;
  if (words.length === 1) return smallNumbers.get(first) ?? tens.get(first);
  const tensValue = tens.get(first);
  const units = smallNumbers.get(words[1]!);
  if (
    words.length === 2 &&
    tensValue !== undefined &&
    units !== undefined &&
    units >= 1 &&
    units <= 9
  )
    return tensValue + units;
  const leading = smallNumbers.get(first);
  if (
    leading !== undefined &&
    leading >= 1 &&
    leading <= 9 &&
    ["hundred", "hundredth", "thousand", "thousandth"].includes(words[1]!)
  ) {
    const multiplier = words[1]!.startsWith("hundred") ? 100 : 1_000;
    if (words.length === 2) return leading * multiplier;
    if (words[1]!.endsWith("th")) return undefined;
    const remainder = englishNumber(words.slice(words[2] === "and" ? 3 : 2));
    if (remainder !== undefined && remainder < multiplier) return leading * multiplier + remainder;
  }
  return undefined;
}

function number(tokens: Token[], start: number) {
  const first = tokens[start]?.value;
  if (first === undefined) return undefined;
  const numericValue = integer(first);
  if (numericValue !== undefined) return { value: numericValue, end: start + 1 };
  if (["st", "nd", "rd", "th"].some((suffix) => first.endsWith(suffix))) {
    const value = integer(first.slice(0, -2));
    if (value !== undefined) return { value, end: start + 1 };
  }
  const words: string[] = [];
  let best: { value: number; end: number } | undefined;
  for (let end = start; end < Math.min(tokens.length, start + 6); end += 1) {
    const next = tokens[end]!.value.split("-").filter(Boolean);
    if (
      !next.length ||
      !next.every(
        (word) =>
          smallNumbers.has(word) ||
          tens.has(word) ||
          ["hundred", "hundredth", "thousand", "thousandth", "and"].includes(word),
      )
    )
      break;
    words.push(...next);
    const value = englishNumber(words);
    if (value !== undefined) best = { value, end: end + 1 };
  }
  return best;
}

function marker(tokens: Token[], start: number): Match | undefined {
  const has = (words: string[]) =>
    words.every((word, index) => tokens[start + index]?.value === word);
  const endAfterSeparator = (index: number) =>
    tokens[index] && [",", ".", ":", ";", ")", "-", "–", "—"].includes(tokens[index]!.value)
      ? index + 1
      : index;
  const phraseMarker = (end: number, marker: Marker): Match => {
    const separatedEnd = endAfterSeparator(end);
    return {
      end: separatedEnd,
      action: { kind: "item", marker },
      evidence: separatedEnd !== end || end === tokens.length ? "explicit" : "contextOnly",
    };
  };
  for (const words of [
    ["next", "bullet", "point"],
    ["next", "bullet"],
    ["bullet", "point"],
    ["new", "bullet"],
  ]) {
    if (has(words)) return phraseMarker(start + words.length, { kind: "bullet" });
  }
  for (const words of [
    ["next", "item"],
    ["new", "item"],
  ]) {
    if (has(words)) return phraseMarker(start + words.length, { kind: "next" });
  }
  if (has(["next"]) && [",", ":"].includes(tokens[start + 1]?.value ?? ""))
    return {
      end: start + 2,
      action: { kind: "item", marker: { kind: "next" } },
      evidence: "contextOnly",
    };
  if (
    ["-", "•", "–"].includes(tokens[start]!.value) &&
    tokens[start + 1] &&
    tokens[start]!.range.end < tokens[start + 1]!.range.start &&
    (start === 0 || tokens[start - 1]!.value === "\n")
  )
    return {
      end: start + 1,
      action: { kind: "item", marker: { kind: "bullet" } },
      evidence: "explicit",
    };
  let numberStart = start;
  const prefixed = ["number", "item"].includes(tokens[start]!.value);
  if (prefixed) {
    numberStart += 1;
    if (tokens[numberStart]?.value === "number") numberStart += 1;
  }
  const parenthesized = tokens[start]!.value === "(";
  if (parenthesized) numberStart += 1;
  const parsed = number(tokens, numberStart);
  if (!parsed) return undefined;
  const action: Action = { kind: "item", marker: { kind: "number", number: parsed.value } };
  if (!parenthesized && parsed.value < 1_000 && tokens[parsed.end]?.value === "is")
    return { end: parsed.end + 1, action, evidence: "copularSeries" };
  if (prefixed) return phraseMarker(parsed.end, { kind: "number", number: parsed.value });
  const end = endAfterSeparator(parsed.end);
  const separator = tokens[parsed.end]?.value ?? "";
  if (parenthesized && separator !== ")") return undefined;
  if (end === parsed.end || parsed.value >= 1_000) return undefined;
  const explicit =
    parenthesized ||
    (integer(tokens[numberStart]!.value) !== undefined && [".", ")", ":"].includes(separator));
  return { end, action, evidence: explicit ? "numeric" : "series" };
}

function styleHint(words: string[]): Style | undefined {
  if (words.some((word) => ["bullet", "bulleted", "unordered"].includes(word))) return "bulleted";
  if (words.some((word) => ["numbered", "ordered"].includes(word))) return "numbered";
  return undefined;
}

function listDescriptor(tokens: Token[], start: number) {
  let end = start;
  const descriptors = new Set([
    "a",
    "an",
    "the",
    "that",
    "this",
    "my",
    "our",
    "new",
    "previous",
    "same",
    "numbered",
    "ordered",
    "bulleted",
    "unordered",
    "bullet",
    "point",
  ]);
  while (end < tokens.length && descriptors.has(tokens[end]!.value)) end += 1;
  const words = tokens.slice(start, end).map((token) => token.value);
  if (
    tokens[end]?.value === "list" ||
    (tokens[end]?.value === "points" && words.includes("bullet"))
  )
    return { end: end + 1, style: styleHint(words) };
  return undefined;
}

function introducesList(tokens: Token[], start: number) {
  return [["i", "have"], ["we", "have"], ["here", "is"], ["here's"], ["this", "is"]].some(
    (prefix) =>
      prefix.every((word, index) => tokens[start + index]?.value === word) &&
      listDescriptor(tokens, start + prefix.length) !== undefined,
  );
}

function directive(tokens: Token[], start: number): Match | undefined {
  let index = start;
  if (["okay", "ok", "alright", "so", "and", "now"].includes(tokens[index]!.value)) {
    index += 1;
    if (tokens[index]?.value === ",") index += 1;
  }
  if (tokens[index]?.value === "please") index += 1;
  if (tokens[index]?.value === "let's") index += 1;
  else if (tokens[index]?.value === "let" && ["me", "us"].includes(tokens[index + 1]?.value ?? ""))
    index += 2;
  if (!tokens[index]) return undefined;
  const finish = (end: number, action: Action): Match | undefined =>
    end === tokens.length
      ? { end, action, evidence: "explicit" }
      : [".", ",", ":", ";", "!", "?", "\n"].includes(tokens[end]?.value ?? "")
        ? { end: end + 1, action, evidence: "explicit" }
        : undefined;
  if (["that's", "that", "this"].includes(tokens[index]!.value)) {
    let endStart = index + 1;
    if (tokens[endStart]?.value === "is") endStart += 1;
    if (tokens[endStart]?.value === "the") endStart += 1;
    if (tokens[endStart]?.value === "end") index = endStart;
  } else if (tokens[index]!.value === "the" && tokens[index + 1]?.value === "end") index += 1;
  if (["end", "finish", "stop"].includes(tokens[index]!.value)) {
    let descriptorStart = index + 1;
    if (tokens[descriptorStart]?.value === "of") descriptorStart += 1;
    const descriptor = listDescriptor(tokens, descriptorStart);
    if (descriptor) return finish(descriptor.end, { kind: "end" });
  }
  if (["make", "create", "start", "begin"].includes(tokens[index]!.value)) {
    const descriptor = listDescriptor(tokens, index + 1);
    if (descriptor) return finish(descriptor.end, { kind: "start", style: descriptor.style });
  }
  if (["continue", "resume"].includes(tokens[index]!.value)) {
    const descriptor = listDescriptor(tokens, index + 1);
    if (descriptor) return finish(descriptor.end, { kind: "resume", style: descriptor.style });
  }
  if (["numbered", "bulleted", "bullet", "new"].includes(tokens[index]!.value)) {
    const descriptor = listDescriptor(tokens, index);
    if (descriptor) return finish(descriptor.end, { kind: "start", style: descriptor.style });
  }
  if (["go", "get"].includes(tokens[index]!.value) && tokens[index + 1]?.value === "back")
    index += 1;
  if (tokens[index]!.value === "back") {
    const allowed = new Set([
      "to",
      "where",
      "i",
      "was",
      "with",
      "on",
      "the",
      "that",
      "this",
      "my",
      "our",
      "previous",
      "same",
      "numbered",
      "bulleted",
      "bullet",
      "point",
    ]);
    let end = index + 1;
    while (end < Math.min(tokens.length, index + 16) && allowed.has(tokens[end]!.value)) end += 1;
    if (tokens[end]?.value === "list")
      return finish(end + 1, {
        kind: "resume",
        style: styleHint(tokens.slice(index, end + 1).map((token) => token.value)),
      });
  }
  return undefined;
}

function scan(text: string): Event[] {
  const tokens = tokenize(text);
  const events: Event[] = [];
  let index = 0;
  let afterDirective = false;
  let itemBodyStart: number | undefined;
  let hasListEvidence = false;
  let hasListIntroduction = false;
  while (index < tokens.length) {
    const afterComma = index > 0 && tokens[index - 1]!.value === ",";
    const atBoundary = index === 0 || boundary(tokens[index - 1]!) || afterDirective || afterComma;
    afterDirective = false;
    if (atBoundary && introducesList(tokens, index)) hasListIntroduction = true;
    if (index === itemBodyStart && !(index > 0 && boundary(tokens[index - 1]!))) {
      index += 1;
      continue;
    }
    const command = atBoundary ? directive(tokens, index) : undefined;
    if (command) {
      events.push({
        range: { start: tokens[index]!.range.start, end: tokens[command.end - 1]!.range.end },
        action: command.action,
        evidence: command.evidence,
      });
      index = command.end;
      afterDirective = true;
      itemBodyStart = undefined;
      hasListEvidence = command.action.kind !== "end";
      hasListIntroduction = command.action.kind !== "end";
      continue;
    }
    let match = marker(tokens, index);
    if (!match) {
      index += 1;
      continue;
    }
    if (
      match.evidence === "copularSeries" &&
      (!hasListIntroduction ||
        (index > 0 &&
          ["this", "that", "the", "each", "every", "only", "which"].includes(
            tokens[index - 1]!.value,
          )))
    ) {
      index += 1;
      continue;
    }
    if (
      match.evidence === "numeric" &&
      !hasListEvidence &&
      index > 0 &&
      tokens[index - 1]!.value !== "\n"
    )
      match = { ...match, evidence: "unanchoredSeries" };
    if (!atBoundary && match.evidence !== "copularSeries") {
      if (
        match.action.kind !== "item" ||
        match.action.marker.kind !== "number" ||
        integer(tokens[index]!.value) === undefined ||
        tokens[index + 1]?.value !== ","
      ) {
        index += 1;
        continue;
      }
      match = { ...match, evidence: "inlineSeries" };
    }
    if (afterComma && match.evidence !== "copularSeries") {
      const previousWasNumber = index >= 2 && number(tokens, index - 2)?.end === index - 1;
      if (
        (!hasListEvidence && match.evidence !== "explicit") ||
        (previousWasNumber && match.evidence !== "explicit")
      ) {
        index += 1;
        continue;
      }
    }
    events.push({
      range: { start: tokens[index]!.range.start, end: tokens[match.end - 1]!.range.end },
      action: match.action,
      evidence: match.evidence,
    });
    index = match.end;
    itemBodyStart = index;
    hasListEvidence ||= match.evidence !== "contextOnly" && match.evidence !== "inlineSeries";
  }
  return events;
}

/** Keep a complete spoken control/number marker on one side of a stream cut. */
export function spokenListBoundaryRanges(text: string) {
  return scan(text).map(({ range }) => range);
}

const contentTokens = (text: string) =>
  tokenize(text)
    .map((token) => token.value)
    .filter(content);
function containsNonCountingContent(text: string) {
  const tokens = tokenize(text).filter((token) => content(token.value));
  let index = 0;
  while (index < tokens.length) {
    const parsed = number(tokens, index);
    if (parsed) index = parsed.end;
    else if (["and", "or"].includes(tokens[index]!.value)) index += 1;
    else return true;
  }
  return false;
}

function inferredMarkers(events: Event[], text: string) {
  const accepted = new Set<number>();
  let series: number[] = [];
  const body = (index: number) =>
    text.slice(events[index]!.range.end, events[index + 1]?.range.start ?? text.length);
  const finishSeries = () => {
    const pending = series;
    series = [];
    if (pending.length < 2) return;
    if (pending.some((index) => events[index]!.evidence === "inlineSeries")) {
      if (events[pending[0]!]!.evidence === "inlineSeries") return;
      const numbers = pending.flatMap((index) => {
        const action = events[index]!.action;
        return action.kind === "item" && action.marker.kind === "number"
          ? [action.marker.number]
          : [];
      });
      if (!numbers.every((value, index) => index === 0 || numbers[index - 1]! < value)) return;
      const hedges = new Set([
        "and",
        "or",
        "maybe",
        "perhaps",
        "possibly",
        "about",
        "around",
        "roughly",
        "approximately",
      ]);
      if (
        !pending.every((index) => {
          const words = contentTokens(body(index));
          return words.some(letter) && !!words[0] && !hedges.has(words[0]);
        })
      )
        return;
    }
    for (const index of pending) accepted.add(index);
  };
  for (const [index, event] of events.entries()) {
    if (event.action.kind !== "item") {
      finishSeries();
      continue;
    }
    if (
      event.action.marker.kind === "number" &&
      event.evidence !== "contextOnly" &&
      content(body(index))
    )
      series.push(index);
    else finishSeries();
  }
  finishSeries();
  return accepted;
}

function itemText(text: string) {
  let value = text;
  while (value.endsWith(",") || value.endsWith(";")) value = value.slice(0, -1).trimEnd();
  const tokens = tokenize(value);
  if (
    tokens.at(-1)?.value === "." &&
    tokens.slice(0, -1).every((token) => ![".", "!", "?"].includes(token.value))
  )
    return value.slice(0, -1).trim();
  return value;
}

function isMeta(text: string) {
  const words = tokenize(text)
    .map((token) => token.value)
    .filter(letter);
  const sentence = words.join(" ");
  if (
    [
      "sorry",
      "go ahead",
      "hold on",
      "hang on",
      "one moment",
      "wait a second",
      "just a second",
      "let me try again",
      "let's try again",
      "okay",
      "ok",
      "all right",
    ].includes(sentence)
  )
    return true;
  const speechTools = [
    "dictation",
    "transcription",
    "voice to text",
    "voice-to-text",
    "speech to text",
    "speech-to-text",
  ];
  const problems = new Set([
    "ruined",
    "broken",
    "wrong",
    "messed",
    "stopped",
    "lost",
    "failed",
    "restarting",
    "restart",
    "redo",
    "again",
  ]);
  const status = speechTools
    .map((tool) => {
      const prefix = `my ${tool} `;
      return sentence.startsWith(prefix) ? sentence.slice(prefix.length) : undefined;
    })
    .find((value) => value !== undefined);
  const statusVerbs = new Set([
    "is",
    "was",
    "has",
    "had",
    "got",
    "went",
    "just",
    "keeps",
    "stopped",
    "failed",
    "broke",
  ]);
  if (
    status !== undefined &&
    statusVerbs.has(status.split(" ")[0] ?? "") &&
    !text.includes("?") &&
    !words.includes("please") &&
    words.some((word) => problems.has(word))
  )
    return true;
  return (
    (sentence.includes("screenshot") || sentence.includes("screen shot")) &&
    ["sorry", "i"].includes(words[0] ?? "") &&
    words.some((word) => ["wanted", "wrong", "meant"].includes(word))
  );
}

function metaPreludeRanges(text: string, range: Range) {
  const removed: Range[] = [];
  let start = range.start;
  for (const token of tokenize(text)) {
    if (!contains(range, token.range.start) || ![".", "!", "?", "\n"].includes(token.value))
      continue;
    const segment = { start, end: token.range.end };
    if (isMeta(text.slice(segment.start, segment.end))) removed.push(segment);
    start = token.range.end;
  }
  const remainder = { start, end: range.end };
  if (isMeta(text.slice(remainder.start, remainder.end))) removed.push(remainder);
  return removed;
}

function removing(removed: Range[], text: string, range: Range) {
  let kept = "";
  let start = range.start;
  for (const removal of removed) {
    kept += text.slice(start, removal.start);
    start = removal.end;
  }
  return kept + text.slice(start, range.end);
}

const numberToken = (value: number) => `#list-number:${value}`;
function sourceContentTokens(
  text: string,
  controls: Range[],
  numberMarkers: { range: Range; number: number }[],
) {
  const result: string[] = [];
  for (const token of tokenize(text)) {
    if (controls.some((range) => contains(range, token.range.start))) continue;
    const marker = numberMarkers.find(({ range }) => contains(range, token.range.start));
    if (marker) {
      if (marker.range.start === token.range.start) result.push(numberToken(marker.number));
      continue;
    }
    if (content(token.value)) result.push(token.value);
  }
  return result;
}

/** Deterministic spoken-list grammar; caller commits returned context after insertion. */
export function formatSpokenList(
  text: string,
  initialContext?: SpokenListContext,
  options: { continuePreviousItem?: boolean; keepTailPunctuation?: boolean } = {},
): FormattedDictation {
  const empty = (value: string, reason?: string): FormattedDictation => ({
    text: value,
    context: initialContext,
    containsList: false,
    endsWithList: false,
    continuesPreviousList: false,
    endedList: false,
    isControlOnly: false,
    consumedControls: [],
    formattingRejectionReason: reason,
  });
  if (!text.trim()) return empty("");
  const events = scan(text);
  const inferred = inferredMarkers(events, text);
  const containsInlineCandidates = events.some((event) => event.evidence === "inlineSeries");
  let context = initialContext;
  let usesOriginalContext = initialContext !== undefined;
  const pieces: { text: string; isList: boolean }[] = [];
  let body = "";
  let cursor = 0;
  let containsList = false;
  let continuesPreviousList = false;
  let endedList = false;
  let consumedControl = false;
  let awaitingMarkedItem = false;
  let bodyStart = 0;
  const controls: Range[] = [];
  const numberMarkers: { range: Range; number: number }[] = [];
  const emittedContent: string[] = [];
  let pendingSourceNumber: number | undefined;
  let continuingItem = options.continuePreviousItem === true && initialContext !== undefined;
  let continuesPreviousItem = false;
  const flush = (finalTail = false) => {
    const value = body.trim();
    body = "";
    awaitingMarkedItem = false;
    if (!value) return;
    if (!context) {
      pieces.push({ text: value, isList: false });
      emittedContent.push(...contentTokens(value));
      return;
    }
    const item = finalTail && options.keepTailPunctuation ? value : itemText(value);
    if (!item) return;
    if (!pieces.length && usesOriginalContext && initialContext?.style === context.style)
      continuesPreviousList = true;
    if (continuingItem) {
      pieces.push({ text: item, isList: true });
      continuesPreviousItem = true;
      continuingItem = false;
    } else if (context.style === "numbered") {
      pieces.push({ text: `${context.nextNumber}. ${item}`, isList: true });
      if (pendingSourceNumber !== undefined) emittedContent.push(numberToken(context.nextNumber));
      context = {
        style: "numbered",
        nextNumber: Math.min(Number.MAX_SAFE_INTEGER, context.nextNumber + 1),
      };
    } else pieces.push({ text: `- ${item}`, isList: true });
    emittedContent.push(...contentTokens(item));
    pendingSourceNumber = undefined;
    containsList = true;
  };
  for (const [index, event] of events.entries()) {
    body += text.slice(cursor, event.range.start);
    cursor = event.range.end;
    const action = event.action;
    if (action.kind === "item") {
      const followingBody = text.slice(
        event.range.end,
        events[index + 1]?.range.start ?? text.length,
      );
      if (action.marker.kind === "number" && !content(followingBody)) {
        body += text.slice(event.range.start, event.range.end);
        continue;
      }
      if (event.evidence === "series" && !containsNonCountingContent(followingBody)) {
        body += text.slice(event.range.start, event.range.end);
        continue;
      }
      const contextSupportsMarker =
        context !== undefined &&
        !["inlineSeries", "unanchoredSeries", "copularSeries"].includes(event.evidence) &&
        !(event.evidence === "series" && containsInlineCandidates && !inferred.has(index));
      if (!(
        contextSupportsMarker ||
        event.evidence === "explicit" ||
        event.evidence === "numeric" ||
        inferred.has(index)
      )) {
        body += text.slice(event.range.start, event.range.end);
        continue;
      }
      flush();
      continuingItem = false;
      if (action.marker.kind === "number") {
        context = { style: "numbered", nextNumber: action.marker.number };
        numberMarkers.push({ range: event.range, number: action.marker.number });
        pendingSourceNumber = action.marker.number;
      } else if (action.marker.kind === "bullet") {
        context = { style: "bulleted", nextNumber: 1 };
        controls.push(event.range);
      } else {
        context ??= { style: "numbered", nextNumber: 1 };
        controls.push(event.range);
      }
      consumedControl = true;
      awaitingMarkedItem = true;
      bodyStart = event.range.end;
    } else if (action.kind === "start") {
      flush();
      continuingItem = false;
      context = { style: action.style ?? "numbered", nextNumber: 1 };
      usesOriginalContext = false;
      consumedControl = true;
      controls.push(event.range);
      bodyStart = event.range.end;
    } else if (action.kind === "resume") {
      if (!containsList && !awaitingMarkedItem) {
        const range = { start: bodyStart, end: event.range.start };
        const removed = metaPreludeRanges(text, range);
        controls.push(...removed);
        body = removing(removed, text, range);
      }
      flush();
      continuingItem = false;
      if (action.style !== undefined && action.style !== context?.style) {
        context = { style: action.style, nextNumber: 1 };
        usesOriginalContext = false;
      } else context ??= { style: action.style ?? "numbered", nextNumber: 1 };
      consumedControl = true;
      controls.push(event.range);
      bodyStart = event.range.end;
    } else {
      flush();
      continuingItem = false;
      context = undefined;
      usesOriginalContext = false;
      endedList = true;
      consumedControl = true;
      controls.push(event.range);
      bodyStart = event.range.end;
    }
  }
  body += text.slice(cursor);
  const endsWithOpenItem = context !== undefined && body.trim().length > 0;
  flush(true);
  if (!consumedControl && initialContext === undefined)
    return { ...empty(text), context: undefined };
  const output = pieces
    .map(
      (piece, index) =>
        `${index === 0 ? "" : pieces[index - 1]!.isList && piece.isList ? "\n" : "\n\n"}${piece.text}`,
    )
    .join("");
  if (
    !output &&
    consumedControl &&
    usesOriginalContext &&
    context &&
    context.style === initialContext?.style
  )
    continuesPreviousList = true;
  const sourceContent = sourceContentTokens(text, controls, numberMarkers);
  if (
    sourceContent.length !== emittedContent.length ||
    sourceContent.some((token, index) => token !== emittedContent[index])
  )
    return empty(
      text,
      "List formatting would change dictated content; kept the original transcript.",
    );
  return {
    text: output,
    context,
    containsList,
    endsWithList: pieces.at(-1)?.isList === true,
    continuesPreviousList,
    continuesPreviousItem,
    endsWithOpenItem,
    endedList,
    isControlOnly: consumedControl && !output,
    consumedControls: controls.map(({ start, end }) => ({ location: start, length: end - start })),
    formattingRejectionReason: undefined,
  };
}

export function replaceFormattedText(
  formatted: FormattedDictation,
  text: string,
): FormattedDictation {
  return { ...formatted, text };
}
