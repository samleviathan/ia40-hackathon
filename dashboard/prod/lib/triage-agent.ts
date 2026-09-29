import { Agent, run, tool } from '@openai/agents';
import { z } from 'zod';
import { sql } from './db';
import type { BoardEvent } from './events';

// One call per read page. The agent sees the new page's OCR text, the documents filed so far in
// this session and recent voice notes, and returns filing decisions as board events. It can read
// earlier pages again to reunite a stray page with its document.
//
// Structured outputs are strict, so optional values are `.nullable()` and fields are a list of
// {name, value} rather than a free-form map.

const Field = z.object({ name: z.string(), value: z.string() });
const Action = z.object({
  text: z.string().describe('What we have to do, as an imperative: "Pay the $54.21 deposit"'),
  due: z.string().nullable().describe('YYYY-MM-DD if the document gives or implies a deadline'),
  detail: z.string().nullable(),
});
const Doc = z.object({
  id: z.string().describe('Reuse an existing id to update that document; new ids are d1, d2, ...'),
  box: z.string().describe('Folder: the agency or organization, e.g. "City of Springfield, IL"'),
  boxkey: z.string().describe('Short stable key for the folder, e.g. "Springfield"'),
  title: z.string(),
  doctype: z.string().describe('Invoice, Extension notice, Final response, Fee itemization form, ...'),
  date: z.string().describe('Document date YYYY-MM-DD, or "" if none'),
  pages: z.array(z.number().int()).describe('Capture numbers in reading order, e.g. [13, 11]'),
  status: z.enum(['open', 'complete']),
  summary: z.string().describe('One or two sentences: what this document is'),
  fields: z.array(Field).describe('Every useful value on the document, labelled as a person would'),
  actions: z.array(Action),
  note: z.string().nullable().describe('How the pages were assembled: reordered, reunited, waiting for page 2'),
  access: z
    .object({ level: z.enum(['public', 'internal', 'restricted', 'privileged']), parties: z.array(z.string()), reason: z.string() })
    .nullable(),
});
const Decisions = z.object({
  docs: z.array(Doc).describe('Documents created or changed by this page; usually one'),
  entities: z.array(z.object({ name: z.string(), etype: z.enum(['person', 'org', 'agency', 'address']), doc: z.string(), seen: z.string() })),
  issues: z.array(z.object({ sev: z.enum(['high', 'med', 'low']), doc: z.string(), text: z.string() })),
  set_aside: z.array(z.object({ page: z.number().int(), reason: z.string() })).describe('Duplicates, overlaps, cut-off shots'),
  narration: z.string().describe('One line for the board feed explaining the decision'),
});
export type Decisions = z.infer<typeof Decisions>;

const INSTRUCTIONS = `You file scanned paper records as they are captured, one page at a time.

For each new page decide:
- Which document it belongs to. Pages arrive out of order: use "Page 2", "N of M", dates, request
  numbers, letterheads and signatures to put pages back in reading order and to reunite stray
  signature pages with their letters. Keep a document "open" until it is whole.
- The fields a person would want, labelled plainly, and a one-sentence summary.
- Action items: what the recipient must do next (pay, respond, decide on an appeal), with due
  dates when the document states or implies one. Say so in the issue list when a deadline has passed.
- People, organizations, agencies and addresses, with how each was written on the page.
- Discrepancies inside or across documents (two different amounts, a date that conflicts).
- Pages to set aside: re-shots of a page already filed, two sheets in one shot, cut-off shots.
- Access: medical, personnel or legal-privileged content is "restricted" or "privileged" with the
  parties who may see it; everything else is "internal" unless it is already public.

Voice notes from the person scanning are hints ("new box", "that was the back page"), not facts.
Never invent values that are not on the page. Today is ${new Date().toISOString().slice(0, 10)}.`;

function makeAgent(batch: string) {
  const readPage = tool({
    name: 'read_page',
    description: 'Full OCR text of an earlier page in this session, by capture number.',
    parameters: z.object({ n: z.number().int() }),
    execute: async ({ n }) => {
      const [p] = await sql()`select ocr_text, verdict from pages where batch = ${batch} and n = ${n}`;
      return p ? `#${n} (${p.verdict})\n${p.ocr_text}` : `No page #${n} in this session.`;
    },
  });
  return new Agent({
    name: 'DocHand triage',
    instructions: INSTRUCTIONS,
    model: process.env.OPENAI_MODEL || 'gpt-5',
    tools: [readPage],
    outputType: Decisions,
  });
}

async function context(batch: string) {
  const db = sql();
  const [docs, voice, pages] = await Promise.all([
    db`select doc from documents where batch = ${batch} order by doc_id`,
    db`select text from voice_notes where batch = ${batch} order by id desc limit 8`,
    db`select n, left(ocr_text, 160) as head, verdict from pages where batch = ${batch} order by n`,
  ]);
  return { docs: docs.map(r => r.doc), voice: voice.map(r => r.text).reverse(), pages };
}

export async function triagePage(batch: string, page: { n: number; text: string; verdict: string }) {
  const ctx = await context(batch);
  const input = [
    `New page #${page.n} (${page.verdict}):\n${page.text}`,
    `Documents filed so far:\n${JSON.stringify(ctx.docs)}`,
    `All pages this session (first line only; use read_page for more):\n${ctx.pages.map(p => `#${p.n} ${p.verdict}: ${p.head}`).join('\n')}`,
    ctx.voice.length ? `Recent voice notes:\n${ctx.voice.map(v => `"${v}"`).join('\n')}` : '',
  ].filter(Boolean).join('\n\n');

  const result = await run(makeAgent(batch), input, { maxTurns: 6 });
  if (!result.finalOutput) throw new Error(`triage returned no decision for #${page.n}`);
  return result.finalOutput;
}

// Decisions -> board events, in the shapes the board already understands.
export function toEvents(d: Decisions): BoardEvent[] {
  return [
    ...d.docs.map(doc => ({
      type: 'doc',
      ...doc,
      fields: Object.fromEntries(doc.fields.map(f => [f.name, f.value])),
      actions: doc.actions.map(a => ({ text: a.text, ...(a.due && { due: a.due }), ...(a.detail && { detail: a.detail }) })),
      access: doc.access ?? undefined,
    })),
    ...d.entities.map(e => ({ type: 'entity', ...e })),
    ...d.issues.map(i => ({ type: 'issue', ...i })),
    { type: 'narration', text: d.narration },
  ];
}
