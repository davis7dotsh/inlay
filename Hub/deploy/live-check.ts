// Live checks of a deployed hub, run on the MacBook with the tokens of the two test devices:
//   HUB_CA=<cert.pem> HUB_TOKEN_FILE=<file> HUB_TOKEN_FILE_2=<file> bun deploy/live-check.ts <address> [address ...]
//   HUB_CA=<cert.pem> HUB_TOKEN_FILE=<file> bun deploy/live-check.ts --revoked <address> [address ...]
// For each address it posts a small generated FLAC record, replays it, cuts a post off twice and
// resends it, sends a wrong hash, no token, a wrong token and a record of the MacBook device, then
// reconfirms and searches. It posts one new recording from both test devices at once (one wins,
// the other gets 403) and resends a record with new texts (the rows take the new texts). It reads the share and the database on services-01 over ssh (read only).
// With HUB_CHECK_LOCAL=1 it runs on services-01 itself and reads them directly. It makes each FLAC
// from a generated 1-second WAV with macOS afconvert.
// It prints one JSON line per check and exits 1 when a check fails. It never prints the token.
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { connect } from "node:tls";

const PORT = Number(process.env.HUB_PORT || 8797);
const ca = await Bun.file(process.env.HUB_CA!).text();
const token = (await Bun.file(process.env.HUB_TOKEN_FILE!).text()).trim();
const TEST_DEVICE = "hub-test-device";
const TEST_DEVICE_2 = "hub-test-device-2";
const MACBOOK = "05d8dedd-c925-4924-8db9-45f3e7452d34";
const args = process.argv.slice(2);
const revokedMode = args[0] === "--revoked";
const addresses = revokedMode ? args.slice(1) : args;
const token2 = revokedMode ? "" : (await Bun.file(process.env.HUB_TOKEN_FILE_2!).text()).trim();
let failed = 0;

const sha = (d: Uint8Array | string) => createHash("sha256").update(d).digest("hex");
function report(address: string, check: string, pass: boolean, evidence: unknown) {
  if (!pass) failed++;
  console.log(JSON.stringify({ address, check, pass, evidence }));
}

