# Architecture

Inlay's native Swift macOS client handles microphone capture, shortcuts, and cursor insertion. An independent TypeScript/Fastify server, compiled with Bun, owns inference, shared settings, and history. Both processes use API version 4. The contract is `Server/api/openapi.yaml` (OpenAPI 3.1). HTTP paths stay under `/v1`, and the client requires `apiVersion` 4 for live dictation and recovery. The same contract applies on one machine or across the network.

## Code map

| Component                 | Responsibility                                                                              |
| ------------------------- | ------------------------------------------------------------------------------------------- |
| `Sources/Inlay`           | SwiftUI/AppKit app, device settings, HTTP client, capture, and guarded delivery.            |
| `Sources/InlayCore`       | Mac configuration, audio metering, microphone selection, and model manifests.               |
| `Sources/InlayAPI`        | Shared wire types and limits.                                                               |
| `Sources/InlayAPIWire`    | Generated Swift transport types used through the API facade.                                |
| `Server/api/openapi.yaml` | Language-neutral HTTP and wire-model contract.                                              |
| `Server/src`              | Packaged TypeScript HTTP server, durable coordinator, text pipeline, and helper management. |
| `Sources/InlayDomain`     | Dictionary and record-embedded wire types shared with the client.                           |
| `Sources/InlayServer`     | Reference Swift server command-line entry point.                                            |
| `Engine`                  | Persistent Parakeet speech helper (vendored whisper.cpp); Metal on Mac, CPU/CUDA on Linux.  |
| `TextEngine`              | Persistent Qwen helper; Swift MLX on Mac, llama.cpp on Linux.                               |

The server talks to helpers over bounded JSON-lines pipes. Models warm at startup and stay loaded. The client contains no model helpers; it never starts or stops the server. The application has no Python runtime dependency.

Bun manages all JavaScript dependencies and compiles the coordinator plus its correction worker into standalone platform executables. Heavy correction alignment runs outside the HTTP event loop. Native inference helpers still require platform builds; the Mac proofreader remains Swift MLX. Linux server packages require neither Swift nor an installed JavaScript runtime.

## A recording

1. For a live take, the client asks the server to create a generation with its device identity. The server freezes shared settings and accepts independent uploads from connected clients. A configured client can start a dictation while offline and upload later to the same endpoint. Offline-start takes capture inference audio only, without an insertion target; **Test microphone** still requires online admission.
2. The client pins its microphone and uploads acknowledged, sequenced PCM chunks while recording. Inference audio is mono 16 kHz float32; optional original audio keeps the microphone rate/channels as float32.
3. Release stops capture, drains uploads, and sends final frame counts. The microphone is available for the next take while earlier uploads finish. The server checks the complete intervals and seals WAV files. Recordings must be at least 0.25 seconds. This server advertises a two-hour limit; the client uses three minutes for a live connection to an older v4 server that does not advertise one. A longer offline take stays on the Mac until the selected server supports its duration. Transcripts over 2,400 characters are proofread in sentence-aligned parts of about 1,200 characters, each checked by the rewrite guards on its own.
4. Sealed recordings enter a FIFO processing queue. Jobs run concurrently, but each helper stage is serialized: one job at a time runs Parakeet, mechanical cleanup, dictionary rules, and list formatting, and one job at a time proofreads, so speech for one take can overlap proofreading for another. Optional Qwen output passes through dictionary rules and deterministic rewrite checks. Rejection or proofreading failure retains the pre-proofreading text. Cancelling one upload or queued job does not interrupt another.
5. NDJSON events carry progress and the saved final result for each generation. Each pending client take retains its original server connection and destination. The client serializes delivery attempts, verifies focus/caret safety, and reports each outcome separately from inference completion.

Capture writes raw PCM under `recordings/<take>/` in the private client data directory. Live uploads read that copy; network speed does not set the pace of microphone capture. The writer checkpoints every ten seconds of processed audio and again at stop. A sudden power loss can still cost the tail since the last checkpoint. Cancelling first renames the local take out of the recovery queue and syncs that decision to disk, then removes the audio. For a finished take, the client releases the spool only after it records its pending delivery and the server confirms the seal.

If a live upload expires or is rejected, the client can upload the saved take to a fresh generation. Interrupted uploads expire on the server after ten idle minutes. The client persists upload identity and seal counts so that a lost acknowledgement can be reconciled without duplicating the recording. After quitting, crashing, or recording offline, Inlay retries saved dictations when the same server is ready. Recovered results are offered for manual copy; they never write to the clipboard or an earlier cursor automatically. Microphone-test spools are not replayed after relaunch.

