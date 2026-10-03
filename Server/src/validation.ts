import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { parse } from "yaml";
import specification from "../api/openapi.yaml" with { type: "text" };
import type { components } from "./generated/api.ts";
import { ServiceError } from "./errors.ts";

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const document: unknown = parse(specification);
if (
  !isObject(document) ||
  !isObject(document.components) ||
  !isObject(document.components.schemas)
) {
  throw new Error("The API contract has no component schemas.");
}
const ajv = new Ajv2020({ strict: false, allErrors: true, validateFormats: true });
addFormats(ajv);
ajv.addSchema({ $id: "inlay-api", components: { schemas: document.components.schemas } });

export function validateBody<Name extends keyof components["schemas"]>(name: Name, body: unknown) {
  const validator = ajv.getSchema<components["schemas"][Name]>(
    `inlay-api#/components/schemas/${name}`,
  );
  if (!validator) throw new Error(`The API contract has no schema named ${name}.`);
  if (!validator(body))
    throw new ServiceError(400, "invalid_json", `The request did not contain valid ${name} JSON.`);
  return body as components["schemas"][Name];
}

export const contract = document;
