import { Readable } from "node:stream";
import Fastify, { type FastifyRequest } from "fastify";
import {
  MAXIMUM_ARTIFACT_BYTES,
  MAXIMUM_CHUNK_BYTES,
  MAXIMUM_DICTIONARY_BYTES,
  type WisprFlowArtifactName,
} from "./api.ts";
import type { RequestActor } from "./devices.ts";
import { ServiceError } from "./errors.ts";
import { logError } from "./log.ts";
import type { GenerationService } from "./generation-service.ts";
import { validateBody } from "./validation.ts";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const identifier = (value: string) => {
  if (!uuidPattern.test(value))
    throw new ServiceError(400, "invalid_id", "A recording ID must be a UUID.");
  return value.toLowerCase();
};
const integer = (value: string | undefined) =>
  value !== undefined && /^-?\d+$/.test(value) && Number.isSafeInteger(Number(value))
    ? Number(value)
    : undefined;
const bytes = (value: unknown) => {
  if (!Buffer.isBuffer(value))
    throw new ServiceError(400, "invalid_chunk", "Supply a binary request body.");
  return value;
};
const artifactNames = new Set<WisprFlowArtifactName>([
  "source.json",
  "source.wav",
  "opus.json",
  "screenshot.png",
  "built-in-audio.bin",
]);
const artifactName = (value: string) => {
  if (!artifactNames.has(value as WisprFlowArtifactName))
    throw new ServiceError(
      400,
      "invalid_source_artifact",
      "Choose an allowlisted source artifact.",
    );
  return value as WisprFlowArtifactName;
};

