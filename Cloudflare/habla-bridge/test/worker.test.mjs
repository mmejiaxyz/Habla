// node --test Cloudflare/habla-bridge/test/
// Guards what matters: caps refuse BEFORE touching R2 (never the paid tier), storage counts
// Portfolio, only enrolled tokens get in, and bytes come back unchanged.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker, { runCron } from '../worker.js';
import { env } from './fakes.mjs';

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
  for (let i = 0; i < 20; i++) await call(e, 'GET', '/v1/state', { token: 'junk-' + 'c'.repeat(40) });  // strangers don't spend the day
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


// ---- v2: the account ----

const dev = (c) => c.repeat(40);
const key = (c) => c.repeat(40);
const sync = async (e, device, report = {}) => {
  const r = await call(e, 'POST', '/v2/sync', { body: JSON.stringify(report), headers: { 'x-habla-device': device } });
  assert.equal(r.status, 200);
  return r.json();
};
const MAC_A = dev('a'), MAC_B = dev('b'), PHONE = dev('c');
const mac = (sps, extra = {}) => ({ kind: 'mac', narrator: { sps, queued: 0 }, ...extra });

test('join codes: made by a device of the account, work once, expire, never readable', async () => {
  const e = await enrolled();
  const id = 'd'.repeat(64);
  assert.equal((await call(e, 'POST', '/v2/codes', { body: JSON.stringify({ id, wrapped: 'sealed' }), token: 'x-' + 'z'.repeat(40) })).status, 401);
  assert.equal((await call(e, 'POST', '/v2/codes', { body: JSON.stringify({ id, wrapped: 'sealed' }) })).status, 201);
  const join = (i) => call(e, 'POST', '/v2/join', { body: JSON.stringify({ id: i }), token: null });
  const r = await join(id);
  assert.equal(r.status, 200);
  assert.equal((await r.json()).wrapped, 'sealed');
  assert.equal((await join(id)).status, 404, 'works once');
  await call(e, 'POST', '/v2/codes', { body: JSON.stringify({ id: 'e'.repeat(64), wrapped: 'w' }) });
  e.DB.db.prepare('UPDATE codes SET expires = 0').run();
  assert.equal((await join('e'.repeat(64))).status, 404, 'expired');
  for (const c of ['1', '2', '3']) await call(e, 'POST', '/v2/codes', { body: JSON.stringify({ id: c.repeat(64), wrapped: 'w' }) });
  assert.equal((await call(e, 'POST', '/v2/codes', { body: JSON.stringify({ id: '4'.repeat(64), wrapped: 'w' }) })).status, 429);
  // Creating accounts needs the server key, and accounts are capped.
  const make = (tok, secret = 's3cret') => call(e, 'POST', '/v2/accounts', {
    body: JSON.stringify({ tokenHash: createHash('sha256').update(tok).digest('hex') }), headers: { 'x-habla-enroll': secret }, token: null });
  assert.equal((await make('t-' + 'q'.repeat(40), 'wrong')).status, 403);
  assert.equal((await make('t-' + 'q'.repeat(40))).status, 201);
  assert.equal((await make(TOKEN)).status, 200, 'an existing account is fine');
});

test('a book added on one device is offered to all; its EPUB leaves the cloud once everyone has it', async () => {
  const e = await enrolled();
  await sync(e, PHONE, { kind: 'phone' });
  await sync(e, MAC_B, mac(1));
  const added = { key: key('1'), meta: 'sealed-meta', sentences: 900, narratable: false, at: Date.now() };
  let v = await sync(e, MAC_A, mac(1, { added: [added], books: [{ key: key('1'), epub: true, ready: 0, left: 0 }] }));
  assert.deepEqual(v.tasks.upload, [{ key: key('1'), kind: 'epub' }], 'the adder uploads the EPUB');
  await call(e, 'PUT', `/v1/transit/${NAME}`, { body: 'epub-chunk' });
  v = await sync(e, MAC_A, mac(1, { books: [{ key: key('1'), epub: true, ready: 0, left: 0 }],
    uploaded: [{ key: key('1'), kind: 'epub', names: [NAME], pack: 'sealed-pack' }] }));
  assert.deepEqual(v.tasks.upload, []);
  let p = await sync(e, PHONE, { kind: 'phone' });
  const b = p.books.find((x) => x.key === key('1'));
  assert.equal(b.meta, 'sealed-meta');
  assert.deepEqual(b.epub, { pack: 'sealed-pack', names: [NAME] });
  await sync(e, PHONE, { kind: 'phone', books: [{ key: key('1'), epub: true, ready: 0, left: 0 }] });
  assert.equal(e.BRIDGE.m.size, 1, 'Mac B still lacks it');
  await sync(e, MAC_B, mac(1, { books: [{ key: key('1'), epub: true, ready: 0, left: 0 }] }));
  assert.equal(e.BRIDGE.m.size, 0, 'everyone has it: the chunks are gone');
  assert.equal((await (await call(e, 'GET', '/v1/transit')).json()).length, 0, 'and the storage ledger with them');
});

