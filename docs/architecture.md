# Architecture

Inlay's native Swift macOS client handles microphone capture, shortcuts, and cursor insertion. An independent TypeScript/Fastify server, compiled with Bun, owns inference, shared settings, and history. Both processes use API version 4. The contract is `Server/api/openapi.yaml` (OpenAPI 3.1). HTTP paths stay under `/v1`, and the client requires `apiVersion` 4 before dictation. The same contract applies on one machine or across the network.

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

1. The client asks the server to create a generation with its device identity. The server freezes shared settings and accepts independent uploads from any connected client. Offline or unavailable speech recognition prevents capture; other recordings do not.
2. The client pins its microphone and uploads acknowledged, sequenced PCM chunks while recording. Inference audio is mono 16 kHz float32; optional original audio keeps the microphone rate/channels as float32.
3. Release stops capture, drains uploads, and sends final frame counts. The microphone is available for the next take while earlier uploads finish. The server checks the complete intervals and seals WAV files. Recordings must be 0.25–180 seconds.
4. Sealed recordings enter a FIFO processing queue. Jobs run concurrently, but each helper stage is serialized: one job at a time runs Parakeet, mechanical cleanup, dictionary rules, and list formatting, and one job at a time proofreads, so speech for one take can overlap proofreading for another. Optional Qwen output passes through dictionary rules and deterministic rewrite checks. Rejection or proofreading failure retains the pre-proofreading text. Cancelling one upload or queued job does not interrupt another.
5. NDJSON events carry progress and the saved final result for each generation. Each pending client take retains its original server connection and destination. The client serializes delivery attempts, verifies focus/caret safety, and reports each outcome separately from inference completion.

Interrupted partial uploads expire; a complete upload can finish after the client disconnects. Pending takes recover interrupted event streams by checking their saved generation and reconnecting. Opening history never pastes an old result. Restarting the server requeues unfinished generations whose sealed inference audio is present and marks the rest failed; completed history is retained. The client retries each chunk upload within a nominal 60-second window, and pending generations persist across relaunch. There is no offline capture queue.

## Text delivery

Only the new `insertionText` can be inserted; `previewText` may include earlier list items. Continuation requires a previous generation from the same device and a confirmed client-side cursor anchor. The server checks age and delivery state before reusing context. Invalid context falls back to a standalone take.

The Mac rechecks destination, selection, protected fields, modifiers, and clipboard state before delivery. Unsafe destinations use clipboard or preview fallback. Only confirmed insertion advances cursor-based continuation. Editor text and Accessibility handles stay on the Mac.

Pasting stages the transcript on the clipboard temporarily and restores the previous contents once insertion is confirmed. When insertion cannot be confirmed, or no editable field is found, the transcript stays on the clipboard as a backup. With **Never leave transcripts on the clipboard** enabled under **This Mac**, Inlay never keeps that backup: unconfirmed words stay in the app to copy, and the previous clipboard returns once insertion is confirmed or after 1.5 seconds. An app that reads the paste later than that inserts the previous clipboard instead.

Microphone capture uses input-only Core Audio without changing system routing or playback volume. Route changes apply to the next take. Release, cancellation, sleep/lock, or device loss ends capture.

**System audio while recording** under **This Mac** chooses **None** (the fresh-install default), **Mute**, or **Duck**. An earlier enabled mute preference carries over to **Mute**. **Mute** mutes the default output device once microphone audio arrives and unmutes it when capture ends. Only mute controls Inlay changed are restored, so output that was already muted stays muted. **Duck** lowers each controllable output volume to a quarter of its starting level for the same span. At teardown, Inlay restores an original only if the readable current value still matches its recorded change (within scalar-volume rounding tolerance); a different value is left alone. Waiting for microphone audio matters for Bluetooth headsets, which switch to a call profile with its own volume and mute while their microphone records. Devices without a settable control, such as some HDMI outputs, stay unchanged; Duck never falls back to mute.

Before changing output, Inlay atomically saves a recovery journal keyed by stable device UID and control element. A control stays unchanged if its journal write fails. Normal teardown and next-launch recovery retain entries for absent devices, unreadable controls, and failed restore writes. Device and control notifications coalesce automatic retries, including after reconnect; a later take also retries recovery and cannot replace an unresolved original for that device. Successful restores and readable user-changed values remove entries, and an empty journal is deleted. If journal cleanup fails, the previous file remains for a later retry. This comparison cannot distinguish a user deliberately choosing the exact value Inlay set; it does not track every volume-key action.

## Settings

| Scope          | Where to edit                    | What it owns                                                                                                                                             |
| -------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| This Mac       | **This Mac** and **Microphone**  | Endpoint/token, device name, shortcut, launch at login, output muting or ducking while recording, clipboard preservation, microphone priority/selection. |
| Shared server  | **Server preferences**           | Language, cleanup prompt, vocabulary, dictionary, proofreading toggle, original-audio retention.                                                         |
| Server process | Command arguments or environment | Bind address, port, data directory, token file, helper/model paths. See [server setup](../Server/README.md).                                             |

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

All clients read shared, paginated history. Deleting an inactive generation deletes its server artifacts. Failed and cancelled takes retain metadata and sealed audio (labeled, deletable per record); partial upload files are internal and cannot be downloaded. Client audio copies are temporary.

Only one server may own a data directory. Back up preferences and generation directories together. Inlay does not add filesystem encryption; protect this directory as you would the recordings it contains. Authentication and remote transport are described in the [server guide](../Server/README.md#remote-access).

See the [HTTP contract](client-server-contract.md) for request details and [text correction](text-correction.md) for behavior and limitations.
