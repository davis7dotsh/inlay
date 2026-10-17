import type { DictionaryEntry, DictionaryList, PersonalDictionary } from "../api.ts";

export const maximumDictionaryEntries = 500;
export const defaultDictionary: PersonalDictionary = {
  lists: [
    {
      id: "personal",
      name: "Personal",
      entries: [
        { id: "minimax", term: "MiniMax", aliases: [], isPriority: false },
        { id: "codex", term: "Codex", aliases: [], isPriority: false },
      ],
    },
  ],
};

const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });
const whitespace = /^[\p{White_Space}\u200B]+|[\p{White_Space}\u200B]+$/gu;
const trim = (text: string) => text.replace(whitespace, "");
const validText = (text: string, limit: number) =>
  text.length > 0 &&
  [...graphemes.segment(text)].length <= limit &&
  text === trim(text) &&
  !/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(text);

/** Unicode default case folding, including expanding folds (ß, ligatures).
 * Upper-then-lower supplies expanding mappings; Unicode's exceptional folds
 * preserve dotless i and uppercase Cherokee, and expand capital sharp s.
 */
export function caseFold(text: string) {
  return [...text]
    .map((character) => {
      const scalar = character.codePointAt(0)!;
      if (character === "ı") return character;
      if (character === "ẞ") return "ss";
      if (
        (scalar >= 0x13a0 && scalar <= 0x13f5) ||
        (scalar >= 0x13f8 && scalar <= 0x13fd) ||
        (scalar >= 0xab70 && scalar <= 0xabbf)
      )
        return character.toUpperCase();
      return character.toUpperCase().toLowerCase();
    })
    .join("");
}

export function dictionaryKey(text: string) {
  return caseFold(text).normalize("NFC");
}

export function dictionaryEntryValidationError(entry: DictionaryEntry) {
  if (!validText(entry.id, 128))
    return "Each dictionary word needs a nonempty id of at most 128 characters.";
  if (!validText(entry.term, 128))
    return "Dictionary words must be single-line, nonempty text of at most 128 characters, without surrounding whitespace.";
  if (entry.aliases.length > 8) return "Each dictionary word can have up to 8 corrections.";
  const seen = new Set([dictionaryKey(entry.term)]);
  for (const alias of entry.aliases) {
    if (!validText(alias, 128))
      return "Corrections must be single-line, nonempty text of at most 128 characters, without surrounding whitespace.";
    const key = dictionaryKey(alias);
    if (seen.has(key))
      return `Corrections for ${entry.term} must be unique and different from its preferred spelling. Capitalization is corrected automatically.`;
    seen.add(key);
  }
  return undefined;
}

export function dictionaryListValidationError(list: DictionaryList) {
  if (!validText(list.id, 128))
    return "Each dictionary list needs a nonempty id of at most 128 characters.";
  if (!validText(list.name, 80))
    return "Dictionary list names must be single-line, nonempty text of at most 80 characters, without surrounding whitespace.";
  if (list.entries.length > maximumDictionaryEntries)
    return `The dictionary can contain up to ${maximumDictionaryEntries} words in total.`;
  if (new Set(list.entries.map((entry) => entry.id.normalize("NFC"))).size !== list.entries.length)
    return "Dictionary word ids must be unique.";
  return list.entries.map(dictionaryEntryValidationError).find((error) => error !== undefined);
}

