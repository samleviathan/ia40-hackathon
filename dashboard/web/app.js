window.REPLAY = window.REPLAY || [];   // events.js is optional (only for replaying a recorded session)

// State is built only from events, so the same page can be driven by a replay or a live event stream.
const S = { pages:{}, docs:{}, boxes:[], ents:{}, issues:[], feed:[] };
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const ETYPE = { person:'People', org:'Organizations', agency:'Agencies', address:'Addresses' };
const SEV = { high:'var(--red)', med:'var(--orange)', low:'var(--mut)' };
const PALETTE = ['#0a84ff', '#ff9f0a', '#30b0c7', '#bf5af2', '#34c759', '#ff375f', '#5e5ce6', '#a2845e'];
const colors = {};
const col = k => colors[k] || (colors[k] = PALETTE[Object.keys(colors).length % PALETTE.length]);

// Access levels. Each doc may carry access {level, parties[], reason}. The viewer switch shows what
// each party would see: Admin sees all; public docs are open to everyone; internal to any named
// party; restricted and privileged only to the parties listed. This is a view, not enforcement:
// the receiver still serves every event and file to anyone who can reach it.
const LEVEL = { public:'Public', internal:'Internal', restricted:'Restricted', privileged:'Privileged' };
let viewer = 'Admin';
const lvl = d => (d && d.access && d.access.level) || 'internal';
function canSee(d) {
  if (!d || viewer === 'Admin') return true;
  const l = lvl(d);
  if (l === 'public') return true;
  if (viewer === 'Public') return false;
  if (l === 'internal') return true;
  return (d.access.parties || []).includes(viewer);
}
const pageLocked = n => { const p = S.pages[n]; return !!(p && p.doc && !canSee(S.docs[p.doc])); };
const entVisible = e => [...e.docs].some(id => !S.docs[id] || canSee(S.docs[id]));
const issueVisible = i => !S.docs[i.doc] || canSee(S.docs[i.doc]);
function accessBadge(d) {
  const l = lvl(d), who = (d.access && d.access.parties || []).join(', ');
  return `<div class="access ${l}">${l === 'public' ? '' : '🔒 '}${LEVEL[l]}${who && l !== 'public' ? ` <small>· ${esc(who)}</small>` : ''}</div>`;
}
function syncViewers() {
  const parties = new Set();
  Object.values(S.docs).forEach(d => (d.access && d.access.parties || []).forEach(p => parties.add(p)));
  const want = ['Admin', ...[...parties].sort(), 'Public'];
  const sel = $('viewer');
  if ([...sel.options].map(o => o.value).join('|') === want.join('|')) return;
  sel.innerHTML = want.map(v => `<option${v === viewer ? ' selected' : ''}>${esc(v)}</option>`).join('');
}
function rerender() {
  Object.keys(S.pages).forEach(n => renderIncoming(n));
  Object.values(S.docs).forEach(d => renderDoc(d, false, d, true));
  renderEntities(); renderIssues(false); counters(); renderFiles();
  if (wide.id) renderWide();
}

