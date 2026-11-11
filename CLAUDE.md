# Repository instructions

- Follow [AGENTS.md](AGENTS.md) and [docs/development.md](docs/development.md).
- No automated tests are allowed, including unit, integration, end-to-end, snapshot, smoke, or regression suites, fixtures, mocks, runners, and scripted behavioral assertion harnesses.
- Validate static changes with `bun run check`, `bun run lint`, and `bun run fmt:check`; run `bun run fmt` after the final TypeScript edits.
- Verify behavior with computer use in **Inlay Dev** against an isolated development server. Start the source server with `bun run dev`; use the native Mac app for dictation and insertion. Report unavailable model/device verification honestly.
