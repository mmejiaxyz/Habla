// node --test Cloudflare/habla-bridge/test/
// Guards what matters: caps refuse BEFORE touching R2 (never the paid tier), storage counts
// Portfolio, only enrolled tokens get in, and bytes come back unchanged.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import worker, { runCron } from '../worker.js';

function fakeD1() {
  const db = new DatabaseSync(':memory:');
  db.exec(readFileSync(new URL('../schema.sql', import.meta.url), 'utf8'));
  // D1 binds ?1..?N by number; node:sqlite only by name, so ?N becomes :pN.
  const named = (sql) => sql.replace(/\?(\d+)/g, ':p$1');
  const params = (args) => Object.fromEntries(args.map((v, i) => [`p${i + 1}`, v]));
  const stmt = (sql, args = []) => {
    const q = () => db.prepare(named(sql));
    const used = (sql.match(/\?(\d+)/g) ?? []).length ? [params(args)] : [];
    return {
      bind: (...a) => stmt(sql, a),
      first: async () => q().get(...used) ?? null,
      all: async () => ({ results: q().all(...used) }),
      run: async () => { const r = q().run(...used); return { meta: { changes: r.changes } }; },
    };
  };
  return { db, prepare: (sql) => stmt(sql), batch: async (s) => { for (const x of s) await x.run(); } };
}

function fakeR2(seed = {}) {
  const m = new Map(Object.entries(seed).map(([k, v]) => [k, Buffer.from(v)]));
  const calls = [];
  let n = 0;
  return {
    m, calls,
    async put(key, body) {
      calls.push('put');
      const buf = body instanceof Uint8Array ? Buffer.from(body) : Buffer.from(await new Response(body).arrayBuffer());
      m.set(key, buf);
      return { size: buf.length, etag: `e${++n}` };
    },
    async get(key) { calls.push('get'); const b = m.get(key); return b && { body: b, size: b.length, etag: 'x' }; },
    async delete(key) { m.delete(key); },
    async list() { calls.push('list'); return { objects: [...m].map(([key, b]) => ({ key, size: b.length })), truncated: false }; },
  };
}

function env(over = {}) {
  return {
    DB: fakeD1(), BRIDGE: fakeR2(), PORTFOLIO: fakeR2({ a: 'x'.repeat(500) }), ENROLL_SECRET: 's3cret',
    STORAGE_CAP_BYTES: '1000', CLASS_A_CAP: '100', CLASS_B_CAP: '100', REQUESTS_CAP_DAY: '1000',
    TRANSIT_TTL_DAYS: '14', MAX_STATE_BYTES: '400', MAX_TRANSIT_BYTES: '800', ...over,
  };
}

const TOKEN = 'token-' + 'a'.repeat(40);
const NAME = 'f'.repeat(40);
const call = (e, method, path, { body, headers = {}, token = TOKEN } = {}) => worker.fetch(new Request('https://b' + path, {
  method, body,
  headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body != null ? { 'content-length': String(body.length) } : {}), ...headers },
}), e);
async function enrolled(over) {
  const e = env(over);
  const hash = createHash('sha256').update(TOKEN).digest('hex');
  const r = await call(e, 'POST', '/v1/spaces', { body: JSON.stringify({ tokenHash: hash }), headers: { 'x-habla-enroll': 's3cret' }, token: null });
  assert.equal(r.status, 201);
  return e;
}

test('only enrolled tokens, and enrolling needs the secret', async () => {
  const e = env();
  const hash = createHash('sha256').update(TOKEN).digest('hex');
  assert.equal((await call(e, 'POST', '/v1/spaces', { body: JSON.stringify({ tokenHash: hash }), headers: { 'x-habla-enroll': 'nope' }, token: null })).status, 403);
  assert.equal((await call(env({ ENROLL_SECRET: undefined }), 'POST', '/v1/spaces', { body: '{}', token: null })).status, 503);
  assert.equal((await call(e, 'GET', '/v1/state')).status, 401);
  const ok = await enrolled();
  assert.equal((await call(ok, 'GET', '/v1/state', { token: 'other-' + 'b'.repeat(40) })).status, 401);
  assert.equal((await call(ok, 'PUT', '/v1/state/Not-A-Hash', { body: 'x' })).status, 400);
});

