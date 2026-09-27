# Development

- Install Bun 1.4.2 and run `bun install --frozen-lockfile` from the repository root.
- Run `bun run fmt`, `bun run fmt:check`, `bun run lint`, and `bun run check`. The last command checks strict TypeScript and generated TypeScript/OpenAPI consistency. Lint includes type-aware correctness and promise handling; warnings fail the command.
- Automated tests are not allowed. Do not add suites, test dependencies, fixtures, mocks, or assertion harnesses. CI runs static checks, generated API verification, and compilation/packaging.

## Source server

```sh
bun run dev
```

- Bun reloads source changes. Stop this foreground instance with Ctrl-C.
- The default listener is `0.0.0.0:8392`; development data lives in `.local/dev-server/data`. This differs from the packaged Mac runner's port 8391 and `.local/server` archive.
- The launcher ignores inherited `V07_SERVER_DATA_DIR` settings. Select another development archive explicitly with `--data-dir`.
- A private token is created once at `.local/dev-server/token` and reused on reload. Do not print or commit its value. Use the token in the native client's server settings; `V07_SERVER_TOKEN_FILE` or `--token-file` can select an existing token file.
- On a local Mac, open [server health](http://localhost:8392/v1/health). On Siva, open [server health](http://siva.otter-hawksbill.ts.net:8392/v1/health) in the collaborative browser. For another machine, use its reachable hostname or Tailscale address and the selected port.
- The server starts without native assets and reports `ready: false`. To enable dictation, follow [model setup](../Server/README.md#models), set `V07_SPEECH_MODEL` to the pinned Parakeet v3 `.bin` and `V07_TEXT_MODEL` to the Qwen model, and run `./scripts/build-server.sh` once to build the real helpers and VAD. Existing helpers can be selected with `V07_ENGINE_PATH`, `V07_TEXT_ENGINE_PATH`, and `V07_VAD_PATH`.
- Pass normal server arguments to override defaults, for example `bun run dev --port 8393 --data-dir "$PWD/.local/another-dev-archive"`. Use `bun run dev --help` for arguments. Keep model files outside Git.

## Native app

- V07 has no browser UI. Browser-origin API requests are rejected; do not weaken that policy to create a verification shortcut.
- On an Apple Silicon Mac with Xcode 26+ and Swift 6.2+, run `./scripts/build-dev-app.sh`. Launch `build/V07 Dev.app` with `V07_CLIENT_DATA_DIR` set to a new workspace-local client directory, so its preferences and credentials remain separate from the regular app:

```sh
mkdir -p .local/dev-client
chmod 700 .local/dev-client
open --env "V07_CLIENT_DATA_DIR=$PWD/.local/dev-client" "build/V07 Dev.app"
```

- Under **This Mac**, select the development server and its token. On a local Mac, use `http://localhost:8392`. The client requires HTTPS for remote hostnames; on the connected tailnet, a literal Tailscale IP may use HTTP. For Siva's default development server, use `http://100.100.40.20:8392` in the native client, or an HTTPS reverse proxy you already have configured.
- Grant **V07 Dev** Microphone and Accessibility permissions. Use **Test microphone** for an in-app transcript; use the recording shortcut in a separate editable app to verify insertion.
- `./scripts/run-dev.sh` remains available to build/start the packaged server and Mac client together. It uses port 8391 by default; choose an unused `V07_SERVER_PORT` and a separate archive before using it alongside an existing installation. Do not stop or restart an existing server without authorization.

## Computer-use verification

- Exercise the behavior you changed using the actual app: save and reload preferences, navigate history, record speech, inspect progress and the finished transcript, or insert dictation into an editable field as appropriate.
- For inference changes, use real helpers and pinned models. Inspect raw/cleaned transcripts and model readiness; `ready: false` is not successful dictation verification.
- For lifecycle or recovery changes, use only the instance and archive created for this task. Reopen the app or restart that isolated server as needed, then inspect persisted state through the app.
- Record what you used and observed. State which flows could not be exercised because a Mac, microphone, permissions, or model assets were unavailable. Static checks and an HTTP health page do not establish native UI or inference behavior.
- When changing Swift or the transport contract, run `bun run generate:api --check` and `swift build --force-resolved-versions` on macOS. Compile affected native helpers when changing C++ or MLX. These are build/static checks, not behavioral test suites.
