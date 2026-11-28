// Habla cloud (Docs/cloud-bridge.md). One `Account` Durable Object per account decides what
// every device does; R2 carries sealed chunks in transit. Everything stored here was sealed on
// a device: this Worker checks token hashes, keeps the account inside Cloudflare's free tier,
// and moves bytes.

const NAME = /^[0-9a-f]{40}$/;
const CODE_ID = /^[0-9a-f]{64}$/;
const CODE_MINUTES = 15;
const enc = new TextEncoder();

const json = (body, status = 200, headers = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });
const fail = (status, error, cap) => json(cap ? { error, cap } : { error }, status);

const month = (d = new Date()) => d.toISOString().slice(0, 7);
const day = (d = new Date()) => d.toISOString().slice(0, 10);
const num = (env, k) => Number(env[k]);

async function sha256hex(s) {
  const d = await crypto.subtle.digest('SHA-256', enc.encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// MD5 (KOReader sync sends md5(password)). Workers' subtle crypto has it; node (tests) uses node:crypto.
async function md5hex(s) {
  try {
    const d = await crypto.subtle.digest('MD5', enc.encode(s));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
  } catch {
    const { createHash } = await import('node:crypto');
    return createHash('md5').update(s).digest('hex');
  }
}

function sameSecret(a, b) {
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

// Counts one unit toward a cap and says whether it was allowed. One statement, so two
// requests can't both take the last unit.
async function take(env, period, metric, cap) {
  const row = await env.DB.prepare(
    `INSERT INTO usage (period, metric, count) VALUES (?1, ?2, 1)
     ON CONFLICT (period, metric) DO UPDATE SET count = count + 1 WHERE count < ?3
     RETURNING count`).bind(period, metric, cap).first();
  return row != null && row.count <= cap;
}
const classA = (env) => take(env, month(), 'classA', num(env, 'CLASS_A_CAP'));
const classB = (env) => take(env, month(), 'classB', num(env, 'CLASS_B_CAP'));

// Reserves upload bytes only if everything stored on the account (Habla + Portfolio +
// uploads in flight) stays under the cap.
async function reserve(env, bytes) {
  const row = await env.DB.prepare(
    `UPDATE meta SET value = CAST(value AS INTEGER) + ?1 WHERE key = 'reserved_bytes'
       AND (SELECT COALESCE(SUM(size), 0) FROM objects) + CAST(value AS INTEGER) + ?1
         + COALESCE((SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'portfolio_bytes'), 0) <= ?2
     RETURNING value`).bind(bytes, num(env, 'STORAGE_CAP_BYTES')).first();
  return row != null;
}
const release = (env, bytes) => env.DB.prepare(
  `UPDATE meta SET value = MAX(0, CAST(value AS INTEGER) - ?1) WHERE key = 'reserved_bytes'`).bind(bytes);

async function usage(env) {
  const stored = await env.DB.prepare('SELECT COALESCE(SUM(size), 0) AS s FROM objects').first();
  const metaRows = (await env.DB.prepare('SELECT key, value FROM meta').all()).results;
  const meta = Object.fromEntries(metaRows.map((r) => [r.key, r.value]));
  const counts = (await env.DB.prepare('SELECT period, metric, count FROM usage WHERE period IN (?1, ?2)')
    .bind(month(), day()).all()).results;
  const count = (p, m) => counts.find((r) => r.period === p && r.metric === m)?.count ?? 0;
  return {
    storageBytes: stored.s + Number(meta.reserved_bytes ?? 0), portfolioBytes: Number(meta.portfolio_bytes ?? 0),
    storageCapBytes: num(env, 'STORAGE_CAP_BYTES'),
    classA: count(month(), 'classA'), classACap: num(env, 'CLASS_A_CAP'),
    classB: count(month(), 'classB'), classBCap: num(env, 'CLASS_B_CAP'),
    requestsToday: count(day(), 'requests'), requestsCapDay: num(env, 'REQUESTS_CAP_DAY'),
  };
}

// One Room per library (space): who is connected right now, and the nudge.
const room = (env, space) => env.ROOM?.get(env.ROOM.idFromName(space));

async function online(env, space) {
  const r = room(env, space);
  if (!r) return new Set();
  try { return new Set(await (await r.fetch('https://room/online')).json()); } catch { return new Set(); }
}

async function nudge(env, space, from) {
  const r = room(env, space);
  if (r) { try { await r.fetch(`https://room/notify?from=${from}`, { method: 'POST' }); } catch {} }
}

const bare = (etag) => (etag ?? '').replace(/^W\//, '').replace(/"/g, '');

async function put(env, request, space, kind, name) {
  const max = kind === 'shelf' ? (num(env, 'MAX_SHELF_BYTES') || 64 * 1048576) : num(env, kind === 'state' ? 'MAX_STATE_BYTES' : 'MAX_TRANSIT_BYTES');
  const length = Number(request.headers.get('content-length'));
  if (!request.headers.has('content-length') || !Number.isInteger(length) || length < 0) return fail(411, 'length required');
  if (length > max) return fail(413, 'too large');
  if (!request.body && length > 0) return fail(400, 'no body');
  if (!(await reserve(env, length))) return fail(507, 'storage cap reached', 'storage');
  try {
    if (!(await classA(env))) { await release(env, length).run(); return fail(429, 'monthly write cap reached', 'classA'); }
    let body = request.body ?? new Uint8Array(0);
    if (request.body && typeof FixedLengthStream === 'function') {      // streams straight through, never buffered
      const { readable, writable } = new FixedLengthStream(length);
      request.body.pipeTo(writable).catch(() => {});
      body = readable;
    }
    const key = `${space}/${kind}/${name}`;
    const obj = await env.BRIDGE.put(key, body);
    if (!obj || obj.size !== length) {
      await env.BRIDGE.delete(key);
      await env.DB.batch([release(env, length), env.DB.prepare(
        'DELETE FROM objects WHERE space = ?1 AND kind = ?2 AND name = ?3').bind(space, kind, name)]);
      return fail(400, 'length mismatch');
    }
    await env.DB.batch([
      env.DB.prepare(`INSERT INTO objects (space, kind, name, size, etag, updated) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT (space, kind, name) DO UPDATE SET size = ?4, etag = ?5, updated = ?6`)
        .bind(space, kind, name, length, bare(obj.etag), Date.now()),
      release(env, length),
    ]);
    if (kind === 'state') await nudge(env, space, NAME.test(request.headers.get('x-habla-device') ?? '') ? request.headers.get('x-habla-device') : '');
    return json({ etag: bare(obj.etag) }, 200, { etag: `"${bare(obj.etag)}"` });
  } catch (e) {
    await release(env, length).run();
    return fail(502, 'upload failed');
  }
}

async function get(env, request, space, kind, name) {
  const row = await env.DB.prepare('SELECT etag FROM objects WHERE space = ?1 AND kind = ?2 AND name = ?3')
    .bind(space, kind, name).first();
  if (!row) return fail(404, 'not found');                                 // no R2 read for missing objects
  const inm = request.headers.get('if-none-match');
  if (inm && bare(inm) === row.etag) return new Response(null, { status: 304, headers: { etag: `"${row.etag}"` } });
  if (!(await classB(env))) return fail(429, 'monthly read cap reached', 'classB');
  const obj = await env.BRIDGE.get(`${space}/${kind}/${name}`);
  if (!obj) return fail(404, 'not found');
  return new Response(obj.body, { headers: { etag: `"${bare(obj.etag)}"`, 'content-type': 'application/octet-stream',
    'content-length': String(obj.size) } });
}

async function remove(env, space, kind, name) {
  await env.BRIDGE.delete(`${space}/${kind}/${name}`);                     // deletes are free in R2
  await env.DB.prepare('DELETE FROM objects WHERE space = ?1 AND kind = ?2 AND name = ?3').bind(space, kind, name).run();
  return json({ ok: true });
}

// Listing the state documents doubles as the device's check-in (X-Habla-Device = its own
// document's name), so "which devices are running" costs no uploads.
async function list(env, request, space, kind) {
  const device = request.headers.get('x-habla-device') ?? '';
  if (kind === 'state' && NAME.test(device)) {
    await env.DB.prepare(`INSERT INTO seen (space, name, at) VALUES (?1, ?2, ?3)
      ON CONFLICT (space, name) DO UPDATE SET at = ?3`).bind(space, device, Date.now()).run();
  }
  const live = kind === 'state' ? await online(env, space) : new Set();
  const rows = (await env.DB.prepare(`SELECT o.name, o.size, o.etag, o.updated, s.at AS seen FROM objects o
      LEFT JOIN seen s ON s.space = o.space AND s.name = o.name WHERE o.space = ?1 AND o.kind = ?2 ORDER BY o.name`)
    .bind(space, kind).all()).results;
  return json(rows.map((r) => ({ name: r.name, size: r.size, etag: r.etag, updated: new Date(r.updated).toISOString(),
    ...(r.seen ? { seen: new Date(r.seen).toISOString() } : {}), ...(live.has(r.name) ? { online: true } : {}) })));
}

// The daily request cap counts only requests that get past the checks below: junk from
// someone who found the URL is refused without spending the account's day.
const dailyCap = (env) => take(env, day(), 'requests', num(env, 'REQUESTS_CAP_DAY'));

async function handle(request, env) {
  const url = new URL(request.url);
  const parts = url.pathname.split('/').filter(Boolean);                   // ["v1", "state", name?]
  if (!['v1', 'v2', 'kosync', 'opds'].includes(parts[0])) return fail(404, 'not found');

  // Creating an account needs the server key (only the owner has it). The account id is the
  // token's hash, so a v1 space is already a v2 account.
  if (((parts[0] === 'v1' && parts[1] === 'spaces') || (parts[0] === 'v2' && parts[1] === 'accounts'))
      && parts.length === 2 && request.method === 'POST') {
    if (!env.ENROLL_SECRET) return fail(503, 'enrollment not configured');
    if (!sameSecret(request.headers.get('x-habla-enroll') ?? '', env.ENROLL_SECRET)) return fail(403, 'forbidden');
    if (!(await dailyCap(env))) return fail(429, 'daily request cap reached', 'requests');
    let body;
    try { body = await request.json(); } catch { return fail(400, 'bad json'); }
    if (!/^[0-9a-f]{64}$/.test(body?.tokenHash ?? '')) return fail(400, 'bad token hash');
    const spaces = await env.DB.prepare('SELECT COUNT(*) AS n FROM spaces').first();
    const known = await env.DB.prepare('SELECT 1 AS ok FROM spaces WHERE id = ?1').bind(body.tokenHash).first();
    if (!known && (spaces?.n ?? 0) >= num(env, 'MAX_SPACES')) return fail(403, 'no room for another account', 'spaces');
    const r = await env.DB.prepare('INSERT OR IGNORE INTO spaces (id, created) VALUES (?1, ?2)').bind(body.tokenHash, Date.now()).run();
    return json({ ok: true }, r.meta?.changes ? 201 : 200);
  }

  // Joining with a one-time code: no token yet. The code's id is a PBKDF2/HKDF derivative of
  // the code (256 bits: unguessable); the answer is sealed with a key only the code makes.
  if (parts[0] === 'v2' && parts[1] === 'join' && parts.length === 2 && request.method === 'POST') {
    let body;
    try { body = await request.json(); } catch { return fail(400, 'bad json'); }
    if (!CODE_ID.test(body?.id ?? '')) return fail(400, 'bad code');
    if (!(await dailyCap(env))) return fail(429, 'daily request cap reached', 'requests');
    const row = await env.DB.prepare('DELETE FROM codes WHERE id = ?1 AND expires > ?2 RETURNING wrapped')
      .bind(body.id, Date.now()).first();
    if (!row) return fail(404, 'code used, expired or wrong');
    return json({ wrapped: row.wrapped });
  }

  // The Xteink (KOReader sync + OPDS): its own username and password, set on it by a Mac.
  if (parts[0] === 'kosync' || parts[0] === 'opds') return ereader(request, env, parts);

  const auth = request.headers.get('authorization') ?? '';
  if (!auth.startsWith('Bearer ') || auth.length < 20) return fail(401, 'unauthorized');
  const space = await sha256hex(auth.slice(7));
  if (!(await env.DB.prepare('SELECT 1 AS ok FROM spaces WHERE id = ?1').bind(space).first())) return fail(401, 'unauthorized');
  if (!(await dailyCap(env))) return fail(429, 'daily request cap reached', 'requests');

  if (parts[0] === 'v2') return v2(request, env, space, parts);
  if (parts[1] === 'usage' && parts.length === 2 && request.method === 'GET') return json(await usage(env));
  if (parts[1] === 'listen' && parts.length === 2) {
    const device = request.headers.get('x-habla-device') ?? '';
    if (!NAME.test(device)) return fail(400, 'bad device');
    if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') return fail(426, 'websocket required');
    const r = room(env, space);
    if (!r) return fail(503, 'no live room');
    await env.DB.prepare(`INSERT INTO seen (space, name, at) VALUES (?1, ?2, ?3)
      ON CONFLICT (space, name) DO UPDATE SET at = ?3`).bind(space, device, Date.now()).run();
    return r.fetch(new Request(`https://room/listen?d=${device}`, request));
  }
  const kind = parts[1];
  if (kind !== 'state' && kind !== 'transit') return fail(404, 'not found');
  if (parts.length === 2) return request.method === 'GET' ? list(env, request, space, kind) : fail(405, 'method not allowed');
  const name = parts[2];
  if (parts.length !== 3 || !NAME.test(name)) return fail(400, 'bad name');
  switch (request.method) {
    case 'GET': return get(env, request, space, kind, name);
    case 'PUT': return put(env, request, space, kind, name);
    case 'DELETE': return remove(env, space, kind, name);
    default: return fail(405, 'method not allowed');
  }
}

// Lists a whole bucket, one Class A operation per page; stops (returns null) at the cap.
async function listAll(env, bucket) {
  const out = [];
  let cursor;
  do {
    if (!(await classA(env))) return null;
    const page = await bucket.list({ cursor, limit: 1000 });
    out.push(...page.objects);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return out;
}

async function scheduled(env) {
  const portfolio = await listAll(env, env.PORTFOLIO);
  if (portfolio) await env.DB.prepare(`UPDATE meta SET value = ?1 WHERE key = 'portfolio_bytes'`)
    .bind(String(portfolio.reduce((s, o) => s + o.size, 0))).run();

  const cutoff = Date.now() - num(env, 'TRANSIT_TTL_DAYS') * 86400000;
  const expired = (await env.DB.prepare(`SELECT space, kind, name FROM objects WHERE kind = 'transit' AND updated < ?1`)
    .bind(cutoff).all()).results;
  for (const o of expired) await remove(env, o.space, o.kind, o.name);

  await env.DB.prepare('DELETE FROM codes WHERE expires <= ?1').bind(Date.now()).run();

  const stored = await listAll(env, env.BRIDGE);
  if (stored) {
    const rows = (await env.DB.prepare('SELECT space, kind, name FROM objects').all()).results;
    const known = new Set(rows.map((r) => `${r.space}/${r.kind}/${r.name}`));
    const present = new Set(stored.map((o) => o.key));
    for (const o of stored) if (!known.has(o.key)) await env.BRIDGE.delete(o.key);
    for (const r of rows) if (!present.has(`${r.space}/${r.kind}/${r.name}`))
      await env.DB.prepare('DELETE FROM objects WHERE space = ?1 AND kind = ?2 AND name = ?3').bind(r.space, r.kind, r.name).run();
  } else {
    console.log('bridge cron: class A cap reached, skipped listing');
  }
  await env.DB.prepare(`UPDATE meta SET value = '0' WHERE key = 'reserved_bytes'`).run();
  await env.DB.prepare(`UPDATE meta SET value = ?1 WHERE key = 'last_cron'`).bind(new Date().toISOString()).run();
}

// A library's live connections. Hibernating WebSockets: an idle connection costs nothing,
// protocol pings are answered without waking it, and outgoing messages are free.
export class Room {
  constructor(ctx) { this.ctx = ctx; }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/listen') {
      const device = url.searchParams.get('d');
      for (const old of this.ctx.getWebSockets(device)) { try { old.close(4000, 'replaced'); } catch {} }
      const [client, server] = Object.values(new WebSocketPair());
      this.ctx.acceptWebSocket(server, [device]);
      return new Response(null, { status: 101, webSocket: client });
    }
    if (url.pathname === '/online') {
      return Response.json([...new Set(this.ctx.getWebSockets().flatMap((ws) => this.ctx.getTags(ws)))]);
    }
    if (url.pathname === '/notify') {
      const from = url.searchParams.get('from');
      for (const ws of this.ctx.getWebSockets()) {
        if (!this.ctx.getTags(ws).includes(from)) { try { ws.send('changed'); } catch {} }
      }
      return new Response('ok');
    }
    return new Response('not found', { status: 404 });
  }

  async webSocketMessage() {}                          // devices only listen
  async webSocketClose(ws, code) { try { ws.close(code === 1005 ? 1000 : code, 'bye'); } catch {} }
  async webSocketError() {}
}

// ---------------------------------------------------------------------------------------
// v2: the account

const DEVICE = /^[0-9a-f]{40}$/;
const account = (env, space) => env.ACCOUNT?.get(env.ACCOUNT.idFromName(space));

async function v2(request, env, space, parts) {
  const device = request.headers.get('x-habla-device') ?? '';
  if (parts[1] === 'codes' && parts.length === 2 && request.method === 'POST') {
    let body;
    try { body = await request.json(); } catch { return fail(400, 'bad json'); }
    if (!CODE_ID.test(body?.id ?? '') || typeof body.wrapped !== 'string' || body.wrapped.length > 4096) return fail(400, 'bad code');
    // A new code replaces the oldest open ones: at most 3 wait at once, and asking again never fails.
    const now = Date.now();
    await env.DB.prepare(`DELETE FROM codes WHERE space = ?1 AND (expires <= ?2 OR id IN (
        SELECT id FROM codes WHERE space = ?1 AND expires > ?2 ORDER BY expires DESC, rowid DESC LIMIT -1 OFFSET 2))`).bind(space, now).run();
    const expires = now + CODE_MINUTES * 60000;
    await env.DB.prepare('INSERT OR REPLACE INTO codes (id, space, wrapped, expires) VALUES (?1, ?2, ?3, ?4)')
      .bind(body.id, space, body.wrapped, expires).run();
    return json({ expires }, 201);
  }
  if (!DEVICE.test(device)) return fail(400, 'bad device');
  const a = account(env, space);
  // The Xteink's login for this account (one per account; a new one replaces the old).
  if (parts[1] === 'ereader' && parts.length === 2 && request.method === 'POST') {
    let body;
    try { body = await request.json(); } catch { return fail(400, 'bad json'); }
    if (!/^[a-z0-9-]{8,40}$/.test(body?.user ?? '') || !/^[0-9a-f]{32}$/.test(body?.keyMd5 ?? '')) return fail(400, 'bad login');
    await env.DB.batch([
      env.DB.prepare('DELETE FROM ereaders WHERE space = ?1 OR user = ?2').bind(space, body.user),
      env.DB.prepare('INSERT INTO ereaders (user, space, key_md5) VALUES (?1, ?2, ?3)').bind(body.user, space, body.keyMd5),
    ]);
    await a.fetch(new Request('https://account/ereader-on', { method: 'POST', headers: { 'x-habla-space': space, 'x-habla-device': device }, body: '{}' }));
    return json({ ok: true }, 201);
  }
  // A book for the Xteink's catalog: the EPUB as it is (readable by Cloudflare, by the owner's choice).
  if (parts[1] === 'shelf' && parts.length === 3 && NAME.test(parts[2]) && request.method === 'PUT') {
    const title = decodeURIComponent(request.headers.get('x-habla-title') ?? '').slice(0, 200);
    const r = await put(env, request, space, 'shelf', parts[2]);
    if (r.status !== 200) return r;
    await a.fetch(new Request('https://account/shelf-add', { method: 'POST', headers: { 'x-habla-space': space, 'x-habla-device': device },
      body: JSON.stringify({ key: parts[2], title, size: Number(request.headers.get('content-length')) }) }));
    return r;
  }
  if (!a) return fail(503, 'no account object');
  const forward = (path, init) => a.fetch(new Request(`https://account${path}`, init), {});
  const headers = { 'x-habla-space': space, 'x-habla-device': device };
  if (parts[1] === 'listen' && parts.length === 2) {
    if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') return fail(426, 'websocket required');
    return a.fetch(new Request(`https://account/listen?space=${space}&d=${device}`, request));
  }
  if (request.method !== 'POST') return fail(405, 'method not allowed');
  const body = await request.text();
  if (body.length > (num(env, 'MAX_SYNC_BYTES') || 2 * 1048576)) return fail(413, 'too large');   // places ≤ 1 MiB + the book list
  if (parts[1] === 'sync' && parts.length === 2) return forward('/sync', { method: 'POST', headers, body });
  if (parts[1] === 'devices' && parts[2] === 'remove' && parts.length === 3) return forward('/remove', { method: 'POST', headers, body });
  return fail(404, 'not found');
}

// KOReader sync (`/kosync/...`) and the OPDS catalog (`/opds`, `/opds/books/<key>.epub`) for the
// Xteink. Login: x-auth-user + x-auth-key (md5 of the password), or HTTP Basic.
async function ereader(request, env, parts) {
  let user = request.headers.get('x-auth-user') ?? '', key = (request.headers.get('x-auth-key') ?? '').toLowerCase();
  const basic = request.headers.get('authorization') ?? '';
  if (basic.startsWith('Basic ')) {
    try {
      const [u, ...rest] = atob(basic.slice(6)).split(':');
      if (!user) user = u;
      if (!key) key = await md5hex(rest.join(':'));
    } catch {}
  }
  if (parts[0] === 'kosync' && parts[1] === 'users' && parts[2] === 'create') return json({ username: user }, 201);
  const row = user && key ? await env.DB.prepare('SELECT space, key_md5 FROM ereaders WHERE user = ?1').bind(user).first() : null;
  if (!row || !sameSecret(key, row.key_md5)) {
    return parts[0] === 'opds'
      ? new Response('Unauthorized', { status: 401, headers: { 'www-authenticate': 'Basic realm="Habla"', 'content-length': '12' } })
      : json({ message: 'Unauthorized' }, 401);
  }
  if (!(await dailyCap(env))) return fail(429, 'daily request cap reached', 'requests');
  const a = account(env, row.space);
  const call = (path, init = {}) => a.fetch(new Request(`https://account${path}`, { ...init, headers: { 'x-habla-space': row.space } }));
  if (parts[0] === 'kosync') {
    if (parts[1] === 'users' && parts[2] === 'auth') return json({ authorized: 'OK' });
    if (parts[1] === 'syncs' && parts[2] === 'progress') {
      if (request.method === 'PUT' && parts.length === 3) return call('/kosync-put', { method: 'POST', body: await request.text() });
      if (request.method === 'GET' && parts.length === 4) return call(`/kosync-get?doc=${encodeURIComponent(parts[3])}`);
    }
    return json({ message: 'Not found' }, 404);
  }
  // OPDS
  if (parts.length === 1) return call('/opds');
  if (parts[1] === 'books' && parts.length === 3 && parts[2].endsWith('.epub')) {
    const k = parts[2].slice(0, -5);
    if (!NAME.test(k)) return fail(404, 'not found');
    const has = await env.DB.prepare(`SELECT size FROM objects WHERE space = ?1 AND kind = 'shelf' AND name = ?2`).bind(row.space, k).first();
    if (!has) return fail(404, 'not found');
    if (!(await classB(env))) return fail(429, 'monthly read cap reached', 'classB');
    const obj = await env.BRIDGE.get(`${row.space}/shelf/${k}`);
    if (!obj) return fail(404, 'not found');
    const title = (await (await call(`/shelf-title?key=${k}`)).text()) || 'Book';
    const file = title.replace(/[\\/:*?"<>|\x00-\x1f]/g, '').trim().slice(0, 90) || 'Book';
    return new Response(obj.body, { headers: { 'content-type': 'application/epub+zip', 'content-length': String(obj.size),
      'content-disposition': `attachment; filename="${encodeURIComponent(file)}.epub"` } });
  }
  return fail(404, 'not found');
}

const MIN = 60000, DAY = 86400000;
const ONLINE_MS = 2 * MIN;              // a sync this recent counts as online
const NARRATOR_GRACE_MS = 15 * MIN;     // a narrator away this long loses its books
const UPLOAD_GRACE_MS = 30 * MIN;       // an upload asked for and not done is asked of another
const AUDIO_PACE_MS = 10 * MIN;         // a narrating device sends new chapters at most this often
const EXPECTED_MS = 30 * DAY;           // devices seen this recently get every book
const MAX_AUDIO_BOOKS = 3, MAX_EPUBS = 20;

// One account: devices, books, who holds what, who narrates, what is in transit, and each
// device's sealed places. SQLite-backed; hibernating sockets for the "changed" nudge.
export class Account {
  constructor(ctx, env) {
    this.ctx = ctx; this.env = env; this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, kind TEXT, info TEXT, narrator TEXT,
      last_seen INTEGER, joined INTEGER)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS books (key TEXT PRIMARY KEY, meta TEXT, sentences INTEGER DEFAULT 0,
      narratable INTEGER DEFAULT 0, added_at INTEGER DEFAULT 0, deleted_at INTEGER, narrator TEXT, narrator_at INTEGER,
      epub_pack TEXT, epub_names TEXT, epub_at INTEGER, epub_by TEXT, epub_asked INTEGER,
      audio_pack TEXT, audio_names TEXT, audio_ready INTEGER DEFAULT 0, audio_at INTEGER, audio_first INTEGER,
      audio_by TEXT, audio_asked INTEGER, audio_dropped INTEGER DEFAULT 0)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS holdings (key TEXT, device TEXT, epub INTEGER, ready INTEGER, left_ INTEGER,
      PRIMARY KEY (key, device))`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS declined (key TEXT, device TEXT, PRIMARY KEY (key, device))`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS requests (key TEXT, device TEXT, PRIMARY KEY (key, device))`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS places (device TEXT PRIMARY KEY, version INTEGER, data TEXT)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS settings (field TEXT PRIMARY KEY, data TEXT, at INTEGER)`);
    // The Xteink's positions (KOReader sync: plain, by the owner's choice) and its catalog.
    this.sql.exec(`CREATE TABLE IF NOT EXISTS ereader_progress (document TEXT PRIMARY KEY, progress TEXT, percentage REAL,
      device TEXT, device_id TEXT, timestamp INTEGER)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS shelf (key TEXT PRIMARY KEY, title TEXT, size INTEGER, at INTEGER)`);
    for (const col of ['shelf_by TEXT', 'shelf_asked INTEGER']) { try { this.sql.exec(`ALTER TABLE books ADD COLUMN ${col}`); } catch {} }
  }

  rows(q, ...args) { return this.sql.exec(q, ...args).toArray(); }
  row(q, ...args) { return this.rows(q, ...args)[0] ?? null; }
  run(q, ...args) { this.sql.exec(q, ...args); }

  async fetch(request) {
    const url = new URL(request.url);
    const space = request.headers.get('x-habla-space') ?? url.searchParams.get('space');
    if (space && /^[0-9a-f]{64}$/.test(space)) this.run(`INSERT OR REPLACE INTO meta (k, v) VALUES ('space', ?)`, space);
    const device = request.headers.get('x-habla-device') ?? url.searchParams.get('d');
    if (url.pathname === '/listen') {
      for (const old of this.ctx.getWebSockets(device)) { try { old.close(4000, 'replaced'); } catch {} }
      const [client, server] = Object.values(new WebSocketPair());
      this.ctx.acceptWebSocket(server, [device]);
      return new Response(null, { status: 101, webSocket: client });
    }
    let body;
    try { body = JSON.parse(await request.text() || '{}'); } catch { return json({ error: 'bad json' }, 400); }
    if (url.pathname === '/sync') return json(await this.sync(device, body));
    if (url.pathname === '/kosync-put') {
      if (typeof body.document !== 'string' || typeof body.progress !== 'string') return json({ message: 'Invalid request' }, 400);
      const ts = Math.floor(Date.now() / 1000);
      this.putProgress({ ...body, timestamp: ts });
      this.notify('');
      return json({ document: body.document, timestamp: ts });
    }
    if (url.pathname === '/kosync-get') {
      const p = this.row(`SELECT * FROM ereader_progress WHERE document = ?`, (url.searchParams.get('doc') ?? '').toLowerCase());
      if (!p) return new Response(null, { status: 204, headers: { 'content-type': 'application/json', 'content-length': '0' } });
      return json({ document: p.document, progress: p.progress, percentage: p.percentage, device: p.device, device_id: p.device_id, timestamp: p.timestamp });
    }
    if (url.pathname === '/shelf-add') {
      this.run(`INSERT OR REPLACE INTO shelf (key, title, size, at) VALUES (?, ?, ?, ?)`, body.key, String(body.title ?? ''), Number(body.size) || 0, Date.now());
      this.run(`UPDATE books SET shelf_by = NULL WHERE key = ?`, body.key);
      return json({ ok: true });
    }
    if (url.pathname === '/ereader-on') {
      this.run(`INSERT OR REPLACE INTO meta (k, v) VALUES ('ereader', '1')`);
      await this.plan(Date.now()); this.notify(device);
      return json({ ok: true });
    }
    if (url.pathname === '/shelf-title') return new Response(this.row(`SELECT title FROM shelf WHERE key = ?`, url.searchParams.get('key'))?.title ?? '');
    if (url.pathname === '/opds') return this.opds();
    if (url.pathname === '/remove') { await this.remove(String(body.id ?? '')); this.notify(device); return json({ ok: true }); }
    return json({ error: 'not found' }, 404);
  }

  // Newest position per document wins (KOReader timestamps are seconds).
  putProgress(p) {
    const doc = String(p.document).toLowerCase().slice(0, 64);
    const cur = this.row(`SELECT timestamp FROM ereader_progress WHERE document = ?`, doc);
    if (cur && cur.timestamp > p.timestamp) return;
    this.run(`INSERT OR REPLACE INTO ereader_progress (document, progress, percentage, device, device_id, timestamp) VALUES (?, ?, ?, ?, ?, ?)`,
      doc, String(p.progress).slice(0, 2048), Number(p.percentage) || 0, String(p.device ?? 'Habla').slice(0, 60),
      String(p.device_id ?? 'habla').slice(0, 60), Math.floor(Number(p.timestamp) || 0));
  }

  opds() {
    const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    const iso = (t) => new Date(t).toISOString();
    const entries = this.rows(`SELECT s.* FROM shelf s JOIN books b ON b.key = s.key WHERE b.deleted_at IS NULL ORDER BY s.title`).map((b) => `
  <entry>
    <title>${esc(b.title || 'Book')}</title>
    <id>urn:habla:${b.key}</id>
    <updated>${iso(b.at)}</updated>
    <link rel="http://opds-spec.org/acquisition" href="/opds/books/${b.key}.epub" type="application/epub+zip" length="${b.size}"/>
  </entry>`).join('');
    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
  <id>urn:habla:library</id>
  <title>Habla</title>
  <updated>${iso(Date.now())}</updated>
  <link rel="self" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
  <link rel="start" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>${entries}
</feed>`;
    return new Response(xml, { headers: { 'content-type': 'application/atom+xml;profile=opds-catalog;kind=acquisition' } });
  }

  online(id, now) {
    if (this.ctx.getWebSockets(id).length > 0) return true;
    const d = this.row(`SELECT last_seen FROM devices WHERE id = ?`, id);
    return !!d && now - d.last_seen < ONLINE_MS;
  }

  notify(from) {
    for (const ws of this.ctx.getWebSockets()) {
      if (!this.ctx.getTags(ws).includes(from)) { try { ws.send('changed'); } catch {} }
    }
  }

  // Deletes chunks from R2 and the storage ledger (the account counts them toward the caps).
  async dropBlobs(names) {
    const space = this.row(`SELECT v FROM meta WHERE k = 'space'`)?.v;
    if (!space || !names?.length) return;
    for (const n of names) {
      if (!NAME.test(n)) continue;
      await this.env.BRIDGE?.delete(`${space}/transit/${n}`);
      await this.env.DB?.prepare(`DELETE FROM objects WHERE space = ?1 AND kind = 'transit' AND name = ?2`).bind(space, n).run();
    }
  }

  async dropShelf(key) {
    const space = this.row(`SELECT v FROM meta WHERE k = 'space'`)?.v;
    if (space) {
      await this.env.BRIDGE?.delete(`${space}/shelf/${key}`);
      await this.env.DB?.prepare(`DELETE FROM objects WHERE space = ?1 AND kind = 'shelf' AND name = ?2`).bind(space, key).run();
    }
    this.run(`DELETE FROM shelf WHERE key = ?`, key);
  }

  async remove(id) {
    if (!DEVICE.test(id)) return;
    for (const t of ['holdings', 'declined', 'requests']) this.run(`DELETE FROM ${t} WHERE device = ?`, id);
    this.run(`DELETE FROM places WHERE device = ?`, id);
    this.run(`DELETE FROM devices WHERE id = ?`, id);
    this.run(`UPDATE books SET narrator = NULL WHERE narrator = ?`, id);
    for (const ws of this.ctx.getWebSockets(id)) { try { ws.close(4001, 'removed'); } catch {} }
  }

  async sync(id, r) {
    const now = Date.now();
    const str = (v, max = 65536) => (typeof v === 'string' && v.length <= max ? v : null);
    const int = (v) => (Number.isFinite(v) ? Math.max(0, Math.floor(v)) : 0);
    const before = this.fingerprint();
    const narrator = r.narrator && Number(r.narrator.sps) > 0
      ? JSON.stringify({ sps: Number(r.narrator.sps), queued: int(r.narrator.queued) }) : null;
    const kind = r.kind === 'phone' ? 'phone' : 'mac';
    this.run(`INSERT INTO devices (id, kind, info, narrator, last_seen, joined) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, info = COALESCE(excluded.info, info),
      narrator = excluded.narrator, last_seen = excluded.last_seen`, id, kind, str(r.info, 16384), narrator, now, now);

    for (const a of Array.isArray(r.added) ? r.added : []) {
      if (!NAME.test(a?.key ?? '')) continue;
      const at = Math.min(int(a.at), now);
      const b = this.row(`SELECT deleted_at, added_at FROM books WHERE key = ?`, a.key);
      if (!b) {
        this.run(`INSERT INTO books (key, meta, sentences, narratable, added_at) VALUES (?, ?, ?, ?, ?)`,
          a.key, str(a.meta, 8192), int(a.sentences), a.narratable ? 1 : 0, at);
      } else if (b.deleted_at != null && at > b.deleted_at) {          // added again after a delete
        this.run(`UPDATE books SET deleted_at = NULL, meta = ?, sentences = ?, narratable = ?, added_at = ? WHERE key = ?`,
          str(a.meta, 8192), int(a.sentences), a.narratable ? 1 : 0, at, a.key);
      } else if (b.deleted_at == null) {
        this.run(`UPDATE books SET meta = COALESCE(meta, ?) WHERE key = ?`, str(a.meta, 8192), a.key);
      }
    }
    for (const d of Array.isArray(r.deleted) ? r.deleted : []) {
      if (!NAME.test(d?.key ?? '')) continue;
      const at = Math.min(int(d.at), now);
      const b = this.row(`SELECT deleted_at, added_at FROM books WHERE key = ?`, d.key);
      if (!b) this.run(`INSERT INTO books (key, added_at, deleted_at) VALUES (?, 0, ?)`, d.key, at);
      else if (b.deleted_at == null && at >= b.added_at) this.run(`UPDATE books SET deleted_at = ? WHERE key = ?`, at, d.key);
    }

    // What this device holds now (the whole list each time).
    this.run(`DELETE FROM holdings WHERE device = ?`, id);
    for (const h of Array.isArray(r.books) ? r.books : []) {
      if (!NAME.test(h?.key ?? '')) continue;
      this.run(`INSERT OR REPLACE INTO holdings (key, device, epub, ready, left_) VALUES (?, ?, ?, ?, ?)`,
        h.key, id, h.epub ? 1 : 0, int(h.ready), int(h.left));
    }
    if (Array.isArray(r.declined)) {
      this.run(`DELETE FROM declined WHERE device = ?`, id);
      for (const k of r.declined) if (NAME.test(k)) this.run(`INSERT OR IGNORE INTO declined (key, device) VALUES (?, ?)`, k, id);
    }
    for (const k of Array.isArray(r.requested) ? r.requested : []) {
      if (!NAME.test(k)) continue;
      this.run(`INSERT OR IGNORE INTO requests (key, device) VALUES (?, ?)`, k, id);
      this.run(`UPDATE books SET audio_dropped = 0 WHERE key = ?`, k);
    }
    for (const u of Array.isArray(r.uploaded) ? r.uploaded : []) {
      const b = NAME.test(u?.key ?? '') && this.row(`SELECT * FROM books WHERE key = ? AND deleted_at IS NULL`, u.key);
      const names = Array.isArray(u?.names) ? u.names.filter((n) => NAME.test(n)) : [];
      if (!b || !str(u.pack)) { await this.dropBlobs(names); continue; }
      const keep = new Set(names);
      if (u.kind === 'epub') {
        await this.dropBlobs(JSON.parse(b.epub_names ?? '[]').filter((n) => !keep.has(n)));
        this.run(`UPDATE books SET epub_pack = ?, epub_names = ?, epub_at = ?, epub_by = NULL, epub_asked = NULL WHERE key = ?`,
          u.pack, JSON.stringify(names), now, u.key);
      } else if (u.kind === 'audio') {
        await this.dropBlobs(JSON.parse(b.audio_names ?? '[]').filter((n) => !keep.has(n)));
        this.run(`UPDATE books SET audio_pack = ?, audio_names = ?, audio_ready = ?, audio_at = ?,
          audio_first = COALESCE(audio_first, ?), audio_by = NULL, audio_asked = NULL, audio_dropped = 0 WHERE key = ?`,
          u.pack, JSON.stringify(names), int(u.ready), now, now, u.key);
        this.run(`DELETE FROM requests WHERE key = ?`, u.key);
      }
    }
    for (const p of Array.isArray(r.ereader) ? r.ereader : []) {
      if (typeof p?.document === 'string' && typeof p.progress === 'string') this.putProgress(p);
    }
    if (str(r.places, 1048576)) {
      const v = (this.row(`SELECT version FROM places WHERE device = ?`, id)?.version ?? 0) + 1;
      this.run(`INSERT OR REPLACE INTO places (device, version, data) VALUES (?, ?, ?)`, id, v, r.places);
    }
    for (const field of ['voice', 'name']) {
      const s = r.settings?.[field];
      if (!s || !str(s.data, 8192)) continue;
      const at = Math.min(int(s.at), now);
      const cur = this.row(`SELECT at FROM settings WHERE field = ?`, field);
      if (!cur || at > cur.at) this.run(`INSERT OR REPLACE INTO settings (field, data, at) VALUES (?, ?, ?)`, field, s.data, at);
    }

    await this.plan(now);
    if (this.fingerprint() !== before) this.notify(id);
    return this.view(id, r.seen ?? {}, now);
  }

  // A cheap summary of everything another device would care about (not last_seen).
  fingerprint() {
    const parts = [
      this.rows(`SELECT key, deleted_at, narrator, epub_at, audio_at, audio_ready FROM books ORDER BY key`),
      this.rows(`SELECT key, device, epub, ready, left_ FROM holdings ORDER BY key, device`),
      this.rows(`SELECT device, version FROM places ORDER BY device`),
      this.rows(`SELECT field, at FROM settings ORDER BY field`),
      this.rows(`SELECT id, info FROM devices ORDER BY id`),
      this.rows(`SELECT document, timestamp FROM ereader_progress ORDER BY document`),
      this.rows(`SELECT key FROM shelf ORDER BY key`),
    ];
    return JSON.stringify(parts);
  }

  // The account's decisions: who narrates each book, what goes up, what comes down.
  async plan(now) {
    const devices = this.rows(`SELECT * FROM devices`);
    const byId = Object.fromEntries(devices.map((d) => [d.id, d]));
    const online = new Set(devices.filter((d) => this.online(d.id, now)).map((d) => d.id));
    const expected = devices.filter((d) => now - d.last_seen < EXPECTED_MS).map((d) => d.id);
    const queue = Object.fromEntries(devices.map((d) => [d.id, d.narrator ? JSON.parse(d.narrator) : null]));
    const books = this.rows(`SELECT * FROM books`);

    // Deleted books: nothing of them stays in transit; tombstones go after 30 days.
    for (const b of books.filter((b) => b.deleted_at != null)) {
      await this.dropBlobs([...JSON.parse(b.epub_names ?? '[]'), ...JSON.parse(b.audio_names ?? '[]')]);
      this.run(`UPDATE books SET epub_pack = NULL, epub_names = NULL, audio_pack = NULL, audio_names = NULL, narrator = NULL WHERE key = ?`, b.key);
      if (this.row(`SELECT key FROM shelf WHERE key = ?`, b.key)) {
        await this.dropShelf(b.key);
      }
      if (now - b.deleted_at > EXPECTED_MS) this.run(`DELETE FROM books WHERE key = ?`, b.key);
    }
    const live = books.filter((b) => b.deleted_at == null).sort((a, b) => a.added_at - b.added_at);
    const holdings = this.rows(`SELECT * FROM holdings`);
    const declined = this.rows(`SELECT * FROM declined`);
    const requests = this.rows(`SELECT * FROM requests`);
    const macsOnline = [...online].filter((id) => byId[id]?.kind === 'mac' && queue[id]);
    const ereaderOn = this.row(`SELECT v FROM meta WHERE k = 'ereader'`)?.v === '1';

    for (const b of live) {
      const held = holdings.filter((h) => h.key === b.key);
      const holder = (id) => held.find((h) => h.device === id);
      const need = expected.filter((id) => !declined.some((x) => x.key === b.key && x.device === id));
      const best = held.reduce((m, h) => Math.max(m, h.ready), 0);
      // `left` is sentences still to narrate on that device; a copy with none left is done.
      const done = held.some((h) => h.left_ === 0 && h.ready > 0);
      const set = (q, ...a) => this.run(`UPDATE books SET ${q} WHERE key = ?`, ...a, b.key);

      // Narration.
      if (!b.narratable || done) {
        if (b.narrator) set(`narrator = NULL, narrator_at = NULL`);
      } else {
        const cur = b.narrator && byId[b.narrator];
        const away = cur && !online.has(cur.id) && now - cur.last_seen > NARRATOR_GRACE_MS;
        const phoneWhileMac = cur && cur.kind === 'phone' && macsOnline.length > 0;
        if (!cur || away || phoneWhileMac || !queue[cur.id]) {
          const pool = macsOnline.length ? macsOnline : [...online].filter((id) => queue[id]);
          let pick = null, finish = Infinity;
          for (const id of pool) {
            const q = queue[id];
            const left = holder(id)?.left_ || b.sentences;
            const t = (q.queued + left) / Math.max(0.01, q.sps);
            if (t < finish) { finish = t; pick = id; }
          }
          if (pick) {
            queue[pick] = { ...queue[pick], queued: queue[pick].queued + b.sentences };
            set(`narrator = ?, narrator_at = ?`, pick, now);
          } else if (cur && away) set(`narrator = NULL, narrator_at = NULL`);
        }
      }

      // The EPUB: up while anyone lacks it, gone once everyone has it.
      const lackEpub = need.filter((id) => !holder(id)?.epub);
      if (b.epub_pack && lackEpub.length === 0) {
        await this.dropBlobs(JSON.parse(b.epub_names ?? '[]'));
        set(`epub_pack = NULL, epub_names = NULL, epub_at = NULL`);
      } else if (!b.epub_pack && lackEpub.length > 0) {
        const holders = held.filter((h) => h.epub).map((h) => h.device);
        const inFlight = live.filter((x) => x.epub_pack).length;
        if (holders.length && inFlight < MAX_EPUBS) this.ask(b, 'epub', holders, online, byId, now);
      }

      // The Xteink's catalog: every book's EPUB, once an Xteink is set up for this account.
      if (ereaderOn && !this.row(`SELECT key FROM shelf WHERE key = ?`, b.key)) {
        const holders = held.filter((h) => h.epub).map((h) => h.device);
        if (holders.length) this.ask(b, 'shelf', holders, online, byId, now);
      }

      // The audio: up while anyone has less than the best copy.
      const lackAudio = need.filter((id) => (holder(id)?.ready ?? 0) < best);
      const coveredByPack = need.every((id) => (holder(id)?.ready ?? 0) >= (b.audio_pack ? b.audio_ready : best));
      if (b.audio_pack && coveredByPack) {
        await this.dropBlobs(JSON.parse(b.audio_names ?? '[]'));
        set(`audio_pack = NULL, audio_names = NULL, audio_ready = 0, audio_at = NULL`);
        b.audio_pack = null;
      } else if (best > 0 && lackAudio.length > 0 && (!b.audio_pack || b.audio_ready < best)) {
        const asked = requests.some((x) => x.key === b.key);
        const bestHolders = held.filter((h) => h.ready === best).map((h) => h.device);
        const stillNarrating = held.some((h) => h.ready === best && h.left_ > 0);
        const paced = b.audio_pack && stillNarrating && now - (b.audio_at ?? 0) < AUDIO_PACE_MS;
        if ((!b.audio_dropped || asked) && !paced) {
          if (!b.audio_pack) {
            const parked = live.filter((x) => x.audio_pack && x.key !== b.key).sort((x, y) => (x.audio_first ?? 0) - (y.audio_first ?? 0));
            while (parked.length >= MAX_AUDIO_BOOKS) {           // only 3 books' audio wait in the cloud
              const old = parked.shift();
              await this.dropBlobs(JSON.parse(old.audio_names ?? '[]'));
              this.run(`UPDATE books SET audio_pack = NULL, audio_names = NULL, audio_ready = 0, audio_at = NULL,
                audio_first = NULL, audio_dropped = 1 WHERE key = ?`, old.key);
              old.audio_pack = null;
            }
          }
          if (b.narrator && bestHolders.includes(b.narrator)) bestHolders.unshift(b.narrator);
          this.ask(b, 'audio', bestHolders, online, byId, now);
        }
      }
    }
  }

  // Asks one holder to upload (online first, a Mac before an iPhone); keeps the ask for 30 minutes.
  ask(b, kind, holders, online, byId, now) {
    const by = b[`${kind}_by`], asked = b[`${kind}_asked`] ?? 0;
    if (by && holders.includes(by) && now - asked < UPLOAD_GRACE_MS) return;
    const order = [...new Set(holders)].filter((id) => byId[id]).sort((x, y) =>
      (online.has(y) - online.has(x)) || ((byId[y].kind === 'mac') - (byId[x].kind === 'mac')));
    const pick = order.find((id) => id !== by || now - asked >= UPLOAD_GRACE_MS) ?? order[0];
    if (pick) this.run(`UPDATE books SET ${kind}_by = ?, ${kind}_asked = ? WHERE key = ?`, pick, now, b.key);
  }

  view(id, seen, now) {
    const holdings = this.rows(`SELECT * FROM holdings`);
    const books = this.rows(`SELECT * FROM books`).map((b) => ({
      key: b.key, meta: b.meta, sentences: b.sentences, narrator: b.narrator ?? null,
      ...(b.deleted_at != null ? { deletedAt: b.deleted_at } : {}),
      epub: b.epub_pack ? { pack: b.epub_pack, names: JSON.parse(b.epub_names ?? '[]') } : null,
      audio: b.audio_pack ? { pack: b.audio_pack, names: JSON.parse(b.audio_names ?? '[]'), ready: b.audio_ready } : null,
      holders: Object.fromEntries(holdings.filter((h) => h.key === b.key).map((h) => [h.device, { epub: !!h.epub, ready: h.ready, left: h.left_ }])),
    }));
    const tasks = { upload: [], narrate: [] };
    const ereaderOn = this.row(`SELECT v FROM meta WHERE k = 'ereader'`)?.v === '1';
    const onShelf = new Set(this.rows(`SELECT key FROM shelf`).map((r) => r.key));
    for (const b of this.rows(`SELECT key, epub_by, audio_by, shelf_by, narrator, deleted_at FROM books WHERE deleted_at IS NULL`)) {
      if (b.epub_by === id) tasks.upload.push({ key: b.key, kind: 'epub' });
      // The Xteink's catalog: any device holding the EPUB adds it (older versions ignore the task,
      // so one chosen device could keep the catalog empty).
      if (ereaderOn && !onShelf.has(b.key) && holdings.some((h) => h.key === b.key && h.device === id && h.epub)) {
        tasks.upload.push({ key: b.key, kind: 'shelf' });
      }
      if (b.audio_by === id) tasks.upload.push({ key: b.key, kind: 'audio' });
      if (b.narrator === id) tasks.narrate.push(b.key);
    }
    const places = this.rows(`SELECT * FROM places WHERE device != ?`, id)
      .filter((p) => (seen?.[p.device] ?? 0) < p.version).map((p) => ({ device: p.device, version: p.version, data: p.data }));
    const settings = Object.fromEntries(this.rows(`SELECT * FROM settings`).map((s) => [s.field, { data: s.data, at: s.at }]));
    const devices = this.rows(`SELECT * FROM devices`).map((d) => ({
      id: d.id, kind: d.kind, info: d.info, online: this.online(d.id, now), lastSeen: d.last_seen,
      narrator: d.narrator ? JSON.parse(d.narrator) : null,
    }));
    const ereader = this.rows(`SELECT * FROM ereader_progress`).map((p) => ({ document: p.document, progress: p.progress,
      percentage: p.percentage, device: p.device, timestamp: p.timestamp }));
    return { now, devices, books, places, settings, tasks, ereader, ereaderOn };
  }

  async webSocketMessage() {}
  async webSocketClose(ws, code) { try { ws.close(code === 1005 ? 1000 : code, 'bye'); } catch {} }
  async webSocketError() {}
}

export default {
  async fetch(request, env) {
    try { return await handle(request, env); } catch (e) { if (globalThis.process?.env?.BRIDGE_DEBUG) console.error(e); return fail(500, 'internal error'); }
  },
  async scheduled(_event, env, ctx) { ctx.waitUntil(scheduled(env)); },
};
export { scheduled as runCron };
