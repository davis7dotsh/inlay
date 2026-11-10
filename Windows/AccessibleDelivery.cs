using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Threading;
using Microsoft.Win32.SafeHandles;

namespace Inlay.Windows;

// Fallback after native capture fails, never a retry after a native write. Capture
// from the WPF dispatcher at press. Only opaque UIA identity/ranges leave the probe;
// never request names, values, document text, or change focus/selection/clipboard.
internal static class AccessibleDelivery
{
    internal sealed record Window(nint Frame, nint Focus, uint Thread, uint Process);
    internal sealed class Watch(Window window)
    {
        internal readonly Window Window = window;
        private int[]? field;
        private string? failure;
        internal string? Failure => Volatile.Read(ref failure);
        internal void Reject(string reason) => Interlocked.CompareExchange(ref failure, reason, null);
        internal void Observe(int[]? id)
        {
            if (id is not { Length: > 0 }) { Reject("Field focus could not be identified."); return; }
            var first = Interlocked.CompareExchange(ref field, id, null);
            if (first != null && !first.AsSpan().SequenceEqual(id)) Reject("Focus left the original field.");
        }
    }
    internal sealed record Target(Watch Watch, nint Host, TextPatternRange Caret, int? Offset)
    {
        internal int Used;
    }
    internal sealed record Probe(Target? Target, string? Reason);
    private static Watch? active;
    internal static void Forget() => Interlocked.Exchange(ref active, null)?.Reject("This take ended.");

