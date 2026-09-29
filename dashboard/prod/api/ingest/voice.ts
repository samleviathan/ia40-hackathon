import { canIngest, deny } from '../../lib/auth';
import { sql } from '../../lib/db';
import { emit } from '../../lib/events';

// POST {batch, clip_id, text}: a transcribed voice note. The triage agent reads recent notes as hints.
export async function POST(req: Request) {
  if (!canIngest(req)) return deny();
  const { batch, clip_id, text } = await req.json();
  await sql()`insert into voice_notes (batch, clip_id, text) values (${batch}, ${clip_id}, ${text})`;
  await emit(batch, [{ type: 'voice', id: clip_id, text, action: '' }]);
  return Response.json({ ok: true });
}
