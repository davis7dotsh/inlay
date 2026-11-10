using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Threading;
using Microsoft.Win32.SafeHandles;

namespace Inlay.Windows;

// UI-dispatcher API. No clipboard, simulated typing, focus changes, selection changes,
// or whole-value replacement. Only a collapsed caret in a known native editor qualifies.
internal static class TextDelivery
{
    internal sealed record Result(string Status, string Message)
    {
        internal bool Inserted => Status == "inserted";
    }
    internal sealed class Target { }
    private sealed record Window(nint Frame, nint Edit, uint Thread, uint Process, bool Notepad);
    private sealed record Position(int Caret, int Length, long Limit, bool Multiline);
    private readonly record struct Point(nint Frame, nint Edit, nint Caret, int X, int Y, int Right, int Bottom);
    private sealed record CaptureState(Target Token, Window Window, Position Position, Point Point, Watch Watch);
    [ThreadStatic] private static CaptureState? current;
    [ThreadStatic] private static Point? pressPoint;

    // The UI dispatcher might be busy between the physical press and its notification.
    // Stamp the foreground thread's native caret in one non-messaging OS call on the
    // hook thread; inspect styles, selection, permissions, etc. only on the UI thread.
    internal static Action GuardPress(Action notify)
    {
        var point = Probe();
        long time = Environment.TickCount64;
        return () =>
        {
            pressPoint = Environment.TickCount64 - time <= 250 ? point : default(Point);
            try { notify(); }
            finally { pressPoint = null; }
        };
    }

    private static Point Probe()
    {
        var info = new GuiInfo { Size = (uint)Marshal.SizeOf<GuiInfo>() };
        return GetGUIThreadInfo(0, ref info) ?
            new(info.Active, info.Focus, info.Caret, info.Left, info.Top, info.Right, info.Bottom) : default;
    }

    internal static Target? Capture()
    {
        Forget();
        var dispatcher = Dispatcher.FromThread(Thread.CurrentThread);
        if (dispatcher == null || dispatcher.HasShutdownStarted || !OnInputDesktop()) return null;
        var point = pressPoint ?? Probe();
        var window = Focus();
        if (window == null || window.Frame != point.Frame || window.Edit != point.Edit || !AllowedProcess(window)) return null;
        var watch = new Watch(window, dispatcher);
        if (watch.Installed && ReadPosition(window) is { } position && Focus() == window && Probe() == point && !watch.Changed)
        {
            var token = new Target();
            current = new(token, window, position, point, watch);
            return token;
        }
        watch.Dispose();
        return null;
    }

    internal static Result Insert(Target? target, string text)
    {
        var saved = current;
        if (target == null || saved == null || target != saved.Token)
            return Preview("No verified editable caret at the start of this take.");
        try
        {
            if (string.IsNullOrWhiteSpace(text) || text.Contains('\0')) return Preview("No insertable text.");
            var (_, window, before, point, watch) = saved;
            if (watch.Changed || !OnInputDesktop() || Focus() != window || !AllowedProcess(window))
                return Preview("The original editor is no longer a safe destination.");
            if (!before.Multiline && (text.Contains('\r') || text.Contains('\n')))
                return Preview("The destination only accepts a single line.");
            // Native EDIT stores CRLF; Rich Edit uses one paragraph mark per break.
            string value = text.ReplaceLineEndings(window.Notepad ? "\r" : "\r\n");
            if ((long)before.Length + value.Length > before.Limit || (long)before.Caret + value.Length >= ushort.MaxValue)
                return Preview("Cannot verify the complete insertion in this editor.");
            if (ReadPosition(window) != before || !OnInputDesktop() || watch.Changed || Focus() != window || Probe() != point || ShortcutHeld())
                return Preview("The field, caret or keyboard state changed.");

            // Target the original HWND, never the active keyboard destination. There is
            // no atomic compare-and-insert across processes. Keep the recheck adjacent
            // to the single synchronous write; a timeout may already have taken effect.
            if (SendText(window.Edit, 0x00C2 /* EM_REPLACESEL */, 1, value, SendFlags, TimeoutMs, out _) != 0 &&
                Focus() == window && ReadPosition(window) is { } after &&
                after.Caret == before.Caret + value.Length &&
                (after.Length == before.Length + value.Length ||
                 (window.Notepad && after.Length == before.Length + value.ReplaceLineEndings("\r\n").Length)))
                return new("inserted", "Inserted at the original caret.");
            return new("unconfirmed", "Insertion could not be confirmed. Check the editor before copying the preview.");
        }
        finally { Forget(); } // tokens are single-use, including uncertain writes
    }

