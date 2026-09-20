// redirect — okuma yolu. setup'ta SEED kadar link oluşturur, sonra rastgele redirect.
import { seedLinks, redirect, pick, summaryLine } from '../lib/ladder.js';
export const options = {
  vus: parseInt(__ENV.VUS || '20', 10), duration: __ENV.DURATION || '60s',
};
export function setup() { return { codes: seedLinks(parseInt(__ENV.SEED || '200', 10)) }; }
export default function (data) { redirect(pick(data.codes)); }
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
