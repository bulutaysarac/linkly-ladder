// Ortak k6 yardımcıları. Senaryolar seviyeyi bilmez: BASE_URL ve LEVEL env alır.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

// 5xx ile 404'ü AYIRMAK şart: merdivende ikisi bambaşka sorunlar.
//   5xx  → sunucu/altyapı kesintisi (rollout penceresi, çökme, bağımlılık arızası)
//   404  → uygulama "böyle bir link yok" diyor (bellek içi store kaybı, sharding, negatif önbellek)
// Tek bir http_req_failed oranı bu ikisini karıştırır ve yanlış sorunu "kanıtlar".
export const http5xx = new Counter('http_5xx');
export const http404 = new Counter('http_404');
export const http429 = new Counter('http_429');

function classify(res) {
  if (res.status >= 500 || res.status === 0) http5xx.add(1);
  else if (res.status === 404) http404.add(1);
  else if (res.status === 429) http429.add(1);
  return res;
}

export const BASE = __ENV.BASE_URL || 'http://lvl00.localtest.me';
export const LEVEL = __ENV.LEVEL || 'unknown';
export const TENANT = __ENV.TENANT || 't1';
const URL_SIZE = parseInt(__ENV.URL_SIZE || '0', 10);

// 13'ten itibaren yazma ucu Bearer anahtar istiyor; anahtar boşsa başlık hiç gönderilmez.
// Kiracıyı artık ANAHTAR belirler — X-Tenant-ID yalnızca 13 öncesinde (ve P13-01'in tuzağında)
// dikkate alınır. İkisini de göndermek bilinçli: merdiven aynı senaryoyu 00'dan 14'e koşturuyor.
export const API_KEY = __ENV.API_KEY || '';
// 08'den itibaren yük testi kimliği: limiter bu jetonu taşıyan isteği saymaz (bkz. <seviye>/deploy/
// loadtest.yaml). Jetonu k6run.sh kümeden okur; limiter'ı SINAYAN scriptlerde (limits_enforced)
// boş gelir ve başlık hiç gönderilmez — o scriptler herkese açık bir istemci gibi davranmalı.
export const LOADTEST_TOKEN = __ENV.LOADTEST_TOKEN || '';
export const LOADTEST_HDR = LOADTEST_TOKEN ? { 'X-Ladder-Loadtest': LOADTEST_TOKEN } : {};
export function headers(extra = {}) {
  const auth = API_KEY ? { Authorization: `Bearer ${API_KEY}` } : {};
  return { 'Content-Type': 'application/json', 'X-Tenant-ID': TENANT, ...auth, ...LOADTEST_HDR, ...extra };
}

let seq = 0;
export function targetUrl() {
  seq++;
  const base = `https://example.com/${__VU}/${seq}`;
  if (URL_SIZE > base.length) return base + '?p=' + 'x'.repeat(URL_SIZE - base.length - 3);
  return base;
}

// Link oluştur, kodu döndür (null = başarısız). tags.name ile URL grouping — kardinalite patlamasın.
export function createLink(url = targetUrl(), extraHeaders = {}) {
  const res = http.post(`${BASE}/api/links`, JSON.stringify({ url }), {
    headers: headers(extraHeaders), tags: { name: 'POST /api/links' },
  });
  const ok = check(classify(res), { 'create 201': (r) => r.status === 201 });
  if (!ok) return null;
  try { return res.json('code'); } catch (e) { return null; }
}

// Redirect'i takip ETME: 30x'in kendisini ölçüyoruz.
export function redirect(code, extraHeaders = {}) {
  const res = http.get(`${BASE}/${code}`, {
    redirects: 0, headers: { ...LOADTEST_HDR, ...extraHeaders }, tags: { name: 'GET /{code}' },
  });
  check(classify(res), { 'redirect 30x': (r) => r.status >= 300 && r.status < 400 });
  return res;
}

export function getMeta(code) {
  return http.get(`${BASE}/api/links/${code}`, { headers: headers(), tags: { name: 'GET /api/links/{code}' } });
}

// Isınma: N link oluşturup kodlarını döndürür (setup() içinde kullanılır).
//
// SEED_BUDGET_MS — setup'ın ZAMAN BÜTÇESİ. Neden var:
// EN: The setup phase is subject to the very fault the experiment injects. With a 2s database
//     delay, seeding 500 links takes 1000s: k6's setupTimeout fires, the run is aborted and the
//     load never happens — while the repro script happily reports "not reproduced". The bug was
//     never in the system under test, it was in the experiment's own preparation.
// TR: Kurulum aşaması, deneyin enjekte ettiği arızaya TABİDİR. 2 sn'lik bir veritabanı gecikmesinde
//     500 link oluşturmak 1000 sn sürer: k6'nın setupTimeout'u devreye girer, koşu iptal olur ve
//     yük hiç çalışmaz — reproduce scripti ise memnuniyetle "reproduce olmadı" der. Hata test
//     edilen sistemde değil, deneyin kendi hazırlığındaydı. Bütçe dolunca elde ne varsa onunla devam.
export function seedLinks(n, budgetMs = parseInt(__ENV.SEED_BUDGET_MS || '30000', 10)) {
  const codes = [];
  const t0 = Date.now();
  for (let i = 0; i < n; i++) {
    const c = createLink();
    if (c) codes.push(c);
    if (Date.now() - t0 > budgetMs) {
      console.log(`seed: zaman bütçesi doldu (${budgetMs}ms), ${codes.length}/${n} kod ile devam`);
      break;
    }
  }
  if (codes.length === 0) throw new Error(`seed: hiç link oluşturulamadı (${BASE})`);
  return codes;
}

export function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

// Özet: konsola tek satır + summary-export (k6 CLI bayrağıyla) — REPRODUCE scriptleri bunu okur.
export function summaryLine(data) {
  const m = data.metrics;
  const v = (k, s) => (m[k] && m[k].values && m[k].values[s] !== undefined) ? m[k].values[s] : NaN;
  const c = (k) => (m[k] && m[k].values ? (m[k].values.count || 0) : 0);
  return `k6 ${LEVEL}: reqs=${v('http_reqs','count')} failed=${(v('http_req_failed','rate')*100).toFixed(2)}% ` +
         `5xx=${c('http_5xx')} 404=${c('http_404')} 429=${c('http_429')} ` +
         `p95=${v('http_req_duration','p(95)').toFixed(1)}ms p99=${v('http_req_duration','p(99)').toFixed(1)}ms\n`;
}
