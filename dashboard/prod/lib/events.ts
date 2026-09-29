import { sql } from './db';

// Board events, same shapes as the Mac receiver's stream (see dashboard/README.md).
export type BoardEvent = { type: string; [k: string]: unknown };

export async function emit(batch: string | null, events: BoardEvent[]) {
  const db = sql();
  for (const e of events) {
    await db`insert into events (batch, body) values (${batch}, ${JSON.stringify({ ...e, ts: Date.now() / 1000 })}::jsonb)`;
  }
}

// `next` is one past the highest seq, so the board's "next < since means restarted" check holds.
export async function since(seq: number) {
  const rows = await sql()`select seq, body from events where seq >= ${seq} order by seq limit 500`;
  const next = rows.length ? Number(rows[rows.length - 1].seq) + 1 : seq;
  return { events: rows.map(r => r.body as BoardEvent), next };
}
