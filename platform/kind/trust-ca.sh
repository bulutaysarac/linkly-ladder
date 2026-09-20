#!/usr/bin/env bash
# Kurumsal TLS araya girmesi (Cloudflare Gateway / Zscaler vb.) altında kind node'ları registry'lere
# bağlanamaz: host macOS keychain'deki kök CA'yı tanır, node konteynerleri tanımaz.
# Bu script canlı el sıkışmadan kök CA'yı çıkarır, her node'un güven deposuna koyar ve containerd'yi yeniler.
# Kurumsal ağ dışındaysan zararsız: zincir zaten public CA ise hiçbir şey eklemez.
set -euo pipefail
CLUSTER=${CLUSTER:-ladder}
# Birden çok hedef dene: proxy bazı adlarda cevap vermeyebilir.
PROBES=${PROBES:-"europe-west8-docker.pkg.dev registry.k8s.io ghcr.io docker.io"}
CA=$(mktemp -d)/corp-ca.crt
: > "$CA.chain"
for probe in $PROBES; do
  # openssl, zincirde self-signed kök görünce 1 döner — bu bizim ARADIĞIMIZ durum.
  # Bu yüzden çıkış kodunu değil, çıktının dolu olup olmadığını kontrol ediyoruz.
  openssl s_client -showcerts -connect "$probe:443" -servername "$probe" </dev/null 2>/dev/null \
    | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > "$CA.chain.try" || true
  if [[ -s "$CA.chain.try" ]]; then
    cat "$CA.chain.try" >> "$CA.chain"
    echo "  zincir alındı: $probe"
  fi
done
[[ -s "$CA.chain" ]] || { echo "hiçbir hedeften TLS zinciri alınamadı (ağ?)"; exit 1; }
# Zincirdeki son sertifika kök: subject == issuer ise MITM kökü, ekle.
python3 - "$CA.chain" "$CA" <<'PY'
import subprocess, sys
chain, out = sys.argv[1], sys.argv[2]
blocks, cur = [], []
for line in open(chain):
    cur.append(line)
    if "END CERTIFICATE" in line:
        blocks.append("".join(cur)); cur = []
keep = []
for b in blocks:
    txt = subprocess.run(["openssl", "x509", "-noout", "-subject", "-issuer"], input=b,
                         capture_output=True, text=True).stdout
    sub = [l for l in txt.splitlines() if l.startswith("subject")][0][8:].strip()
    iss = [l for l in txt.splitlines() if l.startswith("issuer")][0][7:].strip()
    if sub == iss:
        keep.append(b)
open(out, "w").write("".join(keep))
print(f"{len(keep)} kök CA bulundu" if keep else "kurumsal kök CA yok (public zincir) — atlanıyor")
PY

if [[ ! -s "$CA" ]]; then echo "✔ CA enjeksiyonu gerekmiyor"; exit 0; fi
for node in $(kind get nodes --name "$CLUSTER"); do
  docker cp "$CA" "$node:/usr/local/share/ca-certificates/corp-mitm.crt"
  docker exec "$node" update-ca-certificates >/dev/null 2>&1
  docker exec "$node" systemctl restart containerd
  echo "  ✔ $node"
done
echo "✔ kurumsal CA tüm node'lara kuruldu, containerd yeniden başlatıldı"
