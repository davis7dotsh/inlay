# Dictionary and cleanup

The server processes each complete take in this order: Parakeet → mechanical cleanup → dictionary → list formatting → optional Qwen → dictionary → rewrite validation → composition. The Mac receives a finished result for insertion. Models and installation are covered in the [server guide](../Server/README.md#models).

## Dictionary and vocabulary

Edit **Server preferences**, then **Save shared preferences**. All dictionary lists are active. Each generation freezes the settings when the server accepts it; later edits apply to future takes.

- Preferred spellings normalize case. Explicit aliases replace whole words or phrases, such as `mini max → MiniMax`. Longer matches win, and replacements do not cascade.
- Use narrow aliases like `off middleware → auth middleware`; a broad `off → auth` also changes legitimate “turn off.”
- Star priority terms to suggest them to Qwen first. Parakeet does not support recognition vocabulary prompts; history reports those terms as unused with a zero token budget. Dictionary replacements and Qwen’s bounded hint budget still apply.
- Saved recognition vocabulary remains in existing settings for compatibility, but Parakeet does not consume it. Use dictionary rules for deterministic replacements and dictionary names for Qwen cleanup.
- The initial Personal list contains MiniMax and Codex. You can delete them or save an empty dictionary. There is no automatic learning from edits or history.

## Cleanup instructions

The shared **Cleanup instructions** field is the Qwen system prompt. Its default has four freely editable sections: Cleanup, Spoken corrections, Preserve, and Output. It keeps intentional “like,” repetition, answers, numbers, and negations, while allowing explicit spoken corrections. Examples distinguish “42, sorry, 24” from a contrast such as “42, not 24.” It also forbids translation and added information.

**Reset to default** loads a draft; **Save shared preferences** applies it to future takes across clients. Existing custom prompts remain unchanged until edited or reset. Disabling **Proofread with Qwen** keeps the deterministic dictionary/list result, including fillers.

The prompt guides Qwen; it cannot bypass the validation rules below.

## Preservation checks

- List formatting preserves standalone numeric answers and spoken numbering, including resumed, skipped, repeated, or out-of-order numbers. Qwen cannot create or advance list continuation state.
- Cleanup rejects changed list markers, unsupported dictionary names, lost answers, changed quantities/negations, excessive wording changes, and model control tokens or response preambles.
- Explicit corrections can remove an abandoned phrase only when bounded alignment verifies the cue and replacement. Ambiguous apologies or clause restarts can fall back to the source. Unrelated wording remains protected.
- Near-spelling and supported split-name corrections can pass; more ambiguous names should use explicit aliases. This conservative matching prevents a dictionary hint from licensing an invented name.

Rejected, unavailable, or failed proofreading keeps the already-cleaned, dictionary-corrected, list-formatted source. History records raw text, the proposed/accepted cleanup, its outcome/reason, verified corrections, and model details. See [storage](architecture.md#storage).

The checks do not prove identical meaning. Parakeet can omit words; Qwen can mishandle homophones or instructions. The proofreader receives the current dictated chunk, language, preferred terms, and cleanup prompt—not surrounding documents, clipboard contents, or screenshots.

## Limits and testing

The prompt limit is 4,096 UTF-8 bytes. Qwen input is capped at 6,000 characters; its context is 8,192 tokens with 2,048 reserved for output. Oversized text, vocabulary, or validation work skips/rejects cleanup instead of accepting truncated output. The [helper protocol](../TextEngine/README.md) lists lower-level bounds.

Run `swift test` for dictionary/validation tests and `scripts/test-corrections.sh` for the real packaged Qwen helper. To test the built-in default directly, pass `--server build/server/v07-server` to either Python helper harness. An explicit `--prompt FILE` preserves the file's contents, including trailing newlines. A redirected CLI prompt export includes an extra delimiter newline; use `--server` to avoid accidentally testing different prompt bytes.

## Open question: omitted negations

Audio rechecking is deferred. A text-only cleanup model cannot recover a negation that Parakeet never transcribed, and repeating the same decode is not independent verification.

Before adding a verification mode, benchmark human-recorded positive/negative pairs and difficult short answers. Compare baseline recognition with alternate settings and audio crops; measure omissions, invented negations, answer recall, and p50/p95 latency. Ship a mode only if the measured benefit justifies the added delay and false corrections. No current setting guarantees every omitted word is caught.
