// Fakes for the Worker's bindings: D1 and the Account object on node:sqlite, R2 in memory.
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { Account } from '../worker.js';

export function fakeD1() {
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

export function fakeR2(seed = {}) {
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

// The Account Durable Object on node:sqlite (ctx.storage.sql), one instance per account.
export function fakeAccounts(envRef) {
  const objects = new Map();
  return {
    idFromName: (n) => n,
    get(id) {
      if (!objects.has(id)) {
        const db = new DatabaseSync(':memory:');
        const sql = { exec: (q, ...args) => { const st = db.prepare(q); const rows = /^\s*(SELECT|INSERT|UPDATE|DELETE)/i.test(q) && /RETURNING|^\s*SELECT/i.test(q) ? st.all(...args) : (st.run(...args), []); return { toArray: () => rows }; } };
        const ctx = { storage: { sql }, getWebSockets: () => [], getTags: () => [], acceptWebSocket() {} };
        objects.set(id, new Account(ctx, envRef()));
      }
      const o = objects.get(id);
      return { fetch: (req) => o.fetch(req) };
    },
  };
}

export function env(over = {}) {
  let e;
  e = {
    ACCOUNT: fakeAccounts(() => e),
    DB: fakeD1(), BRIDGE: fakeR2(), PORTFOLIO: fakeR2({ a: 'x'.repeat(500) }), ENROLL_SECRET: 's3cret',
    STORAGE_CAP_BYTES: '1000', CLASS_A_CAP: '100', CLASS_B_CAP: '100', REQUESTS_CAP_DAY: '1000',
    TRANSIT_TTL_DAYS: '14', MAX_STATE_BYTES: '400', MAX_TRANSIT_BYTES: '800', MAX_SPACES: '8', ...over,
  };
  return e;
}