test('bytes round-trip; unchanged documents cost no read', async () => {
  const e = await enrolled();
  const put = await call(e, 'PUT', `/v1/state/${NAME}`, { body: 'sealed-bytes' });
  assert.equal(put.status, 200);
  const { etag } = await put.json();
  const list = await (await call(e, 'GET', '/v1/state', { headers: { 'x-habla-device': NAME } })).json();
  assert.deepEqual(list.map((o) => [o.name, o.size]), [[NAME, 12]]);
  assert.ok(list[0].seen, 'listing is the check-in');
  assert.equal(await (await call(e, 'GET', `/v1/state/${NAME}`)).text(), 'sealed-bytes');
  const reads = e.BRIDGE.calls.filter((c) => c === 'get').length;
  assert.equal((await call(e, 'GET', `/v1/state/${NAME}`, { headers: { 'if-none-match': `"${etag}"` } })).status, 304);
  assert.equal(e.BRIDGE.calls.filter((c) => c === 'get').length, reads);
  await call(e, 'DELETE', `/v1/state/${NAME}`);
  assert.equal(e.BRIDGE.m.size, 0);
});

test('storage cap counts Portfolio and refuses before uploading', async () => {
  const e = await enrolled();
  await runCron(e);                                            // measures portfolio-media: 500 bytes
  const big = 'x'.repeat(501);                                 // 500 + 501 > 1000
  const before = e.BRIDGE.calls.length;
  const r = await call(e, 'PUT', `/v1/transit/${NAME}`, { body: big });
  assert.equal(r.status, 507);
  assert.equal(e.BRIDGE.calls.length, before);
  assert.equal((await call(e, 'PUT', `/v1/transit/${NAME}`, { body: 'x'.repeat(500) })).status, 200);
  const u = await (await call(e, 'GET', '/v1/usage')).json();
  assert.equal(u.storageBytes + u.portfolioBytes, 1000);
  assert.equal(Number(e.DB.db.prepare(`SELECT value FROM meta WHERE key = 'reserved_bytes'`).get().value), 0);
  assert.equal((await call(e, 'PUT', `/v1/state/${'0'.repeat(40)}`, { body: 'x' })).status, 507);
});

test('operation and request caps refuse without touching R2', async () => {
  const e = await enrolled({ CLASS_A_CAP: '1', CLASS_B_CAP: '1', REQUESTS_CAP_DAY: '8' });
  assert.equal((await call(e, 'PUT', `/v1/state/${NAME}`, { body: 'a' })).status, 200);
  assert.equal((await call(e, 'PUT', `/v1/state/${NAME}`, { body: 'b' })).status, 429);
  assert.equal((await call(e, 'GET', `/v1/state/${NAME}`)).status, 200);
  assert.equal((await call(e, 'GET', `/v1/state/${NAME}`)).status, 429);
  assert.deepEqual(e.BRIDGE.calls, ['put', 'get']);
  assert.equal(Number(e.DB.db.prepare(`SELECT value FROM meta WHERE key = 'reserved_bytes'`).get().value), 0);
  while ((await call(e, 'GET', '/v1/usage')).status === 200);   // runs out the daily requests
  const r = await call(e, 'GET', '/v1/usage');
  assert.equal(r.status, 429);
  assert.equal((await r.json()).cap, 'requests');
});

test('cron deletes book chunks left too long', async () => {
  const e = await enrolled();
  await call(e, 'PUT', `/v1/transit/${NAME}`, { body: 'chunk' });
  e.DB.db.prepare('UPDATE objects SET updated = 0').run();
  await runCron(e);
  assert.equal(e.BRIDGE.m.size, 0);
  assert.equal((await (await call(e, 'GET', '/v1/transit')).json()).length, 0);
});
