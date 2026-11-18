using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace Inlay.Windows;

internal partial class MainWindow : Window
{
    private readonly IClientUi app;
    private readonly RecordingHud hud;
    private readonly FrameworkElement[] pages;
    private ClientUiState? previous;
    private bool rendering, refreshing, connecting, choosingInput, prefsBusy, settingDraft, closed;
    private int historyRequest, detailRequest, settingsGeneration;
    private IReadOnlyList<UiHistoryEntry> history = Array.Empty<UiHistoryEntry>();
    private UiPreferences? baseline;
    private string? selectedText, historyCursor;
    private bool filtering;
    private sealed record Option(string Name, string Code);
    private static readonly Option[] Languages = {
        new("Automatic", "auto"), new("English", "en"), new("Spanish", "es"), new("French", "fr"),
        new("German", "de"), new("Italian", "it"), new("Portuguese", "pt"), new("Dutch", "nl"), new("Polish", "pl"),
        new("Russian", "ru"), new("Ukrainian", "uk"), new("Swedish", "sv"), new("Japanese", "ja"), new("Chinese", "zh"),
        new("Korean", "ko"), new("Hindi", "hi"), new("Arabic", "ar")
    };

    internal MainWindow(AppController app)
    {
        this.app = app;
        InitializeComponent();
        pages = [DictationPage, HistoryPage, MicPage, ServerPage, DevicePage];
        hud = new RecordingHud();
        ApplyTheme();
        SystemEvents.UserPreferenceChanged += ThemeChanged;
        LanguagePicker.ItemsSource = Languages;
        EndpointBox.Text = app.State.Endpoint;
        DeviceNameBox.Text = app.State.DeviceName;
        Navigation.SelectedIndex = 0;
        app.Changed += SnapshotChanged;
        Render();
    }

    protected override void OnClosed(EventArgs e)
    {
        closed = true;
        app.Changed -= SnapshotChanged;
        SystemEvents.UserPreferenceChanged -= ThemeChanged;
        if (!Dispatcher.HasShutdownStarted) hud.Close();
        base.OnClosed(e);
    }