Once the server has the sealed audio, it owns processing independently of the app. On restart, the server requeues unfinished generations with sealed inference audio and marks unsealed ones failed. Completed history is retained; opening it never triggers insertion.

## Text delivery

Only the new `insertionText` can be inserted; `previewText` may include earlier list items. Continuation requires a previous generation from the same device and a confirmed client-side cursor anchor. The server checks age and delivery state before reusing context. Invalid context falls back to a standalone take.

The Mac rechecks destination, selection, protected fields, modifiers, and clipboard state before delivery. Unsafe destinations use clipboard or preview fallback. Only confirmed insertion advances cursor-based continuation. Editor text and Accessibility handles stay on the Mac.

Pasting stages the transcript on the clipboard temporarily and restores the previous contents once insertion is confirmed. When insertion cannot be confirmed, or no editable field is found, the transcript stays on the clipboard as a backup. With **Never leave transcripts on the clipboard** enabled under **This Mac**, Inlay never keeps that backup: unconfirmed words stay in the app to copy, and the previous clipboard returns once insertion is confirmed or after 1.5 seconds. An app that reads the paste later than that inserts the previous clipboard instead.

Microphone capture uses input-only Core Audio without changing system routing or playback volume. Route changes apply to the next take. Release, cancellation, sleep/lock, or device loss ends capture.

With **Mute system audio while recording** enabled under **This Mac**, the default output device is muted when a take starts and restored when capture ends. Only mute controls Inlay changed are restored, so output that was already muted stays muted. A client crash during a take can leave output muted.

## Settings

| Scope          | Where to edit                    | What it owns                                                                                                                                  |
| -------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| This Mac       | **This Mac** and **Microphone**  | Endpoint/token, device name, shortcut, launch at login, output muting while recording, clipboard preservation, microphone priority/selection. |
| Shared server  | **Server preferences**           | Language, cleanup prompt, vocabulary, dictionary, proofreading toggle, original-audio retention.                                              |
| Server process | Command arguments or environment | Bind address, port, data directory, token file, helper/model paths. See [server setup](../Server/README.md).                                  |

Shared saves use revisions to reject stale concurrent edits. Settings are snapshotted when the server accepts a take; changes affect future recordings. Update shared settings through the UI/API rather than editing files while the server runs.

The regular app uses `~/Library/Application Support/Inlay`; Dev uses `~/Library/Application Support/Inlay Dev`. `INLAY_CLIENT_DATA_DIR` overrides either, and the dev runner selects `.local/client`. `config.json` stores shortcut/microphone settings; `client.json` stores endpoint/device identity. Tokens live in separate release/Dev Keychain services, `dev.davis.inlay.server` and `dev.davis.inlay.dev.server`, scoped to the endpoint and client directory. `INLAY_SERVER_URL` overrides the saved endpoint for a run. Valid manual `config.json` edits are reloaded; invalid files leave the last good configuration active. See [upgrade guidance](../README.md#upgrade-an-existing-installation) when moving from an earlier app identity.

## Storage

The server's `--data-dir` contains the layout below. `./scripts/run-dev.sh` uses `.local/server`. `bun run dev` uses `.local/dev-server/data` and ignores an inherited `INLAY_SERVER_DATA_DIR`. An installed Linux service uses `/var/lib/inlay`.

```text
preferences.json
devices.json
admin-token (only when auto-created)
generations/<UUID>/
  metadata.json
  transcript.txt
  inference.wav
  original.wav
```

Metadata includes device identity, settings snapshot, raw/final text, insertion/preview text, model and processing details, and any delivery receipt. `transcript.txt` contains the current take's final text. Text and metadata are kept forever. Recording audio auto-deletes after the shared `audioRetentionDays` cap (default 90 days; 0 keeps it forever) via a boot/daily sweep, and can be purged on demand from Server preferences; original audio is optional and defaults on for future takes. Cancelled and failed takes keep their audio under the same cap, labeled in History, until it expires or is deleted per record.

All clients read shared, paginated history. Deleting an inactive generation deletes its server artifacts. Failed and cancelled takes retain metadata and sealed audio (labeled, deletable per record); partial upload files are internal and cannot be downloaded. Client spools are kept only until their take is sealed on a server.

Only one server may own a data directory. Back up preferences and generation directories together. Inlay does not add filesystem encryption; protect this directory as you would the recordings it contains. Authentication and remote transport are described in the [server guide](../Server/README.md#remote-access).

See the [HTTP contract](client-server-contract.md) for request details and [text correction](text-correction.md) for behavior and limitations.
