// hot-key — trafiğin HOT_SHARE'i (vars. %50) tek bir koda. Satır kilidi (02), Redis hot key (04), L1 (14).
import { seedLinks, redirect, pick, summaryLine } from '../lib/ladder.js';
export const options = {
  vus: parseInt(__ENV.VUS || '100', 10), duration: __ENV.DURATION || '60s',
};
const SHARE = parseFloat(__ENV.HOT_SHARE || '0.5');
export function setup() { const codes = seedLinks(parseInt(__ENV.SEED || '100', 10)); return { hot: codes[0], codes }; }
export default function (data) { redirect(Math.random() < SHARE ? data.hot : pick(data.codes)); }
export function handleSummary(data) { return { stdout: summaryLine(data) }; }
