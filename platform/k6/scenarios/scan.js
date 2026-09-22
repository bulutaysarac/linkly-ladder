// scan — var olmayan rastgele kodlar. Negative cache (03), 404 limiti (13), enumeration.
import http from 'k6/http';
import { check } from 'k6';
import { BASE, summaryLine } from '../lib/ladder.js';
export const options = { vus: parseInt(__ENV.VUS || '20', 10), duration: __ENV.DURATION || '30s' };
const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
function randomCode(n) { let s = ''; for (let i = 0; i < n; i++) s += alphabet[Math.floor(Math.random() * 62)]; return s; }
// KEYS: SINIRLI bir "yok olan kod" havuzu. Varsayılan (0) sınırsızdır ve her istek YENİ bir kod
// üretir — bu, enumeration/tarama senaryosudur. Ama NEGATİF ÖNBELLEĞİN faydasını ölçmek için
// sınırsız havuz YANLIŞ bir yüktür: aynı eksik anahtar hiç tekrarlanmazsa önbellekte tutulacak
// bir cevap da yoktur, yani deney iddiasını sınayamaz (P03-06 tam olarak böyle ters sonuç verdi).
// EN: an unbounded pool never repeats a missing key, so a negative cache has nothing to serve —
// the wrong load for measuring it. KEYS=N replays N missing codes so the cache can actually hit.
export function setup() {
  const n = parseInt(__ENV.KEYS || '0', 10);
  const len = parseInt(__ENV.CODE_LEN || '7', 10);
  if (n <= 0) return { pool: null };
  const pool = [];
  for (let i = 0; i < n; i++) pool.push(randomCode(len));
  return { pool };
}
export default function (data) {
  const len = parseInt(__ENV.CODE_LEN || '7', 10);
  const pool = data && data.pool;
  const code = pool ? pool[Math.floor(Math.random() * pool.length)] : randomCode(len);
  const r = http.get(`${BASE}/${code}`, { redirects: 0, tags: { name: 'GET /{code} (scan)' } });
  check(r, { '404': (x) => x.status === 404 });
}
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