// Files view: folders are boxes, files are documents, data models are the union of fields per doc type.
let fsel = 'all', fdoc = null;
const slug = t => String(t || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48);
const fileName = d => `${d.date || 'undated'}_${slug(d.title)}.pdf`;
const models = () => {
  const m = {};
  Object.values(S.docs).forEach(d => { const k = d.doctype || 'Document'; (m[k] = m[k] || { docs:[], fields:[] }).docs.push(d);
    Object.keys(d.fields || {}).forEach(f => { if (!m[k].fields.includes(f)) m[k].fields.push(f); }); });
  return m;
};
function renderFiles() {
  if (!document.body.classList.contains('files')) return;
  const docs = Object.values(S.docs), M = models();
  const boxes = S.boxes.map(k => docs.find(d => d.boxkey === k)).filter(Boolean);
  $('fside').innerHTML = `<div class="it ${fsel === 'all' ? 'on' : ''}" data-f="all"><span>All documents</span><small>${docs.length}</small></div>
    <h2>Folders</h2>${boxes.map(b => `<div class="it ${fsel === 'box:' + b.boxkey ? 'on' : ''}" data-f="box:${esc(b.boxkey)}"><i style="background:${col(b.boxkey)}"></i><span>${esc(b.box)}</span><small>${docs.filter(d => d.boxkey === b.boxkey).length}</small></div>`).join('') || '<div class="empty" style="padding:0 8px">None yet</div>'}
    <h2>Data models</h2>${Object.entries(M).map(([k, v]) => `<div class="it ${fsel === 'model:' + k ? 'on' : ''}" data-f="model:${esc(k)}"><span>${esc(k)}</span><small>${v.fields.length} field${v.fields.length === 1 ? '' : 's'}</small></div>`).join('') || '<div class="empty" style="padding:0 8px">None yet</div>'}`;
  const shown = docs.filter(d => fsel === 'all' || fsel === 'box:' + d.boxkey || fsel === 'model:' + (d.doctype || 'Document'));
  const mk = fsel.startsWith('model:') && M[fsel.slice(6)];
  $('flist').innerHTML = (mk ? `<div class="schema"><b>${esc(fsel.slice(6))}</b> · data model inferred from ${mk.docs.length} document${mk.docs.length > 1 ? 's' : ''}<div class="chips">${mk.fields.map(f => `<span class="chip">${esc(f)} <b>${mk.docs.filter(d => d.fields && d.fields[f]).length}/${mk.docs.length}</b></span>`).join('')}</div></div>` : '') +
    (shown.length ? `<table><thead><tr><th>Name</th><th>Type</th><th>Date</th><th>Pages</th><th>Access</th></tr></thead><tbody>${shown.map(d => {
      const ok = canSee(d);
      return `<tr class="${d.id === fdoc ? 'on' : ''}" data-d="${d.id}"><td><div class="fname"><span class="ficon">${ok ? 'PDF' : '🔒'}</span>${ok ? esc(fileName(d)) : 'Restricted document'}</div></td>
        <td class="mut">${esc(d.doctype)}</td><td class="mut">${ok ? esc(d.date) : '—'}</td><td class="mut">${d.pages.length}</td><td>${accessBadge(d)}</td></tr>`; }).join('')}</tbody></table>`
      : '<div class="empty" style="padding:14px">No documents yet</div>');
  const d = S.docs[fdoc];
  if (!d) { $('finsp').innerHTML = '<div class="empty">Select a file to see its pages and fields</div>'; return; }
  if (!canSee(d)) { $('finsp').innerHTML = `<h3>Restricted document</h3><div class="fn">${esc(d.doctype)} · ${d.pages.length} page${d.pages.length > 1 ? 's' : ''}</div>
    <div class="lockbody" style="display:flex;gap:12px;align-items:center"><div class="lockicon">🔒</div><div>Hidden from ${esc(viewer)}.</div></div>${accessBadge(d)}`; return; }
  const model = M[d.doctype || 'Document'];
  $('finsp').innerHTML = `<h3>${esc(d.title)}</h3><div class="fn">${esc(d.box)} / ${esc(fileName(d))}</div>
    <button class="expand" data-open="${d.id}" title="Open wide view" aria-label="Open wide view"><svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2.5h3.5V6M13.5 2.5 9 7M6 13.5H2.5V10M2.5 13.5 7 9"/></svg></button>
    <div class="pv">${d.pages.map(n => `<img src="${S.pages[n]?.img || ''}" data-n="${n}" alt="">`).join('')}</div>
    <div class="sec">${esc(d.doctype)} fields</div>
    <table>${model.fields.map(f => d.fields && d.fields[f] ? `<tr><td>${esc(f)}</td><td>${esc(d.fields[f])}</td></tr>` : `<tr><td>${esc(f)}</td><td class="missing">—</td></tr>`).join('')}</table>
    <div class="sec">File</div>
    <table><tr><td>Folder</td><td>${esc(d.box)}</td></tr><tr><td>Pages</td><td>${d.pages.map(n => '#' + n).join(', ')}</td></tr>
      <tr><td>Status</td><td>${d.status === 'complete' ? 'Complete' : 'Assembling'}</td></tr>${d.note ? `<tr><td>Agent note</td><td>${esc(d.note)}</td></tr>` : ''}</table>
    ${accessBadge(d)}${d.access && d.access.reason ? `<span style="font-size:12px;color:var(--mut)"> ${esc(d.access.reason)}</span>` : ''}`;
}
$('fside').onclick = e => { const it = e.target.closest('[data-f]'); if (it) { fsel = it.dataset.f; renderFiles(); } };
$('flist').onclick = e => { const tr = e.target.closest('[data-d]'); if (tr) { fdoc = tr.dataset.d; renderFiles(); } };
$('seg').onclick = e => { const b = e.target.closest('[data-view]'); if (!b) return;
  document.querySelectorAll('#seg button').forEach(x => x.classList.toggle('on', x === b));
  document.body.classList.toggle('files', b.dataset.view === 'files'); renderFiles(); };

