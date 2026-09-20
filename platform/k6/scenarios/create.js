// create — sadece POST. Yazma yolu, kod üretimi, çakışma, bellek büyümesi.
import { createLink, summaryLine } from '../lib/ladder.js';
export const options = {
  vus: parseInt(__ENV.VUS || '50', 10), duration: __ENV.DURATION || '30s',
  thresholds: { http_req_failed: [{ threshold: 'rate<1', abortOnFail: false }] },
};
export default function () { createLink(); }
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