    private void ThemeChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (!Dispatcher.HasShutdownStarted) Dispatcher.InvokeAsync(() => { if (!closed) ApplyTheme(); });
    }
    private void ApplyTheme()
    {
        bool dark = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is 0;
        ApplyPalette(Resources, dark);
        ApplyPalette(hud.Resources, dark);
    }
    private static void ApplyPalette(ResourceDictionary resources, bool dark)
    {
        (string Key, string Glacier, Brush Contrast)[] palette = [
            ("Ink", "#EDF5FA", SystemColors.WindowTextBrush), ("Muted", "#A4B8C7", SystemColors.WindowTextBrush),
            ("CanvasBrush", "#1B252E", SystemColors.WindowBrush), ("Surface", "#222C35", SystemColors.WindowBrush),
            ("SidebarBrush", "#2B3E4D", SystemColors.WindowBrush), ("Tint", "#3A5265", SystemColors.ControlBrush),
            ("Line", "#485B6B", SystemColors.WindowTextBrush), ("Accent", "#A7D6F5", SystemColors.HighlightBrush),
            ("AccentInk", "#A7D6F5", SystemColors.WindowTextBrush), ("OnAccent", "#192C3A", SystemColors.HighlightTextBrush),
            ("Warning", "#FFB340", SystemColors.WindowTextBrush), ("Success", "#81C995", SystemColors.WindowTextBrush)
        ];
        foreach (var (key, glacier, contrast) in palette)
        {
            if (SystemParameters.HighContrast) resources[key] = contrast;
            else if (dark) resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(glacier));
            else resources.Remove(key); // use the warm palette in the merged dictionary
        }
    }

    private void SnapshotChanged()
    {
        if (closed || Dispatcher.HasShutdownStarted) return;
        if (Dispatcher.CheckAccess()) Render();
        else Dispatcher.InvokeAsync(Render);
    }
    private static Visibility Visible(bool yes) => yes ? Visibility.Visible : Visibility.Collapsed;
    private void Render()
    {
        if (closed) return;
        var state = app.State;
        var busy = state.Activity != UiActivity.Idle;
        var listening = state.Activity == UiActivity.Recording;
        var dictating = busy && !state.IsTesting;
        rendering = true;
        try
        {
            if (previous != null && (state.Endpoint != previous.Endpoint || state.DeviceName != previous.DeviceName))
                ResetSharedPages();
            if (previous?.KeyLabel != state.KeyLabel || previous?.Activity != state.Activity)
                SetKeyCaps(state.KeyLabel, dictating && listening);
            SideStatus.ToolTip = SideStatus.Text = MainStatus.Text = state.ServerStatus;
            MainStatus.ToolTip = state.Endpoint;
            string dot = state.ServerReady ? "Success" : "Warning";
            SideDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, dot);
            MainDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, dot);
            DictationHeading.Text = state.HoldToTalk ? "Hold to dictate." : "Tap to dictate.";
            TranscriptHeading.Text = dictating ? "Current dictation" : "Last dictation";
            if (Transcript.Text != state.Transcript) Transcript.Text = state.Transcript;
            CopyLast.IsEnabled = !dictating && !string.IsNullOrWhiteSpace(state.Transcript);
            Transcript.Visibility = Visible(!dictating);
            TranscriptPlaceholder.Visibility = Visible(!dictating && state.Transcript.Length == 0);
            LivePanel.Visibility = Visible(dictating);
            LiveStatus.Text = state.ActivityText;
            LiveDetail.Text = listening ? $"{Duration(state.Elapsed)}   ·   {state.InputName}" : state.InputName;
            if (previous == null || state.Delivery != previous.Delivery || state.Activity != previous.Activity)
                DeliveryMessage.Text = state.Delivery;
            bool activeTest = state.IsTesting && state.TestResult == null;
            string test = activeTest ? (listening ? "Finish test" : "Cancel test") : listening ? "Release keys to finish" : "Test microphone";
            DictateTest.Content = MicrophoneTest.Content = test;
            DictateTest.IsEnabled = MicrophoneTest.IsEnabled = busy ? activeTest : state.CanTest;
            CheckConnection.IsEnabled = RefreshInputs.IsEnabled = !busy && !refreshing && !connecting;
            Connect.IsEnabled = !busy && !connecting;
            if (!choosingInput && !ReferenceEquals(InputPicker.ItemsSource, state.Inputs))
                InputPicker.ItemsSource = state.Inputs;
            if (!choosingInput && !Equals(InputPicker.SelectedValue, state.InputId)) InputPicker.SelectedValue = state.InputId;
            InputPicker.IsEnabled = !choosingInput && !busy && state.Inputs.Count != 0;
            ResolvedInput.Text = string.IsNullOrEmpty(state.InputName) ? "No input selected" : state.InputName;
            MicMeter.Value = listening && double.IsFinite(state.Level) ? Math.Clamp(state.Level, 0, 1) : 0;
            MicMeterLabel.Text = listening ? $"Input level   ·   {Duration(state.Elapsed)}" : "Input level";
            if (previous == null || state.TestResult != previous.TestResult || state.IsTesting != previous.IsTesting ||
                (state.IsTesting && state.ActivityText != previous.ActivityText))
            {
                MicMessage.Text = state.TestResult?.Message ?? (state.IsTesting ? state.ActivityText : "");
                var text = state.TestResult?.Transcript ?? "";
                if (MicTranscript.Text != text) MicTranscript.Text = text;
                MicTranscript.Visibility = string.IsNullOrWhiteSpace(text) ? Visibility.Hidden : Visibility.Visible;
            }
            if (previous == null || previous.ServerStatus != state.ServerStatus) DeviceMessage.Text = state.ServerStatus;
            AutoCopyDictations.IsChecked = state.AutoCopyDictations;
            DeviceKey.Text = state.KeyLabel;
            DeviceTrigger.Text = state.HoldToTalk ? "Hold to talk" : "Tap to toggle";
            hud.Update(state);
            previous = state;
        }
        finally { rendering = false; }
    }
    private void SetKeyCaps(string chord, bool pressed)
    {
        KeyCaps.Children.Clear();
        var keys = chord.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var key in keys)
        {
            if (KeyCaps.Children.Count > 0) KeyCaps.Children.Add(new TextBlock { Text = "+", VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7, Margin = new Thickness(5,0,5,0) });
            var words = key.Split(' ', 2);
            var label = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            if (words.Length > 1) label.Children.Add(new TextBlock { Text = words[0], FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center });
            label.Children.Add(new TextBlock { Text = words[^1] == "Windows" ? "Win" : words[^1], FontSize = 20, HorizontalAlignment = HorizontalAlignment.Center });
            var cap = new Border { Child = label, MinWidth = 53, Height = 56, Padding = new Thickness(6,0,6,0), CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(1,1,1,pressed ? 1 : 4), ToolTip = key };
            cap.SetResourceReference(Border.BackgroundProperty, pressed ? "Tint" : "Surface");
            cap.SetResourceReference(Border.BorderBrushProperty, "Line");
            label.SetResourceReference(TextBlock.ForegroundProperty, "AccentInk");
            AutomationProperties.SetName(cap, key);
            KeyCaps.Children.Add(cap);
        }
    }
    internal static string Duration(TimeSpan time) => $"{Math.Max(0, (int)time.TotalMinutes)}:{Math.Max(0,time.Seconds):00}";

    private async void NavigationChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Navigation.SelectedItem is not ListBoxItem row || pages == null) return;
        int index = Navigation.SelectedIndex;
        for (int i = 0; i < pages.Length; i++) pages[i].Visibility = Visible(i == index);
        Title = $"Inlay · {row.Tag}";
        if (index == 1) await LoadHistory();
        if (index == 3 && !PrefsDirty && !prefsBusy) await LoadShared();
    }
    private void WindowKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers == ModifierKeys.Control && e.Key is >= Key.D1 and <= Key.D5)
        { Navigation.SelectedIndex = (int)e.Key - (int)Key.D1; e.Handled = true; }
        else if (e.Key == Key.Escape && app.State.Activity != UiActivity.Idle)
        { CancelClicked(sender, e); e.Handled = true; }
    }
    private void DeviceClicked(object sender, RoutedEventArgs e) => Navigation.SelectedIndex = 4;
    private void HistoryClicked(object sender, RoutedEventArgs e) => Navigation.SelectedIndex = 1;
    private async void RefreshClicked(object sender, RoutedEventArgs e)
    {
        if (refreshing) return;
        refreshing = true; Render();
        try { await app.RefreshAsync(); }
        catch (Exception ex) { DeliveryMessage.Text = MicMessage.Text = ex.Message; }
        finally { refreshing = false; Render(); }
    }
    private async void TestClicked(object sender, RoutedEventArgs e)
    {
        if (sender == DictateTest) Navigation.SelectedIndex = 2;
        try
        {
            if (app.State.IsTesting && app.State.Activity != UiActivity.Recording) await app.CancelAsync();
            else await app.ToggleTestAsync();
        }
        catch (Exception ex) { MicMessage.Text = ex.Message; }
    }
    private async void CancelClicked(object sender, RoutedEventArgs e)
    {
        try { await app.CancelAsync(); } catch (Exception ex) { DeliveryMessage.Text = MicMessage.Text = ex.Message; }
    }
    private void PrivacyClicked(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); }
        catch (Exception ex) { MicMessage.Text = ex.Message; }
    }
    private async void InputChanged(object sender, SelectionChangedEventArgs e)
    {
        if (rendering || choosingInput || InputPicker.SelectedItem is not UiInput input || input.Id == app.State.InputId) return;
        choosingInput = true; InputPicker.IsEnabled = false;
        try { await app.SelectInputAsync(input.Id); }
        catch (Exception ex) { MicMessage.Text = ex.Message; }
        finally { choosingInput = false; Render(); }
    }
    private async void ConnectClicked(object sender, RoutedEventArgs e)
    {
        if (connecting) return;
        string endpoint = EndpointBox.Text.Trim(), name = DeviceNameBox.Text.Trim();
        if (endpoint.Length == 0 || name.Length == 0) { DeviceMessage.Text = "Enter a server address and device name."; return; }
        connecting = true; EndpointBox.IsEnabled = DeviceNameBox.IsEnabled = TokenBox.IsEnabled = false; Render();
        try
        {
            await app.ConnectAsync(endpoint, TokenBox.Password, name);
            TokenBox.Clear(); EndpointBox.Text = app.State.Endpoint; DeviceNameBox.Text = app.State.DeviceName;
            ResetSharedPages(); DeviceMessage.Text = app.State.ServerStatus;
        }
        catch (Exception ex)
        {
            // The previous connection stays active. Never leave the form naming a server dictation won't use.
            EndpointBox.Text = app.State.Endpoint; DeviceNameBox.Text = app.State.DeviceName;
            DeviceMessage.Text = !app.HasConnection ? ex.Message
                : $"{ex.Message} Still connected to {app.State.Endpoint}.";
        }
        finally { TokenBox.Clear(); connecting = false; EndpointBox.IsEnabled = DeviceNameBox.IsEnabled = TokenBox.IsEnabled = true; Render(); }
    }
    private void AutoCopyClicked(object sender, RoutedEventArgs e)
    {
        try { app.SetAutoCopyDictations(AutoCopyDictations.IsChecked == true); }
        catch (Exception ex) { Render(); DeviceMessage.Text = $"Couldn’t save the clipboard setting: {ex.Message}"; }
    }
    private static string CopyText(string text) => DictationClipboard.TryCopy(text)
        ? "Copied to clipboard." : "Couldn’t copy to the clipboard. Try again.";
    private void CopyLastClicked(object sender, RoutedEventArgs e)
    { if (app.State.Transcript.Length != 0) DeliveryMessage.Text = CopyText(app.State.Transcript); }
    private void CopySessionClicked(object sender, RoutedEventArgs e)
    { if (!string.IsNullOrEmpty(selectedText)) HistoryMessage.Text = CopyText(selectedText); }

    private void ResetSharedPages()
    {
        ++historyRequest; ++settingsGeneration;
        history = Array.Empty<UiHistoryEntry>(); historyCursor = null; HistoryMore.Visibility = Visibility.Collapsed;
        ApplyHistory(null, "");
        HistoryRefresh.IsEnabled = true;
        baseline = null; settingDraft = true;
        LanguagePicker.SelectedIndex = -1; Proofreading.IsChecked = false; Prompt.Clear(); Vocabulary.Clear();
        settingDraft = prefsBusy = false; UpdateSharedEditor();
        SharedMessage.Text = "Reload to see server preferences.";
    }
    private async void HistoryRefreshClicked(object sender, RoutedEventArgs e) => await LoadHistory();
    private async void MoreHistoryClicked(object sender, RoutedEventArgs e) { if (historyCursor != null) await LoadHistory(historyCursor); }
    private async Task LoadHistory(string? before = null)
    {
        int request = ++historyRequest;
        var previousId = (Sessions.SelectedItem as UiHistoryEntry)?.Id;
        HistoryRefresh.IsEnabled = HistoryMore.IsEnabled = false; HistoryMessage.Text = "Loading shared history…";
        try
        {
            var page = await app.GetHistoryAsync(before);
            if (request != historyRequest || closed) return;
            history = before == null ? page.Items : history.Concat(page.Items).DistinctBy(row => row.Id).ToArray();
            historyCursor = page.NextCursor;
            HistoryMore.Visibility = Visible(historyCursor != null);
            ApplyHistory(previousId, DeviceFilter.SelectedValue as string ?? "");
            HistoryMessage.Text = "Shared history";
        }
        catch (Exception ex) { if (request == historyRequest) HistoryMessage.Text = ex.Message; }
        finally { if (request == historyRequest) HistoryRefresh.IsEnabled = HistoryMore.IsEnabled = true; }
    }
    private void ApplyHistory(string? previousId, string filter)
    {
        filtering = true;
        try
        {
            var options = history.Select(x => x.Device).Where(x => !string.IsNullOrEmpty(x)).Distinct().OrderBy(x => x)
                .Select(x => new Option(x, x)).Prepend(new Option("All devices", "")).ToList();
            DeviceFilter.DisplayMemberPath = "Name"; DeviceFilter.SelectedValuePath = "Code"; DeviceFilter.ItemsSource = options;
            DeviceFilter.SelectedValue = options.Any(x => x.Code == filter) ? filter : "";
        }
        finally { filtering = false; }
        FilterHistory(previousId);
    }
    private void DeviceFilterChanged(object sender, SelectionChangedEventArgs e)
    { if (!filtering) FilterHistory((Sessions.SelectedItem as UiHistoryEntry)?.Id); }
    private void FilterHistory(string? previousId)
    {
        var filter = DeviceFilter.SelectedValue as string;
        var rows = string.IsNullOrEmpty(filter) ? history : history.Where(x => x.Device == filter).ToList();
        filtering = true;
        try { Sessions.ItemsSource = rows; Sessions.SelectedItem = rows.FirstOrDefault(x => x.Id == previousId) ?? rows.FirstOrDefault(); }
        finally { filtering = false; }
        EmptyHistory.Visibility = Visible(rows.Count == 0);
        SessionCount.Text = $"{rows.Count} {(rows.Count == 1 ? "session" : "sessions")} loaded";
        _ = LoadSession();
    }
    private async void SessionChanged(object sender, SelectionChangedEventArgs e) { if (!filtering) await LoadSession(); }
    private async Task LoadSession()
    {
        var request = ++detailRequest;
        selectedText = null; CopySession.IsEnabled = false; SessionTranscript.Text = "";
        if (Sessions.SelectedItem is not UiHistoryEntry entry) { SessionHeading.Text = "Select a dictation"; SessionMeta.Text = ""; return; }
        var local = entry.CreatedAt.ToLocalTime();
        SessionHeading.Text = $"{local:MMM d} · {local:t}";
        SessionMeta.Text = $"{entry.Device}   ·   {entry.Status}";
        SessionTranscript.Text = "Loading transcript…";
        try
        {
            var text = await app.GetTranscriptAsync(entry.Id);
            if (request != detailRequest || closed) return;
            selectedText = text; CopySession.IsEnabled = !string.IsNullOrEmpty(text);
            SessionTranscript.Text = CopySession.IsEnabled ? text : "No transcript available.";
        }
        catch (Exception ex) { if (request == detailRequest) SessionTranscript.Text = ex.Message; }
    }

    private UiPreferences? Draft => baseline is { } original && LanguagePicker.SelectedValue is string code
        ? original with { Language = code, Proofread = Proofreading.IsChecked == true, Prompt = Normalize(Prompt.Text), Vocabulary = Normalize(Vocabulary.Text) }
        : null;
    private static string Normalize(string value) => value.ReplaceLineEndings("\n");
    private bool PrefsDirty => Draft is { } draft && draft != baseline;
    private void UpdateSharedEditor()
    {
        if (settingDraft || SharedEditor == null) return;
        var draft = Draft;
        string? issue = draft != null && (string.IsNullOrWhiteSpace(draft.Prompt) || Encoding.UTF8.GetByteCount(draft.Prompt) > 4096)
            ? "Cleanup instructions must be 1–4,096 UTF-8 bytes."
            : draft != null && Encoding.UTF8.GetByteCount(draft.Vocabulary) > 16384 ? "Vocabulary exceeds 16 KiB." : null;
        SharedEditor.IsEnabled = baseline != null && !prefsBusy;
        SaveShared.IsEnabled = !prefsBusy && PrefsDirty && issue == null;
        ReloadShared.IsEnabled = !prefsBusy; ReloadShared.Content = PrefsDirty ? "Discard changes" : "Reload";
        if (!prefsBusy && baseline != null) SharedMessage.Text = issue ?? (PrefsDirty ? "Unsaved changes" : "Shared across your devices");
    }
    private void PreferenceSelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateSharedEditor();
    private void PreferenceTextChanged(object sender, TextChangedEventArgs e) => UpdateSharedEditor();
    private void PreferenceToggleChanged(object sender, RoutedEventArgs e) => UpdateSharedEditor();
    private async void ReloadSharedClicked(object sender, RoutedEventArgs e) => await LoadShared();
    private async Task LoadShared() => await RunShared(null);
    private async void SaveSharedClicked(object sender, RoutedEventArgs e) { if (Draft is { } draft && PrefsDirty) await RunShared(draft); }
    private async Task RunShared(UiPreferences? save)
    {
        if (prefsBusy) return;
        var gen = settingsGeneration;
        prefsBusy = true; UpdateSharedEditor(); SharedMessage.Text = save == null ? "Loading preferences…" : "Saving preferences…";
        string? message = null;
        try
        {
            var result = save == null ? await app.GetPreferencesAsync() : await app.SavePreferencesAsync(save);
            if (gen != settingsGeneration || closed) return;
            baseline = result with { Prompt = Normalize(result.Prompt), Vocabulary = Normalize(result.Vocabulary) };
            settingDraft = true;
            LanguagePicker.SelectedValue = baseline.Language; Proofreading.IsChecked = baseline.Proofread;
            Prompt.Text = baseline.Prompt; Vocabulary.Text = baseline.Vocabulary;
            if (save != null) message = "Shared preferences saved.";
        }
        catch (Exception ex) { message = ex.Message; }
        finally
        {
            if (gen == settingsGeneration && !closed)
            {
                settingDraft = prefsBusy = false; UpdateSharedEditor();
                if (message != null) SharedMessage.Text = message;
            }
        }
    }
}
