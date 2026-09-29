import { deny, viewCookie } from '../lib/auth';

// GET /api/open?key=<DOCHAND_VIEW_TOKEN>: sets the viewer cookie and opens the live board.
export async function GET(req: Request) {
  const key = new URL(req.url).searchParams.get('key');
  if (!process.env.DOCHAND_VIEW_TOKEN || key !== process.env.DOCHAND_VIEW_TOKEN) return deny();
  return new Response(null, { status: 302, headers: { location: '/live/', 'set-cookie': viewCookie() } });
}
