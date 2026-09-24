#!/usr/bin/env python3
"""Seviye README'sindeki her sorun bölümü, okuyana Grafana'da NEREYE bakacağını ve NE göreceğini söylüyor mu?

Kullanım: tools/lint-grafana.py <seviye-klasörü>   (çıkış 0 = temiz, 1 = hata; hatalar stdout'a)

EN: A problem section that names panels that do not exist ("DB CPU", "rps vs pod sayısı"), or no
    panel at all, leaves the reader asking someone where to look. Each `### PNN-XX` section must
    carry exactly one `**Grafana'da gör:**` block that either
      - links one or more dashboards (http://grafana.localtest.me/d/<uid>?var-level=lvlNN&from=now-…&to=now)
        whose uid exists, with the level preselected, followed by `- "<panel>" → <what you will see>`
        bullets whose panel names exist in those dashboards (or `- Explore'da: `<promql>` → …` when no
        panel shows it), or
      - says `Grafana'da görünmez` and points to the terminal evidence instead.
TR: Var olmayan panelleri ("DB CPU", "rps vs pod sayısı") anan ya da hiç panel anmayan bir sorun
    bölümü, okuyanı nereye bakacağını birine sormak zorunda bırakır. Her `### PNN-XX` bölümü
    tam bir `**Grafana'da gör:**` bloğu taşır: ya var olan dashboard'lara seviyesi seçili linkler +
    var olan panel adlarıyla `- "<panel>" → <ne göreceksin>` maddeleri, ya da `Grafana'da görünmez`
    ve kanıtın terminaldeki yeri.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DASH = ROOT / 'platform/dashboards/out'


def panels_of(obj):
    out = []
    for p in obj.get('panels', []):
        if p.get('title'):
            out.append(p['title'])
        out += panels_of(p)
    return out


dashboards = {}
for f in DASH.glob('*.json'):
    j = json.loads(f.read_text(encoding='utf-8'))
    dashboards[j['uid']] = set(panels_of(j))

LINK = re.compile(r'http://grafana\.localtest\.me/d/([a-z0-9-]+)\?([^)\s>]*)')

def main(level_dir):
    d = pathlib.Path(level_dir)
    if not d.is_absolute():
        d = ROOT / d
    lvl = d.name[:2]
    text = (d / 'README.md').read_text(encoding='utf-8')
    errs = []
    secs = re.split(r'\n(?=### P\d\d-\d\d)', text)[1:]
    for sec in secs:
        pid = sec[4:10]
        # bölüm bir sonraki "---" ya da "## " başlığında biter
        body = re.split(r'\n---\n|\n## ', sec)[0]
        if re.search(r'^\*\*Grafana:\*\*', body, re.M):
            errs.append(f'{pid}: tek satırlık "**Grafana:**" biçimi geçersiz — "**Grafana\'da gör:**" bloğunu kullan')
        blocks = [m.start() for m in re.finditer(r"^\*\*Grafana'da gör:\*\*", body, re.M)]
        if len(blocks) != 1:
            errs.append(f"{pid}: tam bir \"**Grafana'da gör:**\" bloğu olmalı (bulunan: {len(blocks)})")
            continue
        blk = body[blocks[0]:].split('\n\n')[0]
        if "Grafana'da görünmez" in blk:
            if '`' not in blk:
                errs.append(f"{pid}: 'Grafana'da görünmez' diyor ama terminal kanıtı (komut) vermiyor")
            continue
        links = LINK.findall(blk)
        if not links:
            errs.append(f'{pid}: dashboard linki yok (ya da "Grafana\'da görünmez" de)')
            continue
        linked = set()
        for uid, qs in links:
            if uid not in dashboards:
                errs.append(f'{pid}: dashboard yok: {uid}')
                continue
            linked.add(uid)
            if f'var-level=lvl{lvl}' not in qs:
                errs.append(f'{pid}: {uid} linkinde var-level=lvl{lvl} yok')
            if 'from=now-' not in qs:
                errs.append(f'{pid}: {uid} linkinde zaman aralığı (from=now-…) yok')
        allowed = set().union(*(dashboards[u] for u in linked)) if linked else set()
        bullets = [l for l in blk.split('\n')[1:] if l.lstrip().startswith('- "')]
        explore = [l for l in blk.split('\n')[1:] if l.lstrip().startswith("- Explore'da:")]
        for e in explore:
            if '`' not in e or '→' not in e:
                errs.append(f"{pid}: Explore maddesi `sorgu` → ne göreceksin biçiminde değil")
        if not bullets and not explore:
            errs.append(f'{pid}: panel maddesi yok — `- "<panel>" → <ne göreceksin>` ya da `- Explore\'da: `sorgu` → …`')
        for b in bullets:
            name = re.match(r'\s*- "([^"]+)"', b).group(1)
            if name not in allowed:
                errs.append(f'{pid}: panel "{name}" linklenen dashboard\'larda yok')
            if '→' not in b:
                errs.append(f'{pid}: "{name}" maddesinde "→ ne göreceksin" yok')
    for e in errs:
        print(f'  ✘ {d.name}: {e}')
    return 1 if errs else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