    private static Result Preview(string reason) => new("failed", reason + " Text is available in preview.");
    // Guard the short handoff from the hook to the dispatcher. After it, a web
    // editor's UIA selection (not the proxy caret's pixels) identifies the caret.
    internal static (nint Frame, nint Edit) PressWindows => pressPoint is { } p && Probe() == p ? (p.Frame, p.Edit) : default;
    internal static void Forget()
    {
        var old = current;
        current = null;
        old?.Watch.Dispose();
    }

    private static Window? Focus()
    {
        nint frame = GetForegroundWindow();
        if (frame == 0) return null;
        uint thread = GetWindowThreadProcessId(frame, out uint pid);
        var info = new GuiInfo { Size = (uint)Marshal.SizeOf<GuiInfo>() };
        if (thread == 0 || pid == Environment.ProcessId || !GetGUIThreadInfo(thread, ref info) ||
            info.Active != frame || (info.Flags & ~1u) != 0 || info.Capture != 0 || info.Focus == 0 ||
            GetWindowThreadProcessId(info.Focus, out uint focusPid) != thread || focusPid != pid ||
            (info.Caret != 0 && info.Caret != info.Focus) || !IsChild(frame, info.Focus) ||
            !IsWindowVisible(info.Focus) || !IsWindowEnabled(info.Focus) || !IsWindowUnicode(info.Focus)) return null;
        var name = new StringBuilder(128);
        if (GetClassNameW(info.Focus, name, name.Capacity) == 0) return null;
        string cls = name.ToString();
        bool notepad = cls.Equals("RichEditD2DPT", StringComparison.OrdinalIgnoreCase);
        if (!notepad && (!cls.Equals("Edit", StringComparison.OrdinalIgnoreCase) || info.Caret != info.Focus)) return null;
        return new(frame, info.Focus, thread, pid, notepad);
    }

    private static Position? ReadPosition(Window window)
    {
        nint edit = window.Edit;
        int style = GetWindowLongW(edit, -16);
        // Password, read-only, case conversion, OEM conversion, and numeric masks.
        int refusedStyles = window.Notepad ? 0x20 | 0x800 : 0x20 | 0x800 | 0x08 | 0x10 | 0x400 | 0x2000;
        if (style == 0 || (style & refusedStyles) != 0 ||
            Query(edit, 0x00D2 /* EM_GETPASSWORDCHAR */) != 0 ||
            (window.Notepad && !(Query(edit, 0x045A /* EM_GETTEXTMODE */) is long mode && (mode & 3) == 1))) return null;
        if (Query(edit, 0x000E /* WM_GETTEXTLENGTH */) is not (long length and >= 0 and <= int.MaxValue) ||
            Query(edit, 0x00D5 /* EM_GETLIMITTEXT */) is not (long limit and > 0) ||
            Query(edit, 0x00B0 /* EM_GETSEL */) is not long selection) return null;
        // EM_GETSEL's packed return is -1 for large offsets. Don't truncate it,
        // don't move the selection to find out, and never replace selected text.
        if (unchecked((int)selection) == -1) return null;
        int start = (int)(selection & 0xffff), end = (int)((selection >> 16) & 0xffff);
        return start == end && end <= length ? new(start, (int)length, limit, (style & 4) != 0) : null;
    }

    private const uint SendFlags = 1 | 2 | 0x20; // BLOCK | ABORTIFHUNG | ERRORONEXIT
    private const uint TimeoutMs = 100;
    private static long? Query(nint edit, uint message) =>
        SendMessageTimeoutW(edit, message, 0, 0, SendFlags, TimeoutMs, out var value) != 0 ? (long)value : null;

