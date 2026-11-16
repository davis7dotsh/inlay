// Talk to the Transcriber Hub over TLS with a pinned key. The client trusts only the shipped hub
// certificate (ca) and, on every handshake, also checks the SHA-256 of the server's public key
// (SPKI) against the pin. A server that fails either check gets no request bytes: the handshake
// fails before fetch sends the request line.
import { createHash, X509Certificate } from "node:crypto";
import { checkServerIdentity, type PeerCertificate } from "node:tls";
import type { Held, RecordPost } from "../../../Hub/src/record.ts";

export type HubTarget = {
  addresses: string[]; // base URLs in the order to try, such as https://10.10.20.128:8797
  ca: string; // PEM of the hub certificate
  pin: string; // sha256/<base64 SHA-256 of the SPKI DER>
  token: string;
};

/// Why a run stops early. The records it did not reach wait for the next run.
export type Stop =
  | { kind: "unreachable"; detail: string }
  | { kind: "pin_refused"; detail: string }
  | { kind: "nas_window"; retryAfter: string | null }
  | { kind: "share_unavailable" }
  | { kind: "unauthorized"; detail: string };

export class StopRun extends Error {
  constructor(readonly stop: Stop) {
    super(`stop: ${stop.kind}`);
  }
}

/// A reply about one record that does not stop the run (bad record, audio conflict, a 500).
export class RecordRefused extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly detail: string,
  ) {
    super(`hub replied ${status} ${code}`);
  }
}

/// Only https addresses: the pin is checked in the TLS handshake, which plain http skips, so an http
/// address would get the token and the record with no check at all.
export function assertHttps(addresses: string[]) {
  for (const address of addresses)
    if (!URL.canParse(address) || new URL(address).protocol !== "https:")
      throw new Error(`the hub address ${address} is not an https URL`);
}

export const spkiPin = (certDer: Uint8Array) =>
  `sha256/${createHash("sha256")
    .update(new X509Certificate(certDer).publicKey.export({ type: "spki", format: "der" }))
    .digest("base64")}`;

const PIN_MISMATCH = "transcriber-hub pin mismatch";

/// fetch options that check the host name and the pin on every handshake. keepalive: false makes
/// every request a new connection: Bun skips checkServerIdentity on a pooled connection.
function tlsOptions(target: HubTarget) {
  return {
    keepalive: false,
    tls: {
      ca: target.ca,
      checkServerIdentity(host: string, cert: PeerCertificate) {
        const error = checkServerIdentity(host, cert);
        if (error) return error;
        if (spkiPin(cert.raw) !== target.pin) return new Error(PIN_MISMATCH);
        return undefined;
      },
    },
  };
}

const isPinError = (error: unknown) =>
  error instanceof Error &&
  (error.message.includes(PIN_MISMATCH) ||
    /certificate|self.signed|UNABLE_TO_VERIFY|CERT_|ERR_TLS/i.test(
      `${error.message} ${"code" in error ? String(error.code) : ""}`,
    ));

const describe = (error: unknown) =>
  error instanceof Error
    ? `${"code" in error ? `${String(error.code)} ` : ""}${error.message}`.slice(0, 200)
    : "unknown";

export class HubClient {
  private base: string | null = null;

  constructor(private readonly target: HubTarget) {
    assertHttps(target.addresses);
  }

  get address() {
    return this.base;
  }

  /// Find the first address whose /healthz answers over a pinned handshake. Throws StopRun when
  /// none does: pin_refused when an address answered with another key, else unreachable.
  async connect(timeoutMs = 5000): Promise<string> {
    const failures: string[] = [];
    let refused = false;
    for (const base of this.target.addresses) {
      try {
        const res = await fetch(`${base}/healthz`, {
          ...tlsOptions(this.target),
          signal: AbortSignal.timeout(timeoutMs),
        });
        if (res.ok && (await res.text()) === "ok") {
          this.base = base;
          return base;
        }
        failures.push(`${base}: healthz ${res.status}`);
      } catch (error) {
        if (isPinError(error)) refused = true;
        failures.push(`${base}: ${describe(error)}`);
      }
    }
    throw new StopRun({
      kind: refused ? "pin_refused" : "unreachable",
      detail: failures.join("; "),
    });
  }

  /// POST one record. Returns the reply body, which the caller checks against the record.
  post(body: RecordPost, timeoutMs = 15 * 60_000): Promise<unknown> {
    return this.request("/v1/records", body, timeoutMs);
  }

  /// Ask the hub to hash the record's FLAC on the share again and compare every stored hash with
  /// the confirm. Returns the reply body: { ok: true } or { ok: false, mismatches }.
  reconfirm(recordingId: string, held: Held, timeoutMs = 5 * 60_000): Promise<unknown> {
    return this.request(
      `/v1/records/${encodeURIComponent(recordingId)}/reconfirm`,
      { recording_id: recordingId, ...held },
      timeoutMs,
    );
  }

  /// POST JSON. A lost connection retries connect() once, then stops the run. A 503, a refused
  /// pin or a refused token stops the run. Another error reply throws RecordRefused.
  private async request(path: string, body: unknown, timeoutMs: number): Promise<unknown> {
    const json = JSON.stringify(body);
    for (let attempt = 0; ; attempt++) {
      const base = this.base ?? (await this.connect());
      let res: Response;
      try {
        res = await fetch(`${base}${path}`, {
          ...tlsOptions(this.target),
          method: "POST",
          headers: {
            authorization: `Bearer ${this.target.token}`,
            "content-type": "application/json",
          },
          body: json,
          signal: AbortSignal.timeout(timeoutMs),
        });
      } catch (error) {
        this.base = null;
        if (isPinError(error)) throw new StopRun({ kind: "pin_refused", detail: describe(error) });
        if (attempt === 0) continue;
        throw new StopRun({ kind: "unreachable", detail: describe(error) });
      }
      if (res.ok) {
        // The body is read after the headers, so a dropped connection can fail here too. Treat it
        // like a failed fetch: retry once, then stop the run cleanly.
        try {
          return (await res.json()) as unknown;
        } catch (error) {
          this.base = null;
          if (error instanceof SyntaxError)
            throw new RecordRefused(
              res.status,
              "bad_reply",
              "the hub sent a reply that is not JSON",
            );
          if (attempt === 0) continue;
          throw new StopRun({ kind: "unreachable", detail: describe(error) });
        }
      }
      const reply: unknown = await res.json().catch(() => null);
      /// A string field of the hub's error reply ({ error, message }), never a secret or a text.
      const field = (key: "error" | "message") => {
        if (typeof reply !== "object" || reply === null || !(key in reply)) return "unknown";
        const value: unknown = (reply as Record<string, unknown>)[key];
        return typeof value === "string" ? value.slice(0, 200) : "unknown";
      };
      const code = field("error");
      if (res.status === 503)
        throw new StopRun(
          code === "nas_window"
            ? { kind: "nas_window", retryAfter: res.headers.get("retry-after") }
            : { kind: "share_unavailable" },
        );
      if (res.status === 401) throw new StopRun({ kind: "unauthorized", detail: code });
      throw new RecordRefused(res.status, code, field("message"));
    }
  }
}
