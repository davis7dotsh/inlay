# Inlay for Windows

The Windows 11 x64 client is a native desktop app. Like the Mac client, it records at your desk and sends audio to an independently running Inlay server. History, recognition, proofreading, vocabulary, and retention stay on that server. The EXE includes the .NET desktop runtime, not the server or model weights.

## Use it

1. Run `Inlay-Setup.exe` as your normal Windows user, then open **Inlay** from Start. Or open the portable `Inlay.exe` directly. In **This PC**, connect to an Inlay API v4 server. Use a trusted HTTPS endpoint for a remote server. On first setup, enter its enrollment token. Returned device credentials are protected for the signed-in Windows user (DPAPI); don't copy the settings to another account.
2. In Windows **Settings → Privacy & security → Microphone**, allow microphone access for desktop apps. Select your input in **Microphone**, or use the system default. Click **Test microphone**, speak, then click **Finish test**. The transcript appears on the Microphone page; it doesn’t type into another app or replace your last dictation.
3. Focus an editable field. Hold **left Ctrl + left Windows**, speak after recording starts, then release either key. Right-side modifiers aren't substitutes. Start with a normal, non-elevated Notepad window.
4. By default, each finished dictation replaces the Windows clipboard, even when it was inserted at the cursor. If the words didn’t appear, press **Ctrl+V** where you want them. To keep your clipboard untouched, turn off **This PC → Copy each dictation to the clipboard**. Manual **Copy** still works. Both kinds of copy request exclusion from Windows clipboard history (Win+V) and cloud sync; other clipboard managers may still read the text. Microphone tests, cancelled or empty takes, and browsing history never auto-copy.

Close the window to keep the shortcut active. Click the tray icon (possibly under hidden icons) to reopen; right-click to quit.

Native Edit controls and supported Notepad fields receive a targeted insertion. For supported Chromium, Firefox, Electron, or WPF text fields, Inlay verifies the focused editable field and caret, then sends a single line of Unicode text. In Chromium editors (including Helium and Codex), this check uses the field’s text selection rather than the blinking system caret’s screen position. Windows cannot confirm that the app accepted this input: check the field before pasting so you don’t duplicate words. Inlay never sends a paste shortcut. Password prompts, elevated windows, terminals, changed targets and unsupported editors receive no automatic insertion; the clipboard setting still applies.

The shortcut uses the physical left keys. If another dictation app (such as Wispr Flow) already owns this chord, quit or rebind that app before trying it. A quick Ctrl+Win+third-key Windows shortcut doesn’t start a take. During a take, a third key finishes the recording without inserting.

The server must remain awake and reachable during dictation. Use [Tailscale Serve](../Server/README.md#remote-access) for a tailnet-only HTTPS address if the server listens on loopback; **do not enable Funnel**. No public listener or Windows firewall exception is needed on the client.

## Build

Use the .NET SDK pinned in `global.json` and the committed dependency lock file. No model checkout, Swift compiler, Windows SDK installation on the target PC, or elevation is needed to run the result.

```sh
dotnet restore Windows/Inlay.csproj --locked-mode
dotnet publish Windows/Inlay.csproj -c Release --no-restore -o build/windows
```

For the installer, use NSIS 3.13 (`brew install makensis` on macOS, or `choco install nsis.install --version=3.13.0` on Windows). From the repository root, run `makensis Windows/setup.nsi` (on Windows, `makensis Windows\setup.nsi`: makensis only resolves the script's relative paths from a backslash path there) to wrap the published `build/windows/Inlay.exe` as `build/windows/Inlay-Setup.exe`. The Windows CI workflow builds both artifacts. Setup installs under `%LOCALAPPDATA%\Programs\Inlay\Client`, adds a Start shortcut, and supports removal through **Settings → Apps → Installed apps**. It doesn’t change a portable copy, launch tasks, or the device identity. Quit the running copy from the tray before switching versions. If you change settings in a build that predates auto-copy, recheck the clipboard switch when you return to the newer build: older versions don’t preserve it.

Both EXEs are unsigned. Compare their SHA-256 after transfer (`Get-FileHash -Algorithm SHA256 .\Inlay*.exe`). On a PC with Smart App Control enabled, check both the installer and the staged client with Microsoft Defender’s `MpCmdRun.exe -TrustCheck -File <path>` **before stopping the working client**. Running setup manually does not grant the installed app a trust exception. Read the verdict: a zero exit code alone doesn’t mean the file is trusted. If the new hash isn’t recognized, keep the working version and use a [publicly trusted code-signing certificate](https://learn.microsoft.com/windows/apps/develop/smart-app-control/overview) for predictable updates. Don’t disable Smart App Control, SmartScreen or endpoint protection. Rebuild with a serviced .NET 10 SDK when distributing runtime security updates; refresh the dependency lock file intentionally if the SDK's tooling version changes.

## Design and acceptance

- **Reuse the existing service.** Gate admission on v4 readiness, enroll each PC separately, send acknowledged float32 streams, finish with exact frame counts, and report delivery separately from transcription. Keep editor state on the PC.
- **Map the native experience rather than porting SwiftUI.** WPF for the main window and nonactivating HUD, system tray instead of the menu bar, WASAPI for capture, the Mac app's icon, palette and page structure. Install neither hooks nor services that require an administrator.
- **Prioritize the daily path.** A modifier-only hold chord, microphone selection, safe cursor delivery, transcript preview, shared history and core server preferences. This isn't a Windows port of the inference server, Mac local model installer or Wispr Flow importer.
- **Verify on a signed-in Windows desktop.** Check the real app's server status. Dictate into Notepad, then change fields before a second take returns and check the fallback. Try both modifier orders, either-key release, standalone Start and Ctrl+C. In a Helium text field, the Codex composer and T3 Code, place the caret between two words and dictate without submitting. Check that the phrase appears there exactly once. Switching fields before delivery should leave both fields unchanged and put the words in Inlay’s preview. With auto-copy on, paste into a blank Notepad document after both a successful insertion and a refused one. Check that a multi-line transcript pastes with its line breaks and, if Windows clipboard history is enabled, that the transcript doesn't appear in Win+V. With auto-copy off, copy a marker, restart Inlay, dictate again and verify the marker still pastes. A microphone test with auto-copy on should also preserve the marker while showing the words on **Microphone** without changing the last dictation or typing into another app. A process listing or liveness endpoint alone does not verify these behaviors.
