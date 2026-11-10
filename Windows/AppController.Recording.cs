using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Inlay.Windows;

internal sealed partial class AppController
{
    private async Task RefreshInputs()
    {
        var devices = await Microphone.ListAsync(lifetime.Token);
        var inputs = new List<UiInput> { new("", "Windows default") };
        inputs.AddRange(devices.Select(d => new UiInput(d.Id, d.Name)));
        var id = settings.MicrophoneId ?? "";
        Publish(State with { Inputs = State.Inputs.SequenceEqual(inputs) ? State.Inputs : inputs, InputId = id,
            InputName = inputs.FirstOrDefault(d => d.Id == id)?.Name ?? "Selected microphone disconnected" });
    }
    public async Task SelectInputAsync(string id)
    {
        RequireIdle();
        settings.SetMicrophone(string.IsNullOrEmpty(id) ? null : id);
        await RefreshInputs();
    }

    private async Task StartAsync(bool test)
    {
        if (take != null || connecting || disposed || api == null) return;
        var conn = api;
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var ct = operation.Token;
        take = operation;
        testing = test;
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        release = stopped;
        var ticket = new TaskCompletionSource<Task<GenerationRecord>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var admitted = ticket.Task.Unwrap();
        Task<GenerationRecord>? creating = null;
        bool submitted = false, announced = false;
        previewOnly = false;

        void PublishResult(string message, string transcript) => Publish(test
            ? State with { TestResult = new(message, transcript), ActivityText = "" }
            : State with { Delivery = message, Transcript = transcript, ActivityText = "" });

        try
        {
            var destination = test ? null : TextDelivery.Capture();
            var accessible = !test && destination == null ? AccessibleDelivery.CaptureAsync(ct) : null;
            // Let ordinary Win+Ctrl+<key> shortcuts pass without opening a mic or a server session.
            if (!test) await Task.Delay(160, ct);
            announced = true;
            Publish(State with { Activity = UiActivity.Starting, ActivityText = "Starting microphone…", IsTesting = test,
                TestResult = test ? null : State.TestResult, Delivery = test ? State.Delivery : "", Level = 0, Elapsed = TimeSpan.Zero });
            MicrophoneResult frames;
            long releasedAt;
            // Begin local capture before waiting on the network. The bounded upload queue holds
            // the leading audio in RAM; original samples leave the PC only if this take requests them.
            await using (var microphone = await Microphone.StartAsync(settings.MicrophoneId, true, async (chunk, token) =>
            {
                var session = await admitted.WaitAsync(token).ConfigureAwait(false);
                if (chunk.Kind == "inference")
                    await conn.UploadAsync(session.Id, chunk.Sequence, chunk.Data, chunk.ExpectedFrames, token).ConfigureAwait(false);
                else if (session.Settings.Preferences.KeepOriginalAudio)
                    await conn.UploadOriginalAsync(session.Id, chunk.Sequence, chunk.Data, chunk.SampleRate, chunk.Channels, chunk.ExpectedFrames, token).ConfigureAwait(false);
            }, new Progress<float>(level => Volatile.Write(ref peak, level)), ct))
            {
                ct.ThrowIfCancellationRequested();
                creating = conn.CreateAsync(Guid.NewGuid(), test ? "test" : "dictation", ct);
                ticket.SetResult(creating);
                elapsed.Restart();
                Publish(State with { Activity = UiActivity.Recording, ActivityText = test ? "Testing microphone" : "Recording" });
                await Task.WhenAny(stopped.Task, microphone.Completion).WaitAsync(ct);
                releasedAt = Environment.TickCount64;
                Publish(State with { Activity = UiActivity.Processing, ActivityText = "Finishing audio…", Level = 0 });
                frames = await microphone.StopAsync();
                ct.ThrowIfCancellationRequested();
            }
            Publish(State with { ActivityText = "Transcribing…" });
            var record = await admitted;
            var completed = await conn.FinishAsync(record.Id, frames.InferenceFrames, record.Settings.Preferences.KeepOriginalAudio ? frames.OriginalFrames : null, ct);
            submitted = true;
            if (!completed.IsTerminal) completed = await conn.PollAsync(record.Id, ct);
            if (completed.Status != "completed") throw new InvalidOperationException(completed.Error ?? $"Recording {completed.Status}.");
            ct.ThrowIfCancellationRequested();
            var transcript = string.IsNullOrWhiteSpace(completed.PreviewText) ? completed.FinalText : completed.PreviewText;
            string receipt, message;
            if (test)
            {
                receipt = "tested";
                message = frames.Interrupted ? "The microphone dropped audio. Try the test again."
                    : string.IsNullOrWhiteSpace(transcript) ? "No speech detected."
                    : "Microphone test complete.";
            }
            else if (frames.Interrupted) (receipt, message) = ("failed", "The microphone dropped audio. Check the preview for missing words; nothing was inserted.");
            else if (previewOnly || Environment.TickCount64 - releasedAt > 60_000) (receipt, message) = ("failed", "Saved to preview only. The shortcut was interrupted or the response arrived late.");
            else if (string.IsNullOrEmpty(completed.InsertionText)) (receipt, message) = ("failed", "No text to insert.");
            else
            {
                for (int wait = 0; wait < 20 && TextDelivery.ShortcutHeld(); wait++) await Task.Delay(50, ct);
                ct.ThrowIfCancellationRequested();
                var result = destination != null ? TextDelivery.Insert(destination, completed.InsertionText)
                    : await AccessibleDelivery.InsertAsync(await accessible!, completed.InsertionText, ct);
                (receipt, message) = (result.Status, result.Message);
            }
            PublishResult(message, transcript);
            if (!test && receipt != "inserted") Notice?.Invoke(receipt == "unconfirmed" ? "Check the destination before copying from Inlay." : "Open Inlay to copy your dictation.");
            using var reporting = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            try { await conn.DeliveryAsync(record.Id, receipt, message, reporting.Token); }
            catch (Exception)
            { PublishResult(message + " Delivery receipt wasn’t saved.", transcript); }
        }
        catch (Exception ex)
        {
            var cancelled = ct.IsCancellationRequested;
            var idle = State with { Activity = UiActivity.Idle, ActivityText = "", IsTesting = false };
            if (test)
            {
                testing = false;
                Publish(idle with { TestResult = new(cancelled ? "Microphone test cancelled." : $"Microphone test failed: {ex.Message}", "") });
            }
            else if (announced || !cancelled) Publish(idle with { Delivery = cancelled ? "Recording cancelled." : ex.Message });
            if (!cancelled) Notice?.Invoke(test ? "Microphone test failed. Open Inlay for details." : "Dictation couldn’t finish. Open Inlay for details.");
            // A create request already on the wire can still commit after cancellation. Observe its
            // actual id before cancelling; never create a replacement or replay a sealed take.
            if (creating != null && (!submitted || cancelled))
            {
                try
                {
                    var abandoned = await creating;
                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                    await conn.CancelAsync(abandoned.Id, timeout.Token);
                }
                catch { /* unsealed uploads also expire */ }
            }
        }
        finally
        {
            ticket.TrySetCanceled();
            TextDelivery.Forget();
            AccessibleDelivery.Forget();
            elapsed.Reset();
            Volatile.Write(ref peak, 0);
            release = null;
            take = null;
            testing = false;
            Publish(State with { Activity = UiActivity.Idle, ActivityText = "", IsTesting = false, Elapsed = TimeSpan.Zero, Level = 0 });
        }
    }
}
