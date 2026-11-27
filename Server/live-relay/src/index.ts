/**
 * Memor Live relay: a Cloudflare Worker that connects the iPad to OpenAI's
 * GPT-Live, so the OpenAI key stays on the server.
 *
 * The iPad opens a WebSocket to `/live` with `Authorization: Bearer <token>`.
 * The relay checks the token, opens a WebSocket to OpenAI's Live endpoint
 * with the OpenAI key, and passes every message both ways unchanged. It
 * never reads or logs what's said; it only checks that the first message
 * starts a GPT-Live session, and ends calls that run too long.
 *
 * Secrets (set with `npx wrangler secret put`):
 * - OPENAI_API_KEY: the OpenAI key calls are billed to.
 * - MEMOR_LIVE_TOKEN: a long random string; the same one goes in Memor's
 *   Settings › Live Calls.
 */

export interface Env {
  OPENAI_API_KEY: string;
  MEMOR_LIVE_TOKEN: string;
  /** Calls longer than this are ended (default 20). */
  MAX_CALL_MINUTES?: string;
}

const OPENAI_LIVE_URL = "https://api.openai.com/v1/live/sessions";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return new Response("ok");
    }
    if (url.pathname !== "/live") {
      return new Response("Not found", { status: 404 });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket", { status: 426 });
    }
    if (!env.OPENAI_API_KEY || !env.MEMOR_LIVE_TOKEN) {
      return new Response("The relay isn't set up: add OPENAI_API_KEY and MEMOR_LIVE_TOKEN.", { status: 500 });
    }
    const auth = request.headers.get("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
    if (!(await sameSecret(token, env.MEMOR_LIVE_TOKEN))) {
      return new Response("Unauthorized", { status: 401 });
    }

    const pair = new WebSocketPair();
    const [client, iPad] = Object.values(pair);
    iPad.accept();
    // The iPad may hang up while OpenAI is still connecting.
    let iPadClosed = false;
    iPad.addEventListener("close", () => {
      iPadClosed = true;
    });

    let upstream: WebSocket;
    try {
      const response = await fetch(OPENAI_LIVE_URL, {
        headers: {
          Upgrade: "websocket",
          Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        },
      });
      if (!response.webSocket) {
        const message = await openAIMessage(response);
        fail(iPad, `OpenAI didn't start the call (${response.status}): ${message}`);
        return new Response(null, { status: 101, webSocket: client });
      }
      upstream = response.webSocket;
      upstream.accept();
    } catch {
      fail(iPad, "The relay couldn't reach OpenAI.");
      return new Response(null, { status: 101, webSocket: client });
    }
    if (iPadClosed) {
      close(upstream, 1000, "The iPad hung up.");
      return new Response(null, { status: 101, webSocket: client });
    }

    relay(iPad, upstream, maxCallMs(env));
    return new Response(null, { status: 101, webSocket: client });
  },
};

/** Passes messages both ways until either side closes. */
function relay(iPad: WebSocket, upstream: WebSocket, maxMs: number) {
  const startedAt = Date.now();
  let checkedStart = false;
  let timedOut = false;

  const closeBoth = (code: number, reason: string) => {
    close(iPad, code, reason);
    close(upstream, code, reason);
  };

  iPad.addEventListener("message", (event) => {
    if (timedOut) return;
    if (Date.now() - startedAt > maxMs) {
      // Tells the iPad why, then ends the call politely, so OpenAI closes
      // the session (and bills it to the second); both sides close once it has.
      timedOut = true;
      const minutes = Math.round(maxMs / 60_000);
      send(iPad, JSON.stringify({
        type: "error",
        error: { code: "relay_time_limit", message: `The call reached its ${minutes}-minute limit. Tap me to call again.` },
      }));
      send(upstream, JSON.stringify({ type: "session.close" }));
      setTimeout(() => closeBoth(1000, "Time limit"), 3_000);
      return;
    }
    if (!checkedStart) {
      checkedStart = true;
      if (!startsLiveSession(event.data)) {
        fail(iPad, "The first message must be session.start for a gpt-live model.");
        close(upstream, 1000, "Rejected by the relay.");
        return;
      }
    }
    send(upstream, event.data);
  });
  upstream.addEventListener("message", (event) => send(iPad, event.data));

  iPad.addEventListener("close", (event) => close(upstream, event.code, event.reason));
  upstream.addEventListener("close", (event) => close(iPad, event.code, event.reason));
  iPad.addEventListener("error", () => closeBoth(1011, "The iPad's connection failed."));
  upstream.addEventListener("error", () => closeBoth(1011, "OpenAI's connection failed."));
}

/** The call must start a GPT-Live session, so the key can't be used for anything else. */
function startsLiveSession(data: string | ArrayBuffer): boolean {
  if (typeof data !== "string") return false;
  try {
    const event = JSON.parse(data);
    const model = event?.session?.model;
    return event?.type === "session.start" && typeof model === "string" && model.startsWith("gpt-live");
  } catch {
    return false;
  }
}

/** Tells the iPad what went wrong, in the shape of a Live `error` event, and closes. */
function fail(socket: WebSocket, message: string) {
  send(socket, JSON.stringify({ type: "error", error: { code: "relay_upstream", message } }));
  close(socket, 1011, "Relay error");
}

async function openAIMessage(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as { error?: { message?: string } };
    return body.error?.message ?? response.statusText;
  } catch {
    return response.statusText;
  }
}

function send(socket: WebSocket, data: string | ArrayBuffer) {
  try {
    socket.send(data);
  } catch {
    // Already closed.
  }
}

function close(socket: WebSocket, code: number, reason: string) {
  // Only these codes may be sent (1004, 1005, 1006 and 1015 are reserved),
  // and a reason must fit in 123 bytes of UTF-8.
  const sendable = (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) || (code >= 3000 && code <= 4999);
  try {
    socket.close(sendable ? code : 1000, shortReason(reason));
  } catch {
    // Already closed.
  }
}

function shortReason(reason: string): string {
  let short = reason;
  while (new TextEncoder().encode(short).length > 120) {
    short = short.slice(0, -1);
  }
  return short;
}

function maxCallMs(env: Env): number {
  const minutes = Number(env.MAX_CALL_MINUTES ?? "20");
  return (Number.isFinite(minutes) && minutes > 0 ? minutes : 20) * 60_000;
}

/** Compares the token in constant time (both hashed, so lengths match). */
async function sameSecret(given: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(given)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  return given.length > 0 && crypto.subtle.timingSafeEqual(a, b);
}
