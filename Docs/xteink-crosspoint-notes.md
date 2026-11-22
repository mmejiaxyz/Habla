# Xteink / CrossPoint sync — notes from Readest (2026-11-21)

Source: github.com/readest/readest (AGPL-3.0 — **learn from it, don't copy code into Habla**).
Their team verified most of this on a real Xteink X4 and in the CrossPoint simulator.

## How CrossPoint syncs (firmware 1.5–1.6)
- Built-in **KOSync client** (KOReader's sync protocol). Sync is **manual**, from the reader menu.
- One sync server per device. Default is `sync.crosspointreader.com`; a custom URL is allowed.
- **Document id** has two modes:
  - `FILENAME` (the **default**): `md5(file name)`.
  - `Binary`: KOReader partial MD5 of the file (what `BookManifest.koreaderDigest` already stores).
  - A Habla server should accept both. When Habla puts the EPUB on the device itself, it controls the
    file name, so the filename digest is predictable.
- **Progress** is a KOReader XPointer: `/body/DocFragment[N]/body/…/p[K]/text().OFFSET` plus a `percentage`.
  - Newer crengine writes `[1]` on first steps too, so the parser must accept both forms
    (Habla currently omits `[1]`, and emits no `text().N` suffix yet).
  - CrossPoint positions can land 1–3 lines off (a firmware PR fixes it), so match to the nearest sentence.
  - Readest never trusts `percentage` to choose the chapter; it always uses `DocFragment[N]`. Do the same.
- Local device progress (`progress.bin`) is layout-bound and useless off-device; ignore it.

## Getting books onto the device
- CrossPoint has a built-in **OPDS client** (HTTP Basic auth, paging, search) that accepts only
  `application/epub+zip` links. **Habla Studio can serve an OPDS feed on the LAN**, so the Xteink downloads
  EPUBs straight from the Mac.
- Device "File Transfer" mode also accepts `POST /upload?path=` (it refuses to overwrite: delete first).
- SD-card plugins and reading-session events exist on firmware develop builds; only use them later.

## Quirks that matter for Habla's server
- The device's HTTP client needs `Content-Length` (Habla's server always sends it). A body-less `204`
  makes it hang for about 30 s.
- Paged feeds: the firmware asks for `page_size + 1` items and drops the extra one.
- Never ask the device for passwords; Readest moved to per-device keys after finding a LAN-exposed config.
- "Optimize EPUB" on the device rewrites the file and changes the partial MD5. Fall back to matching by
  title + author.

## Plan for Habla
1. `LibraryServer` gains KOSync endpoints (`/users/auth`, `PUT /syncs/progress`, `GET /syncs/progress/:doc`)
   that map XPointer ⇄ (chapter, sentence) through `SourceRef.xpointer`.
2. An OPDS feed of the original EPUBs (the Mac keeps the originals; bundles don't).
3. Store `md5(file name)` next to `koreaderDigest`; add `text().N` offsets to xpointers.

## Implemented (2026-11-21) — verified against the firmware source, not yet a real device
Source of truth: crosspoint-reader/crosspoint-reader (MIT), `src/network/CrossPointWebServer.cpp`,
`src/SettingsList.cpp`. The device's *File Transfer* screen runs:
- UDP discovery on 8134: send `hello`, reply `crosspoint (on <hostname>);<wsPort>`. mDNS name `crosspoint.local`.
- HTTP on port 80, no auth: `GET /api/status`, `GET /api/files?path=`, `POST /mkdir` (form name, path),
  `POST /delete` (form path), `POST /upload?path=` (multipart; refuses to overwrite),
  `POST /api/settings` (JSON by key), `GET/POST /api/opds`.
- KOReader sync keys: `koServerUrl`, `koServerType` (0 CrossPoint, 1 KoSync, 2 Other), `koMatchMethod`
  (0 Filename, 1 Binary), `koUsername`, `koPassword`, `koSendMetadata`, `koSyncBehavior` (0 ask, 1 smart),
  `koSyncOnSleep`.

Flow (`XteinkSync`, `habla xteink find|setup|send`):
1. Find the device (UDP hello, then `crosspoint.local`).
2. `configure`: point KOSync at the Mac's LAN IP (`.local` names can't be relied on from the ESP32),
   KoSync type, Binary matching (Habla uploads the original file untouched), smart sync, sync on sleep,
   and add the `Habla (Mac)` OPDS catalog once.
3. `pushBooks`: create `/Habla`, upload originals the device lacks, replace truncated copies, never delete.
Tested against `Tests/HablaCoreTests/FakeCrossPoint.swift`, a protocol double built from the firmware source.
