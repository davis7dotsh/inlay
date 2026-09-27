#!/usr/bin/env python3
"""Exercise a running Dev server with the public JFK fixture; never open a mic.

Creates two test generations, toggles/restores original retention, checks real
Parakeet/Qwen execution and durable artifacts. Requires an idle Dev server.
"""
import argparse
import array
import json
import os
from pathlib import Path
import struct
import sys
import time
import urllib.error
import urllib.request
import uuid
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default=os.environ.get("V07_SERVER_URL", "http://127.0.0.1:8391"))
    parser.add_argument("--token-file", type=Path)
    parser.add_argument("--audio-fixture", type=Path, help="Public mono 16 kHz PCM16 WAV; defaults to whisper.cpp's JFK sample")
    parser.add_argument("--keep-results", action="store_true", help="Keep the two synthetic generations for UI inspection")
    args = parser.parse_args()
    token = args.token_file.read_text().strip() if args.token_file else ""
    root = Path(__file__).resolve().parents[1]
    endpoint = args.endpoint.rstrip("/")

    class NoRedirects(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    opener = urllib.request.build_opener(NoRedirects)

    def request(path, method="GET", value=None, raw=None, expected=200):
        headers = {"Content-Type": "application/octet-stream" if raw is not None else "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        data = raw if raw is not None else (json.dumps(value).encode() if value is not None else None)
        req = urllib.request.Request(endpoint + "/v1/" + path, data=data, headers=headers, method=method)
        try:
            response = opener.open(req, timeout=240)
        except urllib.error.HTTPError as error:
            response = error
        assert response.status == expected, (path, response.status, response.read().decode()[:300])
        return response

    def api(path, method="GET", value=None, expected=200):
        with request(path, method, value, expected=expected) as response:
            return json.load(response)

    deadline = time.monotonic() + 150
    while True:
        health = api("health")
        assert health["isDev"], "This test only operates on an explicitly marked Dev server"
        if health["ready"] and health["proofreading"]["ready"]:
            break
        assert time.monotonic() < deadline, health
        time.sleep(1)

    with wave.open(str(args.audio_fixture or root / "vendor/whisper.cpp/samples/jfk.wav"), "rb") as source:
        assert source.getnchannels() == 1 and source.getframerate() == 16000 and source.getsampwidth() == 2
        samples = array.array("h", source.readframes(source.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    floats = array.array("f", (sample / 32768.0 for sample in samples))
    if sys.byteorder != "little":
        floats.byteswap()
    pcm = floats.tobytes()
    original = api("preferences")
    assert original["preferences"]["textCorrectionEnabled"], "Enable proofreading for this full model integration test"
    created = []
    own_revision = original["revision"]
    summary = []
    try:
        for keep_original in (True, False):
            update = api("preferences")
            assert update["revision"] == own_revision, "Another client changed preferences during the smoke test"
            update["preferences"]["keepOriginalAudio"] = keep_original
            current = api("preferences", "PUT", update)
            own_revision = current["revision"]
            device = {"id": "api-smoke-" + str(uuid.uuid4()), "name": "API smoke test " + ("Mac" if keep_original else "Neo")}
            generation = api("generations", "POST", {"requestID": str(uuid.uuid4()), "device": device, "mode": "test"}, 201)
            identifier = generation["id"]
            created.append(identifier)
            prefix = "generations/" + identifier
            for kind in (["inference", "original"] if keep_original else ["inference"]):
                for sequence, offset in enumerate(range(0, len(pcm), 65536)):
                    chunk = pcm[offset:offset + 65536]
                    path = f"{prefix}/audio/{kind}?sequence={sequence}&sampleRate=16000&channels=1"
                    with request(path, "POST", raw=chunk) as response:
                        receipt = json.load(response)
                    assert receipt["nextSequence"] == sequence + 1
                    assert receipt["frameCount"] == (offset + len(chunk)) // 4
            counts = {"inferenceFrames": len(samples)}
            if keep_original:
                counts["originalFrames"] = len(samples)
            started = time.monotonic()
            api(prefix + "/finish", "POST", counts, 202)
            states = []
            with request(prefix + "/events") as response:
                assert "ndjson" in response.headers["Content-Type"]
                for line in response:
                    event = json.loads(line)
                    states.append(event["status"])
            elapsed = time.monotonic() - started
            result = api(prefix)
            assert result["status"] == "completed", result.get("error")
            assert states[-1] == "completed", states
            assert "country" in result["rawText"].lower(), result["rawText"]
            assert result["speech"]["modelSHA256"] == "833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f"
            assert result["speech"]["modelID"] == "parakeet-tdt-0.6b-v3"
            assert result["recognitionHints"]["tokenBudget"] == 0
            assert result["recognitionHints"]["includedTerms"] == []
            assert result.get("detectedLanguage") is None
            assert result["textProcessing"]["status"] in ("applied", "unchanged", "rejected"), result["textProcessing"]
            assert result["device"] == device
            assert bool(result.get("originalAudio")) == keep_original
            for kind in (["inference", "original"] if keep_original else ["inference"]):
                with request(f"{prefix}/artifacts/{kind}.wav") as response:
                    audio = response.read()
                assert audio[:4] == b"RIFF" and struct.unpack_from("<H", audio, 20)[0] == 3
                assert audio[44:] == pcm, "Stored audio differs from uploaded samples"
            with request(prefix + "/artifacts/transcript.txt") as response:
                assert response.read().decode() == result["finalText"]
            with request(prefix + "/artifacts/metadata.json") as response:
                assert json.load(response)["finalText"] == result["finalText"]
            api(prefix + "/delivery", "POST", {"status": "tested", "reportedAt": "2026-01-01T00:00:00Z"})
            if not keep_original:
                request(prefix + "/artifacts/original.wav", expected=404).close()
            summary.append({"id": identifier, "audioSeconds": len(samples) / 16000,
                            "afterReleaseSeconds": round(elapsed, 3), "states": list(dict.fromkeys(states)),
                            "originalRetained": keep_original, "proofreading": result["textProcessing"]["status"]})
        history = api("generations")["items"]
        assert set(created) <= {item["id"] for item in history}
        print(json.dumps({"passed": True, "generations": summary}, indent=2))
    finally:
        current = api("preferences")
        if current["revision"] == own_revision:
            current["preferences"] = original["preferences"]
            api("preferences", "PUT", current)
        else:
            print("Preferences changed elsewhere; leaving their current values intact.", file=sys.stderr)
        if not args.keep_results:
            for identifier in created:
                api(f"generations/{identifier}/cancel", "POST")
                request(f"generations/{identifier}", "DELETE", expected=204).close()


if __name__ == "__main__":
    main()
