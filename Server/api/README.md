# Inlay API contract

`openapi.yaml` is the transport contract for the TypeScript server and Swift client,
including JSON models, float32 audio chunks, artifact uploads/downloads, Wispr Flow
imports, and NDJSON generation updates.

From the repository root:

```sh
bun install --frozen-lockfile
bun run generate:api
bun run generate:api --check
```

Generation uses `openapi-typescript` from the Bun lockfile and Apple Swift OpenAPI
Generator 1.13.1 at a pinned Git revision. Its transitive Swift tooling dependencies
are recorded in `swift-generator.Package.resolved`. The complete Swift package
requires Swift 6.2 or newer.
The generator checkout lives under `.build`; normal client builds use committed
sources and only depend on the pinned Swift OpenAPI runtime.

TypeScript transport types live in `Server/src/generated/api.ts` and are generated
with the repository's Prettier configuration so formatting does not change the
generation drift check. The public aliases
in `Server/src/api.ts` make defaults required after archive/request normalization.
Swift transport types live in `Sources/InlayAPIWire`; `InlayAPI.APIWireModel` bridges
them to the existing public Swift models while retaining dictionary validation,
default preferences, and conveniences used by the app. The client retains its
existing URLSession transport and bounded NDJSON parser.

Optional values are normally omitted. Timestamps use whole-second UTC ISO8601.
UUID components generate `Foundation.UUID` in Swift. UTF-16 diagnostic offsets retain
their original units. The server separately enforces byte budgets, Unicode grapheme
limits, cross-field audio constraints, and dictionary spelling uniqueness that JSON
Schema alone cannot express.
