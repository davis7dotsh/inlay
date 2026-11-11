import { randomBytes, timingSafeEqual } from "node:crypto";
import { join } from "node:path";
import type { DeviceIdentity, DeviceList, DeviceSummary } from "./api.ts";
import { ServiceError } from "./errors.ts";
import { atomicPrivateWrite, readRegularFile, sha256 } from "./storage.ts";

export type RequestActor =
  { kind: "admin" } | { kind: "device"; id: string; name: string } | { kind: "none" };

interface DeviceRecord {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: string;
  lastSeenAt?: string;
  revokedAt?: string;
}

interface DeviceStoreFile {
  version: 1;
  legacyEnrollmentClosed: boolean;
  devices: DeviceRecord[];
}

const MAX_DEVICES = 64;
const MAX_STORE_BYTES = 262_144;
const TOUCH_INTERVAL_MS = 3_600_000;

export function timingSafeStringEqual(expected: string, provided: string) {
  const expectedBytes = new TextEncoder().encode(expected);
  const providedBytes = new TextEncoder().encode(provided);
  return (
    expectedBytes.length === providedBytes.length && timingSafeEqual(expectedBytes, providedBytes)
  );
}

// Clients decode with whole-second ISO 8601; older stores may hold milliseconds.
const wholeSeconds = (timestamp: string) => timestamp.replace(/\.\d+Z$/, "Z");

const summary = (device: DeviceRecord): DeviceSummary => {
  const result: DeviceSummary = {
    id: device.id,
    name: device.name,
    createdAt: wholeSeconds(device.createdAt),
  };
  if (device.lastSeenAt) result.lastSeenAt = wholeSeconds(device.lastSeenAt);
  if (device.revokedAt) result.revokedAt = wholeSeconds(device.revokedAt);
  return result;
};

const now = () => wholeSeconds(new Date().toISOString());

function isValidStore(value: unknown): value is DeviceStoreFile {
  if (typeof value !== "object" || value === null) return false;
  const file = value as Partial<DeviceStoreFile>;
  return (
    file.version === 1 &&
    typeof file.legacyEnrollmentClosed === "boolean" &&
    Array.isArray(file.devices) &&
    file.devices.every(
      (device) =>
        typeof device === "object" &&
        device !== null &&
        typeof device.id === "string" &&
        typeof device.name === "string" &&
        typeof device.tokenHash === "string" &&
        typeof device.createdAt === "string",
    )
  );
}

/// Per-device credentials. Only token hashes are stored. Writes chain in
/// call order and each serializes the state current when it runs, so a late
/// write never restores an older snapshot.
export class DeviceStore {
  private file: DeviceStoreFile = { version: 1, legacyEnrollmentClosed: false, devices: [] };
  private readonly path: string;
  private writes = Promise.resolve();

  private constructor(dataDirectory: string) {
    this.path = join(dataDirectory, "devices.json");
  }

  static async open(dataDirectory: string) {
    const store = new DeviceStore(dataDirectory);
    let data: Uint8Array;
    try {
      data = await readRegularFile(store.path, MAX_STORE_BYTES);
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "ENOENT") return store;
      throw new Error(`Device credential store at ${store.path} is unreadable.`, { cause: error });
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data));
    } catch (error) {
      throw new Error(`Device credential store at ${store.path} is invalid JSON.`, {
        cause: error,
      });
    }
    if (!isValidStore(parsed))
      throw new Error(`Device credential store at ${store.path} has an invalid shape.`);
    store.file = parsed;
    return store;
  }

  get legacyEnrollmentClosed() {
    return this.file.legacyEnrollmentClosed;
  }

  find(id: string) {
    return this.file.devices.find((device) => device.id === id);
  }

  authenticateDevice(token: string): DeviceRecord | undefined {
    const hash = sha256(token);
    return this.file.devices.find(
      (device) => !device.revokedAt && timingSafeStringEqual(device.tokenHash, hash),
    );
  }

  list(): DeviceList {
    return {
      devices: this.file.devices.map(summary),
      legacyEnrollmentClosed: this.file.legacyEnrollmentClosed,
    };
  }

  async enroll(identity: DeviceIdentity) {
    const existing = this.find(identity.id);
    if (existing?.revokedAt)
      throw new ServiceError(403, "device_revoked", "This device was revoked on this server.");
    if (!existing && this.file.devices.length >= MAX_DEVICES)
      throw new ServiceError(413, "device_limit", "This server already has the maximum devices.");
    const token = randomBytes(32).toString("hex");
    if (existing) {
      existing.name = identity.name;
      existing.tokenHash = sha256(token);
      existing.lastSeenAt = now();
      await this.persist();
      return { device: summary(existing), token, created: false };
    }
    const record: DeviceRecord = {
      id: identity.id,
      name: identity.name,
      tokenHash: sha256(token),
      createdAt: now(),
      lastSeenAt: now(),
    };
    this.file.devices.push(record);
    await this.persist();
    return { device: summary(record), token, created: true };
  }

  async revoke(id: string) {
    const device = this.find(id);
    if (!device) throw new ServiceError(404, "not_found", "Device not found.");
    device.revokedAt = now();
    device.tokenHash = sha256(randomBytes(32));
    await this.persist();
  }

  async closeLegacyEnrollment() {
    if (!this.file.legacyEnrollmentClosed) {
      this.file.legacyEnrollmentClosed = true;
      await this.persist();
    }
    return this.list();
  }

  async rename(id: string, name: string) {
    const device = this.find(id);
    if (!device || device.name === name) return;
    device.name = name;
    await this.persist();
  }

  async touch(id: string) {
    const device = this.find(id);
    if (!device) return;
    const last = device.lastSeenAt ? Date.parse(device.lastSeenAt) : 0;
    if (Date.now() - last < TOUCH_INTERVAL_MS) return;
    device.lastSeenAt = now();
    await this.persist();
  }

  private persist() {
    const write = this.writes.then(() => atomicPrivateWrite(this.path, JSON.stringify(this.file)));
    this.writes = write.catch(() => {});
    return write;
  }
}
