import { sql } from './db';
import type { Decisions } from './triage-agent';

// Upsert the agent's decisions so the documents, entities and issues are queryable on their own,
// not only as a replay of the event stream.
export async function persist(batch: string, d: Decisions) {
  const db = sql();
  for (const doc of d.docs) {
    const body = { ...doc, fields: Object.fromEntries(doc.fields.map(f => [f.name, f.value])) };
    await db`
      insert into documents (batch, doc_id, doc) values (${batch}, ${doc.id}, ${JSON.stringify(body)}::jsonb)
      on conflict (batch, doc_id) do update set doc = excluded.doc, updated_at = now()`;
  }
  for (const e of d.entities) {
    await db`
      insert into entities (batch, name, etype, doc_id, seen) values (${batch}, ${e.name}, ${e.etype}, ${e.doc}, ${e.seen})
      on conflict do nothing`;
  }
  for (const i of d.issues) {
    await db`insert into issues (batch, doc_id, sev, text) values (${batch}, ${i.doc}, ${i.sev}, ${i.text})`;
  }
}
