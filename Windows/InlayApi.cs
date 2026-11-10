using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Inlay.Windows;

internal sealed class ApiException(HttpStatusCode status, string code, string message) : Exception(message)
{
    public HttpStatusCode Status { get; } = status;
    public string Code { get; } = code;
}

// Immutable for a take. Neither a preferences change nor a proxy redirect can
// retarget a live upload, and no bearer is installed on the shared handler.
internal sealed class InlayApi
{
    public const int ApiVersion = 4;
    public const int MaximumChunkBytes = 1_048_576;
    public const int MaximumRecordingSeconds = 180;
    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, UseProxy = false,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5)
    }) { Timeout = TimeSpan.FromSeconds(15), MaxResponseContentBufferSize = 16 * 1024 * 1024 };
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        RespectNullableAnnotations = true, RespectRequiredConstructorParameters = true
    };
    private readonly Uri root;
    private readonly string token;
    public DeviceIdentity Device { get; }
    public string Endpoint => root.AbsoluteUri.TrimEnd('/');

    internal InlayApi(string endpoint, DeviceIdentity device, string credential)
    {
        root = new Uri(NormalizeEndpoint(endpoint) + "/", UriKind.Absolute);
        Device = device;
        token = ValidateToken(credential);
    }

    internal static string ValidateToken(string value)
    {
        if (value.Length is 0 or > 4096 || value.Any(c => c < '!' || c > '~'))
            throw new ArgumentException("Use a server credential without whitespace, up to 4096 ASCII characters.");
        return value;
    }

    public static string NormalizeEndpoint(string value)
    {
        value = value.Trim();
        if (value.Length > 2048 || value.Any(c => char.IsWhiteSpace(c) || char.IsControl(c) || c is '\\' or '?' or '#') ||
            !Uri.TryCreate(value, UriKind.Absolute, out var uri) || !uri.IsWellFormedOriginalString() ||
            uri.Scheme is not ("http" or "https") || string.IsNullOrEmpty(uri.Host) || uri.Port is < 1 or > 65535 ||
            uri.UserInfo.Length != 0 || uri.Authority.Contains('@') || uri.HostNameType is not (UriHostNameType.Dns or UriHostNameType.IPv4 or UriHostNameType.IPv6))
            throw new ArgumentException("Enter an HTTP or HTTPS server address without credentials, a query, or a fragment.");
        // Check the original authority too: System.Uri can erase empty userinfo or an IPv6 scope ID.
        var authority = value.AsSpan(value.IndexOf("://", StringComparison.Ordinal) + 3);
        var slash = authority.IndexOf('/');
        if (slash >= 0) authority = authority[..slash];
        if (authority.Contains('@') || authority.Contains('%')) throw new ArgumentException("Invalid server address.");
        if (uri.Scheme == "http" && !PermitsHttp(uri))
            throw new ArgumentException("Use HTTPS for remote servers, or HTTP with localhost.");
        return uri.AbsoluteUri.TrimEnd('/');
    }

    private static bool PermitsHttp(Uri uri)
    {
        if (uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase)) return true;
        if (!IPAddress.TryParse(uri.IdnHost, out var ip)) return false;
        var bytes = ip.GetAddressBytes();
        return ip.AddressFamily == AddressFamily.InterNetwork
            ? bytes[0] == 127 : ip.Equals(IPAddress.IPv6Loopback);
    }

    public async Task<ServerHealth> HealthAsync(CancellationToken ct = default)
    {
        var health = await SendAsync<ServerHealth>(HttpMethod.Get, "v1/health", null, ct).ConfigureAwait(false);
        if (health.ApiVersion != ApiVersion)
            throw new InvalidOperationException($"This client requires server API v{ApiVersion}; the server uses v{health.ApiVersion}.");
        return health;
    }

    internal Task<ServerHealth> CheckVersionAsync(CancellationToken ct) => HealthAsync(ct);

    private sealed record Enrollment(DeviceIdentity Device, string Token);
    internal async Task<string> EnrollAsync(CancellationToken ct)
    {
        // Never retry enrollment: rotating an existing credential is not idempotent.
        var result = await SendAsync<Enrollment>(HttpMethod.Post, "v1/devices/enroll", Body(new { device = Device }), ct).ConfigureAwait(false);
        if (result.Device.Id != Device.Id || result.Token == token) throw InvalidResponse();
        return ValidateToken(result.Token);
    }

    public Task<GenerationRecord> CreateAsync(Guid requestId, CancellationToken ct = default) => CreateAsync(requestId, "dictation", ct);
    public async Task<GenerationRecord> CreateAsync(Guid requestId, string mode, CancellationToken ct = default)
    {
        if (requestId == Guid.Empty || mode is not ("dictation" or "test" or "file")) throw new ArgumentException("Invalid recording request.");
        var health = await HealthAsync(ct).ConfigureAwait(false);
        // The server admits queued recordings while a healthy speech model warms up.
        if (!health.Ready) throw new InvalidOperationException(health.Message ?? "The server is not ready to accept recordings.");
        ct.ThrowIfCancellationRequested();
        // Once submitted, don't discard the ID if the hold is released. The caller
        // can cancel the actual generation rather than strand a receiving session.
        var record = await RetryAsync(() => SendAsync<GenerationRecord>(HttpMethod.Post, "v1/generations",
            Body(new { requestID = requestId, device = Device, mode }), CancellationToken.None), CancellationToken.None).ConfigureAwait(false);
        if (record.Id == Guid.Empty || record.RequestId != requestId || record.Device.Id != Device.Id || record.Mode != mode) throw InvalidResponse();
        return record;
    }

    // Send serially for each stream. The caller owns pcm and must not modify it until this task completes.
    public Task<AudioChunkReceipt> UploadAsync(Guid id, int sequence, byte[] pcm, long expectedFrames, CancellationToken ct = default) =>
        UploadChunkAsync(id, "inference", sequence, pcm, 16_000, 1, expectedFrames, ct);
    public Task<AudioChunkReceipt> UploadOriginalAsync(Guid id, int sequence, byte[] pcm, int sampleRate, int channels,
        long expectedFrames, CancellationToken ct = default) => UploadChunkAsync(id, "original", sequence, pcm, sampleRate, channels, expectedFrames, ct);

    private async Task<AudioChunkReceipt> UploadChunkAsync(Guid id, string kind, int sequence, byte[] pcm, int sampleRate,
        int channels, long expectedFrames, CancellationToken ct)
    {
        if (sequence is < 0 or > 4095 || sampleRate is < 8000 or > 192000 || channels is < 1 or > 8 ||
            pcm.Length is 0 or > MaximumChunkBytes || pcm.Length % (4 * channels) != 0 || expectedFrames < pcm.Length / (4 * channels))
            throw new ArgumentException("Invalid audio chunk, sequence, or frame count.");
        var path = FormattableString.Invariant($"{PathFor(id)}/audio/{kind}?sequence={sequence}&sampleRate={sampleRate}&channels={channels}");
        var receipt = await RetryAsync(() => SendAsync<AudioChunkReceipt>(HttpMethod.Post, path,
            Content(pcm, "application/octet-stream"), ct), ct).ConfigureAwait(false);
        if (receipt.NextSequence != sequence + 1 || receipt.FrameCount != expectedFrames) throw InvalidResponse();
        return receipt;
    }

    public Task<GenerationRecord> FinishAsync(Guid id, long inferenceFrames, CancellationToken ct = default) => FinishAsync(id, inferenceFrames, null, ct);
    public Task<GenerationRecord> FinishAsync(Guid id, long inferenceFrames, long? originalFrames, CancellationToken ct = default)
    {
        if (inferenceFrames < 0 || originalFrames < 0) throw new ArgumentOutOfRangeException(nameof(inferenceFrames));
        return RetryAsync(() => RecordAsync(id, HttpMethod.Post, "/finish", Body(new { inferenceFrames, originalFrames }), ct), ct);
    }

    public Task<GenerationRecord> GenerationAsync(Guid id, CancellationToken ct = default) => RecordAsync(id, HttpMethod.Get, "", null, ct);
    public Task<GenerationRecord> CancelAsync(Guid id, CancellationToken ct = default) => RecordAsync(id, HttpMethod.Post, "/cancel", null, ct);
    public Task<GenerationRecord> DeliveryAsync(Guid id, string status, string? message, CancellationToken ct = default) =>
        RecordAsync(id, HttpMethod.Post, "/delivery", Body(new
        {
            status, message, reportedAt = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)
        }), ct);

    public async Task<GenerationRecord> PollAsync(Guid id, CancellationToken ct = default)
    {
        var start = Stopwatch.GetTimestamp();
        while (Stopwatch.GetElapsedTime(start) < TimeSpan.FromMinutes(15))
        {
            var record = await RetryAsync(() => GenerationAsync(id, ct), ct).ConfigureAwait(false);
            if (record.IsTerminal) return record;
            await Task.Delay(Stopwatch.GetElapsedTime(start).TotalSeconds < 5 ? 150 : 750, ct).ConfigureAwait(false);
        }
        throw new TimeoutException("This recording is still processing. Check shared history for the result.");
    }

    public Task<GenerationPage> HistoryAsync(CancellationToken ct = default) => HistoryAsync(null, ct);
    public Task<GenerationPage> HistoryAsync(string? before, CancellationToken ct = default) =>
        SendAsync<GenerationPage>(HttpMethod.Get, "v1/generations" + (before is null ? "" : "?before=" + Uri.EscapeDataString(before)), null, ct);
    public Task<PreferencesSnapshot> PreferencesAsync(CancellationToken ct = default) =>
        SendAsync<PreferencesSnapshot>(HttpMethod.Get, "v1/preferences", null, ct);
    public Task<PreferencesSnapshot> UpdatePreferencesAsync(PreferencesSnapshot snapshot, CancellationToken ct = default) =>
        SendAsync<PreferencesSnapshot>(HttpMethod.Put, "v1/preferences", Body(snapshot), ct);

    private static string PathFor(Guid id) => $"v1/generations/{id:D}";
    private async Task<GenerationRecord> RecordAsync(Guid id, HttpMethod method, string suffix, HttpContent? content, CancellationToken ct)
    {
        var record = await SendAsync<GenerationRecord>(method, PathFor(id) + suffix, content, ct).ConfigureAwait(false);
        if (record.Id != id) throw InvalidResponse();
        return record;
    }
    private static HttpContent Content(byte[] bytes, string mediaType)
    {
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue(mediaType);
        return content;
    }
    private static HttpContent Body<T>(T value) => Content(JsonSerializer.SerializeToUtf8Bytes(value, Json), "application/json");
    private static InvalidDataException InvalidResponse() => new("The server returned an invalid response.");
    private sealed record ErrorBody(string Code, string Message);

    private async Task<T> SendAsync<T>(HttpMethod method, string path, HttpContent? body, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, new Uri(root, path)) { Content = body };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await Http.SendAsync(request, ct).ConfigureAwait(false);
        var data = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            ErrorBody? error = null;
            if (data.Length is > 0 and <= 16_384)
                try { error = JsonSerializer.Deserialize<ErrorBody>(data, Json); } catch (JsonException) { }
            var message = error?.Message ?? $"The server rejected the request (HTTP {(int)response.StatusCode}).";
            throw new ApiException(response.StatusCode, error?.Code ?? "", message[..Math.Min(message.Length, 1000)]);
        }
        try { return JsonSerializer.Deserialize<T>(data, Json) ?? throw InvalidResponse(); }
        catch (JsonException) { throw InvalidResponse(); }
    }
    private static async Task<T> RetryAsync<T>(Func<Task<T>> send, CancellationToken ct)
    {
        for (var failures = 0; ; failures++)
        {
            ct.ThrowIfCancellationRequested();
            try { return await send().ConfigureAwait(false); }
            catch (Exception e) when (failures < 3 && !ct.IsCancellationRequested && (e is HttpRequestException or TaskCanceledException ||
                e is ApiException { Status: HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests or HttpStatusCode.BadGateway or HttpStatusCode.ServiceUnavailable or HttpStatusCode.GatewayTimeout }))
            { await Task.Delay(250 << failures, ct).ConfigureAwait(false); }
        }
    }
}
