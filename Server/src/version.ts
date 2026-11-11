// Build-time stamped by scripts/build-server.sh (define-injected for the
// compiled binary; the environment variable wins for source runs).
export const SERVER_VERSION = process.env.INLAY_SERVER_VERSION ?? "0.0.0-dev";
