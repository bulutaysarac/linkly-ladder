// abuser — 1 "kötü" client (açgözlü, sahte adres yazar) + N normal client. Normal client'ın p99'u ne oluyor?
//
// X-Forwarded-For'da NE VAR ve NEDEN (bkz. platform/manifests/ingress-nginx-config.yaml):
// EN: every virtual user here really comes from ONE address — the machine running k6. To stand in
//     for distinct clients, k6 also plays the trusted L7 load balancer in front of them: it writes
//     each client's "real" address as the LAST entry, and ingress-nginx appends what it saw.
//       abuser  → `<fake>, 203.0.113.66`: its real address never changes, and in FRONT of it the
//                 client injects a different fake on every request (198.18.0.0/15). A reader that
//                 counts trusted hops from the right never sees the fake; TRAP_TRUST_ANY_XFF,
//                 which trusts the first entry, gives it a new bucket per request.
//       normal  → `198.51.100.<n>`: one stable address per VU, never the abuser's.
//     A single fixed address for everyone would put all clients in one bucket and leave
//     "trust any" nothing to be fooled by.
// TR: buradaki her sanal kullanıcı gerçekte TEK bir adresten gelir — k6'yı koşan makineden. Ayrı
//     client'ları temsil etmek için k6, önlerindeki güvenilir L7 yük dengeleyiciyi de oynar: her
//     client'ın "gerçek" adresini listenin SONUNA yazar, ingress-nginx de gördüğünü ekler.
//       kötü    → `<sahte>, 203.0.113.66`: gerçek adresi hiç değişmez; ÖNÜNE her istekte başka bir
//                 sahte adres koyar (198.18.0.0/15). Sağdan güvenilir hop sayan okuyucu sahteyi hiç
//                 görmez; ilk girdiye güvenen TRAP_TRUST_ANY_XFF her istekte ona yeni bir kova verir.
//       normal  → `198.51.100.<n>`: sanal kullanıcı başına sabit, kötü client'ınkinden AYRI bir adres.
//     Herkes için tek bir sabit adres, bütün client'ları tek kovaya koyar ve "herkese güven"
//     tuzağına kanacağı bir şey bırakmaz.
import { seedLinks, redirect, pick, summaryLine } from '../lib/ladder.js';
import { Trend, Rate } from 'k6/metrics';
const normalLatency = new Trend('normal_client_latency', true);
// Sınırlanan = 429 (uygulama) ya da 503 (ingress'in kaba sınırı). Scriptler özet dosyasından okur.
const normalLimited = new Rate('normal_client_limited');
const abuserLimited = new Rate('abuser_limited');
const ABUSER_IP = '203.0.113.66';
export const options = {
  // p(99) k6'nın varsayılan özet istatistiklerinde YOK: `values['p(99)']` tanımsız döner ve
  // aşağıdaki .toFixed özeti patlatır. Hem ekrandaki satır hem özet dosyası için iste.
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: {
    abuser: { executor: 'constant-vus', vus: parseInt(__ENV.VUS || __ENV.ABUSER_VUS || '50', 10), duration: __ENV.DURATION || '60s', exec: 'abuser' },
    normal: { executor: 'constant-arrival-rate', rate: 20, timeUnit: '1s', duration: __ENV.DURATION || '60s', preAllocatedVUs: 10, exec: 'normal' },
  },
};
export function setup() { return { codes: seedLinks(50) }; }
export function abuser(data) {
  const fake = `198.18.${Math.floor(Math.random() * 256)}.${1 + Math.floor(Math.random() * 254)}`;
  const r = redirect(pick(data.codes), { 'X-Forwarded-For': `${fake}, ${ABUSER_IP}`, 'X-Tenant-ID': 'abuser' });
  abuserLimited.add(r.status === 429 || r.status === 503);
}
export function normal(data) {
  const r = redirect(pick(data.codes), { 'X-Forwarded-For': `198.51.100.${1 + (__VU % 250)}`, 'X-Tenant-ID': 'normal' });
  normalLatency.add(r.timings.duration);
  normalLimited.add(r.status === 429 || r.status === 503);
}
export function handleSummary(data) {
  const n = data.metrics.normal_client_latency;
  const p99 = n && n.values['p(99)'] !== undefined ? n.values['p(99)'].toFixed(1) : 'n/a';
  const pct = (m) => (m ? (m.values.rate * 100).toFixed(1) + '%' : 'n/a');
  return { stdout: summaryLine(data) + `normal client p99=${p99}ms · sınırlanan: normal=${pct(data.metrics.normal_client_limited)} kötü=${pct(data.metrics.abuser_limited)}\n` };
}
