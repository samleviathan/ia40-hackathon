# DocHand

Scan a box of paper with an iPhone and watch it turn into filed, structured documents on a live
board: pages grouped into documents and put back in order, fields extracted, people and agencies
resolved, action items and discrepancies flagged. Built for the IA40 hackathon (Seattle, 2026-09-29).

```
iPhone (mobile/)                      Mac receiver (dashboard/server)           Live board (dashboard/web)
  auto-capture 48 MP pages   ──USB/──▶  saves + sha256 every upload               pages appear as scanned
  quality gate: blur, glare,   Wi-Fi    thumbnail + Apple Vision OCR (~0.5 s)     documents assemble, reorder
  cut-off, hand-in-frame                Whisper for voice notes                   people / orgs resolve
  voice notes, Start / Stop             event stream  ◀── agent decisions ──▶    wide view per document
```

| Folder | What it is |
|---|---|
| [`mobile/`](mobile/) | The iOS capture app (SwiftUI, AVFoundation, Vision) |
| [`dashboard/`](dashboard/) | The Mac receiver, its OCR tools and the live board |
| [`dashboard/prod/`](dashboard/prod/) | Production path: an OpenAI Agents SDK agent files each page; files in private Vercel Blob, data in Neon Postgres |

## Quick start

```sh
dashboard/tools/build.sh                                    # compile the OCR helpers once
DOCHAND_ADVERTISE_IP=usb python3 -u dashboard/server/receiver.py
open http://localhost:8765/live/
mobile/build.sh                                             # build, install and launch on the USB iPhone
```

Press **Start** on the phone. Pages show on the board as they are read; an agent files them.

## Private data

Scans can hold sensitive documents (letters, invoices, medical statements). They live in
`dashboard/data/`, which is git-ignored along with Whisper models, logs and the replay file `dashboard/web/events.js`.
