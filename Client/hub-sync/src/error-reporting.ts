// Grouped errors in GlitchTip (errors.lascari.dev), through the Sentry SDK @sentry/bun. GlitchTip on services-01 takes
// the events. No data goes to Sentry.
//
// The SDK is optional: a missing DSN, a bad DSN, a failed import or a failed init logs 1 line and the process runs with
// no SDK. reportError and stopErrorReporting are then no-ops.
//
// Privacy: no local variable values (dataCollection.stackFrameVariables, because BunOptions has no
// includeLocalVariables), no user, cookie, header, query or body data, no breadcrumbs (they would copy log lines), no
// sessions, no client reports and no machine name. An exception message keeps its first line only, at most
// MESSAGE_CAP characters, and a home folder in a message or a path becomes "~". No log line holds the DSN, and a DSN
// must match the SDK's grammar, so the SDK never prints it. The caller exits with process.exit after
// stopErrorReporting, so a request that GlitchTip holds open cannot keep the process alive past the 2 s cap.
import { readFileSync } from "node:fs";

type Sdk = typeof import("@sentry/bun");
type Options = NonNullable<Parameters<Sdk["init"]>[0]>;

export interface ErrorReportingOptions {
  /** The GlitchTip project, sent as the tag source. */
  readonly source: string;
  readonly log: (line: string) => void;
  /** Returns the DSN text. It throws when there is none, and its message says why. */
  readonly readDsn: () => string;
  /** Loads the SDK. A test passes a stub. */
  readonly load?: () => Promise<Sdk>;
  /** Replaces the HTTP transport. A test passes a stub. */
  readonly transport?: Options["transport"];
}

export const FLUSH_CAP_MS = 2000;
export const MESSAGE_CAP = 300;

let sdk: Sdk | null = null;

const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);

/** The DSN in a file, such as a mode-600 DSN file. */
export const dsnFromFile = (file: string) => () => {
  try {
    return readFileSync(file, "utf8");
  } catch (e) {
    throw new Error(
      `no DSN file at ${file} (${(e as NodeJS.ErrnoException).code ?? "unreadable"})`,
    );
  }
};

/** The DSN in an env var, else in the same name in a dotenv file such as ~/workspace/.env (envsync writes it). */
export const dsnFromEnv =
  (name: string, envFile: string, env: Record<string, string | undefined> = process.env) =>
  () => {
    const value = env[name]?.trim();
    if (value) return value;
    let text = "";
    try {
      text = readFileSync(envFile, "utf8");
    } catch {
      throw new Error(`no ${name} in the environment, and no ${envFile}`);
    }
    for (const line of text.split("\n").reverse()) {
      const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
      if (m?.[1] === name && m[2]!.trim() !== "")
        return m[2]!.trim().replace(/^(["'])(.*)\1$/, "$2");
    }
    throw new Error(`no ${name} in the environment or in ${envFile}`);
  };

// The DSN grammar of @sentry/core 11.15.0 (utils/dsn.js), with no secret and a numeric project id. A DSN that this
// accepts never makes the SDK print "Invalid Sentry Dsn: <the DSN>".
const DSN = /^(https?):\/\/(\w+)@(\[[:.%\w]+\]|[\w.-]+)(?::\d+)?\/\d+$/;

/** A DSN is https://<key>@<host>/<project id>. http is for loopback only. */
function parseDsn(text: string): string | null {
  const dsn = text.trim();
  const m = DSN.exec(dsn);
  if (m === null) return null;
  return m[1] === "https" || LOOPBACK.has(m[3]!) ? dsn : null;
}

const HOME_PATH = /\/(?:Users|home)\/[^/\s"'`]+/g;
const scrub = (text: string) => text.replace(HOME_PATH, "~");

/** The options that keep private data in the process. */
function sdkOptions(s: Sdk, dsn: string, transport?: Options["transport"]): Options {
  return {
    dsn,
    // Only these integrations: no console, http, request data, session, uncaught-error or module integrations.
    defaultIntegrations: false,
    integrations: [s.linkedErrorsIntegration(), s.dedupeIntegration()],
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: false,
      httpBodies: [],
      urlQueryParams: false,
      stackFrameVariables: false,
      databaseQueryData: false,
      queues: false,
      genAI: { inputs: false, outputs: false },
      mcp: { inputs: false, outputs: false },
      graphQL: { document: false, variables: false },
      frameContextLines: 0,
    },
    sendClientReports: false,
    maxBreadcrumbs: 0,
    enableRuntimeChannelInjection: false,
    shutdownTimeout: FLUSH_CAP_MS,
    beforeSend(event) {
      delete event.request;
      delete event.user;
      delete event.breadcrumbs;
      delete event.server_name; // the machine name, which can hold a person's name
      for (const value of event.exception?.values ?? []) {
        if (value.value !== undefined)
          value.value = scrub(value.value.split("\n", 1)[0]!).slice(0, MESSAGE_CAP);
        for (const frame of value.stacktrace?.frames ?? []) {
          delete frame.vars;
          if (frame.filename !== undefined) frame.filename = scrub(frame.filename);
          if (frame.abs_path !== undefined) frame.abs_path = scrub(frame.abs_path);
          if (frame.module !== undefined) frame.module = scrub(frame.module);
        }
      }
      return event;
    },
    ...(transport ? { transport } : {}),
  };
}

/** Start the SDK for one source. Returns true when it is on. It never throws. */
export async function startErrorReporting(o: ErrorReportingOptions): Promise<boolean> {
  let text: string;
  try {
    text = o.readDsn();
  } catch (e) {
    o.log(`errors: off, ${e instanceof Error ? e.message : String(e)}`);
    return false;
  }
  const dsn = parseDsn(text);
  if (dsn === null) {
    o.log("errors: off, the DSN is not valid");
    return false;
  }
  try {
    const s = await (o.load ?? (() => import("@sentry/bun")))();
    const client = s.init(sdkOptions(s, dsn, o.transport));
    if (client?.getDsn() === undefined) throw new Error("the SDK took no DSN");
    s.setTag("source", o.source);
    sdk = s;
    o.log(`errors: on for ${o.source}`);
    return true;
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    o.log(
      `errors: off, the SDK did not start: ${message.split(dsn).join("<dsn>").slice(0, MESSAGE_CAP)}`,
    );
    return false;
  }
}

/** Send an error that a handler caught and logged. `handler` names that handler, as a tag. It never throws. */
export function reportError(error: unknown, handler: string): void {
  if (sdk === null) return;
  try {
    sdk.captureException(error, { tags: { handler } });
  } catch {
    // reporting must never break the handler
  }
}

/** Flush and stop the SDK, waiting FLUSH_CAP_MS at most. Returns true when every event was sent. It never throws. */
export async function stopErrorReporting(): Promise<boolean> {
  const s = sdk;
  sdk = null;
  if (s === null) return false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const sent = await Promise.race([
    s.close(FLUSH_CAP_MS).catch(() => false),
    new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), FLUSH_CAP_MS);
    }),
  ]);
  clearTimeout(timer);
  return sent;
}
