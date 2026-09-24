#!/usr/bin/env python3
"""Lint kuralı 19 — seviye README'sindeki rehber, yabancı birinin terminaline olduğu gibi yapıştırılabilir mi?

Her seviye README'si iki yerde yapıştırılacak komut taşır: §4'teki "Rehber" ve §6'daki her sorunun
"Elle" adımları. Bu kural şunları zorunlu tutar:
  • §4'te "**Rehber —" bloğu var.
  • Her "### PNN-XX" bölümünde "**Reproduce (adım adım):**", "Otomatik", "Elle" ve
    "**Terminalde ne görmelisin:**" var; en az bir ```bash bloğu var ve İLK bloğun ilk komutu
    `make fresh` (Grafana her deneye boş başlar, çizgiler önceki deneylere karışmaz).
  • Rehber ve Elle bloklarında yorum YOK: macOS'un varsayılan zsh'ında `interactivecomments` kapalıdır;
    yapıştırılan `komut  # açıklama` satırında `#` ve sonrası komutun argümanı olur ve komut hata verir.
    Açıklama bloğun dışında, adımın metninde durur.
  • Çift tırnak içinde `!` YOK: zsh'ın geçmiş genişletmesi onu yapıştırma anında değiştirir.
  • Her blok `bash -n` ve (varsa) `zsh -n` ile sözdizimi hatasız.
Kullanım: tools/lint-guide.py <seviye-klasörü>   (tools/lint-skeleton.sh çağırır)
"""
import pathlib, re, shutil, subprocess, sys

def comment_positions(line):
    """Tırnak dışında, kelime başındaki '#' — kabuk bunu yorum sayar, zsh (varsayılan) saymaz."""
    q = None; prev = " "
    for i, ch in enumerate(line):
        if q:
            if ch == q and not (q == '"' and prev == "\\"): q = None
        elif ch in "'\"": q = ch
        elif ch == "#" and (prev.isspace() or i == 0): return i
        prev = ch
    return -1

def bang_in_dquotes(line):
    q = None; prev = " "
    for ch in line:
        if q:
            if ch == q and not (q == '"' and prev == "\\"): q = None
            elif q == '"' and ch == "!": return True
        elif ch in "'\"": q = ch
        prev = ch
    return False

def blocks(text):
    return re.findall(r"```bash\n(.*?)```", text, flags=re.S)

def check_block(where, code, errs):
    for n, line in enumerate(code.splitlines(), 1):
        if comment_positions(line) >= 0:
            errs.append(f"{where}: satır {n} yorum içeriyor (zsh'da komutun parçası olur): {line.strip()[:70]}")
        if bang_in_dquotes(line):
            errs.append(f"{where}: satır {n} çift tırnak içinde '!' (zsh geçmiş genişletmesi): {line.strip()[:70]}")
    for sh in ("bash", "zsh"):
        if not shutil.which(sh): continue
        r = subprocess.run([sh, "-n"], input=code, capture_output=True, text=True)
        if r.returncode != 0:
            errs.append(f"{where}: {sh} -n sözdizimi hatası: {r.stderr.strip()[:120]}")

def main(level_dir):
    d = pathlib.Path(level_dir); readme = (d / "README.md").read_text()
    errs = []
    s4 = re.search(r"^## 4\..*?(?=^## 5\.)", readme, flags=re.S | re.M)
    if not s4 or "**Rehber —" not in s4.group(0):
        errs.append("§4: '**Rehber —' bloğu yok")
    else:
        rehber = s4.group(0)[s4.group(0).index("**Rehber —"):]
        for i, b in enumerate(blocks(rehber), 1): check_block(f"§4 Rehber blok {i}", b, errs)
    parts = re.split(r"^(### P\d\d-\d\d)\b", readme, flags=re.M)
    for k in range(1, len(parts), 2):
        pid = parts[k][4:]; body = re.split(r"^## |^---$", parts[k + 1], flags=re.M)[0]
        for need in ("**Reproduce (adım adım):**", "Otomatik", "Elle", "**Terminalde ne görmelisin:**"):
            if need not in body: errs.append(f"{pid}: '{need}' yok")
        bs = blocks(body)
        if not bs:
            errs.append(f"{pid}: yapıştırılacak ```bash bloğu yok"); continue
        first = next((l.strip() for l in bs[0].splitlines() if l.strip()), "")
        if first != "make fresh":
            errs.append(f"{pid}: ilk komut 'make fresh' değil ({first[:40]})")
        for i, b in enumerate(bs, 1): check_block(f"{pid} blok {i}", b, errs)
    for e in errs: print(f"  ✘ {d.name}: {e}")
    return 1 if errs else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
