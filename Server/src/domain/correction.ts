import type { TextProcessingRecord, VerifiedTextRepair } from "../api.ts";
import { caseFold } from "./dictionary.ts";

/** Conservative deterministic validation after a generative proofread. */
export const maxInputCharacters = 6_000;

const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });
const encoder = new TextEncoder();
const maxAlignmentCells = 16_000_000;
const maxScanComparisons = 16_000_000;
const repairSpanLimit = 8;
const wordPattern = /[\p{L}\p{N}]+(?:['’][\p{L}]+)?/gu;
const cuePattern = /(?:err|erm|er|i\p{White_Space}+mean|correction|sorry)/giu;
const markerPattern = /^[\t ]*(?:[0-9]+[.)]|[-*•])[\t ]+/gm;
const numberPattern =
  /[\p{Sc}+−-]?\p{White_Space}*\p{N}+(?:[.,:/-]\p{N}+)*(?:\p{White_Space}*[%‰])?/gu;
const hesitations = new Set(["um", "uh", "er", "err", "erm"]);
const negatives = new Set([
  "no",
  "not",
  "never",
  "neither",
  "nor",
  "without",
  "nothing",
  "nobody",
  "none",
  "nowhere",
]);
const quantities = new Set(
  "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion trillion first second third fourth fifth sixth seventh eighth ninth tenth half quarter percent".split(
    " ",
  ),
);
const contractions: Record<string, string[]> = {
  cannot: ["can", "not"],
  "can't": ["can", "not"],
  "won't": ["will", "not"],
  "shan't": ["shall", "not"],
  "don't": ["do", "not"],
  "doesn't": ["does", "not"],
  "didn't": ["did", "not"],
  "haven't": ["have", "not"],
  "hasn't": ["has", "not"],
  "hadn't": ["had", "not"],
  "isn't": ["is", "not"],
  "aren't": ["are", "not"],
  "wasn't": ["was", "not"],
  "weren't": ["were", "not"],
  "couldn't": ["could", "not"],
  "wouldn't": ["would", "not"],
  "shouldn't": ["should", "not"],
  "mustn't": ["must", "not"],
  "needn't": ["need", "not"],
  "mightn't": ["might", "not"],
};

type Token = { word: string; start: number; end: number };
type Span = { start: number; end: number };

const graphemes = (text: string) => Array.from(segmenter.segment(text), (part) => part.segment);
const same = <T>(left: readonly T[], right: readonly T[]) =>
  left.length === right.length && left.every((value, index) => value === right[index]);
const words = (text: string) => tokens(text).map((token) => token.word);
const isNegative = (word: string) => negatives.has(word) || word.endsWith("n't");
const intersects = (left: Span, right: Span) =>
  Math.min(left.end, right.end) > Math.max(left.start, right.start);
const sameRange = (left: Token, right: Token) =>
  left.start === right.start && left.end === right.end;
const hasSeparator = (text: string) => /[,—–-]/u.test(text);
const hasQuote = (text: string) => /["'‘’“”`]/u.test(text);
const trim = (text: string) =>
  text.replace(/^[\p{White_Space}\u200B]+|[\p{White_Space}\u200B]+$/gu, "");
const lowercase = (text: string) => [...text].map((scalar) => scalar.toLowerCase()).join("");

function characterCount(text: string, limit = Infinity) {
  let count = 0;
  for (const _ of segmenter.segment(text)) {
    if (++count > limit) break;
  }
  return count;
}

function prefixCharacters(text: string, limit: number) {
  let count = 0;
  for (const part of segmenter.segment(text)) {
    if (count++ === limit) return text.slice(0, part.index);
  }
  return text;
}

function matches(pattern: RegExp, text: string) {
  // matchAll clones the expression; each call is independent of lastIndex.
  return Array.from(text.matchAll(pattern));
}

function tokens(text: string): Token[] {
  return matches(wordPattern, text).flatMap((match) => {
    const word = lowercase(match[0]).replaceAll("’", "'");
    const start = match.index;
    return (Object.hasOwn(contractions, word) ? contractions[word]! : [word]).map((value) => ({
      word: value,
      start,
      end: start + match[0].length,
    }));
  });
}

export function modelHints(terms: string[]) {
  let bytes = 0;
  const result: string[] = [];
  for (const term of terms) {
    const length = encoder.encode(term).length;
    if (length > 256 || bytes + length > 4_096) continue;
    bytes += length;
    if (result.length < 80) result.push(term);
  }
  return result;
}

/** Bounds archived model proposals without splitting UTF-16 surrogate pairs. */
export function boundProposedText(text: string) {
  let units = 0;
  for (const scalar of text) {
    if (units + scalar.length > maxInputCharacters * 8) break;
    units += scalar.length;
  }
  return prefixCharacters(text.slice(0, units), maxInputCharacters * 2);
}

export function processingRecord(record: TextProcessingRecord): TextProcessingRecord {
  return {
    ...record,
    ...(record.proposedText === undefined
      ? {}
      : { proposedText: boundProposedText(record.proposedText) }),
    ...(record.verifiedRepairs === undefined
      ? {}
      : { verifiedRepairs: record.verifiedRepairs.slice(0, 8) }),
  };
}

/** Dictionary terms are user-curated: they join split fragments in the source, and an
 * output word within two edits of one counts as the same word. Screen terms are only
 * read off the window, so the rewrite must keep any the source already contains, but
 * they never rewrite the source for comparison: joining fragments into one or swapping
 * toward one is an ordinary word change, and source negations stay as spoken.
 */
export function evaluateCorrection(
  original: string,
  candidate: string,
  dictionaryTerms: string[] = [],
  screenTerms: string[] = [],
) {
  let verifiedRepairs: VerifiedTextRepair[] = [];
  const reject = (rejectionReason?: string) => ({ rejectionReason, verifiedRepairs });
  if (
    original.length > maxInputCharacters * 4 ||
    characterCount(original, maxInputCharacters) > maxInputCharacters
  ) {
    return reject("The source was too long to validate.");
  }
  const output = trim(candidate);
  if (!output) return reject("The text model returned no text.");
  if (
    output.length > maxInputCharacters * 8 ||
    characterCount(output, maxInputCharacters * 2) > maxInputCharacters * 2
  ) {
    return reject("The rewrite was too long.");
  }
  if (output.includes("<|") || output.includes("<think>") || output.includes("</think>")) {
    return reject("The text model returned control tokens.");
  }
  for (const prefix of [
    "here is",
    "here's",
    "corrected text:",
    "corrected transcript:",
    "sure,",
    "certainly,",
  ]) {
    if (lowercase(output).startsWith(prefix) && !lowercase(original).startsWith(prefix)) {
      return reject("The text model added commentary.");
    }
  }
  if (!withinValidationBudget(original, output))
    return reject("The rewrite was too complex to validate.");
  if (!same(listMarkers(original), listMarkers(output)))
    return reject("The rewrite changed the list structure.");

  const repairCheck = verifyRepairs(original, output);
  verifiedRepairs = repairCheck.repairs;
  const protectedSource = repairCheck.protectedSource;
  if (!same(numbers(protectedSource), numbers(output)))
    return reject("The rewrite changed a number.");
  const preferredTerms = [...dictionaryTerms, ...screenTerms];
  const foldedSource = preferredTerms.length ? foldedIndex(protectedSource) : undefined;
  const foldedOutput = preferredTerms.length ? foldedIndex(output) : undefined;
  for (const term of preferredTerms) {
    const count = countPreferredTerm(protectedSource, foldedSource!, term);
    if (count > 0 && countPreferredTerm(output, foldedOutput!, term) !== count)
      return reject("The rewrite changed a dictionary term.");
  }
  const before = words(protectedSource);
  const after = words(output);
  if (
    !same(
      before.filter((word) => quantities.has(word)),
      after.filter((word) => quantities.has(word)),
    )
  )
    return reject("The rewrite changed a quantity.");
  if (!before.length) return reject(output === original ? undefined : "The rewrite added content.");
  const trusted = new Set(dictionaryTerms.flatMap(words));
  const comparedBefore = recognizedTerms(protectedSource, intersection(trusted, after)).map(
    (token) => token.word,
  );
  const ratio = after.length / comparedBefore.length;
  if (ratio < 0.75 || ratio > 1.35) return reject("The rewrite changed too much text.");
  if (
    orderedOverlap(comparedBefore, after, trusted) / Math.max(comparedBefore.length, after.length) <
    0.72
  ) {
    return reject("The rewrite changed too much wording.");
  }
  const reason = preservationReason(protectedSource, output, trusted);
  if (reason) return reject(reason);
  const originalItems = listItems(protectedSource);
  const rewrittenItems = listItems(output);
  for (let index = 0; index < Math.min(originalItems.length, rewrittenItems.length); index++) {
    const b = words(rewrittenItems[index]!);
    const a = recognizedTerms(originalItems[index]!, intersection(trusted, b)).map(
      (token) => token.word,
    );
    if (orderedOverlap(a, b, trusted) / Math.max(1, a.length, b.length) < 0.72)
      return reject("The rewrite changed a list item.");
  }
  return reject();
}

function intersection(left: Set<string>, right: string[]) {
  return new Set(right.filter((word) => left.has(word)));
}

function numbers(text: string) {
  return matches(numberPattern, text).map((match) => match[0].replace(/\p{White_Space}/gu, ""));
}

function listMarkers(text: string) {
  return matches(/^\p{White_Space}*(?:[0-9]+[.)]|[-*•])(?=\p{White_Space})/gmu, text).map((match) =>
    trim(match[0]),
  );
}

function previousScalar(text: string, index: number) {
  if (index === 0) return "";
  const unit = text.charCodeAt(index - 1);
  return text.slice(index - (unit >= 0xdc00 && unit <= 0xdfff ? 2 : 1), index);
}

function nextScalar(text: string, index: number) {
  const scalar = text.codePointAt(index);
  return scalar === undefined ? "" : String.fromCodePoint(scalar);
}

// Foundation/ICU's default boundary skips preceding nonspacing marks and
// format controls, and never starts a boundary immediately before either.
function wordBoundary(text: string, index: number) {
  const next = nextScalar(text, index);
  if (/[\p{Mn}\p{Me}\p{Cf}]/u.test(next)) return false;
  let previous = previousScalar(text, index);
  while (/[\p{Mn}\p{Me}\p{Cf}]/u.test(previous)) {
    index -= previous.length;
    previous = previousScalar(text, index);
  }
  const word = /[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\u200C\u200D]/u;
  return word.test(previous) !== word.test(next);
}

function repairCues(text: string) {
  return matches(cuePattern, text).filter(
    (match) => wordBoundary(text, match.index) && wordBoundary(text, match.index + match[0].length),
  );
}

function foldedIndex(text: string) {
  const parts: string[] = [];
  const boundaries = new Map<number, number>([[0, 0]]);
  let sourceOffset = 0;
  let foldedOffset = 0;
  for (const scalar of text) {
    const folded = caseFold(scalar);
    parts.push(folded);
    sourceOffset += scalar.length;
    foldedOffset += folded.length;
    boundaries.set(foldedOffset, sourceOffset);
  }
  return { text: parts.join(""), boundaries };
}

function countPreferredTerm(source: string, folded: ReturnType<typeof foldedIndex>, term: string) {
  const escaped = caseFold(term).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(escaped, "gu");
  const adjacentWord = /[\p{L}\p{N}\p{M}\p{Pc}\u200C\u200D]/u;
  let count = 0;
  for (const match of matches(pattern, folded.text)) {
    const start = folded.boundaries.get(match.index);
    const end = folded.boundaries.get(match.index + match[0].length);
    // A full case fold may expand a scalar; ICU does not match half of it.
    if (
      start === undefined ||
      end === undefined ||
      adjacentWord.test(previousScalar(source, start)) ||
      adjacentWord.test(nextScalar(source, end))
    )
      continue;
    count++;
  }
  return count;
}

function listItems(text: string) {
  return matches(/^[\t ]*(?:[0-9]+[.)]|[-*•])[\t ]+[^\n]*/gm, text).map((match) => match[0]);
}

