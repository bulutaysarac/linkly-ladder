// steady — mixed ile aynı karışım (1 create : 100 redirect), ama SABİT GELİŞ HIZIYLA (open model).
//
// EN: mixed is a closed model: N VUs, no think time, so the load it produces is whatever the system
//     can answer. That is fine while a limiter caps it, and wrong once the load test is exempt
//     (platform/lib/loadtest.sh): a fast system then receives MORE load than a slow one, the
//     generator saturates the 6-core VM, the API server starves and controllers lose their leader
//     leases — and the experiment measures the cluster collapsing. It also skews availability:
//     fast failures are over-counted because a VU that fails in 1 ms immediately fires again.
//     Production traffic does not slow down because you are slow. RATE is fixed; when the system
//     cannot keep up, k6 reports dropped_iterations instead of quietly generating less load.
//     Measured capacity on this cluster is ~650 rps (burst.js); the default stays well below it.
// TR: mixed kapalı bir modeldir: N VU, bekleme yok; ürettiği yük, sistemin cevaplayabildiği kadardır.
//     Bir limiter onu kısarken sorun yok; yük testi muaf olunca (platform/lib/loadtest.sh) yanlış:
//     hızlı bir sistem yavaş olandan DAHA FAZLA yük alır, üreteç 6 çekirdekli VM'i doyurur, API
//     sunucusu aç kalır, controller'lar lider kiralarını kaybeder ve deney kümenin çöküşünü ölçer.
//     Erişilebilirliği de çarpıtır: 1 ms'de başarısız olan VU hemen yeniden ateşler, hızlı hatalar
//     fazla sayılır. Üretim trafiği sen yavaşladın diye yavaşlamaz. RATE sabittir; sistem
//     yetişemezse k6 sessizce daha az yük üretmek yerine dropped_iterations raporlar.
//     Bu kümede ölçülen kapasite ~650 rps (burst.js); varsayılan bunun epey altında.
import { seedLinks, createLink, redirect, pick, summaryLine } from '../lib/ladder.js';
const RATE = parseInt(__ENV.RATE || '300', 10);
export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: __ENV.DURATION || '60s',
      // Gecikme arttıkça eşzamanlı istek sayısı artar (in-flight ≈ rps × gecikme): 300 rps × 200 ms = 60.
      preAllocatedVUs: parseInt(__ENV.VUS || '100', 10), maxVUs: parseInt(__ENV.MAX_VUS || '600', 10),
    },
  },
};
export function setup() { return { codes: seedLinks(parseInt(__ENV.SEED || '500', 10)) }; }
export default function (data) {
  if (Math.random() < 0.01) { const c = createLink(); if (c) data.codes.push(c); }
  else redirect(pick(data.codes));
}
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
