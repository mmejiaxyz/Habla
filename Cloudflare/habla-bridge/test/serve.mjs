// Runs the real Worker on localhost with fake bindings, for the Swift tests:
//   node test/serve.mjs <port>   (prints "listening <port>")
// Not part of `node --test` (no test() inside).
import http from 'node:http';
import worker from '../worker.js';
import { env } from './fakes.mjs';

const e = env({ STORAGE_CAP_BYTES: String(4 * 1024 ** 3), CLASS_A_CAP: '100000', CLASS_B_CAP: '100000',
  REQUESTS_CAP_DAY: '100000', MAX_STATE_BYTES: '1048576', MAX_TRANSIT_BYTES: '16777216' });
const server = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;
  const headers = Object.fromEntries(Object.entries(req.headers).filter(([, v]) => typeof v === 'string'));
  const r = await worker.fetch(new Request(`http://localhost${req.url}`, { method: req.method, headers,
    body: ['GET', 'HEAD'].includes(req.method) ? undefined : body }), e);
  const out = Buffer.from(await r.arrayBuffer());
  res.writeHead(r.status, { ...Object.fromEntries(r.headers), 'content-length': String(out.length) });
  res.end(out);
});
server.listen(Number(process.argv[2] ?? 0), '127.0.0.1', () => console.log(`listening ${server.address().port}`));
