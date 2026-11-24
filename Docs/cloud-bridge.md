# Cloud bridge (sync away from home)

On the same Wi-Fi, the iPhone and the Mac talk directly (Bonjour + pinned TLS, see `Sync/`).
When they are apart, they meet through a **Cloudflare bridge**: one Worker in front of one
R2 bucket. Cloudflare only ever stores **ciphertext under random-looking names**. It never
holds a key, never sees a title, a position or a word of a book.

- **Positions and markers** (bookmarks + underlines) are kept on the bridge permanently, as
  one small encrypted document per device.
- **Books** only pass through: the Mac uploads every newly finished book (encrypted, in
  chunks), each paired phone downloads it, and the Mac deletes it once every phone has it
  (or after 14 days). EPUBs imported on the phone travel to the Mac the same way.
- LAN sync stays the fast path. The bridge is the fallback and runs alongside it.

## Pieces

| Piece | Where |
|---|---|
| Worker + D1 ledger | `Cloudflare/habla-bridge/` (`worker.js`, `schema.sql`, `wrangler.toml`) |
| R2 bucket | `habla-bridge` (new, only the Worker binding can reach it: no S3 API keys exist) |
| D1 database | `habla-bridge-ledger` (object ledger + usage counters) |
| Swift client | `Packages/HablaCore/Sources/HablaCore/Bridge/` |

## Never reaching the paid tier

The Cloudflare free allowances are per **account** and are shared with the Portfolio
project (`portfolio-media` bucket, `portfolio-media` Worker). The Worker refuses work
*before* doing it once a budget is used up, so the account can't cross into paid usage
because of Habla. Budgets (env vars in `wrangler.toml`):

| Allowance (free, per account) | Habla's hard cap | Notes |
|---|---|---|
| R2 storage 10 GB-month | `STORAGE_CAP_BYTES` = 8 GiB **minus Portfolio's bucket size** | the daily cron measures `portfolio-media` |
| R2 Class A 1 M / month | `CLASS_A_CAP` = 400 000 / month | writes and lists made by the Worker |
| R2 Class B 10 M / month | `CLASS_B_CAP` = 4 000 000 / month | reads made by the Worker |
| Workers 100 k requests / day | `REQUESTS_CAP_DAY` = 20 000 / day | leaves plenty for Portfolio |
| D1 100 k rows written / day | follows from the request cap (≤ 3 writes per request) | |

Expected use (1 iPhone + 2 Macs): the Macs don't poll. Each keeps one live connection to a
Durable Object (free plan, SQLite-backed): an idle hibernating connection isn't billed,
protocol pings are free, and the nudges it sends are outgoing messages, also free. Opening a
connection is one request (after sleep or a network change). The iPhone touches the bridge a
few times a day (open, book closed, background). Roughly a few dozen requests a day, a few
thousand R2 operations a month, storage only while a book is in transit (a 10-hour book is
≈ 300 MB). On the free plan a Durable Object limit only makes calls fail until 00:00 UTC.
Cost: $0, and the caps keep it $0 even if something misbehaves.

When a cap is reached the Worker answers `429` (ops/requests) or `507` (storage) with a JSON
`{ "error": "...", "cap": "..." }`, and the apps quietly stay on LAN sync until the period
rolls over. Nothing is ever retried in a tight loop.

## Keys (all derived on the devices)

The Mac creates a random 32-byte **library key** once. It reaches phones only over the
paired, certificate-pinned LAN connection (in the pairing answer, and via
`GET /v1/bridge` for phones paired earlier). From it, HKDF-SHA256 (salt `habla-bridge-v1`):

| info | use |
|---|---|
| `enc` | AES-GCM-256 key for every object |
| `name` | HMAC-SHA256 key for object names |
| `token` | the bearer token sent to the Worker (base64url of 32 bytes) |

- **Object name** = first 40 hex chars of `HMAC(name, logicalName)`, e.g. logical
  `state/<deviceID>`, `book/<bookID>/<revision>/<path>#<chunk>` or `epub/<id>#<chunk>`.
  The bridge sees only the hex.
- **Object body** = `0x01 ‖ nonce(12) ‖ ciphertext ‖ tag(16)` with **AAD = logicalName**
  (for device documents AAD is `"state"`, and the document must name the device whose slot
  it sits in), so a blob can't be moved under another name. Plaintext is padded before sealing (state
  documents to a multiple of 4 KiB, book chunks to a multiple of 64 KiB) so sizes leak little.
- The Worker stores only `SHA-256(token)` as the space id. Enrolling a space needs the
  `ENROLL_SECRET` Worker secret, which only the Mac has (it enrolls once, then forgets the
  secret).

## Worker API

All requests: `Authorization: Bearer <token>`. Names match `^[0-9a-f]{40}$`.
Responses are JSON unless a body is returned.