    private static bool AllowedProcess(Window window)
    {
        using var process = OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, false, window.Process);
        if (process.IsInvalid || !OpenProcessToken(process, 8 /* TOKEN_QUERY */, out var token)) return false;
        using (token)
        {
            if (!GetElevation(token, 20 /* TokenElevation */, out uint elevation, 4, out _) || elevation != 0) return false;
            // Reject high/system/UIAccess integrity even when TokenElevation is false.
            GetTokenInformation(token, 25 /* TokenIntegrityLevel */, 0, 0, out uint bytes);
            if (bytes < (uint)nint.Size || bytes > 1024) return false;
            nint buffer = Marshal.AllocHGlobal((int)bytes);
            try
            {
                if (!GetTokenInformation(token, 25, buffer, bytes, out _)) return false;
                nint sid = Marshal.ReadIntPtr(buffer);
                if (sid == 0 || !IsValidSid(sid)) return false;
                byte count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                if (count == 0 || unchecked((uint)Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)count - 1))) > 0x2000) return false;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        // Do not write to arbitrary rich-text engines, protected runs, web views,
        // terminals, or emulated editors. Only Notepad's packaged plain-text host.
        if (!window.Notepad) return true;
        uint chars = 128;
        var family = new StringBuilder((int)chars);
        return GetPackageFamilyName(process, ref chars, family) == 0 &&
            family.ToString().Equals("Microsoft.WindowsNotepad_8wekyb3d8bbwe", StringComparison.OrdinalIgnoreCase);
    }

    internal static bool OnInputDesktop()
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

    internal static bool ShortcutHeld() => GetAsyncKeyState(0x10) < 0 || GetAsyncKeyState(0x11) < 0 ||
        GetAsyncKeyState(0x12) < 0 || GetAsyncKeyState(0x5B) < 0 || GetAsyncKeyState(0x5C) < 0;

    // Endpoint comparisons alone miss leaving a field and coming back. Keep a
    // bounded, dispatcher-owned watch until delivery, the next press, or shutdown.
    // Observe identities/events only: never read or retain the editor's document.
    private sealed class Watch : IDisposable
    {
        private readonly List<nint> hooks = [];
        private readonly EventProc callback;
        private readonly Dispatcher owner;
        internal bool Installed => hooks.Count == 3;
        internal bool Changed { get; private set; }

        internal Watch(Window window, Dispatcher owner)
        {
            this.owner = owner;
            callback = (_, kind, hwnd, obj, _, _, _) =>
            {
                if (kind is 3 or 0x20 or 0x8005 ||
                    (hwnd == window.Edit && (((kind is 0x8001 or 0x8003) && (obj is 0 or -4)) ||
                        kind is 0x8006 or 0x8007 or 0x8008 or 0x8009 or 0x800E ||
                        (kind == 0x800B && obj == -8 /* OBJID_CARET */)))) Changed = true;
            };
            Add(3, 3, 0, 0); // EVENT_SYSTEM_FOREGROUND, including switches to Inlay
            Add(0x20, 0x20, 0, 0); // EVENT_SYSTEM_DESKTOPSWITCH
            Add(0x8001, 0x800E, window.Process, window.Thread); // original UI thread only
            owner.ShutdownStarted += Shutdown;
        }

        private void Add(uint first, uint last, uint process, uint thread)
        {
            nint handle = SetWinEventHook(first, last, 0, callback, process, thread, 0 /* OUTOFCONTEXT */);
            if (handle != 0) hooks.Add(handle);
        }
        private void Shutdown(object? sender, EventArgs args) => Forget();
        public void Dispose()
        {
            owner.ShutdownStarted -= Shutdown;
            foreach (nint handle in hooks) UnhookWinEvent(handle);
            hooks.Clear();
        }
    }

    [StructLayout(LayoutKind.Sequential)] private struct GuiInfo
    {
        public uint Size, Flags;
        public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public int Left, Top, Right, Bottom;
    }
    private delegate void EventProc(nint hook, uint kind, nint window, int obj, int child, uint thread, uint time);
    [DllImport("user32")] private static extern nint SetWinEventHook(uint first, uint last, nint module, EventProc callback, uint process, uint thread, uint flags);
    [DllImport("user32")] private static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32")] private static extern nint GetForegroundWindow();
    [DllImport("user32")] private static extern bool GetGUIThreadInfo(uint thread, ref GuiInfo info);
    [DllImport("user32")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32")] private static extern bool IsChild(nint parent, nint child);
    [DllImport("user32")] private static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32")] private static extern bool IsWindowEnabled(nint hwnd);
    [DllImport("user32")] private static extern bool IsWindowUnicode(nint hwnd);
    [DllImport("user32", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern int GetClassNameW(nint hwnd, StringBuilder name, int size);
    [DllImport("user32")] private static extern int GetWindowLongW(nint hwnd, int index);
    [DllImport("user32")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32")] private static extern nint OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32")] private static extern bool CloseDesktop(nint desktop);
    [DllImport("user32", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern bool GetUserObjectInformationW(nint desktop, int index, StringBuilder name, uint bytes, out uint needed);
    [DllImport("user32")] private static extern nint SendMessageTimeoutW(nint hwnd, uint message, nuint w, nint l, uint flags, uint timeout, out nuint result);
    [DllImport("user32", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern nint SendText(nint hwnd, uint message, nuint w, string l, uint flags, uint timeout, out nuint result);
    [DllImport("kernel32")] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern int GetPackageFamilyName(SafeProcessHandle process, ref uint length, StringBuilder family);
    [DllImport("advapi32")] private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32", EntryPoint = "GetTokenInformation")] private static extern bool GetElevation(SafeAccessTokenHandle token, int kind, out uint value, uint bytes, out uint needed);
    [DllImport("advapi32")] private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int kind, nint value, uint bytes, out uint needed);
    [DllImport("advapi32")] private static extern bool IsValidSid(nint sid);
    [DllImport("advapi32")] private static extern nint GetSidSubAuthorityCount(nint sid);
    [DllImport("advapi32")] private static extern nint GetSidSubAuthority(nint sid, uint index);
}
