import { get, put } from '@vercel/blob';

// Scans can hold sensitive documents (letters, invoices, medical statements), so the store is
// private: files are only reachable through /api/file, which checks the viewer token.
export const pagePath = (batch: string, pageId: string, kind: 'jpg' | 'thumb.jpg' | 'full.json') =>
  `pages/${batch}/${pageId}.${kind}`;

export async function putPrivate(pathname: string, body: Blob | ArrayBuffer | string, contentType: string) {
  return put(pathname, body, { access: 'private', contentType, addRandomSuffix: false, allowOverwrite: true });
}

export async function getPrivate(pathname: string) {
  return get(pathname, { access: 'private' });
}

// The board refers to files by URL; it swaps `.thumb.jpg` for `.jpg` / `.full.json` in place,
// so all three variants of a page share one query-string shape.
export const fileUrl = (pathname: string) => `/api/file?path=${encodeURIComponent(pathname)}`;
