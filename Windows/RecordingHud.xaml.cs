using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Interop;
using System.Windows.Shapes;

namespace Inlay.Windows;

internal partial class RecordingHud : Window
{
    private const int ExStyle = -20, NoActivate = 0x08000000, ToolWindow = 0x80, Transparent = 0x20;
    private const uint SwpNoActivate = 0x0010;
    private readonly Rectangle[] bars = new Rectangle[9];
    private TimeSpan? lastSample;
    private nint handle;

    internal RecordingHud()
    {
        InitializeComponent();
        for (int i = 0; i < bars.Length; i++)
        {
            var bar = new Rectangle { Width = 3, Height = 3, RadiusX = 1.5, RadiusY = 1.5,
                Margin = new Thickness(1.5, 0, 1.5, 0), VerticalAlignment = VerticalAlignment.Center };
            bar.SetResourceReference(Shape.FillProperty, "Accent");
            bars[i] = bar; MeterBars.Children.Add(bar);
        }
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        handle = new WindowInteropHelper(this).Handle;
        // In addition to WPF's ShowActivated=false, never accept activation or mouse input,
        // including on subsequent shows above another app's focused text field.
        SetWindowLongPtr(handle, ExStyle, GetWindowLongPtr(handle, ExStyle) | NoActivate | ToolWindow | Transparent);
    }

    internal void Update(ClientUiState state)
    {
        if (state.Activity == UiActivity.Idle)
        {
            if (IsVisible) Hide();
            lastSample = null;
            return;
        }
        bool recording = state.Activity == UiActivity.Recording;
        Listening.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        Working.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
        if (recording)
        {
            if (lastSample == null) foreach (var bar in bars) bar.Height = 3;
            if (lastSample != state.Elapsed)
            {
                for (int i = 0; i < bars.Length - 1; i++) bars[i].Height = bars[i + 1].Height;
                double level = double.IsFinite(state.Level) ? Math.Clamp(state.Level, 0, 1) : 0;
                bars[^1].Height = 3 + 20 * level;
                lastSample = state.Elapsed;
            }
            Clock.Text = MainWindow.Duration(state.Elapsed);
        }
        else
        {
            lastSample = null;
            Stage.Text = string.IsNullOrWhiteSpace(state.ActivityText)
                ? state.Activity == UiActivity.Starting ? "Starting microphone" : "Processing"
                : state.ActivityText;
        }
        AutomationProperties.SetName(this, recording ? $"Inlay recording, {Clock.Text}" : $"Inlay, {Stage.Text}");
        if (IsVisible) return;
        nint monitor = MonitorFromWindow(GetForegroundWindow(), 2);
        new WindowInteropHelper(this).EnsureHandle();
        Position(monitor);
        Show();
        Position(monitor); // WPF finalizes the target monitor's DPI on the first show.
    }

    private void Position(nint monitor)
    {
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (monitor == 0 || !GetMonitorInfo(monitor, ref info)) return;
        double scale = GetDpiForMonitor(monitor, 0, out uint dpi, out _) == 0 ? dpi / 96.0 : 1;
        int width = (int)Math.Round(Width * scale), height = (int)Math.Round(Height * scale);
        int x = info.Work.Left + (info.Work.Right - info.Work.Left - width) / 2;
        int y = info.Work.Bottom - height - (int)Math.Round(18 * scale);
        SetWindowPos(handle, -1, x, y, width, height, SwpNoActivate);
    }

    [StructLayout(LayoutKind.Sequential)] private struct Rect { internal int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { internal uint Size; internal Rect Monitor, Work; internal uint Flags; }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern nint SetWindowLongPtr(nint window, int index, nint value);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int w, int h, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);
}