async function ssh(command: string): Promise<string> {
  const remote =
    process.env.HUB_CHECK_LOCAL === "1"
      ? ["/bin/sh", "-c"]
      : ["ssh", "-o", "BatchMode=yes", "services-01"];
  const p = Bun.spawn(["perl", "-e", "alarm 60; exec @ARGV", ...remote, command], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const out = await new Response(p.stdout).text();
  if ((await p.exited) !== 0) throw new Error(`ssh failed: ${await new Response(p.stderr).text()}`);
  return out.trim();
}

/// Rows of one recording and the files of one FLAC on the share, read on services-01.
async function stored(recordingId: string, flacSha: string) {
  const q = (t: string) => `select count(*) from ${t} where recording_id='${recordingId}'`;
  const db = await ssh(
    `sqlite3 -readonly ~/data/transcripts/transcripts.sqlite "${q("recordings")}; select count(*) from audio where sha256='${flacSha}'; ${q("transcriptions")}; ${q("cleanups")}"`,
  );
  const [recordings, audio, transcriptions, cleanups] = db.split("\n").map(Number);
  const files = await ssh(
    `perl -e 'alarm 60; exec @ARGV' /bin/sh -c 'ls ~/mnt/nas-transcripts/artifacts/${flacSha.slice(0, 2)}/ 2>/dev/null | grep -c ${flacSha} || true'`,
  );
  const fileSha = await ssh(
    `perl -e 'alarm 60; exec @ARGV' /bin/sh -c 'shasum -a 256 ~/mnt/nas-transcripts/artifacts/${flacSha.slice(0, 2)}/${flacSha}.flac 2>/dev/null | cut -d" " -f1'`,
  );
  return { recordings, audio, transcriptions, cleanups, files: Number(files), fileSha };
}

async function makeFlac(frequency: number): Promise<Uint8Array> {
  const base = `/tmp/hub-live-${randomBytes(4).toString("hex")}`;
  const rate = 16000;
  const wav = Buffer.alloc(44 + rate * 2);
  wav.write("RIFF", 0);
  wav.writeUInt32LE(36 + rate * 2, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); // PCM
  wav.writeUInt16LE(1, 22); // mono
  wav.writeUInt32LE(rate, 24);
  wav.writeUInt32LE(rate * 2, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(rate * 2, 40);
  for (let i = 0; i < rate; i++)
    wav.writeInt16LE(Math.round(8000 * Math.sin((2 * Math.PI * frequency * i) / rate)), 44 + i * 2);
  await Bun.write(`${base}.wav`, wav);
  const p = Bun.spawn(["afconvert", "-f", "flac", "-d", "flac", `${base}.wav`, `${base}.flac`], {
    stdout: "ignore",
    stderr: "inherit",
  });
  if ((await p.exited) !== 0) throw new Error("afconvert failed");
  const bytes = new Uint8Array(await Bun.file(`${base}.flac`).arrayBuffer());
  await Bun.file(`${base}.wav`).delete();
  await Bun.file(`${base}.flac`).delete();
  return bytes;
}

function record(flac: Uint8Array, word: string, device = TEST_DEVICE) {
  return {
    recording: {
      recording_id: randomUUID(),
      recorded_at: new Date().toISOString(),
      device_id: device,
      mode: "dictation",
      status: "completed",
      language: "en",
      app: "hub-live-check",
      duration_seconds: 1,
    },
    transcription: {
      provider: "hub-live-check",
      model: "none",
      model_version: null,
      settings: {},
      processing_seconds: null,
      detected_language: "en",
      text: `hub live check raw ${word}`,
    },
    cleanup: {
      engine: "Transcriber",
      engine_version: null,
      model: "none",
      model_sha256: null,
      prompt_sha256: null,
      status: "completed",
      text: `Hub live check, ${word}.`,
    },
    audio: {
      sha256: sha(flac),
      source_sha256: sha(`wav ${word}`),
      source_bytes: null,
      sample_rate: 16000,
      frame_count: 16000,
      flac_base64: Buffer.from(flac).toString("base64"),
    },
  };
}

const call = (address: string, path: string, init: RequestInit & { auth?: string | null } = {}) => {
  const auth = init.auth === undefined ? token : init.auth;
  return fetch(`https://${address}:${PORT}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...(auth ? { authorization: `Bearer ${auth}` } : {}),
    },
    tls: { ca },
  });
};

/// Send a request over a raw TLS socket and close it: after half the body (cut mid-upload), or right
/// after the whole request, before the reply (the confirm never reaches the client).
function cutOff(address: string, body: string, whole: boolean): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = connect({ host: address, port: PORT, ca }, () => {
      const head =
        `POST /v1/records HTTP/1.1\r\nHost: ${address}:${PORT}\r\nAuthorization: Bearer ${token}\r\n` +
        `Content-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n`;
      const sent = whole ? body : body.slice(0, Math.floor(body.length / 2));
      socket.write(head + sent, () => {
        socket.destroy();
        resolve();
      });
    });
    socket.on("error", reject);
  });
}

async function checkAddress(address: string, n: number) {
  const health = await call(address, "/healthz", { auth: null });
  report(
    address,
    "healthz without auth",
    health.status === 200 && (await health.text()) === "ok",
    health.status,
  );

  const word = `zephyrquill${randomBytes(3).toString("hex")}`;
  const flac = await makeFlac(440 + n * 110);
  const body = record(flac, word);
  const id = body.recording.recording_id;
  const res = await call(address, "/v1/records", { method: "POST", body: JSON.stringify(body) });
  const confirm = await res.json();
  report(
    address,
    "post reaches the hub",
    res.status === 200 &&
      confirm.flac_sha256 === body.audio.sha256 &&
      confirm.text_sha256.raw === sha(body.transcription.text) &&
      confirm.text_sha256.clean === sha(body.cleanup.text),
    {
      status: res.status,
      confirm,
    },
  );
  const after = await stored(id, body.audio.sha256);
  report(
    address,
    "post reaches the share and the database",
    after.recordings === 1 &&
      after.audio === 1 &&
      after.transcriptions === 1 &&
      after.cleanups === 1 &&
      after.files === 1 &&
      after.fileSha === body.audio.sha256,
    after,
  );

  const found = await (await call(address, `/v1/search?q=${word}`)).json();
  report(
    address,
    "search finds the text",
    found.results?.[0]?.recording_id === id,
    found.results?.slice(0, 2),
  );

  const replay = await call(address, "/v1/records", { method: "POST", body: JSON.stringify(body) });
  const replayConfirm = await replay.json();
  const afterReplay = await stored(id, body.audio.sha256);
  report(
    address,
    "replay leaves 1 file and 1 set of rows",
    replay.status === 200 &&
      JSON.stringify(replayConfirm) === JSON.stringify(confirm) &&
      JSON.stringify(afterReplay) === JSON.stringify(after),
    {
      status: replay.status,
      stored: afterReplay,
    },
  );

  const midUpload = record(await makeFlac(1000 + n * 110), `${word}mid`);
  await cutOff(address, JSON.stringify(midUpload), false);
  await Bun.sleep(1500);
  const afterMid = await stored(midUpload.recording.recording_id, midUpload.audio.sha256);
  report(
    address,
    "a post cut off mid-upload writes nothing",
    afterMid.recordings === 0 && afterMid.files === 0,
    afterMid,
  );

  const beforeConfirm = record(await makeFlac(1500 + n * 110), `${word}cut`);
  await cutOff(address, JSON.stringify(beforeConfirm), true);
  await Bun.sleep(1500);
  const afterCut = await stored(beforeConfirm.recording.recording_id, beforeConfirm.audio.sha256);
  const resend = await call(address, "/v1/records", {
    method: "POST",
    body: JSON.stringify(beforeConfirm),
  });
  const afterResend = await stored(
    beforeConfirm.recording.recording_id,
    beforeConfirm.audio.sha256,
  );
  report(
    address,
    "a post cut off before its confirm, then resent, leaves 1 set",
    resend.status === 200 &&
      afterResend.recordings === 1 &&
      afterResend.audio === 1 &&
      afterResend.transcriptions === 1 &&
      afterResend.cleanups === 1 &&
      afterResend.files === 1,
    { afterCut, resendStatus: resend.status, afterResend },
  );

  const wrong = record(flac, `${word}bad`);
  wrong.audio.sha256 = sha("not these bytes");
  const bad = await call(address, "/v1/records", { method: "POST", body: JSON.stringify(wrong) });
  const afterBad = await stored(wrong.recording.recording_id, wrong.audio.sha256);
  report(
    address,
    "a wrong hash is refused and writes nothing",
    bad.status === 400 && afterBad.recordings === 0 && afterBad.files === 0,
    {
      status: bad.status,
      stored: afterBad,
    },
  );

  const fresh = JSON.stringify(record(flac, `${word}auth`));
  const missing = await call(address, "/v1/records", { method: "POST", body: fresh, auth: null });
  report(address, "a missing token is refused", missing.status === 401, missing.status);
  const wrongToken = await call(address, "/v1/records", {
    method: "POST",
    body: fresh,
    auth: randomBytes(32).toString("base64url"),
  });
  report(address, "a wrong token is refused", wrongToken.status === 401, wrongToken.status);
  const other = await call(address, "/v1/records", {
    method: "POST",
    body: JSON.stringify(record(flac, `${word}mac`, MACBOOK)),
  });
  report(
    address,
    "the test token naming the MacBook device is refused",
    other.status === 403,
    other.status,
  );

  const { recording_id: _id, ...held } = confirm;
  const re = await (
    await call(address, `/v1/records/${id}/reconfirm`, {
      method: "POST",
      body: JSON.stringify(held),
    })
  ).json();
  report(address, "reconfirm re-hashes the FLAC on the share", re.ok === true, re);

  // Two devices post the same new recording at once, each with its own text provider. Only one
  // may write: the other gets 403, and the recording holds one transcription.
  const raceFlac = await makeFlac(2000 + n * 110);
  const a = record(raceFlac, `${word}race`, TEST_DEVICE);
  const b = structuredClone(a);
  b.recording.device_id = TEST_DEVICE_2;
  b.transcription.provider = "hub-live-check-b";
  const raceId = a.recording.recording_id;
  const [ra, rb] = await Promise.all([
    call(address, "/v1/records", { method: "POST", body: JSON.stringify(a) }),
    call(address, "/v1/records", { method: "POST", body: JSON.stringify(b), auth: token2 }),
  ]);
  const raceRows = await stored(raceId, a.audio.sha256);
  const owner = await ssh(
    `sqlite3 -readonly ~/data/transcripts/transcripts.sqlite "select device_id from recordings where recording_id='${raceId}'"`,
  );
  const statuses = [ra.status, rb.status].sort();
  const winner = ra.status === 200 ? TEST_DEVICE : TEST_DEVICE_2;
  report(
    address,
    "two devices posting one new recording at once: one wins, the other gets 403",
    statuses[0] === 200 &&
      statuses[1] === 403 &&
      owner === winner &&
      raceRows.recordings === 1 &&
      raceRows.transcriptions === 1 &&
      raceRows.cleanups === 1,
    { statuses: [ra.status, rb.status], owner, stored: raceRows },
  );

  // The same take processed again: a resend with new texts updates the rows of the same IDs.
  const again = structuredClone(body);
  const newWord = `${word}again`;
  again.transcription.text = `hub live check raw ${newWord}`;
  again.cleanup.text = `Hub live check, ${newWord}.`;
  const changed = await call(address, "/v1/records", {
    method: "POST",
    body: JSON.stringify(again),
  });
  const changedConfirm = await changed.json();
  const afterChange = await stored(id, body.audio.sha256);
  const texts = await ssh(
    `sqlite3 -readonly ~/data/transcripts/transcripts.sqlite "select text from transcriptions where recording_id='${id}'; select text from cleanups where recording_id='${id}'"`,
  );
  const oldHits = (await (await call(address, `/v1/search?q=${word}`)).json()).results ?? [];
  const newHits = (await (await call(address, `/v1/search?q=${newWord}`)).json()).results ?? [];
  const { recording_id: _id2, ...newHeld } = changedConfirm;
  const reNew = await (
    await call(address, `/v1/records/${id}/reconfirm`, {
      method: "POST",
      body: JSON.stringify(newHeld),
    })
  ).json();
  report(
    address,
    "a resend with new texts updates the rows, and reconfirm passes with the new hashes",
    changed.status === 200 &&
      changedConfirm.text_sha256.raw === sha(again.transcription.text) &&
      changedConfirm.text_sha256.clean === sha(again.cleanup.text) &&
      changedConfirm.flac_sha256 === body.audio.sha256 &&
      JSON.stringify(afterChange) === JSON.stringify(after) &&
      texts === `${again.transcription.text}\n${again.cleanup.text}` &&
      newHits[0]?.recording_id === id &&
      !oldHits.some((h: { recording_id: string }) => h.recording_id === id) &&
      reNew.ok === true,
    {
      status: changed.status,
      stored: afterChange,
      new_word_found: newHits[0]?.recording_id === id,
      old_word_found: oldHits.some((h: { recording_id: string }) => h.recording_id === id),
      reconfirm: reNew,
    },
  );
  const reOld = await (
    await call(address, `/v1/records/${id}/reconfirm`, {
      method: "POST",
      body: JSON.stringify(held),
    })
  ).json();
  report(address, "reconfirm with the old text hashes now fails", reOld.ok === false, reOld);
}

async function checkRevoked(address: string) {
  const flac = await makeFlac(300);
  const res = await call(address, "/v1/records", {
    method: "POST",
    body: JSON.stringify(record(flac, "revoked")),
  });
  report(address, "the revoked test token is refused (post)", res.status === 401, res.status);
  const s = await call(address, "/v1/search?q=hub");
  report(address, "the revoked test token is refused (search)", s.status === 401, s.status);
}

for (const [n, address] of addresses.entries()) {
  if (revokedMode) await checkRevoked(address);
  else await checkAddress(address, n);
}
process.exit(failed ? 1 : 0);
