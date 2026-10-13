# TypeScript server verification

- Run `bun run check` for strict TypeScript and generated TypeScript/OpenAPI consistency, `bun run lint` for type-aware correctness, and `bun run fmt:check` for formatting.
- Verify generated Swift bindings with `bun run generate:api --check` and compile with `swift build --force-resolved-versions` on macOS with Swift 6.2+. Pull-request CI compiles the Swift packages on `macos-26` (that `swift build` does not build the MLX helper or `Inlay.app`), Bun coordinators for Apple Silicon and Linux, and complete Linux CPU packages. The Mac server package and the CUDA package are built only by [the release workflow](../Server/README.md#releases).
- Start an isolated source instance with `bun run dev` and follow [the development guide](development.md) to verify changed behavior with computer use in **Inlay Dev**. Automated tests, fixtures, and smoke harnesses are not allowed.
- Native helpers, Metal assets, and pinned model weights are required for real dictation. A reachable health endpoint with `ready: false` proves only that the HTTP server is running.
- Linux packages target Ubuntu 24.04 or compatible glibc environments; the x64 coordinator uses Bun's baseline CPU target. CUDA, macOS signing/notarization, and native UI behavior require verification on suitable hardware with the necessary credentials.
