// read-your-writes — oluştur, HEMEN redirect et. 404 = RYW ihlali (replikasyon gecikmesi, 09).
import { createLink, redirect, summaryLine } from '../lib/ladder.js';
import { Counter } from 'k6/metrics';
const violations = new Counter('ryw_violations');
export const options = { vus: parseInt(__ENV.VUS || '10', 10), duration: __ENV.DURATION || '30s' };
export default function () {
  const c = createLink(); if (!c) return;
  const r = redirect(c);
  if (r.status === 404) violations.add(1);
}
export function handleSummary(data) {
  const v = data.metrics.ryw_violations ? data.metrics.ryw_violations.values.count : 0;
  return { stdout: summaryLine(data) + `ryw_violations=${v}\n` };
}
