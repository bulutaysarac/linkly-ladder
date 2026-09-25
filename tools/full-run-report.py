#!/usr/bin/env python3
"""Tam tur raporu: tools/full-run.sh'in kaydından (runs.tsv) okunur bir RAPOR.md üretir.

Her adım için: ne koşuldu, hangi saatler arasında, sonuç ve scriptin hüküm cümlesi, tam çıktının
log dosyası ve o adımın saat aralığı linke gömülü Grafana linkleri (seviye README'sindeki
"Grafana'da gör" bloğundan). Linkler adımın başlangıcından 1 dk önce başlar, bitişinden 2 dk sonra
biter: küme metrikleri 30 sn'de bir toplanır ve paneller 1-2 dk'lık ortalama çizer.
Tur sürerken de çalıştırılabilir: o ana kadarki adımları raporlar.
Kullanım: tools/full-run-report.py reports/tam-tur-<zaman>
"""
import csv, datetime as dt, pathlib, re, sys

R = pathlib.Path(__file__).resolve().parent.parent
G = "http://grafana.localtest.me"
RETENTION_H = 48

def hm(ts): return dt.datetime.fromtimestamp(int(ts)).strftime("%H:%M:%S")
def day(ts): return dt.datetime.fromtimestamp(int(ts)).strftime("%d.%m.%Y %H:%M")
def dur(a, b):
    s = int(b) - int(a); return f"{s // 60} dk {s % 60:02d} sn" if s >= 60 else f"{s} sn"
def link(uid_url, ns, t0, t1):
    return f"{uid_url}?var-level={ns}&from={(int(t0) - 60) * 1000}&to={(int(t1) + 120) * 1000}"

def level_dir(nn):
    return next(R.glob(f"{nn}-*"))

_cache = {}
def problem_info(pid):
    """(başlık, [(dashboard adı, taban url)], görünmez mi) — sorunun kendi seviyesinin README'sinden."""
    nn = pid[1:3]
    if nn not in _cache:
        _cache[nn] = (level_dir(nn) / "README.md").read_text()
    text = _cache[nn]
    m = re.search(rf"^### {pid} · (.*)$", text, flags=re.M)
    title = m.group(1).strip() if m else pid
    body = text[m.end():] if m else ""
    body = re.split(r"^### |^## ", body, flags=re.M)[0]
    g = re.search(r"^\*\*Grafana'da gör:\*\*(.*)$", body, flags=re.M)
    dashes, invisible = [], False
    if g:
        line = g.group(1)
        invisible = "görünmez" in line.split("[")[0]
        for name, url in re.findall(r"\[`?([^`\]]+)`?\]\((http://grafana\.localtest\.me/d/[^)?]+)[^)]*\)", line):
            if (name, url) not in dashes: dashes.append((name, url))
    return title, dashes, invisible

def expects_clean(pid):
    """README sorunun kendi seviyesinde NOT-REPRODUCED beklendiğini söylüyor mu? (ör. P12-04: bir doğrulama)"""
    problem_info(pid)
    text = _cache[pid[1:3]]
    m = re.search(rf"^### {pid} · .*$", text, flags=re.M)
    body = re.split(r"^### |^## ", text[m.end():], flags=re.M)[0] if m else ""
    return bool(re.search(r"`?NOT-REPRODUCED`? beklenir", body))

def grafana_cell(pid, ns, t0, t1):
    _, dashes, invisible = problem_info(pid)
    if not dashes:
        return "görünmez — kanıt log'da" if invisible else "—"
    return " · ".join(f"[{n}]({link(u, ns, t0, t1)})" for n, u in dashes)

# Hüküm vermeyen (SKIPPED) bir scriptin gerekçesi, sarı uyarı satırlarından biridir; kayıtta boş kalmışsa
# log'dan okunur: kalıp cümleler ("EKSİK ÖLÇÜMdür") atlanır, ölçümün NEDEN yapılamadığını söyleyen satır seçilir.
_BOILER = ("Bu bir hüküm değil", 'Bu bir "sorun yok"', "make: ***")
_WHY = ("ölçüm yapılamadı", "ölçülemedi", "ölçüm yok", "ulaşılamadı", "kalkmadı", "elle çalıştır", "durdurulamadı",
        "yayılmadı", "hazır değil", "uzatmadı", "dönmedi", "koşmadı", "bulunamadı")
