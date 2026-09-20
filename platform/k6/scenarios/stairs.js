// stairs — kademeli artan rps. Kapasite ölçümü (14) ve HPA tepkisi (07).
import { seedLinks, redirect, pick, summaryLine } from '../lib/ladder.js';
export const options = {
  scenarios: {
    stairs: {
      executor: 'ramping-arrival-rate', startRate: 50, timeUnit: '1s', preAllocatedVUs: 100, maxVUs: 1000,
      stages: [100, 200, 400, 800, 1600].flatMap((r) => [{ target: r, duration: '10s' }, { target: r, duration: '30s' }]),
    },
  },
};
export function setup() { return { codes: seedLinks(parseInt(__ENV.SEED || '200', 10)) }; }
export default function (data) { redirect(pick(data.codes)); }
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