type IDParams = { id: string };
export function createHTTPServer(service: GenerationService) {
  const actors = new WeakMap<FastifyRequest, RequestActor>();
  // Blunts online guessing of a human-chosen admin token; device tokens are
  // 256-bit random. In-memory only: a restart resets the window.
  const authFailures = new Map<string, { count: number; windowStartedAt: number }>();
  const deviceIDOf = (request: FastifyRequest) => {
    const actor = actors.get(request);
    if (actor?.kind !== "device")
      throw new ServiceError(
        403,
        "enrollment_required",
        "This shared token now only enrolls devices. Reconnect from Inlay to give this Mac its own credential.",
      );
    return actor.id;
  };
  // Device IDs allow 128 graphemes, which can exceed find-my-way's default
  // 100-unit param limit. A decoded param is never longer than its encoded
  // path, so the 16 KiB HTTP header limit is the real bound.
  const app = Fastify({
    logger: false,
    bodyLimit: 262_144,
    routerOptions: { maxParamLength: 16_384 },
  });
  const parseJSON = app.getDefaultJsonParser("error", "error");
  app.removeContentTypeParser("application/json");
  app.addContentTypeParser("application/json", { parseAs: "string" }, (request, body, done) => {
    if (body === "") done(null, undefined);
    else void parseJSON(request, typeof body === "string" ? body : body.toString("utf8"), done);
  });
  app.addContentTypeParser(
    "application/octet-stream",
    { parseAs: "buffer" },
    (_request, body, done) => done(null, body),
  );
  app.addHook("onRequest", async (request) => {
    const path = request.url.split("?")[0]!;
    if (path !== "/v1/liveness") {
      const remote = request.socket.remoteAddress ?? "unknown";
      const header = request.headers.authorization ?? "";
      const actor = service.authenticate(
        header.startsWith("Bearer ") ? header.slice(7) : undefined,
      );
      // Valid device credentials skip the throttle so clients sharing one
      // address (a reverse proxy) are not locked out by another's failures.
      if (actor.kind !== "device") {
        const nowMs = Date.now();
        const failures = authFailures.get(remote);
        const windowOpen = failures !== undefined && nowMs - failures.windowStartedAt < 300_000;
        if (windowOpen && failures.count >= 10)
          throw new ServiceError(
            429,
            "auth_throttled",
            "Too many failed sign-in attempts. Try again shortly.",
          );
        if (actor.kind === "none") {
          if (windowOpen) failures.count++;
          else {
            for (const [key, entry] of authFailures)
              if (nowMs - entry.windowStartedAt >= 300_000) authFailures.delete(key);
            authFailures.set(remote, { count: 1, windowStartedAt: nowMs });
          }
          throw new ServiceError(
            401,
            "unauthorized",
            "Connect with this device's server credential.",
          );
        }
        authFailures.delete(remote);
      }
      actors.set(request, actor);
      if (actor.kind === "admin" && !path.startsWith("/v1/devices") && path !== "/v1/health")
        throw new ServiceError(
          403,
          "enrollment_required",
          "This shared token now only enrolls devices. Reconnect from Inlay to give this Mac its own credential.",
        );
    }
    if (request.headers.origin !== undefined)
      throw new ServiceError(
        403,
        "origin_rejected",
        "Browser origins are not supported by this native-client API.",
      );
  });
  app.addHook("onSend", async (_request, reply) => {
    reply.header("Cache-Control", "no-store");
  });
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ServiceError) {
      if (error.status >= 500)
        logError("request_failed", error, {
          route: request.routeOptions.url,
          method: request.method,
          status: error.status,
        });
      return reply.code(error.status).send({ code: error.code, message: error.message });
    }
    const failure = error as { code?: string; statusCode?: number };
    if (failure.code === "FST_ERR_CTP_BODY_TOO_LARGE")
      return reply
        .code(413)
        .send({ code: "body_too_large", message: "The request exceeded its size limit." });
    if (failure.statusCode && failure.statusCode >= 400 && failure.statusCode < 500) {
      return reply.code(failure.statusCode).send({
        code: `http_${failure.statusCode}`,
        message: "The request could not be accepted.",
      });
    }
    logError("request_failed", error, {
      route: request.routeOptions.url,
      method: request.method,
      status: 500,
    });
    return reply
      .code(500)
      .send({ code: "internal_error", message: "The server could not complete this request." });
  });
  app.setNotFoundHandler((_request, reply) =>
    reply.code(404).send({ code: "http_404", message: "Not found." }),
  );

  app.get("/v1/liveness", () => ({ status: "ok" }));
  app.get("/v1/health", () => service.health());
  app.post("/v1/devices/enroll", async (request, reply) => {
    const result = await service.enrollDevice(
      validateBody("EnrollDeviceRequest", request.body),
      actors.get(request) ?? { kind: "none" },
    );
    return reply
      .code(result.created ? 201 : 200)
      .send({ device: result.device, token: result.token });
  });
  app.get("/v1/devices", () => service.listDevices());
  app.post("/v1/devices/close-legacy-enrollment", () => service.closeLegacyEnrollment());
  app.delete<{ Params: IDParams }>("/v1/devices/:id", async (request, reply) => {
    await service.revokeDevice(request.params.id);
    return reply.code(204).send();
  });
  app.get("/v1/preferences", () => service.getPreferences());
  app.get("/v1/storage", () => service.storageUsage());
  app.post("/v1/storage/purge-audio", (request) =>
    service.purgeAllAudio(validateBody("PurgeAudioRequest", request.body)),
  );
  app.put("/v1/preferences", (request) =>
    service.updatePreferences(validateBody("PreferencesSnapshot", request.body)),
  );
  app.post("/v1/generations", async (request, reply) => {
    const record = await service.create(
      validateBody("CreateGenerationRequest", request.body),
      deviceIDOf(request),
    );
    return reply.code(201).send(record);
  });
  app.get<{ Querystring: { limit?: string; before?: string; source?: string } }>(
    "/v1/generations",
    (request) => {
      const limit = request.query.limit === undefined ? 50 : integer(request.query.limit);
      if (limit === undefined)
        throw new ServiceError(400, "invalid_limit", "Invalid history page size.");
      return service.history(limit, request.query.before, request.query.source);
    },
  );
  app.get<{ Params: IDParams }>("/v1/generations/:id", (request) =>
    service.get(identifier(request.params.id)),
  );
  app.post<{
    Params: IDParams & { kind: string };
    Querystring: { sequence?: string; sampleRate?: string; channels?: string };
  }>("/v1/generations/:id/audio/:kind", { bodyLimit: MAXIMUM_CHUNK_BYTES }, (request) => {
    const kind = request.params.kind;
    const sequence = integer(request.query.sequence),
      sampleRate = integer(request.query.sampleRate),
      channels = integer(request.query.channels);
    if (
      (kind !== "inference" && kind !== "original") ||
      sequence === undefined ||
      sampleRate === undefined ||
      channels === undefined
    ) {
      throw new ServiceError(
        400,
        "invalid_audio_parameters",
        "Supply audio kind, sequence, sampleRate and channels.",
      );
    }
    return service.appendAudio(
      identifier(request.params.id),
      kind,
      sequence,
      { sampleRate, channels },
      bytes(request.body),
      deviceIDOf(request),
    );
  });
  app.post<{ Params: IDParams }>("/v1/generations/:id/finish", async (request, reply) =>
    reply
      .code(202)
      .send(
        await service.finish(
          identifier(request.params.id),
          validateBody("FinishGenerationRequest", request.body),
          deviceIDOf(request),
        ),
      ),
  );
  app.post<{ Params: IDParams }>("/v1/generations/:id/cancel", (request) =>
    service.cancel(identifier(request.params.id), deviceIDOf(request)),
  );
  app.post<{ Params: IDParams }>("/v1/generations/:id/reprocess", async (request, reply) =>
    reply.code(202).send(await service.reprocess(identifier(request.params.id))),
  );
  app.post<{ Params: IDParams }>("/v1/generations/:id/delivery", (request) =>
    service.recordDelivery(
      identifier(request.params.id),
      validateBody("DeliveryReceipt", request.body),
      deviceIDOf(request),
    ),
  );
  app.delete<{ Params: IDParams }>("/v1/generations/:id/audio", async (request, reply) => {
    await service.deleteAudio(identifier(request.params.id));
    return reply.code(204).send();
  });
  app.delete<{ Params: IDParams }>("/v1/generations/:id", async (request, reply) => {
    await service.delete(identifier(request.params.id));
    return reply.code(204).send();
  });
  app.get<{ Params: IDParams }>("/v1/generations/:id/events", async (request, reply) => {
    const events = await service.events(identifier(request.params.id));
    const source = Readable.from(
      (async function* () {
        for await (const record of events) yield `${JSON.stringify(record)}\n`;
      })(),
      { objectMode: false },
    );
    reply.raw.once("close", () => {
      source.destroy();
    });
    return reply.type("application/x-ndjson").send(source);
  });
  app.get<{ Params: IDParams & { filename: string } }>(
    "/v1/generations/:id/artifacts/:filename",
    async (request, reply) => {
      const filename = request.params.filename;
      const file = await service.artifact(identifier(request.params.id), filename);
      return reply
        .type(
          filename.endsWith(".wav")
            ? "audio/wav"
            : filename.endsWith(".png")
              ? "image/png"
              : filename.endsWith(".json")
                ? "application/json"
                : "text/plain; charset=utf-8",
        )
        .send(file.createReadStream({ autoClose: true }));
    },
  );

  app.post("/v1/imports/wispr-flow/known", (request) =>
    service.knownWisprFlowIDs(validateBody("WisprFlowKnownIDsRequest", request.body)),
  );
  app.post("/v1/imports/wispr-flow", async (request, reply) =>
    reply
      .code(201)
      .send(
        await service.beginWisprFlowImport(validateBody("WisprFlowImportRequest", request.body)),
      ),
  );
  app.post<{ Params: IDParams }>("/v1/imports/wispr-flow/:id/complete", (request) =>
    service.completeWisprFlowImport(identifier(request.params.id)),
  );
  app.delete<{ Params: IDParams }>("/v1/imports/wispr-flow/:id", async (request, reply) => {
    await service.cancelWisprFlowImport(identifier(request.params.id));
    return reply.code(204).send();
  });
  app.register(async (raw) => {
    raw.removeContentTypeParser("application/json");
    raw.addContentTypeParser("application/json", { parseAs: "buffer" }, (_request, body, done) =>
      done(null, body),
    );
    raw.addContentTypeParser(
      ["audio/wav", "image/png"],
      { parseAs: "buffer" },
      (_request, body, done) => done(null, body),
    );
    raw.put<{ Params: IDParams & { filename: string } }>(
      "/v1/imports/wispr-flow/:id/artifacts/:filename",
      { bodyLimit: MAXIMUM_ARTIFACT_BYTES },
      (request) =>
        service.uploadWisprFlowArtifact(
          identifier(request.params.id),
          artifactName(request.params.filename),
          bytes(request.body),
        ),
    );
    raw.put(
      "/v1/imports/wispr-flow/dictionary",
      { bodyLimit: MAXIMUM_DICTIONARY_BYTES },
      (request) => service.archiveWisprFlowDictionary(bytes(request.body)),
    );
  });
  return app;
}
