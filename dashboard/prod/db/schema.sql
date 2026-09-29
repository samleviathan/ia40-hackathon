-- DocHand production schema (Neon Postgres). Scans and OCR JSON live in private Vercel Blob;
-- these tables hold what the board and the agent need, keyed by the blob pathname.

create table if not exists sessions (
  batch        text primary key,              -- phone batch id, e.g. b20260929-153424
  device       text,
  state        text not null default 'live',  -- live | done
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  summary      text
);

create table if not exists pages (
  batch        text not null references sessions(batch),
  page_id      text not null,                 -- p0004-c4c5ef
  n            int  not null,                 -- capture order within the session
  image_path   text not null,                 -- blob pathname of the straightened JPEG
  thumb_path   text not null,
  ocr_path     text not null,                 -- blob pathname of <page>.full.json (lines + word boxes)
  ocr_text     text not null,                 -- plain text, for the agent and search
  words        int  not null,
  verdict      text not null,                 -- READS | few words | DID NOT READ - retake
  orientation  text not null default 'up',
  sha256       text not null,
  captured_at  timestamptz,
  created_at   timestamptz not null default now(),
  primary key (batch, page_id),
  unique (batch, n)
);

create table if not exists voice_notes (
  id           bigserial primary key,
  batch        text not null references sessions(batch),
  clip_id      text not null,
  text         text not null,
  created_at   timestamptz not null default now()
);

-- One row per document; `doc` is the latest board event body (title, fields, actions, access ...).
create table if not exists documents (
  batch        text not null references sessions(batch),
  doc_id       text not null,
  doc          jsonb not null,
  updated_at   timestamptz not null default now(),
  primary key (batch, doc_id)
);

create table if not exists entities (
  batch        text not null references sessions(batch),
  name         text not null,
  etype        text not null,                 -- person | org | agency | address
  doc_id       text not null,
  seen         text not null,
  primary key (batch, name, doc_id)
);

create table if not exists issues (
  id           bigserial primary key,
  batch        text not null references sessions(batch),
  doc_id       text not null,
  sev          text not null,                 -- high | med | low
  text         text not null,
  created_at   timestamptz not null default now()
);

-- The board's stream: same event shapes as the Mac receiver's /api/events.
create table if not exists events (
  seq          bigserial primary key,
  batch        text,
  body         jsonb not null,
  created_at   timestamptz not null default now()
);
create index if not exists events_batch_seq on events (batch, seq);
