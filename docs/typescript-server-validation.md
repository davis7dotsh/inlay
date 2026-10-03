# TypeScript server verification

- Run `bun run check` for strict TypeScript and generated TypeScript/OpenAPI consistency, `bun run lint` for type-aware correctness, and `bun run fmt:check` for formatting.
- Verify generated Swift bindings with `bun run generate:api --check` and compile with `swift build --force-resolved-versions` on macOS with Swift 6.2+. CI also compiles standalone coordinators and complete CPU packages for supported platforms.
- Start an isolated source instance with `bun run dev` and follow [the development guide](development.md) to verify changed behavior with computer use in **Inlay Dev**. Automated tests, fixtures, and smoke harnesses are not allowed.
- Native helpers, Metal assets, and pinned model weights are required for real dictation. A reachable health endpoint with `ready: false` proves only that the HTTP server is running.
- Linux packages target Ubuntu 24.04 or compatible glibc environments; the x64 coordinator uses Bun's baseline CPU target. CUDA, macOS signing/notarization, and native UI behavior require verification on suitable hardware with the necessary credentials.
