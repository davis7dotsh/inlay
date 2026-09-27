# V07

Hold a key, speak, and release to insert your dictation. V07 is a native Swift macOS app backed by a Bun-compiled TypeScript/Fastify model server running on the same Mac, another Mac, or Linux. Audio uploads while you speak; the server returns progress and one finished transcript. You can start another take immediately: finished recordings queue on the server, and each result returns to its originating client for delivery.

The dev runner builds **V07 Dev**, with separate settings and visible Dev labels. For the regular app, run `./scripts/build-app.sh` and install `build/V07.app` in Applications. Both connect to an independently running server.

Upgrading from an earlier project name: rebuild both client and server, update environment variables to the `V07_` prefix, and grant the renamed app its macOS permissions. V07 uses new application-support directories and Keychain services; copy your existing client settings into the corresponding V07 directory if needed, then re-enter your server token. Keep the server pointed at its existing data directory to retain history and shared preferences. Model files can stay where they are; set `V07_SPEECH_MODEL` and `V07_TEXT_MODEL` to their paths.

## Get started on one Mac

You need Apple Silicon, macOS 14+, full Xcode 26+ with the Metal compiler, Bun 1.4.2, CMake, and Git. Xcode provides Swift; the client/MLX build requires Swift 6.2+. Python 3 is only needed for the test scripts. Bun manages JavaScript dependencies and builds standalone server executables.

```sh
git clone --recurse-submodules https://github.com/davis7dotsh/v07.git
cd v07
```

[Download the pinned Parakeet and Qwen models](Server/README.md#models) into `.local/models`, then build and start:

```sh
export V07_SPEECH_MODEL="$PWD/.local/models/ggml-parakeet-tdt-0.6b-v3-f16.bin"
export V07_TEXT_MODEL="$PWD/.local/models/Qwen3-4B-Instruct-2507-MLX-4bit"
./scripts/run-dev.sh
```

Use your own model paths if they are already installed. The script builds the server and client, starts **http://localhost:8391**, and opens `build/V07 Dev.app`. The first build fetches dependencies and the small Silero speech detector.

1. Grant **V07 Dev** Microphone and Accessibility permissions.
2. Wait for the server to be ready. Focus a text field, hold **Right Option**, speak, and release.
3. Change the shortcut under **This Mac**, choose inputs under **Microphone**, and edit shared cleanup instructions or dictionary entries under **Server preferences**.

**Test microphone** shows a result in V07 without inserting it. Fn/Globe is also supported; set macOS **Keyboard → Press Globe key to → Do Nothing** if its system action conflicts.

## Use a server on another machine

Follow the [server guide](Server/README.md) for macOS, Linux, or containers. On the client Mac, build and open only the app:

```sh
./scripts/build-app.sh
open "build/V07.app"
```

Set its URL and token under **This Mac**. Use HTTPS for remote hosts, or HTTP with the server's literal Tailscale IP on your connected tailnet. The client needs no model weights or GPU for inference.

## Daily development

```sh
./scripts/run-dev.sh start --skip-build   # Start existing builds
./scripts/run-dev.sh status
./scripts/run-dev.sh stop
./scripts/run-dev.sh restart             # Rebuild and restart the server
swift test
./scripts/smoke-test.sh                  # Real HTTP/audio test; server must be idle
./scripts/test-corrections.sh            # Real Qwen helper checks
```

Keep the model-path exports set when starting the server or running helper checks. After rebuilding an already-open client, quit and reopen it to load the new executable. Signing uses an available Apple Development identity or ad-hoc signing; ad-hoc rebuilds may require granting permissions again.

The dev runner stores shared history/settings in `.local/server`, device preferences in `.local/client`, and logs in `.local/server.log`. Keep experiment notes and generated artifacts under the ignored `.local/` directory too. Quitting the app leaves the server running. Recordings require an online, available server and have a three-minute limit.

For newly launched Electron apps, V07 requests accessibility support when a take begins and checks for an editable field for up to three seconds while recording starts independently. The field must become verifiable before you release the key; a short first take or slow renderer can still use the clipboard fallback. Unsupported native apps do not wait for this preparation. Enabling an Electron accessibility tree can increase that app's memory and CPU use for its lifetime; V07 leaves it enabled so other assistive tools can continue using it. This activation mechanism is specific to Electron; Chrome fields use their existing accessibility support.

All connected Macs share history, tagged by device. Both original and inference audio are kept by default; **Keep original microphone audio** changes original retention for future takes. Back up the server data directory to preserve history.

## Reference

- [Server setup and models](Server/README.md)
- [Architecture, configuration, and storage](docs/architecture.md)
- [Dictionary and cleanup instructions](docs/text-correction.md)
- [HTTP API](docs/client-server-contract.md)
- [Parakeet helper](Engine/README.md) and [Qwen helpers](TextEngine/README.md)

[MIT](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
