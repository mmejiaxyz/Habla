# habla-bridge

Cloudflare Worker + R2 bucket + D1 ledger: an encrypted mailbox between your Habla devices.
It never sees a key, a title or a word; it checks a token hash, keeps the account inside the
free tier, and moves sealed bytes. Design and caps: `Docs/cloud-bridge.md`.

Bucket `habla-bridge`, D1 `habla-bridge-ledger`, daily cron 03:17 UTC. The live address and
database id stay out of the repo: `wrangler.toml` is local only (start from `wrangler.example.toml`).

## Provision from scratch
```sh
cp wrangler.example.toml wrangler.toml
wrangler r2 bucket create habla-bridge
wrangler d1 create habla-bridge-ledger           # put the id in wrangler.toml
wrangler d1 execute habla-bridge-ledger --remote --file schema.sql
openssl rand -base64 33 | wrangler secret put ENROLL_SECRET
wrangler deploy
```
Then on the Mac, `~/Library/Application Support/Habla Studio/Security/bridge.json` (mode 600):
`{"url":"https://…workers.dev","enrollSecret":"…"}`. Habla makes the library key, enrolls
once and removes the secret.

## Test
`node --test test/` (Node 22+, no installs).
