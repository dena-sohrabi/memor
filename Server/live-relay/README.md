# Memor Live relay

A tiny Cloudflare Worker that connects Memor's live calls with the study pal to OpenAI's GPT-Live, so the OpenAI key lives on the server instead of the iPad.

The iPad opens a WebSocket to `https://<your-worker>/live` with a token; the relay checks it, connects to `wss://api.openai.com/v1/live/sessions` with your OpenAI key, and passes every message both ways unchanged. It doesn't read, store or log what's said. It only checks that a call starts a `gpt-live` session, and ends calls longer than `MAX_CALL_MINUTES` (20 by default).

Cloudflare runs it in the data center nearest you, which keeps the extra delay small. Try the free plan first; it limits how much CPU time a Worker gets, and a call relays many small audio messages a second. If calls drop after a while, the $5 Workers Paid plan lifts that limit.

## Set up

```bash
cd Server/live-relay
npm install
npx wrangler login
npx wrangler secret put OPENAI_API_KEY      # the key calls are billed to
npx wrangler secret put MEMOR_LIVE_TOKEN    # paste a long random string, e.g. from: openssl rand -hex 32
npx wrangler deploy
```

`wrangler deploy` prints the Worker's address, like `https://memor-live-relay.<you>.workers.dev`. In Memor, open Settings › Live Calls and enter that address and the same token.

Check it's up: `https://memor-live-relay.<you>.workers.dev/health` says `ok`.

## Cost

GPT-Live is $0.05 a minute while a call is open (billed by the second), on the OpenAI key above. The study pal's mind is billed as usual, to the keys in Memor's Settings. The Worker itself costs nothing on the free plan, or $5 a month on Workers Paid.
