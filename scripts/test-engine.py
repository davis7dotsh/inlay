#!/usr/bin/env python3
"""Exercise the actual persistent helper with a downloaded model; no network."""

import argparse
import json
import math
import queue
import random
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_VAD = ROOT / ".build/models/silero-vad.bin"


def float_audio(path, samples, sample_rate=16000):
    data = struct.pack(f"<{len(samples)}f", *samples)
    fmt = struct.pack("<HHIIHH", 3, 1, sample_rate, sample_rate * 4, 4, 32)
    path.write_bytes(
        b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
        + struct.pack("<I", len(fmt)) + fmt + b"data"
        + struct.pack("<I", len(data)) + data
    )


def silence(path, frames=16000, sample_rate=16000, floating=False):
    if floating:
        float_audio(path, [0] * frames, sample_rate=sample_rate)
    else:
        with wave.open(str(path), "wb") as recording:
            recording.setnchannels(1)
            recording.setsampwidth(2)
            recording.setframerate(sample_rate)
            recording.writeframes(bytes(frames * 2))


class Engine:
    def __init__(self, executable, model, diagnostics, vad_model=DEFAULT_VAD):
        self.process = subprocess.Popen(
            [str(executable), "--model", str(model), "--vad-model", str(vad_model)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=diagnostics, text=True, bufsize=1,
        )
        self.events = queue.Queue()

        def consume():
            for line in self.process.stdout:
                try:
                    self.events.put(json.loads(line))
                except json.JSONDecodeError:
                    self.events.put({"invalid_stdout": line})
            self.events.put({"eof": True})

        threading.Thread(target=consume, daemon=True).start()
        event = self.next()
        assert event.get("type") == "ready" and event.get("engineVersion"), event

    def next(self):
        try:
            return self.events.get(timeout=120)
        except queue.Empty as error:
            raise AssertionError("The helper stopped responding for 120 seconds.") from error

    def send(self, request):
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()

    def transcribe(self, path, request_id, **fields):
        self.send({"type": "transcribe", "id": request_id, "path": str(path), **fields})
        last_progress = -1
        while True:
            event = self.next()
            assert event.get("id") == request_id, event
            if event.get("type") != "progress":
                return event
            value = event["value"]
            assert last_progress <= value <= 1, event
            last_progress = value

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        self.process.wait(timeout=10)


def assert_parent_exit(executable, model, vad_model, audio):
    parent_source = """
import json, subprocess, sys
engine, model, vad, audio = sys.argv[1:]
child = subprocess.Popen([engine, '--model', model, '--vad-model', vad], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
assert json.loads(child.stdout.readline())['type'] == 'ready'
child.stdin.write(json.dumps({'type':'transcribe', 'id':'parent-exit', 'path':audio}) + '\\n')
child.stdin.flush()
assert json.loads(child.stdout.readline())['type'] == 'progress'
print(child.pid, flush=True)
sys.stdin.read()
"""
    parent = subprocess.Popen(
        [sys.executable, "-B", "-c", parent_source, str(executable), str(model), str(vad_model), str(audio)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    try:
        child_pid = int(parent.stdout.readline().strip())
        started = time.monotonic()
        parent.terminate()
        parent.wait(timeout=5)
        while True:
            status = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="], capture_output=True, text=True)
            if status.returncode or "Z" in status.stdout:
                break
            if time.monotonic() - started > 5:
                subprocess.run(["kill", "-TERM", str(child_pid)], check=False)
                raise AssertionError("The helper survived its parent during active transcription.")
            time.sleep(0.025)
        print(f"Passed: parent exit stops active transcription ({time.monotonic() - started:.3f}s)", flush=True)
    finally:
        if parent.poll() is None:
            parent.terminate()
            parent.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, default=ROOT / ".build/server-native/Engine/v07-engine")
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--vad-model", type=Path, default=DEFAULT_VAD)
    parser.add_argument("--audio", type=Path, default=ROOT / "vendor/whisper.cpp/samples/jfk.wav")
    args = parser.parse_args()

    missing = subprocess.run(
        [str(args.engine), "--model", "/nonexistent/v07-test-model"],
        capture_output=True, text=True, timeout=10,
    )
    assert missing.returncode != 0
    assert json.loads(missing.stdout)["type"] == "error"
    print("Passed: missing-model error", flush=True)

    missing_vad = subprocess.run(
        [str(args.engine), "--model", str(args.model)],
        capture_output=True, text=True, timeout=10,
    )
    assert missing_vad.returncode != 0
    assert json.loads(missing_vad.stdout)["type"] == "error"
    print("Passed: a missing speech detector fails safely", flush=True)

    with tempfile.TemporaryDirectory(prefix="v07-engine-test-") as directory:
        temporary = Path(directory)
        with tempfile.TemporaryFile(mode="w+") as diagnostics:
            engine = Engine(args.engine, args.model, diagnostics, args.vad_model)
            try:
                engine.process.stdin.write("this is not JSON\n")
                engine.process.stdin.flush()
                assert engine.next()["type"] == "error"

                pcm = temporary / "silence.wav"
                floating = temporary / "silence-float.wav"
                silence(pcm)
                silence(floating, floating=True)
                for path in (pcm, floating):
                    result = engine.transcribe(path, path.name)
                    assert result["type"] == "result", result
                    assert result["text"] == "", result
                    assert result["duration"] == 1, result
                print("Passed: PCM16 / float32 silence and malformed-request recovery", flush=True)

                noise = temporary / "noise.wav"
                tone = temporary / "tone.wav"
                random_source = random.Random(0)
                float_audio(noise, [random_source.uniform(-0.01, 0.01) for _ in range(32000)])
                float_audio(tone, [0.1 * math.sin(i * 440 * 2 * math.pi / 16000) for i in range(32000)])
                for path in (noise, tone):
                    result = engine.transcribe(path, path.name)
                    assert result["type"] == "result" and result["text"] == "", result
                print("Passed: Silero rejects noise and pure tone", flush=True)

                for name, frames, rate in (
                    ("short", 3199, 16000),
                    ("long", 16000 * 180 + 1, 16000),
                    ("rate", 44100, 44100),
                ):
                    path = temporary / f"{name}.wav"
                    silence(path, frames=frames, sample_rate=rate)
                    assert engine.transcribe(path, name)["type"] == "error"
                assert engine.transcribe(temporary / "missing.wav", "missing")["type"] == "error"
                assert engine.transcribe(pcm, "language", language="not-a-language")["type"] == "error"
                assert engine.transcribe(pcm, "prompt", prompt=23)["type"] == "error"
                for index, terms in enumerate((None, "auth", [23], [""], [" auth"], ["auth\nterm"], ["auth\0"], ["x" * 16385])):
                    assert engine.transcribe(pcm, f"invalid-terms-{index}", vocabularyTerms=terms)["type"] == "error"
                print("Passed: duration, sample-rate, path, language, and prompt validation", flush=True)

                # Parakeet cannot consume vocabulary prompts. Preserve every
                # omitted term and report zero capacity, including legacy callers.
                terms = ["auth", "Café"] + [f"preferred term {i}" for i in range(500)]
                for supplied in ([], terms, ["long vocabulary phrase " * 500 + "end", "auth"]):
                    hints = engine.transcribe(pcm, "vocabulary", vocabularyTerms=supplied)
                    assert hints["type"] == "result", hints
                    assert hints["includedTerms"] == [] and hints["omittedTerms"] == supplied, hints
                    assert hints["tokenCount"] == hints["tokenBudget"] == 0, hints
                legacy = engine.transcribe(pcm, "legacy-prompt", prompt="auth, Café")
                assert legacy["includedTerms"] == [] and legacy["omittedTerms"] == ["auth, Café"], legacy
                assert engine.transcribe(pcm, "unsupported-language", language="ja")["type"] == "error"
                for language in ("auto", "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el",
                                 "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"):
                    result = engine.transcribe(pcm, "supported-language", language=language)
                    assert result["type"] == "result" and result["language"] == "auto", result
                print("Passed: unsupported vocabulary is reported honestly; supported languages accepted", flush=True)

                started = time.monotonic()
                result = engine.transcribe(args.audio, "speech", language="en", vocabularyTerms=["country"])
                assert result["type"] == "result", result
                assert result["text"].strip(), result
                if args.audio.name == "jfk.wav":
                    normalized = re.sub(r"[^a-z ]", "", result["text"].lower())
                    assert "ask not what your country can do for you" in normalized, result
                    assert "ask what you can do for your country" in normalized, result
                assert result["language"] == "auto", result
                print(f"Passed: real speech transcription ({time.monotonic() - started:.2f}s)", flush=True)

                with wave.open(str(args.audio), "rb") as source:
                    assert source.getnchannels() == 1 and source.getsampwidth() == 2 and source.getframerate() == 16000
                    samples = [value[0] / 32768 for value in struct.iter_unpack("<h", source.readframes(source.getnframes()))]
                for scale in (1, 0.04):
                    path = temporary / f"speech-{scale}.wav"
                    float_audio(path, [sample * scale for sample in samples])
                    result = engine.transcribe(path, path.name, language="en")
                    assert result["type"] == "result" and result["text"].strip(), result
                    if args.audio.name == "jfk.wav":
                        assert "country" in result["text"].lower(), result
                print("Passed: float32 speech and very quiet speech (-28 dB)", flush=True)

                if args.audio.name == "jfk.wav":
                    # Longer recordings must retain every passage, even when hints
                    # are supplied (and correctly reported as unused).
                    repeated = temporary / "repeated-speech.wav"
                    float_audio(repeated, (samples + [0.0] * 16000) * 3)
                    result = engine.transcribe(repeated, "repeated-speech", language="en",
                                               vocabularyTerms=["MiniMax", "Codex"])
                    assert result["type"] == "result", result
                    normalized = " ".join(re.findall(r"[a-z]+", result["text"].lower()))
                    for phrase in ("my fellow americans", "ask not what your country can do for you",
                                   "ask what you can do for your country"):
                        assert normalized.count(phrase) == 3, result
                    assert "<|" not in result["text"], "Timestamp tokens leaked into plain text"
                    print("Passed: every repeated passage survives across decoding windows with vocabulary hints", flush=True)

                # Silence after speech must not inherit the previous transcript.
                assert engine.transcribe(pcm, "after-speech")["text"] == ""
                assert engine.transcribe(noise, "noise-after-speech")["text"] == ""
                engine.send({"type": "quit"})
                assert engine.process.wait(timeout=10) == 0
                diagnostics.seek(0)
                log = diagnostics.read().lower()
                assert "ask not what your country" not in log, "Transcript leaked into stderr"
                print("Passed: request isolation, transcript-free diagnostics, clean shutdown", flush=True)
            finally:
                engine.stop()

        long_audio = temporary / "long-speech.wav"
        with wave.open(str(args.audio), "rb") as source:
            parameters = source.getparams()
            raw = source.readframes(source.getnframes())
        with wave.open(str(long_audio), "wb") as recording:
            recording.setparams(parameters)
            recording.writeframes((raw * 20)[:16000 * 2 * 120])
        assert_parent_exit(args.engine, args.model, args.vad_model, long_audio)

        with tempfile.TemporaryFile(mode="w+") as diagnostics:
            engine = Engine(args.engine, args.model, diagnostics, args.vad_model)
            try:
                engine.process.stdin.close()
                assert engine.process.wait(timeout=10) == 0
                print("Passed: stdin EOF releases the model", flush=True)
            finally:
                engine.stop()


if __name__ == "__main__":
    main()
