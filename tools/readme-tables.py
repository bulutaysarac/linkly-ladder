#!/usr/bin/env python3
"""Seviye README §6 özet tablosunun "Grafana'da" sütununu, sorun bölümlerindeki "**Grafana'da gör:**"
bloklarından türetir — iki kaynak birbirinden ayrışmasın. Kullanım: tools/readme-tables.py [seviye …]  (argümansız: tüm seviyeler)."""
import re, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
LINK = re.compile(r'\[`(\d\d · [^`]+)`\]\((http://grafana\.localtest\.me/d/[^)]+)\)')
import sys
# Yalnızca VERİLEN seviyelere dokun: argümansız çalıştırmak 15 README'yi birden yeniden yazar ve aynı
# anda başka bir seviyeyi düzenleyen birinin değişikliğini ezebilir. Argümansız = hepsi.
targets = [ROOT / a.rstrip('/') for a in sys.argv[1:]] or sorted(ROOT.glob('[01][0-9]-*'))
for d in targets:
    p = d / 'README.md'; s = p.read_text(encoding='utf-8'); cells = {}
    for sec in re.split(r'\n(?=### P\d\d-\d\d)', s)[1:]:
        pid = sec[4:10]; i = sec.find("**Grafana'da gör:**")
        if i < 0: continue
        blk = sec[i:].split('\n\n')[0]; first = blk.split('\n')[0]
        if "Grafana'da görünmez" in first: cells[pid] = "görünmez — kanıt terminalde ↓"; continue
        c = ' · '.join(f'[{t}]({u})' for t, u in LINK.findall(first)[:2])
        panel = re.search(r'^\s*- "([^"]+)"', blk, re.M)
        c += f' → "{panel.group(1)}"' if panel else (' → Explore ↓' if "- Explore'da:" in blk else '')
        cells[pid] = c.replace('|', '\\|')
    a = s.index('## 6. '); b = s.index('\n### ', a); lines = s[a:b].split('\n'); hdr = None; out = []
    for ln in lines:
        if ln.startswith('| ID |'): hdr = [c.strip() for c in ln.strip('|').split('|')]
        m = re.match(r'^\| (P\d\d-\d\d) \|', ln)
        if m and hdr and "Grafana'da" in hdr and m.group(1) in cells:
            cols = [c.strip() for c in ln.strip().strip('|').split(' | ')]
            if len(cols) == len(hdr):
                cols[hdr.index("Grafana'da")] = cells[m.group(1)]; ln = '| ' + ' | '.join(cols) + ' |'
        out.append(ln)
    p.write_text(s[:a] + '\n'.join(out) + s[b:], encoding='utf-8')
print('§6 tabloları güncellendi')