function bump(id, v) { const el = $(id); if (el.textContent != v) { el.textContent = v; el.classList.add('bump'); setTimeout(() => el.classList.remove('bump'), 700); } }
function counters() {
  bump('c-pages', Object.keys(S.pages).length); bump('c-docs', Object.keys(S.docs).length);
  bump('c-ents', Object.values(S.ents).filter(e => e.etype !== 'address' && entVisible(e)).length); bump('c-issues', S.issues.filter(issueVisible).length);
}

function apply(e) {
  if (e.type === 'session') {
    $('dot').className = 'dot ' + e.state;
    $('stitle').textContent = e.state === 'live' ? 'Scanning…' : 'Session complete';
    if (e.state === 'done') { $('banner').style.display = 'block'; $('banner').textContent = '✓ ' + e.summary; }
  }
  if (e.type === 'page') {
    const p = S.pages[e.n] = Object.assign(S.pages[e.n] || {}, e);
    renderIncoming(e.n, !p.rendered); p.rendered = true;
  }
  if (e.type === 'doc') {
    const isNew = !S.docs[e.id];
    const prev = S.docs[e.id];
    S.docs[e.id] = e;
    if (!S.boxes.includes(e.boxkey)) S.boxes.push(e.boxkey);
    e.pages.forEach(n => { if (S.pages[n]) { S.pages[n].doc = e.id; renderIncoming(n); } });
    renderDoc(e, isNew, prev);
    syncViewers();
    if (prev && lvl(prev) !== lvl(e)) { renderEntities(); renderIssues(false); }
  }
  if (e.type === 'entity') {
    const k = e.name; const was = S.ents[k];
    const x = S.ents[k] = was || { name:e.name, etype:e.etype, docs:new Set(), seen:new Set() };
    x.docs.add(e.doc); x.seen.add(e.seen);
    renderEntities(k, !was);
  }
  if (e.type === 'issue') { S.issues.push(e); renderIssues(true); }
  if (e.type === 'narration') { S.feed.unshift({text:e.text}); renderFeed(); }
  if (e.type === 'voice') {
    S.feed.unshift({text:`“${e.text}”` + (e.action ? ` → ${e.action}` : ''), v:true}); renderFeed();
    // Only pop the bar for a clip transcribed just now, not when a refresh replays the session's events.
    if (!e.dropped && !(e.ts && Date.now() / 1000 - e.ts > 10)) showVoice(e);
  }
  counters();
  renderFiles();
  if (wide.id && ['doc', 'entity', 'issue'].includes(e.type) && (e.id === wide.id || e.doc === wide.id)) {
    renderWide();
    if (wide.id) showWidePage(S.docs[wide.id].pages.includes(wide.n) ? wide.n : S.docs[wide.id].pages[0]);
  }
}

