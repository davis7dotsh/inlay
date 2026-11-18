using System;
using System.Text.Json.Serialization;

namespace Inlay.Windows;

// Wire names are camelCase, except the protocol's uppercase ID suffix. These are
// read projections of generation records; preferences, on the other hand, round-trip in full.
internal sealed record DeviceIdentity(string Id, string Name);
internal sealed record ModelRuntimeInfo([property: JsonPropertyName("modelID")] string ModelId,
    string Backend, bool Ready, string? Message = null);
internal sealed record ServerHealth(int ApiVersion, string ServerVersion, bool IsDev, bool Ready,
    ModelRuntimeInfo Speech, ModelRuntimeInfo Proofreading, string? Message = null);
internal sealed record AudioChunkReceipt(int NextSequence, long FrameCount);
internal sealed record GenerationRecord(Guid Id, [property: JsonPropertyName("requestID")] Guid RequestId,
    DeviceIdentity Device, string Mode, string Status, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt,
    PreferencesSnapshot Settings, string RawText, string FinalText, string InsertionText, string PreviewText,
    string? Error = null, double? Progress = null, int? QueuePosition = null)
{
    [JsonIgnore] public bool IsTerminal => Status is "completed" or "failed" or "cancelled";
}
internal sealed record GenerationSummary(Guid Id, DeviceIdentity Device, string Mode, string Status,
    DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt, string PreviewText);
internal sealed record GenerationPage(GenerationSummary[] Items, string? NextCursor = null);
internal sealed record PreferencesSnapshot(long Revision, ServerPreferences Preferences);
internal sealed record ServerPreferences(string Language, string Vocabulary, PersonalDictionary Dictionary,
    bool TextCorrectionEnabled, bool KeepOriginalAudio, string? ProofreadingPrompt = null, int? AudioRetentionDays = null);
internal sealed record PersonalDictionary(DictionaryList[] Lists);
internal sealed record DictionaryList(string Id, string Name, DictionaryEntry[]? Entries = null);
internal sealed record DictionaryEntry(string Id, string Term, string[]? Aliases = null, bool? IsPriority = null);
