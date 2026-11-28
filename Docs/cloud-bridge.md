# Accounts and the cloud (v2, 2026-11-28)

One **account** = one library on every device. The account lives in a Cloudflare **Durable
Object** (`Account`, one per account). It is the single source of truth: which devices
belong, which books the account has, who holds what, who narrates, what travels. Devices
report what they have and do what the account tells them. Cloudflare never sees a word of a
book, a title, a place or a device name: those are sealed on the devices.

## The rules

- **The EPUB is the book.** A book's id is the SHA-256 prefix of its EPUB file. Every device
  keeps the original EPUB (`Library/Originals/<id>.epub`) and builds the readable text from it
  itself, in the background (`BookImporter`). Only two things ever travel: the **EPUB** and
  the **audio** (per chapter, with its timing). Audio is matched to the text by a per-chapter
  text fingerprint, so audio from another device is installed only on identical text.
- **Adding a book anywhere offers it to every device.** The device that added it registers it
  with the account and uploads the EPUB; every other device fetches it and builds the text.
- **The account decides who narrates.** For each book not yet narrated, it picks the online
  device that finishes first (`(queued + sentences) / speed`, Macs before iPhones; an iPhone
  only when no Mac is online). The choice sticks until that device has been away 15 minutes,
  or a Mac comes online while an iPhone narrates. Narrated chapters go up as they finish (at
  most every 10 minutes, and at the end) and every device takes them.
- **Deleting a book anywhere deletes it everywhere** (a tombstone in the account; adding the
  same EPUB again later brings it back). An iPhone's "Remove download" is local only.
- **Joining**: a device of the account shows a **one-time code** (`XXXX-XXXX-XXXX`, 15 minutes,
  works once) and its QR code; the new device types or scans it. Creating an account needs the
  Worker's server key (only the owner has it). There is no other way in: no link codes, no
  invites, no "help narrate only".

## Keys (made and kept on the devices)

The account's random 32-byte **library key** never reaches Cloudflare. HKDF-SHA256 (salt
`habla-bridge-v1`) derives: `enc` (AES-GCM for everything sealed), `name` (HMAC for opaque
names), `token` (the bearer token; the Worker stores only its SHA-256 = the account id),
`lan` / `lan-token` (Wi-Fi proof, see `Sync/`).

**One-time code.** 60 random bits, shown in Crockford base32. Both sides compute
`s = PBKDF2-SHA256(code, "habla-join-v1", 200 000)`, then `id = HKDF(s, "id")` and
`wrap = HKDF(s, "wrap")`. The inviting device stores `{id, AES-GCM(wrap, {libraryKey, name})}`
on the Worker; the joining device sends `id` and gets the sealed blob back (then it's gone).
The Worker only ever has `id` and ciphertext.

Opaque names: a book is `HMAC(name, "book/<id>")` to the account; transit chunks are
`HMAC(name, "epub/<id>/<sha256>#n")` or `HMAC(name, "blob/<id>/<sha256>#n")` (content-named,
so unchanged audio is never sent twice and a stopped download resumes). Sealed bodies are
`0x01 ‖ nonce ‖ ciphertext ‖ tag` with the logical name as AAD, padded (4 KiB for documents,
64 KiB for chunks).

## Worker API (`Cloudflare/habla-bridge/worker.js`)

`Authorization: Bearer <token>` and `X-Habla-Device: <device id>` (16–40 hex) on every
authenticated call.

| Call | What |
|---|---|
| `POST /v2/accounts` | Create: `X-Habla-Enroll: <server key>`, `{tokenHash}`. `201` / `200` if it exists. |
| `POST /v2/codes` | `{id, wrapped}` → a one-time code's sealed key, 15 minutes, ≤ 3 open per account. |
| `POST /v2/join` | No auth. `{id}` → `{wrapped}` once; `404` if used, expired or wrong. |
| `POST /v2/sync` | The device's report → the account's view and this device's tasks (below). |
| `POST /v2/devices/remove` | `{id}`: forget a device (wiped or replaced). |
| `GET /v2/listen` | WebSocket (hibernating): the account says `changed` when something moved. |
| `GET/PUT/DELETE /v1/transit/{name}`, `GET /v1/transit`, `GET /v1/usage` | Chunks in transit and the free-tier usage (unchanged). |

### `POST /v2/sync`

Report (everything sealed is base64 of a sealed blob):

```jsonc
{
  "kind": "mac" | "phone",
  "info": "<sealed {name, endpoints}>",
  "narrator": {"sps": 1.3, "queued": 2400} | null,     // null: can't narrate now
  "books": [{"key": "<40 hex>", "epub": true, "ready": 12, "left": 340}],   // what it holds: chapters narrated, sentences left
  "added": [{"key", "meta": "<sealed {id,title,author,language}>", "sentences", "narratable", "at"}],
  "deleted": [{"key", "at"}],
  "uploaded": [{"key", "kind": "epub"|"audio", "names": ["<40 hex>"...], "pack": "<sealed>", "ready": 12}],
  "requested": ["key"], "declined": ["key"],
  "places": "<sealed {positions, markers}>" | null,      // only when it changed
  "seen": {"<device>": <placesVersion>},                 // places it already has
  "settings": {"voice": {"data", "at"}, "name": {"data", "at"}}   // only what changed here
}
```

Answer:

```jsonc
{
  "devices": [{"id", "kind", "info", "online", "lastSeen", "narrator"}],
  "books": [{"key", "meta", "sentences", "narrator": "<device>"|null, "deletedAt"?,
             "epub": {"pack", "names"}|null, "audio": {"pack", "names", "ready"}|null,
             "holders": {"<device>": {"epub", "ready", "left"}}}],
  "places": [{"device", "version", "data"}],             // only newer than `seen`
  "settings": {"voice": {"data", "at"}, "name": {"data", "at"}},
  "tasks": {"upload": [{"key", "kind"}], "narrate": ["key"]}
}
```

**Transit.** An EPUB goes up when a device lacks it; audio goes up when a device has fewer
narrated chapters than the best copy. One device is told to upload (the best holder, online
first); the chunks go through `/v1/transit` (storage and operation caps apply), then the device
reports them in `uploaded`. The account deletes the chunks itself once every device has what
they carry (devices seen in the last 30 days, minus those that declined the book), or the book
is deleted. At most **3 books' audio** wait in the cloud for the whole account (the oldest is
dropped and goes again only if a device asks for it with Download); EPUBs are small and
always go (at most 20 at once).

