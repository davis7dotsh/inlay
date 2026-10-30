import { evaluateCorrection } from "./correction.ts";

self.onmessage = (
  event: MessageEvent<{
    original: string;
    candidate: string;
    dictionaryTerms: string[];
    screenTerms: string[];
  }>,
) => {
  const { original, candidate, dictionaryTerms, screenTerms } = event.data;
  self.postMessage(evaluateCorrection(original, candidate, dictionaryTerms, screenTerms));
};
