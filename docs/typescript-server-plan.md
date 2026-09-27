# Bun TypeScript server implementation plan

Keep the native Swift client and replace the packaged HTTP coordinator with TypeScript, Fastify, and a Bun executable. Preserve API v1, existing archive layout, text behavior, and native inference helpers. The reference Swift server and domain packages remain available for source comparison. Verification follows [the development guide](development.md); automated tests are not allowed.

## Phase 1: Contract and project foundation

- Add a root Bun workspace/package and pinned lockfile. All JavaScript dependency installation, scripts, static checks, and executable compilation use Bun.
- Define every implemented route and nested wire model in `Server/api/openapi.yaml` (OpenAPI 3.1), including Wispr Flow imports, binary float32 uploads, and full-record NDJSON events.
- Generate TypeScript types with `openapi-typescript`. Validate JSON at runtime using schemas from the same contract; semantic validation stays in the services.
- Generate public Swift transport types with Apple Swift OpenAPI Generator in a new `V07APIWire` target. Preserve existing client-facing DTO conveniences through typed bridges rather than changing SwiftUI callers.

```yaml
generate: [types]
accessModifier: public
namingStrategy: idiomatic
typeOverrides:
  schemas:
    UUID: Foundation.UUID
```

- Make Swift client's JSON/NDJSON transport consume the generated types. Preserve existing default decoding and conveniences (`isTerminal`, `audioSeconds`, dictionary validation). Verify UUID/date/optional/default round trips and compile the client without launching it.

## Phase 2: Deterministic domain port

- Port transcript cleanup, personal dictionary matching/validation, spoken lists, correction alignment and rejection guards, and continuation composition into pure TypeScript modules.
- Preserve UTF-16 diagnostic offsets, grapheme limits, canonical Unicode matching, non-cascading longest dictionary matches, byte limits, numeric/negation/answer preservation, and control-only continuation behavior.
- Use typed arrays for bounded alignment storage and move expensive text work off the HTTP event loop where needed.
- Compare the Swift and TypeScript implementations and verify output text, status, spans, continuation, and rejection decisions by using the native app.

## Phase 3: Native inference and durable coordinator

- Supervise existing Whisper and Qwen helpers with fixed argument arrays, bounded JSON-lines parsing, one outstanding request per helper, readiness, warm reuse, deadlines, output validation, and stale-process generation guards.
- Preserve pinned model verification, optional proofreading fallback, and cancellation by terminating/replacing busy helpers. Preserve idle warm helpers on cancellation.
- Port generation admission, per-device request idempotency, preference compare-and-swap revisions, chunk sequence/replay validation, finite samples, exact final frame counts, WAV sealing, disk checks, and serial FIFO processing.
- Keep private file permissions, exclusive directory ownership, atomic metadata writes, paginated shared history, allowlisted artifacts, restart recovery, upload expiry, and Wispr Flow staging/reconciliation.

## Phase 4: Fastify HTTP and executable packaging

- Preserve HTTP paths/status/error shapes and authentication, tokenless loopback Host validation, Origin rejection, body limits, and diagnostics that omit user text.
- Stream bounded NDJSON subscriptions with current state, updates, two-second heartbeats, terminal completion, and slow-consumer backpressure. A subscriber disconnect does not cancel completed uploads.
- Compile standalone Bun coordinators for macOS arm64, Linux x64, and Linux arm64. Disable compiled executable dotenv/bunfig autoloading. Cross compilation covers the coordinator; native helpers must be built on the matching platform.
- Update full server packaging to retain native helpers, VAD, licenses, and Mac MLX bundles/Metal library. Preserve Bun's required Mac signing entitlements. Models and personal data remain outside packages.
- Add CPU/CUDA container builds and CI for Bun checks, contract generation, Swift compatibility, standalone executable builds, and platform artifacts.

## Phase 5: Isolated verification, review, and PR

- Use port 8392 and a new `.local/typescript-server` data directory for development. Never invoke the client dev runner or operate the installed server at port 8391 or its data directory.
- Run `bun run check`, `bun run lint`, and `bun run fmt:check`. Compile the Swift client and standalone coordinator, then verify changed behavior with computer use and real inference where model/device access is available. Do not add automated tests.
- Have two independent agents review correctness/security and API/domain/build parity. Fix material findings and re-run relevant checks.
- Commit all implementation changes on `codex/bun-typescript-server`, push, open a PR, and monitor CI/bot reviews until green and conflict-free. Leave the isolated server available and report its endpoint and limitations.

## Intended result

- Bun-managed Fastify server and standalone coordinators for the supported platforms.
- Full v1 contract with generated TypeScript and Swift transport models.
- Native Swift client behavior, native model helpers, and archive compatibility preserved.
- Isolated verified draft, independent reviews, committed branch, and a green PR.
