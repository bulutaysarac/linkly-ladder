// ÖLÇÜLDÜ: bu kümede redirect kapasitesi ~650 istek/s; 1000'lik bir tepe ölçüm değil yıkım
// üretir (probe'lar düşer, pod'lar restart eder, sonraki deneyler bozuk ortam bulur).
// Tepe 400 — HPA'nın gecikmesini göstermek için kapasiteyi AŞMAK gerekmez, hızlı YÜKSELMEK
// yeter. Üstüne çıkmak için: PEAK=1000 make repro P=P07-01
// burst — sessizlik, ani patlama, sessizlik. HPA gecikmesi (07), kuyruk taşması (05), pencere sınırı (08).
import { seedLinks, redirect, pick, summaryLine } from '../lib/ladder.js';
export const options = {
  scenarios: {
    burst: {
      executor: 'ramping-arrival-rate', startRate: 5, timeUnit: '1s', preAllocatedVUs: 50, maxVUs: 500,
      stages: [
        { target: 5,   duration: '20s' },
        { target: parseInt(__ENV.PEAK || '400', 10), duration: '5s' },
        { target: parseInt(__ENV.PEAK || '400', 10), duration: '20s' },
        { target: 5,   duration: '5s' },
        { target: 5,   duration: '20s' },
      ],
    },
  },
};
export function setup() { return { codes: seedLinks(parseInt(__ENV.SEED || '100', 10)) }; }
export default function (data) { redirect(pick(data.codes)); }
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
