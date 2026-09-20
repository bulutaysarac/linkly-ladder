// abuser — 1 "kötü" client (sabit IP/tenant, açgözlü) + N normal client. Normal client'ın p99'u ne oluyor?
import { seedLinks, redirect, pick, summaryLine } from '../lib/ladder.js';
import { Trend } from 'k6/metrics';
const normalLatency = new Trend('normal_client_latency', true);
export const options = {
  scenarios: {
    abuser: { executor: 'constant-vus', vus: parseInt(__ENV.ABUSER_VUS || '50', 10), duration: __ENV.DURATION || '60s', exec: 'abuser' },
    normal: { executor: 'constant-arrival-rate', rate: 20, timeUnit: '1s', duration: __ENV.DURATION || '60s', preAllocatedVUs: 10, exec: 'normal' },
  },
};
export function setup() { return { codes: seedLinks(50) }; }
export function abuser(data) { redirect(pick(data.codes), { 'X-Forwarded-For': '203.0.113.66', 'X-Tenant-ID': 'abuser' }); }
export function normal(data) {
  const ip = `198.51.100.${1 + Math.floor(Math.random() * 200)}`;
  const r = redirect(pick(data.codes), { 'X-Forwarded-For': ip, 'X-Tenant-ID': 'normal' });
  normalLatency.add(r.timings.duration);
}
export function handleSummary(data) {
  const n = data.metrics.normal_client_latency; const p99 = n ? n.values['p(99)'].toFixed(1) : 'n/a';
  return { stdout: summaryLine(data) + `normal client p99=${p99}ms\n` };
}
