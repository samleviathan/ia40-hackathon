import { canIngest, deny } from '../../lib/auth';
import { fileUrl, pagePath, putPrivate } from '../../lib/blob';
import { sql } from '../../lib/db';
import { emit } from '../../lib/events';
import { persist } from '../../lib/persist';
import { toEvents, triagePage } from '../../lib/triage-agent';

// POST multipart/form-data from the Mac receiver, once a page has been OCR'd:
//   batch, page_id, n, sha256, captured_at?, image (jpg), thumb (jpg), ocr (Vision full.json)
// Stores the files in private Blob, records the page, runs the triage agent and streams its
// decisions to the board. Returns the decisions so the receiver can mirror them locally.
type Ocr = { words: number; orientation: string; lines: { text: string; conf: number }[] };

export async function POST(req: Request) {
  if (!canIngest(req)) return deny();
  const form = await req.formData();
  const batch = String(form.get('batch'));
  const pageId = String(form.get('page_id'));
  const n = Number(form.get('n'));
  const image = form.get('image') as File;
  const thumb = form.get('thumb') as File;
  const ocrFile = form.get('ocr') as File;
  const ocr: Ocr = JSON.parse(await ocrFile.text());

  const text = ocr.lines.map(l => l.text).join('\n');
  const conf = ocr.lines.reduce((s, l) => s + l.conf, 0) / Math.max(1, ocr.lines.length);
  const verdict = ocr.words < 30 ? 'few words' : conf >= 0.7 ? 'READS' : 'DID NOT READ - retake';

  const paths = { image: pagePath(batch, pageId, 'jpg'), thumb: pagePath(batch, pageId, 'thumb.jpg'), ocr: pagePath(batch, pageId, 'full.json') };
  await Promise.all([
    putPrivate(paths.image, image, 'image/jpeg'),
    putPrivate(paths.thumb, thumb, 'image/jpeg'),
    putPrivate(paths.ocr, JSON.stringify(ocr), 'application/json'),
  ]);

  const capturedAt = form.get('captured_at');
  await sql()`
    insert into pages (batch, page_id, n, image_path, thumb_path, ocr_path, ocr_text, words, verdict, orientation, sha256, captured_at)
    values (${batch}, ${pageId}, ${n}, ${paths.image}, ${paths.thumb}, ${paths.ocr}, ${text}, ${ocr.words}, ${verdict},
            ${ocr.orientation}, ${String(form.get('sha256'))}, ${capturedAt ? new Date(Number(capturedAt) * 1000) : null})
    on conflict (batch, page_id) do update set ocr_text = excluded.ocr_text, words = excluded.words, verdict = excluded.verdict`;

  const snippet = ocr.lines.find(l => l.text.length > 12)?.text ?? '';
  await emit(batch, [{ type: 'page', n, id: pageId, img: fileUrl(paths.thumb), state: 'read', words: ocr.words, snippet, verdict }]);

  // An unreadable page still goes to the agent: it may be a re-shot to set aside.
  const decisions = await triagePage(batch, { n, text, verdict });
  await persist(batch, decisions);
  await emit(batch, toEvents(decisions));
  return Response.json({ ok: true, decisions });
}
