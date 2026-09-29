import { canView, deny } from '../lib/auth';
import { since } from '../lib/events';

// GET /api/events?since=N: the board's poll, same contract as the Mac receiver.
export async function GET(req: Request) {
  if (!canView(req)) return deny();
  const n = Number(new URL(req.url).searchParams.get('since') ?? 0);
  return Response.json(await since(n), { headers: { 'cache-control': 'no-store' } });
}
