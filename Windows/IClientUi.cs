using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Inlay.Windows;

// AppController implements this boundary. Publish a new snapshot before raising Changed;
// views marshal notifications to the dispatcher. No credential is echoed back to the UI.
internal interface IClientUi
{
    ClientUiState State { get; }
    event Action? Changed;
    Task RefreshAsync();
    Task ConnectAsync(string endpoint, string token, string deviceName);
    Task ToggleTestAsync();
    Task CancelAsync();
    Task SelectInputAsync(string id);
    Task<UiHistoryPage> GetHistoryAsync(string? before = null);
    Task<string> GetTranscriptAsync(string id);
    Task<UiPreferences> GetPreferencesAsync();
    // Merge these fields into the complete server snapshot; PUT with the supplied revision.
    Task<UiPreferences> SavePreferencesAsync(UiPreferences draft);
}

internal enum UiActivity { Idle, Starting, Recording, Processing }
internal sealed record UiInput(string Id, string Name);
internal sealed record UiHistoryEntry(string Id, DateTimeOffset CreatedAt, string Device, string Status, string Preview);
internal sealed record UiHistoryPage(IReadOnlyList<UiHistoryEntry> Items, string? NextCursor);
internal sealed record UiPreferences(long Revision, string Language, bool Proofread, string Prompt, string Vocabulary);
internal sealed record ClientUiState
{
    public string Endpoint { get; init; } = "";
    public string DeviceName { get; init; } = "";
    public string KeyLabel { get; init; } = "";
    public bool HoldToTalk { get; init; } = true;
    public string ServerStatus { get; init; } = "Not connected";
    public bool ServerReady { get; init; }
    public bool CanTest { get; init; }
    public UiActivity Activity { get; init; }
    public string ActivityText { get; init; } = "";
    public string Transcript { get; init; } = "";
    public string Delivery { get; init; } = "";
    public IReadOnlyList<UiInput> Inputs { get; init; } = Array.Empty<UiInput>();
    public string? InputId { get; init; }
    public string InputName { get; init; } = "";
    public double Level { get; init; } // normalized live microphone level (0..1)
    public TimeSpan Elapsed { get; init; }
}
