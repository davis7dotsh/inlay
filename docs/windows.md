# Inlay for Windows

The Windows 11 x64 client is a native desktop app. Like the Mac client, it records at your desk and sends audio to an independently running Inlay server. History, recognition, proofreading, vocabulary, and retention stay on that server. The EXE includes the .NET desktop runtime, not the server or model weights.

## Use it

1. Open `Inlay.exe` as your normal Windows user. In **This PC**, connect to an Inlay API v4 server. Use a trusted HTTPS endpoint for a remote server. On first setup, enter its enrollment token. Returned device credentials are protected for the signed-in Windows user (DPAPI); don't copy the settings to another account.
2. In Windows **Settings → Privacy & security → Microphone**, allow microphone access for desktop apps. Select your input in **Microphone**, or use the system default. **Test microphone** previews a transcript without typing into another app.
3. Focus an editable field. Hold **left Ctrl + left Windows**, speak after recording starts, then release either key. Right-side modifiers aren't substitutes. Start with a normal, non-elevated Notepad window.
4. If Inlay can't safely verify the destination, copy the words from Inlay instead. History is for reading and copying; it never automatically replays old dictations. Close the window to keep the shortcut active. Click the tray icon (possibly under hidden icons) to reopen; right-click to quit.

Native Edit controls and supported Notepad fields receive a targeted insertion. For supported Chromium, Firefox, Electron, or WPF text fields, Inlay verifies the focused editable field and caret, then sends a single line of Unicode text. Windows cannot confirm that the app accepted this input: check the field before copying a preview. Password prompts, elevated windows, terminals, changed targets and unsupported editors stay preview-only. Inlay never automatically pastes or changes the clipboard.

The shortcut uses the physical left keys. If another dictation app (such as Wispr Flow) already owns this chord, quit or rebind that app before trying it. A quick Ctrl+Win+third-key Windows shortcut doesn’t start a take. During a take, a third key finishes to preview instead of inserting.

The server must remain awake and reachable during dictation. Use [Tailscale Serve](../Server/README.md#remote-access) for a tailnet-only HTTPS address if the server listens on loopback; **do not enable Funnel**. No public listener or Windows firewall exception is needed on the client.

## Build

Use the .NET 10 SDK and the committed dependency lock file. No model checkout, Swift compiler, Windows SDK installation on the target PC, or elevation is needed to run the result.

```sh
dotnet restore Windows/Inlay.csproj --locked-mode
dotnet publish Windows/Inlay.csproj -c Release --no-restore -o build/windows
```

Ship `build/windows/Inlay.exe`. This is a self-contained, unsigned x64 build. Compare its SHA-256 after transfer (`Get-FileHash -Algorithm SHA256 .\Inlay.exe`). Don't disable SmartScreen or endpoint protection. Rebuild with a serviced .NET 10 SDK when distributing runtime security updates; refresh the dependency lock file intentionally if the SDK's tooling version changes.

## Design and acceptance

- **Reuse the existing service.** Gate admission on v4 readiness, enroll each PC separately, send acknowledged float32 streams, finish with exact frame counts, and report delivery separately from transcription. Keep editor state on the PC.
- **Map the native experience rather than porting SwiftUI.** WPF for the main window and nonactivating HUD, system tray instead of the menu bar, WASAPI for capture, the Mac app's icon, palette and page structure. Install neither hooks nor services that require an administrator.
- **Prioritize the daily path.** A modifier-only hold chord, microphone selection, safe cursor delivery, transcript preview, shared history and core server preferences. This isn't a Windows port of the inference server, Mac local model installer or Wispr Flow importer.
- **Verify on a signed-in Windows desktop.** Check the real app's server status. Dictate into Notepad, then change fields before a second take returns and check the fallback. Try both modifier orders, either-key release, standalone Start and Ctrl+C. Check that History shows the new record and that a microphone test doesn't type into another application. A process listing or liveness endpoint alone does not verify these behaviors.
