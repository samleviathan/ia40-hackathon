import { canIngest, deny } from '../../lib/auth';
import { sql } from '../../lib/db';
import { emit } from '../../lib/events';

// POST {batch, state: "live" | "done", device?, summary?} when the phone starts or ends a session.
export async function POST(req: Request) {
  if (!canIngest(req)) return deny();
  const { batch, state, device, summary } = await req.json();
  if (state === 'live') {
    await sql()`insert into sessions (batch, device) values (${batch}, ${device ?? null}) on conflict (batch) do nothing`;
  } else {
    await sql()`update sessions set state = 'done', ended_at = now(), summary = ${summary ?? null} where batch = ${batch}`;
  }
  await emit(batch, [{ type: 'session', state, batch, ...(summary && { summary }) }]);
  return Response.json({ ok: true });
}