| Method & path | Purpose |
|---|---|
| `POST /v1/spaces` | Enroll. Header `X-Habla-Enroll: <ENROLL_SECRET>`, body `{"tokenHash":"<sha256 hex>"}`. `201` new, `200` exists. |
| `GET /v1/usage` | `{storageBytes, portfolioBytes, storageCapBytes, classA, classACap, classB, classBCap, requestsToday, requestsCapDay}` |
| `GET /v1/state` | `[{name, size, etag, updated}]` of this space's state objects (from the D1 ledger, no R2 list) |
| `GET /v1/state/{name}` | body (`If-None-Match` → `304`) |
| `PUT /v1/state/{name}` | body ≤ 1 MiB → `{etag}` |
| `DELETE /v1/state/{name}` | |
| `GET /v1/transit` | `[{name, size, updated}]` |
| `PUT /v1/transit/{name}` | body ≤ 16 MiB, `Content-Length` required. Storage is reserved before the upload. |
| `GET /v1/transit/{name}` | body |
| `DELETE /v1/transit/{name}` | frees the storage at once |

Cron (daily): measure `portfolio-media`, delete transit objects older than 14 days,
reconcile the ledger with the bucket.

## Devices sharing one library

Usually one iPhone and two Macs. The iPhone gets the library key from the Mac it is paired
with (over the pinned LAN link). The second Mac joins with a **link code** from the first
(Habla → "Link another Mac…" → copy; on the other Mac "Join another Mac's library…" → paste).
Anyone holding the key is one of your devices, so every device that checked in during the
last 30 days receives every new book.

### Help narrate only (helper Macs)

A Mac joined with "Help narrate only" (`kind: "helper"`) narrates books sent to it and
nothing else: its window shows no library (just "Helping narrate" and a percentage), it
doesn't share on Wi-Fi, it merges no places or marks and publishes none, it never receives
finished books, other devices don't wait for it to collect anything, and once every device
has a book it narrated, it deletes its copy (a book that was already on that Mac is kept).
It still holds the library key, so this is a behaviour, not a cryptographic wall.

### Who narrates a new book

"Running" needs no uploads: a Mac is running while its live connection (`GET /v1/listen`,
WebSocket to the library's `Room` Durable Object) is open; the listing marks those devices
`online`. Every request also carries `X-Habla-Device` (the device's opaque document name) so
the Worker notes `seen`; a device without a live connection counts as running for 5
minutes after it looked. Whenever a device uploads its document, the Room sends "changed" to
every other connected device, which syncs at once. Each document carries
`narrator = {sentencesPerSecond, queuedSentences, measured}`, its speed measured from real
narrations (a guess until then: Mac 1.0, iPhone 0.2) and the work already queued.

**One voice for the account.** `settings.voice` (Heart unless changed in Settings on a Mac;
latest change wins) is used by every device for every book, and an EPUB sent to another
device carries it, so nobody has to check which voice to use.

When a book lands on a device (dropped on a Mac with auto-narrate on, or added on the
iPhone), that device takes fresh check-ins and picks, among the Macs active in the last
12 minutes and itself, the one with the earliest finish
`(queued + book sentences) / speed` (a remote Mac's time is padded by 10 % + 60 s for the
transfer). The EPUB goes to it: over Wi-Fi when that's the paired Mac at home, else through
the bridge as an `epub` transfer with `target`. That device narrates in the background and
then sends the narrated book to the others. If no Mac is running, the iPhone narrates it
itself. A target that stays quiet for 20 minutes without collecting the EPUB is replaced by
the next best running device (or the sender). Books in languages Habla can't narrate just
go to the Mac as text.

## Device documents

Each device writes only its own document (logical name `state/<deviceID>`), so devices
never overwrite each other. Readers merge every document:

```jsonc
{
  "v": 1, "deviceID": "...", "deviceName": "...", "kind": "mac" | "phone",
  "updatedAt": "...",
  "positions": [ReadingPosition],          // merged with ReadingPosition.merge (latest wins)
  "markers": [Marker],                     // merged by id, latest updatedAt wins, tombstones kept
  "has": [{"bookID": "...", "revision": 3}],   // books on this device
  "outbox": [Transfer],                    // narrated books for the others; EPUBs for their narrator
  "recipients": ["deviceID", ...],         // who must collect each book
  "received": ["transferID", ...],         // EPUBs this device collected
  "lastActive": "...",                     // heartbeat
  "narrator": {"sentencesPerSecond": 1.3, "queuedSentences": 2400, "measured": true}
}
```

`Transfer = {id, kind: "book"|"epub", bookID?, revision?, filename?, manifest?: BookManifest,
files: [{path, size, sha256, chunks: Int}], createdAt, target?}`. A receiver rebuilds each file from
its chunks, checks the SHA-256 from the manifest, and installs the book the same way LAN
sync does, when it has more audio than the local copy (or the same audio, newer). The sender
deletes the chunks once every recipient lists the book in `has` (EPUBs: once the target
lists the transfer id in `received`). A Mac sends the books it narrated or imported; the
iPhone only the books it narrated itself; nobody re-sends a book it received.

## Cadence

- Phone: only when Habla opens (what changed elsewhere comes in), when a book (reader or
  player) closes and when Habla goes to the background (the place and marks go out), plus
  when you add a book or it finishes narrating one. Nothing while you read. At home the Mac
  still gets places and marks live over Wi-Fi (free).
- Mac: when nudged (instantly), when its connection reopens (wake, network change), when a
  reader window closes, a few seconds after a book finishes narrating or the voice changes,
  and once every 6 hours as a safety net. Documents are downloaded only if they changed, and
  its own is uploaded only if it changed.
- Only documents whose `etag` changed are downloaded.