function withinValidationBudget(original: string, candidate: string) {
  const input = tokens(original);
  const width = tokens(candidate).length + 1;
  if (input.length + 1 > Math.floor(maxAlignmentCells / width)) return false;
  const cueCount = repairCues(original).length;
  const hesitationCount = input.filter((token) => hesitations.has(token.word)).length;
  const comparisons =
    cueCount * repairSpanLimit * repairSpanLimit * (repairSpanLimit + 4) + hesitationCount * 4;
  return comparisons <= Math.floor(maxScanComparisons / width);
}

function editDistance(left: string, right: string) {
  const a = graphemes(left);
  const b = graphemes(right);
  if (Math.abs(a.length - b.length) > 2) return 3;
  const row = Uint32Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 0; i < a.length; i++) {
    let diagonal = row[0]!;
    row[0] = i + 1;
    for (let j = 0; j < b.length; j++) {
      const old = row[j + 1]!;
      row[j + 1] = Math.min(row[j]! + 1, old + 1, diagonal + (a[i] === b[j] ? 0 : 1));
      diagonal = old;
    }
  }
  return row[b.length]!;
}

function equivalence(preferred: Set<string>) {
  const cache = new Map<string, Map<string, boolean>>();
  return (left: string, right: string) => {
    if (left === right) return true;
    if (!preferred.has(right)) return false;
    let matches = cache.get(left);
    if (!matches) {
      matches = new Map();
      cache.set(left, matches);
    }
    const cached = matches.get(right);
    if (cached !== undefined) return cached;
    const equivalent =
      characterCount(left, 3) >= 4 &&
      characterCount(right, 3) >= 4 &&
      editDistance(left, right) <= 2;
    matches.set(right, equivalent);
    return equivalent;
  };
}