**Online** = an open `/v2/listen` connection, or a sync in the last 2 minutes. Macs keep the
connection open; the iPhone while Habla is on screen.

**Migration from v1.** The account id is the v1 space id, so devices already in a v1 account
are in the v2 account with no step: their first sync reports their books and their old
deletions. v1's per-device state documents, link codes, invites and helper Macs are gone.

## Never reaching the paid tier

The free allowances are per Cloudflare account and shared with Portfolio. The Worker refuses
work before doing it once a budget is used (`429` ops/requests, `507` storage, JSON
`{error, cap}`); the apps pause the cloud until the period rolls over and keep Wi-Fi sync.

| Allowance (free) | Habla's cap |
|---|---|
| R2 storage 10 GB | `STORAGE_CAP_BYTES` 8 GiB minus Portfolio's bucket |
| R2 Class A 1 M / month | `CLASS_A_CAP` 400 000 |
| R2 Class B 10 M / month | `CLASS_B_CAP` 4 000 000 |
| Workers 100 k / day | `REQUESTS_CAP_DAY` 20 000 |
| Durable Objects 100 k requests / day, 5 GB | one request per sync; hibernating sockets are free while idle |

Expected use (1 iPhone + 2 Macs): a few dozen syncs a day, a few thousand R2 operations a
month, storage only while books are in transit. Daily cron: measure Portfolio, delete transit
older than 14 days, reconcile the ledger with the bucket, drop expired codes.

## Deploying

From `Cloudflare/habla-bridge/` (wrangler logged in to the Portfolio Cloudflare account):

```sh
npx wrangler d1 execute habla-bridge-ledger --remote --file schema.sql   # adds the codes table
npx wrangler deploy                                                      # adds the Account class
```

The apps read the Worker's address from `HablaBridgeURL` in their Info.plist, filled at build
time from `HABLA_BRIDGE_URL` (a GitHub Actions secret for releases); it is never committed.

## The Xteink (2026-11-28)

The Xteink can't hold the account key, so it talks to the account in the clear, by the owner's
choice: its **positions** (KOReader sync) and a **catalog** of the account's EPUBs (OPDS). This
works with no Mac on. It is the one exception to "Cloudflare never sees anything".

- **Login**: a Mac in the account sets the Xteink up once over Wi-Fi (File Transfer open): a
  random username and password, registered with `POST /v2/ereader` (the Worker stores only the
  password's MD5, which KOReader sync sends). One per account; a new one replaces the old.
- **Positions**: `/kosync/users/auth`, `PUT /kosync/syncs/progress`, `GET /kosync/syncs/progress/{doc}`
  (x-auth-user + x-auth-key, or HTTP Basic). The account keeps the newest record per document
  (document = KOReader partial MD5 of the EPUB; progress = an XPointer; percentage; time). Devices
  get the records in `/v2/sync` and turn them into (chapter, sentence) with their own copy of the
  text; they write their own newest place back in the same form (`ereader` in the report), so the
  Xteink opens where the iPhone left off. CrossPoint 2.0 syncs only from its reader menu.
- **Catalog**: `GET /opds` (HTTP Basic) lists the account's books by **title and subtitle only**
  (`BookTitle.clean`: no Project Gutenberg, university, press, shop or series notes); `GET
  /opds/books/{key}.epub` serves the EPUB unchanged (so its digest matches for position sync).
  The account asks a device holding the EPUB to upload it (`PUT /v2/shelf/{key}`, plain); a
  deleted book leaves the catalog and the cloud at once. The Xteink downloads into `/Habla`,
  named by title. Positions are sent without titles (`koSendMetadata` off).
- **What Cloudflare can read**: those EPUBs (their content and their own metadata inside), their
  titles, and the Xteink's reading positions. Nothing of the other devices.
- Deploy adds the `ereaders` table: run `schema.sql` again, then `wrangler deploy`.
