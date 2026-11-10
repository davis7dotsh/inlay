using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Inlay.Windows;

// Observe, don't own, the physical keys. In particular, never swallow a Win-down
// that we'd then have to replay to make Win+L, Win+E, or Win+Ctrl+D work.
internal sealed class DictationKeys : IDisposable
{
    private const int LeftCtrl = 0xA2, LeftWin = 0x5B, MenuMask = 0xE8;
    private readonly Action pressed, released, cancelled;
    private readonly Dispatcher ui = Dispatcher.CurrentDispatcher;
    private readonly TaskCompletionSource<Dispatcher> ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Thread thread;
    private readonly HookProc callback;
    private int disposed;

    // The hook, session messages, and watchdog all run on a dedicated message pump.
    // A slow UI (or an unresponsive foreign editor during Capture) can't block typing.
    private nint hook;
    private DispatcherTimer? watchdog;
    private readonly bool[] down = new bool[256];
    private int otherKeys, gesture;
    private bool active, disarmed, locked;

    internal DictationKeys(Action pressed, Action released, Action cancelled)
    {
        (this.pressed, this.released, this.cancelled) = (pressed, released, cancelled);
        callback = KeyboardEvent;
        thread = new Thread(Listen) { IsBackground = true, Name = "Inlay keyboard" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        ready.Task.GetAwaiter().GetResult();
    }

    private void Listen()
    {
        try
        {
            var pump = Dispatcher.CurrentDispatcher;
            using var window = new HwndSource(new HwndSourceParameters("Inlay input notifications") { WindowStyle = 0, Width = 0, Height = 0 });
            window.AddHook(WindowEvent);
            if (!WTSRegisterSessionNotification(window.Handle, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                hook = SetWindowsHookExW(13 /* WH_KEYBOARD_LL */, callback, GetModuleHandleW(null), 0);
                if (hook == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                Resync();
                watchdog = new DispatcherTimer(TimeSpan.FromMilliseconds(150), DispatcherPriority.Normal, Watch, pump);
                ready.SetResult(pump);
                Dispatcher.Run();
            }
            finally
            {
                watchdog?.Stop();
                if (hook != 0) UnhookWindowsHookEx(hook);
                WTSUnRegisterSessionNotification(window.Handle);
            }
        }
        catch (Exception error) when (!ready.Task.IsCompleted) { ready.SetException(error); }
    }

    private nint WindowEvent(nint hwnd, int msg, nint w, nint l, ref bool handled)
    {
        // Disconnect, logoff, lock, and suspend may take all remaining key-ups
        // to another desktop. Never interpret the eventual unlock as a release.
        if ((msg == 0x02B1 && (int)w is 2 or 4 or 6 or 7) || (msg == 0x0218 && w == 4))
        {
            locked = true;
            Cancel();
        }
        else if ((msg == 0x02B1 && (int)w is 1 or 3 or 5 or 8) || (msg == 0x0218 && (int)w is 7 or 18))
        {
            Cancel();
            locked = false;
            Resync();
        }
        return 0;
    }

    private void Resync()
    {
        otherKeys = 0;
        Array.Clear(down);
        // Skip mouse buttons and generic aliases of the left/right modifiers.
        for (int k = 8; k < 255; k++)
        {
            if (k is 0x10 or 0x11 or 0x12 || !IsDown(k)) continue;
            down[k] = true;
            if (k is not (LeftCtrl or LeftWin)) otherKeys++;
        }
        disarmed = down[LeftCtrl] || down[LeftWin];
    }

    private void Watch(object? sender, EventArgs e)
    {
        if (locked || (!down[LeftCtrl] && !down[LeftWin] && otherKeys == 0)) return;
        // Recover missed ups without synthesizing a release/commit. Polls can
        // disarm, never start a recording from a synthetic or pre-held key.
        for (int k = 8; k < down.Length; k++)
        {
            if (down[k] && !IsDown(k)) { Cancel(); Resync(); return; }
        }
    }

    private nint KeyboardEvent(int code, nint message, nint data)
    {
        if (code == 0 && !locked && Volatile.Read(ref disposed) == 0)
        {
            int key = Marshal.ReadInt32(data), flags = Marshal.ReadInt32(data, 8);
            if ((flags & 0x12) != 0) // injected events can disarm, never arm or release
            {
                if (key != MenuMask && (flags & 0x80) == 0 && (down[LeftCtrl] || down[LeftWin])) Cancel();
            }
            else if ((uint)key < down.Length)
            {
                if (key == 0x11) key = (flags & 1) == 0 ? LeftCtrl : 0xA3;
                if (key == 0x10) key = Marshal.ReadInt32(data, 4) == 0x36 ? 0xA1 : 0xA0;
                if (key == 0x12) key = (flags & 1) == 0 ? 0xA4 : 0xA5;
                bool held = (flags & 0x80) == 0;
                if (down[key] != held) Transition(key, held);
            }
        }
        return CallNextHookEx(0, code, message, data);
    }

    private void Transition(int key, bool held)
    {
        down[key] = held;
        if (key is not (LeftCtrl or LeftWin))
        {
            otherKeys += held ? 1 : -1;
            if (held && (down[LeftCtrl] || down[LeftWin])) Cancel();
            return;
        }
        if (!held)
        {
            if (active) { active = false; Post(released); }
            disarmed = down[LeftCtrl] || down[LeftWin]; // drain both before rearming
            return;
        }
        if (otherKeys != 0 || IsDown(0xA3) || IsDown(0x5C) || IsDown(0x10) || IsDown(0x12)) disarmed = true;
        if (disarmed || !down[LeftCtrl] || !down[LeftWin]) return;
        active = true;
        int id = ++gesture;
        // Mask the shell's menu activation only after both real downs are forwarded.
        // 0xE8 is unassigned, not a character, Ctrl, Alt, or Win. Its paired synthetic
        // events are ignored above. A solitary Win press is never masked.
        Dispatcher.CurrentDispatcher.BeginInvoke(() => { if (active && gesture == id) MaskStart(); });
        Post(TextDelivery.GuardPress(pressed));
    }

    private void Cancel()
    {
        disarmed = true;
        if (!active) return;
        active = false;
        Post(cancelled);
    }

    private void Post(Action action) => ui.BeginInvoke(DispatcherPriority.Normal, new Action(() =>
    {
        if (Volatile.Read(ref disposed) == 0) action();
    }));

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        ready.Task.GetAwaiter().GetResult().BeginInvokeShutdown(DispatcherPriority.Send);
        thread.Join();
    }

    // INPUT's union has MOUSEINPUT's size/alignment even for a keyboard event.
    [StructLayout(LayoutKind.Sequential)] private struct Mouse { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Key { public ushort Vk, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Explicit)] private struct Payload { [FieldOffset(0)] public Mouse Mouse; [FieldOffset(0)] public Key Key; }
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public Payload Data; }
    private static void MaskStart()
    {
        var input = new Input { Type = 1, Data = new Payload { Key = new Key { Vk = MenuMask } } };
        var up = input;
        up.Data.Key.Flags = 2;
        SendInput(2, [input, up], Marshal.SizeOf<Input>());
    }

    private static bool IsDown(int key) => GetAsyncKeyState(key) < 0;
    private delegate nint HookProc(int code, nint message, nint data);
    [DllImport("user32", SetLastError = true)] private static extern nint SetWindowsHookExW(int id, HookProc proc, nint module, uint thread);
    [DllImport("user32")] private static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32")] private static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("user32")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32")] private static extern uint SendInput(uint count, Input[] input, int size);
    [DllImport("kernel32", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern nint GetModuleHandleW(string? name);
    [DllImport("wtsapi32", SetLastError = true)] private static extern bool WTSRegisterSessionNotification(nint window, uint flags);
    [DllImport("wtsapi32")] private static extern bool WTSUnRegisterSessionNotification(nint window);
}
