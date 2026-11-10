using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Inlay.Windows;

// All user-visible transitions run on the WPF dispatcher. Capture and HTTP run off-thread.
internal sealed partial class AppController : IClientUi, IDisposable
{
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly CancellationTokenSource lifetime = new();
    private readonly DictationKeys keys;
    private readonly DispatcherTimer tick;
    private readonly Stopwatch elapsed = new();
    private readonly ClientSettings settings;
    private InlayApi? api;
    private bool connecting, disposed;
    private DateTime nextRefresh = DateTime.UtcNow.AddSeconds(30);
    private float peak;
    private CancellationTokenSource? take;
    private TaskCompletionSource? release;
    private bool testing, previewOnly;
    private CancellationTokenSource? chordOwner;
    internal event Action<string>? Notice;

    public ClientUiState State { get; private set; } = new();
    public event Action? Changed;

    internal AppController()
    {
        settings = ClientSettings.Load();
        LoadConnection();
        keys = new DictationKeys(() =>
        {
            chordOwner = null;
            if (take != null || connecting || disposed) return;
            if (api == null) { Notice?.Invoke("Connect to a server in This PC first."); return; }
            _ = StartAsync(false);
            chordOwner = take;
        }, () => FinishGesture(false), () => FinishGesture(true));
        tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        tick.Tick += (_, _) =>
        {
            if (take != null && !take.IsCancellationRequested && !TextDelivery.OnInputDesktop()) take.Cancel();
            if (State.Activity == UiActivity.Recording)
                Publish(State with { Level = Volatile.Read(ref peak), Elapsed = elapsed.Elapsed });
            if (DateTime.UtcNow >= nextRefresh && take == null && !connecting)
            {
                nextRefresh = DateTime.UtcNow.AddSeconds(45);
                _ = RefreshAsync();
            }
        };
        tick.Start();
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPower;
    }

    private void Publish(ClientUiState state)
    {
        if (disposed) return;
        State = state with { CanTest = state.ServerReady && !connecting && (take == null || testing) };
        Changed?.Invoke();
    }

    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff or SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect)
            dispatcher.BeginInvoke((Action)(() => _ = CancelAsync()));
    }
    private void OnPower(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) dispatcher.BeginInvoke((Action)(() => _ = CancelAsync()));
    }
    public void SetAutoCopyDictations(bool enabled)
    {
        settings.SetAutoCopyDictations(enabled);
        Publish(State with { AutoCopyDictations = enabled });
    }

    public Task ToggleTestAsync()
    {
        if (take == null) return StartAsync(true);
        if (testing) EndCapture();
        return Task.CompletedTask;
    }
    private void FinishGesture(bool interrupted)
    {
        if (chordOwner != null && chordOwner == take)
        {
            previewOnly |= interrupted;
            EndCapture();
        }
        chordOwner = null;
    }
    private void EndCapture()
    {
        if (State.Activity is UiActivity.Idle or UiActivity.Starting) take?.Cancel();
        else release?.TrySetResult();
    }
    public Task CancelAsync()
    {
        take?.Cancel();
        return Task.CompletedTask;
    }
    private void RequireIdle()
    {
        if (take != null || connecting) throw new InvalidOperationException("Finish the current operation first.");
    }
    private InlayApi Connected => api ?? throw new InvalidOperationException("Connect to a server in This PC first.");

    public void Dispose()
    {
        disposed = true;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPower;
        keys.Dispose();
        tick.Stop();
        take?.Cancel();
        lifetime.Cancel();
        lifetime.Dispose();
    }
}
