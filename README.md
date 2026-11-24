# Habla

EPUB → natural audiobook + Apple Books–style reader, synced between your Mac and iPhone.
The Mac does the heavy work (narration with Kokoro-82M; the iPhone keeps Paradee, a small model distilled from Kokoro, as a backup); the iPhone app is under 1 MB and only plays and reads.

## Get started

```sh
Scripts/build.sh          # → dist/Habla.app (Mac) and dist/Habla.ipa (iPhone)
```

1. **Mac** — open Habla (move it to Applications so it can update itself). First run: click
   **Install** in the banner (Kokoro voice engine, ~350 MB, once). Drop EPUB files on the window;
   narration starts by itself (~11× real time on an M3 Pro with two Kokoro workers: a 10-hour book in under an hour). Habla opens at login and keeps working
   with its window closed: it serves the iPhone, imports books the iPhone sends, and narrates them.
   The Mac stays awake while narrating. *Habla → Open at Login* turns that off.
2. **iPhone** — install `Habla.ipa` with AltStore. Open it on the same Wi-Fi: it finds the Mac by
   itself (allow *Local Network*). Tap **Get** on a book from the Mac, or **＋** to add an EPUB from
   Files (or *Share → Habla* from anywhere). Books you add are readable at once; they go to the Mac,
   which narrates them, and the audio arrives on the next sync.
3. **Reading** — press and hold a word for a card with **Underline**, **Dictionary** (Apple's; its
   *Manage* button downloads more dictionaries, e.g. Spanish–English) and **Translate** (Apple's
   on-device translator, iOS 17.4+). Switch the card to *Sentence* to underline or translate the
   whole sentence. On the Mac, double-click a word; the definition shows inline.

## Languages

Books in **English, Spanish, German, Russian, Ukrainian** (and French, Hindi) read fully: layout and
hyphenation follow the book's language (detected from the text, even when the EPUB says otherwise),
and Find, the dictionary and translation work in all of them. **Narration** on the Mac uses Kokoro's voices:
English (Heart, Bella, Nicole, Sarah, Michael, Fenrir, Puck, Emma, Isabella, George, Fable) and Spanish
(Dora, Alex, Santa). The iPhone's Paradee backup has fewer (Heart, Puck, Isabella, Fable; Alex) and uses
the closest one. Books narrated with Paradee on the Mac keep their audio; **Re-narrate with Kokoro**
redoes them (per book, or all at once from the Library).
Books in other languages (German, Russian, Ukrainian, French, Hindi…) are read-only.

## Updates

Every push to `main` runs `.github/workflows/release.yml`: tests, builds both apps, and publishes a
release `build-N` with `Habla-Mac.zip`, `Habla.ipa` and `altstore.json`.

- **Mac:** Habla checks GitHub every few hours, downloads new builds in the background and shows
  *Restart*; otherwise it installs when you quit. *Habla → Check for Updates…* checks now.
- **iPhone:** in AltStore, add this source once (Browse → Sources → ＋):
  `https://github.com/mmejiaxyz/Habla/releases/latest/download/altstore.json`.
  AltStore then shows and installs updates; Habla also shows *Update in AltStore* when one exists.

The Xteink (CrossPoint) support is built but hidden until it's tested on the device
(`Features.xteink` in HablaUI; protocol notes in `Docs/`).

Listening and reading share one position: *Read along* opens the page being spoken (highlighted);
*Listen* in the reader narrates from the page you're on.

## Layout

```
Packages/HablaCore   Core (no third-party deps): EPUB → bundle, voice rendering (Kokoro on the Mac), Mac⇄iPhone sync,
                     KOReader/CrossPoint sync, OPDS, Xteink delivery. CLI: `habla`.
Packages/HablaUI     App layer: design system, TextKit page engine (justified + hyphenated), narration
                     player, iPhone screens, Studio screens, stores. `habla-snapshots` renders screens.
Apps/                Xcode project (xcodegen): Habla (iOS 17+), HablaStudio (macOS 14+)
Tools/kokoro         Kokoro voice worker + installer (bundled into the Mac app)
Tools/voice          Paradee worker + installer (CLI only: habla render --engine paradee)
Docs/                Xteink/CrossPoint protocol notes (verified against the firmware source)
Design/Snapshots     Rendered screens (sheet-phone.png, sheet-mac.png)
```

## Tests

```sh
cd Packages/HablaCore && swift test   # import, text, render cache, sync (incl. damage repair), KOReader
                                      # positions (firmware text()[k].off format), Xteink vs a fake device
cd Packages/HablaUI && swift test     # phone⇄Mac sync end-to-end, reader never loses the place, player
```

CLI (same code as the apps): `habla import|list|inspect|render|serve|pull|export|xpcheck|xteink …`
— pass `--library DIR` to keep everything (progress, cache) inside DIR.
