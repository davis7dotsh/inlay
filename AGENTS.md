# Repository instructions

- At the end of any turn that adds, edits, or deletes TypeScript files, run `bun run fmt` from the repository root after the final code edits and before committing or responding.
- Automated tests are not allowed: do not add, restore, or run unit, integration, end-to-end, snapshot, smoke, or regression suites; test fixtures, mocks, runners, and scripted behavioral assertion harnesses are also prohibited.
- Use `bun run check` for strict TypeScript and generated API consistency, `bun run lint` for type-aware correctness, and `bun run fmt:check` for formatting. Fix failures rather than weakening checks or adding blanket suppressions. Unicode scalar iteration is intentional; the lint configuration allows spreading strings.
- Verify runtime behavior with computer use against a development instance. Inlay is a native macOS app, not a web app: use **Inlay Dev** for dictation, preferences, history, and insertion. A browser visit to `/v1/health` only verifies server reachability and reported readiness.
- Start the source server with `bun install --frozen-lockfile` then `bun run dev`. It hot reloads on `0.0.0.0:8392`, isolates data under `.local/dev-server/data`, and creates a private token file. Build native helpers and configure model paths for dictation; never substitute fake inference to claim verification.
- Follow [docs/development.md](docs/development.md) for Mac setup and computer-use verification. Keep existing servers, recordings, and user settings intact; report unavailable model or device verification explicitly.
- When changing Swift or the API, verify generated Swift bindings and compile the Swift packages on macOS with Swift 6.2+. Native engine changes require compiling the affected helper. Build checks are allowed; automated behavioral tests are not.
- Vendored submodules are upstream dependencies. Leave their contents intact; Inlay's CMake configurations disable their test targets.
