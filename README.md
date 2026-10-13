# Inlay

Hold a key, speak, and release to insert your dictation. Inlay is a native Swift macOS app backed by a Bun-compiled TypeScript/Fastify model server running on the same Mac, another Mac, or Linux. Audio uploads while you speak; the server returns progress and one finished transcript. You can start another take immediately: finished recordings queue on the server, and each result returns to its originating client for delivery.

The dev runner builds **Inlay Dev**, with separate settings and visible Dev labels. For the regular app, run `./scripts/build-app.sh` and install `build/Inlay.app` in Applications. Both connect to an independently running server.

## Get started on one Mac

The app runs on Apple Silicon and macOS 14 or later. `Package.swift` and `LSMinimumSystemVersion` both set that floor to 14.0. Building requires a Mac: `scripts/build-app.sh` exits on Linux and other systems. The build needs full Xcode 26 or later, including the Metal compiler, because the client and the MLX helper require Swift 6.2+. You also need Bun 1.4.2, CMake, and Git. Xcode provides Swift. Bun manages JavaScript dependencies and builds standalone server executables. Linux can build and run the server; it cannot build `Inlay.app`.

```sh
git clone --recurse-submodules https://github.com/davis7dotsh/inlay.git
cd inlay
```

[Download the pinned Parakeet and Qwen models](Server/README.md#models) into `.local/models`, then build and start:

```sh
export INLAY_SPEECH_MODEL="$PWD/.local/models/ggml-parakeet-tdt-0.6b-v3-f16.bin"
export INLAY_TEXT_MODEL="$PWD/.local/models/Qwen3-4B-Instruct-2507-MLX-4bit"
./scripts/run-dev.sh
```

Use your own model paths if they are already installed. The script builds the server and client, starts **http://localhost:8391**, and opens `build/Inlay Dev.app`. The first build fetches dependencies and the small Silero speech detector.

1. Grant **Inlay Dev** Microphone and Accessibility. The window treats those two as required. Accessibility also listens for the dictation key, so do not add a separate Input Monitoring grant. Microphone is under **System Settings → Privacy & Security → Microphone**. Accessibility is under **Privacy & Security → Accessibility**, except on macOS 27 and later, where that list is **Privacy & Security → Device Control and Data Access**. If the server is on another machine, allow **Local Network** when macOS asks.
2. Wait for the server to be ready. Focus a text field, hold **Right Option**, speak, and release.
3. Change the shortcut under **This Mac**, choose inputs under **Microphone**, and edit shared cleanup instructions or dictionary entries under **Server preferences**.

**Test microphone** shows a result in Inlay without inserting it. Fn/Globe is also supported; set macOS **Keyboard → Press Globe key to → Do Nothing** if its system action conflicts.

## Use a server on another machine

Follow the [server guide](Server/README.md) for macOS, Linux, or containers. On the client Mac, build and open only the app:

```sh
./scripts/build-app.sh
open "build/Inlay.app"
```

Set its URL and token under **This Mac**. Use HTTPS for remote hosts, or HTTP with the server's literal Tailscale IP on your connected tailnet. The client needs no model weights or GPU for inference.

## Upgrade an existing installation

- Rebuild the client, server, and native helpers. Update service definitions and launch scripts for `Inlay.app`, `inlay-server`, `inlay-engine`, and `inlay-text-engine`; replace the former environment-variable prefix with `INLAY_`.
- Update the client and server together. Inlay reports API version 2 because the native-history filter is now `source=inlay`; clients reject a server with a different API version.
- The regular app now uses `~/Library/Application Support/Inlay`; Dev uses `~/Library/Application Support/Inlay Dev`. With both clients quit, copy your existing `config.json` and `client.json` into the corresponding new directory to retain device settings and identity. A custom `INLAY_CLIENT_DATA_DIR` can continue using the existing client directory. The packaged dev runner's `.local/client` directory is unchanged.
- Re-enter the server token under **This Mac**. Release and Dev credentials use separate Keychain services, `dev.davis.inlay.server` and `dev.davis.inlay.dev.server`, scoped to the client directory and endpoint. Grant **Inlay** or **Inlay Dev** Microphone and Accessibility permissions for the new app identity, and enable launch at login again if desired.
- Retain the existing server archive with `--data-dir` or `INLAY_SERVER_DATA_DIR`, and keep the same token file. Back up the archive before switching servers and stop the previous server before opening that archive with the new executable. History and shared preferences retain their existing format; the default workspace archives are unchanged. Container upgrades must mount the existing data volume rather than create an empty one under the new example name.
- Replace the speech model: the old Whisper file fails the Parakeet pin. Run `scripts/download-model.sh`, then set `INLAY_SPEECH_MODEL` to the full path of the downloaded `ggml-parakeet-tdt-0.6b-v3-f16.bin`, and delete the old `ggml-large-v3-turbo.bin` if desired. Keep the installed Qwen model in place and set `INLAY_TEXT_MODEL` to its existing path. The Mac runner's default model locations now use the Inlay name; explicit overrides preserve models installed under older directories.

## Daily development

For server edits on macOS or Linux, install dependencies once and run the source with hot reload:

```sh
bun install --frozen-lockfile
bun run dev
```

This listens on `0.0.0.0:8392`, uses `.local/dev-server/data`, and creates a private token file at `.local/dev-server/token`. Build the native helpers once with `./scripts/build-server.sh` for dictation. On macOS, export the Parakeet and MLX paths from the Mac setup above. On Linux, keep the Parakeet path and point `INLAY_TEXT_MODEL` at the GGUF file instead:

```sh
export INLAY_SPEECH_MODEL="$PWD/.local/models/ggml-parakeet-tdt-0.6b-v3-f16.bin"
export INLAY_TEXT_MODEL="$PWD/.local/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
```

The MLX directory does not run on Linux. If those variables are unset, `bun run dev` looks under `~/Library/Application Support/Inlay/Models` and `~/.inlay/models` on macOS, and under `.local/dev-server/models` on Linux. Without helpers or models, the server still starts and health reports unavailable inference. On the same Mac, open [server health](http://localhost:8392/v1/health).

```sh
bun run fmt
bun run fmt:check
bun run lint
bun run check
```

Automated tests are not allowed. Verify behavior by using **Inlay Dev** through computer use; this is a native Mac app, so the browser health endpoint alone cannot verify dictation or insertion. See [the development guide](docs/development.md) for setup and verification.

For the packaged Mac app and server:

```sh
./scripts/run-dev.sh start --skip-build   # Start existing builds
./scripts/run-dev.sh status
./scripts/run-dev.sh stop
./scripts/run-dev.sh restart             # Rebuild the server and Mac client, then restart
```

Keep `INLAY_SPEECH_MODEL` and `INLAY_TEXT_MODEL` set when starting the server. On Linux, `INLAY_TEXT_MODEL` must be the GGUF file, and `run-dev.sh` builds and starts the server without the app. After rebuilding an already-open client, quit and reopen it to load the new executable. `scripts/build-app.sh` signs with `INLAY_SIGNING_IDENTITY` when that is set. Otherwise it uses the Apple Development identity only when exactly one is installed, and ad-hoc signs in every other case. Ad-hoc rebuilds may require granting permissions again. Neither path notarizes the app.

The dev runner stores shared history/settings in `.local/server`, device preferences in `.local/client`, and logs in `.local/server.log`. Keep experiment notes and generated artifacts under the ignored `.local/` directory too. Quitting the app leaves the server running. Recordings require an online, available server and have a three-minute limit.

For newly launched Electron apps, Inlay requests accessibility support when a take begins and checks for an editable field for up to three seconds while recording starts independently. The field must become verifiable before you release the key; a short first take or slow renderer can still use the clipboard fallback. Unsupported native apps do not wait for this preparation. Enabling an Electron accessibility tree can increase that app's memory and CPU use for its lifetime; Inlay leaves it enabled so other assistive tools can continue using it. This activation mechanism is specific to Electron; Chrome fields use their existing accessibility support.

All connected Macs share history, tagged by device. Both original and inference audio are kept by default; **Keep original microphone audio** changes original retention for future takes. Back up the server data directory to preserve history.

## Releases

Nothing in this repository publishes a GitHub Release or a downloadable `Inlay.app`. Build the Mac app locally with `./scripts/build-app.sh` and copy `build/Inlay.app` where you want it. Server tarballs are Actions artifacts from the `Server release packages` workflow, produced by a `server-v*` tag or a manual run. Pull-request CI does not build the Mac app, the MLX helper, or the CUDA package. Details, artifact names, and checksums are in [how releases are produced](Server/README.md#releases).

## Reference

- [Server setup and models](Server/README.md)
- [Architecture, configuration, and storage](docs/architecture.md)
- [Dictionary and cleanup instructions](docs/text-correction.md)
- [HTTP API](docs/client-server-contract.md)
- [Parakeet helper](Engine/README.md) and [Qwen helpers](TextEngine/README.md)

[MIT](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
