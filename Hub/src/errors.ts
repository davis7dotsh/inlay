/// An error that maps to one HTTP reply. The message goes to the client, never a secret or a text.
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}