def skip_reason(out, log):
    try:
        lines = [l.strip() for l in (out / log).read_text().splitlines() if l.strip()]
    except OSError:
        return ""
    lines = [l for l in lines if not l.startswith(_BOILER)]
    for l in reversed(lines):
        if any(w in l for w in _WHY):
            return l[:300]
    return lines[-1][:300] if lines else ""

MARK = {"REPRODUCED": "🔴 REPRODUCED", "NOT-REPRODUCED": "🟢 NOT-REPRODUCED", "SKIPPED": "⚪ SKIPPED", "OK": "✔"}
def res(r): return MARK.get(r, f"✘ {r}")
def esc(s): return (s or "").replace("|", "\\|").strip()

def main(out):
    out = pathlib.Path(out)
    rows = list(csv.DictReader(open(out / "runs.tsv"), delimiter="\t"))
    for r in rows:
        if r["result"] == "SKIPPED" and not r["summary"].strip() and r["log"]:
            r["summary"] = skip_reason(out, r["log"])
    # Tekrar koşulan adımlar ayrı kayıtta: seviyenin saat aralığı turdaki asıl koşuyu gösterir.
    rr = out / "reruns.tsv"
    reruns = list(csv.DictReader(open(rr), delimiter="\t")) if rr.exists() else []
    for r in reruns:
        if r["result"] == "SKIPPED" and not r["summary"].strip() and r["log"]:
            r["summary"] = skip_reason(out, r["log"])
    again = {(r["level"], r["kind"], r["id"]): r for r in reruns}
    if not rows:
        print("kayıt yok"); return
    levels = []
    for r in rows:
        if r["level"] not in levels: levels.append(r["level"])
    t_first, t_last = rows[0]["start"], rows[-1]["end"]
    L = []
    L.append(f"# Tam tur raporu — 00 → 14\n")
    L.append(f"Tur: **{day(t_first)} → {day(t_last)}** ({dur(t_first, t_last)}). Araç: `tools/full-run.sh`; kayıt: "
             f"`runs.tsv`, her adımın tam çıktısı `logs/` altında.\n")
    L.append("**Nasıl okunur.** Her seviye rehberin sırasıyla koşuldu: `make up` (FRESH=0: Grafana temizlenmedi) → "
             "önceki seviyenin sorunları bu seviyede (`verify-prev`) → seviyenin kendi sorunları (`make repro`, "
             "`CONFIRM=1`) → `make down`. Veri yalnızca turun başında silindi (`make wipe`); bütün tur tek zaman "
             "ekseninde. Tablolardaki Grafana linkleri seviye seçili ve **o adımın saat aralığı hazır** açılır "
             "(başlangıçtan 1 dk önce → bitişten 2 dk sonra). Giriş: admin / ladder.\n")
    L.append(f"**Süre sınırı:** Prometheus {RETENTION_H} saat saklar — bu rapordaki linkler "
             f"**{day(int(t_last) + RETENTION_H * 3600)}**'e kadar veri gösterir. Sonrası için: "
             f"`make wipe` çalıştırılmadıkça veri {RETENTION_H} saati dolan kısımdan başlayarak silinir.\n")
    L.append("**Sonuçlar:** 🔴 REPRODUCED = sorun var (kendi seviyesinde beklenen) · 🟢 NOT-REPRODUCED = sorun yok · "
             "⚪ SKIPPED = script ölçemedi, hüküm vermedi · ✘ HATA = script ya da adım hata verdi. `verify-prev`'de "
             "BEKLENEN `NOT-REPRODUCED` yazan satırlar bu seviyenin çözdüğünü iddia ettikleridir; uyuşmazsa ✘. "
             "Tempo ve Loki yalnızca 11'in profilinde açıktır (`platform/lib/profile.sh`): 12'de 11'in trace ya da log "
             "isteyen sorunları SKIPPED görünür — ortamın tasarımı, sorunun değil.\n")

    L.append(f"**Bütün tur tek ekranda:** [00 · Overview]({G}/d/ladder-overview?from={(int(t_first) - 60) * 1000}"
             f"&to={(int(t_last) + 120) * 1000}) — her çizgi bir seviye; seviyeler sırayla koştuğu için zaman "
             "ekseninde yan yana dizilir.\n")
    L.append("## Özet\n")
    L.append("| Seviye | Saat | Kendi sorunları (🔴/🟢/⚪/✘) | Önceki seviyenin sorunları | Genel bakış |")
    L.append("|---|---|---|---|---|")
    for lv in levels:
        rs = [r for r in rows if r["level"] == lv]
        own = [r for r in rs if r["kind"] == "own"]; prev = [r for r in rs if r["kind"] == "prev"]
        c = lambda xs, k: sum(1 for x in xs if x["result"] == k)
        err = lambda xs: sum(1 for x in xs if x["result"].startswith("HATA"))
        bad = sum(1 for x in prev if x["expected"] and x["result"] not in (x["expected"], "SKIPPED") )
        claimed = sum(1 for x in prev if x["expected"])
        prevtxt = (f"{len(prev)} koşuldu · çözüldü iddiası {claimed}, uyuşmayan **{bad}**" if prev else "—")
        up = next((r for r in rs if r["kind"] == "up"), None)
        uptxt = "" if not up or up["result"] == "OK" else " · ✘ kurulum"
        ns = f"lvl{lv}"; t0, t1 = rs[0]["start"], rs[-1]["end"]
        over = (f"[Pods]({link(G + '/d/ladder-pods', ns, t0, t1)}) · [k6]({link(G + '/d/ladder-k6', ns, t0, t1)}) · "
                f"[RED]({link(G + '/d/ladder-app-red', ns, t0, t1)})")
        name = level_dir(lv).name
        L.append(f"| [{name}](#{name}) | {hm(t0)}–{hm(t1)} | {c(own,'REPRODUCED')}/{c(own,'NOT-REPRODUCED')}/"
                 f"{c(own,'SKIPPED')}/{err(own)}{uptxt} | {prevtxt} | {over} |")
    L.append("")

    # Bakılması gerekenler: hüküm vermeyen, iddiayla uyuşmayan ya da hata veren adımlar — tekrarıyla.
    look = []
    for r in rows:
        k = (r["level"], r["kind"], r["id"])
        why = ""
        if r["result"] == "SKIPPED": why = "ölçemedi"
        elif r["result"].startswith("HATA"): why = "hata"
        elif r["kind"] == "prev" and r["expected"] and r["result"] != r["expected"]: why = "çözüldü iddiasıyla uyuşmuyor"
        elif r["kind"] == "own" and r["result"] == "NOT-REPRODUCED" and not expects_clean(r["id"]):
            why = "kendi seviyesinde görünmedi"
        elif k in again: why = "script düzeltildi, tekrar koşuldu"
        if why: look.append((r, why, again.get(k)))
    if look:
        L.append("## Bakılması gerekenler\n")
        L.append("Hüküm vermeyen, beklenenle uyuşmayan ya da hata veren adımlar. Tekrar koşulduysa sonucu yanında; "
                 "ayrıntısı seviyenin tablosunda ve [Tekrar koşulanlar](#tekrar-koşulanlar) bölümünde.\n")
        L.append("| Seviye | Adım | İlk sonuç | Neden listede | Scriptin söylediği | Tekrar |")
        L.append("|---|---|---|---|---|---|")
        for r, why, rr in look:
            kind = "önceki seviye" if r["kind"] == "prev" else "kendi"
            said = esc(r["summary"]) or "—"
            L.append(f"| {level_dir(r['level']).name} | **{r['id']}** ({kind}) | {res(r['result'])} | {why} | "
                     f"{said} ([log]({r['log']})) | "
                     f"{res(rr['result']) + ' — ' + esc(rr.get('expected', '')) if rr else '—'} |")
        L.append("")

    for lv in levels:
        rs = [r for r in rows if r["level"] == lv]
        name = level_dir(lv).name; ns = f"lvl{lv}"
        t0, t1 = rs[0]["start"], rs[-1]["end"]
        L.append(f"## {name}\n")
        L.append(f"{day(t0)} → {hm(t1)} ({dur(t0, t1)}) · seviye README: [{name}/README.md](../../{name}/README.md) · "
                 f"bütün seviye boyunca: [01 · Pods & Resources]({link(G + '/d/ladder-pods', ns, t0, t1)}) · "
                 f"[15 · k6]({link(G + '/d/ladder-k6', ns, t0, t1)}) · [02 · App RED]({link(G + '/d/ladder-app-red', ns, t0, t1)})\n")
        for r in rs:
            if r["kind"] in ("up", "down", "platform"):
                label = {"up": "`FRESH=0 make up`", "down": "`make down`", "platform": "platform kontrolü"}[r["kind"]]
                extra = "" if r["result"] == "OK" else f" — {esc(r['summary'])} ([log]({r['log']}))"
                L.append(f"- {label}: {hm(r['start'])}–{hm(r['end'])} ({dur(r['start'], r['end'])}) {res(r['result'])}{extra}")
        prev = [r for r in rs if r["kind"] == "prev"]
        if prev:
            L.append(f"\n### Önceki seviyenin sorunları {ns}'de (`verify-prev`)\n")
            L.append("| Sorun | Sonuç | Beklenen | Saat | Scriptin hükmü | Grafana (saat aralığı hazır) |")
            L.append("|---|---|---|---|---|---|")
            for r in prev:
                title, _, _ = problem_info(r["id"])
                mis = " ✘" if r["expected"] and r["result"] not in (r["expected"], "SKIPPED") else ""
                if (lv, "prev", r["id"]) in again: mis += f" → tekrar: {res(again[(lv, 'prev', r['id'])]['result'])}"
                L.append(f"| **{r['id']}** {esc(title)} | {res(r['result'])}{mis} | {r['expected'] or '(açık kalabilir)'} | "
                         f"{hm(r['start'])}–{hm(r['end'])} | {esc(r['summary'])} ([log]({r['log']})) | "
                         f"{grafana_cell(r['id'], ns, r['start'], r['end'])} |")
        own = [r for r in rs if r["kind"] == "own"]
        if own:
            L.append(f"\n### {name} sorunları (`make repro`)\n")
            L.append("| Sorun | Sonuç | Saat | Scriptin hükmü | Grafana (saat aralığı hazır) |")
            L.append("|---|---|---|---|---|")
            for r in own:
                title, _, _ = problem_info(r["id"])
                tk = f" → tekrar: {res(again[(lv, 'own', r['id'])]['result'])}" if (lv, "own", r["id"]) in again else ""
                if r["result"] == "NOT-REPRODUCED" and expects_clean(r["id"]): tk += " (beklenen: bu bir doğrulama)"
                L.append(f"| **[{r['id']}](../../{name}/README.md#6-reproduce-edilebilir-sorunlar)** "
                         f"{esc(title)} | {res(r['result'])}{tk} | {hm(r['start'])}–{hm(r['end'])} ({dur(r['start'], r['end'])}) | "
                         f"{esc(r['summary'])} ([log]({r['log']})) | {grafana_cell(r['id'], ns, r['start'], r['end'])} |")
        L.append("")
    if reruns:
        L.append("## Tekrar koşulanlar\n")
        L.append("Turda ölçemeyen ya da ortam yüzünden yanlış ölçen adımlar, sebebi giderildikten sonra aynı seviye "
                 "yeniden kurularak tekrar koşuldu. Saat aralığı tekrarın kendisidir.\n")
        L.append("| Seviye | Adım | İlk sonuç | Tekrar | Neden tekrar | Saat | Scriptin hükmü | Grafana (saat aralığı hazır) |")
        L.append("|---|---|---|---|---|---|---|---|")
        first = {(r["level"], r["kind"], r["id"]): r for r in rows}
        for r in reruns:
            f0 = first.get((r["level"], r["kind"], r["id"]))
            ns = f"lvl{r['level']}"
            kind = "önceki seviye" if r["kind"] == "prev" else "kendi"
            L.append(f"| {level_dir(r['level']).name} | **{r['id']}** ({kind}) | {res(f0['result']) if f0 else '—'} | "
                     f"{res(r['result'])} | {esc(r.get('expected', ''))} | {day(r['start'])}–{hm(r['end'])} | "
                     f"{esc(r['summary'])} ([log]({r['log']})) | {grafana_cell(r['id'], ns, r['start'], r['end'])} |")
        L.append("")
    (out / "RAPOR.md").write_text("\n".join(L) + "\n")
    print(out / "RAPOR.md")

if __name__ == "__main__":
    main(sys.argv[1])
