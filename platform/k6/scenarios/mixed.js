// mixed — gerçekçi karışım: 1 create : 100 redirect (URL kısaltıcı okuma ağırlıklı).
import { seedLinks, createLink, redirect, pick, summaryLine } from '../lib/ladder.js';
export const options = {
  vus: parseInt(__ENV.VUS || '30', 10), duration: __ENV.DURATION || '60s',
};
export function setup() { return { codes: seedLinks(parseInt(__ENV.SEED || '500', 10)) }; }
export default function (data) {
  if (Math.random() < 0.01) { const c = createLink(); if (c) data.codes.push(c); }
  else redirect(pick(data.codes));
}
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
