#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P00-07 · Sunucu timeout'u yok → yarım-açık bağlantı sonsuza kadar kaynak tutar
#
# ÖLÇÜM NOTU 1: ingress üzerinden ölçmek işe yaramaz — ingress-nginx kendi timeout'larıyla yarım
#   bağlantıları yutar. Yani korumayı SEN tasarlamadın, tesadüfen önündeki katmandan geldi.
#   Uygulamanın kendi davranışını görmek için doğrudan pod'a bağlanıyoruz (port-forward).
# ÖLÇÜM NOTU 2: Go'da slowloris "yeni istekleri yavaşlatmaz" (her bağlantı kendi goroutine'inde).
#   Gerçek belirti: sunucu boşta duran yarım bağlantıyı ASLA kapatmaz → goroutine/FD/bellek birikir.
#   Kesin test: yarım bir istek gönder, WAIT saniye bekle, sunucu bağlantıyı kapattı mı?
WAIT=${WAIT:-20}
CONNS=${CONNS:-300}
ensure_healthy
pod=$(pod_name)
step "Doğrudan pod'a bağlan (ingress'i atla), yarım bir istek gönder ve $WAIT sn bekle"
port_forward "$pod" 18081
result=$(python3 - "$WAIT" "$CONNS" <<'PYEOF'
import socket, sys, time
wait, conns = int(sys.argv[1]), int(sys.argv[2])
# 1) Tek bağlantı: sunucu boşta duran yarım isteği kapatıyor mu?
s = socket.create_connection(("127.0.0.1", 18081), timeout=5)
s.sendall(b"POST /api/links HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 500\r\n\r\n{")
time.sleep(wait)
# Üç olası sonuç:
#   b""          → sunucu bağlantıyı KAPATTI (timeout var)
#   veri geldi   → sunucu YANIT verdi (408/413/503 — yine bir timeout/limit devrede)
#   socket.timeout → sunucu hâlâ sessizce BEKLİYOR (hiçbir koruma yok) ← aradığımız hata
s.settimeout(3)
closed = False
try:
    data = s.recv(1024)
    closed = True              # kapattı ya da yanıt verdi: her iki halde de kendini koruyor
except socket.timeout:
    closed = False             # hâlâ açık ve sessiz → korumasız
except OSError:
    closed = True
s.close()
# 2) Birikim: kaç yarım bağlantı aynı anda tutulabiliyor?
held = []
for _ in range(conns):
    try:
        c = socket.create_connection(("127.0.0.1", 18081), timeout=3)
        c.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")
        held.append(c)
    except OSError:
        break
print(f"{'CLOSED' if closed else 'OPEN'} {len(held)}")
time.sleep(5)
for c in held:
    try: c.close()
    except OSError: pass
PYEOF
)
port_forward_stop
state=${result%% *}; held=${result##* }
note "Yarım istek $WAIT sn sonra: sunucu $([[ $state == CLOSED ]] && echo 'KAPATTI ya da yanıt verdi (koruma var)' || echo 'hâlâ sessizce BEKLİYOR (koruma yok)')"
note "Aynı anda tutulabilen yarım bağlantı sayısı: $held (her biri bir goroutine + bir FD)"
note "ReadHeaderTimeout/IdleTimeout olsaydı sunucu saniyeler içinde kapatırdı."
grafana_hint "01 · Pods & Resources → 'Goroutine' (01'den itibaren; 00'da metrik yok → P00-09)"
[[ "$state" == OPEN ]] && reproduced "sunucu yarım bağlantıyı $WAIT sn boyunca kapatmadı — hiçbir timeout yok, $held bağlantı birikti"
not_reproduced "sunucu yavaş/yarım bağlantıyı kapattı — timeout'lar var (01)"
