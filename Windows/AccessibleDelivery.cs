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
    internal readonly record struct NativeCaret(nint Owner, int Left, int Top, int Right, int Bottom);
    internal sealed record Window(nint Frame, nint Focus, uint Thread, uint Process, NativeCaret Caret);
    internal sealed class Target(Window window, long epoch, nint host, int[] id, TextPatternRange caret)
    {
        internal readonly Window Window = window;
        internal readonly long Epoch = epoch;
        internal readonly nint Host = host;
        internal readonly int[] Id = id;
        internal readonly TextPatternRange Caret = caret;
        internal int Used;
    }

    internal static async Task<Target?> CaptureAsync(CancellationToken ct)
    {
        long stamp = Interlocked.Increment(ref epoch); // another take invalidates outstanding tokens
        ct.ThrowIfCancellationRequested();
        if (!WatchWindows() || Focus() is not { } window) return null;
        var target = await ProbeAsync(window, stamp, null, ct).ConfigureAwait(false);
        return target != null && Current(stamp) && Focus() == window ? target : null;
    }

    internal static async Task<TextDelivery.Result> InsertAsync(Target? target, string text, CancellationToken ct)
    {
        if (target == null || Interlocked.Exchange(ref target.Used, 1) != 0)
            return Preview("No unused, verified editable caret.");
        ct.ThrowIfCancellationRequested();
        var input = UnicodeInput(text);
        if (input == null) return Preview("Text is empty, too long, or contains unsupported characters.");
        if (!Current(target.Epoch) || Focus() != target.Window || ShortcutHeld() || LastInput() is not uint inputTime)
            return Preview("Focus, desktop or keyboard state changed.");

        var verified = await ProbeAsync(target.Window, target.Epoch, target, ct).ConfigureAwait(false);
        // A click/key during the COM probe can move a virtual caret without
        // changing HWNDs or generating a timely accessibility notification.
        if (verified == null || Focus() != target.Window || LastInput() != inputTime || !Current(target.Epoch) || ShortcutHeld())
            return Preview("Could not verify the original writable field and caret.");
        ct.ThrowIfCancellationRequested();

        // SendInput targets the foreground queue, not an HWND. One bounded batch
        // avoids interleaving batches or retrying a partial write. Focus can still
        // change between validation and dispatch, including in the editor's own
        // handlers. Queue acceptance is NOT an insertion receipt (filters, IMEs,
        // app shortcuts, etc.); even caret motion cannot prove what was inserted.
        uint sent = SendInput((uint)input.Length, input, Marshal.SizeOf<Input>());
        return sent == 0 ? Preview("Windows did not queue the text.") : new("unconfirmed",
            sent == input.Length ? "Text was sent but insertion is unconfirmed. Check the field before copying the preview."
                                 : "Only part of the input was queued. Check the field before copying the preview.");
    }

    private static TextDelivery.Result Preview(string reason) => new("failed", reason + " Text is available in preview.");
    private static long epoch;
    private static bool Current(long stamp) => stamp == Interlocked.Read(ref epoch);
    private static int probing;
    private static bool watchingUia;

    // UIA crosses untrusted process boundaries. Use one outstanding read on the
    // thread pool's MTA, never the dispatcher/keyboard hook or a lock around COM.
    // If a provider hangs, callers time out and new probes fail closed rather than
    // leaking workers. An abandoned probe has no text and no path to SendInput.
    private static async Task<Target?> ProbeAsync(Window window, long stamp, Target? expected, CancellationToken ct)
    {
        if (Interlocked.CompareExchange(ref probing, 1, 0) != 0) return null;
        var read = Task.Run(() =>
        {
            try
            {
                if (ct.IsCancellationRequested || !Current(stamp) || !AllowedProcess(window.Process)) return null;
                if (!watchingUia)
                {
                    // One process-lifetime subscription, not one per take. Never call
                    // back into UIA from a focus notification, or retain its sender.
                    Automation.AddAutomationFocusChangedEventHandler((_, _) => Interlocked.Increment(ref epoch));
                    watchingUia = true;
                }
                return ReadField(window, stamp, expected);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException && ex is not AccessViolationException)
            { return null; } // disappearing elements, disabled accessibility, COM/provider failures
            finally { Volatile.Write(ref probing, 0); }
        });
        try { return await read.WaitAsync(TimeSpan.FromMilliseconds(1500), ct).ConfigureAwait(false); }
        catch (TimeoutException) { return null; }
    }

    private static Target? ReadField(Window window, long stamp, Target? expected)
    {
        if (!Current(stamp) || Focus() != window) return null;
        var field = AutomationElement.FocusedElement;
        if (field == null || field.Current.ProcessId != window.Process || field.Current.ControlType != ControlType.Edit ||
            field.Current.FrameworkId is not ("Chrome" or "Gecko" or "WPF")) return null;
        // The normal UIA defaults (e.g. IsPassword=false) aren't provider evidence.
        object Property(AutomationProperty p) => field.GetCurrentPropertyValue(p, ignoreDefaultValue: true);
        if (Property(AutomationElement.IsPasswordProperty) is not false ||
            Property(AutomationElement.IsOffscreenProperty) is not false ||
            Property(AutomationElement.IsEnabledProperty) is not true ||
            Property(AutomationElement.HasKeyboardFocusProperty) is not true ||
            field.Current.BoundingRectangle is not { Width: > 0, Height: > 0 }) return null;

        int[] id = field.GetRuntimeId();
        nint host = Host(field, window);
        if (id.Length == 0 || host == 0 || (expected != null && (host != expected.Host || !id.AsSpan().SequenceEqual(expected.Id)))) return null;
        if (!field.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) || pattern is not TextPattern text ||
            text.SupportedTextSelection == SupportedTextSelection.None) return null;
        var caret = CollapsedCaret(text);
        if (caret == null || (expected != null && !caret.Compare(expected.Caret))) return null;

        // Require positive writability evidence. A provider may omit the range
        // attribute for a plain Edit, but an explicit mixed/readonly run always wins.
        object readOnly = caret.GetAttributeValue(TextPattern.IsReadOnlyAttribute);
        object valueReadOnly = Property(ValuePattern.IsReadOnlyProperty);
        object hidden = caret.GetAttributeValue(TextPattern.IsHiddenAttribute);
        if (valueReadOnly is true || (readOnly is not false && !(readOnly == AutomationElement.NotSupported && valueReadOnly is false)) ||
            (hidden is not false && hidden != AutomationElement.NotSupported)) return null;
        return Current(stamp) && Automation.Compare(field, AutomationElement.FocusedElement) &&
            CollapsedCaret(text) is { } now && now.Compare(caret) ? new(window, stamp, host, id, now) : null;
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
        return new(frame, info.Focus, thread, pid, info.Caret == 0 ? default :
            new(info.Caret, info.Left, info.Top, info.Right, info.Bottom));
    }

    // Endpoint equality misses leaving and returning. Observe desktop/foreground
    // and native focus from the start of capture, plus virtual focus via UIA. OS
    // notifications are asynchronous; this is a guard, not a focus reservation.
    private static Dispatcher? owner;
    private static nint systemHook, focusHook;
    private static readonly EventProc changed = (_, kind, _, _, _, _, _) =>
    {
        if (kind is 3 or 0x20 or 0x8005) Interlocked.Increment(ref epoch);
    };
    private static bool WatchWindows()
    {
        var ui = Dispatcher.FromThread(Thread.CurrentThread);
        if (ui == null || ui.HasShutdownStarted) return false;
        if (owner != null) return ui == owner;
        systemHook = SetWinEventHook(3, 0x20, 0, changed, 0, 0, 0); // FOREGROUND through DESKTOPSWITCH
        focusHook = SetWinEventHook(0x8005, 0x8005, 0, changed, 0, 0, 0); // OBJECT_FOCUS
        if (systemHook == 0 || focusHook == 0) { StopWatching(); return false; }
        owner = ui;
        ui.ShutdownStarted += (_, _) => StopWatching();
        return true;
    }
    private static void StopWatching()
    {
        Interlocked.Increment(ref epoch);
        if (focusHook != 0) UnhookWinEvent(focusHook);
        if (systemHook != 0) UnhookWinEvent(systemHook);
        focusHook = systemHook = 0;
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
    private static uint? LastInput()
    {
        var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        return GetLastInputInfo(ref info) ? info.Time : null;
    }
    private static bool ShortcutHeld() => GetAsyncKeyState(0x10) < 0 || GetAsyncKeyState(0x11) < 0 ||
        GetAsyncKeyState(0x12) < 0 || GetAsyncKeyState(0x5B) < 0 || GetAsyncKeyState(0x5C) < 0;

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
    [DllImport("user32")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32")] private static extern uint SendInput(uint count, Input[] input, int size);
    [DllImport("kernel32")] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("advapi32")] private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32", EntryPoint = "GetTokenInformation")] private static extern bool TokenFlag(SafeAccessTokenHandle token, int kind, out uint value, uint bytes, out uint needed);
    [DllImport("advapi32")] private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int kind, nint value, uint bytes, out uint needed);
    [DllImport("advapi32")] private static extern bool IsValidSid(nint sid);
    [DllImport("advapi32")] private static extern nint GetSidSubAuthorityCount(nint sid);
    [DllImport("advapi32")] private static extern nint GetSidSubAuthority(nint sid, uint index);
}