    internal static async Task<Probe> CaptureAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!WatchWindows() || Focus() is not { } window || TextDelivery.PressWindows != (window.Frame, window.Focus))
            return new(null, "Could not identify the editor at shortcut press.");
        var watch = new Watch(window);
        Interlocked.Exchange(ref active, watch)?.Reject("A newer take started.");
        return await ProbeAsync(watch, null, ct).ConfigureAwait(false);
    }

    internal static async Task<TextDelivery.Result> InsertAsync(Probe captured, string text, CancellationToken ct)
    {
        if (captured.Target is not { } target) return Preview(captured.Reason ?? "No verified editable caret.");
        if (Interlocked.Exchange(ref target.Used, 1) != 0) return Preview("This destination was already used.");
        ct.ThrowIfCancellationRequested();
        var input = UnicodeInput(text);
        if (input == null) return Preview("Text is empty, too long, or contains unsupported characters.");
        var watch = target.Watch;
        // LastInput also advances for a harmless mouse move. In that case allow
        // one fresh, read-only verification; never retry a write or a mismatched field.
        for (int attempt = 0; ; attempt++)
        {
            if (watch.Failure is { } changed) return Preview(changed);
            if (Focus() != watch.Window) return Preview("The foreground editor changed.");
            if (TextDelivery.ShortcutHeld()) return Preview("A shortcut modifier is still held.");
            // Chromium exposes its accessibility tree asynchronously. Give a recent
            // click or key-up time to reach it before trusting its view of focus.
            if (await QuietInputAsync(ct).ConfigureAwait(false) is not uint before)
                return Preview("Keyboard or mouse input is still changing.");
            var verified = await ProbeAsync(watch, target, ct).ConfigureAwait(false);
            if (verified.Target == null) return Preview(verified.Reason ?? "The editor could not verify its caret.");
            if (Focus() != watch.Window || TextDelivery.ShortcutHeld() || watch.Failure != null)
                return Preview(watch.Failure ?? "The foreground editor or keyboard state changed during verification.");
            if (LastInput() == before) break;
            if (attempt != 0) return Preview("Keyboard or mouse input continued during verification.");
        }
        ct.ThrowIfCancellationRequested();

        // SendInput targets the foreground queue, not an HWND. One bounded batch
        // avoids interleaving batches or retrying a partial write. Focus can still
        // change between validation and dispatch, including in the editor's own
        // handlers. Queue acceptance is NOT an insertion receipt (filters, IMEs,
        // app shortcuts, etc.); even caret motion cannot prove what was inserted.
        uint sent = SendInput((uint)input.Length, input, Marshal.SizeOf<Input>());
        return sent == 0 ? Preview("Windows did not queue the text.") : new("unconfirmed",
            sent == input.Length ? "Text was sent but insertion is unconfirmed. Check the field before pasting."
                                 : "Only part of the input was queued. Check the field before pasting.");
    }

    private static TextDelivery.Result Preview(string reason) => new("failed", reason + " Text is available in preview.");
    private static int probing;
    private static bool watchingUia;

    // UIA crosses untrusted process boundaries. Use one outstanding read on the
    // thread pool's MTA, never the dispatcher/keyboard hook or a lock around COM.
    // If a provider hangs, callers time out and new probes fail closed rather than
    // leaking workers. An abandoned probe has no text and no path to SendInput.
    private static async Task<Probe> ProbeAsync(Watch watch, Target? expected, CancellationToken ct)
    {
        if (Interlocked.CompareExchange(ref probing, 1, 0) != 0) return new(null, "The accessibility provider is still busy.");
        var read = Task.Run(() =>
        {
            try
            {
                ct.ThrowIfCancellationRequested();
                if (!AllowedProcess(watch.Window.Process)) return new Probe(null, "The editor is elevated or inaccessible.");
                if (!watchingUia)
                {
                    var cache = new CacheRequest { AutomationElementMode = AutomationElementMode.None };
                    cache.Add(AutomationElement.RuntimeIdProperty);
                    using (cache.Activate()) Automation.AddAutomationFocusChangedEventHandler(FieldFocused);
                    watchingUia = true;
                }
                return ReadField(watch, expected);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException && ex is not AccessViolationException)
            { return new Probe(null, "The accessibility provider could not read the field."); }
            finally { Volatile.Write(ref probing, 0); }
        });
        try { return await read.WaitAsync(TimeSpan.FromMilliseconds(1500), ct).ConfigureAwait(false); }
        catch (TimeoutException) { return new(null, "The accessibility provider took too long."); }
    }

    // Chromium can re-announce the very same focused editor on modifier release.
    // Only compare cached runtime IDs here: no COM round trips in an event handler.
    private static void FieldFocused(object sender, AutomationFocusChangedEventArgs args)
    {
        if (Volatile.Read(ref active) is not { } watch) return;
        try { watch.Observe((sender as AutomationElement)?.GetCachedPropertyValue(AutomationElement.RuntimeIdProperty, true) as int[]); }
        catch (InvalidOperationException) { watch.Reject("Field focus could not be identified."); }
    }

    private static Probe ReadField(Watch watch, Target? expected)
    {
        var window = watch.Window;
        if (watch.Failure != null || Focus() != window) return new(null, watch.Failure ?? "The foreground editor changed.");
        var field = AutomationElement.FocusedElement;
        if (field == null || field.Current.ProcessId != window.Process || field.Current.ControlType != ControlType.Edit ||
            field.Current.FrameworkId is not ("Chrome" or "Gecko" or "WPF")) return new(null, "The focused control is not a supported editor.");
        // The normal UIA defaults (e.g. IsPassword=false) aren't provider evidence.
        object Property(AutomationProperty p) => field.GetCurrentPropertyValue(p, ignoreDefaultValue: true);
        if (Property(AutomationElement.IsPasswordProperty) is not false ||
            Property(AutomationElement.IsOffscreenProperty) is not false ||
            Property(AutomationElement.IsEnabledProperty) is not true ||
            Property(AutomationElement.HasKeyboardFocusProperty) is not true ||
            field.Current.BoundingRectangle is not { Width: > 0, Height: > 0 }) return new(null, "The field is protected, hidden or inactive.");

        watch.Observe(field.GetRuntimeId());
        if (watch.Failure is { } failure) return new(null, failure);
        nint host = Host(field, window);
        if (host == 0 || (expected != null && host != expected.Host)) return new(null, "The field's editor host changed or could not be verified.");
        if (!field.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) || pattern is not TextPattern text ||
            text.SupportedTextSelection == SupportedTextSelection.None) return new(null, "The field does not expose a text selection.");
        var caret = CollapsedCaret(text);
        if (caret == null) return new(null, "The field does not have a single insertion point.");

        // Require positive writability evidence. A provider may omit the range
        // attribute for a plain Edit, but an explicit mixed/readonly run always wins.
        object readOnly = caret.GetAttributeValue(TextPattern.IsReadOnlyAttribute);
        object valueReadOnly = Property(ValuePattern.IsReadOnlyProperty);
        object hidden = caret.GetAttributeValue(TextPattern.IsHiddenAttribute);
        if (valueReadOnly is true || (readOnly is not false && !(readOnly == AutomationElement.NotSupported && valueReadOnly is false)) ||
            (hidden is not false && hidden != AutomationElement.NotSupported)) return new(null, "The caret is not visibly writable.");

        // Chromium may recreate the AX text leaf for a contenteditable (Codex) or
        // browser input (Helium) without replacing the field or moving the caret.
        // Prefer a field-relative character offset to a live range the renderer can
        // invalidate. Never read editor text to calculate it.
        int? offset = expected?.Offset;
        if (expected == null && field.Current.FrameworkId == "Chrome") offset = Offset(text, caret);
        if (expected != null && !(offset is int saved ? AtOffset(text, caret, saved) : caret.Compare(expected.Caret)))
            return new(null, "The insertion point moved.");
        if (watch.Failure != null || Focus() != window || !Automation.Compare(field, AutomationElement.FocusedElement) ||
            CollapsedCaret(text) is not { } now || !now.Compare(caret)) return new(null, watch.Failure ?? "The field or caret changed during verification.");
        return new(new(watch, host, now, offset), null);
    }

    private static bool AtOffset(TextPattern field, TextPatternRange caret, int offset)
    {
        var prefix = field.DocumentRange;
        var start = TextPatternRangeEndpoint.Start;
        var end = TextPatternRangeEndpoint.End;
        // Some browser providers allow ranges to leave their owning control.
        // A field that shrank must not validate an offset in the surrounding page.
        if (prefix.CompareEndpoints(end, caret, start) < 0) return false;
        if (offset == 0) return prefix.CompareEndpoints(start, caret, start) == 0;
        prefix.MoveEndpointByRange(end, prefix, start);
        return prefix.MoveEndpointByUnit(end, TextUnit.Character, offset) == offset && prefix.CompareEndpoints(end, caret, start) == 0;
    }

    private static int? Offset(TextPattern field, TextPatternRange caret)
    {
        // Chromium lets a range move beyond its owning input into other page text.
        // Start at the *field's* beginning and count a bounded number of units toward
        // the selection. Cloning and moving range endpoints never moves the real caret.
        const int limit = 8192;
        var start = TextPatternRangeEndpoint.Start;
        var end = TextPatternRangeEndpoint.End;
        try
        {
            var prefix = field.DocumentRange;
            int cmp = prefix.CompareEndpoints(start, caret, start);
            if (cmp == 0) return 0;
            if (cmp > 0 || prefix.CompareEndpoints(end, caret, start) < 0) return null;
            prefix.MoveEndpointByRange(end, prefix, start);
            int offset = 0, step = 16;
            bool bracketed = false;
            long started = Environment.TickCount64;
            while (step > 0 && Environment.TickCount64 - started < 300)
            {
                var next = prefix.Clone();
                int moved = next.MoveEndpointByUnit(end, TextUnit.Character, step);
                if (moved <= 0 || moved > step) break;
                cmp = next.CompareEndpoints(end, caret, start);
                if (cmp == 0) return offset + moved;
                if (cmp > 0) { bracketed = true; step /= 2; continue; }
                prefix = next;
                offset += moved;
                if (moved < step) break;
                step = Math.Min(bracketed ? step / 2 : step * 2, limit - offset);
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or NotSupportedException or ArgumentException or COMException)
        { /* Optional provider capability. Keep strict range comparison when unavailable. */ }
        return null;
    }

    private static TextPatternRange? CollapsedCaret(TextPattern text) => text.GetSelection() is [var r] &&
        r.CompareEndpoints(TextPatternRangeEndpoint.Start, r, TextPatternRangeEndpoint.End) == 0 ? r : null;

    // Browser/WPF edits are often virtual children (NativeWindowHandle == 0).
    // Bind their nearest real host to the OS focus hierarchy, not just a PID.
    // A renderer host can itself be a child of the window receiving keyboard input.
    private static nint Host(AutomationElement field, Window window)
    {
        AutomationElement? node = field;
        for (int depth = 0; node != null && depth < 64; depth++, node = TreeWalker.RawViewWalker.GetParent(node))
        {
            nint host = node.Current.NativeWindowHandle;
            if (host == 0) continue;
            return GetWindowThreadProcessId(host, out uint pid) == window.Thread && pid == window.Process &&
                IsWindowVisible(host) && IsWindowEnabled(host) && (host == window.Frame || IsChild(window.Frame, host)) &&
                (host == window.Focus || IsChild(host, window.Focus) || IsChild(window.Focus, host)) ? host : 0;
        }
        return 0;
    }

    private static Window? Focus()
    {
        nint frame = GetForegroundWindow();
        if (frame == 0 || !OnInputDesktop()) return null;
        uint thread = GetWindowThreadProcessId(frame, out uint pid);
        var info = new GuiInfo { Size = (uint)Marshal.SizeOf<GuiInfo>() };
        if (thread == 0 || pid == Environment.ProcessId || !GetGUIThreadInfo(thread, ref info) || info.Active != frame ||
            (info.Flags & ~1u) != 0 || info.Capture != 0 || info.Focus == 0 ||
            (info.Focus != frame && !IsChild(frame, info.Focus)) || GetWindowThreadProcessId(info.Focus, out uint focusPid) != thread ||
            focusPid != pid || !IsWindowVisible(info.Focus) || !IsWindowEnabled(frame) || !IsWindowEnabled(info.Focus) ||
            GetForegroundWindow() != frame) return null;
        return new(frame, info.Focus, thread, pid);
    }

    // Endpoint equality misses leaving and returning. Observe desktop/foreground
    // changes from the start of capture, plus the actual field identity via UIA. OS
    // notifications are asynchronous; this is a guard, not a focus reservation.
    private static Dispatcher? owner;
    private static nint foregroundHook, desktopHook;
    private static readonly EventProc changed = (_, kind, hwnd, _, _, _, _) =>
    {
        if (Volatile.Read(ref active) is not { } watch) return;
        if (kind == 0x20 || hwnd != watch.Window.Frame) watch.Reject("Focus left the original window or desktop.");
    };
    private static bool WatchWindows()
    {
        var ui = Dispatcher.FromThread(Thread.CurrentThread);
        if (ui == null || ui.HasShutdownStarted) return false;
        if (owner != null) return ui == owner;
        foregroundHook = SetWinEventHook(3, 3, 0, changed, 0, 0, 0);
        desktopHook = SetWinEventHook(0x20, 0x20, 0, changed, 0, 0, 0);
        if (foregroundHook == 0 || desktopHook == 0) { StopWatching(); return false; }
        owner = ui;
        ui.ShutdownStarted += (_, _) => StopWatching();
        return true;
    }
    private static void StopWatching()
    {
        Forget();
        if (desktopHook != 0) UnhookWinEvent(desktopHook);
        if (foregroundHook != 0) UnhookWinEvent(foregroundHook);
        desktopHook = foregroundHook = 0;
        owner = null;
    }

    private static bool AllowedProcess(uint pid)
    {
        using var process = OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, false, pid);
        if (process.IsInvalid || !OpenProcessToken(process, 8 /* TOKEN_QUERY */, out var token)) return false;
        using (token)
        {
            if (!TokenFlag(token, 20 /* TokenElevation */, out uint elevated, 4, out _) || elevated != 0 ||
                !TokenFlag(token, 26 /* TokenUIAccess */, out uint uiAccess, 4, out _) || uiAccess != 0) return false;
            GetTokenInformation(token, 25 /* TokenIntegrityLevel */, 0, 0, out uint size);
            if (size < nint.Size || size > 1024) return false;
            nint buffer = Marshal.AllocHGlobal((int)size);
            try
            {
                if (!GetTokenInformation(token, 25, buffer, size, out _)) return false;
                nint sid = Marshal.ReadIntPtr(buffer);
                if (sid == 0 || !IsValidSid(sid)) return false;
                byte count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                return count > 0 && unchecked((uint)Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)count - 1))) <= 0x2000; // medium
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    private static bool OnInputDesktop()
    {
        nint desktop = OpenInputDesktop(0, false, 1 /* DESKTOP_READOBJECTS */);
        if (desktop == 0) return false;
        try
        {
            var name = new StringBuilder(64);
            return GetUserObjectInformationW(desktop, 2 /* UOI_NAME */, name, (uint)name.Capacity * 2, out _) &&
                name.ToString().Equals("Default", StringComparison.OrdinalIgnoreCase);
        }
        finally { CloseDesktop(desktop); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct LastInputInfo { public uint Size, Time; }
    private static async Task<uint?> QuietInputAsync(CancellationToken ct)
    {
        const uint settleMs = 200;
        for (int retries = 0; LastInput() is uint last; retries++)
        {
            uint age = unchecked((uint)Environment.TickCount - last);
            if (age >= settleMs) return last;
            if (retries == 3) break;
            await Task.Delay((int)(settleMs - age), ct).ConfigureAwait(false);
        }
        return null;
    }
    private static uint? LastInput()
    {
        var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        return GetLastInputInfo(ref info) ? info.Time : null;
    }

    private static Input[]? UnicodeInput(string text)
    {
        if (text.Length is 0 or > 2048 || string.IsNullOrWhiteSpace(text)) return null;
        var input = new Input[text.Length * 2];
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            // Never turn transcription into Enter, Tab, backspace, etc. Do not
            // synthesize modifier releases or split/repair malformed surrogates.
            if (char.IsControl(c) || c is '\u2028' or '\u2029' ||
                (char.IsHighSurrogate(c) && (i + 1 == text.Length || !char.IsLowSurrogate(text[i + 1]))) ||
                (char.IsLowSurrogate(c) && (i == 0 || !char.IsHighSurrogate(text[i - 1])))) return null;
            var down = new Input { Type = 1, Data = new Payload { Key = new Key { Scan = c, Flags = 4 /* UNICODE */ } } };
            input[2 * i] = down;
            down.Data.Key.Flags |= 2; // KEYUP
            input[2 * i + 1] = down;
        }
        return input;
    }

    [StructLayout(LayoutKind.Sequential)] private struct GuiInfo
    {
        public uint Size, Flags;
        public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public int Left, Top, Right, Bottom;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Mouse { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Key { public ushort Vk, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Explicit)] private struct Payload { [FieldOffset(0)] public Mouse Mouse; [FieldOffset(0)] public Key Key; }
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public Payload Data; }
    private delegate void EventProc(nint hook, uint kind, nint window, int obj, int child, uint thread, uint time);
    [DllImport("user32")] private static extern nint SetWinEventHook(uint first, uint last, nint module, EventProc callback, uint process, uint thread, uint flags);
    [DllImport("user32")] private static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32")] private static extern nint GetForegroundWindow();
    [DllImport("user32")] private static extern bool GetGUIThreadInfo(uint thread, ref GuiInfo info);
    [DllImport("user32")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32")] private static extern bool IsChild(nint parent, nint child);
    [DllImport("user32")] private static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32")] private static extern bool IsWindowEnabled(nint hwnd);
    [DllImport("user32")] private static extern nint OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32")] private static extern bool CloseDesktop(nint desktop);
    [DllImport("user32", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern bool GetUserObjectInformationW(nint desktop, int index, StringBuilder name, uint bytes, out uint needed);
    [DllImport("user32")] private static extern bool GetLastInputInfo(ref LastInputInfo info);
    [DllImport("user32")] private static extern uint SendInput(uint count, Input[] input, int size);
    [DllImport("kernel32")] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("advapi32")] private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32", EntryPoint = "GetTokenInformation")] private static extern bool TokenFlag(SafeAccessTokenHandle token, int kind, out uint value, uint bytes, out uint needed);
    [DllImport("advapi32")] private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int kind, nint value, uint bytes, out uint needed);
    [DllImport("advapi32")] private static extern bool IsValidSid(nint sid);
    [DllImport("advapi32")] private static extern nint GetSidSubAuthorityCount(nint sid);
    [DllImport("advapi32")] private static extern nint GetSidSubAuthority(nint sid, uint index);
}
