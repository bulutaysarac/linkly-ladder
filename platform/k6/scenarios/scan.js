// scan — var olmayan rastgele kodlar. Negative cache (03), 404 limiti (13), enumeration.
import http from 'k6/http';
import { check } from 'k6';
import { BASE, summaryLine } from '../lib/ladder.js';
export const options = { vus: parseInt(__ENV.VUS || '20', 10), duration: __ENV.DURATION || '30s' };
const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
function randomCode(n) { let s = ''; for (let i = 0; i < n; i++) s += alphabet[Math.floor(Math.random() * 62)]; return s; }
export default function () {
  const r = http.get(`${BASE}/${randomCode(parseInt(__ENV.CODE_LEN || '7', 10))}`, { redirects: 0, tags: { name: 'GET /{code} (scan)' } });
  check(r, { '404': (x) => x.status === 404 });
}
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