test('the account picks the narrator: fastest online Mac, an iPhone only when no Mac is there', async () => {
  const e = await enrolled();
  const book = (k, sentences) => ({ key: key(k), meta: 'm', sentences, narratable: true, at: Date.now() });
  const has = (k, left) => ({ key: key(k), epub: true, ready: 0, left });
  await sync(e, MAC_B, mac(3));                                       // faster
  let a = await sync(e, MAC_A, mac(1, { added: [book('2', 600)], books: [has('2', 600)] }));
  assert.deepEqual(a.tasks.narrate, [], 'not the slower Mac');
  let bview = await sync(e, MAC_B, mac(3));
  assert.deepEqual(bview.tasks.narrate, [key('2')]);
  // A phone alone (no Mac with a voice online) narrates as a backup.
  const e2 = await enrolled();
  const ph = await sync(e2, PHONE, { kind: 'phone', narrator: { sps: 0.2, queued: 0 }, added: [book('3', 50)], books: [has('3', 50)] });
  assert.deepEqual(ph.tasks.narrate, [key('3')]);
  // A Mac comes online: the book moves to it.
  const m = await sync(e2, MAC_A, mac(1));
  assert.deepEqual(m.tasks.narrate, [key('3')]);
  assert.deepEqual((await sync(e2, PHONE, { kind: 'phone', narrator: { sps: 0.2, queued: 0 }, books: [has('3', 50)] })).tasks.narrate, []);
  // Narrated: chapters go up (the narrator holds the best copy), and nobody narrates it any more.
  const done = await sync(e2, MAC_A, mac(1, { books: [{ key: key('3'), epub: true, ready: 4, left: 0 }] }));
  assert.deepEqual(done.tasks.narrate, []);
  assert.ok(done.tasks.upload.some((t) => t.key === key('3') && t.kind === 'audio'));
});

test('deleting anywhere deletes everywhere; only 3 books of audio wait in the cloud', async () => {
  const e = await enrolled();
  const now = Date.now();
  await sync(e, PHONE, { kind: 'phone' });
  const books = ['5', '6', '7', '8'].map((k, i) => ({ key: key(k), meta: 'm', sentences: 10, narratable: false, at: now - 1000 + i }));
  const held = books.map((b) => ({ key: b.key, epub: true, ready: 3, left: 0 }));
  await sync(e, MAC_A, mac(1, { added: books, books: held }));
  for (const [i, b] of books.entries()) {
    const name = String(i).repeat(40);
    await call(e, 'PUT', `/v1/transit/${name}`, { body: 'audio' });
    await sync(e, MAC_A, mac(1, { books: held, uploaded: [{ key: b.key, kind: 'audio', names: [name], pack: 'p', ready: 3 }] }));
  }
  const v = await sync(e, PHONE, { kind: 'phone' });
  assert.equal(v.books.filter((b) => b.audio).length, 3, 'the oldest book was dropped from the cloud');
  assert.equal(v.books.find((b) => b.key === key('5')).audio, null);
  // The phone deletes a book: it's a tombstone for everyone, and its chunks go.
  const after = await sync(e, PHONE, { kind: 'phone', deleted: [{ key: key('8'), at: Date.now() }] });
  assert.ok(after.books.find((b) => b.key === key('8')).deletedAt);
  assert.ok(!e.BRIDGE.m.has(`${createHash('sha256').update(TOKEN).digest('hex')}/transit/${'3'.repeat(40)}`));
  // Adding the same EPUB again later brings it back.
  const back = await sync(e, MAC_A, mac(1, { added: [{ ...books[3], at: Date.now() + 1 }] }));
  assert.equal(back.books.find((b) => b.key === key('8')).deletedAt, undefined);
});

test('places and settings: sealed, newest wins, only what changed comes back', async () => {
  const e = await enrolled();
  await sync(e, MAC_A, mac(1, { places: 'mac-places', settings: { voice: { data: 'v-old', at: 1 } } }));
  let p = await sync(e, PHONE, { kind: 'phone', settings: { voice: { data: 'v-new', at: 2 }, name: { data: 'n', at: 2 } } });
  assert.deepEqual(p.places.map((x) => [x.device, x.data]), [[MAC_A, 'mac-places']]);
  assert.equal(p.settings.voice.data, 'v-new');
  p = await sync(e, PHONE, { kind: 'phone', seen: { [MAC_A]: p.places[0].version } });
  assert.deepEqual(p.places, [], 'nothing new');
  const m = await sync(e, MAC_A, mac(1, { settings: { voice: { data: 'stale', at: 1 } } }));
  assert.equal(m.settings.voice.data, 'v-new', 'an older change never wins');
  // Removing a device forgets it.
  await call(e, 'POST', '/v2/devices/remove', { body: JSON.stringify({ id: PHONE }), headers: { 'x-habla-device': MAC_A } });
  assert.ok(!(await sync(e, MAC_A, mac(1))).devices.some((d) => d.id === PHONE));
});