function orderedOverlap(before: string[], after: string[], preferred: Set<string>) {
  const row = new Uint32Array(after.length + 1);
  const equivalent = equivalence(preferred);
  for (const word of before) {
    let diagonal = 0;
    for (let index = 0; index < after.length; index++) {
      const old = row[index + 1]!;
      row[index + 1] = equivalent(word, after[index]!) ? diagonal + 1 : Math.max(row[index]!, old);
      diagonal = old;
    }
  }
  return row[after.length]!;
}

function alignment(before: Token[], after: Token[], preferred: Set<string>) {
  const width = after.length + 1;
  const scores = new Uint32Array((before.length + 1) * width);
  const equivalent = equivalence(preferred);
  const weight = (i: number, j: number) =>
    8 +
    (i > 0 && j > 0 && equivalent(before[i - 1]!.word, after[j - 1]!.word) ? 2 : 0) +
    (i + 1 < before.length &&
    j + 1 < after.length &&
    equivalent(before[i + 1]!.word, after[j + 1]!.word)
      ? 2
      : 0);
  for (let i = 1; i <= before.length; i++) {
    for (let j = 1; j <= after.length; j++) {
      const skip = Math.max(scores[(i - 1) * width + j]!, scores[i * width + j - 1]!);
      scores[i * width + j] = equivalent(before[i - 1]!.word, after[j - 1]!.word)
        ? Math.max(skip, scores[(i - 1) * width + j - 1]! + weight(i - 1, j - 1))
        : skip;
    }
  }
  let i = before.length;
  let j = after.length;
  const result: [number, number][] = [];
  while (i > 0 && j > 0) {
    if (
      equivalent(before[i - 1]!.word, after[j - 1]!.word) &&
      scores[i * width + j] === scores[(i - 1) * width + j - 1]! + weight(i - 1, j - 1)
    ) {
      result.push([--i, --j]);
    } else if (scores[(i - 1) * width + j]! >= scores[i * width + j - 1]!) i--;
    else j--;
  }
  return result.reverse();
}

