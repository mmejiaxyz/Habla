// Habla cloud bridge (Docs/cloud-bridge.md): an encrypted mailbox for one person's devices.
// Everything stored here was sealed on a device; this Worker only checks a token hash,
// keeps the account inside Cloudflare's free tier, and moves bytes.

const NAME = /^[0-9a-f]{40}$/;
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
  const max = num(env, kind === 'state' ? 'MAX_STATE_BYTES' : 'MAX_TRANSIT_BYTES');
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

async function handle(request, env) {
  if (!(await take(env, day(), 'requests', num(env, 'REQUESTS_CAP_DAY')))) return fail(429, 'daily request cap reached', 'requests');
  const url = new URL(request.url);
  const parts = url.pathname.split('/').filter(Boolean);                   // ["v1", "state", name?]
  if (parts[0] !== 'v1') return fail(404, 'not found');

  if (parts[1] === 'spaces' && parts.length === 2 && request.method === 'POST') {
    if (!env.ENROLL_SECRET) return fail(503, 'enrollment not configured');
    if (!sameSecret(request.headers.get('x-habla-enroll') ?? '', env.ENROLL_SECRET)) return fail(403, 'forbidden');
    let body;
    try { body = await request.json(); } catch { return fail(400, 'bad json'); }
    if (!/^[0-9a-f]{64}$/.test(body?.tokenHash ?? '')) return fail(400, 'bad token hash');
    const r = await env.DB.prepare('INSERT OR IGNORE INTO spaces (id, created) VALUES (?1, ?2)').bind(body.tokenHash, Date.now()).run();
    return json({ ok: true }, r.meta?.changes ? 201 : 200);
  }

  const auth = request.headers.get('authorization') ?? '';
  if (!auth.startsWith('Bearer ') || auth.length < 20) return fail(401, 'unauthorized');
  const space = await sha256hex(auth.slice(7));
  if (!(await env.DB.prepare('SELECT 1 AS ok FROM spaces WHERE id = ?1').bind(space).first())) return fail(401, 'unauthorized');

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

export default {
  async fetch(request, env) {
    try { return await handle(request, env); } catch (e) { if (globalThis.process?.env?.BRIDGE_DEBUG) console.error(e); return fail(500, 'internal error'); }
  },
  async scheduled(_event, env, ctx) { ctx.waitUntil(scheduled(env)); },
};
export { scheduled as runCron };
