// stairs — kademeli artan rps. Kapasite ölçümü (14) ve HPA tepkisi (07).
import { seedLinks, redirect, pick, summaryLine } from '../lib/ladder.js';
export const options = {
  scenarios: {
    stairs: {
      executor: 'ramping-arrival-rate', startRate: 25, timeUnit: '1s', preAllocatedVUs: 60, maxVUs: 400,
      // ÖLÇÜLDÜ: bu kümede tek seviyenin redirect kapasitesi ~650 istek/s. Kapasitenin çok
      // üstüne (ör. 1600'e) çıkan bir merdiven ölçüm değil YIKIM üretir: kuyruk büyür, probe'lar
      // zaman aşımına uğrar, pod'lar yeniden başlar ve ARDINDAN GELEN her script "ortam bozuk" der.
      // Yük, ölçtüğün sistemi ÖLDÜRMEMELİ; kapasiteyi bulmak için ona YAKLAŞMAK yeterli.
      // Gerekirse RATES ile üstüne çık: RATES=100,200,400,800 make repro P=...
      stages: (__ENV.RATES || '50,100,200,400').split(',')
        .map((r) => parseInt(r, 10))
        .flatMap((r) => [{ target: r, duration: '10s' }, { target: r, duration: '30s' }]),
    },
  },
};
export function setup() { return { codes: seedLinks(parseInt(__ENV.SEED || '200', 10)) }; }
export default function (data) { redirect(pick(data.codes)); }
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
