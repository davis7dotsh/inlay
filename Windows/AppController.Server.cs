using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace Inlay.Windows;

internal sealed partial class AppController
{
    private PreferencesSnapshot? shared;

    private void LoadConnection()
    {
        State = State with { KeyLabel = "Left Ctrl + Left Windows", Endpoint = settings.Endpoint,
            DeviceName = settings.DeviceName, InputId = settings.MicrophoneId ?? "", InputName = "Windows default" };
        try { api = settings.OpenApi(); }
        catch (InvalidOperationException ex) { State = State with { ServerStatus = ex.Message }; }
    }

    public async Task RefreshAsync()
    {
        if (connecting || disposed || take != null) return;
        var conn = api;
        // Device failures must not make a reachable server look offline (or vice versa).
        try { await RefreshInputs(); }
        catch (Exception ex) { Publish(State with { InputName = ex.Message, Inputs = Array.Empty<UiInput>() }); }
        if (conn != api || connecting || disposed) return;
        if (conn == null)
        {
            Publish(State with { ServerReady = false, ServerStatus = "Connect in This PC" });
            return;
        }
        try
        {
            var health = await conn.CheckVersionAsync(lifetime.Token);
            if (conn == api && !connecting) ShowHealth(health);
        }
        catch (Exception ex)
        {
            if (conn == api && !connecting) Publish(State with { ServerReady = false, ServerStatus = ex.Message });
        }
    }
    private void ShowHealth(ServerHealth h) => Publish(State with { ServerReady = h.Ready,
        ServerStatus = h.Ready ? "Ready to dictate" : h.Message ?? "Server unavailable" });

    public async Task ConnectAsync(string endpoint, string token, string deviceName)
    {
        RequireIdle();
        connecting = true;
        Publish(State with { ServerStatus = "Connecting…" });
        try
        {
            api = await settings.ConnectAsync(endpoint, token, deviceName, lifetime.Token);
            shared = null;
            Publish(State with { Endpoint = settings.Endpoint, DeviceName = settings.DeviceName, ServerReady = false });
        }
        catch (Exception ex)
        {
            Publish(State with { ServerReady = false, ServerStatus = ex.Message });
            throw;
        }
        finally { connecting = false; Publish(State); }
        await RefreshAsync();
    }

    public async Task<UiHistoryPage> GetHistoryAsync(string? before = null)
    {
        var conn = Connected;
        var page = await conn.HistoryAsync(before, lifetime.Token);
        if (conn != api) throw new InvalidOperationException("Connection changed. Reload history.");
        return new(page.Items.Select(r => new UiHistoryEntry(r.Id.ToString(), r.CreatedAt, r.Device.Name, r.Status, r.PreviewText)).ToArray(), page.NextCursor);
    }
    public async Task<string> GetTranscriptAsync(string id)
    {
        var record = await Connected.GenerationAsync(Guid.Parse(id), lifetime.Token);
        return string.IsNullOrEmpty(record.PreviewText) ? record.FinalText : record.PreviewText;
    }
    private static UiPreferences ToUI(PreferencesSnapshot s) => new(s.Revision, s.Preferences.Language,
        s.Preferences.TextCorrectionEnabled, s.Preferences.ProofreadingPrompt ?? "", s.Preferences.Vocabulary);
    public async Task<UiPreferences> GetPreferencesAsync()
    {
        var conn = Connected;
        var result = await conn.PreferencesAsync(lifetime.Token);
        if (conn != api) throw new InvalidOperationException("Connection changed. Reload server preferences.");
        shared = result;
        return ToUI(result);
    }
    public async Task<UiPreferences> SavePreferencesAsync(UiPreferences draft)
    {
        var conn = Connected;
        var s = shared;
        if (s == null || s.Revision != draft.Revision) throw new InvalidOperationException("Reload server preferences before saving.");
        var result = await conn.UpdatePreferencesAsync(s with { Preferences = s.Preferences with {
            Language = draft.Language, TextCorrectionEnabled = draft.Proofread, ProofreadingPrompt = draft.Prompt,
            Vocabulary = draft.Vocabulary } }, lifetime.Token);
        if (conn != api) throw new InvalidOperationException("Connection changed. Reload server preferences.");
        shared = result;
        return ToUI(result);
    }
}