function renderIncoming(n, isNew) {
  const p = S.pages[n]; let el = $('inc-' + n);
  if (!el) { el = document.createElement('div'); el.id = 'inc-' + n; el.className = 'inc enter'; $('incoming').prepend(el); }
  const locked = pageLocked(n);
  el.classList.toggle('locked', locked);
  const status = locked ? `<span class="s">🔒 ${LEVEL[lvl(S.docs[p.doc])]} · ${p.doc}</span>`
    : p.doc ? `<span class="s filed">→ ${p.doc} · ${esc(S.docs[p.doc]?.boxkey)}</span>`
    : p.state === 'captured' ? `<span class="s"><span class="spin"></span>uploading</span>`
    : p.state === 'reading' ? `<span class="s"><span class="spin"></span>reading</span>`
    : /DID NOT READ/.test(p.verdict || '') ? `<span class="s" style="color:var(--red)">didn't read — retake</span>`
    : `<span class="s"><span class="spin"></span>${p.words} words · agent filing</span>`;
  el.innerHTML = `<img src="${p.img}" data-n="${n}" alt=""><div><div class="n">Page ${n}</div>${status}</div>`;
}

function renderDoc(d, isNew, prev, quiet) {
  let box = $('box-' + d.boxkey);
  if (!box) {
    if ($('boxes').querySelector('.empty')) $('boxes').innerHTML = '';
    box = document.createElement('div'); box.className = 'box enter'; box.id = 'box-' + d.boxkey;
    box.innerHTML = `<div class="boxhead"><i style="background:${col(d.boxkey)}"></i><span>${esc(d.box)}</span><small id="boxn-${d.boxkey}"></small></div><div class="docs"></div>`;
    $('boxes').appendChild(box);
  }
  let card = $('doc-' + d.id);
  if (!card) { card = document.createElement('div'); card.id = 'doc-' + d.id; card.className = 'doc enter'; card.style.setProperty('--c', col(d.boxkey)); box.querySelector('.docs').appendChild(card); }
  else if (!quiet) { card.classList.remove('flash'); void card.offsetWidth; card.classList.add('flash'); }
  card.classList.toggle('locked', !canSee(d));
  if (!canSee(d)) {
    card.innerHTML = `
    <div class="top"><div><h3>Restricted document</h3><div class="meta">${esc(d.doctype)} · ${d.id}</div></div>
      <span class="pill ${d.status}">${d.status === 'complete' ? 'Complete' : 'Assembling'}</span></div>
    <div class="lockbody"><div class="lockicon">🔒</div><div><b>${d.pages.length} page${d.pages.length > 1 ? 's' : ''} hidden from ${esc(viewer)}</b>
      Visible to ${esc(lvl(d) === 'internal' ? 'named parties' : ['Admin', ...(d.access.parties || [])].join(', '))}</div></div>
    ${accessBadge(d)}`;
    const count = Object.values(S.docs).filter(x => x.boxkey === d.boxkey).length;
    $('boxn-' + d.boxkey).textContent = `${count} document${count > 1 ? 's' : ''}`;
    return;
  }
  const oldKeys = new Set(Object.keys(prev?.fields || {}));
  const waiting = d.status === 'open' && /page 1 not scanned/.test(d.note || '') ? `<div class="slot">page 1<br>?</div>` : '';
  const waiting2 = d.status === 'open' && /waiting for page 2/.test(d.note || '') ? `<div class="slot">page 2<br>?</div>` : '';
  card.innerHTML = `
    <div class="top"><div><h3>${esc(d.title)}</h3><div class="meta">${esc(d.doctype)} · ${esc(d.date)} · ${d.id}</div></div>
      <span class="pill ${d.status}">${d.status === 'complete' ? 'Complete' : 'Assembling'}</span></div>
    <div class="thumbs">${waiting}${d.pages.map((n, i) => `<figure><img src="${S.pages[n]?.img || ''}" data-n="${n}" alt=""><figcaption>p${i + 1 + (waiting ? 1 : 0)} · #${n}</figcaption></figure>`).join('')}${waiting2}</div>
    <dl class="fields">${Object.entries(d.fields).slice(0, 7).map(([k, v]) =>
      `<dt>${esc(k.replace(/_/g, ' '))}</dt><dd class="${prev && !oldKeys.has(k) ? 'new' : ''}">${esc(v)}</dd>`).join('')}</dl>
    ${d.note ? `<div class="note">${esc(d.note)}</div>` : ''}
    ${accessBadge(d)}${d.access && d.access.reason ? `<span class="meta"> ${esc(d.access.reason)}</span>` : ''}`;
  const count = Object.values(S.docs).filter(x => x.boxkey === d.boxkey).length;
  $('boxn-' + d.boxkey).textContent = `${count} document${count > 1 ? 's' : ''}`;
  if (isNew) card.scrollIntoView({behavior:'smooth', block:'nearest'});
}

function renderEntities(changed, isNew) {
  const groups = {};
  Object.values(S.ents).filter(entVisible).forEach(e => (groups[e.etype] = groups[e.etype] || []).push(e));
  $('entities').innerHTML = Object.keys(ETYPE).filter(t => groups[t]).map(t => `<div class="etype">${ETYPE[t]}</div><div class="chips">${
    groups[t].map(e => `<span class="chip ${e.name === changed ? (isNew ? 'enter' : 'grow') : ''}" title="Seen as: ${esc([...e.seen].join(' · '))}">${esc(e.name)} <b>${e.docs.size}</b></span>`).join('')}</div>`).join('');
}

function renderIssues(isNew) {
  const shown = S.issues.filter(issueVisible);
  if (!shown.length) { $('issues').innerHTML = '<div class="empty">Nothing yet</div>'; return; }
  $('issues').innerHTML = shown.map((i, k) => `<div class="issue ${isNew && i === S.issues[S.issues.length - 1] ? 'enter' : ''}" style="--sev:${SEV[i.sev]}">
    <div class="h">${i.sev === 'high' ? 'Discrepancy' : i.sev === 'med' ? 'Conflict across documents' : 'Note'} · ${esc(i.doc)}</div>${esc(i.text)}</div>`).join('');
}

function renderFeed() {
  $('feed').innerHTML = S.feed.slice(0, 8).map((f, k) => `<div class="${f.v ? 'v' : ''} ${k === 0 ? 'enter' : ''}">${esc(f.text)}</div>`).join('');
}

let vtimer;
function showVoice(e) {
  $('vtext').textContent = '“' + e.text + '”'; $('vaction').textContent = e.action ? '→ ' + e.action : '';
  $('voicebar').classList.add('show'); clearTimeout(vtimer); vtimer = setTimeout(() => $('voicebar').classList.remove('show'), 4200);
}

// Click a document card (or its Open button in Files) for the wide view; a thumbnail inside the card
// opens the wide view on that page.
document.addEventListener('click', e => {
  const card = e.target.closest('.doc, [data-open]');
  if (!card || e.target.closest('#wide')) return;
  const id = card.dataset.open || card.id.replace(/^doc-/, '');
  if (!S.docs[id] || !canSee(S.docs[id])) return;
  e.stopImmediatePropagation();
  openWide(id, +(e.target.closest('.thumbs img')?.dataset.n || 0));
}, true);

// Click any page thumbnail to see the full scan (thumbnail first, then the full-resolution master).
document.addEventListener('click', e => {
  const img = e.target.closest('.inc img, .insp .pv img');
  if (img) {
    const n = +(img.dataset.n || 0);
    if (pageLocked(n)) return;
    const full = img.getAttribute('src').replace('.thumb.jpg', '.jpg');
    $('lbimg').src = img.getAttribute('src');
    const hi = new Image(); hi.onload = () => { if ($('lightbox').classList.contains('show')) $('lbimg').src = full; }; hi.src = full;
    const p = S.pages[n] || {};
    $('lbcap').textContent = n ? `Page ${n}` + (p.doc ? ` · ${p.doc} · ${S.docs[p.doc]?.title || ''}` : '') + ' · B toggles word boxes · click or Esc to close' : 'click or Esc to close';
    showBoxes(img.getAttribute('src'));
    $('lightbox').classList.add('show');
    return;
  }
  if (e.target.closest('#lightbox')) $('lightbox').classList.remove('show');
});
document.addEventListener('keydown', e => {
  if ($('lightbox').classList.contains('show')) {
    if (e.key === 'Escape') $('lightbox').classList.remove('show');
    if (e.key === 'b' || e.key === 'B') $('lbstage').classList.toggle('nobox');
    return;
  }
  if (!wide.id) return;
  if (e.key === 'Escape') closeWide();
  if (e.key === 'b' || e.key === 'B') toggleWideBoxes();
  if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
    const ps = S.docs[wide.id].pages, i = ps.indexOf(wide.n) + (e.key === 'ArrowRight' ? 1 : -1);
    if (ps[i] != null) showWidePage(ps[i]);
  }
});

// Word boxes from the receiver's OCR (<page>.full.json): normalized, top-left origin, in the upright
// image. When OCR read the page upside down, rotate the boxes 180° back onto the image as captured.
const boxFor = {};
const showBoxes = src => drawBoxes('lbsvg', src);
async function drawBoxes(svg, src) {
  $(svg).innerHTML = '';
  boxFor[svg] = src;
  let r;
  try { r = await (await fetch(src.replace('.thumb.jpg', '.full.json'), { cache:'no-store' })).json(); } catch { return; }
  if (boxFor[svg] !== src || !r?.lines) return;
  const down = r.orientation === 'down';
  $(svg).innerHTML = r.lines.flatMap(l => l.words || []).map(w => {
    let [x, y, bw, bh] = w.b;
    if (down) { x = 1 - x - bw; y = 1 - y - bh; }
    return `<rect x="${x}" y="${y}" width="${bw}" height="${bh}"><title>${esc(w.t)}</title></rect>`;
  }).join('');
}

// Wide view. A doc event may carry, besides title/doctype/date/fields:
//   summary  one or two sentences: what this document is
//   actions  [{text, due?: 'YYYY-MM-DD', detail?}] or plain strings: what we have to do next
// The agent sets these; the board only shows them. Fields named like "Action needed" also count as
// action items.
const wide = { id:null, n:0 };
const DAY = 864e5;
function dueChip(due) {
  if (!due) return '';
  const days = Math.round((new Date(due + 'T12:00:00') - new Date().setHours(12, 0, 0, 0)) / DAY);
  if (isNaN(days)) return `<span class="due">${esc(due)}</span>`;
  const when = days < 0 ? `overdue · ${due}` : days === 0 ? 'due today' : days === 1 ? 'due tomorrow' : `due ${due} · ${days}d`;
  return `<span class="due ${days < 0 ? 'over' : days <= 14 ? 'soon' : ''}">${esc(when)}</span>`;
}
function openWide(id, n) {
  const d = S.docs[id];
  wide.id = id;
  $('wbox').style.setProperty('--c', col(d.boxkey));
  renderWide();
  showWidePage(d.pages.includes(n) ? n : d.pages[0]);
  $('wide').classList.add('show');
  document.body.style.overflow = 'hidden';
}
function closeWide() { wide.id = null; $('wide').classList.remove('show'); document.body.style.overflow = ''; }
function toggleWideBoxes() {
  const off = $('wpic').classList.toggle('nobox');
  $('wboxbtn').textContent = 'Word boxes: ' + (off ? 'off' : 'on');
}
function showWidePage(n) {
  wide.n = n;
  const src = S.pages[n]?.img || '';
  $('wimg').src = src;
  if (src.endsWith('.thumb.jpg')) {
    const full = src.replace('.thumb.jpg', '.jpg'), hi = new Image();
    hi.onload = () => { if (wide.n === n) $('wimg').src = full; }; hi.src = full;
  }
  drawBoxes('wsvg', src);
  const ps = S.docs[wide.id].pages;
  $('wstrip').innerHTML = ps.length > 1 ? ps.map((p, i) => `<img src="${S.pages[p]?.img || ''}" data-wp="${p}" class="${p === n ? 'on' : ''}" title="Page ${i + 1} · #${p}" alt="">`).join('') : '';
}
function renderWide() {
  const d = S.docs[wide.id];
  if (!d) return closeWide();
  if (!canSee(d)) return closeWide();
  const f = d.fields || {};
  // Agents also write these as plain fields ("Decision", "Action needed"); read those too so the
  // wide view never disagrees with the card.
  const fieldsLike = re => Object.entries(f).filter(([k]) => re.test(k.replace(/[_.]/g, ' ').trim()));
  const actions = [...(d.actions || []), ...fieldsLike(/^(action|actions|action needed|actions needed|next steps?|to ?do)$/i).map(([, v]) => v)]
    .map(a => typeof a === 'string' ? { text:a } : a);
  const ents = Object.values(S.ents).filter(x => x.docs.has(d.id));
  const issues = S.issues.filter(i => i.doc === d.id);
  $('winfo').innerHTML = `
    <div class="kick"><i></i><span>${esc(d.box)}</span><span>·</span><span>${esc(d.doctype)}</span>${d.date ? `<span>·</span><span>${esc(d.date)}</span>` : ''}
      <span class="pill ${d.status}">${d.status === 'complete' ? 'Complete' : 'Assembling'}</span></div>
    <h1>${esc(d.title)}</h1>
    ${d.summary ? `<p class="sum">${esc(d.summary)}</p>` : ''}
    <h2>Action items${actions.length ? ` · ${actions.length}` : ''}</h2>
    <div class="acts">${actions.length ? actions.map(a => `<div class="act"><span class="ck"></span>
      <div>${esc(a.text)}${a.detail ? `<small>${esc(a.detail)}</small>` : ''}</div>${dueChip(a.due)}</div>`).join('') : '<div class="none">None recorded</div>'}</div>
    ${issues.length ? `<h2>Needs attention</h2>${issues.map(i => `<div class="issue" style="--sev:${SEV[i.sev]}">${esc(i.text)}</div>`).join('')}` : ''}
    <h2>Extracted data</h2>
    <dl class="wfields">${Object.entries(f).map(([k, v]) => `<dt>${esc(k.replace(/_/g, ' '))}</dt><dd>${esc(v)}</dd>`).join('') || '<dt>—</dt><dd class="mut">No fields yet</dd>'}</dl>
    ${ents.length ? `<h2>People &amp; organizations</h2><div class="chips">${ents.map(x => `<span class="chip" title="${esc(ETYPE[x.etype] || x.etype)} · seen as: ${esc([...x.seen].join(' · '))}">${esc(x.name)}</span>`).join('')}</div>` : ''}
    <h2>File</h2>
    <dl class="wfields"><dt>Folder</dt><dd>${esc(d.box)}</dd><dt>Name</dt><dd>${esc(fileName(d))}</dd>
      <dt>Pages</dt><dd>${d.pages.length} · scanned as ${d.pages.map(n => '#' + n).join(', ')}</dd>
      ${d.note ? `<dt>Agent note</dt><dd>${esc(d.note)}</dd>` : ''}
      <dt>Access</dt><dd>${accessBadge(d)}${d.access && d.access.reason ? ` <span class="mut">${esc(d.access.reason)}</span>` : ''}</dd></dl>`;
}
$('wclose').onclick = closeWide;
$('wboxbtn').onclick = toggleWideBoxes;
$('wide').onclick = e => {
  const t = e.target.closest('[data-wp]');
  if (t) return showWidePage(+t.dataset.wp);
  if (e.target === $('wide')) closeWide();
};

// Replay driver. For live use, replace with an EventSource on the receiver that calls apply(event).
let speed = 1, timers = [];
function reset() {
  timers.forEach(clearTimeout); timers = [];
  Object.assign(S, { pages:{}, docs:{}, boxes:[], ents:{}, issues:[], feed:[] });
  $('incoming').innerHTML = ''; $('boxes').innerHTML = '<div class="empty">Waiting for the first page…</div>';
  $('entities').innerHTML = '<div class="empty">None yet</div>'; $('issues').innerHTML = '<div class="empty">Nothing yet</div>';
  $('feed').innerHTML = ''; $('banner').style.display = 'none'; $('dot').className = 'dot'; $('stitle').textContent = 'Scanning session';
  ['c-pages', 'c-docs', 'c-ents', 'c-issues'].forEach(id => $(id).textContent = 0);
  syncViewers(); fdoc = null; renderFiles(); closeWide();
}
$('viewer').onchange = e => { viewer = e.target.value; rerender(); };
function play() { reset(); window.REPLAY.forEach(e => timers.push(setTimeout(() => apply(e), e.at * 1000 / speed))); }
$('play').onclick = play;
document.querySelectorAll('[data-speed]').forEach(b => b.onclick = () => {
  speed = +b.dataset.speed; document.querySelectorAll('[data-speed]').forEach(x => x.classList.toggle('on', x === b)); play();
});
const LIVE = location.pathname.startsWith('/live');
async function liveLoop() {
  let since = 0;
  document.querySelector('.controls').style.display = 'none';
  $('stitle').textContent = 'Waiting for Start on the phone…';
  for (;;) {
    try {
      const r = await (await fetch('/api/events?since=' + since, {cache:'no-store'})).json();
      if (r.next < since) { since = 0; reset(); continue; }   // receiver restarted
      for (const e of r.events) {
        if (e.type === 'session' && e.state === 'live') reset();
        apply(e);
      }
      since = r.next;
    } catch (err) {}
    await new Promise(res => setTimeout(res, 400));
  }
}
// Phone mirror: the app posts ~10 preview frames a second with its UI state to /api/mirror (over the
// same link as uploads), and the board redraws the phone screen from them.
const QCOL = { searching:['#ffcc00','none'], stabilizing:['#ffcc00','rgba(255,204,0,A)'], captured:['#34c759','rgba(52,199,89,.35)'],
  waiting:['rgba(255,255,255,.5)','none'], duplicate:['#ff9f0a','rgba(255,159,10,.25)'], paused:['#8e8e93','none'] };
async function phoneMirror() {
  let url;
  for (;;) {
    try {
      const r = await fetch('/api/mirror?t=' + Date.now(), {cache:'no-store'});
      if (r.status !== 200) throw 0;
      const m = JSON.parse(atob(r.headers.get('X-Mirror') || '') || '{}');
      const next = URL.createObjectURL(await r.blob());
      $('phoneimg').src = next; if (url) URL.revokeObjectURL(url); url = next;
      $('pcnt').textContent = m.count ?? 0;
      $('poff').textContent = m.offline ? 'laptop offline' : '';
      $('pcue').className = 'cue ' + (m.running && m.cue ? m.cue : ''); $('pcue').textContent = m.running && m.cue ? (m.cue === 'rescan' ? 'Rescan' : 'Next') : '';
      $('pcue').style.display = m.running && m.cue ? '' : 'none';
      $('pbtn').textContent = m.running ? 'Stop' : 'Start'; $('pbtn').className = 'btn' + (m.running ? ' stop' : '');
      const [st, p] = String(m.state || 'paused').split(':'), [stroke, fill] = QCOL[st] || QCOL.paused;
      const q = $('pquad');
      q.setAttribute('points', m.quad ? m.quad.map(([x, y]) => `${x},${y}`).join(' ') : '');
      q.setAttribute('stroke', stroke); q.setAttribute('fill', fill.replace('A', String(0.35 * (+p || 0))));
      $('phone').classList.add('show'); document.body.classList.add('hasphone');
      await new Promise(res => setTimeout(res, 60));
    } catch (e) {
      $('phone').classList.remove('show'); document.body.classList.remove('hasphone');
      await new Promise(res => setTimeout(res, 1000));
    }
  }
}
if (LIVE) phoneMirror();
if (LIVE) liveLoop();
else if (location.hash === '#end') window.REPLAY.forEach(apply); else play();