function preservationReason(original: string, candidate: string, trusted: Set<string>) {
  const output = tokens(candidate);
  const input = recognizedTerms(
    original,
    intersection(
      trusted,
      output.map((token) => token.word),
    ),
  );
  const inputNegatives = input.flatMap((token, index) => (isNegative(token.word) ? [index] : []));
  const outputNegatives = output.flatMap((token, index) => (isNegative(token.word) ? [index] : []));
  if (
    !same(
      inputNegatives.map((index) => input[index]!.word),
      outputNegatives.map((index) => output[index]!.word),
    )
  )
    return "The rewrite changed a negation.";
  const aligned = alignment(input, output, trusted);
  const matchedOutput = new Set(aligned.map((pair) => pair[1]));
  if (output.some((token, index) => trusted.has(token.word) && !matchedOutput.has(index)))
    return "The rewrite introduced an unsupported dictionary term.";
  const positiveInput = input.flatMap((token, index) => (!isNegative(token.word) ? [index] : []));
  const positiveOutput = output.flatMap((token, index) => (!isNegative(token.word) ? [index] : []));
  const positiveAlignment = alignment(
    positiveInput.map((index) => input[index]!),
    positiveOutput.map((index) => output[index]!),
    trusted,
  ).map(([i, j]): [number, number] => [positiveInput[i]!, positiveOutput[j]!]);
  for (let index = 0; index < inputNegatives.length; index++) {
    const sourceNegative = inputNegatives[index]!;
    const outputNegative = outputNegatives[index]!;
    const left = positiveAlignment.findLast((pair) => pair[0] < sourceNegative)?.[1] ?? -1;
    const right = positiveAlignment.find((pair) => pair[0] > sourceNegative)?.[1] ?? output.length;
    if (!(left < outputNegative && outputNegative < right))
      return "The rewrite moved a negation to different wording.";
  }
  const retained = new Set(aligned.map((pair) => pair[0]));
  for (const unit of answerUnits(original, input)) {
    if (!unit.length) continue;
    const minimum = unit.length <= 4 ? unit.length : Math.max(1, Math.ceil(unit.length * 0.5));
    if (unit.filter((index) => retained.has(index)).length < minimum)
      return "The rewrite removed an answer or sentence.";
  }
  return undefined;
}

