import { timingSafeEqual } from "node:crypto";
import { Readable } from "node:stream";
import Fastify from "fastify";
import {
  MAXIMUM_ARTIFACT_BYTES,
  MAXIMUM_CHUNK_BYTES,
  MAXIMUM_DICTIONARY_BYTES,
  type WisprFlowArtifactName,
} from "./api.ts";
import { ServiceError } from "./errors.ts";
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
export function isLoopbackAuthority(value: string | undefined) {
  if (!value) return false;
  const match = /^(localhost|127\.0\.0\.1|\[::1\])(?::(\d+))?$/i.exec(value);
  return (
    !!match && (match[2] === undefined || (Number(match[2]) >= 1 && Number(match[2]) <= 65535))
  );
}
const equal = (left: string, right: string) => {
  const a = Buffer.from(left),
    b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
};
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
export function createHTTPServer(service: GenerationService, token?: string) {
  const app = Fastify({ logger: false, bodyLimit: 262_144 });
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
    if (token === undefined && !isLoopbackAuthority(request.headers.host)) {
      throw new ServiceError(
        403,
        "host_rejected",
        "Tokenless connections must address localhost directly.",
      );
    }
    if (
      request.url.split("?")[0] !== "/v1/health" &&
      token !== undefined &&
      !equal(request.headers.authorization ?? "", `Bearer ${token}`)
    ) {
      throw new ServiceError(401, "unauthorized", "Connect with the server's access token.");
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
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof ServiceError)
      return reply.code(error.status).send({ code: error.code, message: error.message });
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
    return reply
      .code(500)
      .send({ code: "internal_error", message: "The server could not complete this request." });
  });
  app.setNotFoundHandler((_request, reply) =>
    reply.code(404).send({ code: "http_404", message: "Not found." }),
  );

  app.get("/v1/health", () => service.health());
  app.get("/v1/preferences", () => service.getPreferences());
  app.put("/v1/preferences", (request) =>
    service.updatePreferences(validateBody("PreferencesSnapshot", request.body)),
  );
  app.post("/v1/generations", async (request, reply) => {
    const record = await service.create(validateBody("CreateGenerationRequest", request.body));
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
    );
  });
  app.post<{ Params: IDParams }>("/v1/generations/:id/finish", async (request, reply) =>
    reply
      .code(202)
      .send(
        await service.finish(
          identifier(request.params.id),
          validateBody("FinishGenerationRequest", request.body),
        ),
      ),
  );
  app.post<{ Params: IDParams }>("/v1/generations/:id/cancel", (request) =>
    service.cancel(identifier(request.params.id)),
  );
  app.post<{ Params: IDParams }>("/v1/generations/:id/retry", async (request, reply) =>
    reply.code(202).send(await service.retry(identifier(request.params.id))),
  );
  app.post<{ Params: IDParams }>("/v1/generations/:id/delivery", (request) =>
    service.recordDelivery(
      identifier(request.params.id),
      validateBody("DeliveryReceipt", request.body),
    ),
  );
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
