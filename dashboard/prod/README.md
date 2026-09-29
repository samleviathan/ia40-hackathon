# DocHand production

Locally, an agent can file pages by hand through `watch.py` and `agent.py`. Production replaces
that loop with one OpenAI Agents SDK call per page and moves storage to Vercel. The Mac keeps capture, OCR and Whisper; everything after that runs here.

```
Mac receiver ──(DOCHAND_CLOUD_URL)──▶ /api/ingest/page ──▶ private Blob: jpg, thumb, OCR json
  cloud.py                             │                 ──▶ Neon: pages row
                                       ├─▶ triage agent (OpenAI Agents SDK, read_page tool)
                                       │     └─ decisions: docs, entities, issues, set-asides
                                       ├─▶ Neon: documents, entities, issues
                                       └─▶ Neon: events ──▶ /api/events ──▶ board (/live/)
                                                 decisions also mirrored onto the local board
```

| Path | Role |
|---|---|
| `lib/triage-agent.ts` | The agent: instructions, strict output schema (docs with fields, actions, access; entities; issues; set-asides), `read_page` tool for reuniting pages |
| `api/ingest/page.ts` | Store a page's files in private Blob, record it, run the agent, persist and stream its decisions |
| `api/ingest/session.ts`, `voice.ts` | Session start/end and voice notes (the agent reads recent notes as hints) |
| `api/events.ts` | `GET ?since=N` for the board, same contract as the Mac receiver |
| `api/file.ts` | Streams a private blob (page image, thumbnail, OCR word boxes) to a signed-in viewer |
| `api/open.ts` | `?key=<view token>` sets the viewer cookie and opens the board |
| `lib/blob.ts`, `db.ts`, `events.ts`, `persist.ts`, `auth.ts` | Storage and auth helpers |
| `db/schema.sql` | sessions, pages, voice_notes, documents, entities, issues, events |
| `../server/cloud.py` | Mac-side forwarder: pages, voice notes and sessions, one background worker, best-effort |

## Storage

- **Vercel Blob, private store.** Scans can hold sensitive documents (letters, invoices, medical
  statements), so nothing is public. Files are read only through `/api/file`, which checks the viewer cookie.
  Paths are `pages/<batch>/<page>.{jpg,thumb.jpg,full.json}`, so the board's thumbnail-to-full
  and thumbnail-to-OCR swaps work unchanged.
- **Neon Postgres** from the Vercel Marketplace. The event table feeds the board; the documents,
  entities and issues tables hold the same decisions in queryable form.

## Deploy

```sh
cd dashboard/prod
vercel link
vercel integration add neon                          # sets DATABASE_URL
vercel blob create-store dochand-scans --access private
vercel env add OPENAI_API_KEY
vercel env add DOCHAND_INGEST_TOKEN                  # shared with the Mac receiver
vercel env add DOCHAND_VIEW_TOKEN                    # for people viewing the board
vercel env pull .env.local --yes && npm install && npm run db:migrate
vercel --prod
```

The build copies `../web` into `public/` (minus the replay file), and `/live/` rewrites to it, so
the same board runs locally and in production. Open `https://<deployment>/api/open?key=<view token>`.

Then point the Mac at it:

```sh
DOCHAND_CLOUD_URL=https://<deployment> DOCHAND_INGEST_TOKEN=... \
DOCHAND_ADVERTISE_IP=usb python3 -u dashboard/server/receiver.py
```

## Status

Written against the SDK and storage APIs as documented, not yet run. Before relying on it:
`npm run typecheck`, one page end to end against a preview deployment, and a check that the
`maxDuration` of 60 s covers the agent on long pages. The phone mirror stays local (`/api/mirror`
is not deployed), and page ingest is sequential per receiver, so pages are filed in capture order.