function answerUnits(text: string, input: Token[]) {
  const markers = matches(markerPattern, text).map((match) => ({
    start: match.index,
    end: match.index + match[0].length,
  }));
  const result: number[][] = [];
  let current: number[] = [];
  for (let index = 0; index < input.length; index++) {
    const token = input[index]!;
    if (markers.some((marker) => intersects(marker, token))) continue;
    const previous = current.at(-1);
    if (previous !== undefined && token.start >= input[previous]!.end) {
      const gap = text.slice(input[previous]!.end, token.start);
      if (gap.includes("\n") || /[.!?](?:\p{White_Space}|["'’”])/u.test(gap)) {
        result.push(current);
        current = [];
      }
    }
    current.push(index);
  }
  if (current.length) result.push(current);
  return result;
}

function occurrenceStarts(phrase: string[], output: string[]) {
  if (!phrase.length || phrase.length > output.length) return [];
  const result: number[] = [];
  for (let index = 0; index <= output.length - phrase.length; index++) {
    if (phrase.every((word, offset) => word === output[index + offset]!)) result.push(index);
  }
  return result;
}

function touchesHyphen(range: Span, source: string) {
  return (
    (range.start > 0 && source[range.start - 1] === "-") ||
    (range.end < source.length && source[range.end] === "-")
  );
}

function isLocalizedRepair(
  abandoned: string[],
  replacement: string[],
  anchoredWordReplacement: boolean,
) {
  if (same(abandoned, replacement)) return false;
  if (anchoredWordReplacement && abandoned.length === 1 && replacement.length === 1) return true;
  const isQuantity = (word: string) => quantities.has(word) || /^\p{Nd}+$/u.test(word);
  if (abandoned.every(isQuantity) && replacement.every(isQuantity)) return true;
  const repeated = abandoned.filter((word) => !isNegative(word));
  return (
    repeated.length > 0 &&
    same(
      repeated,
      replacement.filter((word) => !isNegative(word)),
    ) &&
    !same(abandoned.filter(isNegative), replacement.filter(isNegative))
  );
}

function repairSpan(range: Span, source: string) {
  return {
    locationUTF16: range.start,
    lengthUTF16: range.end - range.start,
    text: prefixCharacters(source.slice(range.start, range.end), 512),
  };
}

function verifyRepairs(original: string, candidate: string) {
  const input = tokens(original);
  const output = words(candidate);
  const units = answerUnits(original, input);
  const removals: Span[] = [];
  const repairs: VerifiedTextRepair[] = [];
  const repairedUnits = new Set<number>();
  for (const match of repairCues(original)) {
    if (repairs.length >= 8) break;
    const cue = { start: match.index, end: match.index + match[0].length };
    if (touchesHyphen(cue, original)) continue;
    const firstCue = input.findIndex((token) => intersects(token, cue));
    const lastCue = input.findLastIndex((token) => intersects(token, cue));
    if (firstCue <= 0 || lastCue + 1 >= input.length) continue;
    const unitIndex = units.findIndex((unit) => unit.includes(firstCue));
    if (unitIndex < 0 || repairedUnits.has(unitIndex)) continue;
    const unit = units[unitIndex]!;
    const unitStart = unit[0]!;
    const unitEnd = unit[unit.length - 1]!;
    if (firstCue <= unitStart || lastCue >= unitEnd) continue;
    const beforeGap = original.slice(input[firstCue - 1]!.end, cue.start);
    const afterGap = original.slice(cue.end, input[lastCue + 1]!.start);
    if (!hasSeparator(beforeGap) || hasQuote(beforeGap) || hasQuote(afterGap)) continue;
    const cueWords = input.slice(firstCue, lastCue + 1).map((token) => token.word);
    if (!same(cueWords, ["i", "mean"]) && !hasSeparator(afterGap)) continue;
    let verified: [number, number] | undefined;
    for (
      let start = firstCue - 1;
      start >= Math.max(unitStart, firstCue - repairSpanLimit);
      start--
    ) {
      if (start > 0 && sameRange(input[start]!, input[start - 1]!)) continue;
      for (let end = lastCue + 1; end <= Math.min(unitEnd, lastCue + repairSpanLimit); end++) {
        if (end + 1 < input.length && sameRange(input[end]!, input[end + 1]!)) continue;
        const left = input.slice(Math.max(unitStart, start - 2), start).map((token) => token.word);
        const replacement = input.slice(lastCue + 1, end + 1).map((token) => token.word);
        const right = input
          .slice(end + 1, Math.min(unitEnd + 1, end + 3))
          .map((token) => token.word);
        if (
          !same(cueWords, ["i", "mean"]) &&
          !same(cueWords, ["correction"]) &&
          !isLocalizedRepair(
            input.slice(start, firstCue).map((token) => token.word),
            replacement,
            start > unitStart || end === unitEnd,
          )
        )
          continue;
        const expected = [...left, ...replacement, ...right];
        const positions = occurrenceStarts(expected, output).filter(
          (position) =>
            (start !== 0 || position === 0) &&
            (end + 1 !== input.length || position + expected.length === output.length),
        );
        if (positions.length !== 1) continue;
        verified = [start, end];
        break;
      }
      if (verified) break;
    }
    if (!verified) continue;
    const [start, end] = verified;
    const abandonedRange = { start: input[start]!.start, end: input[firstCue - 1]!.end };
    const replacementRange = { start: input[lastCue + 1]!.start, end: input[end]!.end };
    const removal = { start: abandonedRange.start, end: input[lastCue + 1]!.start };
    if (removals.some((range) => intersects(range, removal))) continue;
    removals.push(removal);
    repairs.push({
      abandoned: repairSpan(abandonedRange, original),
      cue: repairSpan(cue, original),
      replacement: repairSpan(replacementRange, original),
    });
    repairedUnits.add(unitIndex);
  }
  let protectedSource = original;
  for (const removal of removals.sort((a, b) => b.start - a.start)) {
    protectedSource = protectedSource.slice(0, removal.start) + protectedSource.slice(removal.end);
  }
  return { protectedSource: omittingVerifiedHesitations(protectedSource, candidate), repairs };
}

function omittingVerifiedHesitations(original: string, candidate: string) {
  const input = tokens(original);
  const output = words(candidate);
  const removals: Span[] = [];
  for (let index = 0; index < input.length; index++) {
    const token = input[index]!;
    if (!hesitations.has(token.word) || touchesHyphen(token, original)) continue;
    const start = index === 0 ? 0 : input[index - 1]!.end;
    const end = index + 1 === input.length ? original.length : input[index + 1]!.start;
    const before = original.slice(start, token.start);
    const after = original.slice(token.end, end);
    if (
      hasQuote(before) ||
      hasQuote(after) ||
      (index !== 0 && !hasSeparator(before)) ||
      (index !== 0 && index + 1 !== input.length && !hasSeparator(after))
    )
      continue;
    const left = input.slice(Math.max(0, index - 2), index).map((token) => token.word);
    const right = input
      .slice(index + 1, Math.min(input.length, index + 3))
      .map((token) => token.word);
    const expected = [...left, ...right];
    const occurrences = occurrenceStarts(expected, output).filter(
      (position) =>
        (index !== 0 || position === 0) &&
        (index + 1 !== input.length || position + expected.length === output.length),
    );
    if (occurrences.length === 1) removals.push(token);
  }
  let result = original;
  for (const range of removals.reverse())
    result = result.slice(0, range.start) + result.slice(range.end);
  return result;
}

function recognizedTerms(text: string, candidates: Set<string>) {
  const input = tokens(text);
  const preferred = [...candidates].filter((term) => characterCount(term, 3) >= 4).sort();
  const result: Token[] = [];
  let index = 0;
  while (index < input.length) {
    let joined = false;
    for (const width of [3, 2]) {
      if (index + width > input.length) continue;
      const fragments = input.slice(index, index + width);
      // Joining across a negation would delete it before the negation check ("not able" → Notable).
      if (
        !fragments.every((token) => characterCount(token.word, 1) >= 2 && !isNegative(token.word))
      )
        continue;
      if (
        !fragments.slice(1).every((right, offset) => {
          const left = fragments[offset]!;
          return right.start > left.end && /^[\t ]+$/u.test(text.slice(left.end, right.start));
        })
      )
        continue;
      const phrase = fragments.map((token) => token.word).join("");
      const term = preferred.find((term) => editDistance(phrase, term) <= 1);
      if (term === undefined) continue;
      result.push({ word: term, start: input[index]!.start, end: input[index + width - 1]!.end });
      index += width;
      joined = true;
      break;
    }
    if (!joined) result.push(input[index++]!);
  }
  return result;
}
