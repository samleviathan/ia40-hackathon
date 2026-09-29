import { canView, deny } from '../lib/auth';
import { getPrivate } from '../lib/blob';

// GET /api/file?path=pages/<batch>/<page>.{jpg,thumb.jpg,full.json}: stream a private blob to a viewer.
export async function GET(req: Request) {
  if (!canView(req)) return deny();
  const path = new URL(req.url).searchParams.get('path') ?? '';
  if (!/^pages\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(path)) return new Response('bad path', { status: 400 });
  const file = await getPrivate(path);
  if (!file || file.statusCode !== 200) return new Response('not found', { status: 404 });
  return new Response(file.stream, {
    headers: { 'content-type': file.blob.contentType, 'cache-control': 'private, max-age=3600' },
  });
}
