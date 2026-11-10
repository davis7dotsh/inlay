using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Inlay.Windows;

// Only connection/identity and this PC's preferences live on disk. DPAPI's optional
// entropy binds each device credential to the *validated* endpoint and device ID.
// The admin token is used in memory once and never written, even temporarily.
internal sealed class ClientSettings
{
    private const string DefaultEndpoint = "http://127.0.0.1:8391";
    private static readonly string FilePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Inlay", "client.json");
    private sealed record Settings(string Endpoint, Guid DeviceId, string DeviceName, Dictionary<string, byte[]> Credentials, string? MicrophoneId = null, bool AutoCopyDictations = true);
    private readonly object sync = new();
    private readonly SemaphoreSlim connecting = new(1, 1);
    private volatile Settings saved;

    private ClientSettings(Settings state) => saved = state;
    public string Endpoint => saved.Endpoint;
    public string DeviceName => saved.DeviceName;
    public string DeviceId => saved.DeviceId.ToString("D");
    public string? MicrophoneId => saved.MicrophoneId;
    public bool AutoCopyDictations => saved.AutoCopyDictations;

    public static ClientSettings Load()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        try
        {
            using var file = File.OpenRead(FilePath);
            if (file.Length > 1024 * 1024) throw new InvalidDataException("Device settings exceed their size limit.");
            var state = JsonSerializer.Deserialize<Settings>(file);
            if (state is null || state.DeviceId == Guid.Empty || state.Endpoint is null || state.DeviceName is null || state.Credentials is null)
                throw new InvalidDataException("Device settings are invalid.");
            return new ClientSettings(state with { Endpoint = InlayApi.NormalizeEndpoint(state.Endpoint), DeviceName = ValidateName(state.DeviceName) });
        }
        catch (FileNotFoundException)
        {
            var name = string.IsNullOrWhiteSpace(Environment.MachineName) ? "My PC" : Environment.MachineName;
            var settings = new ClientSettings(new Settings(DefaultEndpoint, Guid.NewGuid(), ValidateName(name), []));
            // Commit the stable identity before *any* enrollment can use it.
            settings.Save(settings.saved);
            return settings;
        }
        catch (JsonException ex) { throw new InvalidDataException("Could not read this PC's Inlay settings. The original file has been preserved.", ex); }
    }

    // Opening never contacts the network or rotates a credential. A genuinely
    // unconfigured endpoint has no client; do not fall back to another endpoint.
    public InlayApi? OpenApi()
    {
        var state = saved;
        // A moved/restored profile may no longer be able to decrypt its blob. Keep
        // it intact and leave the connection form available for explicit enrollment.
        try { return OpenApi(state, state.Endpoint, state.DeviceName); }
        catch (CryptographicException) { return null; }
    }
    private static InlayApi? OpenApi(Settings state, string endpoint, string name)
    {
        if (!state.Credentials.TryGetValue(endpoint, out var blob)) return null;
        var plaintext = ProtectedData.Unprotect(blob, Entropy(endpoint, state.DeviceId), DataProtectionScope.CurrentUser);
        try { return new InlayApi(endpoint, new DeviceIdentity(state.DeviceId.ToString("D"), name), Encoding.UTF8.GetString(plaintext)); }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    public async Task<InlayApi> ConnectAsync(string endpoint, string? token, string deviceName, CancellationToken ct = default)
    {
        endpoint = InlayApi.NormalizeEndpoint(endpoint);
        deviceName = ValidateName(deviceName);
        token = token?.Trim();
        await connecting.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var state = saved;
            InlayApi api;
            byte[]? newBlob = null;
            if (string.IsNullOrEmpty(token))
            {
                try { api = OpenApi(state, endpoint, deviceName) ?? throw new InvalidOperationException("Enter this server’s enrollment token to connect this PC."); }
                catch (CryptographicException ex) { throw new InvalidOperationException("Reconnect with the enrollment token. This account cannot unlock the saved device credential.", ex); }
                await api.HealthAsync(ct).ConfigureAwait(false);
            }
            else
            {
                var device = new DeviceIdentity(state.DeviceId.ToString("D"), deviceName);
                var admin = new InlayApi(endpoint, device, token);
                // Health admits the admin token even when models are cold. Only explicit
                // enrollment sends the admin credential; all normal requests use the result.
                await admin.HealthAsync(ct).ConfigureAwait(false);
                // Rotation can invalidate an existing credential. Once sent, keep the
                // response alive and store its replacement even if the UI cancels.
                ct.ThrowIfCancellationRequested();
                var returnedToken = await admin.EnrollAsync(CancellationToken.None).ConfigureAwait(false);
                var bytes = Encoding.UTF8.GetBytes(returnedToken);
                try { newBlob = ProtectedData.Protect(bytes, Entropy(endpoint, state.DeviceId), DataProtectionScope.CurrentUser); }
                finally { CryptographicOperations.ZeroMemory(bytes); }
                api = new InlayApi(endpoint, device, returnedToken);
            }
            lock (sync)
            {
                var current = saved;
                if (newBlob is not null || endpoint != current.Endpoint || deviceName != current.DeviceName)
                {
                    var credentials = newBlob is null ? current.Credentials : new Dictionary<string, byte[]>(current.Credentials) { [endpoint] = newBlob };
                    Save(current with { Endpoint = endpoint, DeviceName = deviceName, Credentials = credentials });
                }
            }
            return api;
        }
        finally { connecting.Release(); }
    }

    public void SetAutoCopyDictations(bool enabled)
    {
        lock (sync) Save(saved with { AutoCopyDictations = enabled });
    }

    public void SetMicrophone(string? id)
    {
        if (id?.Length > 2048) throw new ArgumentException("Invalid microphone ID.");
        lock (sync) Save(saved with { MicrophoneId = string.IsNullOrEmpty(id) ? null : id });
    }
    private static byte[] Entropy(string endpoint, Guid id) => Encoding.UTF8.GetBytes($"Inlay.Windows/device/v1\0{id:D}\0{endpoint}");
    private static string ValidateName(string value)
    {
        value = value.Trim();
        if (value.Length == 0 || new StringInfo(value).LengthInTextElements > 120 || value.Any(c => char.IsControl(c) || c is '\u2028' or '\u2029'))
            throw new ArgumentException("Use a single-line device name between 1 and 120 characters.");
        return value;
    }
    private void Save(Settings next)
    {
        var temp = FilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, next);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temp, FilePath, overwrite: true);
            saved = next;
        }
        finally { File.Delete(temp); }
    }
}