export function dictionaryValidationError(dictionary: PersonalDictionary) {
  if (dictionary.lists.length > 32) return "The dictionary can contain up to 32 lists.";
  if (
    new Set(dictionary.lists.map((list) => list.id.normalize("NFC"))).size !==
    dictionary.lists.length
  )
    return "Dictionary list ids must be unique.";
  const listError = dictionary.lists
    .map(dictionaryListValidationError)
    .find((error) => error !== undefined);
  if (listError !== undefined) return listError;
  const entries = dictionary.lists.flatMap((list) => list.entries);
  if (entries.length > maximumDictionaryEntries)
    return `The dictionary can contain up to ${maximumDictionaryEntries} words in total.`;
  if (new Set(entries.map((entry) => entry.id.normalize("NFC"))).size !== entries.length)
    return "Dictionary word ids must be unique across all lists.";
  const spellings = new Map<string, string>();
  for (const entry of entries) {
    for (const spelling of [entry.term, ...entry.aliases]) {
      const key = dictionaryKey(spelling);
      const existing = spellings.get(key);
      if (existing !== undefined && existing.normalize("NFC") !== entry.term.normalize("NFC")) {
        return `${spelling} maps to both ${existing} and ${entry.term}. Each spelling can have only one preferred word across all lists.`;
      }
      spellings.set(key, entry.term);
    }
  }
  return undefined;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

/** Keep Swift's strict decoding and legacy defaults, returning errors as values. */
export function decodePersonalDictionary(
  value: unknown,
): { value: PersonalDictionary; error?: never } | { error: string; value?: never } {
  if (!isRecord(value) || !Array.isArray(value.lists))
    return { error: "Dictionary lists must be an array." };
  const lists: DictionaryList[] = [];
  for (const list of value.lists) {
    if (
      !isRecord(list) ||
      typeof list.id !== "string" ||
      typeof list.name !== "string" ||
      ("entries" in list && !Array.isArray(list.entries))
    )
      return { error: "Dictionary lists need string ids, names, and an entries array." };
    const entries: DictionaryEntry[] = [];
    for (const entry of (list.entries ?? []) as unknown[]) {
      if (
        !isRecord(entry) ||
        typeof entry.id !== "string" ||
        typeof entry.term !== "string" ||
        ("aliases" in entry &&
          (!Array.isArray(entry.aliases) ||
            !entry.aliases.every((alias) => typeof alias === "string"))) ||
        ("isPriority" in entry && typeof entry.isPriority !== "boolean")
      ) {
        return {
          error:
            "Dictionary words need string ids, terms, string corrections, and a boolean priority flag.",
        };
      }
      entries.push({
        id: entry.id,
        term: entry.term,
        aliases: (entry.aliases ?? []) as string[],
        isPriority: (entry.isPriority ?? false) as boolean,
      });
    }
    lists.push({ id: list.id, name: list.name, entries });
  }
  const dictionary = { lists };
  const error = dictionaryValidationError(dictionary);
  return error === undefined ? { value: dictionary } : { error };
}

function uniqueTerms(terms: string[]) {
  const seen = new Set<string>();
  return terms.filter((term) => {
    const key = dictionaryKey(term);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function dictionaryVocabularyTerms(dictionary: PersonalDictionary) {
  if (dictionaryValidationError(dictionary) !== undefined) return [];
  const entries = dictionary.lists.flatMap((list) => list.entries);
  return uniqueTerms(
    [
      ...entries.filter((entry) => entry.isPriority),
      ...entries.filter((entry) => !entry.isPriority),
    ].map((entry) => entry.term),
  );
}

export const vocabularyTerms = dictionaryVocabularyTerms;

const escapePattern = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Match original graphemes once. Folded text retains an offset map, so canonical
 * forms and expanding case folds match without normalizing surrounding prose.
 */
export function applyDictionary(
  dictionary: PersonalDictionary,
  text: string,
  maximumOutputUTF8Bytes?: number,
) {
  if (text.length === 0 || dictionaryValidationError(dictionary) !== undefined) return text;
  const replacements = new Map<string, string>();
  for (const entry of dictionary.lists.flatMap((list) => list.entries)) {
    for (const spelling of [entry.term, ...entry.aliases])
      replacements.set(dictionaryKey(spelling), entry.term);
  }
  if (replacements.size === 0) return text;
  const alternatives = [...replacements.keys()]
    .sort((left, right) => right.length - left.length || (left < right ? -1 : left > right ? 1 : 0))
    .map(escapePattern)
    .join("|");
  const word = "[\\p{L}\\p{M}\\p{N}\\p{Pc}\\u200C\\u200D]";
  const pattern = new RegExp(`(?<!${word})(?:${alternatives})(?!${word})`, "gu");
  const boundaries = new Map<number, number>([[0, 0]]);
  const foldedParts: string[] = [];
  let foldedLength = 0;
  for (const segment of graphemes.segment(text)) {
    const folded = dictionaryKey(segment.segment);
    foldedParts.push(folded);
    foldedLength += folded.length;
    boundaries.set(foldedLength, segment.index + segment.segment.length);
  }
  const foldedText = foldedParts.join("");
  const result: string[] = [];
  let outputBytes = 0;
  let cursor = 0;
  let matched = false;
  for (const match of foldedText.matchAll(pattern)) {
    const lower = boundaries.get(match.index);
    const upper = boundaries.get(match.index + match[0].length);
    const replacement = replacements.get(match[0]);
    if (lower === undefined || upper === undefined || replacement === undefined) continue;
    const unchanged = text.slice(cursor, lower);
    outputBytes += Buffer.byteLength(unchanged) + Buffer.byteLength(replacement);
    if (maximumOutputUTF8Bytes !== undefined && outputBytes > maximumOutputUTF8Bytes) return text;
    result.push(unchanged, replacement);
    cursor = upper;
    matched = true;
  }
  if (!matched) return text;
  const remaining = text.slice(cursor);
  if (
    maximumOutputUTF8Bytes !== undefined &&
    outputBytes + Buffer.byteLength(remaining) > maximumOutputUTF8Bytes
  )
    return text;
  result.push(remaining);
  return result.join("");
}
