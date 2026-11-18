using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Dsp;
using NAudio.Wave;

namespace Inlay.Windows;

internal sealed record MicrophoneDevice(string Id, string Name);
internal sealed record MicrophoneChunk(string Kind, int Sequence, int SampleRate, int Channels, byte[] Data, long ExpectedFrames);
internal sealed record MicrophoneResult(long InferenceFrames, long? OriginalFrames, bool Interrupted = false);

internal sealed class Microphone : IAsyncDisposable
{
    private const int InferenceRate = 16_000;
    private const int MaxSeconds = 180;
    private readonly CancellationTokenSource abort = new();
    private readonly TaskCompletionSource started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int disposing;
    private volatile bool stopRequested;

    public Task<MicrophoneResult> Completion { get; }

    private Microphone(string? deviceId, bool keepOriginal, Func<MicrophoneChunk, CancellationToken, Task> upload,
        IProgress<float>? progress, CancellationToken cancellationToken)
    {
        Completion = Task.Run(() => RunAsync(deviceId, keepOriginal, upload, progress, cancellationToken));
    }

    // IDs are opaque endpoint IDs, not indices. An explicitly selected device never falls back silently.
    public static Task<IReadOnlyList<MicrophoneDevice>> ListAsync(CancellationToken cancellationToken = default) =>
        Task.Run<IReadOnlyList<MicrophoneDevice>>(() =>
        {
            using var enumerator = new MMDeviceEnumerator();
            var result = new List<MicrophoneDevice>();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                using (device)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    result.Add(new(device.ID, device.FriendlyName));
                }
            }
            return result;
        }, cancellationToken);

    // upload runs off-dispatcher, serially. Return only after acknowledgement and honor its token.
    // Use Progress<float> constructed on the dispatcher for UI-bound metering.
    public static async Task<Microphone> StartAsync(string? deviceId, bool keepOriginal,
        Func<MicrophoneChunk, CancellationToken, Task> upload, IProgress<float>? progress = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var mic = new Microphone(deviceId, keepOriginal, upload, progress, cancellationToken);
        try
        {
            await Task.WhenAny(mic.started.Task, mic.Completion).ConfigureAwait(false);
            if (mic.Completion.IsCompleted) await mic.Completion.ConfigureAwait(false);
            return mic;
        }
        catch
        {
            await mic.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    public Task<MicrophoneResult> StopAsync()
    {
        stopRequested = true;
        return Completion;
    }

    // Dispose is an abort, not a finish. Completion/StopAsync remain the source of recording errors.
    public async ValueTask DisposeAsync()
    {
        bool first = Interlocked.Exchange(ref disposing, 1) == 0;
        if (first) await abort.CancelAsync().ConfigureAwait(false);
        try { await Completion.ConfigureAwait(false); }
        catch { /* Never hide the original capture/upload exception during cleanup. */ }
        finally { if (first) abort.Dispose(); }
    }

    private async Task<MicrophoneResult> RunAsync(string? deviceId, bool keepOriginal,
        Func<MicrophoneChunk, CancellationToken, Task> upload, IProgress<float>? progress, CancellationToken external)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(abort.Token, external);
        var token = lifetime.Token;
        // Hold a whole capped take (250 ms chunks for both streams) so a slow link
        // delays the upload instead of aborting the take. RAM only, never disk.
        var queue = Channel.CreateBounded<MicrophoneChunk>(new BoundedChannelOptions(MaxSeconds * 4 * 2 + 8)
        {
            SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait
        });
        // WASAPI and all its buffers live on one dedicated worker (never the WPF dispatcher).
        var capture = Task.Factory.StartNew(() =>
        {
            try { return Capture(deviceId, keepOriginal, queue.Writer, progress, token); }
            catch (UnauthorizedAccessException ex)
            {
                lifetime.Cancel();
                throw new IOException("Microphone access denied. Allow desktop apps in Windows microphone privacy settings.", ex);
            }
            catch (COMException ex)
            {
                lifetime.Cancel();
                throw new IOException($"Windows could not access the microphone (0x{ex.HResult:X8}). Check the input device and connection.", ex);
            }
            catch { lifetime.Cancel(); throw; }
            finally { queue.Writer.TryComplete(); }
        }, token, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        var pump = UploadAsync();
        await Task.WhenAll(capture, pump).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        return await capture.ConfigureAwait(false);

        async Task UploadAsync()
        {
            try
            {
                await foreach (var chunk in queue.Reader.ReadAllAsync(token).ConfigureAwait(false))
                {
                    token.ThrowIfCancellationRequested();
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
                    deadline.CancelAfter(TimeSpan.FromSeconds(60));
                    try { await upload(chunk, deadline.Token).ConfigureAwait(false); }
                    catch (OperationCanceledException ex) when (!token.IsCancellationRequested && deadline.IsCancellationRequested)
                    { throw new IOException("Timed out uploading microphone audio.", ex); }
                }
            }
            catch { lifetime.Cancel(); throw; }
        }
    }

    private MicrophoneResult Capture(string? id, bool keepOriginal, ChannelWriter<MicrophoneChunk> sink,
        IProgress<float>? progress, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var enumerator = new MMDeviceEnumerator();
        using var device = string.IsNullOrEmpty(id)
            ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia)
            : enumerator.GetDevice(id);
        if (device.DataFlow != DataFlow.Capture || device.State != DeviceState.Active)
            throw new IOException("The selected microphone is not available.");
        using var client = device.AudioClient;
        var format = client.MixFormat;
        var encoder = new Encoder(format, keepOriginal, sink, progress);
        client.Initialize(AudioClientShareMode.Shared, AudioClientStreamFlags.None,
            TimeSpan.FromMilliseconds(200).Ticks, 0, format, Guid.Empty);
        var reader = client.AudioCaptureClient; // owned by client
        int bufferFrames = client.BufferSize;
        if (bufferFrames <= 0 || bufferFrames > format.SampleRate * 2)
            throw new IOException("Unexpected microphone buffer size.");
        byte[] scratch = new byte[checked(bufferFrames * format.BlockAlign)];
        token.ThrowIfCancellationRequested();
        client.Start();
        started.TrySetResult();
        var clock = Stopwatch.StartNew();
        var lastPacket = TimeSpan.Zero;
        bool stopped = false, interrupted = false;
        try
        {
            while (true)
            {
                token.ThrowIfCancellationRequested();
                if (!stopped && (stopRequested || clock.Elapsed.TotalSeconds >= MaxSeconds || encoder.Full))
                {
                    stopped = true;
                    client.Stop(); // freezes the stream; unlike Reset(), leaves pending packets for the final drain
                }
                if (encoder.Full) break;
                if (reader.GetNextPacketSize() == 0)
                {
                    if (stopped) break;
                    if (clock.Elapsed - lastPacket > TimeSpan.FromSeconds(encoder.InputFrames == 0 ? 8 : 3))
                        throw new IOException("The microphone stopped supplying audio.");
                    token.WaitHandle.WaitOne(10);
                    continue;
                }

                var pointer = reader.GetBuffer(out int frames, out var flags);
                bool silent = (flags & AudioClientBufferFlags.Silent) != 0;
                try
                {
                    if (frames <= 0 || frames > bufferFrames) throw new IOException("Invalid microphone packet.");
                    // The first packet may legitimately mark the start of a new device timeline.
                    if (encoder.InputFrames != 0 && (flags & AudioClientBufferFlags.DataDiscontinuity) != 0)
                        interrupted = true; // preserve usable packets, return a warning and preview instead of inserting
                    if (!silent) Marshal.Copy(pointer, scratch, 0, checked(frames * format.BlockAlign));
                }
                finally { reader.ReleaseBuffer(frames); }
                lastPacket = clock.Elapsed;
                encoder.Append(scratch, frames, silent);
            }
        }
        finally { if (!stopped) client.Stop(); }
        token.ThrowIfCancellationRequested();
        return encoder.Finish() with { Interrupted = interrupted };
    }

    private sealed class Encoder
    {
        private readonly int rate, channels, sampleBytes;
        private readonly bool ieeeFloat;
        private readonly ChannelWriter<MicrophoneChunk> sink;
        private readonly IProgress<float>? progress;
        private readonly WdlResampler? resampler;
        private readonly float[] mono;
        private readonly float[]? original;
        private int used, inferenceSequence, originalSequence, meterFrames;
        private double sumSquares;
        private long inferenceFrames;
        public long InputFrames { get; private set; }
        public bool Full => InputFrames >= (long)rate * MaxSeconds;

        public Encoder(WaveFormat mix, bool keepOriginal, ChannelWriter<MicrophoneChunk> sink, IProgress<float>? progress)
        {
            var format = mix is WaveFormatExtensible ext ? ext.ToStandardWaveFormat() : mix;
            rate = format.SampleRate;
            channels = format.Channels;
            sampleBytes = format.BitsPerSample / 8;
            ieeeFloat = format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32;
            bool pcm = format.Encoding == WaveFormatEncoding.Pcm && format.BitsPerSample is 8 or 16 or 24 or 32;
            if (rate is < 8000 or > 192000 || channels is < 1 or > 64 || (!ieeeFloat && !pcm) || mix.BlockAlign != channels * sampleBytes)
                throw new NotSupportedException($"Unsupported microphone format: {mix}.");
            this.sink = sink;
            this.progress = progress;
            mono = new float[rate / 4];
            // Omit an ineligible archive from the outset, matching the server's per-stream limits.
            if (keepOriginal && channels <= 8 && (long)rate * channels * 4 * MaxSeconds <= 268_435_456)
                original = new float[mono.Length * channels];
            if (rate != InferenceRate)
            {
                resampler = new WdlResampler();
                resampler.SetMode(false, 0, true); // band-limited sinc; carry filter/phase across chunks
                resampler.SetRates(rate, InferenceRate);
                resampler.SetFeedMode(true);
            }
        }

        public void Append(byte[] raw, int frames, bool silent)
        {
            int count = (int)Math.Min(frames, (long)rate * MaxSeconds - InputFrames);
            int offset = 0;
            for (int f = 0; f < count; f++)
            {
                double sum = 0;
                for (int ch = 0; ch < channels; ch++, offset += sampleBytes)
                {
                    float sample = silent ? 0 : Decode(raw.AsSpan(offset, sampleBytes));
                    if (original != null) original[used * channels + ch] = sample;
                    sum += sample;
                }
                float mixed = (float)(sum / channels);
                mono[used++] = mixed;
                InputFrames++;
                sumSquares += (double)mixed * mixed;
                if (++meterFrames >= rate / 20)
                {
                    double rms = Math.Sqrt(sumSquares / meterFrames);
                    progress?.Report((float)Math.Clamp((20 * Math.Log10(Math.Max(rms, 1e-6)) + 60) / 60, 0, 1));
                    meterFrames = 0;
                    sumSquares = 0;
                }
                if (used == mono.Length) Flush(false);
            }
        }

        private float Decode(ReadOnlySpan<byte> data)
        {
            if (ieeeFloat)
            {
                float sample = BinaryPrimitives.ReadSingleLittleEndian(data);
                return float.IsFinite(sample) ? sample : throw new IOException("The microphone returned invalid float audio.");
            }
            return sampleBytes switch
            {
                1 => (data[0] - 128) / 128f,
                2 => BinaryPrimitives.ReadInt16LittleEndian(data) / 32768f,
                3 => ((data[0] << 8) | (data[1] << 16) | (data[2] << 24)) / 2147483648f,
                4 => BinaryPrimitives.ReadInt32LittleEndian(data) / 2147483648f,
                _ => throw new UnreachableException()
            };
        }

        public MicrophoneResult Finish()
        {
            if (InputFrames * 4 < rate) throw new IOException("Recording too short. Speak for at least a quarter second.");
            Flush(true);
            return new(inferenceFrames, original == null ? null : InputFrames);
        }

        private void Flush(bool final)
        {
            int due = checked((int)((InputFrames * InferenceRate + rate / 2) / rate - inferenceFrames));
            float[] output = mono;
            int produced = used;
            if (resampler != null)
            {
                output = new float[due];
                resampler.ResamplePrepare(used, 1, out var input, out int offset);
                Array.Copy(mono, 0, input, offset, used);
                produced = resampler.ResampleOut(output, 0, used, due, 1);
                if (final && produced < due)
                {
                    // Right zero-extension supplies only filter lookahead. Never emit samples beyond
                    // the nearest 16 kHz frame of the actual accepted microphone interval.
                    const int lookahead = 128;
                    resampler.ResamplePrepare(lookahead, 1, out input, out offset);
                    Array.Clear(input, offset, lookahead);
                    produced += resampler.ResampleOut(output, produced, lookahead, due - produced, 1);
                    if (produced != due) throw new IOException("Could not drain the microphone resampler.");
                }
            }
            if (produced > 0)
            {
                inferenceFrames += produced;
                Emit("inference", inferenceSequence++, InferenceRate, 1, output.AsSpan(0, produced), inferenceFrames);
            }
            if (original != null && used > 0)
                Emit("original", originalSequence++, rate, channels, original.AsSpan(0, used * channels), InputFrames);
            used = 0;
        }

        private void Emit(string kind, int seq, int hz, int ch, Span<float> samples, long expectedFrames)
        {
            var bytes = MemoryMarshal.AsBytes(samples).ToArray(); // Windows is little-endian
            if (!sink.TryWrite(new(kind, seq, hz, ch, bytes, expectedFrames)))
                throw new IOException("The audio upload fell behind. This recording could not be sent completely.");
        }
    }
}
