// Two shared secrets. The Mac receiver ingests with a bearer token; the board is opened with
// /api/open?key=<view token> once, which sets a cookie for its API calls and image loads.
const bearer = (req: Request) => req.headers.get('authorization')?.replace(/^Bearer\s+/i, '') ?? '';
const cookie = (req: Request, name: string) =>
  req.headers.get('cookie')?.split(/;\s*/).find(c => c.startsWith(name + '='))?.slice(name.length + 1) ?? '';

export function canIngest(req: Request) {
  return !!process.env.DOCHAND_INGEST_TOKEN && bearer(req) === process.env.DOCHAND_INGEST_TOKEN;
}

export function canView(req: Request) {
  const want = process.env.DOCHAND_VIEW_TOKEN;
  if (!want) return false;
  return cookie(req, 'dochand_view') === want;
}

export const viewCookie = () =>
  `dochand_view=${process.env.DOCHAND_VIEW_TOKEN}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000`;

export const deny = () => new Response('unauthorized', { status: 401 });
